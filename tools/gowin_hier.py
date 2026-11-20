#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
"""Per-module resource table from a Gowin synthesis hierarchy report.

Reads impl/gwsynthesis/<top>_syn_rsc.xml (written by every gowin/p1/build.sh and gowin/res.sh run) and
prints a Markdown table of the totals (the module and everything below it) for the instances named on the
command line. With no instance named: the top, its direct sub-modules and theirs (two levels).

    python tools/gowin_hier.py gowin/impl/sdr_top/impl/gwsynthesis/sdr_top_syn_rsc.xml [path ...]

A path is instance names from the top down, separated by '/', e.g. u_core/u_rx_bank.
"""
import re
import sys
import xml.etree.ElementTree as ET

def tot(e, key):
    """The total (the instance and everything below it) of the resource `key` in an XML element, 0 when it is not listed.
    A value such as "123(45)" is read as its leading number."""
    v = e.get("T_" + key)
    if v is None:
        v = e.get(key)
    if v is None:
        return 0
    m = re.match(r"(\d+)", v)
    return int(m.group(1)) if m else 0


def find(root, path):
    """The XML element of the instance at `path` (names separated by '/'), or None if there is no such instance."""
    e = root
    for name in path.split("/"):
        nxt = None
        for c in e.findall("SubModule"):
            if c.get("name") == name:
                nxt = c
                break
        if nxt is None:
            return None
        e = nxt
    return e


def main():
    """Prints one Markdown table row for the whole design and for each requested instance."""
    xml = sys.argv[1]
    root = ET.parse(xml).getroot()
    paths = sys.argv[2:]
    if not paths:
        for c in root.findall("SubModule"):
            paths.append(c.get("name"))
            paths += [c.get("name") + "/" + g.get("name") for g in c.findall("SubModule")]
    print("| Instance | LUT | ALU | Registers | BSRAM | SSRAM (LUT-RAM) | DSP (27x18 + 27x36) |")
    print("|---|---|---|---|---|---|---|")
    rows = [("%s (all)" % (root.get("name") or "top"), root)] + [(p, find(root, p)) for p in paths]
    for name, e in rows:
        if e is None:
            print(f"| {name} | (not found) | | | | | |")
            continue
        dsp = tot(e, "MULTALU27X18") + tot(e, "MULT27X36") + tot(e, "MULTADDALU27X18") + tot(e, "MULT18X18")
        print(f"| {name} | {tot(e, 'Lut')} | {tot(e, 'Alu')} | {tot(e, 'Register')} | {tot(e, 'Bsram')} | "
              f"{tot(e, 'Ssram')} | {dsp} |")


if __name__ == "__main__":
    main()
