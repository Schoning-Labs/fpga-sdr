#!/usr/bin/env python
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
"""Loads the radio into the Tang board (SRAM only, nothing is written to the flash) and optionally opens the PC mouse and keyboard window.

    py tools/radio_start.py            load the radio
    py tools/radio_start.py --input    load it, then open tools/radio_input.py

This script does not talk to the board itself.  It needs a board loader tool (board.py with its board.json) that is not part
of this repository, because that tool paces the bytes sent over the debug cable and never resets the cable on its own, which
is what keeps the board's debug USB chip from getting stuck.  Three environment variables name what it needs, and none has a
default, so the script stops with a message when one is missing:
  RADIO_BOARD_TOOL  the folder that holds board.py and board.json
  RADIO_NETBOOT     the small boot image that makes the board accept the firmware over the network
  RADIO_BOARD_LOCK  the path of the lock file that keeps two sessions off the debug cable at once
The built radio is found through RADIO_KEEP (see below).

What happens when it runs, in order:
  1. It looks for the board's debug USB console port (one FTDI port, serial number ending in B) and stops if there is not exactly one.
  2. It writes a board configuration for the tool into %LOCALAPPDATA%/fpga-sdr-board (or the temp folder), based on the tool's board.json.
  3. It takes the lock file (LOCK), so that no second session sends to the board at the same time, and releases it at the end.
  4. It asks the board tool to load the bitstream over the debug cable and then the roughly 2 MB firmware image over the network,
     so the board's RJ45 cable has to be plugged into the home network, never over the serial cable (which would take far too long).
The bitstream and the firmware come from the folder KEEP (sdr_top.fs and ft8fw.img).  See docs/USER_MANUAL.md for the whole procedure.
"""
import json
import os
import subprocess
import sys
import tempfile
import time

# Folder with the built radio: sdr_top.fs (the bitstream) and ft8fw.img (the firmware image).  The default is the
# author's own build folder on his PC, so point the environment variable RADIO_KEEP at your own build output instead.
KEEP = os.environ.get("RADIO_KEEP", "G:/proj/fpga-sdr/impl/keep/radio_20261021")
# The board loader tool (board.py and board.json), which paces the bytes sent to the board and limits the UART speed.
# It is not part of this repository; RADIO_BOARD_TOOL names its folder.
BOARD_TOOL = os.environ.get("RADIO_BOARD_TOOL")
# The small boot image that makes the board accept the firmware over the network, and the lock file that
# keeps two sessions off the debug cable at once.  Neither has a default.
NETBOOT = os.environ.get("RADIO_NETBOOT")
LOCK = os.environ.get("RADIO_BOARD_LOCK")
HERE = os.path.dirname(os.path.abspath(__file__))


def check_settings():
    """Stops the script with a message when one of the three board tool environment variables is not set."""
    missing = [n for n, v in (("RADIO_BOARD_TOOL", BOARD_TOOL), ("RADIO_NETBOOT", NETBOOT), ("RADIO_BOARD_LOCK", LOCK)) if not v]
    if missing:
        raise SystemExit("Not set: %s. This script needs a board loader tool (board.py with its board.json) that is not part of "
                         "this repository: RADIO_BOARD_TOOL is its folder, RADIO_NETBOOT the network boot image and RADIO_BOARD_LOCK "
                         "the lock file path. Nothing was touched." % ", ".join(missing))


def console_port():
    """The COM port of the board's debug USB console, found by USB id (FTDI 0403:6010, serial number ending in B).

    Stops the script with a message unless exactly one such port is present, so that nothing is ever sent to the wrong device.
    """
    from serial.tools import list_ports
    ports = [p for p in list_ports.comports() if p.vid == 0x0403 and p.pid == 0x6010 and (p.serial_number or "").endswith("B")]
    if len(ports) != 1:
        raise SystemExit("The board's debug USB is not on the PC (found %d console ports). Check the USB-C cable and the board's power. "
                         "Nothing was touched." % len(ports))
    return ports[0].device


def main():
    """Checks the settings and the build files, writes a board configuration for the board tool, takes the lock and runs the load."""
    check_settings()
    for f in ("sdr_top.fs", "ft8fw.img"):
        if not os.path.isfile(os.path.join(KEEP, f)):
            raise SystemExit("missing %s in %s" % (f, KEEP))
    port = console_port()
    base = json.load(open(BOARD_TOOL + "/board.json", encoding="utf-8"))
    state = os.path.join(os.environ.get("LOCALAPPDATA", tempfile.gettempdir()), "fpga-sdr-board").replace("\\", "/")
    os.makedirs(state, exist_ok=True)
    # The tool's own board.json is the base, and the radio's variant (which bitstream, which firmware, which text on the
    # console means the load worked) is put over it, so the tool's files are never changed.
    base.update({
        "port": port, "baud": 184320,  # the flash loader divides for 50 MHz, the UART runs from 80 MHz
        "state_dir": state, "console_log": state + "/board_console.log", "console_tcp": 21400,
        "variants": {"radio": {"fs_glob": KEEP + "/sdr_top.fs", "program": True, "ok": "receivers in the chip", "net_load": True}},
        "image": KEEP + "/ft8fw.img", "netboot_image": NETBOOT, "net_wait_s": 150,
    })
    cfg = os.path.join(state, "radio_board.json")
    json.dump(base, open(cfg, "w", encoding="utf-8"), indent=1)

    # O_EXCL makes the creation fail when the file exists already, which means another session holds the board.
    try:
        fd = os.open(LOCK, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError:
        raise SystemExit("The board is in use: %s exists (another session has the board). Ask there, then run this again." % LOCK)
    os.write(fd, ("radio_start.py %s\n" % time.strftime("%Y-%m-%dT%H:%M:%S")).encode())
    os.close(fd)
    # The lock is released in the finally clause, whatever the load does, so a failed load never leaves the board locked.
    try:
        env = dict(os.environ, PYTHONIOENCODING="utf-8", BOARD_CONFIG=cfg)
        print("Loading the radio (about 1 minute): bitstream over the debug cable, firmware over the network ...", flush=True)
        r = subprocess.run([sys.executable, BOARD_TOOL + "/board.py", "load", "radio", "--echo"], cwd=os.path.normpath(os.path.join(BOARD_TOOL, "..", "..")),
                           env=env)
        rc = r.returncode
    finally:
        try:
            os.remove(LOCK)
        except OSError:
            pass
    if rc != 0:
        raise SystemExit("The load did not finish cleanly (code %d). Look at the lines above. Nothing was written to the flash." % rc)
    print("\nThe radio is running. Mouse and keyboard from this PC: py tools/radio_input.py")
    if "--input" in sys.argv[1:]:
        subprocess.run([sys.executable, os.path.join(HERE, "radio_input.py")])


if __name__ == "__main__":
    main()
