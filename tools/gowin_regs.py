#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
"""Registers by name inside one unit of a Gowin synthesis netlist (.vg): which signals the flip-flops are.

The instance names of the flip-flops keep the source's register names (`name_3_s0`, `\\grp[2].name_s1`); the bit
index and the tool's suffix are cut off and the rest is counted. Sub-instances are listed with their totals.

    python tools/gowin_regs.py <sdr_top.vg> u_core/u_backend [--top 40]

The netlist is the one Gowin synthesis writes (the .vg file in the build's gwsynthesis folder).  The script only reads it,
with the parser of tools/gowin_fanout.py, and the second argument is the instance path below the top module (which
--topmod names if it is not sdr_top).
"""
import argparse
import os
import re
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gowin_fanout import parse  # noqa: E402

PRIMS = None


def base(name):
    """The register name behind a flip-flop instance name, with the tool's suffix, bit and generate indices removed."""
    n = re.sub(r"_s\d+$", "", name)          # the tool's suffix
    n = re.sub(r"(_\d+)+$", "", n)           # bit indices
    n = re.sub(r"\[\d+\]", "[]", n)          # generate indices
    n = re.sub(r"RAMREG_\d+_G", "RAMREG_n_G", n)   # a memory built from flip-flops: all its words together
    return n


def total(mods, mod, memo):
    """The number of flip-flops in module `mod` and everything below it (memo keeps the result per module)."""
    if mod in memo:
        return memo[mod]
    t = 0
    for cell, _name, _c in mods[mod].insts:
        if cell in mods:
            t += total(mods, cell, memo)
        elif cell.startswith("DFF") or cell.startswith("DL"):
            t += 1
    memo[mod] = t
    return t


def main():
    """Follows the instance path down from the top module and prints its sub-instances and register names with their counts."""
    ap = argparse.ArgumentParser()
    ap.add_argument("vg")
    ap.add_argument("path", help="instance path below the top module, e.g. u_core/u_backend")
    ap.add_argument("--top", type=int, default=40)
    ap.add_argument("--topmod", default="sdr_top")
    a = ap.parse_args()
    mods = parse(a.vg)
    mod = a.topmod
    for step in [s for s in a.path.split("/") if s]:
        for cell, name, _c in mods[mod].insts:
            if name == step and cell in mods:
                mod = cell
                break
        else:
            sys.exit("no instance %s in %s" % (step, mod))
    memo = {}
    regs = Counter()
    subs = Counter()
    for cell, name, _c in mods[mod].insts:
        if cell in mods:
            subs[name] += total(mods, cell, memo)
        elif cell.startswith("DFF") or cell.startswith("DL"):
            regs[base(name)] += 1
    print("%s (%s): %d registers of its own, %d in sub-instances" % (a.path, mod, sum(regs.values()), sum(subs.values())))
    for n, c in subs.most_common():
        print("  %6d  %s/" % (c, n))
    for n, c in regs.most_common(a.top):
        print("  %6d  %s" % (c, n))


if __name__ == "__main__":
    main()
