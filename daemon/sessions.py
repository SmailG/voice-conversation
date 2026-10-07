"""Which interactive Claude Code sessions are open, found by scanning processes.

A process scan, not SessionStart/SessionEnd hooks: /clear fires End then Start, an async SessionEnd
dies with its claude process, and kill -9 or closing a terminal tab skips it entirely.
"""

import os
import subprocess
import threading
import time
from dataclasses import dataclass
from typing import Callable

# Claude Code's own background processes, and headless runs, are not sessions someone is using.
NOT_A_SESSION = {"bg-pty-host", "--bg-pty-host", "bg-spare", "--bg-spare", "daemon", "-p", "--print"}
NPM_ENTRY = "@anthropic-ai/claude-code"


@dataclass(frozen=True)
class Session:
    pid: int
    tty: str


def _is_claude(args: list[str]) -> bool:
    return os.path.basename(args[0]) == "claude" or any(NPM_ENTRY in a for a in args[:2])


def _is_session(tty: str, args: list[str]) -> bool:
    """An interactive Claude Code process: claude with a terminal, not a background helper or -p."""
    return tty not in ("??", "-") and _is_claude(args) and not NOT_A_SESSION & set(args[1:])


def parse_sessions(ps_output: str) -> list[Session]:
    """Sessions from `ps -axo pid=,tty=,args=` output: a claude process with a terminal."""
    sessions = []
    for line in ps_output.splitlines():
        parts = line.split(None, 2)
        if len(parts) < 3 or not parts[0].isdigit():
            continue
        if _is_session(parts[1], parts[2].split()):
            sessions.append(Session(int(parts[0]), parts[1]))
    return sessions


MAX_ANCESTRY = 64  # deeper than any real process tree; also ends a parent loop


def sessions_under(ps_output: str, app_pid: int) -> list[Session]:
    """Sessions (as parse_sessions) running inside the app with this pid, from
    `ps -axo pid=,ppid=,tty=,args=` output: the app is one of the session's ancestors.

    launchd (pid 1) is everyone's ancestor, so it hosts nothing. A tmux or screen session's
    server is launchd's child, so it belongs to no app.
    """
    if app_pid <= 1:
        return []
    parent: dict[int, int] = {}
    candidates: list[Session] = []
    for line in ps_output.splitlines():
        parts = line.split(None, 3)
        if len(parts) < 4 or not (parts[0].isdigit() and parts[1].isdigit()):
            continue
        pid, ppid = int(parts[0]), int(parts[1])
        parent[pid] = ppid
        if _is_session(parts[2], parts[3].split()):
            candidates.append(Session(pid, parts[2]))
    found = []
    for session in candidates:
        pid = session.pid
        for _ in range(MAX_ANCESTRY):
            pid = parent.get(pid, 0)
            if pid <= 1:
                break
            if pid == app_pid:
                found.append(session)
                break
    return found


def run_ps(tty: str | None = None) -> str | None:
    """All processes (~0.15 s with a few hundred running), or only one terminal's (~0.02 s)."""
    where = ["-t", tty] if tty else ["-ax"]
    try:
        done = subprocess.run(["ps", *where, "-o", "pid=,tty=,args="], capture_output=True, text=True,
                              timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    if done.returncode == 0 or (tty and done.returncode == 1 and not done.stdout):
        return done.stdout  # ps -t exits 1 for a terminal that no longer exists: nothing runs there
    return None


MAX_PID = 10_000_000  # far above macOS's limit (99998); rejects absurd query values


def parse_pid(value: str | None) -> int | None:
    """An app pid from a query string: digits only, above launchd's 1, below MAX_PID."""
    if not value or not (value.isascii() and value.isdigit()) or len(value) > len(str(MAX_PID)):
        return None
    pid = int(value)
    return pid if 1 < pid < MAX_PID else None


def host_payload(ps_output: str, app_pid: int, guarded: list[str]) -> dict:
    """GET /host's answer: the app's sessions, each with whether it shows a menu (a prompt or a
    question that pasted text would answer)."""
    return {"pid": app_pid,
            "sessions": [{"tty": s.tty, "guarded": s.tty in guarded} for s in sessions_under(ps_output, app_pid)]}


def run_ps_tree() -> str | None:
    """All processes with their parents, for sessions_under (~0.15 s)."""
    try:
        done = subprocess.run(["ps", "-axo", "pid=,ppid=,tty=,args="], capture_output=True, text=True,
                              timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    return done.stdout if done.returncode == 0 else None


def runs_claude(tty: str, scan: Callable[[str], str | None] = run_ps) -> bool | None:
    """Whether this terminal runs an interactive Claude Code session; None if ps failed."""
    output = scan(tty)
    if output is None:
        return None
    return any(s.tty == tty for s in parse_sessions(output))


class SessionWatch:
    def __init__(self, scan: Callable[[], str | None] = run_ps, clock: Callable[[], float] = time.monotonic):
        self._scan, self._clock = scan, clock
        self.sessions: list[Session] = []
        self._empty_since: float | None = clock()
        self._lock = threading.Lock()  # the worker loop and /health both refresh

    def refresh(self) -> None:
        output = self._scan()
        if output is None:  # ps failed: keep the last known state rather than guess "none open"
            return
        with self._lock:
            self.sessions = parse_sessions(output)
            if self.sessions:
                self._empty_since = None
            elif self._empty_since is None:
                self._empty_since = self._clock()

    def none_for(self, seconds: float) -> bool:
        """True once no session has been open for `seconds` (a grace for /clear and restarts)."""
        return self._empty_since is not None and self._clock() - self._empty_since >= seconds
