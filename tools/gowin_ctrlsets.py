#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
"""Control sets of the flip-flops in a Gowin synthesis netlist (.vg).

A slice (CLS) holds two flip-flops and they share clock, clock enable and set/reset. Flip-flops with different
enables or resets cannot share a slice, so a design with very many small groups needs more slices than its
flip-flop count says. Printed: the number of control sets, the slices the flip-flops need when only flip-flops
of one set share a slice (sum of ceil(n / 2)), the histogram of set sizes, and the units with the most sets.

    python tools/gowin_ctrlsets.py <sdr_top.vg> [--depth 2] [--top 25]

The netlist is the one Gowin synthesis writes (the .vg file in the build's gwsynthesis folder); the script only reads it,
reusing the netlist parser of tools/gowin_fanout.py, and does not need the Gowin software.  --depth says how many
levels of the instance path name a unit in the last list, --top how many units that list shows, and --topmod the name
of the top module if it is not sdr_top.
"""
import argparse
import os
import sys
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gowin_fanout import parse  # noqa: E402


def main():
    """Walks the netlist from the top module down, collects the control set of every flip-flop and prints the summary."""
    ap = argparse.ArgumentParser()
    ap.add_argument("vg")
    ap.add_argument("--depth", type=int, default=2)
    ap.add_argument("--top", type=int, default=25)
    ap.add_argument("--topmod", default="sdr_top")
    a = ap.parse_args()
    mods = parse(a.vg)
    sets = Counter()            # (instance path of the module, clk, ce, sr, kind) -> flip-flops
    sys.setrecursionlimit(10000)

    def walk(mod, path, env):
        """Visits the instances of module `mod`; env maps its port names to the net names outside, so that nets keep one name through the hierarchy."""
        m = mods[mod]
        for cell, name, conn in m.insts:
            if cell in mods:
                sub = {}
                for port, expr in conn:
                    e = expr.strip()
                    sub[port] = env.get(e, path + "/" + e)
                walk(cell, path + "/" + name, sub)
            elif cell.startswith("DFF") or cell.startswith("DL"):
                c = {p: e.strip() for p, e in conn}

                def net(p):
                    """The flattened net name on pin p of this flip-flop (or GND, VCC or an empty string when it is tied or missing)."""
                    e = c.get(p, "")
                    if e in ("GND", "VCC", ""):
                        return e
                    return env.get(e, path + "/" + e)
                sr = net("RESET") or net("SET") or net("CLEAR") or net("PRESET")
                sets[(net("CLK"), net("CE"), sr, cell)] += 1
    walk(a.topmod, "", {})
    n = sum(sets.values())
    cls = sum((v + 1) // 2 for v in sets.values())
    print("%d flip-flops in %d control sets; %d slices when only one set shares a slice (%d if all could pair)"
          % (n, len(sets), cls, (n + 1) // 2))
    hist = Counter()
    for v in sets.values():
        hist[1 if v == 1 else 2 if v == 2 else 4 if v <= 4 else 8 if v <= 8 else 16 if v <= 16 else 64 if v <= 64 else 999] += 1
    for k in sorted(hist):
        print("  sets of up to %3s flip-flops: %6d" % (k if k < 999 else ">64", hist[k]))
    odd = sum(1 for v in sets.values() if v % 2)
    print("  sets with an odd count (half a slice lost each): %d" % odd)
    per = defaultdict(lambda: [0, 0])
    for (clk, ce, sr, cell), v in sets.items():
        key = ce if ce not in ("VCC", "GND", "") else sr
        unit = "/".join(key.split("/")[1:1 + a.depth]) if key.startswith("/") else "(no enable, no reset)"
        per[unit][0] += 1
        per[unit][1] += v
    print("units by number of control sets (named by where the enable or reset comes from): sets, flip-flops")
    for u, (s, f) in sorted(per.items(), key=lambda kv: -kv[1][0])[:a.top]:
        print("  %6d %7d  %s" % (s, f, u))


if __name__ == "__main__":
    main()
