#!/bin/bash
# Two-sided tests for hooks/tts.sh and scripts/speakctl.sh against a fake daemon.
# Every behaviour has a case that must happen AND a case that must not, so a broken
# harness (e.g. the fake daemon never receiving anything) fails instead of passing vacuously.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TTS="$ROOT/hooks/tts.sh"; CTL="$ROOT/scripts/speakctl.sh"; SYNC="$ROOT/hooks/sync.sh"
for f in "$TTS" "$CTL" "$SYNC"; do [ -f "$f" ] || { echo "FATAL: missing $f"; exit 2; }; done
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "FATAL: need jq and python3"; exit 2; }

PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1 (expected '$2', got '$3')"; fi; }

TMP=$(mktemp -d); DATA="$TMP/data"; mkdir -p "$DATA/daemon"  # daemon/: set up, so the hooks post
PORT=$((20000 + RANDOM % 20000)); export VOICE_CONVERSATION_PORT=$PORT
LOG="$TMP/requests.log"

# Fake daemon: records "<path> <body>" per request; /health reports home=$DATA.
python3 - "$PORT" "$LOG" "$DATA" <<'PY' &
import http.server, json, sys
port, log, home = int(sys.argv[1]), sys.argv[2], sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0) or 0)).decode()
        open(log, "a").write(f"{self.path} {body}\n"); self.send_response(204); self.end_headers()
    def do_GET(self):
        b = json.dumps({"name": "voice-conversation", "version": "t", "home": home, "ready": True,
                        "models": {"en": True, "bs": False}, "sessions": ["ttys001", "ttys002"]}).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
PY
FAKE=$!
trap 'kill $FAKE 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/health" && break; sleep 0.1; done

requests() { grep -c '^/' "$LOG" 2>/dev/null || true; }  # count requests, not lines (bodies may end in \n)
: > "$LOG"

# --- tts.sh: forwards in interactive sessions ...
echo '{"session_id":"s1","last_assistant_message":"hi"}' | CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_DATA=$DATA bash "$TTS" speak
check "speak forwarded (cli)" "/speak" "$(grep -m1 -o '^/[a-z]*' "$LOG")"
check "tty param is a terminal name or empty" "1" "$(grep -cE '^/speak\?tty=(ttys[0-9]+)? ' "$LOG")"
: > "$LOG"; echo '{"session_id":"s1","prompt":"x"}' | CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_DATA=$DATA bash "$TTS" stop
check "stop forwards payload with session" "s1" "$(grep -m1 '^/stop?' "$LOG" | cut -d' ' -f2- | jq -r .session_id)"
: > "$LOG"; echo '{"hook_event_name":"PermissionRequest","tool_name":"Bash"}' | CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_DATA=$DATA bash "$TTS" guard
check "no voice input: guard sends nothing" "0" "$(requests)"
mkdir -p "$DATA/models/whisper"; touch "$DATA/models/whisper/config.json"  # voice input set up
: > "$LOG"; echo '{"hook_event_name":"PermissionRequest","tool_name":"Bash"}' | CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_DATA=$DATA bash "$TTS" guard
check "guard forwards the hook event" "PermissionRequest" "$(grep -m1 '^/guard?' "$LOG" | cut -d' ' -f2- | jq -r .hook_event_name)"
: > "$LOG"; echo '{"hook_event_name":"PostToolUse","tool_name":"Read","tool_input":{"file_path":"/x"},"tool_response":"BIG"}' \
  | CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_DATA=$DATA bash "$TTS" guard
check "guard sends the call, not its output" '{"hook_event_name":"PostToolUse","tool_name":"Read","tool_input":{"file_path":"/x"}}' \
  "$(grep -m1 '^/guard?' "$LOG" | cut -d' ' -f2-)"
if [ "$(uname)" = Darwin ]; then  # a real terminal: the tty of the process that ran the hook
  : > "$LOG"; script -q /dev/null bash -c "echo '{}' | CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_DATA=$DATA bash '$TTS' guard" </dev/null >/dev/null
  check "guard reports the session's tty" "1" "$(grep -cE '^/guard\?tty=ttys[0-9]+ ' "$LOG")"
fi
# ... stays silent for headless runs, and when muted only closes the session's menus
: > "$LOG"
echo '{"last_assistant_message":"hi"}' | CLAUDE_CODE_ENTRYPOINT=sdk-cli CLAUDE_PLUGIN_DATA=$DATA bash "$TTS" speak
echo '{"prompt":"x"}' | CLAUDE_CODE_ENTRYPOINT=sdk-py CLAUDE_PLUGIN_DATA=$DATA bash "$TTS" stop
echo '{}' | CLAUDE_CODE_ENTRYPOINT=sdk-py CLAUDE_PLUGIN_DATA=$DATA bash "$TTS" guard
check "headless sends nothing" "0" "$(requests)"
FRESH="$TMP/fresh"; mkdir -p "$FRESH"  # installed, /speak setup not run yet
echo '{"last_assistant_message":"hi"}' | CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_DATA=$FRESH bash "$TTS" speak
echo '{"prompt":"x"}' | CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_DATA=$FRESH bash "$TTS" stop
check "not set up: sends nothing" "0" "$(requests)"
touch "$DATA/off"; echo '{"hook_event_name":"Stop","last_assistant_message":"hi"}' | CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_DATA=$DATA bash "$TTS" speak
check "muted: no speech, only the guard" "/guard" "$(grep -o '^/[a-z]*' "$LOG" | tr '\n' ' ' | sed 's/ $//')"
: > "$LOG"; rm -f "$DATA/models/whisper/config.json"
echo '{"hook_event_name":"Stop"}' | CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_DATA=$DATA bash "$TTS" speak
check "muted without voice input: nothing" "0" "$(requests)"; rm -f "$DATA/off"

# --- tts.sh with the daemon down: fast, silent, exit 0
start=$(python3 -c 'import time; print(time.time())')
out=$(echo '{}' | CLAUDE_CODE_ENTRYPOINT=cli VOICE_CONVERSATION_PORT=1 CLAUDE_PLUGIN_DATA=$DATA bash "$TTS" speak 2>&1); rc=$?
fast=$(python3 -c "import time; print(time.time() - $start < 1.5)")
check "daemon down: exit 0" "0" "$rc"; check "daemon down: no output" "" "$out"; check "daemon down: fast" "True" "$fast"

# --- speakctl: valid options change state, invalid ones don't
# speakctl talks to launchd about the hotkey helper: give it a fake launchctl that logs its calls and
# reports the agent loaded only while $TMP/agent_up exists.
CTLBIN="$TMP/ctlbin"; mkdir -p "$CTLBIN"
printf '#!/bin/sh\necho "$*" >> "%s/launchctl.log"\n[ "$1" != print ] || [ -e "%s/agent_up" ]\n' "$TMP" "$TMP" > "$CTLBIN/launchctl"
chmod +x "$CTLBIN/launchctl"
ctl() { PATH="$CTLBIN:$PATH" bash "$CTL" "$1" "${2:-}" "$DATA"; }
check "off mutes" "yes" "$(ctl off >/dev/null; [ -e "$DATA/off" ] && echo yes || echo no)"
check "on unmutes" "no" "$(ctl on >/dev/null; [ -e "$DATA/off" ] && echo yes || echo no)"
check "limit 3000" "3000" "$(ctl 'limit 3000' >/dev/null; cat "$DATA/max_chars")"
check "LIMIT 0 (case)" "0" "$(ctl 'LIMIT 0' >/dev/null; cat "$DATA/max_chars")"
check "limit 0100 (leading zero)" "100" "$(ctl 'limit 0100' >/dev/null; cat "$DATA/max_chars")"
for bad in "limit" "limit abc" "limit 999999" "limit 5; touch $TMP/pwned"; do
  ctl "$bad" >/dev/null
  check "rejects '$bad'" "100" "$(cat "$DATA/max_chars")"
done
check "no injection" "no" "$([ -e "$TMP/pwned" ] && echo yes || echo no)"
for good in "1:1" "1.0:1" "1.25:1.25" "1.3:1.3" "1.30:1.3"; do
  ctl "speed ${good%%:*}" >/dev/null
  check "speed accepts ${good%%:*}" "${good##*:}" "$(cat "$DATA/speed")"
done
for bad in "speed" "speed 0.9" "speed 1.31" "speed 1.4" "speed 1.5" "speed 2" "speed .5" "speed 1." "speed abc" "speed 1.2; touch $TMP/pwned2"; do
  ctl "$bad" >/dev/null
  check "rejects '$bad'" "1.3" "$(cat "$DATA/speed")"
done
check "no injection via speed" "no" "$([ -e "$TMP/pwned2" ] && echo yes || echo no)"
check "status shows speed" "1" "$(ctl status | grep -c 'speed 1.3x (~243 wpm in English)')"
echo garbage > "$DATA/speed"
check "corrupt speed file reads as 1x" "1" "$(ctl status | grep -c 'speed 1x')"
for good in "0:0" "10:10" "1440:1440" "007:7"; do
  ctl "unload ${good%%:*}" >/dev/null
  check "unload accepts ${good%%:*}" "${good##*:}" "$(cat "$DATA/unload_minutes")"
done
for bad in "unload" "unload -1" "unload 1441" "unload 2.5" "unload abc" "unload 5; touch $TMP/pwned3"; do
  ctl "$bad" >/dev/null
  check "rejects '$bad'" "7" "$(cat "$DATA/unload_minutes")"
done
check "no injection via unload" "no" "$([ -e "$TMP/pwned3" ] && echo yes || echo no)"
check "status shows memory state" "1" "$(ctl status | grep -c 'Bosnian voice not loaded · 2 sessions open — Bosnian voice unloads after 7 min idle')"
ctl "unload 0" >/dev/null
check "status shows keep-loaded" "1" "$(ctl status | grep -c 'kept loaded while a session is open')"
for good in auto bs hr sr en; do
  ctl "lang $good" >/dev/null
  check "lang accepts $good" "$good" "$(cat "$DATA/stt_lang")"
done
for bad in "lang" "lang de" "lang BSX" "lang en; touch $TMP/pwned4"; do
  ctl "$bad" >/dev/null
  check "rejects '$bad'" "en" "$(cat "$DATA/stt_lang")"
done
check "no injection via lang" "no" "$([ -e "$TMP/pwned4" ] && echo yes || echo no)"
for good in right-command fn off right-option; do
  ctl "hotkey $good" >/dev/null
  check "hotkey accepts $good" "$good" "$(cat "$DATA/hotkey")"
done
check "hotkey change restarts the helper" "4" "$(grep -c "kickstart -k gui/$(id -u)/com.voice-conversation.hotkey" "$TMP/launchctl.log")"
for bad in "hotkey" "hotkey left-option" "hotkey caps" "hotkey fn; touch $TMP/pwned5"; do
  ctl "$bad" >/dev/null
  check "rejects '$bad'" "right-option" "$(cat "$DATA/hotkey")"
done
check "no injection via hotkey" "no" "$([ -e "$TMP/pwned5" ] && echo yes || echo no)"
check "fn warns about other double-Fn apps" "1" "$(ctl 'hotkey fn' | grep -c 'Wispr Flow')"
check "right option gives no Fn warning" "0" "$(ctl 'hotkey right-option' | grep -c 'Wispr Flow')"
ctl "autosend on" >/dev/null; check "autosend on" "on" "$(cat "$DATA/autosend")"
check "autosend before setup made the data dir" "on" "$(PATH="$CTLBIN:$PATH" bash "$CTL" "autosend on" "" "$TMP/new-data" >/dev/null; cat "$TMP/new-data/autosend" 2>/dev/null)"
for bad in "autosend" "autosend yes" "autosend off; touch $TMP/pwned6"; do
  ctl "$bad" >/dev/null
  check "rejects '$bad'" "on" "$(cat "$DATA/autosend")"
done
check "no injection via autosend" "no" "$([ -e "$TMP/pwned6" ] && echo yes || echo no)"
check "status: no voice-input line before setup input" "0" "$(ctl status | grep -c 'Voice input')"
mkdir -p "$DATA/models/whisper"; touch "$DATA/models/whisper/config.json"
check "status: helper not running" "1" "$(ctl status | grep -c 'Voice input: double-tap right-option · autosend on · language en · hotkey helper not running')"
touch "$TMP/agent_up"
check "status: no status file is not 'ready'" "1" "$(ctl status | grep -c 'helper state unknown')"
echo '{"input_monitoring":true,"microphone":"not asked"}' > "$DATA/hotkey_status.json"
check "status: missing permission named" "1" "$(ctl status | grep -c 'needs Microphone (System Settings')"
echo '{"input_monitoring":true,"microphone":"granted"}' > "$DATA/hotkey_status.json"
check "status: helper ready" "1" "$(ctl status | grep -c 'language en · ready$')"
mkdir "$TMP/saved"; mv "$DATA/hotkey" "$DATA/autosend" "$DATA/stt_lang" "$TMP/saved/" 2>/dev/null
out=$(ctl status 2>&1)  # settings never set: defaults, and no error text in /speak's output
check "status: unset settings read as defaults" "1" "$(printf '%s' "$out" | grep -c 'double-tap right-option · autosend off · language auto')"
check "status: unset settings print no error" "0" "$(printf '%s' "$out" | grep -c 'No such file')"
mv "$TMP/saved/"* "$DATA/"
# --- check.sh (SessionStart): warns only when voice input is set up and can't work
chk() { PATH="$CTLBIN:$PATH" CLAUDE_CODE_ENTRYPOINT="${1:-cli}" TERM_PROGRAM="${2:-iTerm.app}" CLAUDE_PLUGIN_DATA="$DATA" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$ROOT/hooks/check.sh"; }
check "check: all granted is silent" "" "$(chk)"
echo '{"input_monitoring":false,"microphone":"granted","automation_denied":["iTerm2"]}' > "$DATA/hotkey_status.json"
check "check: names each missing permission" "voice-conversation voice input can't work yet. Voice Conversation Hotkey still needs: Input Monitoring, Automation of iTerm2. Allow it in System Settings > Privacy & Security, in the section of that name." "$(chk | jq -r .systemMessage)"
check "check: headless runs stay silent" "" "$(chk sdk-cli)"
check "status: names a refused terminal" "1" "$(ctl status | grep -c 'needs Input Monitoring, Automation of iTerm2')"
ctl "hotkey off" >/dev/null; check "check: hotkey off is silent" "" "$(chk)"; ctl "hotkey right-option" >/dev/null
echo '{"input_monitoring":true,"microphone":"granted","automation_denied":["Terminal"]}' > "$DATA/hotkey_status.json"
check "check: a terminal this session doesn't run in is not a problem" "" "$(chk cli iTerm.app)"
check "check: the session's own terminal is named" "1" "$(chk cli Apple_Terminal | jq -r .systemMessage | grep -c 'needs: Automation of Terminal\.')"
check "check: an unsupported terminal has no Automation to ask for" "" "$(chk cli ghostty)"
mkdir "$DATA/.hotkey-build.lock"
check "check: silent while an update rebuilds the helper" "" "$(chk cli Apple_Terminal)"
rmdir "$DATA/.hotkey-build.lock"
echo '{"input_monitoring":false,"microphone":"granted","automation_denied":["iTerm2"]}' > "$DATA/hotkey_status.json"
rm -f "$TMP/agent_up"
check "check: a stopped helper is reported" "1" "$(chk | jq -r .systemMessage | grep -c "hotkey helper isn't running")"
mv "$DATA/models/whisper/config.json" "$TMP/whisper-config"
check "check: no voice input is silent" "" "$(chk)"
mv "$TMP/whisper-config" "$DATA/models/whisper/config.json"
mv "$DATA/hotkey" "$TMP/hotkey-saved" 2>/dev/null; touch "$TMP/agent_up"
check "check: an unset hotkey prints no error" "0" "$(chk 2>&1 | grep -c 'No such file')"
mv "$TMP/hotkey-saved" "$DATA/hotkey" 2>/dev/null
check "setup asks for speech setup" "[speak] SETUP" "$(ctl setup)"
check "the skill's Read rule is an absolute path" "1" "$(grep -cF 'Read(/${CLAUDE_PLUGIN_ROOT}/' "$ROOT/skills/speak/SKILL.md")"
if [ "$(uname)" = Darwin ]; then  # voice input without a Swift compiler: refused before any download
  NOSW="$TMP/noswift"; mkdir -p "$NOSW"
  printf '#!/bin/sh\nexit 2\n' > "$NOSW/xcode-select"
  printf '#!/bin/sh\necho "$*" >> "%s/uv.log"\n' "$TMP" > "$NOSW/uv"; chmod +x "$NOSW"/*
  out=$(HOME="$TMP/swhome" PATH="$NOSW:$PATH" bash "$ROOT/scripts/setup.sh" "$TMP/sw-data" both 2>&1); rc=$?
  check "setup both without a compiler fails" "1" "$rc"
  check "setup both without a compiler says how to get one" "1" "$(printf '%s' "$out" | grep -c 'xcode-select --install')"
  check "setup both without a compiler downloads nothing" "no" "$([ -e "$TMP/uv.log" ] && echo yes || echo no)"
  HOME="$TMP/swhome" PATH="$NOSW:$PATH" bash "$ROOT/scripts/setup.sh" "$TMP/sw-data" speech >/dev/null 2>&1  # stops at the stub runtime
  check "speech-only setup doesn't need a compiler" "yes" "$([ -e "$TMP/uv.log" ] && echo yes || echo no)"
fi
check "setup flow file exists" "1" "$([ -f "$ROOT/skills/speak/setup-flow.md" ] && echo 1)"
check "setup flow names every setup.sh mode" "3" "$(grep -oE '`(speech|both|input)`' "$ROOT/skills/speak/setup-flow.md" | sort -u | wc -l | tr -d ' ')"
check "setup.sh has a case for every mode the flow names" "3" "$(grep -cE '^  (speech|input|both)\)' "$ROOT/scripts/setup.sh")"
check "setup takes over an old install in every speech mode" "2" "$(grep -cE '^    migrate_old_install$' "$ROOT/scripts/setup.sh")"
check "setup input asks for input setup" "[speak] SETUP input" "$(ctl 'setup input')"
check "setup rejects other targets" "0" "$(ctl 'setup bogus' | grep -c '^\[speak\] SETUP')"
check "status names plugin" "1" "$(ctl status | grep -c '^\[speak\] voice-conversation ')"
check "status sees own daemon" "1" "$(ctl status | grep -c 'service running')"
check "unknown option" "1" "$(ctl bogus | grep -c 'Unknown option')"
check "every line marked" "0" "$({ ctl status; ctl bogus; ctl 'limit x'; } 2>&1 | grep -vc '^\[speak\] ')"

# --- replay: reads the session transcript, skips /speak echoes; nothing without a transcript
SID="0000aaaa-1111-2222-3333-444455556666"; PROJ="$HOME/.claude/projects/voice-conversation-test-$$"
mkdir -p "$PROJ"; trap 'kill $FAKE 2>/dev/null; rm -rf "$TMP" "$PROJ"' EXIT
{ echo '{"type":"assistant","message":{"content":[{"type":"text","text":"The real reply."}]}}'
  echo '{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"subagent"}]}}'
  echo '{"type":"assistant","message":{"content":[{"type":"text","text":"[speak] Speech ON"}]}}'; } > "$PROJ/$SID.jsonl"
: > "$LOG"; ctl "" "$SID" >/dev/null
check "replay sends last real reply" "The real reply." "$(cut -d' ' -f2- "$LOG" | jq -r .last_assistant_message)"
: > "$LOG"
check "fresh session: nothing to replay" "1" "$(ctl "" "9999bbbb-0000-0000-0000-000000000000" | grep -c 'Nothing to replay')"
check "fresh session: nothing sent" "0" "$(requests)"
check "bad session id rejected" "1" "$(ctl "" '../../etc' | grep -c 'Nothing to replay')"

# --- platform.sh: stubbed uname / sysctl / sw_vers, so every case runs on any OS
STUBS="$TMP/stubs"; mkdir -p "$STUBS"
printf '#!/bin/sh\n[ "$1" = "-s" ] && echo "$FAKE_OS" || echo "$FAKE_ARCH"\n' > "$STUBS/uname"
printf '#!/bin/sh\ncase "$2" in hw.optional.arm64) echo "$FAKE_ARM64";; sysctl.proc_translated) echo "$FAKE_TRANSLATED";; esac\n' > "$STUBS/sysctl"
printf '#!/bin/sh\necho "$FAKE_MACOS"\n' > "$STUBS/sw_vers"
chmod +x "$STUBS"/*
on() {  # on <os> <uname -m> <hw.optional.arm64> <proc_translated> <macOS> <shell code>
  FAKE_OS=$1 FAKE_ARCH=$2 FAKE_ARM64=$3 FAKE_TRANSLATED=$4 FAKE_MACOS=$5 PATH="$STUBS:$PATH" \
    bash -c "source '$ROOT/scripts/platform.sh'; $6"
}
check "platform: Apple Silicon, macOS 14.0" "" "$(on Darwin arm64 1 0 14.0 platform_problem)"
check "platform: Apple Silicon, macOS 26.5" "" "$(on Darwin arm64 1 0 26.5 platform_problem)"
check "platform: Rosetta shell is still Apple Silicon" "" "$(on Darwin x86_64 1 1 26.5 platform_problem)"
check "platform: Rosetta detected" "yes" "$(on Darwin x86_64 1 1 26.5 'is_translated && echo yes || echo no')"
check "platform: native is not translated" "no" "$(on Darwin arm64 1 0 26.5 'is_translated && echo yes || echo no')"
check "platform: macOS 13 refused" "1" "$(on Darwin arm64 1 0 13.6.1 platform_problem | grep -c 'macOS 14 Sonoma or newer; this is macOS 13.6.1')"
check "platform: unknown macOS refused" "1" "$(on Darwin arm64 1 0 '' platform_problem | grep -c 'this is macOS unknown')"
check "platform: Intel Mac refused" "1" "$(on Darwin x86_64 0 0 15.7 platform_problem | grep -c 'MLX does not run on Intel')"
check "platform: Intel Mac without the arm64 key refused" "1" "$(on Darwin x86_64 '' '' 15.7 platform_problem | grep -c 'Intel')"
check "platform: Linux refused" "1" "$(on Linux x86_64 '' '' '' platform_problem | grep -c 'this is Linux')"

# --- sync.sh: restarts the service only when daemon sources changed, and only for its own install
if [ -x /usr/libexec/PlistBuddy ]; then
  SH="$TMP/synchome"; SD="$TMP/syncdata"; BIN="$TMP/bin"; KICKS="$TMP/kicks.log"
  mkdir -p "$SH/Library/LaunchAgents" "$SD/daemon/__pycache__" "$BIN"
  printf '#!/bin/sh\necho "$*" >> "%s"\n' "$KICKS" > "$BIN/launchctl"; chmod +x "$BIN/launchctl"
  plist() { /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:VOICE_CONVERSATION_HOME string $1" \
    "$SH/Library/LaunchAgents/com.voice-conversation.daemon.plist" >/dev/null; }
  sync_run() { HOME="$SH" PATH="$BIN:$PATH" CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PLUGIN_DATA="$SD" bash "$SYNC"; }
  kicks() { cat "$KICKS" 2>/dev/null | grep -c kickstart; }  # prints 0 before the first call
  plist "$SD"; cp "$ROOT"/daemon/*.py "$SD/daemon/"; echo junk > "$SD/daemon/__pycache__/x.pyc"
  sync_run; check "sync: bytecode alone is not a change" "0" "$(kicks)"
  echo "# old" >> "$SD/daemon/text.py"; sync_run
  check "sync: changed source restarts once" "1" "$(kicks)"
  check "sync: changed source is copied" "0" "$(cmp -s "$ROOT/daemon/text.py" "$SD/daemon/text.py"; echo $?)"
  MINE=$(jq -r .version "$ROOT/.claude-plugin/plugin.json")
  check "sync: records the version that synced" "$MINE" "$(cat "$SD/synced_version" 2>/dev/null)"
  # Another version's install, as a session started before or after an update holds it.
  mkroot() {  # mkroot <version>: a copy of this plugin claiming <version>, with a distinct daemon
    local r="$TMP/root-$1"; rm -rf "$r"; mkdir -p "$r"
    cp -R "$ROOT/hooks" "$ROOT/scripts" "$ROOT/daemon" "$ROOT/helper" "$ROOT/.claude-plugin" "$r/"
    jq --arg v "$1" '.version = $v' "$ROOT/.claude-plugin/plugin.json" > "$r/.claude-plugin/plugin.json"
    echo "# from $1" >> "$r/daemon/text.py"; echo "$r"
  }
  sync_from() { HOME="$SH" PATH="$BIN:$PATH" CLAUDE_PLUGIN_ROOT="$1" CLAUDE_PLUGIN_DATA="$SD" bash "$1/hooks/sync.sh"; }
  K=$(kicks); sync_from "$(mkroot 0.0.1)"
  check "sync: an older version does not restart the service" "$K" "$(kicks)"
  check "sync: an older version does not copy its daemon" "0" "$(grep -c 'from 0.0.1' "$SD/daemon/text.py")"
  echo 0.9.0 > "$SD/synced_version"; sync_from "$(mkroot 0.10.0)"
  check "sync: a newer version (0.10.0 after 0.9.0) restarts the service" "$((K + 1))" "$(kicks)"
  check "sync: a newer version records itself" "0.10.0" "$(cat "$SD/synced_version")"
  sync_from "$(mkroot 0.9.0)"
  check "sync: 0.9.0 after 0.10.0 is left alone" "$((K + 1))" "$(kicks)"
  echo "not-a-version" > "$SD/synced_version"; sync_from "$(mkroot 0.0.2)"
  check "sync: an unreadable record does not block syncing" "$((K + 2))" "$(kicks)"
  rm -f "$SD/synced_version"; sync_run
  boots() { cat "$KICKS" 2>/dev/null | grep -c bootstrap; }
  if xcode-select -p >/dev/null 2>&1 && xcrun --find swiftc >/dev/null 2>&1; then  # the hotkey helper
    out=$(HOME="$TMP/buildhome" PATH="$BIN:$PATH" bash "$ROOT/scripts/build-helper.sh" "$TMP/builddata" 2>&1); rc=$?
    check "build-helper: a good build exits 0" "0" "$rc"
    check "build-helper: reports the build" "1" "$(printf '%s' "$out" | grep -c '^built ')"
    check "build-helper: leaves no lock" "0" "$(ls -a "$TMP/builddata" | grep -c lock)"
    mkdir "$TMP/builddata/.hotkey-build.lock"
    check "build-helper: a running build is left alone" "1" \
      "$(HOME="$TMP/buildhome" PATH="$BIN:$PATH" bash "$ROOT/scripts/build-helper.sh" "$TMP/builddata" | grep -c 'another hotkey helper build')"
    rmdir "$TMP/builddata/.hotkey-build.lock"; KB=$(boots)
    HP="$SH/Library/LaunchAgents/com.voice-conversation.hotkey.plist"
    /usr/libexec/PlistBuddy -c "Add :ProgramArguments array" -c "Add :ProgramArguments:0 string x" \
      -c "Add :ProgramArguments:1 string $SD" "$HP" >/dev/null
    sync_run
    check "sync: hotkey helper built" "1" "$(ls "$SH/Applications/Voice Conversation Hotkey.app/Contents/MacOS" 2>/dev/null | grep -c VoiceConversationHotkey)"
    check "sync: hotkey helper started" "$((KB + 1))" "$(boots)"
    sync_run; check "sync: unchanged helper is not rebuilt or restarted" "$((KB + 1))" "$(boots)"
    LC_ALL=C sync_run; LC_ALL=en_US.UTF-8 sync_run
    check "sync: the caller's locale does not trigger a rebuild" "$((KB + 1))" "$(boots)"
    OLD=$(mkroot 0.0.1); echo "// older helper" >> "$OLD/helper/main.swift"; sync_from "$OLD"
    check "sync: an older version does not rebuild the hotkey helper" "$((KB + 1))" "$(boots)"
    rm -f "$HP"
  else
    echo "SKIP: 9 hotkey helper checks (no Swift compiler)"
  fi
  rm "$SH/Library/LaunchAgents/com.voice-conversation.daemon.plist"; plist "/some/other/install"
  K=$(kicks); echo "# old" >> "$SD/daemon/text.py"; sync_run
  check "sync: another install's service is left alone" "$K" "$(kicks)"
else
  echo "SKIP: 13 sync.sh checks (need macOS PlistBuddy)"
fi

echo "shell tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
