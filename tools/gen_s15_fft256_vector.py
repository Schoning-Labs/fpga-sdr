#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
"""Writes fw/tr-modes/tests/data/s15_fft256_vector.txt, the test vector for the firmware's 256-point FFT.

The file holds the input and the output of the bit-true FFT model (tools/fft_r22sdf.py, LOG_N = 8, IW = 16, complex input) for
four frames, so that the Rust port in fw/tr-modes/src/frontend/fft256.rs, which the FT8 spectrogram code uses, can be checked
bit for bit against the same arithmetic as the FFT in the FPGA.  The four frames are random full-scale complex data, real data
with the second half zero (the way the spectrogram feeds the FFT, 128 samples and then zero padding), a full-scale constant
(the worst case for word growth) and a weak tone in noise.

Usage, from anywhere: python tools/gen_s15_fft256_vector.py  (needs numpy).  The random generator is seeded, so the file
comes out the same every time.
"""

import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fft_r22sdf as f1  # noqa: E402

LOG_N, IW = 8, 16
N = 1 << LOG_N


def frames():
    """The four input frames as (real, imaginary) integer arrays of N = 256 samples."""
    rng = np.random.default_rng(15)
    out = []
    # random full-scale complex
    out.append((rng.integers(-32768, 32768, N), rng.integers(-32768, 32768, N)))
    # real input, second half zero (the F5 case: 128 samples then zero padding)
    x = np.zeros(N, dtype=np.int64)
    x[:128] = rng.integers(-32768, 32768, 128)
    out.append((x, np.zeros(N, dtype=np.int64)))
    # full-scale constant (worst growth)
    out.append((np.full(N, 32767, dtype=np.int64), np.zeros(N, dtype=np.int64)))
    # low-level tone plus noise, real
    n = np.arange(N)
    tone = np.round(300 * np.cos(2 * np.pi * 37.3 * n / N) + rng.normal(0, 40, N)).astype(np.int64)
    tone[128:] = 0
    out.append((tone, np.zeros(N, dtype=np.int64)))
    return out


def main():
    """Runs the model on each frame and writes input and output, the output put into natural bin order."""
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    path = os.path.join(root, "fw", "tr-modes", "tests", "data", "s15_fft256_vector.txt")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fr = frames()
    with open(path, "w", newline="\n", encoding="utf-8") as f:
        f.write("# SPDX-License-Identifier: Apache-2.0\n")
        f.write("# Copyright 2026 Franz Schöning, https://www.schoning.com\n")
        f.write("# F1 bit-true FFT model (tools/fft_r22sdf.py), LOG_N=8, IW=16, complex input.\n")
        f.write("# Written by tools/gen_s15_fft256_vector.py. Per frame, 256 lines, natural bin order:\n")
        f.write("# in_re in_im out_re out_im   (line k: input sample k, output bin k)\n")
        f.write("%d\n" % len(fr))
        for xr, xi in fr:
            re, im, w = f1.model(xr, xi, LOG_N, IW)
            assert w == IW + LOG_N
            idx = np.array([f1.bitrev(t, LOG_N) for t in range(N)])
            nr = np.zeros(N, dtype=np.int64)
            ni = np.zeros(N, dtype=np.int64)
            nr[idx] = re
            ni[idx] = im
            for k in range(N):
                f.write("%d %d %d %d\n" % (xr[k], xi[k], nr[k], ni[k]))
    print("wrote", path)


if __name__ == "__main__":
    main()
