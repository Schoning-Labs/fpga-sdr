#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
"""Spectral test of the receive NCO mixer (rtl/rx/nco_mixer.v, MODE 0): how clean the mixer's output is.

The mixer multiplies the input by a sine and a cosine from a table, with a correction term, and any error in that shows up as
spurious lines in the output spectrum.  The test measures them with random settings and compares against an ideal mixer.

For each of CASES random 32-bit tuning words, a full-scale 12-bit tone (random frequency and
phase) goes through the RTL (sim/rx/nco_sfdr_sim.v under iverilog); the 4,096 outputs are
windowed (Kaiser, beta 38: sidelobes far below -200 dB) and FFT'd. A real input tone gives two
output tones, at f_nco + f_tone and f_nco - f_tone, each G x 2047 / 2; both are excluded.

Reported per case, and as the worst over all cases:
  - mixer spurious-free range: the largest bin of the spectrum of (output - ideal output), the
    ideal being G x e^(j 2 pi phase / 2^32) times the SAME 12-bit input words, relative to one
    output tone. This is the mixer's own spur level (target: at least 100 dBc).
  - output spurious-free range: the largest bin of the output spectrum outside the two tones.
    This includes the input tone's own 12-bit quantization spurs, which an ideal mixer passes
    unchanged; it is also computed for that ideal output, to show the mixer adds nothing.
  - level error: each tone's level (windowed correlation at its exact frequency) against the same
    measurement of the ideal output (target: within 0.01 dB), and against G x 2047 / 2.

Usage, from anywhere: python tools/rb4_nco_sfdr.py [cases]   (default 1000; about 10 minutes)
Exit status 0 when every case meets both targets.

It needs numpy, and iverilog and vvp on the PATH (oss-cad-suite, which is in C:/tools/oss-cad-suite on the author's PC, so
put its bin folder on the PATH, or start the script from the shell that oss-cad-suite's environment script provides).  It
writes its working files into sim/out of the repository.
"""
import os
import subprocess
import sys

import numpy as np

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
OUT = os.path.join(REPO, "sim", "out")
NS = 4096              # output samples analyzed per case
G = 107922 / 2048      # the mixer's gain, table amplitude A over 2048 (see tools/gen_nco_table.py)
AMP = 2047.0           # full-scale 12-bit tone amplitude


def run_sim(cases):
    """Writes the cases (tuning word, tone frequency, tone phase), runs the Verilog simulation and returns its output as an array of shape (cases, NS, 4)."""
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "nco_sfdr_cases.txt"), "w", newline="\n") as f:
        f.write(f"{len(cases)}\n")
        for w, ft, pt in cases:
            f.write(f"{w} {ft:.12f} {pt:.12f}\n")
    vvp = os.path.join(OUT, "nco_sfdr.vvp")
    subprocess.run(["iverilog", "-g2012", "-o", vvp, "sim/rx/nco_sfdr_sim.v"], cwd=REPO, check=True)
    subprocess.run(["vvp", vvp], cwd=REPO, check=True, stdout=subprocess.DEVNULL)
    with open(os.path.join(OUT, "nco_sfdr_out.txt")) as f:
        d = np.array(f.read().split(), dtype=np.int64).reshape(-1, 4)
    assert d.shape[0] == len(cases) * NS, d.shape
    return d.reshape(len(cases), NS, 4)


def analyse(block, w, ft):
    """Measures one case: returns the mixer's own spur level, the output's spur level, the ideal mixer's spur level (all in dBc) and the two tone level errors in dB."""
    # block holds, per output sample, the input word, the NCO phase and the I and Q outputs.
    x, ph, oi, oq = (block[:, i] for i in range(4))
    n = np.arange(NS)
    win = np.kaiser(NS, 38.0)
    wsum = win.sum()
    z = oi + 1j * oq
    ideal = G * x * np.exp(2j * np.pi * ph / 2.0**32)
    fn = w / 2.0**32
    freqs = np.fft.fftfreq(NS)
    mask = np.ones(NS, bool)
    for t in (fn + ft, fn - ft):
        dist = np.abs(((freqs - t + 0.5) % 1.0) - 0.5) * NS
        mask &= dist > 16
    ref = G * AMP / 2

    def spur(v, m):
        """The strongest bin of the windowed spectrum of v among the bins selected by mask m, in dB below one output tone."""
        return 20 * np.log10(ref / (np.abs(np.fft.fft(v * win))[m].max() / wsum))

    def level(v, t):
        """The amplitude of v at the exact normalized frequency t, by windowed correlation (not limited to FFT bins)."""
        return np.abs(np.sum(win * v * np.exp(-2j * np.pi * t * n))) / wsum

    lv = []
    for t in (fn + ft, fn - ft):
        lo, li = level(z, t), level(ideal, t)
        lv.append((20 * np.log10(lo / li), 20 * np.log10(lo / ref)))
    return (spur(z - ideal, np.ones(NS, bool)), spur(z, mask), spur(ideal, mask), lv)


def main():
    """Runs the requested number of random cases, prints the worst and median figures and returns 0 for PASS (mixer spurs at least 100 dBc down, level within 0.01 dB of ideal)."""
    ncases = int(sys.argv[1]) if len(sys.argv) > 1 else 1000
    rng = np.random.default_rng(4)
    cases = [(int(rng.integers(1, 2**32)), float(rng.uniform(0.003, 0.497)), float(rng.uniform(0, 2 * np.pi)))
             for _ in range(ncases)]
    blocks = run_sim(cases)
    res = [analyse(blocks[i], cases[i][0], cases[i][1]) for i in range(ncases)]
    mix = np.array([r[0] for r in res])
    out = np.array([r[1] for r in res])
    idl = np.array([r[2] for r in res])
    lv_ideal = np.array([[l[0] for l in r[3]] for r in res])
    lv_abs = np.array([[l[1] for l in r[3]] for r in res])
    worst = int(np.argmin(mix))
    print(f"{ncases} random tuning words, full-scale 12-bit tone, {NS}-point FFT (Kaiser 38)")
    print(f"mixer spurious-free range (spectrum of output - ideal): worst {mix.min():.1f} dBc "
          f"(word {cases[worst][0]:#010x}), median {np.median(mix):.1f} dBc")
    print(f"output spurious-free range: worst {out.min():.1f} dBc, median {np.median(out):.1f} dBc; "
          f"ideal mixer on the same input: worst {idl.min():.1f} dBc; "
          f"largest difference output - ideal {np.max(idl - out):.2f} dB")
    print(f"level error against the ideal mixer: worst {np.abs(lv_ideal).max():.5f} dB; "
          f"against G x 2047 / 2: {lv_abs.min():+.5f} .. {lv_abs.max():+.5f} dB")
    ok = mix.min() >= 100.0 and np.abs(lv_ideal).max() <= 0.01
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
