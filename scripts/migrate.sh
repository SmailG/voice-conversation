#!/bin/bash
# Takes over an install made under this plugin's old name, claude-speak (0.4.0 and earlier): stops
# its services, removes its hotkey app and that app's privacy permissions, copies its settings into
# this install's data dir (never overwriting), and mutes its hooks until it is uninstalled.
# The models live in the shared Hugging Face cache, so nothing is downloaded again.
#   migrate.sh <data_dir>
# Exit 0: nothing to migrate. Exit 10: migrated. Anything else: failed.
set -euo pipefail

DATA="${1:?usage: migrate.sh <data_dir>}"
OLD="com.claude-speak"
OLD_DATA="$HOME/.claude/plugins/data/claude-speak-claude-speak"
OLD_APP="${VOICE_CONVERSATION_APP_DIR:-$HOME/Applications}/Claude Speak Hotkey.app"
AGENTS="$HOME/Library/LaunchAgents"
PORT="${VOICE_CONVERSATION_PORT:-8765}"
PORT_FREE_WAIT_S=15
MIGRATED=10

[ -f "$AGENTS/$OLD.daemon.plist" ] || [ -d "$OLD_DATA" ] || exit 0
echo "==> taking over the claude-speak install (this plugin's old name)"

for agent in "$OLD.daemon" "$OLD.hotkey"; do
  launchctl bootout "gui/$(id -u)/$agent" >/dev/null 2>&1 || true
  rm -f "$AGENTS/$agent.plist"
done
if [ -d "$OLD_APP" ]; then
  tccutil reset All "$OLD.hotkey" >/dev/null 2>&1 || true  # while the app still exists
  rm -rf "$OLD_APP"
fi

# The old service can take a moment to exit; setup refuses to start while the port is taken.
waited=0
while lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 && [ "$waited" -lt "$PORT_FREE_WAIT_S" ]; do
  sleep 1; waited=$((waited + 1))
done

if [ -d "$OLD_DATA" ]; then
  mkdir -p "$DATA"
  # Settings, voices and the Whisper folder (symlinks into the model cache). Not the old code,
  # logs or runtime state.
  rsync -a --ignore-existing \
    --exclude=/daemon/ --exclude='/*.log' --exclude=/hotkey_status.json --exclude=/guard.json \
    --exclude=/.hotkey-build.lock --exclude=/off \
    "$OLD_DATA/" "$DATA/"
  touch "$OLD_DATA/off"  # its hooks stay quiet until it is uninstalled
  echo "==> copied its settings to $DATA"
fi
exit "$MIGRATED"
