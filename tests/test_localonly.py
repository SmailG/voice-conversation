import http.client
import os
import sys
import threading
import unittest
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "daemon"))
from localonly import LocalOnlyHandler, is_local_host  # noqa: E402

PORT = 8765


class IsLocalHost(unittest.TestCase):
    def test_loopback_names_with_or_without_our_port(self):
        for host in ("127.0.0.1:8765", "127.0.0.1", "localhost:8765", "LOCALHOST", "[::1]:8765", "[::1]"):
            self.assertTrue(is_local_host(host, PORT), host)

    def test_no_host_header_is_allowed(self):
        self.assertTrue(is_local_host(None, PORT))

    def test_a_rebinding_pages_hostname_is_refused(self):
        for host in ("evil.example:8765", "evil.example", "127.0.0.1.evil.example:8765",
                     "localhost.evil.example", "evil.example@127.0.0.1:8765", "127.0.0.1@evil.example",
                     "127.0.0.1:8765/x", "", "  "):
            self.assertFalse(is_local_host(host, PORT), host)

    def test_another_port_or_a_bad_port_is_refused(self):
        for host in ("127.0.0.1:80", "localhost:9999", "127.0.0.1:abc", "[::1]:1"):
            self.assertFalse(is_local_host(host, PORT), host)


class Ok(LocalOnlyHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()


class Handler(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Ok)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.port = cls.server.server_address[1]

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def status(self, host):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.putrequest("GET", "/health", skip_host=True)
        conn.putheader("Host", host)
        conn.endheaders()
        status = conn.getresponse().status
        conn.close()
        return status

    def test_request_addressed_to_loopback_is_served(self):
        self.assertEqual(self.status(f"127.0.0.1:{self.port}"), 200)

    def test_request_addressed_to_another_name_is_refused(self):
        self.assertEqual(self.status(f"evil.example:{self.port}"), 403)


class DaemonUsesIt(unittest.TestCase):
    def test_the_daemons_handler_refuses_other_hosts(self):
        with open(os.path.join(os.path.dirname(__file__), "..", "daemon", "speakd.py")) as f:
            self.assertIn("class Handler(LocalOnlyHandler)", f.read())


if __name__ == "__main__":
    unittest.main()
