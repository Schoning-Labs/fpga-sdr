#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
"""Sizes and memories per unit from a Gowin synthesis netlist (.vg).

The netlist is the one Gowin synthesis writes (the .vg file in the build's gwsynthesis folder), and the script only reads
it, reusing the parser of tools/gowin_fanout.py, so the Gowin software is not needed.  It answers the questions "which unit
uses how many LUTs, registers, block RAMs and multipliers" and "what did the synthesis make of this memory", the second one
mattering because a memory can end up in block RAM, in LUT RAM or in plain flip-flops, and the netlist is where that shows.

Printed:
  - per unit (instance path, --depth levels): LUT, adder cells, LUT-RAM cells, registers, block RAM primitives,
    blocks (a primitive wider than 18 bits counts two: place-and-route splits it), multipliers
  - with --mem: every block RAM by its name in the source (the primitives of one memory joined): kind, words
    in use (from the address bits that are not constant), data bits in use, primitives, blocks
  - with --lutram: the LUT RAMs by name: cells

    python tools/gowin_mems.py <sdr_top.vg> [--depth 3] [--under u_core/u_rx_bank/] [--mem] [--lutram]
"""
import argparse
import os
import re
import sys
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gowin_fanout import parse, bits, nm  # noqa: E402

# Names of the Gowin block RAM primitives (the X9 versions are the 9-bit-per-byte ones), and the pattern of a defparam line.
BSRAM = ("SDPB", "SDPX9B", "DPB", "DPX9B", "pROM", "pROMX9", "SP", "SPX9")
DEFP = re.compile(r"^\s*defparam\s+(\\\S+\s|[A-Za-z_][\w$]*)\s*\.(\w+)\s*=\s*(\S+?);")


def defparams(vg, names=("BIT_WIDTH", "BIT_WIDTH_0", "BIT_WIDTH_1")):
    """The data widths that the netlist sets on its block RAM instances with defparam, as {(module, instance): {parameter: width}}."""
    out, cur = {}, None
    with open(vg, encoding="utf-8", errors="replace") as f:
        for line in f:
            if line.startswith("module "):
                cur = nm(line.split()[1].split("(")[0])
            elif "defparam" in line and "BIT_WIDTH" in line:
                m = DEFP.match(line)
                if m and m.group(2) in names:
                    out.setdefault((cur, nm(m.group(1))), {})[m.group(2)] = int(m.group(3))
    return out


def kind(cell):
    """The resource class of a primitive cell (bsram, lut, alu, reg, ssram or dsp), or None for cells that are not counted."""
    if cell in BSRAM:
        return "bsram"
    if cell.startswith("LUT") or cell.startswith("MUX2"):
        return "lut" if cell.startswith("LUT") else None
    if cell == "ALU":
        return "alu"
    if cell.startswith("DFF") or cell.startswith("DL"):
        return "reg"
    if cell.startswith("RAM16") or cell.startswith("ROM16"):
        return "ssram"
    if cell.startswith("MULT") or cell.startswith("PADD") or cell.startswith("ALU54"):
        return "dsp"
    return None


def var(expr, mod):
    """The number of bits of a port expression that are connected to real nets, which means not tied to GND or VCC."""
    return sum(1 for b in bits(expr, mod) if b is not None and b not in ("GND", "VCC"))


def main():
    """Counts the cells per unit and prints the table, plus the block RAM and LUT RAM lists when asked for."""
    ap = argparse.ArgumentParser()
    ap.add_argument("vg")
    ap.add_argument("--depth", type=int, default=3)
    ap.add_argument("--under", default="")
    ap.add_argument("--mem", action="store_true")
    ap.add_argument("--lutram", action="store_true")
    a = ap.parse_args()
    mods = parse(a.vg)
    dp = defparams(a.vg)
    used = {c for m in mods.values() for c, _, _ in m.insts}
    top = [m for m in mods if m not in used][-1]
    tot = defaultdict(Counter)
    mems = defaultdict(lambda: Counter())
    lram = Counter()
    dsp = defaultdict(Counter)

    def walk(modname, path):
        """Visits every instance below module `modname`; the name of a memory is its instance name without the tool's bit and copy suffix, so the primitives of one memory are counted together."""
        mod = mods[modname]
        for cell, name, conns in mod.insts:
            p = path + name
            if cell in mods:
                walk(cell, p + "/")
                continue
            k = kind(cell)
            if k is None or not p.startswith(a.under):
                continue
            parts = p.split("/")
            u = "/".join(parts[:min(a.depth, len(parts) - 1)]) or "(top)"
            tot[u][k] += 1
            if k == "dsp":
                dsp[u][cell] += 1
            if k == "ssram":
                lram[path + re.sub(r"(_\d+)+_s\d*$", "", name)] += 1
            if k == "bsram":
                d = dp.get((modname, name), {})
                w = max(d.values()) if d else 0
                blocks = 2 if (cell in ("SDPB", "SDPX9B", "pROM", "pROMX9") and w > 18) else 1
                tot[u]["blocks"] += blocks
                c = dict(conns)
                base = path + re.sub(r"(_\d+)+_s\d*$", "", name)
                e = mems[base]
                e["prims"] += 1
                e["blocks"] += blocks
                e[cell + str(w)] += 1
                ad = c.get("ADA", c.get("AD", ""))
                # the low address bits of a narrow primitive are tied off; the bits in use are the others
                e["abits"] = max(e["abits"], var(ad, mod), var(c.get("ADB", ""), mod))
                di = var(c.get("DI", c.get("DIA", "")), mod)
                e["dbits"] += di if di else w
    walk(top, "")
    print("unit: LUT, adders, LUT-RAM cells, registers, block RAM primitives, blocks, multipliers")
    s = Counter()
    for u in sorted(tot):
        t = tot[u]
        s.update(t)
        print("  %-52s %6d %6d %5d %6d %4d %4d  %s" % (u, t["lut"], t["alu"], t["ssram"], t["reg"], t["bsram"], t["blocks"],
              " ".join("%s:%d" % kv for kv in sorted(dsp[u].items()))))
    print("  %-52s %6d %6d %5d %6d %4d %4d" % ("total", s["lut"], s["alu"], s["ssram"], s["reg"], s["bsram"], s["blocks"]))
    if a.mem:
        print("\nblock RAMs: name, primitives by kind and width, words (2^address bits in use), data bits, blocks")
        for b in sorted(mems):
            e = mems[b]
            kinds = " ".join("%s x%d" % (k, v) for k, v in sorted(e.items()) if k not in ("prims", "blocks", "abits", "dbits"))
            print("  %-70s %-26s %6d x %3d  %2d" % (b, kinds, 1 << e["abits"], e["dbits"], e["blocks"]))
    if a.lutram:
        print("\nLUT RAMs: name, cells")
        for b, n in sorted(lram.items()):
            print("  %-70s %4d" % (b, n))


if __name__ == "__main__":
    main()
