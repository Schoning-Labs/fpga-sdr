#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
"""
Generates the 4,096-point window coefficient ROM for rtl/zoom/zoom_window.v.

A window is multiplied onto the samples before the FFT, to keep a strong signal from
spreading its energy over many bins.  This is the same window family as the full-band FFT
window of docs/ARCHITECTURE.md section 3.3: 4-term Blackman-Harris (about -92 dB side lobes).
It is symmetric (w[n] = w[N-1-n]), so only the first half (N/2 entries) is written and the RTL
folds the address for the second half.  The values are unsigned Q0.16.

Run (from anywhere, needs numpy):
    python tools/gen_zoom_window.py
Writes:
    rtl/zoom/zoom_window_coeffs.hex -- $readmemh file for zoom_window.v
Prints: coherent gain and equivalent noise bandwidth (both are needed to
convert an FFT bin to a calibrated dBFS or dBm reading) and the highest side lobe.
"""
import os
import numpy as np

N = 4096
COEFF_WIDTH = 16  # unsigned Q0.16

HERE = os.path.dirname(os.path.abspath(__file__))
RTL_OUT = os.path.normpath(os.path.join(HERE, "..", "rtl", "zoom", "zoom_window_coeffs.hex"))

# 4-term Blackman-Harris coefficients (same values used throughout the
# project's spectral windows).
A0, A1, A2, A3 = 0.35875, 0.48829, 0.14128, 0.01168


def blackman_harris(n_points):
    """The 4-term Blackman-Harris window of n_points samples (the divisor n_points - 1 makes it exactly symmetric)."""
    n = np.arange(n_points)
    return (A0
            - A1 * np.cos(2 * np.pi * n / (n_points - 1))
            + A2 * np.cos(4 * np.pi * n / (n_points - 1))
            - A3 * np.cos(6 * np.pi * n / (n_points - 1)))


def main():
    """Quantizes the window, checks it is still symmetric, writes the first half and prints the window's figures of merit."""
    w = blackman_harris(N)
    scale = (2 ** COEFF_WIDTH) - 1
    q = np.clip(np.round(w * scale), 0, scale).astype(np.uint32)

    half = q[: N // 2]
    # sanity: confirm the RTL's address-folding assumption (w[n] == w[N-1-n])
    # holds for the quantized table too, not just the continuous formula.
    assert np.array_equal(half, q[N - 1: N // 2 - 1: -1]), "window is not symmetric after quantization"

    os.makedirs(os.path.dirname(RTL_OUT), exist_ok=True)
    with open(RTL_OUT, "w") as f:
        for c in half:
            f.write(f"{int(c):04x}\n")

    coherent_gain = w.mean()
    enbw_bins = N * np.sum(w ** 2) / (np.sum(w) ** 2)

    # highest side lobe: zero-pad and FFT the (unquantized) window, look at
    # everything outside the main lobe's first few bins.
    padded = np.zeros(N * 16)
    padded[:N] = w
    spec_db = 20 * np.log10(np.abs(np.fft.rfft(padded)) / np.sum(w) + 1e-300)
    sidelobe_db = spec_db[16 * 8:].max()  # skip the main lobe (+/- a few original-resolution bins)

    print(f"N={N} COEFF_WIDTH={COEFF_WIDTH} (unsigned Q0.{COEFF_WIDTH})")
    print(f"Coherent gain: {coherent_gain:.6f}")
    print(f"Equivalent noise bandwidth: {enbw_bins:.4f} bins")
    print(f"Highest side lobe: {sidelobe_db:.1f} dB below the main lobe")
    print(f"{N//2} coefficients written to {RTL_OUT}")


if __name__ == "__main__":
    main()
