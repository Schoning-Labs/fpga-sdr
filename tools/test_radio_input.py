# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
"""Tests of tools/radio_input.py: its packet builder against the golden datagrams that the firmware's parser reads
(fw/tr-input/tests/golden.bin), the status reader against the board's bytes, the event queue, and a loopback exchange
with a stand-in for the board. Run from the repository root: py -m unittest tools/test_radio_input.py

The tests need neither the board nor the board loader tool, because the "board" in the last test is a UDP socket
on the local machine.  The only file they read from outside tools/ is fw/tr-input/tests/golden.bin, the byte-exact script
that the Rust test of tr-input (tests/netinput.rs) checks as well, so a change to the wire format has to show up in both."""

import os
import socket
import struct
import sys
import threading
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import radio_input as ri  # noqa: E402

GOLDEN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "fw", "tr-input", "tests", "golden.bin")


def unpack(blob):
    """Splits golden.bin into datagrams; each one is stored behind its length as a big-endian 16-bit number."""
    out, at = [], 0
    while at < len(blob):
        (n,) = struct.unpack(">H", blob[at:at + 2])
        out.append(blob[at + 2:at + 2 + n])
        at += 2 + n
    return out


class Golden(unittest.TestCase):
    """The Python packet builder must produce the same bytes as the file the firmware's tests parse."""

    def test_builder_matches_the_file_the_firmware_parser_reads(self):
        """Every datagram of golden_datagrams() equals the one stored in golden.bin, in the same order."""
        with open(GOLDEN, "rb") as f:
            golden = unpack(f.read())
        self.assertEqual(ri.golden_datagrams(), golden)

    def test_wire_bytes_fixed_by_the_doc(self):
        """A few encodings written out by hand, as docs/NETINPUT.md gives them (header, signed movement, key, wheel)."""
        self.assertEqual(ri.events_packet(1, [ri.ev_move_rel(1, -1)])[8:], bytes([1, 0, 1, 0xFF, 0xFF]))
        self.assertEqual(ri.events_packet(0x0102, [])[:8], b"TRIN\x01\x01\x01\x02")
        self.assertEqual(ri.hello_packet(0), b"TRIN\x01\x00\x00\x00")
        self.assertEqual(ri.ev_key(0x04, 0x02, True), bytes([6, 4, 2]))
        self.assertEqual(ri.ev_key(0x04, 0x02, False), bytes([7, 4, 2]))
        self.assertEqual(ri.ev_wheel(-1), bytes([5, 0xFF]))

    def test_at_most_64_events(self):
        """64 events fit in one datagram and 65 are refused."""
        ri.events_packet(1, [ri.ev_release_all()] * 64)
        with self.assertRaises(ValueError):
            ri.events_packet(1, [ri.ev_release_all()] * 65)


class Status(unittest.TestCase):
    """Reading the board's 18 byte status datagram."""

    def test_reads_what_the_board_sends(self):
        """A status built by hand decodes to the right fields, and a short, foreign or hello datagram is rejected."""
        # tr_input::Status { seq: 0xABCD, applied: 0x01020304, x: 1919, y: 1079, blocked: 7 }.encode()
        b = b"TRIN\x01\x02" + bytes([0xAB, 0xCD, 1, 2, 3, 4]) + struct.pack(">HHH", 1919, 1079, 7)
        self.assertEqual(ri.parse_status(b), {"seq": 0xABCD, "applied": 0x01020304, "x": 1919, "y": 1079, "blocked": 7})
        self.assertIsNone(ri.parse_status(b[:-1]))
        self.assertIsNone(ri.parse_status(b"XXXX" + b[4:]))
        self.assertIsNone(ri.parse_status(ri.hello_packet()))


class Queue(unittest.TestCase):
    """The event queue that sits between the window and the sender."""

    def test_moves_are_merged_and_buttons_keep_their_place(self):
        """Runs of relative movement collapse into one, but a button between two movements keeps them apart and in order."""
        q = ri.EventQueue()
        q.move_rel(3, 4)
        q.move_rel(-1, 1)
        q.button(0, True)
        q.move_rel(0, 5)
        q.button(0, False)
        q.wheel(2)
        self.assertEqual(q.take(), [ri.ev_move_rel(2, 5), ri.ev_button(0, True), ri.ev_move_rel(0, 5),
                                    ri.ev_button(0, False), ri.ev_wheel(2)])
        self.assertEqual(len(q), 0)

    def test_big_movement_is_split_and_absolute_replaces_absolute(self):
        """Two movements whose sum would not fit in 16 bits stay two events, and the latest absolute position wins (limited to the screen)."""
        q = ri.EventQueue()
        q.move_rel(30000, 0)
        q.move_rel(30000, 0)
        self.assertEqual(q.take(), [ri.ev_move_rel(30000, 0), ri.ev_move_rel(30000, 0)])
        q.move_abs(10, 10)
        q.move_abs(5000, -5)
        self.assertEqual(q.take(), [ri.ev_move_abs(1919, 0)])

    def test_keys_modifiers_and_auto_repeat(self):
        """Shift is part of the modifier mask while it is held, a repeated press is dropped, an unknown key is dropped,
        and release_all forgets held keys so that the next press of the same key counts again."""
        q = ri.EventQueue()
        self.assertTrue(q.key("Shift_L", 16, True))
        self.assertTrue(q.key("a", 0x41, True))
        self.assertFalse(q.key("a", 0x41, True), "auto-repeat is dropped")
        self.assertTrue(q.key("a", 0x41, False))
        self.assertTrue(q.key("Shift_L", 16, False))
        self.assertFalse(q.key("Menu", 0xFFFF, True), "a key without a usage is dropped")
        self.assertEqual(q.take(), [ri.ev_key(0xE1, 0x02, True), ri.ev_key(0x04, 0x02, True), ri.ev_key(0x04, 0x02, False),
                                    ri.ev_key(0xE1, 0x00, False)])
        q.key("a", 0x41, True)
        q.release_all()
        q.key("a", 0x41, True)
        self.assertEqual(q.take()[1:], [ri.ev_release_all(), ri.ev_key(0x04, 0, True)])

    def test_usage_table(self):
        """Spot checks of the virtual-key to USB HID table: letters, digits, Enter, Esc, F12, arrows, number pad, punctuation, right Ctrl."""
        u = ri.key_usage
        self.assertEqual(u("a", 0x41), 0x04)
        self.assertEqual(u("z", 0x5A), 0x1D)
        self.assertEqual(u("1", 0x31), 0x1E)
        self.assertEqual(u("0", 0x30), 0x27)
        self.assertEqual(u("Return", 0x0D), 0x28)
        self.assertEqual(u("Escape", 0x1B), 0x29)
        self.assertEqual(u("F12", 0x7B), 0x45)
        self.assertEqual(u("Left", 0x25), 0x50)
        self.assertEqual(u("KP_1", 0x61), 0x59)
        self.assertEqual(u("KP_0", 0x60), 0x62)
        self.assertEqual(u("bracketleft", 0xDB), 0x2F)
        self.assertEqual(u("Control_R", 17), 0xE4)
        self.assertIsNone(u("Menu", 0xFFFF))


class Loopback(unittest.TestCase):
    """The sending side of the script against a socket on this machine that plays the board."""

    def test_hello_discovery_and_events_against_a_stand_in_board(self):
        """The stand-in answers a hello with a status, discover() finds it, and then the datagrams for one queued
        movement and button and one empty heartbeat arrive in order with consecutive sequence numbers."""
        board = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        board.bind(("127.0.0.1", 0))
        board.settimeout(5)
        port = board.getsockname()[1]
        got = []

        def run():
            """The stand-in board: records the first three datagrams and answers each hello with an all-zero status."""
            try:
                while len(got) < 3:
                    data, src = board.recvfrom(2048)
                    got.append(data)
                    if data[5] == ri.KIND_HELLO:
                        board.sendto(b"TRIN\x01\x02" + bytes(12), src)
            except OSError:
                pass

        t = threading.Thread(target=run)
        t.start()
        # The script sends its hellos to the module's PORT, so it is pointed at the stand-in for the test and put back afterwards.
        saved = ri.PORT
        ri.PORT = port
        try:
            sock = ri.open_socket()
            found = ri.discover(sock, "127.0.0.1", 3.0)
            self.assertIsNotNone(found)
            self.assertEqual(found[0], "127.0.0.1")
            sender = ri.Sender(sock, ("127.0.0.1", port))
            q = ri.EventQueue()
            q.move_rel(7, 8)
            q.button(0, True)
            sender.send_queue(q)
            sender.send_events([])
        finally:
            ri.PORT = saved
        t.join(6)
        board.close()
        self.assertEqual(got[0], ri.hello_packet(0))
        self.assertEqual(got[1][8:], ri.ev_move_rel(7, 8) + ri.ev_button(0, True))
        self.assertEqual(got[2][8:], b"")
        self.assertEqual(struct.unpack(">H", got[2][6:8])[0], (struct.unpack(">H", got[1][6:8])[0] + 1) & 0xFFFF)


if __name__ == "__main__":
    unittest.main()
