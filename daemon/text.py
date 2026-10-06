"""Text preparation for speech: markdown cleanup, length limit, language routing, chunking.

Pure functions (stdlib only) so they can be unit-tested without the audio stack.
"""

import json
import re

CONTROL_MARKER = "[speak]"  # speakctl output prefix; replies starting with it are never spoken
# Typing /speak (or its plugin-qualified form /voice-conversation:speak) may start a replay, so
# its own UserPromptSubmit must not stop speech. "/speaker" or "/x:speakers" are other commands.
SPEAK_COMMAND = re.compile(r"/(?:[\w.-]+:)?speak(?:\s|$)")

# Chunking: Kokoro reads ~15% faster when given a whole paragraph, so English gets
# sentence-sized chunks (short sentences merged up to ~60 chars). OmniVoice re-reads the voice reference on every call, so short sentences are
# merged up to ~160 chars to stay ahead of realtime playback. The first chunk stays one
# sentence so speech starts quickly.
CHUNK_MAX = 220
MERGE_TO = {"en": 60, "bs": 160}
FIRST_MERGE_TO = 40

BS_WORDS = {"je", "sam", "da", "se", "nije", "što", "su", "na", "za", "od", "to",
            "li", "ali", "kao", "ako", "sada", "samo", "jer", "treba", "sve", "ovo",
            "svi", "gotovo", "nema", "može", "bio", "već", "još", "ili", "kad", "gdje",
            "koji", "koja", "ovdje", "nisam", "jesam", "hoćeš", "evo", "nešto", "prolaze"}
EN_WORDS = {"the", "is", "and", "to", "of", "in", "it", "that", "for", "this",
            "with", "are", "not", "you", "be", "was", "have", "on"}
BS_CHARS = set("čćžšđČĆŽŠĐ")


def clean_markdown(text: str) -> str:
    """Drop what shouldn't be read aloud: code blocks, tables, URLs, paths, markup."""
    text = re.sub(r"```.*?```", " ", text, flags=re.S)
    text = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("|"))
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)            # [label](url) -> label
    text = re.sub(r"https?://\S+", " ", text)
    text = re.sub(r"`([^`]*/[^`]*)`", " ", text)                     # `paths/with/slashes`
    text = re.sub(r"`([^`]*)`", r"\1", text)
    text = re.sub(r"^\s*(#+|[-*+]|\d+\.)\s+", "", text, flags=re.M)  # headings, bullets
    text = re.sub(r"[*_~>#]", "", text)
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r" *\n *", "\n", text)       # no stray spaces around line breaks
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def truncate(text: str, limit: int) -> str:
    """Cut to `limit` chars, preferably at a sentence end."""
    if len(text) <= limit:
        return text
    cut = text[:limit]
    end = max(cut.rfind(". "), cut.rfind("! "), cut.rfind("? "), cut.rfind("\n"))
    return cut[: end + 1] if end > limit // 3 else cut


def is_bosnian(text: str) -> bool:
    """Per-reply heuristic: Bosnian/Croatian/Serbian stopwords and diacritics vs English."""
    words = re.findall(r"[a-zčćžšđ]+", text.lower())
    if not words:
        return False
    bs = sum(w in BS_WORDS for w in words) + sum(any(c in BS_CHARS for c in w) for w in words)
    en = sum(w in EN_WORDS for w in words)
    return bs >= 1 if en == 0 else (bs > 1.2 * en and bs >= 2)


def _pack(parts: list[str], merge_to: int, first_merge_to: int | None = None) -> list[str]:
    """Greedily join parts while the running chunk is shorter than merge_to."""
    chunks: list[str] = []
    for p in parts:
        limit = first_merge_to if first_merge_to is not None and len(chunks) == 1 else merge_to
        if chunks and len(chunks[-1]) < limit and len(chunks[-1]) + len(p) + 1 <= CHUNK_MAX:
            chunks[-1] = f"{chunks[-1]} {p}"
        else:
            chunks.append(p)
    return chunks


def split_long(sentence: str) -> list[str]:
    """Break a sentence over CHUNK_MAX at clause marks, then at spaces as a last resort."""
    if len(sentence) <= CHUNK_MAX:
        return [sentence]
    clauses = [c for c in re.split(r"(?<=[,;])\s+|\s+[—–]\s+", sentence) if c]
    out: list[str] = []
    for c in _pack(clauses, CHUNK_MAX):
        while len(c) > CHUNK_MAX:
            cut = c.rfind(" ", 0, CHUNK_MAX)
            cut = cut if cut > 0 else CHUNK_MAX
            out.append(c[:cut])
            c = c[cut:].strip()
        out.append(c)
    return out


def split_chunks(text: str, merge_to: int) -> list[str]:
    sentences = [s.strip() for s in re.split(r"(?<=[.!?:])\s+|\n+", text) if s.strip()]
    return _pack([p for s in sentences for p in split_long(s)], merge_to, FIRST_MERGE_TO)


def parse_payload(payload: bytes) -> tuple[str, str | None, str]:
    """Return (reply text, session_id, prompt) from a hook payload; plain text is accepted too."""
    try:
        data = json.loads(payload) if payload else {}
        if not isinstance(data, dict):
            raise ValueError("payload is not an object")
        text = data.get("last_assistant_message") or data.get("text") or ""
        return text, data.get("session_id"), data.get("prompt") or ""
    except (ValueError, AttributeError):
        return payload.decode("utf-8", "replace"), None, ""


def prepare(text: str, limit: int) -> str:
    """Clean and cut a reply; limit 0 means no limit."""
    text = clean_markdown(text)
    return truncate(text, limit) if limit > 0 else text


def is_speak_command(prompt: str) -> bool:
    """True for a prompt that invokes the /speak skill, plain or plugin-qualified."""
    return SPEAK_COMMAND.match(prompt.lstrip()) is not None
