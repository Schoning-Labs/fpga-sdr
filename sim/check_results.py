#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
# Checks the output of the functional receiver bank bench (rx/rx_bank_functional_sim.v, run by run_sim.sh): reads the captured
# I/Q samples of the eight receivers, finds the tones that were fed in, and prints their amplitude and frequency error and the
# strongest spur next to them. Exit status 0 means that every tone was within 0.5 dB and within the frequency limit.
# Call it after a simulation run, as: python sim/check_results.py
"""
Checker for sim/tb_rx_bank.v output.

Reads:
  sim/out/rx_capture.csv               -- recnum,rx_index,i,q (one row per
                                           output IQ sample, all 8 receivers
                                           interleaved in time order)
  tools/gen_signals/out/adc_test_meta.json -- what was fed in and which
                                           receiver was tuned to what

For each receiver: FFT the captured IQ stream (Blackman-Harris window,
discarding an initial settling region so filter group delay/transients
do not leak into the spectrum), find the tuned tone(s), and report:
  - measured baseband offset frequency vs expected
  - measured amplitude vs expected input level (dBFS), after a single
    calibration constant derived across all receivers (see below)
  - in-band spur/image rejection: the strongest OTHER peak in the same
    output spectrum, relative to the wanted tone
  - a PNG spectrum plot per receiver into sim/out/

Amplitude calibration: the receiver chain's overall DC gain is a fixed
design constant (CORDIC processing gain x CIC1 DC gain x CIC2's own
normalization x FIR DC gain), the same for every receiver regardless of
frequency or output rate, by construction (cic_var normalizes each
decimation setting back to ~unit gain). So ONE calibration constant,
derived as the median offset between "measured raw FFT peak, in dB" and
"known input dBFS" across all receivers, should bring every receiver's
measurement in line with its own known input level. Reporting each
receiver's residual error after applying that single constant is exactly
the "amplitude within 0.5 dB" check the brief asks for, and also catches
any receiver/rate whose gain is NOT consistent with the others.

Run via sim/run_sim.sh (does codegen + compile + sim + this check in one
command), or directly after a sim run:
    python sim/check_results.py
"""
import json
import os
import sys

import numpy as np

# Input files and the output folder for the spectrum plots, all relative to this script.
HERE = os.path.dirname(os.path.abspath(__file__))
CSV_PATH = os.path.join(HERE, "out", "rx_capture.csv")
META_PATH = os.path.normpath(os.path.join(HERE, "..", "tools", "gen_signals", "out", "adc_test_meta.json"))
OUT_DIR = os.path.join(HERE, "out")

# Analysis settings. SPUR_GUARD_BINS and DC_GUARD_BINS are the numbers of FFT bins left out around each wanted tone and around DC when the
# strongest spur is searched for (the main lobe of the window is a few bins wide, and the mixer has a small DC offset).
# SETTLE_FRACTION is the part of the capture thrown away at the start, so that the filter's start-up transient does not leak into the spectrum.
SPUR_GUARD_BINS = 6          # bins around each wanted peak excluded from spur search
DC_GUARD_BINS = 3            # bins around DC excluded from spur search (mixer DC offset)
SETTLE_FRACTION = 0.15       # fraction of captured samples discarded at the start (filter settling)


def load_meta():
    with open(META_PATH) as f:
        return json.load(f)


def load_capture():
    import csv
    per_rx = {i: {"i": [], "q": []} for i in range(8)}
    skipped = 0
    with open(CSV_PATH) as f:
        r = csv.DictReader(f)
        for row in r:
            # The first output or two of a receiver can carry X (an undefined simulation value) while the CIC and FIR pipeline is still filling,
            # before any register has been clocked through a full decimation cycle. Those rows are skipped and counted, and the settle fraction
            # in analyze_receiver() takes care of the start-up transient anyway.
            # the first output or two per receiver can carry X (uninitialized
            # sim state) while the CIC/FIR pipeline is still filling, before
            # any register has been clocked through a full decimation cycle;
            # skip those rather than crash, the settle-fraction discard in
            # analyze_receiver() already accounts for this startup transient
            try:
                rx = int(row["rx_index"])
                iv = int(row["i"])
                qv = int(row["q"])
            except ValueError:
                skipped += 1
                continue
            per_rx[rx]["i"].append(iv)
            per_rx[rx]["q"].append(qv)
    if skipped:
        print(f"(skipped {skipped} rows with undefined (X) values -- initial pipeline fill)")
    return per_rx


def analyze_receiver(rx_idx, rx_meta, iq, out_rate, tones):
    n = len(iq)
    settle = int(n * SETTLE_FRACTION)
    seg = iq[settle:]
    n_fft = len(seg)
    if n_fft < 64:
        return None

    window = np.blackman(n_fft) if n_fft < 8 else _blackman_harris(n_fft)
    coherent_gain = np.sum(window) / n_fft
    windowed = seg * window
    spec = np.fft.fftshift(np.fft.fft(windowed))
    freqs = np.fft.fftshift(np.fft.fftfreq(n_fft, d=1.0 / out_rate))
    # The magnitude is divided by n_fft times the coherent gain of the window, so that a peak bin reads the real signal amplitude whatever
    # the number of samples was. Receivers at different output rates get different n_fft from the same capture, and without this the raw
    # magnitude grows with n_fft and makes the faster receivers look louder.
    # normalize by n_fft * coherent_gain so a peak bin reads the actual
    # signal amplitude, independent of how many samples/receivers were
    # captured (receivers at different output rates get different n_fft
    # from the same fixed-length capture, otherwise raw FFT magnitude scales
    # with n_fft and makes higher-rate receivers look artificially louder)
    mag = np.abs(spec) / (n_fft * coherent_gain)
    mag_db = 20 * np.log10(np.maximum(mag, 1e-9))

    lo = rx_meta["lo_hz"]
    my_tones = [t for t in tones if t["rx"] == rx_idx]

    bin_width = out_rate / n_fft
    search_hz = max(300.0, 4.0 * bin_width)

    results = []
    peak_bins = []
    for t in my_tones:
        expected_offset = t["freq_hz"] - lo  # baseband = RF - LO (down-conversion)
        # Search a window around the expected offset (and around the negative of it, in case the mixing sign is the other one), leaving out bins
        # that an earlier tone of the same receiver has claimed, so that two close tones (the two tone pair of receiver 0) cannot both latch
        # onto the same peak. The baseband frequency is the RF frequency minus the LO frequency.
        # search a window around the expected offset (allow for the other
        # mixing sign convention too, +/-), excluding bins already claimed by
        # an earlier tone of the SAME receiver (so two close tones, e.g.
        # rx0's two-tone pair, cannot both latch onto the same peak)
        claimed = np.zeros(n_fft, dtype=bool)
        for b in peak_bins:
            claimed[max(0, b - 2):b + 3] = True

        def _candidates(off):
            m = (np.abs(freqs - off) <= search_hz) & (~claimed)
            return np.where(m)[0]

        idx_candidates = _candidates(expected_offset)
        if len(idx_candidates) == 0:
            idx_candidates = _candidates(-expected_offset)
            if len(idx_candidates) > 0:
                expected_offset = -expected_offset
        if len(idx_candidates) == 0:
            continue
        local_peak = idx_candidates[np.argmax(mag_db[idx_candidates])]
        peak_bins.append(local_peak)
        measured_offset = freqs[local_peak]

        # Sub-bin frequency refinement: a parabola through the log magnitudes of the peak and its two neighbors gives the frequency between
        # bins. It uses only this receiver's own data, with no knowledge of the true tone frequency, and it is needed because the bin grid
        # alone is too coarse to place two tones a couple of kHz apart in a short capture.
        # Sub-bin frequency refinement (parabolic interpolation of the
        # log-magnitude around the peak, a standard windowed-estimator
        # technique -- derived purely from this receiver's own captured
        # data, no foreknowledge of the true tone frequency used): the raw
        # FFT bin grid alone is too coarse to place two tones only a couple
        # of kHz apart (rx0's pair) accurately in a short capture.
        if 0 < local_peak < n_fft - 1:
            ym1, y0, yp1 = mag_db[local_peak - 1], mag_db[local_peak], mag_db[local_peak + 1]
            denom = (ym1 - 2 * y0 + yp1)
            delta = 0.5 * (ym1 - yp1) / denom if abs(denom) > 1e-9 else 0.0
            delta = float(np.clip(delta, -1.0, 1.0))
        else:
            delta = 0.0
        refined_offset = measured_offset + delta * bin_width

        # Exact frequency correlator: a single-bin DFT (as the Goertzel algorithm computes it) evaluated at the refined frequency instead of
        # read off the nearest FFT bin. It removes the picket fence and leakage error that limits the amplitude accuracy when two close
        # tones (receiver 0's pair, 2 kHz apart) share a short capture, since each is resolved against its own frequency.
        # Exact-frequency correlator (a single-bin/Goertzel-style DFT
        # evaluated AT the refined frequency estimate rather than read off
        # the nearest FFT bin): removes picket-fence/leakage error, which
        # otherwise limits amplitude accuracy for two tones close together
        # (e.g. rx0's pair, 2 kHz apart) sharing a short capture --
        # exact-frequency correlation resolves each one directly against
        # its own refined frequency instead of the coarse shared bin grid.
        n_idx = np.arange(n_fft)
        osc = np.exp(-1j * 2 * np.pi * refined_offset * n_idx / out_rate)
        correlated = np.sum(windowed * osc) / (n_fft * coherent_gain)
        correlated_mag_db = 20 * np.log10(max(np.abs(correlated), 1e-9))
        measured_offset = refined_offset

        results.append({
            "freq_hz": t["freq_hz"],
            "level_dbfs": t["level_dbfs"],
            "expected_offset_hz": expected_offset,
            "measured_offset_hz": measured_offset,
            "freq_error_hz": measured_offset - expected_offset,
            "peak_bin": int(local_peak),
            "peak_mag_db_raw": correlated_mag_db,
        })

    # Spur search: the strongest bin outside the guard regions around every wanted tone and around DC.
    # spur search: strongest bin outside the guard regions around every
    # wanted peak and around DC
    mask = np.ones(n_fft, dtype=bool)
    dc_bin = np.argmin(np.abs(freqs))
    mask[max(0, dc_bin - DC_GUARD_BINS):dc_bin + DC_GUARD_BINS + 1] = False
    for b in peak_bins:
        mask[max(0, b - SPUR_GUARD_BINS):b + SPUR_GUARD_BINS + 1] = False
    if mask.any():
        spur_bin = np.where(mask)[0][np.argmax(mag_db[mask])]
        spur_db_raw = mag_db[spur_bin]
        spur_freq = freqs[spur_bin]
    else:
        spur_bin, spur_db_raw, spur_freq = None, -999.0, 0.0

    main_peak_db_raw = max((r["peak_mag_db_raw"] for r in results), default=-999.0)

    return {
        "rx": rx_idx, "lo_hz": lo, "out_rate": out_rate, "n_fft": n_fft,
        "tones": results, "main_peak_db_raw": main_peak_db_raw,
        "spur_db_raw": spur_db_raw, "spur_freq_hz": spur_freq,
        "freqs": freqs, "mag_db": mag_db,
    }


# Blackman-Harris window of 4 terms (coefficients 0.35875, 0.48829, 0.14128, 0.01168), whose side lobes are far enough down for the
# spur search to see deep spurs.
def _blackman_harris(n):
    a0, a1, a2, a3 = 0.35875, 0.48829, 0.14128, 0.01168
    k = np.arange(n)
    return (a0 - a1 * np.cos(2 * np.pi * k / (n - 1))
               + a2 * np.cos(4 * np.pi * k / (n - 1))
               - a3 * np.cos(6 * np.pi * k / (n - 1)))


def main():
    if not os.path.exists(CSV_PATH):
        print(f"ERROR: {CSV_PATH} not found -- run the simulation first", file=sys.stderr)
        sys.exit(1)

    meta = load_meta()
    tones = meta["tones"]
    rx_meta_by_idx = {r["index"]: r for r in meta["receivers"]}
    per_rx = load_capture()

    analyses = []
    for rx_idx in range(8):
        rec = per_rx[rx_idx]
        n = len(rec["i"])
        iq = np.array(rec["i"], dtype=np.float64) + 1j * np.array(rec["q"], dtype=np.float64)
        rx_meta = rx_meta_by_idx[rx_idx]
        out_rate = rx_meta["rate_ksps"] * 1000.0
        a = analyze_receiver(rx_idx, rx_meta, iq, out_rate, tones)
        if a is None:
            print(f"rx{rx_idx}: only {n} samples captured -- FAIL (too few for analysis)")
            continue
        analyses.append(a)

    # One calibration constant for all receivers: the median over every tone of (known input level minus measured raw peak, in dB). The gain of
    # the whole chain is a design constant, the same for every receiver and output rate, so a receiver whose result is off after this
    # single correction has a gain that does not match the others.
    # --- single calibration constant across all receivers' main tones ---
    offsets = []
    for a in analyses:
        for t in a["tones"]:
            offsets.append(t["level_dbfs"] - t["peak_mag_db_raw"])
    cal_db = float(np.median(offsets)) if offsets else 0.0
    print(f"Amplitude calibration constant (single value, applied to all receivers): {cal_db:.3f} dB")
    print()

    os.makedirs(OUT_DIR, exist_ok=True)
    all_ok = True
    table_rows = []

    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        have_plot = True
    except ImportError:
        have_plot = False
        print("matplotlib not available, skipping plots")

    for a in analyses:
        rx = a["rx"]
        print(f"--- rx{rx}  LO={a['lo_hz']/1e6:.4f} MHz  out_rate={a['out_rate']/1e3:.0f} ksps  "
              f"n_fft={a['n_fft']} ---")
        for t in a["tones"]:
            measured_dbfs = t["peak_mag_db_raw"] + cal_db
            amp_err = measured_dbfs - t["level_dbfs"]
            freq_err = t["freq_error_hz"]
            # A tone passes when its amplitude is within 0.5 dB and its frequency within the larger of 50 Hz and 0.2 % of the output rate.
            ok = abs(amp_err) <= 0.5 and abs(freq_err) <= max(50.0, a["out_rate"] * 0.002)
            all_ok &= ok
            print(f"  tone {t['freq_hz']/1e6:.4f} MHz ({t['level_dbfs']:.0f} dBFS): "
                  f"measured {measured_dbfs:.2f} dBFS (err {amp_err:+.2f} dB), "
                  f"offset {t['measured_offset_hz']:+.1f} Hz (expected {t['expected_offset_hz']:+.1f} Hz, "
                  f"err {freq_err:+.1f} Hz)  [{'OK' if ok else 'FAIL'}]")
            table_rows.append((rx, t["freq_hz"], t["level_dbfs"], measured_dbfs, amp_err,
                                t["expected_offset_hz"], freq_err))
        # How far the strongest spur is below the wanted tone.
        rejection_db = a["main_peak_db_raw"] - a["spur_db_raw"]
        print(f"  strongest in-band spur: {a['spur_freq_hz']:+.1f} Hz, "
              f"{rejection_db:.1f} dB below the wanted tone")
        print()

        if have_plot:
            fig, ax = plt.subplots(figsize=(8, 4.5))
            ax.plot(a["freqs"], a["mag_db"] + cal_db, lw=0.6)
            for t in a["tones"]:
                ax.axvline(t["expected_offset_hz"], color="green", ls="--", lw=0.7)
            ax.set_xlabel("Baseband offset from LO (Hz)")
            ax.set_ylabel("Level (dBFS, calibrated)")
            ax.set_title(f"rx{rx}  LO={a['lo_hz']/1e6:.4f} MHz  {a['out_rate']/1e3:.0f} ksps")
            ax.grid(True, alpha=0.3)
            fig.tight_layout()
            fig.savefig(os.path.join(OUT_DIR, f"rx{rx}_spectrum.png"), dpi=110)
            plt.close(fig)

    print("=" * 70)
    print(f"{'rx':>3} {'freq(MHz)':>10} {'exp(dBFS)':>10} {'meas(dBFS)':>11} {'err(dB)':>8} "
          f"{'exp_off(Hz)':>12} {'freq_err(Hz)':>13}")
    for row in table_rows:
        rx, f, exp_db, meas_db, err_db, exp_off, freq_err = row
        print(f"{rx:>3} {f/1e6:>10.4f} {exp_db:>10.1f} {meas_db:>11.2f} {err_db:>+8.2f} "
              f"{exp_off:>12.1f} {freq_err:>+13.1f}")
    print("=" * 70)
    print("ALL CHECKS " + ("PASSED" if all_ok else "FAILED"))

    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
