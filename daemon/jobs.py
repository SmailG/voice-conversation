"""Speech jobs: per-session replacement, cross-session queueing, per-job cancellation.

Rules:
  - a new reply from a session cancels that session's queued/playing jobs (it replaces them)
  - a reply from another session waits its turn (FIFO) instead of interrupting
  - a stop from a session cancels only that session's jobs; stop-all cancels everything
  - a job that waits too long is dropped (busy sessions can't stack speech). The limit follows
    the length limit (queue_age_limit) and travels with the job as expires_at, because it is
    checked both before generation and when the job's audio reaches the front of the player
  - a generated job stays cancellable until its audio has had time to play (generation is
    usually far faster than playback, so "done generating" is not "done speaking")

Cancelled job ids live in a small ring in shared memory so the player process can see them.
"""

import math
import threading
import time
from collections import deque
from dataclasses import dataclass, field
from typing import Any, Callable

MIN_QUEUE_AGE_S = 180
SLOWEST_CHARS_PER_S = 14.0  # Bosnian (OmniVoice) at speed 1.0 measures ~14.7; English ~16.4
QUEUE_AGE_SLACK_S = 30      # generation lag before the reply ahead starts playing
RING_SIZE = 64
PLAY_SLACK_S = 5.0  # margin on the playback-end estimate; over-cancelling a finished job is harmless


class CancelRing:
    """Last RING_SIZE cancelled job ids, in shared memory (readable from the player process)."""

    def __init__(self, ids: Any, cursor: Any):
        self.ids, self.cursor = ids, cursor

    @classmethod
    def create(cls, ctx: Any) -> "CancelRing":
        # ids unlocked: the player process only reads them and may be killed at any moment, which
        # would strand a lock it held; writers are serialised by the cursor lock (parent only).
        return cls(ctx.Array("q", RING_SIZE, lock=False), ctx.Value("q", 0))

    def add(self, job_id: int) -> None:
        with self.cursor.get_lock():
            self.ids[self.cursor.value % RING_SIZE] = job_id
            self.cursor.value += 1

    def __contains__(self, job_id: int) -> bool:
        return job_id in self.ids[:]  # ids start at 1; 0 marks an empty slot


def queue_age_limit(char_limit: int) -> float:
    """How long a reply may wait: enough to sit behind one maximum-length reply at normal speed.

    char_limit 0 means replies have no length limit, so no wait can be called too long.
    """
    if char_limit <= 0:
        return math.inf
    return max(MIN_QUEUE_AGE_S, char_limit / SLOWEST_CHARS_PER_S + QUEUE_AGE_SLACK_S)


class StaleFilter:
    """Player side of the age limit: generation outruns playback, so the backlog waits there.

    A job is judged once, when its first audio reaches the front; a reply that started playing
    always finishes.
    """

    def __init__(self, clock: Callable[[], float] = time.monotonic):
        self.clock = clock
        self._current: int | None = None
        self._stale = False

    def is_stale(self, job_id: int, expires_at: float) -> bool:
        if job_id != self._current:
            self._current = job_id
            self._stale = self.clock() > expires_at
        return self._stale


@dataclass
class Job:
    id: int
    text: str
    session: str | None
    queued_at: float = field(default_factory=time.monotonic)
    expires_at: float = math.inf  # dropped if still waiting after this (monotonic clock)


class JobBoard:
    def __init__(self, ring: CancelRing, clock: Callable[[], float] = time.monotonic,
                 max_age_s: float = MIN_QUEUE_AGE_S):
        self.ring, self.clock, self.max_age_s = ring, clock, max_age_s
        self._cond = threading.Condition()
        self._queue: deque[Job] = deque()
        self._interrupted = False
        self._live: dict[int, Job] = {}  # queued, generating, or generated but maybe still playing
        self._plays_until: dict[int, float] = {}  # generated job id -> estimated end of its audio
        self._player_busy_until = 0.0
        self._next_id = 1

    def submit(self, text: str, session: str | None, max_age_s: float | None = None) -> Job:
        """Queue a reply; max_age_s (default: the board's) bounds how long it may wait."""
        with self._cond:
            if session is not None:
                self._cancel_where(lambda j: j.session == session)
            now = self.clock()
            age = self.max_age_s if max_age_s is None else max_age_s
            job = Job(self._next_id, text, session, now, now + age)
            self._next_id += 1
            self._queue.append(job)
            self._live[job.id] = job
            self._cond.notify()
            return job

    def cancel_session(self, session: str) -> int:
        with self._cond:
            return self._cancel_where(lambda j: j.session == session)

    def cancel_all(self) -> int:
        with self._cond:
            return self._cancel_where(lambda j: True)

    def interrupt(self) -> None:
        """Make a waiting next_job() return None now (other work is waiting for the worker)."""
        with self._cond:
            self._interrupted = True
            self._cond.notify_all()

    def next_job(self, timeout: float | None = None) -> Job | None:
        """Block until a live, fresh job is queued; stale ones are cancelled and skipped.
        Returns None on timeout or interrupt()."""
        with self._cond:
            deadline = None if timeout is None else self.clock() + timeout
            while True:
                if self._interrupted:
                    self._interrupted = False
                    return None
                while self._queue:
                    job = self._queue.popleft()
                    if job.id in self.ring:
                        continue
                    if self.clock() > job.expires_at:
                        self._cancel_where(lambda j: j.id == job.id)
                        continue
                    return job
                remaining = None if deadline is None else deadline - self.clock()
                if remaining is not None and remaining <= 0:
                    return None
                self._cond.wait(remaining)

    def is_cancelled(self, job: Job) -> bool:
        return job.id in self.ring

    def finish(self, job: Job, audio_s: float = 0.0) -> None:
        """Generation is done; keep the job cancellable while its audio may still be playing."""
        with self._cond:
            if job.id not in self._live:
                return
            self._player_busy_until = max(self._player_busy_until, self.clock()) + audio_s
            self._plays_until[job.id] = self._player_busy_until + PLAY_SLACK_S

    def _cancel_where(self, pred: Callable[[Job], bool]) -> int:
        self._forget_played()
        doomed = [j for j in self._live.values() if pred(j)]
        for j in doomed:
            self.ring.add(j.id)
            del self._live[j.id]
            self._plays_until.pop(j.id, None)
        self._queue = deque(j for j in self._queue if j.id in self._live)
        return len(doomed)

    def _forget_played(self) -> None:
        now = self.clock()
        for job_id in [i for i, until in self._plays_until.items() if until < now]:
            del self._plays_until[job_id]
            self._live.pop(job_id, None)
