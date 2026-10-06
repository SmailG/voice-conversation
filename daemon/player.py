"""Audio playback in its own process, so MLX generation in speakd can't starve the output.

MLX generation holds the GIL for long stretches. In-process playback stuttered (sounddevice's
callback needs the GIL and built-in speakers buffer only ~27 ms), and a multiprocessing Queue
was no better: its feeder thread also waits on the GIL, delaying first audio by seconds. So the
generator writes to a Pipe synchronously, and all playback work (a reader thread plus blocking
writes with a larger buffer) lives in this child process with its own GIL.

A PortAudio call can block forever inside CoreAudio (seen: Pa_StopStream waiting on a HAL mutex
for over a day, while the reader thread kept accepting audio, so replies were generated and never
heard). Python cannot interrupt a thread inside native code, so recovery is from outside: the child
publishes a deadline in shared memory around each blocking audio call (and the parent sets one
for its startup); the parent kills a child that misses it, and the next send starts a fresh player.
"""

import os
import queue
import threading
import time
from dataclasses import dataclass
from typing import Any

from jobs import CancelRing, StaleFilter

BUFFER_S = 0.25   # PortAudio output latency; absorbs scheduling hiccups
BLOCK_S = 0.1     # write granularity, also the cancel reaction time
CALL_S = 10.0     # write/stop/abort/close are bounded by the 0.25 s buffer: 10 s means a wedged device
OPEN_S = 30.0     # opening or starting a stream can legitimately take seconds (Bluetooth route wake)
STARTUP_S = 30.0  # spawn + numpy/sounddevice import (sounddevice runs Pa_Initialize on import)
WATCH_EVERY_S = 1.0


def _reader(conn: Any, local: queue.Queue) -> None:
    while True:
        try:
            local.put(conn.recv())
        except (EOFError, OSError):  # speakd is gone (restart, update, kill): don't linger as an orphan
            os._exit(0)


class _AudioCalls:
    """Brackets each blocking PortAudio call with a deadline in shared memory (0 = not in one)."""

    def __init__(self, deadline: Any):
        self._deadline = deadline

    def __call__(self, fn: Any, *args: Any, limit: float = CALL_S) -> Any:
        self._deadline.value = time.monotonic() + limit
        try:
            return fn(*args)
        finally:
            self._deadline.value = 0.0


def player_main(conn: Any, ring_ids: Any, ring_cursor: Any, deadline: Any) -> None:
    """Child process: play (job_id, audio, sr, t0, expires_at) items; skip cancelled or stale jobs."""
    # The reader starts first, so a child that hangs while importing still drains the pipe and
    # can't block speakd's send; the parent's startup deadline covers the hang itself.
    local: queue.Queue = queue.Queue()
    threading.Thread(target=_reader, args=(conn, local), daemon=True).start()
    import numpy as np
    import sounddevice as sd

    deadline.value = 0.0  # started
    call = _AudioCalls(deadline)
    ring = CancelRing(ring_ids, ring_cursor)
    stale = StaleFilter()
    stream, stream_sr = None, None
    while True:
        job_id, audio, sr, t0, expires_at = local.get()
        if stale.is_stale(job_id, expires_at):
            if t0 is not None:
                print("dropped a reply that waited past its limit", flush=True)
            continue
        if job_id in ring:
            if stream is not None and stream.active and local.empty():
                call(stream.stop)  # release the device; don't leave it open playing silence
            continue
        if stream is None or sr != stream_sr:
            if stream is not None:
                call(stream.close)
            stream = call(lambda: sd.OutputStream(samplerate=sr, channels=1, dtype="float32",
                                                  latency=BUFFER_S), limit=OPEN_S)
            stream_sr = sr
        if not stream.active:
            call(stream.start, limit=OPEN_S)
        if t0 is not None:
            print(f"first audio after {time.monotonic() - t0:.2f}s", flush=True)
        block = int(BLOCK_S * sr)
        samples = np.ascontiguousarray(audio, dtype=np.float32).reshape(-1, 1)
        for i in range(0, len(samples), block):
            if job_id in ring:
                call(stream.abort)  # drop buffered audio immediately
                break
            call(stream.write, samples[i:i + block])
        if local.empty() and stream.active:
            call(stream.stop)  # drains the buffer, then releases the device between replies


@dataclass
class _Child:
    """One player process with its own pipe and deadline; replaced whole, never patched."""
    proc: Any
    send_end: Any
    deadline: Any
    gone: bool = False  # killed by the watchdog or seen dead: never killed or reported twice


class Player:
    """Parent-side handle. send() pickles and writes in the calling thread (no feeder thread).

    A watchdog thread kills a player that misses its deadline; send() then finds the pipe broken
    and starts a new one. Audio queued in the old player is lost with it, and the rest of the
    reply it was playing is dropped rather than resumed mid-sentence.
    """

    def __init__(self, ring: CancelRing, ctx: Any, target: Any = player_main,
                 startup_s: float = STARTUP_S, watch_every_s: float = WATCH_EVERY_S):
        self._ring, self._ctx, self._target = ring, ctx, target
        self._startup_s, self._watch_every_s = startup_s, watch_every_s
        self._lock = threading.Lock()
        self._last_job: int | None = None
        self.restarts = 0
        self._child = self._spawn()
        threading.Thread(target=self._watch, daemon=True).start()

    def _spawn(self) -> _Child:
        recv_end, send_end = self._ctx.Pipe(duplex=False)
        # Stamped before start(), so a child that hangs before its first audio call is covered too.
        deadline = self._ctx.Value("d", time.monotonic() + self._startup_s, lock=False)
        proc = self._ctx.Process(target=self._target,
                                 args=(recv_end, self._ring.ids, self._ring.cursor, deadline),
                                 daemon=True)
        proc.start()
        recv_end.close()  # only the child holds the read end, so its death breaks the pipe (not left to GC)
        return _Child(proc, send_end, deadline)

    def _respawn(self) -> None:
        old = self._child
        old.gone = True
        old.proc.kill()
        old.proc.join(timeout=2)
        old.send_end.close()
        self.restarts += 1
        self._child = self._spawn()

    @staticmethod
    def _overdue(child: _Child) -> float:
        deadline = child.deadline.value
        if child.gone or not deadline:
            return 0.0
        return max(0.0, time.monotonic() - deadline)

    def overdue_s(self) -> float:
        """Seconds the current player is past its deadline (0 when on time, idle or already gone)."""
        return self._overdue(self._child)

    def is_alive(self) -> bool:
        return not self._child.gone

    def _watch(self) -> None:
        # Kill only, without the send lock: a send blocked on a full pipe holds it, and the kill
        # is what unblocks that send (it then fails with a broken pipe and respawns).
        while True:
            time.sleep(self._watch_every_s)
            try:
                self._check(self._child)  # one snapshot: a respawn mid-check can't redirect the kill
            except Exception as e:  # the watchdog must outlive any one bad tick
                print(f"player watchdog error: {e!r}", flush=True)

    def _check(self, child: _Child) -> None:
        if child.gone:
            return
        if not child.proc.is_alive():
            child.gone = True
            return
        overdue = self._overdue(child)
        if overdue > 0:
            print(f"player missed its deadline by {overdue:.1f}s (stuck in startup or an audio "
                  "call); restarting it", flush=True)
            child.gone = True
            child.proc.kill()

    def _try_send(self, item: tuple) -> bool:
        try:
            self._child.send_end.send(item)
            return True
        except OSError:  # BrokenPipeError: the player died, or the watchdog killed it
            return False

    def send(self, item: tuple) -> None:
        job_id = item[0]
        with self._lock:
            # A killed child that lingers keeps the pipe open, so "gone" is checked, not just EPIPE.
            if not self._child.gone and self._try_send(item):
                self._last_job = job_id
                return
            print("player gone; starting a new one", flush=True)
            self._respawn()
            if job_id == self._last_job:  # it died mid-reply: drop the rest rather than resume
                self._ring.add(job_id)
                return
            if self._try_send(item):
                self._last_job = job_id
                return
            # The replacement is gone too (device still wedged). Cancel the whole reply, so a later
            # chunk can't start it mid-sentence; the next reply tries a new player again.
            print("new player gone too; dropped this reply", flush=True)
            self._ring.add(job_id)

    def close(self) -> None:
        child = self._child
        child.gone = True
        child.proc.kill()
        child.proc.join(timeout=2)
        child.send_end.close()
