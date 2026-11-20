#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
"""Turns the `--vv` output of codec2's freedv_rx (stderr) into the compact trace file that
fw/tr-freedv/tests/c_reference.rs compares the Rust receiver with: 12 bytes per call to
freedv_rx, little endian: nin u16 (samples the next call wants), flags u8 (1 trial sync,
2 sync, 4 bits, 8 bit errors), state u8 (0 search, 1 trial, 2 synced, the state before the
state machine ran), uw_errors u8, ldpc iterations u8, parity checks satisfied u8, 0, frequency
offset i16 in 0.1 Hz, SNR estimate i16 in 0.1 dB (0 when the call decoded no frame).

The input is the text that the C reference program prints, one line per call of freedv_rx, so the Rust port can be checked
against the C code call by call (same state, same number of input samples, same decoder results).  Lines that do not look
like such a trace line are skipped.  The script needs nothing but the standard library and does not touch the board.

usage: trace2bin.py in.trace out.bin"""
import re, struct, sys

STATES = {"search": 0, "trial": 1, "synced": 2}
FLAGS = {c: i for i, c in enumerate("TSBE")}  # position in the text -> bit
out = bytearray()
for line in open(sys.argv[1]):
    # One regular expression picks the numbers out of a trace line (nin, state, unique word errors, frequency offset, and,
    # on lines where a frame was decoded, SNR, LDPC iterations and parity checks) and the four character status text at the end.
    m = re.match(r"\s*\d+ nin:\s*(\d+) st: (\w+)\s+euw:\s*(\d+)\s+\d+ mf:\s*\d+ f:\s*(-?[\d.]+) pbw: \d+\s+"
                 r"(?:snr:\s*(-?[\d.]+) eraw:\s*\d+ ecdd:\s*\d+ iter:\s*(\d+) pcc:\s*(\d+) )?.*rxst: (\S+)", line)
    if not m:
        continue
    nin, st, euw, foff, snr, it, pcc, rxst = m.groups()
    text = rxst  # "EBST" with '-' for unset, E = bit errors, B = bits, S = sync, T = trial
    flags = (8 if text[0] == "E" else 0) | (4 if text[1] == "B" else 0) | (2 if text[2] == "S" else 0) | (1 if text[3] == "T" else 0)
    out += struct.pack("<HBBBBBBhh", int(nin), flags, STATES[st], int(euw), int(it or 0), int(pcc or 0), 0,
                       round(float(foff) * 10), round(float(snr) * 10) if snr else 0)
open(sys.argv[2], "wb").write(out)
print(sys.argv[2], len(out) // 12, "calls")
