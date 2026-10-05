#!/bin/bash
# voice-conversation SessionStart hook: after a plugin update, copy the new daemon code into the
# data dir the launchd service runs from, and restart it; rebuild the voice-input hotkey helper
# if its source changed (build-helper.sh is a no-op otherwise). A no-op unless /speak setup was run
# by THIS install (a --plugin-dir checkout and a marketplace install share one launchd label).
# Never fails the session.

ROOT="${CLAUDE_PLUGIN_ROOT:-}"
DATA="${CLAUDE_PLUGIN_DATA:-}"
LABEL="com.voice-conversation.daemon"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

[ -n "$ROOT" ] && [ -n "$DATA" ] && [ -f "$PLIST" ] || exit 0
owner=$(/usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:VOICE_CONVERSATION_HOME" "$PLIST" 2>/dev/null)
[ "$owner" = "$DATA" ] || exit 0

# A session keeps the plugin version it started with, so one left open across an update runs an
# older copy of this hook at its next /clear, compact or resume. It used to copy its older daemon
# over the newer one and rebuild the hotkey helper from older source, which wipes the helper's
# macOS permissions (and the next new session rebuilt it back, wiping them again). So once a
# version has synced, older versions leave everything alone.
MARK="$DATA/synced_version"
version_of() { sed -n 's/^ *"version": *"\([0-9][0-9.]*\)".*/\1/p' "$1" 2>/dev/null | head -1; }
older_than() {  # older_than A B: A is an earlier version than B, compared field by field
  local a b i
  IFS=. read -r -a a <<<"$1"
  IFS=. read -r -a b <<<"$2"
  for i in 0 1 2 3; do
    [ "${a[i]:-0}" -lt "${b[i]:-0}" ] && return 0
    [ "${a[i]:-0}" -gt "${b[i]:-0}" ] && return 1
  done
  return 1
}
mine=$(version_of "$ROOT/.claude-plugin/plugin.json")
synced=$(head -1 "$MARK" 2>/dev/null)
case "$synced" in *[!0-9.]* | .* | *.) synced="" ;; esac
if [ -n "$mine" ] && [ -n "$synced" ] && older_than "$mine" "$synced"; then exit 0; fi

# Compare only the sources: the running daemon writes __pycache__/ into DATA, and treating that
# as a change would restart the service (and cut off speech) at every session start.
daemon_changed() {
  local f
  for f in "$ROOT"/daemon/*.py; do
    cmp -s "$f" "$DATA/daemon/${f##*/}" || return 0
  done
  return 1
}
if daemon_changed; then
  mkdir -p "$DATA/daemon" && cp "$ROOT"/daemon/*.py "$DATA/daemon/" \
    && launchctl kickstart -k "gui/$(id -u)/$LABEL" >/dev/null 2>&1
fi

HOTKEY_PLIST="$HOME/Library/LaunchAgents/com.voice-conversation.hotkey.plist"
if [ -f "$HOTKEY_PLIST" ] \
  && [ "$(/usr/libexec/PlistBuddy -c "Print :ProgramArguments:1" "$HOTKEY_PLIST" 2>/dev/null)" = "$DATA" ]; then
  bash "$ROOT/scripts/build-helper.sh" "$DATA" >/dev/null 2>&1
fi
[ -z "$mine" ] || [ "$mine" = "$synced" ] || printf '%s\n' "$mine" > "$MARK"
exit 0
