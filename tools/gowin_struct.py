#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
"""Structure of a Gowin synthesis netlist (.vg) in one column of numbers, for comparing two designs
(docs/ROUTE_CAUSE.md): cells by kind, nets and pins, enable and reset nets, control sets, flip-flops without a LUT
of their own, adder chains by length, LUT RAM, nets with many loads.

    python tools/gowin_struct.py <top.vg> [--under u_core/u_ft8/] [--units 2]

--under limits every count to the cells below that instance path; --units N adds a table per unit of depth N.

The netlist is the one Gowin synthesis writes (the .vg file in the build's gwsynthesis folder).  The script only reads it,
with the parser and flattening of tools/gowin_fanout.py, so the Gowin software is not needed.  Running it on two builds and
putting the columns side by side shows what differs in their structure (for example more enables, more control sets, longer
adder chains), which is a way to look for why one of them routes badly and the other does not.
"""
import argparse
import os
import sys
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gowin_fanout import parse, Flat, unit  # noqa: E402


def kind(c):
    """The resource class of a primitive cell: ff, lut, alu, mux, lutram, rom16, bram, dsp or other."""
    if c.startswith("DFF") or c.startswith("DL"):
        return "ff"
    if c.startswith("LUT"):
        return "lut"
    if c == "ALU":
        return "alu"
    if c.startswith("MUX2_"):
        return "mux"
    if c.startswith("RAM16"):
        return "lutram"
    if c.startswith("ROM16"):
        return "rom16"
    if c in ("SDPB", "SDPX9B", "DPB", "DPX9B", "pROM", "pROMX9", "SP", "SPX9"):
        return "bram"
    if c.startswith("MULT") or c.startswith("ALU54") or c.startswith("PADD"):
        return "dsp"
    return "other"


def stats(fl, pre):
    """The list of (description, value) lines for the cells whose instance path starts with `pre` (all cells when empty)."""
    cells = {}                                  # path -> cell type (cells with at least one pin seen)
    ins = defaultdict(list)                     # cell path -> [(port, net)]
    for net, p, cell, port in fl.loads:
        if p.startswith(pre):
            cells[p] = cell
            ins[p].append((port, fl.find(net)))
    drv = {}
    for net, (p, cell, port) in fl.drv.items():
        drv[fl.find(net)] = (p, cell, port)
        if p.startswith(pre):
            cells.setdefault(p, cell)
    k = Counter(kind(c) for c in cells.values())
    lutn = Counter(c for c in cells.values() if c.startswith("LUT"))
    loads = Counter()
    ce, sr, data_pins = Counter(), Counter(), 0
    bare = Counter()
    hosts = set()
    cin = {}                                    # alu path -> net at CIN
    for p, lst in ins.items():
        kd = kind(cells[p])
        for port, n in lst:
            loads[n] += 1
            if kd == "ff" and port == "CE":
                ce[n] += 1
            elif kd == "ff" and port in ("RESET", "SET", "CLEAR", "PRESET"):
                sr[n] += 1
            else:
                data_pins += 1
            if kd == "ff" and port == "D":
                d = drv.get(n)
                dk = kind(d[1]) if d else "none"
                if dk in ("lut", "alu", "mux", "rom16") and n not in hosts:
                    hosts.add(n)
                elif dk in ("lut", "alu", "mux", "rom16"):
                    bare["copy"] += 1           # a second flip-flop on the same LUT output: a register copy
                else:
                    bare[dk] += 1
            if kd == "alu" and port == "CIN":
                cin[p] = n
    # adder chains: an ALU whose CIN is another ALU's COUT continues that chain
    nxt = {}
    heads = set(p for p, c in cells.items() if c == "ALU")
    for p, n in cin.items():
        d = drv.get(n)
        if d and d[1] == "ALU" and d[2] == "COUT":
            nxt[d[0]] = p
            heads.discard(p)
    chains = []
    for h in heads:
        n, p = 1, h
        while p in nxt:
            p = nxt[p]
            n += 1
        chains.append(n)
    ctrl = Counter()
    for p, lst in ins.items():
        if kind(cells[p]) != "ff":
            continue
        d = dict((port if port not in ("SET", "CLEAR", "PRESET") else "RESET", n) for port, n in lst)
        ctrl[(d.get("CE"), d.get("RESET"), cells[p])] += 1
    nff = k["ff"]
    logic = k["lut"] + k["alu"] + k["rom16"] + 6 * k["lutram"]
    npins = sum(loads.values())
    out = [
        ("LUT / adder cells / LUT-ROM / LUT-RAM cells", "%d / %d / %d / %d" % (k["lut"], k["alu"], k["rom16"], k["lutram"])),
        ("wide-mux cells (MUX2_LUT5..8)", "%d" % k["mux"]),
        ("flip-flops", "%d" % nff),
        ("block RAM / DSP primitives", "%d / %d" % (k["bram"], k["dsp"])),
        ("share of adder cells in logic", "%.0f %%" % (100.0 * k["alu"] / max(1, logic))),
        ("share of LUT4 among LUTs", "%.0f %%" % (100.0 * lutn["LUT4"] / max(1, k["lut"]))),
        ("flip-flops per logic cell", "%.2f" % (nff / max(1, logic))),
        ("nets with loads", "%d" % len(loads)),
        ("input pins (no clocks)", "%d" % npins),
        ("pins per net (mean)", "%.2f" % (npins / max(1, len(loads)))),
        ("nets with one load", "%.0f %%" % (100.0 * sum(1 for v in loads.values() if v == 1) / max(1, len(loads)))),
        ("nets with 9..64 loads: nets / pins", "%d / %d" % (sum(1 for v in loads.values() if 8 < v <= 64),
                                                            sum(v for v in loads.values() if 8 < v <= 64))),
        ("nets with over 64 loads: nets / pins", "%d / %d" % (sum(1 for v in loads.values() if v > 64),
                                                             sum(v for v in loads.values() if v > 64))),
        ("flip-flops with an enable", "%.0f %%" % (100.0 * sum(ce.values()) / max(1, nff))),
        ("enable nets / per 1,000 flip-flops", "%d / %.1f" % (len(ce), 1000.0 * len(ce) / max(1, nff))),
        ("flip-flops with a reset or set", "%.0f %%" % (100.0 * sum(sr.values()) / max(1, nff))),
        ("reset nets", "%d" % len(sr)),
        ("control sets / per 1,000 flip-flops", "%d / %.1f" % (len(ctrl), 1000.0 * len(ctrl) / max(1, nff))),
        ("control sets of 1 or 2 flip-flops", "%d" % sum(1 for v in ctrl.values() if v <= 2)),
        ("flip-flops without a LUT of their own", "%d (%.0f %%)" % (sum(bare.values()), 100.0 * sum(bare.values()) / max(1, nff))),
        ("  fed by a flip-flop / copy of another register / LUT RAM / block RAM or DSP / other",
         "%d / %d / %d / %d / %d" % (bare["ff"], bare["copy"], bare["lutram"], bare["bram"] + bare["dsp"],
                                     sum(v for kk, v in bare.items() if kk not in ("ff", "copy", "lutram", "bram", "dsp")))),
        ("adder chains / mean length / longest", "%d / %.1f / %d" % (len(chains), sum(chains) / max(1, len(chains)),
                                                                    max(chains or [0]))),
        ("adder cells in chains of 1..16 / 17..32 / 33..48 / over 48",
         "%d / %d / %d / %d" % (sum(c for c in chains if c <= 16), sum(c for c in chains if 16 < c <= 32),
                                sum(c for c in chains if 32 < c <= 48), sum(c for c in chains if c > 48))),
        ("chains over 32 / over 48", "%d / %d" % (sum(1 for c in chains if c > 32), sum(1 for c in chains if c > 48))),
    ]
    return out


def main():
    """Prints the statistics for the whole design (or the part below --under) and, with --units, for the twelve largest units."""
    ap = argparse.ArgumentParser()
    ap.add_argument("vg")
    ap.add_argument("--under", default="")
    ap.add_argument("--units", type=int, default=0)
    a = ap.parse_args()
    sys.setrecursionlimit(20000)
    fl = Flat(parse(a.vg))
    for name, val in stats(fl, a.under):
        print("%-62s %s" % (name, val))
    if a.units:
        us = Counter()
        for _n, p, _c, _port in fl.loads:
            if p.startswith(a.under):
                us[unit(p, a.units)] += 1
        for u, _ in us.most_common(12):
            print("\n== " + u)
            for name, val in stats(fl, u + "/"):
                print("%-62s %s" % (name, val))
    return 0


if __name__ == "__main__":
    sys.exit(main())
