# Voice input in any app that runs Claude Code

Status: accepted, 2026-10-07. Target release 0.7.0.

## Goal

A double-tap works wherever a Claude Code session runs: iTerm2, Terminal.app, the integrated
terminal of Cursor, VS Code, Antigravity and other IDEs, Ghostty, Warp and other terminal apps.
Today the helper ignores every app except iTerm2 and Terminal.app, silently.

## What was measured (2026-10-07)

- Claude Code has no documented way for another process to put text into a running terminal
  session. The IDE integration's ⌥K inserts only `@file#L1-2`, and the `vscode://` `prompt=`
  URI pre-fills only the extension's own panel. The in-process mod (`$.prompt.fill`) worked in a
  spike but was shelved on 2026-10-04. So delivery outside iTerm2 is a paste (⌘V) into whatever
  has keyboard focus.
- VS Code-family IDEs (Electron) report no focused element to Accessibility unless
  `AXManualAccessibility` is set on the app. With it set, a focused terminal reads
  `DOMClassList=xterm-helper-textarea` with the terminal's title (`2.1.289` for Claude Code,
  `zsh` for a shell). Setting it made Cursor ask whether to turn on
  `editor.accessibilitySupport`, and Yes wrote that to the user's settings. Antigravity IDE did
  not ask.
- Ghostty reports its focused text area without anything being set, but not which tab or split.

## Decisions

1. **Paste where focus is.** Every app other than iTerm2 and Terminal.app gets the transcript
   by ⌘V into the focused element, the clipboard restored afterwards. iTerm2 and Terminal.app
   keep their current paths unchanged.
2. **Three guards, each cheap:**
   - **Arm only where Claude Code runs.** The double-tap starts recording only when the front
     app hosts an interactive `claude` session: a `claude` process with a terminal whose
     ancestors include the front app's pid. Elsewhere it stays silent, as now.
   - **Same app at delivery.** If the front app changed while transcribing, the transcript goes
     to the clipboard.
   - **No paste into a menu.** If any Claude session in that app shows a permission prompt or a
     question (the daemon's guard), the transcript goes to the clipboard.
3. **Autosend only in iTerm2 and Terminal.app**, where the target tab is known by its tty.
   Elsewhere the paste waits for Enter; `/speak status` and the README say so.
4. **The paste copy is transient.** The copy made for one paste (here and in the Terminal.app path)
   carries `org.nspasteboard.TransientType` and `org.nspasteboard.ConcealedType`, so clipboard
   managers keep no history of it, and the person's clipboard comes back afterwards unless
   something was copied meanwhile. A transcript left on the clipboard for the person to paste
   (a guard refused) is a normal copy, so it survives in their history if it goes nowhere.
5. **Sessions in tmux or screen** have no host app in their ancestry, so their app doesn't arm.

## Considered and dropped: the IDE focus check

Setting `AXManualAccessibility` on Electron IDEs would let the helper paste only into a focused
terminal and autosend when that terminal's title shows Claude Code. Dropped because:
- its main payoff, autosend in IDEs, is unused (autosend is off);
- what it prevents, a paste into an editor, is visible and undone with ⌘Z;
- it costs a forced accessibility tree in every IDE dictated into, a screen-reader prompt that
  changed a real setting during testing, and a new module with a title heuristic and a setting.

Revisit it as an opt-in if pastes into editors become a nuisance or autosend in IDEs is wanted.

## Changes

- **Daemon:** `GET /host?pid=<app pid>` → `{"sessions": [{"tty", "guarded"}]}` for interactive
  `claude` sessions under that pid. One `ps -axo pid=,ppid=,tty=,args=` scan; the pure function
  `sessions_under(ps_output, pid)` walks the ancestry.
- **Helper:**
  - `Gate.swift`: pure `armDecision` and `pasteDecision` functions for the three guards.
  - `main.swift`: `beginListening` falls back to `/host` for apps other than iTerm2 and
    Terminal.app, and remembers the app's pid. `deliver` re-checks the guards and pastes.
  - `Terminals.swift`: a `CGEvent` ⌘V paste (Accessibility only, no System Events grant), and
    transient clipboard types.
- **speakctl / README:** supported hosts, where autosend applies, the tmux limit.

## Tests

- Python: `sessions_under` over fixture `ps` output, with nested shells, a tmux server parent, a
  `claude -p` run, another app's session and a dead parent.
- Swift `GateTests`: every branch of the two decisions, including the refusals: no session, a
  changed front app, a guarded session.
- Mutation checks: dropping each guard must fail a test.

## Verification before merge

1. **Clipboard race** (blocks the release). A Cursor terminal and a Ghostty pane, each running
   `cat > file`, with a sentinel on the clipboard. Deliver a known transcript 10 times per host
   and compare byte for byte. Any sentinel leak means a longer restore delay or typing via
   keystrokes.
2. **Host matrix:** iTerm2 and Terminal.app unchanged; Cursor, Antigravity IDE and VS Code
   (terminal); Ghostty; a tmux session (does not arm).
3. Independent code review, CI green. The helper rebuild can make macOS ask for Input
   Monitoring and Accessibility again.
