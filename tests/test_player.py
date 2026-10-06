import multiprocessing as mp
import os
import sys
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "daemon"))
from jobs import CancelRing  # noqa: E402
from player import Player  # noqa: E402

ITEM = (1, b"", 24000, None, 0.0)


# Stand-ins for player_main (module level, so the spawn context can import them in the child).
def idle_player(conn, ids, cursor, busy):
    """Healthy: keeps reading and is never inside an audio call."""
    while True:
        conn.recv()


def wedged_player(conn, ids, cursor, busy):
    """Enters an audio call on the first item and never returns (the CoreAudio deadlock)."""
    conn.recv()
    busy.value = time.monotonic()
    time.sleep(3600)


def dying_player(conn, ids, cursor, busy):
    """Exits as soon as it starts."""


def wait_for(predicate, timeout=10.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    return False


class PlayerWatchdogTest(unittest.TestCase):
    def make(self, target, **kw):
        ctx = mp.get_context("spawn")
        player = Player(CancelRing.create(ctx), ctx, target=target, watch_every_s=0.05, **kw)
        self.addCleanup(player.close)
        return player

    def test_player_stuck_in_an_audio_call_is_killed_and_replaced(self):
        player = self.make(wedged_player, stall_s=0.3)
        first = player._proc
        player.send(ITEM)
        self.assertTrue(wait_for(lambda: not first.is_alive()), "the watchdog never killed the stuck player")
        player.send(ITEM)  # the broken pipe starts a new player
        self.assertEqual(player.restarts, 1)
        self.assertIsNot(player._proc, first)
        self.assertTrue(player._proc.is_alive())

    def test_idle_player_is_left_alone(self):
        player = self.make(idle_player, stall_s=0.3)
        first = player._proc
        player.send(ITEM)
        time.sleep(1.0)  # several watch periods past stall_s
        player.send(ITEM)
        self.assertIs(player._proc, first)
        self.assertTrue(first.is_alive())
        self.assertEqual(player.restarts, 0)
        self.assertEqual(player.stuck_for(), 0.0)

    def test_dead_player_is_replaced_on_the_next_send(self):
        player = self.make(dying_player)
        first = player._proc
        self.assertTrue(wait_for(lambda: not first.is_alive()))
        player.send(ITEM)
        self.assertEqual(player.restarts, 1)
        self.assertIsNot(player._proc, first)


if __name__ == "__main__":
    unittest.main()
