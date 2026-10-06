"""voice-conversation daemon: speaks Claude Code replies locally, and transcribes voice input.

  POST /speak   Stop-hook JSON payload (last_assistant_message, session_id)
  POST /stop    UserPromptSubmit payload (session_id, prompt); empty body = stop everything
  POST /prepare      start loading Whisper (voice input is about to record)
  POST /transcribe   16-bit PCM WAV body -> {"text", "language"} (local Whisper; text is never logged)
  POST /guard?tty=X  hook JSON: a session opened or closed a menu that typing would answer
  GET  /health  {"name", "version", "home", "ready", "models", "sessions", "guarded", ...}; 503 while loading
  GET  /session?tty=X  {"open", "guarded"} for one terminal (fast: scans only that tty)
  GET  /config  voice-input settings
/guard, and ?tty=X on /speak and /stop (a reply or prompt closes that session's menus), need the
X-Voice-Conversation-Hook header, which a web page can't send to localhost without a CORS preflight.

State lives in VOICE_CONVERSATION_HOME (the plugin's data dir). Kokoro (English) stays loaded; OmniVoice
(Bosnian) and Whisper load on first use and unload when idle or once no Claude Code session is open.
"""

import json
import multiprocessing as mp
import os
import queue
import threading
import time
import traceback
from http.server import ThreadingHTTPServer
from urllib.parse import parse_qs

import engines
import stt
from guard import PromptGuard, is_tty
from jobs import CancelRing, Job, JobBoard, queue_age_limit
from localonly import LocalOnlyHandler
from models import ModelManager
from sessions import SessionWatch, runs_claude
from player import Player
from settings import (HOME, MIN_SPEED, VOICES_DIR, char_limit, speech_speed, stt_language,
                      unload_minutes)
from text import (CONTROL_MARKER, MERGE_TO, is_bosnian, is_speak_command, parse_payload, prepare,
                  split_chunks)

NAME, VERSION = "voice-conversation", "0.6.3"
HOST, PORT = "127.0.0.1", int(os.environ.get("VOICE_CONVERSATION_PORT", "8765"))
LOG_PATH, LOG_MAX_BYTES = os.path.join(HOME, "speakd.log"), 512 * 1024
MAX_BODY_BYTES = 20 * 1024 * 1024
TRANSCRIBE_TIMEOUT_S = 120
HOOK_HEADER = "X-Voice-Conversation-Hook"
HOUSEKEEPING_EVERY_S = 30  # session scan + idle sweep
NO_SESSION_GRACE_S = 60    # /clear and restarts briefly show zero sessions


def short(session: str | None) -> str:
    return (session or "?")[:8]


class WorkerTask:
    """A function to run on the MLX worker thread, with its result handed back."""

    def __init__(self, fn):
        self.fn, self.done, self.result, self.error = fn, threading.Event(), None, None


def trim_log() -> None:
    """Keep the log bounded; launchd opens it O_APPEND, so truncating in place is safe."""
    try:
        if os.path.getsize(LOG_PATH) > LOG_MAX_BYTES:
            os.truncate(LOG_PATH, 0)
    except OSError:
        pass


class Speaker:
    """One MLX worker thread loads models and generates; a player process plays.

    MLX GPU streams are thread-local, so models must load in the thread that runs them.
    """

    def __init__(self):
        ctx = mp.get_context("spawn")
        ring = CancelRing.create(ctx)
        self.board = JobBoard(ring)
        self.player = Player(ring, ctx)
        self.models = ModelManager({"en": engines.load_en, "bs": lambda: engines.load_bs(VOICES_DIR),
                                    "stt": lambda: stt.load(HOME)},
                                   resident=("en",), release=engines.release)
        self._tasks: queue.SimpleQueue = queue.SimpleQueue()
        self.sessions = SessionWatch()
        self.guard = PromptGuard(os.path.join(HOME, "guard.json"))
        self._next_housekeeping = 0.0
        self.ready = threading.Event()
        threading.Thread(target=self._generate_loop, daemon=True).start()

    def speak(self, text: str, session: str | None) -> None:
        if not text:  # e.g. a turn that ended on a tool call: never cancel for nothing
            print(f"ignored empty reply from session {short(session)}", flush=True)
            return
        if text.startswith(CONTROL_MARKER):  # Claude echoing /speak output: don't cut a replay
            return
        self.board.submit(text, session, queue_age_limit(char_limit()))

    def stop_from(self, session: str | None, prompt: str = "") -> None:
        """A prompt only silences its own session; typing /speak never stops (it may be replaying)."""
        if is_speak_command(prompt):
            return
        n = self.board.cancel_session(session) if session else self.board.cancel_all()
        if n:
            print(f"stop: session={short(session) if session else 'all'} cancelled={n}", flush=True)

    def on_worker(self, fn, wait: bool = True):
        """Run fn on the MLX worker thread ahead of queued speech; returns its result if wait."""
        task = WorkerTask(fn)
        self._tasks.put(task)
        self.board.interrupt()
        if not wait:
            return None
        if not task.done.wait(TRANSCRIBE_TIMEOUT_S):
            raise TimeoutError("the speech worker did not answer in time")
        if task.error is not None:
            raise task.error
        return task.result

    def _run_tasks(self) -> None:
        while True:
            try:
                task = self._tasks.get_nowait()
            except queue.Empty:
                return
            try:
                task.result = task.fn()
            except Exception as e:  # handed to the waiting HTTP thread
                task.error = e
            finally:
                task.done.set()

    def _load(self) -> None:
        list(self._synth("Ready.", False, MIN_SPEED))  # loads and warms up Kokoro
        self.ready.set()
        print(f"{NAME} {VERSION}: English voice loaded, Bosnian loads on first use (home {HOME})", flush=True)

    def _synth(self, chunk: str, bosnian: bool, speed: float):
        if bosnian:
            return engines.synth_bs(self.models.get("bs"), chunk, speed)
        return engines.synth_en(self.models.get("en"), chunk, speed)

    def _generate_loop(self) -> None:
        try:
            self._load()
        except Exception:  # never sit "loading" forever: exit so launchd logs it and retries
            traceback.print_exc()
            print(f"{NAME}: model load failed; exiting (re-run /speak setup)", flush=True)
            os._exit(1)
        while True:
            self._run_tasks()
            self._housekeeping()
            job = self.board.next_job(timeout=HOUSEKEEPING_EVERY_S)
            if job is None:
                continue
            audio_s = 0.0
            try:
                audio_s = self._speak_job(job)
            finally:
                self.board.finish(job, audio_s)
                engines.clear_cache()

    def _housekeeping(self) -> None:
        """Every HOUSEKEEPING_EVERY_S: rescan sessions, unload idle models (MLX thread only)."""
        now = time.monotonic()
        if now < self._next_housekeeping:
            return
        self._next_housekeeping = now + HOUSEKEEPING_EVERY_S
        self.sessions.refresh()
        self.models.sweep(unload_minutes() * 60, self.sessions.none_for(NO_SESSION_GRACE_S))

    def _speak_job(self, job: Job) -> float:
        """Generate one job's audio into the player; returns seconds of audio sent."""
        text = prepare(job.text, char_limit())
        bosnian = is_bosnian(text)
        speed = speech_speed()
        trim_log()
        print(f"reply: session={short(job.session)} engine={'omnivoice/bs' if bosnian else 'kokoro/en'} "
              f"chars={len(text)} speed={speed:g} waited={time.monotonic() - job.queued_at:.1f}s", flush=True)
        chunks = split_chunks(text, MERGE_TO["bs" if bosnian else "en"])
        started = time.monotonic()
        synth_s = audio_s = 0.0
        for chunk in chunks:
            self._run_tasks()  # a transcription waits at most one chunk
            if self.board.is_cancelled(job):
                break
            chunk_t0 = time.monotonic()
            try:
                for audio, sr in self._synth(chunk, bosnian, speed):
                    self.player.send((job.id, audio, sr, started if audio_s == 0 else None, job.expires_at))
                    audio_s += len(audio) / sr
            except Exception as e:  # keep the daemon alive on a bad chunk
                print(f"synth error: {e!r} on {chunk[:60]!r}", flush=True)
            synth_s += time.monotonic() - chunk_t0
        print(f"reply done: chunks={len(chunks)} audio={audio_s:.1f}s synth={synth_s:.1f}s", flush=True)
        return audio_s


def make_handler(speaker: Speaker):
    class Handler(LocalOnlyHandler):  # refuses requests not addressed to 127.0.0.1
        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0) or 0)
            if length > MAX_BODY_BYTES:
                return self._reply(413)
            body = self.rfile.read(length)
            path, _, query = self.path.partition("?")
            tty = parse_qs(query).get("tty", [None])[0]
            tty = tty if is_tty(tty) and self.headers.get(HOOK_HEADER) == "1" else None
            if path == "/transcribe":
                return self._transcribe(body)
            if path == "/guard":
                return self._guard(tty, body)
            if path == "/prepare":
                speaker.on_worker(lambda: speaker.models.get("stt") if stt.is_installed(HOME) else None,
                                  wait=False)
                return self._reply(204)
            text, session, prompt = parse_payload(body)
            if path == "/speak":
                speaker.speak(text.strip(), session)
            elif path == "/stop":
                speaker.stop_from(session, prompt)
            else:
                return self._reply(404)
            if tty:
                speaker.guard.clear(tty)
            self._reply(204)

        def _guard(self, tty: str | None, body: bytes):
            try:
                payload = json.loads(body or b"{}")
            except ValueError:
                payload = None
            if not tty or not isinstance(payload, dict):
                return self._reply(400)
            speaker.guard.event(tty, payload)
            self._reply(204)

        def _transcribe(self, body: bytes):
            try:
                audio = stt.decode_wav(body)
            except stt.BadAudio as e:
                return self._json(400, {"error": str(e)})
            lang, started = stt_language(), time.monotonic()
            try:
                result = speaker.on_worker(lambda: stt.transcribe(speaker.models.get("stt"), audio, lang))
            except FileNotFoundError as e:
                return self._json(503, {"error": str(e)})
            except Exception as e:  # keep the service up; the caller shows the error
                print(f"transcribe error: {e!r}", flush=True)
                return self._json(500, {"error": "transcription failed; see speakd.log"})
            print(f"transcribed {len(audio) / stt.WHISPER_RATE:.1f}s audio -> {len(result['text'])} chars "
                  f"lang={result['language']} ({lang}) in {time.monotonic() - started:.1f}s", flush=True)
            self._json(200, result)

        def do_GET(self):
            path, _, query = self.path.partition("?")
            if path == "/session":
                return self._session(parse_qs(query).get("tty", [None])[0])
            if self.path == "/config":
                return self._json(200, {"lang": stt_language(), "voice_input": stt.is_installed(HOME)})
            if self.path != "/health":
                return self._reply(404)
            ready = speaker.ready.is_set()
            ttys = [x.tty for x in speaker.sessions.sessions]
            body = json.dumps({"name": NAME, "version": VERSION, "home": HOME, "ready": ready,
                               "models": speaker.models.loaded(), "unload_minutes": unload_minutes(),
                               "voice_input": stt.is_installed(HOME),
                               "sessions": ttys, "guarded": speaker.guard.guarded(ttys)}).encode()
            self._reply(200 if ready else 503, body)

        def _session(self, tty: str | None):  # hotkey helper: one tty's scan is ~20 ms, all is ~0.2 s+
            if not is_tty(tty):
                return self._reply(400)
            is_open = runs_claude(tty)
            if is_open is None:
                return self._reply(503)
            self._json(200, {"tty": tty, "open": is_open, "guarded": tty in speaker.guard.guarded(),
                             "voice_input": stt.is_installed(HOME)})

        def _json(self, code: int, obj: dict):
            self._reply(code, json.dumps(obj).encode())

        def _reply(self, code: int, body: bytes = b""):
            self.send_response(code)
            if body:
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if body:
                self.wfile.write(body)

    return Handler


if __name__ == "__main__":
    speaker = Speaker()
    print(f"{NAME} {VERSION} listening on {HOST}:{PORT}", flush=True)
    ThreadingHTTPServer((HOST, PORT), make_handler(speaker)).serve_forever()
