#!/bin/bash
# Pause / resume Claude Code (and Codex) speech. The menu bar app (caps-mute-menubar) runs
# this on an icon click or a bare tap of Control; it also works by hand from any shell.
#
#   speak-pause.sh [toggle]    speaking or idle -> pause, paused -> resume
#   speak-pause.sh pause | resume | status | kill
#
# Playback is ~/.claude/hooks/speak-play, started by speak-response.sh (Claude and Codex
# copies). Pause = SIGUSR2, resume = SIGCONT, kill = SIGTERM (it exits 0 and the speaking
# session's hook carries on, releasing the queue lock). While paused the player keeps a
# marker file ~/.claude/.speak-paused.d/<pid> (the menu bar badge reads it) and keeps the
# shared speak lock fresh, so other sessions wait behind it instead of talking over it.
# A separate flag holds upcoming replies too, including when pause is pressed at idle.
# `kill` is what mute (Caps Lock / double-tap Control / menu) uses: stops speak-play, afplay, say.
# Exit codes: 0 = done (for status: paused), 1 = status: speaking, 2 = nothing playing.
set -u
PLAYER=speak-play
MARKERS="$HOME/.claude/.speak-paused.d"
PAUSE_FLAG="$HOME/.claude/.speech-paused"

players() { pgrep -x "$PLAYER" 2>/dev/null; }
paused_players() {   # PIDs with a live marker; stale markers (dead pid) are pruned on the way
  local f pid comm
  [ -d "$MARKERS" ] || return 0
  for f in "$MARKERS"/*; do
    [ -e "$f" ] || continue
    pid=${f##*/}
    comm=$(ps -o comm= -p "$pid" 2>/dev/null); comm=${comm##*/}
    if [ "$comm" = "$PLAYER" ]; then echo "$pid"; else rm -f "$f"; fi
  done
}

pause_speech() {
  : > "$PAUSE_FLAG" || return 1
  local all
  all=$(players)
  [ -z "$all" ] || kill -USR2 $all 2>/dev/null
  echo paused
}
resume_speech() {
  rm -f "$PAUSE_FLAG" || return 1
  local paused
  paused=$(paused_players)
  [ -z "$paused" ] || kill -CONT $paused 2>/dev/null
  echo resumed
}

case "${1:-toggle}" in
  toggle)
    paused=$(paused_players)
    if [ -e "$PAUSE_FLAG" ] || [ -n "$paused" ]; then resume_speech
    else pause_speech; fi ;;
  pause)
    pause_speech ;;
  resume)
    resume_speech ;;
  status)
    if   [ -e "$PAUSE_FLAG" ] || [ -n "$(paused_players)" ]; then echo paused; exit 0
    elif [ -n "$(players)" ];        then echo speaking; exit 1
    else                                  echo idle;     exit 2; fi ;;
  kill)
    rm -f "$PAUSE_FLAG"
    pkill -TERM -x "$PLAYER" 2>/dev/null; pkill -x afplay 2>/dev/null; pkill -x say 2>/dev/null
    rm -f "$MARKERS"/* 2>/dev/null; echo stopped ;;
  *) echo "usage: speak-pause.sh [toggle|pause|resume|status|kill]" >&2; exit 64 ;;
esac
