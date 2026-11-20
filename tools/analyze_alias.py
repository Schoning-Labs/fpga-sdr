#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
"""
Analytical worst-case alias rejection of the receiver's decimation chain (cic_fixed, then cic_var, then fir_decim, all in rtl/rx).

The question it answers is this: for a full-scale signal anywhere between 0 and 38.4 MHz (the Nyquist range of the 76.8 MHz
input), how little does the chain attenuate it before its alias lands inside the final output passband?  The answer is
worked out per output rate (48, 96, 192 and 384 kHz) and separately for the cic_fixed stage, the cic_var stage and fir_decim,
whose own figure is the stopband number that tools/gen_fir_coeffs.py prints.

Why this is a calculation and not just a test with a few tones: a decimating CIC stage lets through only narrow bands, a few kHz
wide, that sit at exact multiples of that stage's output rate away from the tuned frequency (a few hundred kHz to a few MHz
away in this design), and tones at arbitrary frequencies almost never land in them.  A multi-tone test therefore looks clean
whether the filter is good or bad.  This script finds the exact frequencies, so that tools/gen_signals/gen_alias_test_signals.py
can place a strong interferer on one and sim/check_alias.py can measure in simulation what really gets through.

The stages are scored one at a time and the smallest of the three figures is the prediction.  tools/analyze_zoom_alias.py,
for the zoom receiver, instead scores every candidate frequency against the whole chain at once.

Run: python tools/analyze_alias.py  (needs numpy)
Writes: tools/gen_signals/out/alias_plan.json (read by the signal generator and the checker) and prints the table of the
worst case per rate and per stage.
"""
import json
import os

import numpy as np

# The chain's parameters, which have to match the instances in the Verilog: sample rate at the input, then for each stage its
# decimation D and its order N (the number of integrator and comb pairs).
FS_ADC = 76.8e6
CIC1_D, CIC1_N = 10, 3          # rtl/rx/rx_channel.v cic_fixed instance
CIC2_N = 5                       # rtl/rx/rx_channel.v cic_var instance
FIR_TAPS, FIR_DECIM = 65, 4
FIR_OWN_REJECTION_DB = 99.2      # from tools/gen_fir_coeffs.py's printed stopband number

# Decimation of cic_var for each final output rate: 76.8 MHz / 10 / (40 * 4) = 48 kHz, and so on, the FIR taking the last 4.
RATE_TO_CIC2_DECIM = {48e3: 40, 96e3: 20, 192e3: 10, 384e3: 5}
# usable passband half-width per rate: +/-48% of the full output Nyquist
# (see docs/RX_DSP.md section 3, fir_decim's designed passband edge)
PASSBAND_HALF_WIDTH = {r: 0.48 * (r / 2.0) for r in RATE_TO_CIC2_DECIM}

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_PATH = os.path.join(HERE, "gen_signals", "out", "alias_plan.json")


def cic_mag_db(f, D, N, Fs):
    """|H(f)| in dB of an order-N, decimate-by-D CIC, DC-normalized to 0 dB,
    input sampled at Fs.  The magnitude is (sin(pi f D / Fs) / (D sin(pi f / Fs))) to the power N, with the value 1 where
    the denominator is zero (f at a multiple of Fs), and it is floored at -300 dB so the logarithm stays finite at the nulls."""
    f = np.asarray(f, dtype=float)
    x = np.pi * f / Fs
    num = np.sin(np.pi * f * D / Fs)
    den = D * np.sin(x)
    with np.errstate(divide="ignore", invalid="ignore"):
        h = np.where(np.abs(np.sin(x)) < 1e-12, 1.0, num / den)
    return 20 * np.log10(np.maximum(np.abs(h) ** N, 1e-15))


def worst_case(Fs, D, N, edge):
    """Search every alias band (near every multiple of Fout=Fs/D, within
    +/-edge of it, since that is exactly what folds inside a final passband
    of half-width `edge`) for the least-attenuated (worst-case) point.
    Returns (attenuation_db, frequency_hz)."""
    # Each band is scanned with 600 points, which is fine enough because a band is only a few kHz wide.
    Fout = Fs / D
    nmax = int(np.floor(Fs / 2 / Fout)) + 1
    worst_atten = 1e9
    worst_f = None
    for k in range(1, nmax + 1):
        f0 = k * Fout
        lo, hi = max(f0 - edge, 1e-6), min(f0 + edge, Fs / 2)
        if hi <= lo:
            continue
        fs_scan = np.linspace(lo, hi, 600)
        mag_db = cic_mag_db(fs_scan, D, N, Fs)
        i = np.argmax(mag_db)  # least attenuation = worst case
        atten = -mag_db[i]
        if atten < worst_atten:
            worst_atten, worst_f = atten, fs_scan[i]
    return worst_atten, worst_f


def fold(f, Fout):
    """Fold frequency f (Hz) into [-Fout/2, Fout/2] the way a real decimating
    filter's output spectrum would alias it."""
    return f - round(f / Fout) * Fout


def fold_through_chain(f_rf, rate):
    """Track a frequency from ADC input, through cic_fixed -> cic_var ->
    fir_decim, returning its final baseband offset in the receiver's IQ
    output (Hz)."""
    # After each decimation the frequency is folded into the new, lower Nyquist range, so three folds follow each other.
    f = f_rf
    f = fold(f, FS_ADC / CIC1_D)
    f = fold(f, (FS_ADC / CIC1_D) / RATE_TO_CIC2_DECIM[rate])
    f = fold(f, ((FS_ADC / CIC1_D) / RATE_TO_CIC2_DECIM[rate]) / FIR_DECIM)
    return f


def main():
    """Prints the worst-case table for the four output rates and writes the plan file the signal generator reads."""
    plan = {"rates": {}}
    print(f"{'rate':>8}  {'cic_fixed worst':>22}  {'cic_var worst':>22}  {'overall predicted':>18}")
    for rate, cic2_d in RATE_TO_CIC2_DECIM.items():
        edge = PASSBAND_HALF_WIDTH[rate]

        a1_db, a1_f = worst_case(FS_ADC, CIC1_D, CIC1_N, edge)
        Fs_cic1_out = FS_ADC / CIC1_D
        a2_db, a2_f = worst_case(Fs_cic1_out, cic2_d, CIC2_N, edge)

        # The weakest stage sets the prediction (see the module docstring).
        overall = min(a1_db, a2_db, FIR_OWN_REJECTION_DB)
        print(f"{rate/1e3:>6.0f}k  {a1_db:8.1f} dB @ {a1_f/1e6:7.4f} MHz  "
              f"{a2_db:8.1f} dB @ {a2_f/1e6:7.4f} MHz  {overall:14.1f} dB")

        plan["rates"][str(int(rate))] = {
            "rate_hz": rate,
            "cic1_worst_db": a1_db, "cic1_worst_freq_hz": a1_f,
            "cic1_landing_offset_hz": fold_through_chain(a1_f, rate),
            "cic2_worst_db": a2_db, "cic2_worst_freq_hz": a2_f,
            "cic2_landing_offset_hz": fold_through_chain(a2_f, rate),
            "fir_own_rejection_db": FIR_OWN_REJECTION_DB,
            "predicted_overall_db": overall,
        }

    os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
    with open(OUT_PATH, "w") as f:
        json.dump(plan, f, indent=2)
    print(f"\nWritten to {OUT_PATH}")


if __name__ == "__main__":
    main()
