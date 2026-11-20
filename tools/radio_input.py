# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
"""Controls the radio's own screen with this PC's mouse and keyboard over the home network (docs/NETINPUT.md).

The radio has no mouse or keyboard of its own, so this script plays the part of one: it turns the mouse movement, buttons, wheel
and key presses in a small window on the PC into UDP datagrams (port 21600, magic bytes "TRIN") that the firmware's tr-input crate
(fw/tr-input) reads and feeds to the radio's graphical interface on the HDMI screen.  The firmware has to be running already
(tools/radio_start.py loads it), the board and the PC have to be on the same home network, and nothing else is needed from the
board loader tool.

Standard library only (tkinter, socket, ctypes), written for Windows 11 and Python 3.10.  The ctypes calls (ClipCursor, SetCursorPos)
exist only on Windows, so on another system the window still works but the pointer is not held inside it.

    py tools/radio_input.py                  finds the board by a broadcast hello, opens the capture window
    py tools/radio_input.py --ip 192.168.2.160
    py tools/radio_input.py --probe          only asks the board and prints its answer

Click into the window: the mouse and keyboard are captured and everything goes to the radio's HDMI screen. Esc and F12
together release them. The radio never transmits from the network: keys that mean transmit or answer on the radio
(t c s u 0-9 - + =) are dropped by the board, and so are the screen's own transmit buttons while the network is in use.
The script itself sends every key it has a code for, because the filtering is done by the board.
"""

import argparse
import random
import socket
import struct
import sys
import time

# UDP port the board listens on (the same number as tr_input::UDP_PORT in fw/tr-input/src/lib.rs).
PORT = 21600
# Every datagram starts with these four bytes, a version byte, a kind byte and a 16-bit sequence number (see header()).
MAGIC = b"TRIN"
VERSION = 1
# The three kinds of datagram: hello (the PC asks), events (the PC sends input), status (the board answers).
KIND_HELLO, KIND_EVENTS, KIND_STATUS = 0, 1, 2
# Size of the radio's HDMI screen in pixels, which is also the range of the absolute pointer position.
SCREEN_W, SCREEN_H = 1920, 1080
MAX_EVENTS = 64  # per datagram
STATUS_LEN = 18  # the board's status datagram is always this many bytes

BTN_LEFT, BTN_RIGHT, BTN_MIDDLE = 0, 1, 2

FLUSH_MS = 40  # mouse movement is merged and sent this often
HEARTBEAT_MS = 250  # an empty events datagram keeps the link alive, because the board lets go of held buttons after 3 s of silence
STATUS_POLL_MS = 100  # the status check runs every 5 times this, so every half second


# ---------------------------------------------------------------------------------------------------------------
# Packets (the same bytes as fw/tr-input; tests/golden.bin is the common check)
# ---------------------------------------------------------------------------------------------------------------

def header(kind, seq):
    """The 8 bytes that start every datagram: magic, version, kind and a big-endian 16-bit sequence number."""
    return MAGIC + bytes([VERSION, kind]) + struct.pack(">H", seq & 0xFFFF)


def ev_move_rel(dx, dy):
    """Event 0x01, pointer movement by (dx, dy) pixels, each a big-endian signed 16-bit number."""
    return b"\x01" + struct.pack(">hh", dx, dy)


def ev_move_abs(x, y):
    """Event 0x02, pointer jumps to screen position (x, y), each a big-endian unsigned 16-bit number."""
    return b"\x02" + struct.pack(">HH", x, y)


def ev_button(button, down):
    """Event 0x03 (pressed) or 0x04 (released) for a mouse button (BTN_LEFT, BTN_RIGHT or BTN_MIDDLE)."""
    return bytes([0x03 if down else 0x04, button])


def ev_wheel(delta):
    """Event 0x05, wheel steps as a signed byte, taken from the PC's wheel direction unchanged."""
    return b"\x05" + struct.pack(">b", delta)


def ev_key(usage, mods, down):
    """Event 0x06 (pressed) or 0x07 (released) for a key, given as a USB HID usage code plus the modifier bit mask."""
    return bytes([0x06 if down else 0x07, usage, mods])


def ev_release_all():
    """Event 0x08, which tells the board to let go of every button and key it thinks is held."""
    return b"\x08"


def hello_packet(seq=0):
    """The datagram that asks the board for a status answer, which it sends back to the address the hello came from."""
    return header(KIND_HELLO, seq)


def events_packet(seq, events):
    """A datagram that carries up to MAX_EVENTS already encoded events behind the header."""
    if len(events) > MAX_EVENTS:
        raise ValueError("at most %d events per datagram" % MAX_EVENTS)
    return header(KIND_EVENTS, seq) + b"".join(events)


def parse_status(data):
    """The board's answer as a dict, or None if the datagram is not one."""
    if len(data) != STATUS_LEN or data[:4] != MAGIC or data[4] != VERSION or data[5] != KIND_STATUS:
        return None
    seq, applied, x, y, blocked = struct.unpack(">HIHHH", data[6:18])
    return {"seq": seq, "applied": applied, "x": x, "y": y, "blocked": blocked}


def golden_datagrams():
    """A fixed script of datagrams that covers every event kind and the extreme values, which fw/tr-input/tests/netinput.rs
    (golden_script) builds in the same way; tests/golden.bin holds the expected bytes, so the two implementations stay identical."""
    return [
        hello_packet(0),
        events_packet(1, [ev_move_rel(5, -3), ev_move_rel(-300, 200), ev_wheel(-1)]),
        events_packet(2, [ev_move_abs(1919, 1079), ev_button(0, True), ev_button(0, False), ev_button(1, True),
                          ev_button(1, False), ev_button(2, True), ev_button(2, False)]),
        events_packet(3, [ev_key(0x04, 0x02, True), ev_key(0x04, 0x02, False), ev_key(0x28, 0, True),
                          ev_key(0x28, 0, False), ev_key(0x17, 0, True)]),
        events_packet(4, []),
        events_packet(30000, [ev_release_all(), ev_move_rel(-32768, 32767)]),
    ]


# ---------------------------------------------------------------------------------------------------------------
# Keys: Windows virtual-key codes (tkinter's event.keycode) and key names to USB HID usages
# ---------------------------------------------------------------------------------------------------------------

# Modifier bit mask of the HID keyboard report (left Ctrl, Shift, Alt, GUI in bits 0 to 3, the right-hand keys in bits 4 to 7),
# which is sent along with every key event, and the HID usage codes of those same keys (0xE0 to 0xE7).
MOD_BITS = {"Control_L": 0x01, "Shift_L": 0x02, "Alt_L": 0x04, "Win_L": 0x08, "Control_R": 0x10, "Shift_R": 0x20,
            "Alt_R": 0x40, "Win_R": 0x80}
MOD_USAGE = {"Control_L": 0xE0, "Shift_L": 0xE1, "Alt_L": 0xE2, "Win_L": 0xE3, "Control_R": 0xE4, "Shift_R": 0xE5,
             "Alt_R": 0xE6, "Win_R": 0xE7}

# Windows virtual-key code (what tkinter reports as event.keycode) to USB HID usage code.  The table is the
# literal keys first and the loops below add the letters, digits, function keys and number pad digits.
_VK = {
    0x0D: 0x28, 0x1B: 0x29, 0x08: 0x2A, 0x09: 0x2B, 0x20: 0x2C,   # Enter, Esc, Backspace, Tab, Space
    0xBD: 0x2D, 0xBB: 0x2E, 0xDB: 0x2F, 0xDD: 0x30, 0xDC: 0x31,   # - = [ ] \
    0xBA: 0x33, 0xDE: 0x34, 0xC0: 0x35, 0xBC: 0x36, 0xBE: 0x37, 0xBF: 0x38,   # ; ' ` , . /
    0xE2: 0x64,                                                    # the key next to the left Shift on a 102-key board
    0x2D: 0x49, 0x24: 0x4A, 0x21: 0x4B, 0x2E: 0x4C, 0x23: 0x4D, 0x22: 0x4E,   # Insert Home PgUp Delete End PgDn
    0x27: 0x4F, 0x25: 0x50, 0x28: 0x51, 0x26: 0x52,                # Right Left Down Up
    0x6F: 0x54, 0x6A: 0x55, 0x6D: 0x56, 0x6B: 0x57, 0x6E: 0x63,   # number pad / * - + .
}
for _i in range(26):
    _VK[0x41 + _i] = 0x04 + _i                       # A-Z
for _i in range(9):
    _VK[0x31 + _i] = 0x1E + _i                       # 1-9
_VK[0x30] = 0x27                                     # 0
for _i in range(12):
    _VK[0x70 + _i] = 0x3A + _i                       # F1-F12
for _i in range(1, 10):
    _VK[0x60 + _i] = 0x58 + _i                       # number pad 1-9
_VK[0x60] = 0x62                                     # number pad 0


def key_usage(keysym, keycode):
    """The HID usage for a tkinter key event, or None for a key the radio has no use for.

    Modifier keys are recognized by their tkinter key name, because left and right versions share one virtual-key code on Windows.
    """
    if keysym in MOD_USAGE:
        return MOD_USAGE[keysym]
    return _VK.get(keycode)


# ---------------------------------------------------------------------------------------------------------------
# What waits to be sent
# ---------------------------------------------------------------------------------------------------------------

def clamp16(v):
    """Limits a number to the range of a signed 16-bit field."""
    return max(-32768, min(32767, v))


class EventQueue:
    """Events in the order they happened; runs of mouse movement are merged into one.

    Movement is kept as plain numbers until take() encodes it, so that many small mouse moves between two sends cost one event
    and not dozens.  Buttons, wheel and keys are kept already encoded, since they must never be merged or reordered.
    """

    def __init__(self):
        self.items = []  # ("rel", dx, dy) | ("abs", x, y) | ("raw", bytes)
        self.pressed_keys = set()  # HID usages that are held now, used to drop the PC's auto-repeat
        self.mods = 0  # modifier bit mask of the keys held now

    def __len__(self):
        return len(self.items)

    def move_rel(self, dx, dy):
        """Relative movement; it is added to the movement already at the end of the queue, as long as the sum fits in 16 bits."""
        if dx == 0 and dy == 0:
            return
        if self.items and self.items[-1][0] == "rel":
            _, ox, oy = self.items[-1]
            nx, ny = ox + dx, oy + dy
            if abs(nx) <= 32767 and abs(ny) <= 32767:
                self.items[-1] = ("rel", nx, ny)
                return
        self.items.append(("rel", dx, dy))

    def move_abs(self, x, y):
        """Absolute position, limited to the screen; a newer position replaces an older one still waiting at the end of the queue."""
        x = max(0, min(SCREEN_W - 1, x))
        y = max(0, min(SCREEN_H - 1, y))
        if self.items and self.items[-1][0] == "abs":
            self.items[-1] = ("abs", x, y)
        else:
            self.items.append(("abs", x, y))

    def button(self, button, down):
        """Queues a mouse button press or release."""
        self.items.append(("raw", ev_button(button, down)))

    def wheel(self, delta):
        """Queues wheel steps (limited to one signed byte); a zero delta queues nothing."""
        delta = max(-127, min(127, delta))
        if delta:
            self.items.append(("raw", ev_wheel(delta)))

    def key(self, keysym, keycode, down):
        """A key press or release from the window. Auto-repeat (a press of a key already down) is dropped.

        Returns True when an event was queued.  The modifier mask that goes out with the event already includes a modifier that
        is pressed by this very event, and no longer includes one that is released by it.
        """
        usage = key_usage(keysym, keycode)
        if usage is None:
            return False
        bit = MOD_BITS.get(keysym, 0)
        if down:
            if usage in self.pressed_keys:
                return False
            self.pressed_keys.add(usage)
            self.mods |= bit
        else:
            self.pressed_keys.discard(usage)
            self.mods &= ~bit & 0xFF
        self.items.append(("raw", ev_key(usage, self.mods, down)))
        return True

    def release_all(self):
        """Forgets every held key and queues the release-all event, which is what happens when the window lets go of the mouse and keyboard."""
        self.pressed_keys.clear()
        self.mods = 0
        self.items.append(("raw", ev_release_all()))

    def take(self, limit=MAX_EVENTS):
        """Removes up to `limit` events from the front of the queue and returns them encoded.

        Merging stops before a summed movement would pass 16 bits, so a long movement leaves as several events, and
        the clamp here is only a safety net for movements added to the queue in some other way.
        """
        out = []
        while self.items and len(out) < limit:
            item = self.items.pop(0)
            if item[0] == "raw":
                out.append(item[1])
            elif item[0] == "rel":
                out.append(ev_move_rel(clamp16(item[1]), clamp16(item[2])))
            else:
                out.append(ev_move_abs(item[1], item[2]))
        return out


class Sender:
    """Numbers the datagrams and sends them from one socket (which the board's answers come back to)."""

    def __init__(self, sock, addr):
        self.sock = sock
        self.addr = addr
        # A random start keeps a second run of the script from reusing the sequence numbers of the first one,
        # which the board could take for old datagrams arriving again.
        self.seq = random.randrange(1, 0x4000)
        self.last_sent = 0.0  # time of the last events datagram, so the window knows when a heartbeat is due

    def send_events(self, events):
        """Sends one events datagram with the next sequence number (an empty list is the heartbeat)."""
        self.seq = (self.seq + 1) & 0xFFFF
        self.sock.sendto(events_packet(self.seq, events), self.addr)
        self.last_sent = time.monotonic()

    def send_queue(self, queue):
        """Sends everything waiting in the queue, in datagrams of at most MAX_EVENTS events."""
        while len(queue):
            self.send_events(queue.take())

    def hello(self):
        """Sends a hello with the current sequence number (it does not advance the number)."""
        self.sock.sendto(hello_packet(self.seq), self.addr)


# ---------------------------------------------------------------------------------------------------------------
# Finding the board
# ---------------------------------------------------------------------------------------------------------------

def local_broadcasts():
    """255.255.255.255 and the /24 broadcast address of each of this PC's addresses.

    The /24 guess (last byte 255) is right for an ordinary home network, and the global broadcast is there for the case that it is not.
    Loopback and link-local addresses are skipped because the board is never on them.
    """
    out = ["255.255.255.255"]
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if ip.startswith("127.") or ip.startswith("169.254."):
                continue
            b = ip.rsplit(".", 1)[0] + ".255"
            if b not in out:
                out.append(b)
    except OSError:
        pass
    return out


def open_socket():
    """A UDP socket that may send broadcasts, bound to any free local port (the board answers to that port)."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.bind(("", 0))
    return s


def discover(sock, ip=None, timeout=5.0, stats=None, interval=0.5):
    """Sends a hello (to `ip`, or broadcast) every `interval` s until the board answers. Returns (ip, status) or None.
    `stats`, if given, is filled with what happened: hellos sent, targets, datagrams that were not a status,
    and socket errors (which main() prints when nothing answered, so that a firewall or a wrong network can be told apart)."""
    targets = [ip] if ip else local_broadcasts()
    if stats is None:
        stats = {}
    stats.update({"targets": targets, "hellos": 0, "other": [], "errors": []})
    deadline = time.monotonic() + timeout
    sock.settimeout(0.1)
    next_hello = 0.0
    while time.monotonic() < deadline:
        if time.monotonic() >= next_hello:
            for t in targets:
                try:
                    sock.sendto(hello_packet(0), (t, PORT))
                except OSError as e:
                    if str(e) not in stats["errors"]:
                        stats["errors"].append(str(e))
            stats["hellos"] += 1
            next_hello = time.monotonic() + interval
        try:
            data, src = sock.recvfrom(2048)
        except socket.timeout:
            continue
        except OSError as e:
            if str(e) not in stats["errors"]:
                stats["errors"].append(str(e))
            continue
        st = parse_status(data)
        if st is not None:
            return src[0], st
        stats["other"].append((src[0], len(data)))
    return None


# ---------------------------------------------------------------------------------------------------------------
# The capture window
# ---------------------------------------------------------------------------------------------------------------

def run_window(sock, board_ip, first_status, absolute, speed):
    """Opens the capture window and runs it until it is closed.

    Two modes exist.  In relative mode (the default) the real pointer is hidden, held inside the window and put back to the
    window's center after every move, and the distance it moved (times `speed`) is sent, like a mouse on a desk.  In absolute
    mode the pointer's place inside the window is scaled to the 1920 x 1080 screen and sent as a position.  The window sends
    queued events every FLUSH_MS, a heartbeat when it is quiet, and asks for the board's status now and then.
    """
    import tkinter as tk
    import ctypes

    user32 = ctypes.windll.user32 if hasattr(ctypes, "windll") else None
    queue = EventQueue()
    sender = Sender(sock, (board_ip, PORT))
    sock.setblocking(False)

    root = tk.Tk()
    root.geometry("640x400")
    root.configure(bg="#202428")
    # captured: the window owns mouse and keyboard.  status and last_status_t: the board's latest answer and when it came.
    # frac: the part of a pointer move that was too small to send yet (pixels times speed are not whole numbers).
    # ignore_motion: motion events still to be skipped that were caused by our own SetCursorPos back to the center.
    # esc and f12: whether each key is held now, since both together release the capture.
    state = {"captured": False, "status": first_status, "last_status_t": time.monotonic(), "frac": [0.0, 0.0],
             "ignore_motion": 0, "esc": False, "f12": False}
    abs_var = tk.BooleanVar(value=absolute)

    label = tk.Label(root, bg="#202428", fg="#d8dde2", font=("Segoe UI", 12), justify="left")
    label.pack(fill="both", expand=True)
    check = tk.Checkbutton(root, text="Absolute pointer (the window is the screen)", variable=abs_var, bg="#202428",
                           fg="#d8dde2", selectcolor="#202428", activebackground="#202428", activeforeground="#d8dde2")
    check.pack(side="bottom", anchor="w")

    def center():
        """Screen coordinates of the middle of the label, where the pointer is parked in relative mode."""
        root.update_idletasks()
        return (root.winfo_rootx() + label.winfo_width() // 2, root.winfo_rooty() + label.winfo_height() // 2)

    def clip(on):
        """Confines the Windows pointer to the label (on) or frees it again (off); does nothing where ctypes has no windll."""
        if user32 is None:
            return
        if on:
            rect = (ctypes.c_long * 4)(root.winfo_rootx(), root.winfo_rooty(), root.winfo_rootx() + label.winfo_width(),
                                       root.winfo_rooty() + label.winfo_height())
            user32.ClipCursor(rect)
        else:
            user32.ClipCursor(None)

    def show():
        """Redraws the window title and text from the capture state and the board's latest status."""
        st = state["status"]
        if st:
            line = "board %s   datagrams applied %d   pointer %d,%d   transmit keys dropped %d" % (
                board_ip, st["applied"], st["x"], st["y"], st["blocked"])
        else:
            line = "board %s   no answer yet" % board_ip
        if time.monotonic() - state["last_status_t"] > 5.0:
            line += "   (no status for %d s: the board is busy or the network drops datagrams)" % (time.monotonic() - state["last_status_t"])
        if state["captured"]:
            root.title("Radio input - captured, Esc+F12 to release")
            head = "Captured. Esc and F12 together release the mouse and keyboard."
        else:
            root.title("Radio input - click to capture")
            head = "Click here to capture the mouse and keyboard."
        label.config(text=head + "\n\n" + line + "\n\nThe radio never transmits from here: t c s u 0-9 - + = are dropped.")

    def capture():
        """Starts capturing: in relative mode it hides the pointer, clips it to the window and parks it in the center."""
        if state["captured"]:
            return
        state["captured"] = True
        state["esc"] = state["f12"] = False
        if not abs_var.get():
            root.config(cursor="none")
            label.config(cursor="none")
            clip(True)
            cx, cy = center()
            if user32:
                user32.SetCursorPos(cx, cy)
            state["ignore_motion"] = 2
        show()

    def release():
        """Ends capturing, frees the pointer and tells the board to release every held button and key."""
        if not state["captured"]:
            return
        state["captured"] = False
        clip(False)
        root.config(cursor="")
        label.config(cursor="")
        queue.release_all()
        show()

    # tkinter numbers the buttons 1 left, 2 middle, 3 right.
    buttons = {1: BTN_LEFT, 2: BTN_MIDDLE, 3: BTN_RIGHT}

    def on_click(e):
        """The first click only captures; later clicks are sent as button presses (in absolute mode the position goes first)."""
        if not state["captured"]:
            capture()
            return
        if e.num in buttons:
            if abs_var.get():
                on_motion(e)
            queue.button(buttons[e.num], True)

    def on_unclick(e):
        """Sends a button release while captured."""
        if state["captured"] and e.num in buttons:
            queue.button(buttons[e.num], False)

    def on_motion(e):
        """Turns pointer motion into an absolute position, or in relative mode into the distance from the parking spot.

        In relative mode the pointer is put back to the center after each move, and that jump produces a motion event
        of its own, which has to be recognized (by its position) and skipped, or the radio's pointer would drift.
        """
        if not state["captured"]:
            return
        if abs_var.get():
            w, h = max(1, label.winfo_width()), max(1, label.winfo_height())
            queue.move_abs(int(e.x * SCREEN_W / w), int(e.y * SCREEN_H / h))
            return
        cx, cy = center()
        if state["ignore_motion"] and e.x_root == cx and e.y_root == cy:
            state["ignore_motion"] = max(0, state["ignore_motion"] - 1)
            return
        fx = (e.x_root - cx) * speed + state["frac"][0]
        fy = (e.y_root - cy) * speed + state["frac"][1]
        dx, dy = int(fx), int(fy)
        state["frac"] = [fx - dx, fy - dy]
        queue.move_rel(dx, dy)
        if user32:
            user32.SetCursorPos(cx, cy)
            state["ignore_motion"] = 1

    def on_wheel(e):
        """Wheel turns, in steps of 120 (the Windows wheel unit); a smaller delta still counts as one step."""
        if state["captured"]:
            queue.wheel(int(e.delta / 120) or (1 if e.delta > 0 else -1))

    def on_key(e, down):
        """Key press or release.  Esc and F12 held together release the capture; every other key goes to the queue,
        and "break" stops tkinter from also handling it, so the PC does not react to keys meant for the radio."""
        if not state["captured"]:
            return "break"
        if e.keysym == "Escape":
            state["esc"] = down
        elif e.keysym == "F12":
            state["f12"] = down
        if state["esc"] and state["f12"]:
            release()
            return "break"
        queue.key(e.keysym, e.keycode, down)
        return "break"

    def tick():
        """Every FLUSH_MS: sends what is queued, or a heartbeat when nothing was sent for HEARTBEAT_MS while captured."""
        now = time.monotonic()
        if len(queue):
            sender.send_queue(queue)
        elif state["captured"] and now - sender.last_sent >= HEARTBEAT_MS / 1000.0:
            sender.send_events([])
        root.after(FLUSH_MS, tick)

    def poll_status():
        """Reads the board's status answers that arrived, asks again with a hello after 2 s of silence, and redraws the window."""
        now = time.monotonic()
        if now - state["last_status_t"] > 2.0 and now - state.get("last_hello_t", 0.0) > 2.0:
            state["last_hello_t"] = now
            sender.hello()  # the board may have been busy; ask again
        try:
            while True:
                data, _src = sock.recvfrom(2048)
                st = parse_status(data)
                if st:
                    state["status"] = st
                    state["last_status_t"] = time.monotonic()
        except (BlockingIOError, OSError):
            pass
        show()
        root.after(STATUS_POLL_MS * 5, poll_status)

    def on_close():
        """Window closed: release everything first, so the board does not wait for its 3 s timeout with a button held."""
        release()
        sender.send_queue(queue)  # the release must leave before the window goes
        root.destroy()

    label.bind("<ButtonPress>", on_click)
    label.bind("<ButtonRelease>", on_unclick)
    label.bind("<Motion>", on_motion)
    label.bind("<MouseWheel>", on_wheel)
    root.bind("<KeyPress>", lambda e: on_key(e, True))
    root.bind("<KeyRelease>", lambda e: on_key(e, False))
    root.bind("<FocusOut>", lambda e: release() if e.widget is root else None)
    root.protocol("WM_DELETE_WINDOW", on_close)
    sender.hello()
    show()
    tick()
    poll_status()
    root.mainloop()
    clip(False)


def main(argv=None):
    """Finds the board, prints what it answered and (unless --probe) opens the capture window; returns the exit code."""
    ap = argparse.ArgumentParser(description="Control the radio's screen with this PC's mouse and keyboard.")
    ap.add_argument("--ip", help="the board's address (otherwise found by a broadcast hello)")
    ap.add_argument("--absolute", action="store_true", help="the window is the screen (pointer position, not movement)")
    ap.add_argument("--speed", type=float, default=1.0, help="pointer speed factor in relative mode (default 1.0)")
    ap.add_argument("--timeout", type=float, default=15.0, help="seconds to look for the board")
    ap.add_argument("--probe", action="store_true", help="ask the board, print the answer, and exit")
    args = ap.parse_args(argv)

    sock = open_socket()
    stats = {}
    found = discover(sock, args.ip, args.timeout, stats)
    if not found:
        print("No answer from the board on UDP port %d after %d hellos (every 0.5 s) to %s." % (
            PORT, stats["hellos"], ", ".join(stats["targets"])), file=sys.stderr)
        if stats["other"]:
            print("Other datagrams that came back: %s" % ", ".join("%s (%d bytes)" % o for o in stats["other"][:5]), file=sys.stderr)
        else:
            print("Nothing at all came back.", file=sys.stderr)
        if stats["errors"]:
            print("Socket errors: %s" % "; ".join(stats["errors"]), file=sys.stderr)
        print("The board's input service runs once per main-loop pass, which can be seconds while it decodes; use a longer"
              " --timeout (now %.0f s), or --ip <address> (the radio's console prints it)." % args.timeout, file=sys.stderr)
        return 1
    ip, st = found
    print("board %s: %d datagrams applied, pointer %d,%d, %d transmit keys dropped" % (ip, st["applied"], st["x"], st["y"], st["blocked"]))
    if args.probe:
        return 0
    run_window(sock, ip, st, args.absolute, args.speed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
