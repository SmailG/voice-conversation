#!/bin/bash
# What stops voice input from working, for /speak status and the session-start warning.
#   voice-input-state.sh <data_dir>
# Prints one line, or nothing when voice input isn't set up or the hotkey is off:
#   ready | not running | unknown | missing: <permission>, <permission>
# Fast (one launchctl call, one small JSON file); never fails.

DATA="${1:-}"
AGENT="com.voice-conversation.hotkey"
[ -n "$DATA" ] && [ -f "$DATA/models/whisper/config.json" ] || exit 0
[ "$(tr -d '[:space:]' 2>/dev/null < "$DATA/hotkey")" = "off" ] && exit 0

if ! launchctl print "gui/$(id -u)/$AGENT" >/dev/null 2>&1; then
  echo "not running"
elif ! missing=$(jq -er '[(if .input_monitoring then empty else "Input Monitoring" end),
                          (if .microphone == "granted" then empty else "Microphone" end),
                          ((.automation_denied // [])[] | "Automation of \(.)")] | join(", ")' \
                 "$DATA/hotkey_status.json" 2>/dev/null); then
  echo "unknown"
elif [ -n "$missing" ]; then
  echo "missing: $missing"
else
  echo "ready"
fi
exit 0
