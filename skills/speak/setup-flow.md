# voice-conversation setup flow

Follow these steps in order. Show the text in the quoted blocks exactly as written (as normal
Markdown, without the `>` markers). Don't add claims of your own about what is installed.

## 1. Show what setup does

For `[speak] SETUP` show all of this; for `[speak] SETUP input` show only the
"Two-way conversation adds" part (the user is adding voice input to an existing install).

> **What `/speak setup` installs and asks for.** No audio or text leaves your Mac: the only network
> use is setup downloading the runtime (PyPI, GitHub) and the models (Hugging Face). The source is
> public: https://github.com/SmailG/voice-conversation
>
> **Voice replies** (Claude speaks its answers):
> - the `mlx-audio` runtime (a uv tool) and two voice models, ~4.5 GB, downloaded once from Hugging Face
> - a background service (`com.voice-conversation.daemon`) that listens only on 127.0.0.1
> - hooks that send each reply's text, and each prompt you type (it stops speech), to that local service
> - no macOS permission prompts
>
> **Two-way conversation adds** (you talk back by double-tapping Right Option in a Claude Code tab):
> - the Whisper speech-recognition model, ~1.5 GB
> - a small helper app compiled from source on your Mac (`~/Applications/Voice Conversation Hotkey.app`;
>   needs the Xcode Command Line Tools) and a LaunchAgent that keeps it running
> - hooks that tell the local service when Claude shows a permission prompt or a question, so
>   dictation can never answer one by accident. To see when a menu closes they send each tool
>   call's name and input; the service keeps only a hash of it and logs nothing
> - macOS will ask you to allow the helper:
>   - **Input Monitoring**: to notice the double tap. It only listens; it never blocks keys,
>     looks only at which modifier key changed, and never reads what you type.
>   - **Microphone**: used only between your double tap and the tap that stops it.
>   - **Automation of iTerm2 / Terminal**: to find the Claude Code tab and type the transcript into it.
>   - Terminal.app only, asked the first time you dictate there: **Automation of System Events**
>     and **Accessibility**, because Terminal.app can only receive text as a ⌘V paste.
>
> `/speak uninstall` removes the service, the helper and its permissions.

## 2. Ask

Use the AskUserQuestion tool. If it isn't available, ask the same questions in plain text and wait.

For `[speak] SETUP`, ask first (single choice, header "Mode"):
"How do you want to use voice-conversation?"
- "Voice replies only": "Claude speaks its replies. ~4.5 GB, no macOS permission prompts."
- "Two-way conversation": "Also dictate to Claude: double-tap Right Option, speak, tap again. +1.5 GB, a helper app, and the macOS permissions listed above."

For `[speak] SETUP input`, skip that question: the mode is two-way.

Only if the mode is two-way, ask next (single choice, header "Autosend"):
"After you dictate, should the transcript be sent right away?"
- "Off: I review it and press Enter (Recommended)": "The text lands in the prompt so you can fix a misheard word first."
- "On: send it immediately": "Hands-free; a misheard word goes to Claude as is."

## 3. Install

1. Two-way only: run `bash "<PLUGIN_ROOT>/scripts/speakctl.sh" "autosend off" "" "<DATA_DIR>"`
   (or `"autosend on"`, as chosen).
2. Run with the Bash tool and `run_in_background: true`:
   `bash "<PLUGIN_ROOT>/scripts/setup.sh" "<DATA_DIR>" MODE`, where MODE is
   `speech` for voice replies only, `both` for two-way from `[speak] SETUP`, and `input` for
   `[speak] SETUP input`.
3. Tell the user it has started and roughly how long downloads take on first run. For two-way, add
   that the macOS permission prompts appear near the end, from "Voice Conversation Hotkey".
4. When it finishes, report its last lines: success, or the error and the fix it suggests. Only
   when it succeeded and the choice was two-way, end with: "Double-tap Right Option in a Claude Code tab to dictate. Change it later
   with /speak hotkey, /speak autosend and /speak lang."

Do nothing else.
