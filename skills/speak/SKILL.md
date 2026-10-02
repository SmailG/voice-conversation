---
name: speak
description: Replay the last reply aloud, turn spoken replies on or off, set the length limit, speaking speed or when the Bosnian voice unloads, set up and configure local voice input (hotkey, language, autosend), show status, or set up / uninstall the local speech service
argument-hint: "[on|off|status|limit N|speed X|unload N|lang X|hotkey X|autosend on|off|setup [input]|uninstall]  (no argument = replay last reply)"
disable-model-invocation: true
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/speakctl.sh" *) Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" *) Read(${CLAUDE_PLUGIN_ROOT}/skills/speak/setup-flow.md) AskUserQuestion
---

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/speakctl.sh" "$ARGUMENTS" "${CLAUDE_SESSION_ID}" "${CLAUDE_PLUGIN_DATA}"`

If the line above is exactly `[speak] SETUP` or `[speak] SETUP input`: read
`${CLAUDE_PLUGIN_ROOT}/skills/speak/setup-flow.md` and follow it. In it, `<PLUGIN_ROOT>` means
`${CLAUDE_PLUGIN_ROOT}` and `<DATA_DIR>` means `${CLAUDE_PLUGIN_DATA}`.

Otherwise reply with exactly the line(s) above and nothing else. Do not call any tools.
