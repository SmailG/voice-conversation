#!/bin/bash
# Builds the voice-input hotkey helper into ~/Applications/Voice Conversation Hotkey.app and keeps its
# LaunchAgent (com.voice-conversation.hotkey) running. Idempotent: rebuilds only when the helper source
# changed, because the app is signed ad hoc and macOS ties its permissions (Input Monitoring,
# Microphone, Automation) to that exact build, so every rebuild means granting them again.
#   build-helper.sh <data_dir>
# Exit 3: no Swift compiler (Xcode Command Line Tools).
set -euo pipefail

DATA="${1:?usage: build-helper.sh <data_dir>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="Voice Conversation Hotkey"
APP_DIR="${VOICE_CONVERSATION_APP_DIR:-$HOME/Applications}"
APP="$APP_DIR/$NAME.app"
BUNDLE_ID="com.voice-conversation.hotkey"
LABEL="$BUNDLE_ID"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PORT="${VOICE_CONVERSATION_PORT:-8765}"
BUNDLE_FORMAT=1  # bump when info_plist() changes, so existing installs rebuild
LOCK="$DATA/.hotkey-build.lock"
LOCK_STALE_MIN=10
WORK=""

cleanup() {
  [ -n "$WORK" ] && rm -rf "$WORK"
  rmdir "$LOCK" 2>/dev/null || true
}

# Two sessions starting after an update both run this; only one may build.
take_lock() {
  mkdir -p "$DATA"
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +"$LOCK_STALE_MIN" 2>/dev/null)" ]; then rmdir "$LOCK"; fi
  mkdir "$LOCK" 2>/dev/null || { echo "another hotkey helper build is running"; exit 0; }
  trap cleanup EXIT
}

has_swiftc() {  # /usr/bin/swiftc exists on every Mac; it's only a shim without the developer tools
  xcode-select -p >/dev/null 2>&1 && xcrun --find swiftc >/dev/null 2>&1
}

# Sorted bytewise: a glob sorts by the caller's locale (main.swift lands after HUD.swift under
# en_US.UTF-8, last under C.UTF-8), so sessions from different terminals saw different hashes and
# rebuilt the app back and forth, wiping its permissions each time.
source_hash() {
  local f
  { echo "$BUNDLE_FORMAT"
    printf '%s\n' "$ROOT"/helper/*.swift | LC_ALL=C sort | while IFS= read -r f; do cat "$f"; done
  } | shasum -a 256 | cut -c1-16
}

info_plist() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>VoiceConversationHotkey</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$BUNDLE_FORMAT.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Records what you say after you double-tap the hotkey in a Claude Code tab, for local transcription.</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Finds the terminal tab running Claude Code and types your transcript into it.</string>
</dict>
</plist>
EOF
}

agent_plist() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$APP/Contents/MacOS/VoiceConversationHotkey</string><string>$DATA</string></array>
  <key>EnvironmentVariables</key>
  <dict><key>VOICE_CONVERSATION_PORT</key><string>$PORT</string></dict>
  <key>RunAtLoad</key><true/>
  <!-- Stop respawning once the plugin's data dir is gone (plugin uninstalled). -->
  <key>KeepAlive</key>
  <dict><key>PathState</key><dict><key>$DATA/daemon/speakd.py</key><true/></dict></dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>StandardOutPath</key><string>$DATA/hotkey.log</string>
  <key>StandardErrorPath</key><string>$DATA/hotkey.log</string>
</dict>
</plist>
EOF
}

build() {
  has_swiftc || {
    echo "The hotkey needs the Xcode Command Line Tools: run 'xcode-select --install', then /speak setup input again."
    exit 3
  }
  local bundle replaced=false
  WORK=$(mktemp -d)
  bundle="$WORK/$NAME.app"
  mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
  xcrun swiftc -O -o "$bundle/Contents/MacOS/VoiceConversationHotkey" "$ROOT"/helper/*.swift
  info_plist > "$bundle/Contents/Info.plist"
  source_hash > "$bundle/Contents/Resources/source-hash"
  codesign --force --sign - --identifier "$BUNDLE_ID" "$bundle" >/dev/null 2>&1
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  mkdir -p "$APP_DIR"
  if [ -d "$APP" ]; then mv "$APP" "$WORK/previous.app"; replaced=true; fi
  mv "$bundle" "$APP"
  if $replaced; then  # the old grants belong to the old build; clear them so macOS asks again
    tccutil reset All "$BUNDLE_ID" >/dev/null 2>&1 || true
  fi
  echo "built $APP"
}

take_lock
changed=false
if [ "$(cat "$APP/Contents/Resources/source-hash" 2>/dev/null)" != "$(source_hash)" ]; then
  build
  changed=true
fi
if [ "$(cat "$PLIST" 2>/dev/null)" != "$(agent_plist)" ]; then
  mkdir -p "$(dirname "$PLIST")"
  agent_plist > "$PLIST"
  plutil -lint "$PLIST" >/dev/null
  changed=true
fi
if $changed || ! launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  echo "started $LABEL"
else
  echo "hotkey helper up to date"
fi
