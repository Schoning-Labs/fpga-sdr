#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
"""
Constant tables for the receiver back end (docs/R4_BACKEND.md): the half-band decimator taps, the logarithm and exponential
tables of the level measurement, the CORDIC constants and a sine for the testbench.

One run writes every table twice, once for the RTL and once for the bit-exact Rust model, so the
two can never disagree:

    rtl/rx_backend/bk_hb.hex        half-band decimator taps: {offset[5:0], coefficient[25:0]}
    rtl/rx_backend/bk_log2.hex      1,024 x 12 bit: round(4096 * log2(1 + i/1024))
    rtl/rx_backend/bk_exp2.hex      1,024 x 17 bit: round(65536 * 2^(i/1024))
    rtl/rx_backend/bk_consts.vh     CORDIC arctangent table, 1/K, half-band stage layout
    sim/rx_backend/bk_sine.hex      1,024 x 18 bit sine, only for the testbench stimulus
    fw/tr-dsp/src/backend/tables.rs the same numbers as Rust constants

`cargo test -p tr-dsp backend::tables` re-reads the .hex files and fails if they and tables.rs
differ, so a table edited on one side only is caught.

Half-band design: equiripple (scipy remez) by the usual trick of designing the (N+1)/2-tap
single-band filter and interleaving it with zeros; the center tap is exactly 0.5. Pass band
+/-9.6 kHz at every stage (docs/R4_BACKEND.md section 3.2 gives the reasoning). Coefficients are
Q25 in 26-bit two's complement, center 0.5 = 2^24.

Run from anywhere (the output folders are found from the script's own location; needs numpy and scipy):
    python tools/gen_rx_backend_tables.py
"""
import math
import os

import numpy as np
from scipy.signal import freqz, remez

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RTL = os.path.join(ROOT, "rtl", "rx_backend")
SIM = os.path.join(ROOT, "sim", "rx_backend")
RS = os.path.join(ROOT, "fw", "tr-dsp", "src", "backend", "tables.rs")

PASS_HZ = 9600.0
# The four half-band decimate-by-2 stages take 384 ksps down to 24 ksps.
# (name, input rate, taps, delay-line length in words)
STAGES = [
    ("HB1", 384000.0, 11, 16),
    ("HB2", 192000.0, 15, 16),
    ("HB3", 96000.0, 23, 32),
    ("HB4", 48000.0, 63, 64),
]
HB_FRAC = 25            # Q25
HB_WIDTH = 26

CORDIC_ITER = 20
ANGLE_BITS = 24         # angle in turns, 2^24 = one turn
KINV_FRAC = 17

LOG2_ENTRIES = 1024
LOG2_FRAC = 12
EXP2_ENTRIES = 1024
EXP2_FRAC = 16
SINE_ENTRIES = 1024
SINE_FRAC = 17          # sine table Q17 in 18 bits


def hb_design(n_taps, fp):
    """Real-valued taps of a half-band lowpass with n_taps taps and passband edge fp (as a fraction of the input rate).

    In a half-band filter every second tap except the center one is zero and the center tap is 0.5.  The nonzero taps
    form a short filter of (n_taps + 1) / 2 taps that is designed here at twice the frequency scale (passband edge 2 fp,
    stopband from 0.5), and then spread out with zeros in between, which halves all frequencies again.
    """
    m = (n_taps + 1) // 2
    assert m % 2 == 0, "half-band length must be 4k+3"
    g = remez(m, [0, 2 * fp, 0.5, 0.5], [1, 0], weight=[1, 1], fs=1.0)
    h = np.zeros(n_taps)
    h[0::2] = g / 2
    h[(n_taps - 1) // 2] = 0.5
    return h


def hb_taps():
    """Returns [(stage, [(offset, coef_q25), ...]), ...] and prints each stage's response."""
    out = []
    for name, fs_in, n, length in STAGES:
        assert n <= length
        fp = PASS_HZ / fs_in
        h = hb_design(n, fp)
        centre = (n - 1) // 2
        taps = []
        for k in range(n):
            if k == centre:
                taps.append((k, 1 << (HB_FRAC - 1)))
            elif k % 2 == 0:
                c = int(round(h[k] * (1 << HB_FRAC)))
                assert -(1 << (HB_WIDTH - 1)) <= c < (1 << (HB_WIDTH - 1))
                taps.append((k, c))
        q = np.zeros(n)
        for k, c in taps:
            q[k] = c / (1 << HB_FRAC)
        w, hq = freqz(q, worN=1 << 16, fs=1.0)
        stop = np.abs(hq[w >= 0.5 - fp]).max()
        pas = np.abs(hq[w <= fp])
        print(f"{name}: {fs_in/1e3:.0f} ksps in, {n} taps ({len(taps)} non-zero), "
              f"stop band from {(0.5 - fp) * fs_in / 1e3:.1f} kHz: {20*math.log10(stop):.1f} dB, "
              f"pass-band ripple {20*math.log10(pas.max()/pas.min()):.2e} dB")
        out.append((name, taps, length))
    return out


def tw(v, bits):
    """Two's complement of v in `bits` bits, as an unsigned int."""
    return v & ((1 << bits) - 1)


def main():
    """Writes every table for the RTL, the testbench and the Rust model (see the module docstring for the list)."""
    os.makedirs(RTL, exist_ok=True)
    os.makedirs(SIM, exist_ok=True)

    stages = hb_taps()
    flat = []
    layout = []  # (start, count, length)
    for name, taps, length in stages:
        layout.append((len(flat), len(taps), length))
        flat.extend(taps)
    with open(os.path.join(RTL, "bk_hb.hex"), "w", newline="\n") as f:
        for off, c in flat:
            f.write(f"{(off << HB_WIDTH) | tw(c, HB_WIDTH):08x}\n")

    # Lookup tables for the level measurement: the fraction of a base-2 logarithm and its inverse, each with 1,024 entries.
    log2 = [int(round((1 << LOG2_FRAC) * math.log2(1 + i / LOG2_ENTRIES))) for i in range(LOG2_ENTRIES)]
    exp2 = [int(round((1 << EXP2_FRAC) * 2 ** (i / EXP2_ENTRIES))) for i in range(EXP2_ENTRIES)]
    assert max(log2) < (1 << LOG2_FRAC) and max(exp2) < (1 << (EXP2_FRAC + 1))
    with open(os.path.join(RTL, "bk_log2.hex"), "w", newline="\n") as f:
        f.writelines(f"{v:03x}\n" for v in log2)
    with open(os.path.join(RTL, "bk_exp2.hex"), "w", newline="\n") as f:
        f.writelines(f"{v:05x}\n" for v in exp2)

    # CORDIC: the angle of each micro-rotation atan(2^-i) in 1/2^24 turn, and 1/K, the inverse of the gain K that
    # 20 iterations add to the vector length (K is the product of sqrt(1 + 2^(-2i))).
    atan = [int(round(math.atan(2.0 ** -i) / (2 * math.pi) * (1 << ANGLE_BITS))) for i in range(CORDIC_ITER)]
    k = 1.0
    for i in range(CORDIC_ITER):
        k *= math.sqrt(1 + 2.0 ** (-2 * i))
    kinv = int(round((1 << KINV_FRAC) / k))

    sine = [int(round(((1 << SINE_FRAC) - 1) * math.sin(2 * math.pi * i / SINE_ENTRIES))) for i in range(SINE_ENTRIES)]
    with open(os.path.join(SIM, "bk_sine.hex"), "w", newline="\n") as f:
        f.writelines(f"{tw(v, 18):05x}\n" for v in sine)

    hdr = "// SPDX-License-Identifier: Apache-2.0\n// Copyright 2026 Franz Schöning, https://www.schoning.com\n"
    with open(os.path.join(RTL, "bk_consts.vh"), "w", newline="\n", encoding="utf-8") as f:
        f.write(hdr)
        f.write("//\n// GENERATED by tools/gen_rx_backend_tables.py -- do not edit. Receiver back-end constants\n")
        f.write("// (docs/R4_BACKEND.md). Included inside a module body.\n\n")
        f.write(f"localparam integer BK_CORDIC_ITER = {CORDIC_ITER};\n")
        f.write(f"localparam integer BK_KINV = {kinv};   // round(2^{KINV_FRAC} / K), K = {k:.10f}\n")
        f.write("function [23:0] bk_atan;\n    input [4:0] i;\n    case (i)\n")
        for i, a in enumerate(atan):
            f.write(f"        5'd{i}: bk_atan = 24'd{a};\n")
        f.write("        default: bk_atan = 24'd0;\n    endcase\nendfunction\n")
        for s, (start, count, length) in enumerate(layout):
            f.write(f"localparam integer BK_HB{s+1}_START = {start}, BK_HB{s+1}_COUNT = {count}, BK_HB{s+1}_LEN = {length};\n")
        f.write(f"localparam integer BK_HB_ENTRIES = {len(flat)};\n")

    def arr(name, ty, vals, per_line=12):
        """The text of a Rust `pub const NAME: [ty; N]` array holding vals, per_line numbers to a line."""
        s = f"pub const {name}: [{ty}; {len(vals)}] = [\n"
        for i in range(0, len(vals), per_line):
            s += "    " + ", ".join(str(v) for v in vals[i:i + per_line]) + ",\n"
        return s + "];\n"

    os.makedirs(os.path.dirname(RS), exist_ok=True)
    with open(RS, "w", newline="\n", encoding="utf-8") as f:
        f.write(hdr)
        f.write("\n//! GENERATED by `tools/gen_rx_backend_tables.py` -- do not edit. Constant tables of the\n")
        f.write("//! receiver back end (docs/R4_BACKEND.md); the RTL reads the same numbers from\n")
        f.write("//! `rtl/rx_backend/*.hex` and `bk_consts.vh` (checked equal by `backend::tests::tables_match_rtl_hex`).\n\n")
        f.write(f"pub const CORDIC_ITER: usize = {CORDIC_ITER};\n")
        f.write(f"/// round(2^{KINV_FRAC} / K), K = {k:.10f} (CORDIC gain after {CORDIC_ITER} iterations).\n")
        f.write(f"pub const KINV: i64 = {kinv};\n")
        f.write("/// round(atan(2^-i) / 2pi * 2^24): CORDIC angle steps in 1/2^24 turn.\n")
        f.write(arr("ATAN", "i64", atan, 5))
        f.write("/// Half-band stages HB1..HB4: (first entry in HB_TAPS, number of entries, delay-line length).\n")
        f.write("pub const HB_LAYOUT: [(usize, usize, usize); 4] = [" + ", ".join(f"({a}, {b}, {c})" for a, b, c in layout) + "];\n")
        f.write("/// Half-band taps: (offset into the delay line, coefficient Q25). The centre tap is 0.5.\n")
        f.write("pub const HB_TAPS: [(usize, i64); %d] = [\n" % len(flat))
        for off, c in flat:
            f.write(f"    ({off}, {c}),\n")
        f.write("];\n")
        f.write("/// round(4096 * log2(1 + i/1024)).\n")
        f.write(arr("LOG2", "u16", log2, 16))
        f.write("/// round(65536 * 2^(i/1024)).\n")
        f.write(arr("EXP2", "u32", exp2, 12))
        f.write("/// round(131071 * sin(2 pi i / 1024)): test stimulus only (also `sim/rx_backend/bk_sine.hex`).\n")
        f.write(arr("SINE", "i32", sine, 12))
    print(f"CORDIC: {CORDIC_ITER} iterations, K = {k:.10f}, KINV = {kinv}")
    print("wrote", os.path.relpath(RTL, ROOT), os.path.relpath(SIM, ROOT), os.path.relpath(RS, ROOT))


if __name__ == "__main__":
    main()
