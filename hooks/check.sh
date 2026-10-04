#!/bin/bash
# voice-conversation SessionStart hook (startup, resume): when two-way voice input is set up but can't
# work (the helper stopped, or macOS hasn't granted a permission), show a warning. Silent otherwise.
# Synchronous, so the warning reaches the user; fast (no network) and always exits 0.

DATA="${CLAUDE_PLUGIN_DATA:-}"
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
case "${CLAUDE_CODE_ENTRYPOINT:-}" in sdk-*) exit 0 ;; esac

[ -d "$DATA/.hotkey-build.lock" ] && exit 0  # an update is rebuilding the helper right now
case "${TERM_PROGRAM:-}" in
  iTerm.app) terminal=iTerm2 ;;
  Apple_Terminal) terminal=Terminal ;;
  *) terminal=none ;;  # a terminal the helper doesn't type into: no Automation grant matters
esac
state=$(bash "$ROOT/scripts/voice-input-state.sh" "$DATA" "$terminal")
case "$state" in
  "missing: "*)
    msg="voice-conversation voice input can't work yet. Voice Conversation Hotkey still needs: ${state#missing: }. Allow it in System Settings > Privacy & Security, in the section of that name." ;;
  "not running")
    msg="voice-conversation voice input is set up, but its hotkey helper isn't running. Run /speak setup input to reinstall it, or /speak hotkey off to turn voice input off." ;;
  *) exit 0 ;;
esac
jq -cn --arg m "$msg" '{systemMessage: $m}' 2>/dev/null
exit 0
