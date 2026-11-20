#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
"""
Designs the CIC-droop compensation filter used by rtl/zoom/zoom_cic_comp.v
(docs/F3_ZOOM.md section 3): a short, non-decimating FIR that flattens the
combined passband droop of the CIC stages in front of it across the displayed 80% of
the FFT's bins, to within a 0.5 dB flatness target.  (A CIC filter always lets its own
passband sag toward the edge, and the zoom receiver shows that part of the spectrum, so the
sag is undone here.)

Why per-span coefficients (11 sets, one for each span index 0 to 10, selected by span_shift),
and not one static filter: cic_fixed's own droop only matters at the widest span (span_shift=0,
where cic_var_pow2 does not decimate at all, so cic_fixed is the only
filtering upstream); at every other span, the droop of cic_var_pow2 (and, for the
narrowest spans, of zoom_cic_narrow) dominates and is nearly self-similar,
since it converges as the decimation 2^span_shift grows.  The two droop shapes
are different enough (a decimate-by-10, order-9 CIC against a decimate-by-2^k,
order-11 CIC in the limit of large decimation) that no single fixed equalizer curve fits
both to within 0.5 dB: a curve fitted to the span_shift=6 shape alone leaves span_shift=0
about 1.2 dB off, which is more than twice the target.  So each span gets its own
matched compensation curve.  The structure of the compensation filter (15 taps,
one coefficient ROM block per span) is fixed and only the coefficient
values change with span_shift, which costs ROM addressed by span_shift and
no extra multipliers, so the DSP count is the same as for a single 15-tap
filter however many coefficient sets are stored.

Design method: for each span, evaluate the exact combined cic_fixed +
cic_var_pow2 (and zoom_cic_narrow) magnitude response (the same formula tools/analyze_zoom_alias.py
uses) across the displayed passband (0 to 0.4 cyc/sample of the final,
post-zoom_fir_half rate, which is 80% of that rate's Nyquist), then design a
15-tap linear-phase FIR (scipy.signal.firls, piecewise-linear desired
response built from many closely spaced points so the whole smooth droop
curve is represented, not just its band edges) whose gain is the inverse
of that curve.

Run (from anywhere, needs numpy and scipy):
    python tools/gen_zoom_cic_comp_coeffs.py
Writes:
    rtl/zoom/zoom_cic_comp_coeffs.hex -- 11 blocks of TAPS coefficients each
    (span_shift=0 first), $readmemh file for zoom_cic_comp.v
Prints: per-span residual flatness after compensation, ideal and with the quantized coefficients.
"""
import os
import numpy as np
from scipy.signal import firls, freqz

FS_ADC = 76.8e6
CIC1_D, CIC1_N = 10, 9   # rtl/zoom/zoom_ddc.v cic_fixed instance
CIC2_N = 11                # rtl/zoom/zoom_ddc.v cic_var_pow2 instance
CIC2_MAX_SHIFT = 6         # its largest decimation, 64
CIC3_N = 11                # rtl/zoom/zoom_cic_narrow.v: the narrow spans (span index 7 to 10), decimation 2 to 16
FP = 0.2                   # zoom_fir_half's own passband edge, cyc/sample at ITS input rate
USABLE_FRACTION = 0.8

TAPS = 15
COEFF_WIDTH = 18   # signed; scale = 2^(COEFF_WIDTH-2) so coefficients up to ~2.0 fit (max here: ~1.40)
N_SPANS = 11   # 0 to 6: cic_var_pow2 at 1 to 64; 7 to 10: cic_var_pow2 at 64 and zoom_cic_narrow at 2 to 16

HERE = os.path.dirname(os.path.abspath(__file__))
RTL_OUT = os.path.normpath(os.path.join(HERE, "..", "rtl", "zoom", "zoom_cic_comp_coeffs.hex"))


def cic_mag(f, D, N, Fs):
    """Linear |H(f)| of an order-N, decimate-by-D CIC, DC-normalized to 1.0."""
    f = np.asarray(f, dtype=float)
    x = np.pi * f / Fs
    num = np.sin(np.pi * f * D / Fs)
    den = D * np.sin(x)
    with np.errstate(divide="ignore", invalid="ignore"):
        h = np.where(np.abs(np.sin(x)) < 1e-12, 1.0, num / den)
    return np.abs(h) ** N


def combined_mag(shift, u_arr):
    """Combined cic_fixed*cic_var_pow2 magnitude vs. u = f / (FP * Fs_cic2_out),
    i.e. u=1 at zoom_fir_half's own passband edge (== the displayed edge)."""
    d2 = 2 ** min(shift, CIC2_MAX_SHIFT)
    d3 = 2 ** max(shift - CIC2_MAX_SHIFT, 0)
    Fs_cic1_out = FS_ADC / CIC1_D
    Fs_cic2_out = Fs_cic1_out / d2
    Fs_cic3_out = Fs_cic2_out / d3            # the rate in front of zoom_fir_half
    f = u_arr * FP * Fs_cic3_out
    m1 = cic_mag(f, CIC1_D, CIC1_N, FS_ADC)
    m2 = cic_mag(f, d2, CIC2_N, Fs_cic1_out) if d2 > 1 else np.ones_like(f)
    m3 = cic_mag(f, d3, CIC3_N, Fs_cic2_out) if d3 > 1 else np.ones_like(f)
    return m1 * m2 * m3


def quantize(taps, width):
    """Rounds the taps to signed integers of `width` bits with one bit of headroom (scale 2^(width-2)) and returns them with the scale."""
    scale = 2 ** (width - 2)  # headroom for a coefficient magnitude up to ~2.0
    q = np.round(taps * scale).astype(np.int64)
    q = np.clip(q, -(2 ** (width - 1)), (2 ** (width - 1)) - 1)
    return q, scale


def main():
    """For every span, designs the compensation FIR, reports the residual ripple and writes all coefficient sets to one file."""
    u = np.linspace(0, 1, 101)
    freq_final = u * (USABLE_FRACTION / 2.0)  # cyc/sample at the FINAL rate: u=1 -> 0.4

    all_coeffs = []
    print(f"{'span_shift':>10}  {'ideal residual (dB)':>20}  {'quantized residual (dB)':>24}")
    for shift in range(N_SPANS):
        target = combined_mag(shift, u)
        comp_db = -20 * np.log10(np.maximum(target, 1e-12))
        comp_lin = 10 ** (comp_db / 20)

        # The wanted response as 100 short straight segments (each with its own start and end gain), which firls fits in the least squares sense.
        bands = np.empty(2 * (len(u) - 1))
        desired = np.empty(2 * (len(u) - 1))
        bands[0::2] = freq_final[:-1]
        bands[1::2] = freq_final[1:]
        desired[0::2] = comp_lin[:-1]
        desired[1::2] = comp_lin[1:]

        h = firls(TAPS, bands * 2, desired)  # *2: firls normalizes freq to Nyquist=1
        qh, scale = quantize(h, COEFF_WIDTH)
        qh_f = qh / scale

        w, H = freqz(h, worN=8192)
        wq, Hq = freqz(qh_f, worN=8192)
        cyc = w / (2 * np.pi)
        cycq = wq / (2 * np.pi)
        magdb = 20 * np.log10(np.maximum(np.abs(H), 1e-12))
        magdbq = 20 * np.log10(np.maximum(np.abs(Hq), 1e-12))

        # Residual flatness: the CIC droop plus the FIR gain over the displayed band, taken relative to DC.
        Hfir = np.interp(freq_final, cyc, magdb)
        Hfirq = np.interp(freq_final, cycq, magdbq)
        total_db = 20 * np.log10(np.maximum(target, 1e-12)) + Hfir
        total_db -= total_db[0]
        total_dbq = 20 * np.log10(np.maximum(target, 1e-12)) + Hfirq
        total_dbq -= total_dbq[0]

        print(f"{shift:>10}  {np.max(np.abs(total_db)):>20.4f}  {np.max(np.abs(total_dbq)):>24.4f}")
        all_coeffs.append(qh)

    os.makedirs(os.path.dirname(RTL_OUT), exist_ok=True)
    with open(RTL_OUT, "w") as f:
        for shift in range(N_SPANS):
            for c in all_coeffs[shift]:
                uval = int(c) & ((1 << COEFF_WIDTH) - 1)
                f.write(f"{uval:0{(COEFF_WIDTH + 3) // 4}x}\n")

    print(f"\n{N_SPANS} sets of {TAPS} coefficients written to {RTL_OUT}")


if __name__ == "__main__":
    main()
