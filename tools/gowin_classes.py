#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
"""Path classes of one clock from a Gowin timing report.

The Gowin timing report lists the worst paths one by one, and for a big design that is thousands of lines in which the same
RTL statement shows up once per bit.  This script reads the HTML report (the file ending in _tr_content.html in the build's
impl folder) and groups the paths so that one line stands for one RTL statement, which is much easier to read when looking for
what limits the clock.  It only reads the report that is given as the first argument, and does not need the Gowin software.

    python tools/gowin_classes.py <..._tr_content.html> [clock, default clk_dsp] [period ns for the Fmax column]
                                 [--min-levels N] [--top K] [--strip PREFIX]

A class is the set of listed setup paths with the same start and end register after the bit numbers, the
copy numbers of generated blocks and the pipeline number are removed: one RTL statement. Per class: number
of end points listed, worst slack, the delay of the worst path (cell + route, route share), the largest
number of logic levels, the largest fan-out of a net on the worst path, and the frequency the worst path
allows alone (1 / (period - slack)). The report lists as many paths as the constraint file asks for
(`report_timing -setup -max_paths N`, SUG940 section 5.5.1).
"""
import re
import sys


def norm(n, strip):
    """Turns a register or pin name from the report into the name of its class.

    The prefixes in `strip` are cut off, then the pin name at the end (/CLK, /Q, /D and so on), bit numbers, the suffixes the
    synthesis tool adds (_s0, _G[0], mem_mem_n_n) and generated copy numbers are removed, so that all bits of one register
    and all copies of one generated block get the same name.
    """
    for s in strip:
        n = n.replace(s, "")
    n = re.sub(r"/(CLK|Q|D|DI\[\d+\]|CE|F|I\d|COUT|CIN|SUM|DO\[\d+\]|AD\[\d+\]|A\[\d+\]|B\[\d+\]|C\[\d+\]|DOUT\[\d+\]|WAD\[\d+\]|RAD\[\d+\]|WRE)$", "", n)
    n = re.sub(r"pp\[\d\]", "pp[]", n)
    n = re.sub(r"_\d+_s\d+$", "", n)            # bit number and the tool's suffix
    n = re.sub(r"_s\d+$", "", n)
    n = re.sub(r"_\d+_G\[\d+\]$", "", n)
    n = re.sub(r"mem_mem_\d+_\d+$", "mem", n)
    n = re.sub(r"_\d+$", "", n)
    return n


def paths(text, clock):
    """The setup paths in the report text that start and end in `clock`, each as a dict.

    The keys are slack (ns), from and to (register names), levels (logic levels), cell and route (delay in ns, the flip-flop's
    clock-to-output counted as cell delay) and fan (the largest fan-out of a net on the path).  Hold paths are left out, because
    the search stops at the hold section of the report.
    """
    a = text.find('name="Setup_Analysis"')
    if a < 0:
        a = text.find("Setup Analysis Report")
    b = text.find("Hold Analysis Report", a)
    out = []
    for blk in re.split(r"<h3>Path\d+</h3>", text[a:b if b > 0 else len(text)])[1:]:
        lab = dict(re.findall(r'<td class="label">([^<]*)</td>\s*<td>([^<]*)</td>', blk))
        lab = {x.strip(): y.strip() for x, y in lab.items()}
        if "Slack" not in lab or not lab.get("Launch Clk", "").startswith(clock) or not lab.get("Latch Clk", "").startswith(clock):
            continue
        d = lab.get("Arrival Data Path Delay", "")
        g = lambda k: float(re.search(k + r":\s*([\d.]+)", d).group(1)) if k + ":" in d else 0.0
        # rows of the data arrival path: AT, DELAY, TYPE, RF, FANOUT, LOC, NODE
        arr = blk[blk.find("Data Arrival Path"):blk.find("Data Required Path")]
        fan, src = 0, lab.get("From", "")
        seen = False
        for row in re.findall(r"<tr>(.*?)</tr>", arr, flags=re.S):
            c = [re.sub(r"<[^>]+>", "", x).strip() for x in re.findall(r"<td[^>]*>(.*?)</td>", row, flags=re.S)]
            if len(c) < 7:
                continue
            if c[2] == "tC2Q":
                seen = True
            if seen and c[2] in ("tC2Q", "tINS") and c[4].isdigit():
                fan = max(fan, int(c[4]))
        out.append({"slack": float(lab["Slack"]), "from": src, "to": lab.get("To", ""),
                    "levels": int(float(lab.get("Logic Level", "0"))), "cell": g("cell") + g("tC2Q"), "route": g("route"),
                    "fan": fan})
    return out


def main():
    """Reads the report, groups its paths into classes and prints them as a Markdown table, the worst class first."""
    # The options are looked up by hand: av is the list of positional arguments (report, clock, period), and the value that
    # follows an option such as --top is taken out of it again.
    av = [x for x in sys.argv[1:] if not x.startswith("--")]
    opt = sys.argv[1:]
    val = lambda k, d: opt[opt.index(k) + 1] if k in opt else d
    if "--min-levels" in opt:
        av = [x for x in av if x != val("--min-levels", "")]
    if "--top" in opt:
        av = [x for x in av if x != val("--top", "")]
    if "--strip" in opt:
        av = [x for x in av if x != val("--strip", "")]
    clock = av[1] if len(av) > 1 else "clk_dsp"
    period = float(av[2]) if len(av) > 2 else None
    minlev = int(val("--min-levels", "0"))
    top = int(val("--top", "60"))
    strip = [val("--strip", "u_core/")]
    ps = paths(open(av[0], encoding="utf-8", errors="replace").read(), clock)
    cl = {}
    for p in ps:
        k = (norm(p["from"], strip), norm(p["to"], strip))
        c = cl.setdefault(k, {"n": 0, "worst": p, "lev": 0, "ends": set()})
        c["ends"].add(p["to"])
        c["lev"] = max(c["lev"], p["levels"])
        if p["slack"] < c["worst"]["slack"]:
            c["worst"] = p
    rows = sorted(cl.items(), key=lambda kv: kv[1]["worst"]["slack"])
    rows = [r for r in rows if r[1]["lev"] >= minlev]
    print(f"{len(ps)} paths of {clock} listed, {len(cl)} classes, slack of the last listed path "
          f"{max(p['slack'] for p in ps):+.3f} ns" if ps else "no paths")
    print("| Start -> end | End points | Worst slack | Levels | Cell | Route | Route % | Fan-out | Alone MHz |")
    print("|---|---|---|---|---|---|---|---|---|")
    for (f, t), c in rows[:top]:
        w = c["worst"]
        tot = w["cell"] + w["route"]
        mhz = f"{1000.0 / (period - w['slack']):.0f}" if period else ""
        print(f"| {f} -> {t} | {len(c['ends'])} | {w['slack']:+.2f} | {c['lev']} | {w['cell']:.2f} | {w['route']:.2f} | "
              f"{100 * w['route'] / (tot or 1):.0f} | {w['fan']} | {mhz} |")


if __name__ == "__main__":
    main()
