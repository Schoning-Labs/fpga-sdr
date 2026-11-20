#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
"""Where the placer put the cells: reads Gowin's placement database impl/pnr/<top>.db (docs/ROUTE_DIAG.md).

The file is written after placement, before routing, so it exists for a build that fails to route. Layout (found by
reading it, not documented by Gowin, so another version of the Gowin software may write it differently): int32 count, then 20-byte records
    uint16 cell type, uint16 row, uint16 column, uint16 position in the grid cell (0..7; 65535 = none), int32 0,
    int32 sequence, int32 cell id
(the first record is a header). Logic rows are 2..108 without the block-RAM rows 10, 28, 46, 64, 82, 100 and the DSP
rows 19, 37, 55, 73, 91; logic columns 2..181: 96 x 180 grid cells (CFU) of 4 slices = 8 LUT + 8 flip-flops.
The file has no names. Type codes seen: 64 DFFRE, 68 DFFSE, 54 and 60 other flip-flops, 21..24 LUT1..LUT4, 106 ALU,
33..36 MUX2_LUT5..8, 97 RAM16SDP4, 94 RAM16S4, 95 RAM16SDP1, 98 ROM16, 199 SDPB, 200 SDPX9B, 202 DPX9B, 204 pROM,
205 pROMX9, 185 MULTALU27X18, 188 MULT27X36, 187 MULT12X12.

Printed: half-slices by content, slice use per region, and input pins per block of 8 x 8 grid cells (one band of
logic rows between two hard rows, 8 columns): the measure that tells a build that routes from one that does not (the
threshold is --pins, 2400 by default, see docs/ROUTE_DIAG.md).  The script only reads the .db file and does not need the Gowin software.

    python tools/gowin_place.py <sdr_top.db> [--pins 2400]
"""
import argparse
import struct
from collections import Counter, defaultdict

# The cell type codes (see the list in the docstring) that count as flip-flops, LUTs (an adder cell and a ROM16 use a LUT too)
# and LUT RAM, and for each type the number of input pins it adds to the routing load of its block.
FF = {64, 68, 54, 60}
LUT = {21, 22, 23, 24, 106, 98}
RAM = {97, 94, 95}
PIN = {64: 3, 68: 3, 54: 2, 60: 3, 21: 1, 22: 2, 23: 3, 24: 4, 106: 3, 33: 1, 34: 1, 35: 1, 36: 1, 97: 13, 94: 9,
       95: 10, 98: 4}


def load(path):
    """cell id -> (type, row, column, position)"""
    b = open(path, "rb").read()
    n = struct.unpack_from("<i", b, 0)[0]
    out = {}
    for i in range(1, n):
        a, row, col, e, _f, _seq, cid = struct.unpack_from("<HHHHiii", b, 4 + 20 * i)
        out[cid] = (a, row, col, e)
    return out


def main():
    """Prints the slice use of the whole chip and the routing pin load per block of 8 x 8 grid cells."""
    ap = argparse.ArgumentParser()
    ap.add_argument("db")
    ap.add_argument("--pins", type=int, default=2400)
    a = ap.parse_args()
    cells = load(a.db)
    lut, ff, ram = defaultdict(set), defaultdict(set), set()
    pins, alu, rams = Counter(), Counter(), Counter()
    for t, row, col, e in cells.values():
        if not (2 <= row <= 108 and 2 <= col <= 181):
            continue
        k = (row, col)
        if t in FF:
            ff[k].add(e)
        elif t in LUT:
            lut[k].add(e)
        elif t in RAM:
            ram.add(k)
        if t in PIN:
            b = ((row - 2) // 9, (col - 2) // 8)
            pins[b] += PIN[t]
            alu[b] += t == 106
            rams[b] += t in RAM
    both = fo = lo = 0
    used = Counter()
    for k in set(lut) | set(ff) | ram:
        L, F = lut.get(k, set()), ff.get(k, set())
        both += len(L & F)
        fo += len(F - L)
        lo += len(L - F)
        used[k] = 4 if k in ram else len({e // 2 for e in L | F})
    print("cells %d; half-slices with LUT and flip-flop %d, flip-flop only %d, LUT only %d; grid cells with LUT RAM %d"
          % (len(cells), both, fo, lo, len(ram)))
    h = Counter(used.values())
    print("grid cells by slices used: 0: %d, 1: %d, 2: %d, 3: %d, 4: %d" % (17280 - len(used), h[1], h[2], h[3], h[4]))
    rows = [r for r in range(2, 109) if (r - 1) % 9]
    print("slice use in %, 12 row bands down, 12 column bands across")
    for i in range(12):
        rr = rows[i * 8:i * 8 + 8]
        print("  rows %3d-%3d: " % (rr[0], rr[-1]) + " ".join(
            "%3d" % round(25 * sum(used[(r, c)] for r in rr for c in range(2 + 15 * j, 17 + 15 * j)) / (8 * 15))
            for j in range(12)))
    v = sorted(pins.values())
    n = len(v)
    hot = [b for b, x in pins.items() if x > a.pins]
    print("input pins per block of 8 x 8 grid cells: median %d, 90th %d, 99th %d, max %d; blocks over %d: %d of %d"
          % (v[n // 2], v[n * 9 // 10], v[n * 99 // 100], v[-1], a.pins, len(hot), n))
    if hot:
        print("  in those blocks: adder cells %.0f per block (all blocks %.0f), LUT-RAM cells %.1f (all %.1f)"
              % (sum(alu[b] for b in hot) / len(hot), sum(alu.values()) / n, sum(rams[b] for b in hot) / len(hot),
                 sum(rams.values()) / n))
        print("  (row band, column band): " + " ".join("%d,%d" % b for b in sorted(hot)))


if __name__ == "__main__":
    main()
