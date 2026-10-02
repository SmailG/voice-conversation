# voice-conversation

Speaks Claude Code replies aloud with local, offline text-to-speech on Apple Silicon.
English uses [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M); Bosnian, Croatian and
Serbian use [OmniVoice](https://github.com/k2-fsa/OmniVoice) with a cloned voice. Both run through
[mlx-audio](https://github.com/Blaizzy/mlx-audio). Optional voice input works the other way:
double-tap Right Option in a Claude Code tab, speak, and a local
[Whisper](https://huggingface.co/openai/whisper-large-v3-turbo) transcript lands in the prompt.
Nothing is sent to a cloud service.

## Install

```bash
claude plugin marketplace add SmailG/voice-conversation
claude plugin install voice-conversation@voice-conversation
```

Then, in a Claude Code session:

```
/speak setup
```

Setup first shows what it installs and which macOS permissions each choice needs (the same list
as [below](#what-setup-installs-and-asks-for)), then asks two things:

1. **Mode**: voice replies only, or two-way conversation (you also dictate to Claude).
2. **Autosend** (two-way only): send a transcript right away, or leave it in the prompt to review
   (the default).

It then installs the `mlx-audio` runtime as a [uv](https://docs.astral.sh/uv/) tool, downloads the
voice models (about 4.5 GB, once; +1.5 GB for two-way), and registers a small launchd service that
keeps them loaded. Re-running it is safe. When it finishes you hear "Speech is ready."

### What setup installs and asks for

No audio or text leaves your Mac; the only network use is downloading the models.

| | Voice replies only | Two-way conversation adds |
|---|---|---|
| Installs | `mlx-audio` (uv tool), Kokoro + OmniVoice models, launchd service on 127.0.0.1 | Whisper model, the helper app `~/Applications/Voice Conversation Hotkey.app` (compiled on your Mac) and its LaunchAgent |
| Hooks send | each reply's text, to the local service | also which permission prompt or question is open, so dictation never answers one |
| macOS asks for | nothing | Input Monitoring, Microphone, Automation of your terminal; for Terminal.app also System Events and Accessibility ([why](#voice-input)) |

If two-way is set up and a permission is missing or the helper stopped, Claude Code shows a warning
when a session starts, and the helper says which permission it lacks when you double-tap.

**Requirements:** an Apple Silicon Mac (M1 or later) with macOS 14 Sonoma or newer, `uv`, `jq`,
`curl`, ~5 GB disk, ~1 GB free memory (~3 GB while the Bosnian voice is loaded). Voice input
adds ~1.5 GB disk and needs the Xcode Command Line Tools. Intel Macs are not supported: the speech models run on MLX,
which needs Apple Silicon. Setup also works from a terminal running under Rosetta.

### Coming from claude-speak

This plugin was called `claude-speak` up to 0.4.0; Claude Code now reserves plugin names that start
with `claude-`. To move over, keeping your settings and the downloaded models:

```bash
claude plugin marketplace add SmailG/voice-conversation
claude plugin install voice-conversation@voice-conversation
```

Start a new session and run `/voice-conversation:speak setup` (plain `/speak` is ambiguous while
both plugins are installed). Setup stops the old service and hotkey helper, removes the old helper
app, copies your settings, and starts everything under the new name. With voice input, macOS asks
again for the helper's permissions, because it is a new app. Then remove the old plugin:

```bash
claude plugin uninstall claude-speak@claude-speak
claude plugin marketplace remove claude-speak
```

## Use

Replies are spoken automatically once setup is done.

| Command | What it does |
|---|---|
| `/speak` | Replay the last reply of this session (works while muted) |
| `/speak off` / `/speak on` | Mute / unmute spoken replies (`off` also stops current speech) |
| `/speak status` | Version, mute state, length limit, speed, service state |
| `/speak limit N` | Speak at most N characters per reply (default 2000; `0` = no limit) |
| `/speak speed X` | Speaking speed, `1.0`–`1.3`, e.g. `1.25` (default 1.0 ≈ 187 words per minute in English) |
| `/speak unload N` | Minutes idle before the Bosnian voice unloads (default 10; `0` = keep it loaded while a session is open) |
| `/speak setup input` | Add [voice input](#voice-input) to a voice-only install (asks about autosend first) |
| `/speak lang X` | Voice input language: `auto` (default), `bs`, `hr`, `sr`, `en`. `auto` may label Bosnian as Croatian or Serbian, and short clips can come back in Cyrillic, so `bs` is safer |
| `/speak hotkey X` | Voice input key, double-tapped: `right-option` (default), `right-command`, `fn`, `off` |
| `/speak autosend on\|off` | Send the transcript right away (`on`), or leave it in the prompt to edit (`off`, default) |
| `/speak setup` | Guided install or repair: shows what it installs, asks voice-only or two-way |
| `/speak uninstall` | Stop and remove the speech service |

The plugin skill is `/voice-conversation:speak`; plain `/speak` works as long as no other command uses that name.

## How it behaves

- **Typing stops speech** — but only the speech of the session you type in.
- **Several sessions** — a reply from another session waits until the current one finishes;
  a new reply from the same session replaces its own older one. A reply that waits longer than
  one maximum-length reply takes to speak (at least 3 minutes; never with `limit 0`) is
  dropped, so busy sessions can't stack speech. That covers one long reply ahead of yours,
  not two.
- **Headless runs** (`claude -p`, Agent SDK, background summarizers) are never spoken.
- **What is read**: code blocks, tables, URLs and file paths are skipped; long replies are cut
  at a sentence end at the length limit.
- **Language** is decided per reply: Bosnian/Croatian/Serbian text goes to OmniVoice, everything
  else to Kokoro (`af_heart`). Typical time to first audio: English ~0.3 s, Bosnian ~3 s, or
  ~9 s when the Bosnian voice has to load first.
- **Memory**: the English voice stays loaded (~0.8 GB). The Bosnian voice (~2 GB more) loads on its
  first reply and unloads after `/speak unload` minutes without use, and always 1–2 minutes after
  the last Claude Code session closes. Sessions are found by scanning running `claude` processes
  that have a terminal, so a crashed or killed session counts as closed too.
- **Speed** applies to the next reply. Both engines speed up natively, so pitch stays the same.
  The range stops at 1.3× (~243 words per minute in English): above that, Bosnian synthesis
  falls behind playback (gaps between sentences), and at 1.5× Whisper transcribes 6–30% of its
  words wrongly.

## Voice input

`/speak setup input` downloads Whisper large-v3-turbo and builds a small helper app,
`~/Applications/Voice Conversation Hotkey.app`, from source on your Mac (it needs the Xcode Command Line
Tools: `xcode-select --install`). macOS then asks you to allow it:

| Permission | Why |
|---|---|
| Input Monitoring | To see the double tap. The helper only listens (it never blocks or changes a key). It notes that some other key was pressed, which cancels a tap in progress, but never reads which key or what you type |
| Microphone | To record while you dictate |
| Automation (iTerm2 / Terminal) | To find the tab running Claude Code and type the transcript into it |
| Automation (System Events) and Accessibility, Terminal.app only | Terminal.app has no "type text" command, so the helper pastes with ⌘V and restores your clipboard; asked at the first dictation in Terminal.app, which goes to the clipboard |

Then, in an **iTerm2 or Terminal.app tab running Claude Code**: double-tap Right Option, speak,
and tap it once more (or stay silent for 15 s; a recording is capped at 2 minutes). Speech that is
playing stops first, so the microphone doesn't hear it. The transcript is typed into that tab's
prompt; with `/speak autosend on` it is also sent.

- **Only in Claude Code**: anywhere else (another app, a terminal tab without Claude Code) the key
  does nothing, and Right Option keeps working normally, including `@`, `[` and `{` on keyboard
  layouts that use it: a press counts only when the key is tapped alone.
- **Never into a menu**: while that session shows a permission prompt, a question, a plan to
  approve or an MCP form, the transcript goes to the clipboard instead (a "yes" or "2" would
  answer the menu). After you answer a permission prompt with "No" or Esc, this lasts until you
  send your next prompt. The same happens if the tab stopped running Claude Code, or if
  Terminal.app is no longer the active app when the transcript is ready. Other one-key prompts
  Claude Code may show (such as a feedback survey) are not detected.
- **Fn**: `/speak hotkey fn` works, but other apps that use a double Fn (Wispr Flow, macOS
  dictation) also see it. That only matters inside Claude Code tabs, where the helper reacts.
- **Speed**: about 1 s to transcribe 15 s of speech, plus ~2 s the first time while Whisper loads.
  Whisper unloads like the Bosnian voice.
- **After an update that changes the helper**, macOS asks for the permissions again: the helper
  is signed on your Mac, and macOS ties permissions to the exact build.
- `/speak status` shows the hotkey, language, autosend and whether a permission is missing. The
  helper's log is `hotkey.log` in the plugin's data directory.

## How it works

```
Stop hook ──► hooks/tts.sh ──► speakd (launchd, 127.0.0.1:8765) ──► player process ──► speakers
UserPromptSubmit ──► tts.sh stop ─┘   generates sentence chunks with MLX   (own process, so
/speak ──► scripts/speakctl.sh ───┘   while earlier chunks play            generation can't stutter it)

double tap ──► Voice Conversation Hotkey ──► records ──► speakd /transcribe (Whisper) ──► types into the tab
permission / question hooks ──► tts.sh guard ──► speakd (which sessions show a menu)
```

The service runs from the plugin's data directory (`~/.claude/plugins/data/…`), so plugin updates
don't break it; a SessionStart hook copies new daemon code there and restarts the service after an
update. Its log is `speakd.log` in that directory.

## Custom Bosnian voice

Replace `voices/voice_bs.wav` (≤10 s of clean speech) and `voices/voice_bs.txt` (its exact
transcript) in the plugin's data directory, then restart the service:
`launchctl kickstart -k gui/$(id -u)/com.voice-conversation.daemon`. Setup never overwrites them.

## Uninstall

Run `/speak uninstall` first (stops and unregisters the service), then
`claude plugin uninstall voice-conversation`. The models and the `mlx-audio` uv tool are left in place
because other tools may use them; `/speak uninstall` prints how to remove them. It removes the
hotkey helper app, its LaunchAgent and its privacy permissions.

## Privacy

Everything runs locally. Reply text goes only to the local service on `127.0.0.1`. `/speak`
reads the current session's transcript in `~/.claude/projects/` to find the last reply. The
service log records per reply only the session id prefix, engine, length and timings; when
synthesis fails on a chunk, the error line quotes that chunk's first 60 characters. Voice
input records only between your double tap and the stop; the recording goes to the local service
and is not saved, and neither log contains a transcript (only its length and timings).

## Licenses

- Code: MIT, see [LICENSE](LICENSE).
- `voices/`: generated with OmniVoice, whose weights are **CC-BY-NC-4.0**; see [voices/NOTICE](voices/NOTICE).
- Models (downloaded at setup, not redistributed here): Kokoro-82M is Apache-2.0; OmniVoice
  weights are CC-BY-NC-4.0 (non-commercial use); Whisper large-v3-turbo is MIT.
