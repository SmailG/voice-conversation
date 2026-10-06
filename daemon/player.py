"""Audio playback in its own process, so MLX generation in speakd can't starve the output.

MLX generation holds the GIL for long stretches. In-process playback stuttered (sounddevice's
callback needs the GIL and built-in speakers buffer only ~27 ms), and a multiprocessing Queue
was no better: its feeder thread also waits on the GIL, delaying first audio by seconds. So the
generator writes to a Pipe synchronously, and all playback work (a reader thread plus blocking
writes with a larger buffer) lives in this child process with its own GIL.

A PortAudio call can block forever inside CoreAudio (seen: Pa_StopStream waiting on a HAL mutex
for over a day, while the reader thread kept accepting audio, so replies were generated and never
heard). The child marks when each blocking audio call starts; the parent kills a child stuck in
one call for STALL_S, and the next send starts a fresh player.
"""

import os
import queue
import threading
import time
from typing import Any

from jobs import CancelRing, StaleFilter

BUFFER_S = 0.25   # PortAudio output latency; absorbs scheduling hiccups
BLOCK_S = 0.1     # write granularity, also the cancel reaction time
STALL_S = 10.0    # one audio call blocking this long means the device is wedged: restart the player
WATCH_EVERY_S = 1.0


def _reader(conn: Any, local: queue.Queue) -> None:
    while True:
        try:
            local.put(conn.recv())
        except (EOFError, OSError):  # speakd is gone (restart, update, kill): don't linger as an orphan
            os._exit(0)


class _AudioCalls:
    """Brackets each blocking PortAudio call with its start time in shared memory (0 = none)."""

    def __init__(self, busy: Any):
        self._busy = busy

    def __call__(self, fn: Any, *args: Any) -> Any:
        self._busy.value = time.monotonic()
        try:
            return fn(*args)
        finally:
            self._busy.value = 0.0


def player_main(conn: Any, ring_ids: Any, ring_cursor: Any, busy: Any) -> None:
    """Child process: play (job_id, audio, sr, t0, expires_at) items; skip cancelled or stale jobs."""
    import numpy as np
    import sounddevice as sd

    call = _AudioCalls(busy)

    ring = CancelRing(ring_ids, ring_cursor)
    local: queue.Queue = queue.Queue()
    threading.Thread(target=_reader, args=(conn, local), daemon=True).start()
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
                                                  latency=BUFFER_S))
            stream_sr = sr
        if not stream.active:
            call(stream.start)
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


class Player:
    """Parent-side handle. send() pickles and writes in the calling thread (no feeder thread).

    A watchdog thread kills a player stuck in one audio call; send() then finds the pipe broken
    and starts a new one. Audio already queued in the old player is lost with it.
    """

    def __init__(self, ring: CancelRing, ctx: Any, target: Any = player_main,
                 stall_s: float = STALL_S, watch_every_s: float = WATCH_EVERY_S):
        self._ring, self._ctx, self._target = ring, ctx, target
        self._stall_s, self._watch_every_s = stall_s, watch_every_s
        self._busy = ctx.Value("d", 0.0, lock=False)
        self._lock = threading.Lock()
        self.restarts = 0
        self._spawn()
        threading.Thread(target=self._watch, daemon=True).start()

    def _spawn(self) -> None:
        recv_end, self._send_end = self._ctx.Pipe(duplex=False)
        self._busy.value = 0.0
        self._proc = self._ctx.Process(target=self._target,
                                       args=(recv_end, self._ring.ids, self._ring.cursor, self._busy),
                                       daemon=True)
        self._proc.start()
        recv_end.close()  # only the child holds the read end, so its death breaks the pipe (not left to GC)

    def _respawn(self) -> None:
        self._proc.kill()
        self._proc.join(timeout=2)
        self._send_end.close()
        self.restarts += 1
        self._spawn()

    def stuck_for(self) -> float:
        """Seconds the player has been inside one audio call (0 when it isn't in one)."""
        started = self._busy.value
        return time.monotonic() - started if started else 0.0

    def _watch(self) -> None:
        # Kill only, without the send lock: a send blocked on a full pipe holds it, and the kill
        # is what unblocks that send (it then fails with a broken pipe and respawns).
        while True:
            time.sleep(self._watch_every_s)
            stuck = self.stuck_for()
            proc = self._proc
            if stuck > self._stall_s and proc.is_alive():
                print(f"player stuck in an audio call for {stuck:.1f}s; restarting it", flush=True)
                proc.kill()

    def send(self, item: tuple) -> None:
        with self._lock:
            try:
                self._send_end.send(item)
            except OSError:  # BrokenPipeError: the player died, or the watchdog killed it
                print("player gone; starting a new one", flush=True)
                self._respawn()
                self._send_end.send(item)

    def close(self) -> None:
        self._proc.kill()
        self._proc.join(timeout=2)
        self._send_end.close()
