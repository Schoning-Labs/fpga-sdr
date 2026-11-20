#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
"""
Designs the final decimate-by-2 anti-alias FIR used by rtl/zoom/zoom_fir_half.v
(docs/F3_ZOOM.md section 3 has the full rationale).

Chain recap: ADC 76.8 Msps -> cordic_mixer -> cic_fixed (STAGES, DECIMATION=10,
fixed) -> cic_var_pow2 (STAGES, decim=2^span_shift) -> zoom_cic_narrow (only for
the narrowest spans) -> zoom_fir_half (this filter, decimate-by-2) -> IQ at the
full (uncropped) internal rate. Only the central USABLE_FRACTION of that rate is
shown on the display: the outer bins are computed by the FFT like any other bin
but are not part of the alias-protected view, and leaving them out of the view is
what makes a filter with a gentle transition band good enough.

Frequencies below are "cyc/sample" at zoom_fir_half's OWN input rate (Fin =
2 x its output rate): 0.5 = Fin's Nyquist. Passband edge FP is chosen so
that, after decimating by 2, the flat part of the passband covers exactly
USABLE_FRACTION of the output's own Nyquist: FP = USABLE_FRACTION * 0.25
(0.25 = the output Nyquist expressed as a fraction of Fin). Stopband edge is
the standard decimate-by-2 alias-free limit, FS = 0.5 - FP: everything from
there to Fin's own Nyquist (0.5) must be rejected, since that whole range
folds into the passband on decimation by 2.

Run (from anywhere, needs numpy and scipy):
    python tools/gen_zoom_fir_coeffs.py
Writes:
    rtl/zoom/zoom_fir_half_coeffs.hex -- $readmemh coefficient file
Prints: passband ripple and stopband attenuation, both ideal and quantized
to the RTL's actual coefficient width.
"""
import os
import numpy as np
from scipy.signal import remez, freqz

TAPS = 63           # odd -> Type-I linear phase FIR
DECIM = 2
COEFF_WIDTH = 20    # signed coefficient width, matches zoom_fir_half.v COEFF_WIDTH
USABLE_FRACTION = 0.8   # central fraction of the output Nyquist kept flat -- docs/F3_ZOOM.md section 3

FP = USABLE_FRACTION * 0.25   # passband edge, cyc/sample at zoom_fir_half's own input rate
FS = 0.5 - FP                  # stopband edge (alias-free limit for decimate-by-2)

HERE = os.path.dirname(os.path.abspath(__file__))
RTL_OUT = os.path.normpath(os.path.join(HERE, "..", "rtl", "zoom", "zoom_fir_half_coeffs.hex"))


def quantize(taps, width):
    """Rounds the taps to signed integers of `width` bits (full scale is 2^(width-1) - 1) and returns them with the scale used."""
    scale = (2 ** (width - 1)) - 1
    q = np.round(taps * scale).astype(np.int64)
    q = np.clip(q, -(2 ** (width - 1)), (2 ** (width - 1)) - 1)
    return q, scale


def main():
    """Designs the FIR (stopband weighted 4 times the passband), quantizes it, writes the .hex file and prints ripple and attenuation, ideal and quantized."""
    taps = remez(TAPS, [0, FP, FS, 0.5], [1, 0], fs=1.0, weight=[1, 4])
    qtaps, scale = quantize(taps, COEFF_WIDTH)
    qtaps_f = qtaps / scale

    w, h = freqz(taps, worN=32768)
    cyc = w / (2 * np.pi)
    mag_db = 20 * np.log10(np.maximum(np.abs(h), 1e-15))
    pb_mask = cyc <= FP
    sb_mask = cyc >= FS
    ripple_db = mag_db[pb_mask].max() - mag_db[pb_mask].min()
    stopband_atten_db = -mag_db[sb_mask].max()

    wq, hq = freqz(qtaps_f, worN=32768)
    mag_db_q = 20 * np.log10(np.maximum(np.abs(hq), 1e-15))
    ripple_db_q = mag_db_q[pb_mask].max() - mag_db_q[pb_mask].min()
    stopband_atten_db_q = -mag_db_q[sb_mask].max()

    os.makedirs(os.path.dirname(RTL_OUT), exist_ok=True)
    with open(RTL_OUT, "w") as f:
        for c in qtaps:
            uval = int(c) & ((1 << COEFF_WIDTH) - 1)
            f.write(f"{uval:0{(COEFF_WIDTH + 3) // 4}x}\n")

    print(f"TAPS={TAPS} COEFF_WIDTH={COEFF_WIDTH} DECIM={DECIM} USABLE_FRACTION={USABLE_FRACTION}")
    print(f"Passband edge = {FP:.4f} cyc/sample, stopband edge = {FS:.4f} cyc/sample (own input rate)")
    print(f"Ideal:     passband ripple {ripple_db:.4f} dB, stopband attenuation {stopband_atten_db:.2f} dB")
    print(f"Quantized: passband ripple {ripple_db_q:.4f} dB, stopband attenuation {stopband_atten_db_q:.2f} dB")
    print(f"Coefficients written to {RTL_OUT}")


if __name__ == "__main__":
    main()
