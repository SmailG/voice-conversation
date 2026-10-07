import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "daemon"))
from sessions import (Session, SessionWatch, host_payload, parse_sessions, parse_pid, runs_claude,  # noqa: E402
                      sessions_under)

# Shape of `ps -axo pid=,tty=,args=` on a Mac running Claude Code 2.1 (session ids made up).
PS = """\
  101 ??       /Users/u/.local/bin/claude daemon run
  102 ??       claude bg-pty-host --bg-pty-host
  103 ??       claude bg-spare --bg-spare
  104 ttys011  claude bg-spare --bg-spare
  105 ttys009  claude --resume 00000000-1111-2222-3333-444444444444
  106 ttys014  claude --dangerously-skip-permissions
  107 ttys020  claude -p summarize this
  108 ttys021  /usr/bin/python3 -m claude_tools
  109 ttys022  node /opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js
  110 ttys023  vim claude.md
  111 ttys024  claude --print hello
  112 ??       claude --resume 55555555-6666-7777-8888-999999999999
"""


# Shape of `ps -axo pid=,ppid=,tty=,args=`: one Cursor window with a Claude terminal, a plain shell
# terminal and a headless run; Ghostty with a Claude tab and a tmux client; the tmux server, which
# launchd adopts; an iTerm2 session; and a session whose parent is gone.
PS_TREE = """\
    1     0 ??       /sbin/launchd
  500     1 ??       /Applications/Cursor.app/Contents/MacOS/Cursor
  510   500 ??       /Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin) terminal pty-host
  520   510 ttys010  /bin/zsh -il
  530   520 ttys010  claude --dangerously-skip-permissions
  540   510 ttys012  /bin/zsh -il
  541   540 ttys012  claude -p summarize this
  600     1 ??       /Applications/Ghostty.app/Contents/MacOS/ghostty
  610   600 ttys020  /usr/bin/login -flp u /bin/zsh
  620   610 ttys020  -zsh
  630   620 ttys020  claude --resume 00000000-1111-2222-3333-444444444444
  640   600 ttys021  /usr/bin/login -flp u /bin/zsh
  650   640 ttys021  tmux attach -t work
  700     1 ??       tmux new -s work
  710   700 ttys030  -zsh
  720   710 ttys030  claude
  800     1 ??       /Applications/iTerm.app/Contents/MacOS/iTerm2
  810   800 ttys040  -zsh
  820   810 ttys040  claude
  900   999 ttys050  claude
"""


class SessionsUnderTest(unittest.TestCase):
    def test_finds_the_interactive_session_inside_an_app(self):
        self.assertEqual(sessions_under(PS_TREE, 500), [Session(530, "ttys010")])

    def test_headless_run_inside_the_app_is_not_a_session(self):
        self.assertNotIn(541, [s.pid for s in sessions_under(PS_TREE, 500)])

    def test_each_app_sees_only_its_own_sessions(self):
        self.assertEqual(sessions_under(PS_TREE, 600), [Session(630, "ttys020")])
        self.assertEqual(sessions_under(PS_TREE, 800), [Session(820, "ttys040")])

    def test_a_tmux_session_belongs_to_no_terminal_app(self):
        # The tmux server is launchd's child, so the app hosting the tmux client can't reach it.
        hosts = [pid for pid in (500, 600, 800) if 720 in [s.pid for s in sessions_under(PS_TREE, pid)]]
        self.assertEqual(hosts, [])

    def test_an_app_with_no_session_and_an_unknown_pid(self):
        self.assertEqual(sessions_under(PS_TREE, 510 + 1), [])
        self.assertEqual(sessions_under(PS_TREE, 4242), [])

    def test_launchd_is_never_a_host(self):
        self.assertEqual(sessions_under(PS_TREE, 1), [])

    def test_a_parent_loop_does_not_hang(self):
        self.assertEqual(sessions_under("  10    11 ttys001  claude\n  11    10 ttys001  -zsh\n", 77), [])

    def test_empty_and_garbage_output(self):
        self.assertEqual(sessions_under("", 500), [])
        self.assertEqual(sessions_under("not ps output\n  x y z", 500), [])


class HostPayloadTest(unittest.TestCase):
    def test_lists_the_app_sessions_with_their_menu_state(self):
        self.assertEqual(host_payload(PS_TREE, 500, guarded=["ttys010", "ttys040"]),
                         {"pid": 500, "sessions": [{"tty": "ttys010", "guarded": True}]})
        self.assertEqual(host_payload(PS_TREE, 600, guarded=[]),
                         {"pid": 600, "sessions": [{"tty": "ttys020", "guarded": False}]})

    def test_parse_pid_accepts_only_a_plain_positive_number(self):
        self.assertEqual(parse_pid("55386"), 55386)
        for bad in [None, "", "0", "1", "-5", "12a", " 42", "1e3", "99999999999", "²", "٤٢"]:
            with self.subTest(bad=bad):
                self.assertIsNone(parse_pid(bad))

class ParseSessionsTest(unittest.TestCase):
    def test_finds_interactive_sessions_only(self):
        self.assertEqual(parse_sessions(PS), [Session(105, "ttys009"), Session(106, "ttys014"),
                                              Session(109, "ttys022")])

    def test_claude_without_a_terminal_is_not_a_session(self):
        self.assertNotIn(112, [s.pid for s in parse_sessions(PS)])

    def test_background_helpers_with_a_tty_are_not_sessions(self):
        self.assertNotIn("ttys011", [s.tty for s in parse_sessions(PS)])

    def test_empty_and_garbage_output(self):
        self.assertEqual(parse_sessions(""), [])
        self.assertEqual(parse_sessions("not ps output\n\n  x y"), [])


class FakeClock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


class SessionWatchTest(unittest.TestCase):
    def setUp(self):
        self.clock, self.output = FakeClock(), PS
        self.watch = SessionWatch(scan=lambda: self.output, clock=self.clock)

    def test_open_sessions_are_never_none_for(self):
        self.watch.refresh()
        self.clock.now += 3600
        self.assertFalse(self.watch.none_for(60))

    def test_grace_period_after_the_last_session_closes(self):
        self.watch.refresh()
        self.output = ""
        self.watch.refresh()
        self.clock.now += 59
        self.assertFalse(self.watch.none_for(60))  # /clear or a restart: not yet
        self.clock.now += 1
        self.assertTrue(self.watch.none_for(60))

    def test_rescans_during_the_grace_do_not_restart_it(self):
        self.output = ""
        self.watch.refresh()
        self.clock.now += 30
        self.watch.refresh()  # housekeeping scans every 30 s
        self.clock.now += 30
        self.assertTrue(self.watch.none_for(60))

    def test_a_returning_session_resets_the_grace(self):
        self.output = ""
        self.watch.refresh()
        self.clock.now += 30
        self.output = PS
        self.watch.refresh()
        self.output = ""
        self.watch.refresh()
        self.clock.now += 59
        self.assertFalse(self.watch.none_for(60))

    def test_failed_scan_keeps_the_last_known_sessions(self):
        self.watch.refresh()
        self.output = None
        self.watch.refresh()
        self.clock.now += 3600
        self.assertEqual(len(self.watch.sessions), 3)
        self.assertFalse(self.watch.none_for(60))



class RunsClaudeTest(unittest.TestCase):
    def test_one_terminal_is_checked_by_its_own_scan(self):
        asked = []

        def scan(tty):
            asked.append(tty)
            return PS

        self.assertTrue(runs_claude("ttys009", scan))
        self.assertEqual(asked, ["ttys009"])

    def test_a_terminal_with_only_a_shell_or_background_helper_is_not_a_session(self):
        self.assertFalse(runs_claude("ttys011", lambda tty: PS))  # claude bg-spare
        self.assertFalse(runs_claude("ttys099", lambda tty: PS))

    def test_a_failed_scan_is_unknown(self):
        self.assertIsNone(runs_claude("ttys009", lambda tty: None))

if __name__ == "__main__":
    unittest.main()
