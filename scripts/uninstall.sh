#!/bin/bash
# voice-conversation uninstall: stop and unregister the speech service. Never deletes models or the
# runtime (they may be shared); prints how to remove them. The plugin's data dir is removed by
# `claude plugin uninstall voice-conversation`.
#   uninstall.sh <data_dir>

DATA="${1:-${CLAUDE_PLUGIN_DATA:-}}"
LABEL="com.voice-conversation.daemon"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
HOTKEY="com.voice-conversation.hotkey"
HOTKEY_PLIST="$HOME/Library/LaunchAgents/$HOTKEY.plist"
HOTKEY_APP="${VOICE_CONVERSATION_APP_DIR:-$HOME/Applications}/Voice Conversation Hotkey.app"

launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 && echo "Stopped the speech service." \
  || echo "Speech service was not running."
if [ -f "$PLIST" ]; then
  rm -f "$PLIST" && echo "Removed $PLIST."
fi
if [ -f "$HOTKEY_PLIST" ] || [ -d "$HOTKEY_APP" ]; then
  launchctl bootout "gui/$(id -u)/$HOTKEY" >/dev/null 2>&1
  tccutil reset All "$HOTKEY" >/dev/null 2>&1  # its privacy permissions, while the app still exists
  rm -f "$HOTKEY_PLIST"
  rm -rf "$HOTKEY_APP"
  echo "Removed the voice-input hotkey helper."
fi
# Hooks stay quiet until /speak setup runs again; setup clears this mute, but not one set by /speak off.
[ -n "$DATA" ] && printf 'uninstalled\n' > "$DATA/off" 2>/dev/null
echo "Now run: claude plugin uninstall voice-conversation   (removes the plugin and its data dir)"
echo "Optional, frees ~5 GB (~6.5 GB with voice input): 'uv tool uninstall mlx-audio', and delete these folders in ~/.cache/huggingface/hub:"
echo "  models--mlx-community--Kokoro-82M-bf16, models--prince-canuma--Kokoro-82M, models--mlx-community--OmniVoice-bfloat16,"
echo "  and for voice input models--mlx-community--whisper-large-v3-turbo, models--openai--whisper-large-v3-turbo"
