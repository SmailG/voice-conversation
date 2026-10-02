# Contributing

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md). Report security issues
privately, as described in [SECURITY.md](SECURITY.md). Pull requests use the template in
`.github/`; a maintainer reviews and merges them.

## Layout

| Path | Role |
|---|---|
| `hooks/hooks.json`, `hooks/tts.sh` | Stop / UserPromptSubmit hooks that forward payloads to the daemon; permission / question hooks that tell it which session shows a menu |
| `hooks/sync.sh` | SessionStart: copy new daemon code into the data dir after an update; rebuild the hotkey helper if its source changed |
| `helper/`, `scripts/build-helper.sh` | The voice-input hotkey helper (Swift app + LaunchAgent): `Gate.swift` holds the testable logic (double tap, where text may go, transcript cleanup) |
| `skills/speak/SKILL.md`, `scripts/speakctl.sh` | The `/speak` command; `skills/speak/setup-flow.md` is the guided setup (transparency note, questions) |
| `hooks/check.sh`, `scripts/voice-input-state.sh` | SessionStart warning when two-way voice input lacks a permission or its helper stopped (same state `/speak status` shows) |
| `scripts/setup.sh`, `scripts/uninstall.sh` | Install / remove the runtime, models and launchd service |
| `scripts/migrate.sh` | Takes over an install made under the old name `claude-speak` (called by setup) |
| `scripts/platform.sh` | Apple Silicon / macOS version / Rosetta checks used by setup |
| `daemon/` | `speakd.py` (HTTP + MLX worker loop), `engines.py` (load/run Kokoro and OmniVoice), `models.py` (lazy load, idle unload), `sessions.py` (open Claude Code sessions via `ps`), `guard.py` (sessions showing a menu), `localonly.py` (refuses requests not addressed to 127.0.0.1), `stt.py` (Whisper voice input), `settings.py` (the per-user setting files), `player.py` (playback process), `jobs.py` (queueing), `text.py` (cleanup, routing, chunking) |

## Rules

- **Bump the version on every change** in both `.claude-plugin/plugin.json` and `NAME, VERSION`
  in `daemon/speakd.py` (`tests/test_version.py` checks they match). `claude plugin update` does
  nothing while the version is unchanged.
- Hooks must never block or fail a session: short timeouts, always `exit 0`.
- MLX models must load in the thread that generates (GPU streams are thread-local), and playback
  must stay in the separate player process (in-process playback stutters while MLX holds the GIL).
- Nothing in the daemon may reference `${CLAUDE_PLUGIN_ROOT}`: it changes on every update. The
  daemon runs from `VOICE_CONVERSATION_HOME` (the plugin data dir).

## Tests

```bash
python3 -m unittest discover -s tests   # daemon logic + version sync (needs numpy)
bash tests/shell.test.sh                # hooks and /speak against a fake daemon (needs jq)
bash tests/helper/run.sh                # hotkey helper logic (macOS, needs swiftc)
claude plugin validate --strict .claude-plugin/plugin.json
```

Shell tests are two-sided: each behaviour has a must-happen and a must-not-happen case.
For a live check: `claude --plugin-dir .`, run `/speak setup`, and watch `speakd.log`.
