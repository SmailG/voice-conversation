import multiprocessing as mp
import os
import sys
import threading
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "daemon"))
from jobs import CancelRing  # noqa: E402
from player import Player  # noqa: E402

BIG = b"\0" * (4 * 1024 * 1024)  # far larger than a pipe buffer: send blocks unless someone reads


def item(job_id, payload=b""):
    return (job_id, payload, 24000, None, 0.0)


# Stand-ins for player_main (module level, so the spawn context can import them in the child).
# Each clears the parent's startup deadline once "started", as player_main does after its imports.
def brief_calls_player(conn, ids, cursor, deadline):
    """Healthy: every item is one short audio call that ends well within its deadline."""
    deadline.value = 0.0
    while True:
        conn.recv()
        deadline.value = time.monotonic() + 0.5
        time.sleep(0.2)
        deadline.value = 0.0


def wedged_player(conn, ids, cursor, deadline):
    """Enters an audio call on the first item and never returns (the CoreAudio deadlock)."""
    deadline.value = 0.0
    conn.recv()
    deadline.value = time.monotonic() + 0.3
    time.sleep(3600)


def hung_at_startup_player(conn, ids, cursor, deadline):
    """Never finishes starting and never reads: only the parent's startup deadline can catch it."""
    time.sleep(3600)


def dying_player(conn, ids, cursor, deadline):
    """Exits as soon as it starts."""


def wait_for(predicate, timeout=10.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    return False


def send_with_timeout(player, it, timeout=10.0):
    """send() in a thread: a regression that blocks forever fails the test instead of hanging it.

    Returns None when send returned normally, else what went wrong.
    """
    errors = []

    def run():
        try:
            player.send(it)
        except Exception as e:  # reported to the test, not lost in the thread
            errors.append(e)

    t = threading.Thread(target=run, daemon=True)
    t.start()
    t.join(timeout)
    if t.is_alive():
        return "send blocked"
    return repr(errors[0]) if errors else None


class PlayerWatchdogTest(unittest.TestCase):
    def make(self, target, startup_s=5.0):
        ctx = mp.get_context("spawn")
        ring = CancelRing.create(ctx)
        player = Player(ring, ctx, target=target, startup_s=startup_s, watch_every_s=0.05)
        self.addCleanup(player.close)
        return player, ring

    def test_player_stuck_in_an_audio_call_is_killed_and_replaced(self):
        player, _ = self.make(wedged_player)
        first = player._child
        player.send(item(1))
        self.assertTrue(wait_for(lambda: not first.proc.is_alive()), "the watchdog never killed it")
        player.send(item(2))  # the broken pipe starts a new player
        self.assertEqual(player.restarts, 1)
        self.assertIsNot(player._child, first)
        self.assertTrue(player._child.proc.is_alive())

    def test_player_hung_at_startup_cannot_block_send(self):
        player, _ = self.make(hung_at_startup_player, startup_s=0.5)
        # The replacement hangs too, as it would while CoreAudio stays wedged: send must still return.
        self.assertIsNone(send_with_timeout(player, item(1, BIG)))
        self.assertGreaterEqual(player.restarts, 1)
        self.assertIsNone(send_with_timeout(player, item(2, BIG)))  # and keeps returning

    def test_healthy_player_making_short_calls_is_left_alone(self):
        player, _ = self.make(brief_calls_player)
        first = player._child
        for job in range(1, 5):  # spans many watch periods, each with a call in progress
            player.send(item(job))
            time.sleep(0.3)
        self.assertIs(player._child, first)
        self.assertTrue(first.proc.is_alive())
        self.assertEqual(player.restarts, 0)

    def test_dead_player_is_replaced_on_the_next_send(self):
        player, _ = self.make(dying_player)
        first = player._child
        self.assertTrue(wait_for(lambda: not first.proc.is_alive()))
        player.send(item(1))
        self.assertEqual(player.restarts, 1)
        self.assertIsNot(player._child, first)

    def test_reply_interrupted_by_a_kill_is_dropped_not_resumed(self):
        player, ring = self.make(wedged_player)
        first = player._child
        player.send(item(7))
        self.assertTrue(wait_for(lambda: not first.proc.is_alive()))
        player.send(item(7))  # the rest of the same reply
        self.assertIn(7, ring)
        player.send(item(8))  # the next reply still goes to the new player
        self.assertNotIn(8, ring)

    def test_overdue_is_zero_once_the_player_is_gone(self):
        player, _ = self.make(wedged_player)
        player.send(item(1))
        self.assertTrue(wait_for(lambda: not player.is_alive()))
        self.assertEqual(player.overdue_s(), 0.0)


if __name__ == "__main__":
    unittest.main()
