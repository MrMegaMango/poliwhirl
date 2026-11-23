#!/bin/bash
# Speak Codex's final response after an `agent-turn-complete` notification.
#
# Pipeline:
#   notify JSON -> last-assistant-message -> short listen-friendly summary
#               -> local Phonon/macOS speech -> serialized pausable playback
#
# Codex already supplies the completed answer in the notification payload, so
# unlike the Claude Code hook this does not scrape or poll a transcript.
set -uo pipefail
umask 077
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

hook_dir="${CODEX_SPEAK_HOOK_DIR:-$HOME/.codex/hooks}"
speak_log="${CODEX_SPEAK_LOG:-$hook_dir/speak-response.log}"

# Reuse the existing private voice key and voice settings without copying the
# secret. A Codex-specific file can override them when desired.
shared_voice_env="${CODEX_SHARED_VOICE_ENV:-$HOME/.claude/hooks/voice.env}"
codex_voice_env="${CODEX_VOICE_ENV:-$hook_dir/voice.env}"
[ -r "$shared_voice_env" ] && . "$shared_voice_env"
[ -r "$codex_voice_env" ] && . "$codex_voice_env"

phonon_voice="${CODEX_PHONON_VOICE:-${PHONON_VOICE:-Harper}}"
speed="${CODEX_VOICE_SPEED:-${SPEED:-1.0}}"
volume="${CODEX_VOICE_VOLUME:-${VOLUME:-1.0}}"
summarize="${CODEX_SUMMARIZE:-${SUMMARIZE:-1}}"
# Summary model chain, tried in order: gpt-*/o* -> OpenAI Responses API,
# claude-* -> Anthropic Messages API. Default GPT-6 (the only GPT-6 this key
# can see, 2026-09-09), then Claude Opus 5: the same chain as the Claude Code hook.
summary_models="${CODEX_SUMMARY_MODELS:-${SUMMARY_MODELS:-${CODEX_SUMMARY_MODEL:-${SUMMARY_MODEL:-gpt-6-astra}} claude-opus-5}}"
summary_api_key="${CODEX_VOICE_API_KEY:-${VOICE_API_KEY:-${ANTHROPIC_API_KEY:-}}}"
# OpenAI key: an explicit override, else the one Codex itself is logged in with
# (its environment, or ~/.codex/auth.json). Read only; Codex auth is untouched.
summary_openai_key="${CODEX_OPENAI_API_KEY:-${VOICE_OPENAI_API_KEY:-${OPENAI_API_KEY:-$(jq -r '.OPENAI_API_KEY // empty' "$HOME/.codex/auth.json" 2>/dev/null)}}}"
# Keep credentials in this shell only; child processes receive the key through
# a private header file, never their environment or command line.
unset CODEX_VOICE_API_KEY VOICE_API_KEY ANTHROPIC_API_KEY CODEX_OPENAI_API_KEY VOICE_OPENAI_API_KEY OPENAI_API_KEY
text_cap="${CODEX_SPEAK_CAP:-${CAP:-1500}}"
dry_run="${CODEX_SPEAK_DRY_RUN:-0}"
no_play="${CODEX_SPEAK_NO_PLAY:-0}"
mute_probe="${CODEX_MUTE_PROBE:-$HOME/.claude/hooks/muted.sh}"

log() { printf '%s | %s\n' "$(date '+%FT%T')" "$*" >> "$speak_log" 2>/dev/null; }
is_muted() { [ -x "$mute_probe" ] && "$mute_probe"; }

temporary_dir=""
lock_held=0
cleanup() {
  if declare -F clear_raw_playback >/dev/null 2>&1; then
    clear_raw_playback
  fi
  if declare -F release_speak_lock >/dev/null 2>&1; then
    release_speak_lock
  fi
  [ -n "$temporary_dir" ] && [ -d "$temporary_dir" ] && rm -rf -- "$temporary_dir"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

payload=$(cat)
event=$(printf '%s' "$payload" | jq -r '.type // empty' 2>/dev/null)
thread_id=$(printf '%s' "$payload" | jq -r '."thread-id" // empty' 2>/dev/null | cut -c1-12)
turn_id=$(printf '%s' "$payload" | jq -r '."turn-id" // empty' 2>/dev/null | cut -c1-12)

if [ "$event" != "agent-turn-complete" ]; then
  log "thread=$thread_id turn=$turn_id skipped(event=${event:-invalid})"
  exit 0
fi

message_type=$(printf '%s' "$payload" | jq -r 'if has("last-assistant-message") then ."last-assistant-message" | type else "missing" end' 2>/dev/null)
if [ "$message_type" != "string" ]; then
  log "thread=$thread_id turn=$turn_id skipped(message-type=${message_type:-invalid})"
  exit 0
fi
text=$(printf '%s' "$payload" | jq -r '."last-assistant-message"' 2>/dev/null)
if [ -z "$text" ]; then
  log "thread=$thread_id turn=$turn_id skipped(empty-message)"
  exit 0
fi

if is_muted; then
  log "thread=$thread_id turn=$turn_id muted(skipped)"
  exit 0
fi

strip_markdown() {
  printf '%s\n' "$1" | sed -E \
    -e 's/`//g' -e 's/\*+//g' \
    -e 's/^[[:space:]]*#{1,6}[[:space:]]*//' \
    -e 's/^[[:space:]]*>[[:space:]]*//' \
    -e 's/\[([^]]+)\]\([^)]+\)/\1/g' \
    -e 's/[—–]/, /g' \
    | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177'
}

# Rewrite the final answer for listening, via the summary model chain (GPT-6
# with the Codex key, then Claude Opus 5 with the shared voice key). Read-only
# use of the keys: this never changes Codex authentication or exports a key.
spoken=""
summary_source="raw"
if [ "$summarize" = "1" ] && { [ -n "$summary_api_key" ] || [ -n "$summary_openai_key" ]; }; then
  source_text=$(printf '%s' "$text" | jq -Rrs '.[:6000]')
  system_prompt="You turn a coding agent's written reply into words it will speak aloud to its user, who is listening rather than reading. Lead with the outcome. Use short, plain sentences and natural spoken phrasing. You may reorganize and omit minor detail, but every statement must remain factually accurate to the reply. Never invent, add, exaggerate, or change a fact. Do not read code, paths, commands, flags, symbols, URLs, or identifiers literally; describe them naturally when they matter. Keep the assistant's first-person voice. Clearly state any question or action needed from the user, ideally last. Output only the spoken words, with no markdown or code. Hard limit: about 140 words. Finish every sentence and never cut off a required action or question. Do not answer or react to the reply yourself."
  system_prompt+=" Keep the reply's original language: summarize Chinese replies in Chinese and English replies in English, preserving necessary mixed-language terms."
  # One attempt against one model; prints the summary text, empty on any
  # failure (no key for that provider, no access, 4xx/5xx, refusal, network).
  # Both model families think by default and thinking counts against the
  # output cap, so leave headroom and pick the text blocks explicitly; lowest
  # reasoning effort keeps latency down. Feed the private API header through
  # an inherited file descriptor: never argv, the environment, or a temp file.
  summarize_with() {
    local m="$1"
    case "$m" in
      claude-*)
        [ -n "$summary_api_key" ] || return 0
        printf '%s' "$source_text" | jq -n --rawfile message /dev/stdin --arg model "$m" --arg system "$system_prompt" '{
          model: $model, max_tokens: 2000, system: $system,
          output_config: { effort: "low" },
          messages: [{role: "user", content: $message}]
        }' | curl -sS --max-time 30 https://api.anthropic.com/v1/messages \
          -H @<(printf '%s\n' "x-api-key: $summary_api_key" 'anthropic-version: 2023-06-01' 'content-type: application/json') \
          --data-binary @- 2>/dev/null \
        | jq -r '[.content[]? | select(.type=="text") | .text] | join(" ")' 2>/dev/null ;;
      *)
        [ -n "$summary_openai_key" ] || return 0
        printf '%s' "$source_text" | jq -n --rawfile message /dev/stdin --arg model "$m" --arg system "$system_prompt" '{
          model: $model, instructions: $system, input: $message,
          reasoning: { effort: "low" }, max_output_tokens: 2000
        }' | curl -sS --max-time 30 https://api.openai.com/v1/responses \
          -H @<(printf '%s\n' "Authorization: Bearer $summary_openai_key" 'content-type: application/json') \
          --data-binary @- 2>/dev/null \
        | jq -r '[.output[]? | select(.type=="message") | .content[]? | select(.type=="output_text") | .text] | join(" ")' 2>/dev/null ;;
    esac
  }
  # Walk the chain: the first model that returns text wins.
  tried=0
  for candidate in $summary_models; do
    spoken=$(summarize_with "$candidate" || true)
    if [ -n "$spoken" ]; then
      [ "$tried" = 0 ] && summary_source="llm:$candidate" || summary_source="llm:$candidate;fallback"
      break
    fi
    tried=$((tried + 1))
  done
  [ -n "$spoken" ] || summary_source="raw(summary-failed)"
fi

[ -n "$spoken" ] || spoken=$(strip_markdown "$text")
if [ -z "$spoken" ]; then
  log "thread=$thread_id turn=$turn_id skipped(empty-after-strip)"
  exit 0
fi
[ "$text_cap" -gt 0 ] 2>/dev/null && spoken=$(printf '%s' "$spoken" | jq -Rrs --argjson cap "$text_cap" '.[:$cap]')

# Use built-in Mandarin speech for Chinese and mixed-language replies.
say_voice=""
if printf '%s' "$spoken" | jq -eRs 'test("\\p{Han}")' >/dev/null; then
  say_voice="${CODEX_CHINESE_SAY_VOICE:-${CHINESE_SAY_VOICE:-Tingting}}"
fi

if [ "$dry_run" = "1" ]; then
  log "thread=$thread_id turn=$turn_id dry-run($summary_source) source_chars=${#text} spoken_chars=${#spoken}"
  printf '%s\n' "$spoken"
  exit 0
fi

# Share Claude's fixed playback lock so Claude and Codex never talk over each
# other. Keep this path pinned because stale-lock recovery removes it.
speak_lock_dir="$HOME/.claude/hooks/.speak.lock.d"
# Pausable player shared with the Claude Code hook (Control tap -> ~/.claude/hooks/speak-pause.sh).
# Exit 2 = it could not start -> fall back to afplay / say.
player="$HOME/.claude/hooks/speak-play"
# An explicit Codex speed override remains fixed; otherwise follow the shared
# slider preference during playback, even when this clip was queued earlier.
live_speed_args=(--speed "$speed")
if [ -z "${CODEX_VOICE_SPEED:-}" ]; then
  live_speed_args+=(--speed-file "$shared_voice_env")
fi
playback_skipped_muted=0
wait_for_speech_resume() {
  # Playback owns the queue lock here; keep it fresh while an idle pause holds this reply.
  while [ -e "$HOME/.claude/.speech-paused" ]; do
    is_muted && return 1
    touch -c "$speak_lock_dir" 2>/dev/null
    sleep "$lock_poll"
  done
  ! is_muted
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
  if [ -x "$player" ]; then
    "$player" --volume "$volume" --touch "$speak_lock_dir" "${live_speed_args[@]}" "$1"
    [ "$?" = "2" ] || return 0
  fi
  wait_for_speech_resume || { playback_skipped_muted=1; return 0; }
  mark_raw_playback
  afplay -v "$volume" -q 1 -r "$speed" "$1"
  local playback_status=$?
  clear_raw_playback
  return "$playback_status"
}
speak_text() {
  wait_for_speech_resume || { playback_skipped_muted=1; return 0; }
  if [ -x "$player" ]; then
    "$player" --volume "$volume" --touch "$speak_lock_dir" "${live_speed_args[@]}" --say "$1"
    [ "$?" = "2" ] || return 0
  fi
  wait_for_speech_resume || { playback_skipped_muted=1; return 0; }
  mark_raw_playback
  local say_args=(-r "$(awk -v speed="$speed" 'BEGIN { printf "%.0f", 200 * speed }')")
  [ -z "$say_voice" ] || say_args+=(-v "$say_voice")
  printf '[[volm %s]] %s' "$volume" "$1" | say "${say_args[@]}"
  local playback_status=$?
  clear_raw_playback
  return "$playback_status"
}
lock_wait="${CODEX_SPEAK_LOCK_WAIT:-${LOCK_WAIT:-240}}"
lock_poll="${CODEX_SPEAK_LOCK_POLL:-${LOCK_POLL:-0.2}}"
lock_stale="${CODEX_SPEAK_LOCK_STALE:-${LOCK_STALE:-300}}"

acquire_speak_lock() {
  local start holder lock_mtime now waited stale
  start=$(date +%s)
  while :; do
    if mkdir "$speak_lock_dir" 2>/dev/null; then
      printf '%s' "$$" > "$speak_lock_dir/pid" 2>/dev/null
      lock_held=1
      return 0
    fi

    stale=0
    holder=$(cat "$speak_lock_dir/pid" 2>/dev/null)
    case "$holder" in
      ''|*[!0-9]*) ;;
      *) kill -0 "$holder" 2>/dev/null || stale=1 ;;
    esac
    lock_mtime=$(stat -f %m "$speak_lock_dir" 2>/dev/null || echo 0)
    now=$(date +%s)
    [ "$lock_mtime" -gt 0 ] && [ $((now - lock_mtime)) -ge "$lock_stale" ] && stale=1
    if [ "$stale" = "1" ]; then
      mv "$speak_lock_dir" "$speak_lock_dir.dead.$$" 2>/dev/null \
        && rm -rf -- "$speak_lock_dir.dead.$$" 2>/dev/null
      continue
    fi

    waited=$((now - start))
    [ "$waited" -ge "$lock_wait" ] && return 1
    sleep "$lock_poll"
  done
}

release_speak_lock() {
  [ "$lock_held" = "1" ] || return 0
  [ "$(cat "$speak_lock_dir/pid" 2>/dev/null)" = "$$" ] && rm -rf -- "$speak_lock_dir" 2>/dev/null
  lock_held=0
}

temporary_dir=$(mktemp -d) || {
  log "thread=$thread_id turn=$turn_id skipped(mktemp-failed)"
  exit 0
}
audio_file="$temporary_dir/tts.wav"
tts_engine="macos"
rendered_voice="${say_voice:-system}"

# Keep queued audio at 1x so the live player can apply the current slider speed.
if [ -z "$say_voice" ]; then
  if printf '%s' "$spoken" | "$hook_dir/phonon/venv/bin/python" \
    "$hook_dir/phonon/render.py" "$phonon_voice" "$audio_file" 2>/dev/null; then
    tts_engine="phonon"
    rendered_voice="$phonon_voice"
  fi
fi

queue_start=$(date +%s)
if ! acquire_speak_lock; then
  log "thread=$thread_id turn=$turn_id skipped(queue-busy>${lock_wait}s;$summary_source)"
  exit 0
fi
queue_wait=$(( $(date +%s) - queue_start ))

if is_muted; then
  log "thread=$thread_id turn=$turn_id muted-while-queued(${queue_wait}s)"
  exit 0
fi

if [ "$no_play" = "1" ]; then
  log "thread=$thread_id turn=$turn_id prepared(no-play;engine=$tts_engine;voice=$rendered_voice;$summary_source) source_chars=${#text} spoken_chars=${#spoken}"
elif [ "$tts_engine" = "phonon" ] && [ -s "$audio_file" ]; then
  play_audio "$audio_file"
  if [ "$playback_skipped_muted" = "1" ]; then log "thread=$thread_id turn=$turn_id skipped(muted-before-playback)"; exit 0; fi
  log "thread=$thread_id turn=$turn_id spoke($tts_engine;voice=$rendered_voice;$summary_source;qwait=${queue_wait}s) source_chars=${#text} spoken_chars=${#spoken}"
else
  speak_text "$spoken"
  if [ "$playback_skipped_muted" = "1" ]; then log "thread=$thread_id turn=$turn_id skipped(muted-before-playback)"; exit 0; fi
  log "thread=$thread_id turn=$turn_id spoke(macos;voice=${say_voice:-system};$summary_source;qwait=${queue_wait}s) source_chars=${#text} spoken_chars=${#spoken}"
fi
