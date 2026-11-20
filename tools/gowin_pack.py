#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
"""How the flip-flops of a Gowin synthesis netlist (.vg) are fed: by a LUT or adder cell of their own, or not.

A flip-flop whose D input comes from a LUT or adder cell can sit in that cell's slice half. One whose D comes
from another flip-flop, a memory, a DSP block, a pin or a constant ("bare"), or from a LUT that already hosts
another flip-flop, needs a slice half whose LUT then stays empty, if the slice has no way around its LUT.
Printed per unit: flip-flops, hosted, bare by kind of driver; and the sum logic cells + bare flip-flops.

    python tools/gowin_pack.py <sdr_top.vg> [--depth 2] [--topmod sdr_top]

The netlist is the one Gowin synthesis writes (the .vg file in the build's gwsynthesis folder).  The script only reads it,
with the parser of tools/gowin_fanout.py, so the Gowin software is not needed.  Only units with at least 300 flip-flops are listed.
"""
import argparse
import os
import sys
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gowin_fanout import parse, bits  # noqa: E402

# Output port names of the primitives, which is how the driver of a net is found.
OUTP = ("F", "SUM", "O", "Q", "DO", "DOUT", "COUT")


def main():
    """Finds the driver of every flip-flop's D input, decides which flip-flops are hosted by a LUT or adder of their own, and prints the per unit table."""
    ap = argparse.ArgumentParser()
    ap.add_argument("vg")
    ap.add_argument("--depth", type=int, default=2)
    ap.add_argument("--topmod", default="sdr_top")
    a = ap.parse_args()
    mods = parse(a.vg)
    sys.setrecursionlimit(10000)
    driver = {}      # global net bit -> (kind, cell instance id)
    ffs = []         # (unit, global D net)
    logic = Counter()
    uid = [0]

    def unit_of(path):
        """The unit (first --depth instance names) that an instance path belongs to."""
        return "/".join(path.split("/")[1:1 + a.depth]) or "(top)"

    def walk(mod, path, env):
        """Visits module `mod`, recording the driver of every net and the D net of every flip-flop; env maps port names to the nets outside."""
        m = mods[mod]

        def g(b):
            """The global name of net bit b, or None for a constant."""
            if b is None or b in ("GND", "VCC"):
                return None
            return env.get(b, path + "/" + b)
        for cell, name, conn in m.insts:
            if cell in mods:
                sub = {}
                sm = mods[cell]
                for port, expr in conn:
                    ob = bits(expr, m)
                    w = sm.width.get(port)
                    names = ([port] if w is None else
                             ["%s[%d]" % (port, i) for i in (range(w[0], w[1] - 1, -1) if w[0] >= w[1] else range(w[0], w[1] + 1))])
                    for pn, b in zip(names[-len(ob):] if len(ob) <= len(names) else names, ob[-len(names):]):
                        gb = g(b)
                        if gb is not None:
                            sub[pn] = gb
                walk(cell, path + "/" + name, sub)
                continue
            uid[0] += 1
            me = uid[0]
            if cell.startswith("LUT") or cell.startswith("MUX2") or cell == "ALU":
                kind = "lut"
                logic[unit_of(path)] += 1
            elif cell.startswith("DFF") or cell.startswith("DL"):
                kind = "ff"
            elif cell.startswith("RAM16") or cell.startswith("ROM16"):
                kind = "lutram"
                logic[unit_of(path)] += 6 if cell.startswith("RAM16") else 1
            else:
                kind = "hard"
            for port, expr in conn:
                if port in OUTP:
                    for b in bits(expr, m):
                        gb = g(b)
                        if gb is not None:
                            driver[gb] = (kind, me)
                elif port == "D" and kind == "ff":
                    b = bits(expr, m)
                    ffs.append((unit_of(path), g(b[0]) if b else None))
    walk(a.topmod, "", {})
    # One LUT can host only one flip-flop: the first flip-flop fed by a LUT takes it, and a second one fed by the same LUT is bare.
    host = set()
    per = defaultdict(Counter)
    for unit, d in ffs:
        k = driver.get(d, ("pin/const", 0))
        if k[0] == "lut" and k[1] not in host:
            host.add(k[1])
            per[unit]["hosted"] += 1
        else:
            per[unit]["bare: " + ("LUT taken" if k[0] == "lut" else k[0])] += 1
    tot = Counter()
    print("unit: flip-flops, hosted by their own LUT/adder, bare (from a flip-flop, LUT RAM, hard block, taken LUT, pin), logic cells")
    for u in sorted(per, key=lambda x: -sum(per[x].values())):
        c = per[u]
        n = sum(c.values())
        tot.update(c)
        if n >= 300:
            print("  %-40s %6d %6d | ff %5d  lutram %5d  hard %5d  taken %5d  pin %4d | logic %6d" % (
                u, n, c["hosted"], c["bare: ff"], c["bare: lutram"], c["bare: hard"], c["bare: LUT taken"],
                c["bare: pin/const"], logic[u]))
    n = sum(tot.values())
    bare = n - tot["hosted"]
    lg = sum(logic.values())
    print("total: %d flip-flops, %d hosted, %d bare (%s); logic %d; logic + bare = %d = %d slices" % (
        n, tot["hosted"], bare, ", ".join("%s %d" % (k[6:], v) for k, v in tot.items() if k != "hosted"), lg,
        lg + bare, (lg + bare + 1) // 2))


if __name__ == "__main__":
    main()
