#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
# The timing-margin step of the build (TIMING_MARGIN_PCT), written for this project's constraint file, where a generated clock may have no -divide_by.
"""Tightens the design clocks in a build's copy of the timing constraints.

    python gowin/p1/sdc_margin.py <constraint file, rewritten in place> <percent>

Each `create_generated_clock` line of clk_dsp, clk_pix5, clk_pix and clk_eth (the RJ45 network unit) gets its ratio multiplied by
(100 + percent) / 100 (the three lane clocks of the SFP transceiver, made with `create_clock`, get
their period divided by it), so place-and-route works against a clock that is that many percent faster than the real one.
A design that meets the tightened clocks has that margin on the board. The clocks of the AE350 and of DDR3
are left as they are.
Called by gowin/p1/build.sh when TIMING_MARGIN_PCT is not 0 (docs/TANG_LESSONS.md section 7), on the build's own copy
of the constraints, so the committed constraint file is never changed.  It needs only the standard library.
"""
import math
import re
import sys

CLOCKS = ("clk_dsp", "clk_pix5", "clk_pix", "clk_eth")
LANE_CLOCKS = ("sfp_txc", "n1_rxc", "bl_rxc")   # create_clock lines: the period is shortened (the SFP transceiver's lanes)


def tighten(line, pct):
    """The constraint line `line` made pct percent faster if it defines one of the listed clocks, otherwise unchanged."""
    # A create_clock line of a lane clock: the period is divided by the factor and the waveform (a 50 % duty cycle, 0 to half the period) follows.
    m = re.search(r"-name\s+(\S+)", line)
    if "create_clock" in line and not line.lstrip().startswith("//") and m and m.group(1) in LANE_CLOCKS:
        per = re.search(r"-period\s+([0-9.]+)", line)
        new = float(per.group(1)) * 100.0 / (100 + pct)
        line = re.sub(r"-period\s+[0-9.]+", "-period %.3f" % new, line)
        return re.sub(r"-waveform\s+\{[^}]*\}", "-waveform {0 %.3f}" % (new / 2), line)
    if "create_generated_clock" not in line or line.lstrip().startswith("//") or not m or m.group(1) not in CLOCKS:
        return line
    # A generated clock is described by a ratio multiply_by / divide_by (either may be missing, which means 1).  The faster clock
    # has the ratio times (100 + pct) / 100, and it is kept as a reduced fraction of whole numbers, as the constraint needs.
    mu = re.search(r"-multiply_by\s+(\d+)", line)
    dv = re.search(r"-divide_by\s+(\d+)", line)
    a = (int(mu.group(1)) if mu else 1) * (100 + pct)
    b = (int(dv.group(1)) if dv else 1) * 100
    g = math.gcd(a, b)
    line = re.sub(r"\s*-(multiply|divide)_by\s+\d+", "", line)
    if " [get_pins" not in line:
        raise SystemExit("sdc_margin: no [get_pins ...] target in: " + line.strip())
    return line.replace(" [get_pins", " -multiply_by %d -divide_by %d [get_pins" % (a // g, b // g), 1)


def main():
    """Rewrites the constraint file given as the first argument in place, tightened by the percentage given as the second."""
    path, pct = sys.argv[1], int(sys.argv[2])
    with open(path, encoding="utf-8") as f:
        lines = [tighten(x, pct) for x in f]
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("".join(lines))


if __name__ == "__main__":
    main()
