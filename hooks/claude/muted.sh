#!/bin/bash
# Quiet-mode probe for Claude Code hooks. Exit 0 (success) = muted, exit 1 = not.
# Muted when EITHER:
#   - the menu bar click-toggle is on (file ~/.claude/.muted-click exists), OR
#   - the Caps Lock key is engaged.
# Reading Caps Lock needs no installs: JXA -> AppKit NSEvent.modifierFlags,
# the 0x10000 (65536) bit = Caps Lock.
#
# Manual override (testing): CLAUDE_QUIET=1 force muted / CLAUDE_QUIET=0 force not.
case "${CLAUDE_QUIET:-}" in
  1) exit 0 ;;
  0) exit 1 ;;
esac

[ -f "$HOME/.claude/.muted-click" ] && exit 0

state=$(osascript -l JavaScript \
  -e 'ObjC.import("AppKit"); (($.NSEvent.modifierFlags & 65536) !== 0).toString()' \
  2>/dev/null)

[ "$state" = "true" ]
