#!/bin/bash
# Backend of the /speak skill.
#   speakctl.sh "<args>" <session_id> <data_dir>
#   args: (none) = replay this session's last reply | on | off | status | limit N | speed X
#         | unload N | lang X | hotkey X | autosend on|off | setup [input] | uninstall
# The skill passes all its arguments as one string ($1); it is re-split here.
# Every line starts with "[speak]": the daemon never speaks replies with that marker, so
# Claude echoing this output can't interrupt a replay.

SESSION="${2:-}"
DATA="${3:-${CLAUDE_PLUGIN_DATA:-}}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${VOICE_CONVERSATION_PORT:-8765}"
DEFAULT_LIMIT=2000   # keep in sync with MAX_CHARS in daemon/settings.py
MAX_LIMIT=100000
SPEED_RE='^1(\.([0-2][0-9]?|30?))?$'   # 1.0 .. 1.3, at most two decimals (MIN/MAX_SPEED in settings.py)
EN_WPM=187           # English words per minute measured at speed 1
DEFAULT_UNLOAD=10    # keep in sync with DEFAULT_UNLOAD_MIN in daemon/settings.py
MAX_UNLOAD=1440
LANG_RE='^(auto|bs|hr|sr|en)$'   # LANGUAGES in daemon/settings.py
HOTKEY_RE='^(right-option|right-command|fn|off)$'   # Hotkey in helper/Gate.swift
HOTKEY_AGENT="com.voice-conversation.hotkey"
VERSION=$(jq -r '.version // "?"' "$ROOT/.claude-plugin/plugin.json" 2>/dev/null)

say() { echo "[speak] $*"; }

if [ -z "$DATA" ]; then say "No plugin data directory given; run this through /speak."; exit 0; fi
MUTE="$DATA/off"
LIMIT_FILE="$DATA/max_chars"
SPEED_FILE="$DATA/speed"
UNLOAD_FILE="$DATA/unload_minutes"
LANG_FILE="$DATA/stt_lang"
HOTKEY_FILE="$DATA/hotkey"
AUTOSEND_FILE="$DATA/autosend"

daemon_state() {
  health=$(curl -s --max-time 1 "http://127.0.0.1:$PORT/health" 2>/dev/null)
  home=$(printf '%s' "$health" | jq -r '.home // empty' 2>/dev/null)
  if [ -z "$health" ]; then
    echo "service not running (run /speak setup)"
  elif [ "$home" != "$DATA" ]; then
    echo "port $PORT is served by another voice-conversation install ($home)"
  elif [ "$(printf '%s' "$health" | jq -r .ready)" = "true" ]; then
    echo "service running"
  else
    echo "service loading models"
  fi
}

limit_state() {
  n=$(cat "$LIMIT_FILE" 2>/dev/null || echo "$DEFAULT_LIMIT")
  [ "$n" = "0" ] && echo "no length limit" || echo "limit $n chars"
}

# "1.30" -> "1.3", "1.0" -> "1" (string ops: bash has no floats, and printf %f is locale-bound)
normalize_speed() {
  local v="$1"
  [[ "$v" == *.* ]] && while [[ "$v" == *0 ]]; do v="${v%0}"; done
  printf '%s' "${v%.}"
}

speed_state() {
  local v frac s100
  v=$(cat "$SPEED_FILE" 2>/dev/null)
  [[ "$v" =~ $SPEED_RE ]] || v=1
  frac="${v#1}"; frac="${frac#.}00"; s100=$((100 + 10#${frac:0:2}))
  echo "speed ${v}x (~$((EN_WPM * s100 / 100)) wpm in English)"
}

unload_state() {
  local n
  n=$(cat "$UNLOAD_FILE" 2>/dev/null || echo "$DEFAULT_UNLOAD")
  [[ "$n" =~ ^[0-9]+$ ]] || n=$DEFAULT_UNLOAD
  if [ "$n" = "0" ]; then
    echo "Bosnian voice kept loaded while a session is open"
  else
    echo "Bosnian voice unloads after $n min idle"
  fi
}

# "Bosnian voice loaded · 2 sessions open", from /health (empty when the service doesn't report it)
memory_state() {
  curl -s --max-time 1 "http://127.0.0.1:$PORT/health" 2>/dev/null | jq -r '
    select(.models != null)
    | "Bosnian voice \(if .models.bs then "loaded" else "not loaded" end) · \(.sessions | length) session\(if (.sessions | length) == 1 then "" else "s" end) open"' 2>/dev/null
}

# "playback restarted 2 times ..." when the watchdog had to replace a wedged audio player
player_state() {
  curl -s --max-time 1 "http://127.0.0.1:$PORT/health" 2>/dev/null | jq -r '
    select((.player.restarts // 0) > 0)
    | "playback restarted \(.player.restarts) time\(if .player.restarts == 1 then "" else "s" end) since the service started (the audio device got stuck; see speakd.log)"' 2>/dev/null
}

lang_state() {
  local v
  v=$(cat "$LANG_FILE" 2>/dev/null)
  [[ "$v" =~ $LANG_RE ]] || v=auto
  echo "voice input language: $v"
}

hotkey_state() {
  local v
  v=$(tr -d '[:space:]' 2>/dev/null < "$HOTKEY_FILE")
  [[ "$v" =~ $HOTKEY_RE ]] || v=right-option
  echo "$v"
}

# autosend as status shows it: on applies only where a tab is addressable
autosend_label() {
  [ "$(autosend_state)" = on ] && echo "on (iTerm2 and Terminal.app)" || echo off
}

autosend_state() {
  [ "$(tr -d '[:space:]' 2>/dev/null < "$AUTOSEND_FILE")" = "on" ] && echo on || echo off
}

# "Voice input: double-tap right-option · autosend off · language bs · ready" (only once set up)
input_state() {
  local lang helper state
  [ -f "$DATA/models/whisper/config.json" ] || return
  lang=$(tr -d '[:space:]' 2>/dev/null < "$LANG_FILE"); [[ "$lang" =~ $LANG_RE ]] || lang=auto
  state=$(bash "$ROOT/scripts/voice-input-state.sh" "$DATA")
  case "$state" in
    "not running") helper="hotkey helper not running (run /speak setup input)" ;;
    unknown)       helper="helper state unknown (see hotkey.log in the data dir)" ;;
    "missing: "*)  helper="needs ${state#missing: } (System Settings > Privacy & Security)" ;;
    "")            helper="off" ;;
    *)             helper="$state" ;;
  esac
  echo "Voice input: double-tap $(hotkey_state) · autosend $(autosend_label) · language $lang · $helper"
}

# Last final-text reply of this session, from its transcript (works while muted and across
# daemon restarts). Skips earlier /speak echoes and subagent (sidechain) entries.
last_reply_json() {
  [[ "$SESSION" =~ ^[0-9a-fA-F-]{8,64}$ ]] || return 1
  transcript=$(ls "$HOME"/.claude/projects/*/"$SESSION".jsonl 2>/dev/null | head -1)
  [ -n "$transcript" ] || return 1
  jq -c 'select(.type == "assistant" and (.isSidechain | not))
         | .message.content[]? | select(.type == "text") | .text
         | select(startswith("[speak]") | not)' "$transcript" 2>/dev/null | tail -1
}

replay() {
  text=$(last_reply_json)
  if [ -z "$text" ] || [ "$text" = '""' ]; then say "Nothing to replay yet in this session."; return; fi
  payload=$(jq -cn --arg s "$SESSION" --argjson t "$text" '{session_id: $s, last_assistant_message: $t}')
  if curl -s --max-time 2 -o /dev/null --data-binary "$payload" "http://127.0.0.1:$PORT/speak" 2>/dev/null; then
    say "Replaying the last reply ($(printf '%s' "$text" | jq -r 'length') chars before cleanup)."
  else
    say "Could not reach the speech service — $(daemon_state)"
  fi
}

set -f  # no globbing when re-splitting the argument string
# shellcheck disable=SC2086
set -- $(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
set +f
ACTION="${1:-replay}"
VALUE="${2:-}"

case "$ACTION" in
  replay|again) replay ;;
  on)     rm -f "$MUTE"; say "Speech ON — $(limit_state) — $(daemon_state)" ;;
  off)    touch "$MUTE"
          curl -s --max-time 1 -o /dev/null -X POST "http://127.0.0.1:$PORT/stop" 2>/dev/null
          say "Speech OFF (/speak still replays on demand)" ;;
  status) [ -e "$MUTE" ] && s=OFF || s=ON
          say "voice-conversation $VERSION — speech $s — $(limit_state) — $(speed_state) — $(daemon_state)"
          mem=$(memory_state); [ -n "$mem" ] && say "$mem — $(unload_state)"
          pl=$(player_state); [ -n "$pl" ] && say "$pl"
          inp=$(input_state); [ -n "$inp" ] && say "$inp" ;;
  limit)  if [[ "$VALUE" =~ ^[0-9]+$ ]] && [ "$VALUE" -le "$MAX_LIMIT" ]; then
            printf '%s\n' "$((10#$VALUE))" > "$LIMIT_FILE"; say "Speech $(limit_state) (0 = no limit)"
          else
            say "Usage: /speak limit N  (N = 0..$MAX_LIMIT characters, 0 = no limit). Currently: $(limit_state)"
          fi ;;
  speed)  if [[ "$VALUE" =~ $SPEED_RE ]]; then
            normalize_speed "$VALUE" > "$SPEED_FILE"; say "Speech $(speed_state), from the next reply"
          else
            say "Usage: /speak speed X  (X = 1.0..1.3, e.g. 1.2). Currently: $(speed_state)"
          fi ;;
  unload) if [[ "$VALUE" =~ ^[0-9]+$ ]] && [ "$((10#$VALUE))" -le "$MAX_UNLOAD" ]; then
            printf '%s\n' "$((10#$VALUE))" > "$UNLOAD_FILE"; say "$(unload_state) (always unloads 1–2 min after the last session closes)"
          else
            say "Usage: /speak unload N  (N = minutes idle before the Bosnian voice unloads, 0..$MAX_UNLOAD; 0 = keep loaded while a session is open). Currently: $(unload_state)"
          fi ;;
  lang)   if [[ "$VALUE" =~ $LANG_RE ]]; then
            printf '%s\n' "$VALUE" > "$LANG_FILE"; say "Voice input language set: $VALUE"
          else
            say "Usage: /speak lang auto|bs|hr|sr|en  (auto lets Whisper detect it; short Bosnian clips may come back as Serbian in Cyrillic, so bs is safer). Currently: $(lang_state)"
          fi ;;
  hotkey) if [[ "$VALUE" =~ $HOTKEY_RE ]]; then
            printf '%s\n' "$VALUE" > "$HOTKEY_FILE"
            launchctl kickstart -k "gui/$(id -u)/$HOTKEY_AGENT" >/dev/null 2>&1
            say "Voice input hotkey: $VALUE$([ "$VALUE" = off ] || echo " (double-tap it where Claude Code runs)")"
            [ "$VALUE" = fn ] && say "Note: other apps that use a double Fn (Wispr Flow, macOS dictation) also react to it in apps where Claude Code runs."
          else
            say "Usage: /speak hotkey right-option|right-command|fn|off. Currently: $(hotkey_state)"
          fi ;;
  autosend) if [[ "$VALUE" =~ ^(on|off)$ ]]; then
            mkdir -p "$DATA" && printf '%s\n' "$VALUE" > "$AUTOSEND_FILE"
            if [ "$VALUE" = on ]; then say "Voice input autosend on: the transcript is sent right away in iTerm2 and Terminal.app; in other apps it is pasted for you to send"
            else say "Voice input autosend off: the transcript waits in the prompt for you to edit and press Enter"; fi
          else
            say "Usage: /speak autosend on|off. Currently: $(autosend_state)"
          fi ;;
  setup)  case "$VALUE" in
            "") say "SETUP" ;;
            input) say "SETUP input" ;;
            *) say "Usage: /speak setup  (speech)  or  /speak setup input  (local voice input, +1.5 GB)" ;;
          esac ;;
  uninstall) bash "$ROOT/scripts/uninstall.sh" "$DATA" | sed 's/^/[speak] /' ;;
  *)      say "Unknown option '$ACTION'. Use: /speak (replay) | on | off | status | limit N | speed X | unload N | lang X | hotkey X | autosend on|off | setup [input] | uninstall" ;;
esac
exit 0
