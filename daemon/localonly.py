"""HTTP handler base for the daemon: answers only requests addressed to this machine.

The service listens on 127.0.0.1, but a web page can still reach it through DNS rebinding: its
own hostname re-resolves to 127.0.0.1, so the browser treats the page and the service as one
origin and lets it send any header (the X-Voice-Conversation-Hook check included) and read
replies. Such a request still carries the page's hostname in its Host header, so a Host that
isn't a loopback name is refused before any endpoint runs.
"""
from http.server import BaseHTTPRequestHandler
from urllib.parse import urlsplit

LOOPBACK_NAMES = frozenset({"127.0.0.1", "localhost", "::1"})
FORBIDDEN = 403


def is_local_host(host: str | None, port: int) -> bool:
    """True for a Host header naming this machine's loopback (port optional, but ours if given).
    No Host at all (HTTP/1.0) is allowed: browsers always send one."""
    if host is None:
        return True
    try:
        parts = urlsplit("//" + host.strip())
        given = parts.port
    except ValueError:  # a port that isn't a number
        return False
    return (parts.hostname in LOOPBACK_NAMES and given in (None, port)
            and parts.username is None and not parts.path and not parts.query)


class LocalOnlyHandler(BaseHTTPRequestHandler):
    def parse_request(self) -> bool:
        if not super().parse_request():
            return False
        if is_local_host(self.headers.get("Host"), getattr(self.server, "server_port", 0)):
            return True
        self.send_error(FORBIDDEN, "requests must be addressed to 127.0.0.1")
        return False

    def log_message(self, format, *args):  # silence per-request logging
        pass
