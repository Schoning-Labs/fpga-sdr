#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
"""
Designs the decimate-by-4 FIR that ends each receiver's decimation chain (rtl/rx/fir_decim.v) and writes its coefficients.

Chain recap (see docs/RX_DSP.md for the full picture):

  ADC 76.8 Msps -> cordic_mixer -> cic_fixed (STAGES=3, DECIMATION=10, fixed)
                 -> cic_var (STAGES=5, DECIMATION in {5,10,20,40}, rate-selected)
                 -> fir_decim (this filter, decimate-by-4, coefficients fixed)
                 -> IQ out at 48/96/192/384 ksps

fir_decim always runs at exactly 4x the selected output rate and always
decimates by 4, so ONE coefficient set covers all four output rates: every
frequency in the chain scales with the output rate, so the normalized design
frequencies below (a fraction of fir_decim's own sample rate) are identical
in every rate case.

Frequencies below are "cyc/sample" at fir_decim's OWN input rate (Fin =
4 x out_rate): 0.5 = Fin's Nyquist. A decimate-by-4 stage's alias-free limit
is 1/8 = 0.125 cyc/sample (= the output's own Nyquist, out_rate/2, mapped
back to Fin). We deliberately use less than that (FP below) to get a real
(non-brick-wall) transition band, which costs some usable receiver
bandwidth: the receiver's flat/low-ripple passband ends up at
+/-(FP/0.125) of the full output Nyquist, i.e. +/-(FP/0.125)*out_rate/2.

cic_var (order 5) has sinc^5 passband droop, which the shape of this filter does
not compensate; instead FP is chosen small enough that the residual droop at
the passband edge stays well under the 0.5 dB amplitude-accuracy budget.
cic_fixed's droop is negligible in every case: its decimation (10) is modest
and its output rate (7.68 MHz) is always far above the passband edges used here.

Run (from anywhere, the output paths are found from the script's own location; needs numpy and scipy, and
matplotlib if the plot is wanted):
    python tools/gen_fir_coeffs.py
Writes:
    rtl/rx/fir_coeffs.hex    -- $readmemh coefficient file for fir_decim.v
    sim/out/fir_response.png -- passband/stopband plot (gitignored)
Prints: passband ripple, stopband attenuation, and the CIC droop budget.
"""
import os
import numpy as np
from scipy.signal import remez, freqz

TAPS = 65          # odd -> Type-I linear phase FIR
DECIM = 4
COEFF_WIDTH = 20   # signed coefficient width, matches fir_decim.v COEFF_WIDTH
                   # (wider than the GW5AST DSP's 18-bit port, so the multiplier
                   # maps to 2 cascaded 18x18 DSP blocks instead of 1, see docs/RX_DSP.md)
CIC_STAGES = 5     # cic_var order, for droop bookkeeping only (not compensated in-filter)

FP = 0.06          # passband edge, cyc/sample at fir_decim's own input rate
FS = 0.25 - FP      # stopband edge (alias-free limit for decimate-by-4)

HERE = os.path.dirname(os.path.abspath(__file__))
RTL_OUT = os.path.normpath(os.path.join(HERE, "..", "rtl", "rx", "fir_coeffs.hex"))
PLOT_OUT = os.path.normpath(os.path.join(HERE, "..", "sim", "out", "fir_response.png"))


def cic_var_droop_db(cyc):
    """sinc^5 droop of cic_var at frequency `cyc` (cyc/sample at fir_decim's
    input rate == cic_var's own output rate)."""
    return 20 * np.log10(np.maximum(np.abs(np.sinc(cyc)) ** CIC_STAGES, 1e-12))


def quantize(taps, width):
    """Rounds the taps to signed integers of `width` bits (full scale is 2^(width-1) - 1) and returns them with the scale used."""
    scale = (2 ** (width - 1)) - 1
    q = np.round(taps * scale).astype(np.int64)
    q = np.clip(q, -(2 ** (width - 1)), (2 ** (width - 1)) - 1)
    return q, scale


def main():
    """Designs the FIR (stopband weighted 4 times the passband), quantizes it, writes the .hex file, prints the figures and plots them."""
    taps = remez(TAPS, [0, FP, FS, 0.5], [1, 0], fs=1.0, weight=[1, 4])
    qtaps, scale = quantize(taps, COEFF_WIDTH)
    qtaps_f = qtaps / scale

    w, h = freqz(qtaps_f, worN=32768)
    cyc = w / (2 * np.pi)
    mag_db = 20 * np.log10(np.maximum(np.abs(h), 1e-12))

    pb_mask = cyc <= FP
    sb_mask = cyc >= FS
    ripple_db = mag_db[pb_mask].max() - mag_db[pb_mask].min()
    stopband_atten_db = -mag_db[sb_mask].max()

    droop_edge_db = cic_var_droop_db(FP)
    combined_edge_db = ripple_db - droop_edge_db  # droop is negative, so this adds

    out_bw_fraction = FP / 0.125  # fraction of the full output Nyquist that stays flat

    # One two's complement word per line, as many hex digits as COEFF_WIDTH needs, for $readmemh in fir_decim.v.
    os.makedirs(os.path.dirname(RTL_OUT), exist_ok=True)
    with open(RTL_OUT, "w") as f:
        for c in qtaps:
            uval = int(c) & ((1 << COEFF_WIDTH) - 1)
            f.write(f"{uval:0{(COEFF_WIDTH + 3) // 4}x}\n")

    print(f"TAPS={TAPS} COEFF_WIDTH={COEFF_WIDTH} DECIM={DECIM}")
    print(f"Passband edge = {FP} cyc/sample, stopband edge = {FS:.3f} cyc/sample (fir_decim's own rate)")
    print(f"Usable output passband = +/-{out_bw_fraction*100:.0f}% of full output Nyquist (+/-{FP/0.125:.3f} x out_rate/2)")
    print(f"FIR-only passband ripple: {ripple_db:.4f} dB")
    print(f"Stopband attenuation (image/alias rejection from this FIR): {stopband_atten_db:.2f} dB")
    print(f"cic_var sinc^5 droop at passband edge (uncompensated): {droop_edge_db:.3f} dB")
    print(f"Combined worst-case passband amplitude error (FIR + CIC droop): {abs(combined_edge_db):.3f} dB")
    print(f"Coefficients written to {RTL_OUT}")

    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt

        os.makedirs(os.path.dirname(PLOT_OUT), exist_ok=True)
        fig, ax = plt.subplots(figsize=(8, 5))
        ax.plot(cyc, mag_db, label="fir_decim response")
        ax.axvline(FP, color="green", ls="--", lw=0.8, label="passband edge")
        ax.axvline(FS, color="red", ls="--", lw=0.8, label="stopband edge")
        ax.axhline(-90, color="gray", ls=":", lw=0.8, label="90 dB target")
        ax.set_xlabel("Frequency (cyc/sample at fir_decim's own input rate, Nyquist=0.5)")
        ax.set_ylabel("Magnitude (dB)")
        ax.set_xlim(0, 0.5)
        ax.set_ylim(-160, 10)
        ax.set_title("Compensating FIR (decimate-by-4) design response")
        ax.legend()
        ax.grid(True, alpha=0.3)
        fig.tight_layout()
        fig.savefig(PLOT_OUT, dpi=120)
        print(f"Plot written to {PLOT_OUT}")
    except ImportError:
        print("matplotlib not available, skipping plot")


if __name__ == "__main__":
    main()
