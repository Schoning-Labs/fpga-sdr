#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
"""Regenerates rtl/audio/audio_interp_coeffs.hex, the coefficient file of the audio interpolator.

The 144-tap FIR in that file is used by rtl/audio/audio_interp_x8.v to interpolate 48 kHz stereo audio by 8, to 384 kHz,
for the PT8211 DAC (docs/ARCHITECTURE.md section 3.7).  Interpolating means putting seven zeros after every sample, which
creates images of the audio spectrum around multiples of 48 kHz, and the filter has to remove those images while leaving the
audio alone.

Design: direct-form lowpass, Parks-McClellan (scipy.signal.remez), passband 0-18 kHz, stopband
from 28 kHz (= 48 kHz - 20 kHz, the nearest image of 20 kHz audio content), evaluated at the
interpolated rate of 384 kHz. 144 taps so the 8-way polyphase decomposition used in the RTL
(phase p, tap k = h[8k+p]) comes out to exactly 18 taps per phase with no padding.  The taps are rounded
to 18-bit signed integers with 17 fraction bits.

The script also prints the response of the quantized filter (worst stopband level, passband ripple, group delay), so that
docs/A1_AUDIO.md, which has the measured figures, can be checked against it.

Requires numpy and scipy (`pip install numpy scipy`).  It is not part of tools/check.sh, because regenerating the
coefficients is a deliberate step that has to be reviewed and not something every check run should redo.

Run from the repository root (the output path is relative to it): python tools/gen_audio_interp_coeffs.py
"""

import numpy as np
from scipy.signal import remez, freqz

FS = 384_000.0          # interpolated (output) rate the filter is designed at
FPASS = 18_000.0        # passband edge (audio content assumed <= 18 kHz)
FSTOP = 28_000.0        # stopband edge = 48 kHz - 20 kHz guard, nearest zero-stuffing image
NUMTAPS = 144            # 144 = 8 phases x 18 taps/phase, exactly
COEFF_BITS = 18          # signed coefficient width (Q17: scale = 2^17)
SCALE = 2 ** 17

OUT_PATH = "rtl/audio/audio_interp_coeffs.hex"


def main():
    """Designs the filter, checks the quantized taps fit in 18 bits, prints the response and writes the .hex file."""
    h = remez(NUMTAPS, [0, FPASS, FSTOP, FS / 2], [1, 0], fs=FS, maxiter=200)

    hq = np.round(h * SCALE).astype(np.int64)
    if hq.max() >= 2 ** (COEFF_BITS - 1) or hq.min() < -(2 ** (COEFF_BITS - 1)):
        raise SystemExit(f"coefficient overflow for {COEFF_BITS}-bit signed storage")

    # Report the quantized filter's measured response so docs/A1_AUDIO.md can be checked against
    # this script's output.
    hq_f = hq.astype(np.float64) / SCALE
    w, H = freqz(hq_f, worN=65536, fs=FS)
    stop_db = 20 * np.log10(np.max(np.abs(H[w >= FSTOP])))
    pass_mag = np.abs(H[w <= FPASS])
    ripple_db = 20 * np.log10(pass_mag.max()) - 20 * np.log10(pass_mag.min())
    group_delay_out_samples = (NUMTAPS - 1) / 2
    print(f"taps={NUMTAPS} phase_len={NUMTAPS // 8}")
    print(f"quantized stopband worst (>= {FSTOP/1e3:.0f} kHz) = {stop_db:.2f} dB")
    print(f"quantized passband ripple (0-{FPASS/1e3:.0f} kHz) = {ripple_db:.4f} dB")
    print(f"sum(coeff)/2^17 = {np.sum(hq) / SCALE:.6f} (nominal per-branch DC gain before x8 compensation)")
    print(f"group delay = {group_delay_out_samples} output samples @ 384 kHz "
          f"= {group_delay_out_samples / 384000 * 1e6:.2f} us "
          f"= {group_delay_out_samples / 8:.4f} input samples @ 48 kHz")

    # One two's complement word per line, 5 hex digits, in tap order; the header lines are comments for $readmemh.
    mask = (1 << COEFF_BITS) - 1
    with open(OUT_PATH, "w", encoding="utf-8", newline="\n") as f:
        f.write(
            "// SPDX-License-Identifier: Apache-2.0\n"
            "// Copyright 2026 Franz Schöning, https://www.schoning.com\n"
            "//\n"
            "// Coefficients for the audio x8 interpolator (rtl/audio/audio_interp_x8.v), read with\n"
            "// $readmemh. One 18-bit two's complement hex value per line (5 hex digits), 144 values in\n"
            "// direct-form tap order h[0]..h[143]; the RTL re-derives the 8 polyphase phases from this same\n"
            "// order (phase p, tap k = h[8k+p], i.e. line number 8k+p+1). See docs/A1_AUDIO.md for the\n"
            "// filter design (144-tap FIR, Parks-McClellan/remez, passband 0-18 kHz, stopband from 28 kHz,\n"
            "// Q17 fixed point) and tools/gen_audio_interp_coeffs.py, which generated this file and must be\n"
            "// re-run if the filter design changes (do not hand-edit).\n"
        )
        for c in hq:
            f.write(f"{int(c) & mask:05x}\n")
    print(f"wrote {OUT_PATH} ({len(hq)} lines)")


if __name__ == "__main__":
    main()
