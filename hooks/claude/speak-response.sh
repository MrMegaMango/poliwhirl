#!/bin/bash
# Speak Claude's final response aloud when a turn finishes.
#
# Pipeline:  transcript -> THIS turn's final answer text
#                       -> the summary LLM (GPT-6, Opus 5 fallback) rewrites it into a spoken-style summary
#                       -> local Phonon or built-in macOS speech
#                       -> afplay plays it — ONE session at a time.
# Wired in as a Stop hook in ~/.claude/settings.json.
#
# CROSS-SESSION SERIALIZATION: several Claude Code sessions finishing at once
# would otherwise all speak simultaneously (afplay has no built-in mixing lock),
# which is just noise. So the SLOW prep (summary + audio render) runs
# unlocked and in parallel, but the actual PLAYBACK grabs a shared lock
# ($SPEAK_LOCK_DIR): a session queues until whoever is speaking finishes, then
# plays. No overlap. The queue wait is logged as qwait=…s, and mute is re-checked
# after the wait so muting mid-queue stays silent.
#
# Two correctness guards against the transcript "flush race" (the Stop hook can
# fire a beat before this turn's final text is written to the transcript file):
#   1. TURN-SCOPED: only consider assistant messages AFTER the last real user
#      prompt. A previous turn's answer is therefore structurally unreachable —
#      no more "it read the previous turn's stuff".
#   2. BOUNDED WAIT: if this turn's answer isn't in the file yet, poll briefly
#      for it to appear instead of going silent or reading something stale.
#
# Uses the shared Phonon runtime in ~/.codex/hooks/phonon for English,
# built-in macOS speech for Chinese, and a key for the summary chain ($SUMMARY_MODELS,
# default GPT-6 then Claude Opus 5): OpenAI key = VOICE_OPENAI_API_KEY or the
# Codex CLI login (~/.codex/auth.json); Anthropic key = VOICE_API_KEY (see
# ~/.claude/hooks/voice.env), falling back to ANTHROPIC_API_KEY. No key ->
# speaks the raw reply. Falls back to macOS speech if Phonon cannot render.
#
# DIAGNOSTIC LOG ($SPEAK_LOG): one line per fire — decision, wait time, and a
# preview of the extracted answer + what was voiced. Tail it with:
#   tail -f ~/.claude/hooks/speak-response.log
#
# Tuning knobs (env): PHONON_VOICE SPEED VOLUME SUMMARIZE SUMMARY_MODELS (or SUMMARY_MODEL + SUMMARY_MODEL_FALLBACK) VOICE_API_KEY VOICE_OPENAI_API_KEY CAP
#   WAIT_TRIES (default 15) / WAIT_INTERVAL (default 0.2s) -> ~3s max flush wait
#   SPEAK_LOG, SPEAK_LOG_FULL (1 = log full text, not previews)
#   LOCK_WAIT (max queue wait, default 240s) / SPEAK_LOCK_DIR / LOCK_STALE (300s)
# Pause / resume mid-sentence: tap the Control key (menu bar app -> speak-pause.sh), or run
#   ~/.claude/hooks/speak-pause.sh [toggle|pause|resume|status|kill]
# Playback goes through ~/.claude/hooks/speak-play (pausable; keeps the queue lock fresh while
# paused); afplay / say are only used if that binary is missing or cannot start.
# Stop playback any time:  killall speak-play afplay say   (the queue then drains to the next)
set -uo pipefail

# Secrets/overrides for the voice pipeline, kept OUT of the global shell env so
# Claude Code sessions keep their own auth (exporting ANTHROPIC_API_KEY globally
# would make Claude Code itself bill that key). Only this hook reads it.
[ -r "$HOME/.claude/hooks/voice.env" ] && . "$HOME/.claude/hooks/voice.env"

PHONON_VOICE="${PHONON_VOICE:-Harper}"
SPEED="${SPEED:-1.0}"
VOLUME="${VOLUME:-1.0}"
SUMMARIZE="${SUMMARIZE:-1}"
# Summary model chain, tried in order (space-separated): the first model that
# returns text wins; a later one is logged as ";fallback". gpt-*/o* -> OpenAI
# Responses API, claude-* -> Anthropic Messages API. Default = GPT-6 (the only
# GPT-6 the Codex key can see, 2026-09-09), then Opus 5 (the voice key's org
# has no Fable access). SUMMARY_MODEL / SUMMARY_MODEL_FALLBACK still set the
# first / second entry; SUMMARY_MODEL_FALLBACK="" drops the retry.
SUMMARY_MODELS="${SUMMARY_MODELS:-${SUMMARY_MODEL:-gpt-6-astra} ${SUMMARY_MODEL_FALLBACK-claude-opus-5}}"
# Anthropic key for claude-* models; falls back to ANTHROPIC_API_KEY.
SUMMARY_API_KEY="${VOICE_API_KEY:-${ANTHROPIC_API_KEY:-}}"
# OpenAI key for gpt-*/o* models: VOICE_OPENAI_API_KEY (voice.env) if set, else
# the key Codex CLI is logged in with (~/.codex/auth.json). Never exported.
SUMMARY_OPENAI_KEY="${VOICE_OPENAI_API_KEY:-$(jq -r '.OPENAI_API_KEY // empty' "$HOME/.codex/auth.json" 2>/dev/null)}"
CAP="${CAP:-1500}"
PLAYER="$HOME/.claude/hooks/speak-play"   # pausable player (see speak-pause.sh); exit 2 = could not start
SPEAK_LOG="${SPEAK_LOG:-$HOME/.claude/hooks/speak-response.log}"
WAIT_TRIES="${WAIT_TRIES:-15}"
WAIT_INTERVAL="${WAIT_INTERVAL:-0.2}"
WAIT_MS=200   # keep in sync with WAIT_INTERVAL (for the log's waited=… figure)

log() { printf '%s | %s\n' "$(date '+%FT%T')" "$*" >> "$SPEAK_LOG" 2>/dev/null; }
prev() {
  local n="${2:-200}"
  [ "${SPEAK_LOG_FULL:-0}" = "1" ] && n=100000
  printf '%s' "${1:-}" | tr '\n\t' '  ' | cut -c1-"$n"
}

# --- Cross-session speak lock -------------------------------------------------
# Only one session speaks at a time so concurrent sessions don't talk over each
# other. mkdir is the atomic primitive (macOS has no flock). A lock is stolen if
# its owner PID is dead or it is older than $LOCK_STALE, so a hard-killed session
# can't wedge the queue. Normal release is via the EXIT trap.
SPEAK_LOCK_DIR="${SPEAK_LOCK_DIR:-$HOME/.claude/hooks/.speak.lock.d}"
LOCK_WAIT="${LOCK_WAIT:-240}"     # max secs to wait in the queue before giving up
LOCK_POLL="${LOCK_POLL:-0.2}"     # queue poll interval
LOCK_STALE="${LOCK_STALE:-300}"   # a lock older than this is treated as abandoned
_lock_held=0
acquire_speak_lock() {
  local start holder lmtime now waited stale
  start=$(date +%s)
  while :; do
    if mkdir "$SPEAK_LOCK_DIR" 2>/dev/null; then
      printf '%s' "$$" > "$SPEAK_LOCK_DIR/pid" 2>/dev/null
      _lock_held=1
      return 0
    fi
    stale=0
    holder=$(cat "$SPEAK_LOCK_DIR/pid" 2>/dev/null)
    [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null && stale=1
    lmtime=$(stat -f %m "$SPEAK_LOCK_DIR" 2>/dev/null || echo 0)
    now=$(date +%s)
    [ "$lmtime" -gt 0 ] && [ $((now - lmtime)) -ge "$LOCK_STALE" ] && stale=1
    if [ "$stale" = "1" ]; then
      # single-winner steal: only the process whose rename wins clears the lock
      mv "$SPEAK_LOCK_DIR" "$SPEAK_LOCK_DIR.dead.$$" 2>/dev/null \
        && rm -rf "$SPEAK_LOCK_DIR.dead.$$" 2>/dev/null
      continue
    fi
    waited=$((now - start))
    [ "$waited" -ge "$LOCK_WAIT" ] && return 1
    sleep "$LOCK_POLL"
  done
}
release_speak_lock() {
  [ "$_lock_held" = "1" ] || return 0
  [ "$(cat "$SPEAK_LOCK_DIR/pid" 2>/dev/null)" = "$$" ] && rm -rf "$SPEAK_LOCK_DIR" 2>/dev/null
  _lock_held=0
}

input=$(cat)

# Quiet mode (Caps Lock engaged): stay silent.
if "$HOME/.claude/hooks/muted.sh"; then log "muted | skipped"; exit 0; fi

transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
sess=$(basename "${transcript:-unknown}" .jsonl 2>/dev/null | cut -c1-8)
if [ ! -f "$transcript" ]; then log "sess=$sess | no-transcript ($transcript)"; exit 0; fi

# THIS turn's final answer = last text-bearing assistant message that lives after
# the last real user prompt AND has no tool_use after it. (lastidx binds the array
# first — inside jq's reduce, `.` is the accumulator, not the array.)
read -r -d '' EXTRACT <<'JQ'
def lastidx(f): . as $arr | reduce range(0; ($arr|length)) as $i (null; if ($arr[$i]|f) then $i else . end);
def has(t): ((.message.content|type)=="array") and (([.message.content[]?.type] | index(t)) != null);
def real_user: .type=="user" and ( ((.message.content|type)=="string") or (((.message.content|type)=="array") and (([.message.content[]?.type] | index("tool_result")) == null)) );
. as $all
| ($all | lastidx(real_user)) as $b
| ([ $all[((($b // -1)+1)):][] | select(.type=="assistant") ]) as $a
| ($a | lastidx(has("text"))) as $tj
| ($a | lastidx(has("tool_use"))) as $tk
| if ($tj != null) and (($tk==null) or ($tj > $tk))
  then [ $a[$tj].message.content[]? | select(.type=="text") | .text ] | join(" ")
  else empty end
JQ

# Bounded wait for this turn's answer to flush (handles the race).
text=""; tries=0
while [ "$tries" -lt "$WAIT_TRIES" ]; do
  tries=$((tries + 1))
  text=$(jq -rs "$EXTRACT" "$transcript" 2>/dev/null)
  [ -n "$text" ] && break
  sleep "$WAIT_INTERVAL"
done
waitms=$(( (tries - 1) * WAIT_MS ))

if [ -z "$text" ]; then
  # No answer for this turn even after waiting: ended on a tool call / interrupted.
  diag=$(jq -rs '
    def lastidx(f): . as $arr | reduce range(0; ($arr|length)) as $i (null; if ($arr[$i]|f) then $i else . end);
    def real_user: .type=="user" and ( ((.message.content|type)=="string") or (((.message.content|type)=="array") and (([.message.content[]?.type] | index("tool_result")) == null)) );
    . as $all | ($all | lastidx(real_user)) as $b
    | ([ $all[((($b // -1)+1)):][] | select(.type=="assistant") ] | last | .message.content // []) | map(.type) | join(",")
  ' "$transcript" 2>/dev/null)
  log "sess=$sess | silent(no-answer-after-${waitms}ms; turn-last-blocks=[$diag])"
  exit 0
fi

strip_md() {
  printf '%s\n' "$1" | sed -E \
    -e 's/`//g' -e 's/\*+//g' \
    -e 's/^[[:space:]]*#{1,6}[[:space:]]*//' \
    -e 's/^[[:space:]]*>[[:space:]]*//' \
    -e 's/\[([^]]+)\]\([^)]+\)/\1/g' \
    -e 's/[—–]/, /g' \
    | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177'
}

# --- Step 1: rewrite into a listen-friendly spoken summary via the summary LLM (optional) ---
spoken=""
summary_src="raw"
if [ "$SUMMARIZE" = "1" ] && { [ -n "$SUMMARY_API_KEY" ] || [ -n "$SUMMARY_OPENAI_KEY" ]; }; then
  src=$(printf '%s' "$text" | jq -Rrs '.[:6000]')
  sys="You turn an AI coding assistant's written reply (below) into words IT will speak aloud to its user, who is LISTENING, not reading. Optimize entirely for the ear: lead with the outcome, use short plain sentences and natural spoken phrasing. You may reorganize and leave out minor detail so it is effortless to follow by ear, BUT everything you say must be factually accurate to the reply: never invent, add, exaggerate, or change any fact, and when unsure leave it out rather than guess. Never read code, file paths, commands, flags, symbols, or IDs literally, describe them in plain words (say 'the summary hook', not the filename). Keep the assistant's own first-person voice (\"I did X\"). Convey what was done and the result. If the reply asks the user something or needs them to act, state that plainly, ideally as the last thing said. Output ONLY the spoken words: no markdown, no code. You have a hard limit of about 140 words and MUST finish completely within it: prioritize ruthlessly, lead with the most important outcome, and drop lesser details entirely instead of trying to mention everything. Always finish your final sentence, and never cut off a question or action the user needs to take. Do NOT react to or answer the reply yourself."
  sys+=" Keep the reply's original language: summarize Chinese replies in Chinese and English replies in English, preserving necessary mixed-language terms."
  # One attempt against one model; prints the summary text (empty on any
  # failure: no key for that provider, no model access, 4xx/5xx, safety
  # refusal, network error). gpt-*/o* -> OpenAI Responses API, claude-* ->
  # Anthropic Messages API. Both families think by default and thinking tokens
  # count against the output cap, so give headroom well beyond the ~190-token
  # summary and pick the text blocks explicitly. Lowest reasoning effort keeps
  # latency + cost minimal for this trivial rewrite. Keys travel in a header
  # file via process substitution, never in argv.
  summarize_with() {
    local model="$1" body resp
    case "$model" in
      claude-*)
        [ -n "$SUMMARY_API_KEY" ] || return 0
        body=$(jq -n --arg model "$model" --arg sys "$sys" --arg t "$src" '{
          model: $model, max_tokens: 2000, system: $sys,
          output_config: { effort: "low" },
          messages: [ { role: "user", content: $t } ]
        }')
        resp=$(curl -sS --max-time 30 https://api.anthropic.com/v1/messages \
          -H @<(printf '%s\n' "x-api-key: $SUMMARY_API_KEY" 'anthropic-version: 2023-06-01' 'content-type: application/json') \
          -d "$body" 2>/dev/null)
        printf '%s' "$resp" | jq -r '[.content[]? | select(.type=="text") | .text] | join(" ")' 2>/dev/null ;;
      *)
        [ -n "$SUMMARY_OPENAI_KEY" ] || return 0
        body=$(jq -n --arg model "$model" --arg sys "$sys" --arg t "$src" '{
          model: $model, instructions: $sys, input: $t,
          reasoning: { effort: "low" }, max_output_tokens: 2000
        }')
        resp=$(curl -sS --max-time 30 https://api.openai.com/v1/responses \
          -H @<(printf '%s\n' "Authorization: Bearer $SUMMARY_OPENAI_KEY" 'content-type: application/json') \
          -d "$body" 2>/dev/null)
        printf '%s' "$resp" | jq -r '[.output[]? | select(.type=="message") | .content[]? | select(.type=="output_text") | .text] | join(" ")' 2>/dev/null ;;
    esac
  }

  # Walk the chain: the first model that returns text wins.
  tried=0
  for m in $SUMMARY_MODELS; do
    spoken=$(summarize_with "$m")
    if [ -n "$spoken" ]; then
      [ "$tried" = 0 ] && summary_src="llm($m)" || summary_src="llm($m;fallback)"
      break
    fi
    tried=$((tried + 1))
  done
  [ -n "$spoken" ] || summary_src="raw(summary-failed)"
fi

[ -n "$spoken" ] || spoken=$(strip_md "$text")
if [ -z "$spoken" ]; then log "sess=$sess | silent(empty-after-strip)"; exit 0; fi
[ "$CAP" -gt 0 ] && spoken=$(printf '%s' "$spoken" | jq -Rrs --argjson cap "$CAP" '.[:$cap]')

# Use built-in Mandarin speech for Chinese and mixed-language replies.
say_voice=""
if printf '%s' "$spoken" | jq -eRs 'test("\\p{Han}")' >/dev/null; then
  say_voice="${CHINESE_SAY_VOICE:-Tingting}"
fi

# --- Step 2: render English with Phonon; otherwise use macOS speech. Rendering runs
# WITHOUT the speak lock so queued sessions prep their audio in parallel. ---
# Both players prefer speak-play so a Control tap can pause them; afplay/say are the fallback.
playback_skipped_muted=0
wait_for_speech_resume() {
  # Playback owns the queue lock here; keep it fresh while an idle pause holds this reply.
  while [ -e "$HOME/.claude/.speech-paused" ]; do
    "$HOME/.claude/hooks/muted.sh" && return 1
    touch -c "$SPEAK_LOCK_DIR" 2>/dev/null
    sleep "$LOCK_POLL"
  done
  ! "$HOME/.claude/hooks/muted.sh"
}
mark_raw_playback() {
  local playing_dir="$HOME/.claude/.speak-playing.d"
  if mkdir -p "$playing_dir" 2>/dev/null; then
    printf '%s\n' "$$" > "$playing_dir/$$" 2>/dev/null || true
  fi
}
clear_raw_playback() {
  rm -f -- "$HOME/.claude/.speak-playing.d/$$" 2>/dev/null || true
}
play_audio() {
  wait_for_speech_resume || { playback_skipped_muted=1; return 0; }
  if [ -x "$PLAYER" ]; then
    "$PLAYER" --volume "$VOLUME" --touch "$SPEAK_LOCK_DIR" --speed "$SPEED" --speed-file "$HOME/.claude/hooks/voice.env" "$1"
    [ "$?" = "2" ] || return 0
  fi
  wait_for_speech_resume || { playback_skipped_muted=1; return 0; }
  mark_raw_playback
  afplay -v "$VOLUME" -q 1 -r "$SPEED" "$1"
  local playback_status=$?
  clear_raw_playback
  return "$playback_status"
}
speak_with_say() {
  wait_for_speech_resume || { playback_skipped_muted=1; return 0; }
  if [ -x "$PLAYER" ]; then
    "$PLAYER" --volume "$VOLUME" --touch "$SPEAK_LOCK_DIR" --speed "$SPEED" --speed-file "$HOME/.claude/hooks/voice.env" --say "$1"
    [ "$?" = "2" ] || return 0
  fi
  wait_for_speech_resume || { playback_skipped_muted=1; return 0; }
  mark_raw_playback
  local say_args=(-r "$(awk -v speed="$SPEED" 'BEGIN { printf "%.0f", 200 * speed }')")
  [ -z "$say_voice" ] || say_args+=(-v "$say_voice")
  printf '[[volm %s]] %s' "$VOLUME" "$1" | say "${say_args[@]}"
  local playback_status=$?
  clear_raw_playback
  return "$playback_status"
}

tmpdir=$(mktemp -d)
trap 'clear_raw_playback; release_speak_lock; rm -rf "$tmpdir"' EXIT
audio="$tmpdir/tts.wav"
tts_engine="macos"
rendered_voice="${say_voice:-system}"

# Render at normal speed; the player reads the latest preference at playback
# time and follows slider changes, including for already-rendered queued clips.
if [ -z "$say_voice" ]; then
  if printf '%s' "$spoken" | "$HOME/.codex/hooks/phonon/venv/bin/python" \
    "$HOME/.codex/hooks/phonon/render.py" "$PHONON_VOICE" "$audio" 2>/dev/null; then
    tts_engine="phonon"
    rendered_voice="$PHONON_VOICE"
  fi
fi

# --- Step 3: queue for playback. Wait for the shared lock so only ONE session
# speaks at a time; the rest wait here instead of talking over each other. ---
qstart=$(date +%s)
if ! acquire_speak_lock; then
  log "sess=$sess | skipped(speak-queue-busy>${LOCK_WAIT}s;$summary_src) | said=\"$(prev "$spoken" 160)\""
  exit 0
fi
qwait=$(( $(date +%s) - qstart ))
# Re-check mute: the user may have muted while this was waiting in the queue.
if "$HOME/.claude/hooks/muted.sh"; then log "sess=$sess | muted-while-queued(${qwait}s) | skipped"; exit 0; fi

if [ "$tts_engine" = "phonon" ] && [ -s "$audio" ]; then
  play_audio "$audio"
  if [ "$playback_skipped_muted" = "1" ]; then log "sess=$sess | muted-before-playback | skipped"; exit 0; fi
  log "sess=$sess | spoke(phonon;voice=$rendered_voice;$summary_src;waited=${waitms}ms;qwait=${qwait}s) | srclen=${#text} | src=\"$(prev "$text" 160)\" | said=\"$(prev "$spoken" 220)\""
else
  speak_with_say "$spoken"
  if [ "$playback_skipped_muted" = "1" ]; then log "sess=$sess | muted-before-playback | skipped"; exit 0; fi
  log "sess=$sess | spoke(macos;voice=${say_voice:-system};$summary_src;waited=${waitms}ms;qwait=${qwait}s) | srclen=${#text} | src=\"$(prev "$text" 160)\" | said=\"$(prev "$spoken" 220)\""
fi
