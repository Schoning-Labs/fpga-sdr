#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
# Checks the output of the alias rejection bench (rx/rx_alias_sim.v, run by run_sim.sh): for each of the eight receivers a full scale
# interferer sits at the frequency that aliases into that receiver's passband, and this script measures how far down it lands, in dB
# below what an on-tune full scale signal would give. Exit status 0 means that every output rate reached 90 dB of rejection.
# Call it after a simulation run, as: python sim/check_alias.py
"""
Checker for sim/tb_alias.v: measures how much of each full-scale, precisely
targeted alias interferer (see tools/analyze_alias.py and
tools/gen_signals/gen_alias_test_signals.py) actually lands in the
corresponding receiver's baseband output, and reports the rejection in dB.

Uses the HIGH-PRECISION capture (sim/out/alias_hires.csv, fir_decim's own
44-bit MAC accumulator, probed directly per receiver before it gets rounded
down to the normal 24-bit output): rejection this deep (100+ dB) is well
below 1 count of the normal rounded output, which would just read as
exactly 0 -- indistinguishable from "barely 90 dB" and "150 dB" alike in an
exact, noiseless simulation with no dither to average out. The 44-bit
accumulator has the headroom to actually resolve it. Falls back to the
normal 24-bit capture (sim/out/alias_capture.csv) if the hi-res file is
missing (e.g. an older sim run), with a clearly reduced-precision report.

Conversion to dB uses a directly-measured linear gain constant (see G_REAL
below): rejection_dB = 20*log10(ADC_FULL_SCALE * G_REAL /
measured_residual_magnitude), i.e. "how many dB below what a full-scale
on-tune signal would produce is what we actually see".
"""
import csv
import json
import os
import sys

import numpy as np

# Capture files (the high precision one is preferred) and the case list written by the signal generator, relative to this script.
HERE = os.path.dirname(os.path.abspath(__file__))
HIRES_PATH = os.path.join(HERE, "out", "alias_hires.csv")
CSV_PATH = os.path.join(HERE, "out", "alias_capture.csv")
META_PATH = os.path.normpath(os.path.join(HERE, "..", "tools", "gen_signals", "out", "alias_test_meta.json"))

# Amplitude, in ADC counts, of the full scale interferer (a little under the 12 bit maximum of 2047).
ADC_FULL_SCALE = 2040.0
# Linear gain from the ADC peak amplitude to the steady state magnitude |I + jQ| of the output for a real on-tune tone. A real
# tone's baseband magnitude is half that of a literal DC input of the same size, since half its power sits in the image sideband
# that the mixing removes. It was measured by feeding a 0 dBFS on-tune tone (peak 2047, with the NCO phase increment matched to a
# 1.84 MHz test cosine) through the whole chain from the mixer through the two CIC stages to the FIR decimator, which settles
# to |out_i + j * out_q| = 10043, so G_REAL = 10043 / 2047 = 4.9062. It does not depend on frequency or rate, since the variable
# CIC stage normalizes every decimation setting to the same gain (identical input through all four settings gives identical output).
G_REAL = 10043.0 / 2047.0

# The MAC accumulator of fir_decim.v is not normalized (its coefficients are fixed point with 19 fractional bits), so dividing by
# 2^19 puts a raw accumulator reading on the same scale as the normal out_i and out_q ports (for a strong unaliased signal the
# accumulator divided by 2^19 matches the out_i reading to within rounding).
HI_SCALE = float(1 << 19)

# Required rejection in dB, at every output rate.
TARGET_DB = 90.0
# Only the back half of each short capture is used, well past the settling of the filters.
SETTLE_FRACTION = 0.5  # short segments -- keep only the back half, well past settling


def load_hires():
    per_rx = {i: [] for i in range(8)}
    with open(HIRES_PATH) as f:
        r = csv.DictReader(f)
        for row in r:
            rx = int(row["rx_index"])
            hi_i, hi_q = int(row["hi_i"]), int(row["hi_q"])
            per_rx[rx].append((hi_i + 1j * hi_q) / HI_SCALE)
    return per_rx


def load_capture():
    per_rx = {i: [] for i in range(8)}
    with open(CSV_PATH) as f:
        r = csv.DictReader(f)
        for row in r:
            rx = int(row["rx_index"])
            try:
                iv, qv = int(row["i"]), int(row["q"])
            except ValueError:
                continue
            per_rx[rx].append(iv + 1j * qv)
    return per_rx


def main():
    hi_res = os.path.exists(HIRES_PATH)
    if not hi_res and not os.path.exists(CSV_PATH):
        print(f"ERROR: neither {HIRES_PATH} nor {CSV_PATH} found -- run the simulation first",
              file=sys.stderr)
        sys.exit(1)

    with open(META_PATH) as f:
        meta = json.load(f)
    cases = {c["rx"]: c for c in meta["cases"]}

    per_rx = load_hires() if hi_res else load_capture()
    resolution_note = ("44-bit pre-rounding MAC accumulator" if hi_res
                        else "24-bit rounded output (reduced precision -- hi-res capture missing)")

    print(f"Reference gain (0 dBFS on-tune -> output magnitude): G_REAL={G_REAL:.4f}, "
          f"reference magnitude = {ADC_FULL_SCALE*G_REAL:.1f}")
    print(f"Measurement source: {resolution_note}")
    print()

    results = []
    for rx in range(8):
        c = cases[rx]
        iq = np.array(per_rx[rx])
        n = len(iq)
        if n < 4:
            print(f"rx{rx}: only {n} samples captured -- FAIL (too few)")
            continue
        # The median of the magnitudes is robust against any transient that is left.
        keep = iq[int(n * SETTLE_FRACTION):]
        mag = np.abs(keep)
        measured = float(np.median(mag))  # robust to any residual transient

        # Smallest magnitude that can be resolved: one count of the 44 bit accumulator after scaling, or 1 for the rounded output. A result
        # below it is reported as ">=" the rejection that the floor allows.
        floor = (1.0 / HI_SCALE) if hi_res else 1.0
        at_floor = measured < floor
        rejection_db = 20 * np.log10((ADC_FULL_SCALE * G_REAL) / max(measured, floor))

        results.append({**c, "measured_mag": measured, "rejection_db": rejection_db,
                         "at_floor": at_floor, "n_captured": n})
        ok = rejection_db >= TARGET_DB
        tag = ">=" if at_floor else " ="
        print(f"rx{rx}  {c['rate']/1e3:>3.0f}ksps {c['stage']:5s}  f={c['freq_hz']/1e6:8.4f} MHz  "
              f"n_captured={n:5d}  measured_mag={measured:12.6f}  "
              f"rejection{tag} {rejection_db:6.1f} dB  (predicted {c['predicted_db']:6.1f} dB)  "
              f"[{'OK' if ok else 'FAIL'}]")

    # Worst case per output rate over the two stages (cic_fixed and cic_var).
    print()
    print("=" * 70)
    print("Worst-case measured alias rejection per output rate (min of cic_fixed, cic_var):")
    all_ok = True
    for rate in (48e3, 96e3, 192e3, 384e3):
        rate_results = [r for r in results if r["rate"] == rate]
        if not rate_results:
            continue
        worst = min(rate_results, key=lambda r: r["rejection_db"])
        ok = worst["rejection_db"] >= TARGET_DB
        all_ok &= ok
        tag = ">=" if worst["at_floor"] else " ="
        print(f"  {rate/1e3:>3.0f} ksps: rejection{tag} {worst['rejection_db']:6.1f} dB "
              f"(worst stage: {worst['stage']}, {worst['freq_hz']/1e6:.4f} MHz)  "
              f"[{'OK' if ok else 'FAIL'}, target {TARGET_DB:.0f} dB]")
    print("=" * 70)
    print("ALL ALIAS CHECKS " + ("PASSED" if all_ok else "FAILED"))
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
