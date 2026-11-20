#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
"""Bit-true Python model of the radix-2^2 single-path delay-feedback FFT, and the tool that makes its twiddle ROM files.

This is the companion to rtl/fft/fft_r22sdf.v (docs/F1_FFT.md).  An FFT of this kind (R2²SDF) takes one complex sample per clock
and passes it through a chain of stages, each of which has a delay line that feeds back on itself and two butterflies (an
add and a subtract of two samples) with a multiplication by a twiddle factor, a complex number on the unit circle, between
every second pair of butterflies.  The result comes out one bin per clock in bit-reversed order (the bin number read with its
bits the wrong way round).  Three commands are available:

  python tools/fft_r22sdf.py gen-tw          write the twiddle ROM files rtl/fft/tw/fft_tw18_lNN.hex (one per size 2^NN, NN = 3 to 16)
  python tools/fft_r22sdf.py sweep [--quick] accuracy sweep of the bit-true model (tones, noise)
  python tools/fft_r22sdf.py compare FILE    bit-exact check of an RTL dump (vvp ... +dump writes
                                             fft_dump.txt: "frame input out_re out_im" per bin)

The model here is bit-exact with the RTL: the same butterflies, the same twiddle table (octant
symmetry included), the same rounding and saturation. It computes the transform block-wise
(in-place decimation in frequency) instead of sample by sample; the streaming single-path
delay-feedback pipeline in the RTL produces the same numbers in the same (bit-reversed) order.

The twiddles are stored as 18-bit signed numbers with 17 fraction bits (Q17), because 18 bits is the native width of the
multiplier input of the DSP block on the Gowin chip, and only the first octant (angles 0 to 45 degrees) is kept in the ROM:
the other seven are made from it by swapping and negating cosine and sine, which saves seven eighths of the ROM.

Needs numpy.  The default output folder of gen-tw is rtl/fft/tw next to this tools folder, so it can be run from anywhere.
"""

import argparse
import math
import os
import sys

import numpy as np

TW = 18                      # twiddle width, signed; DSP 27x18 native
TW_SCALE = (1 << (TW - 1)) - 1   # 131071: +1.0 is not representable in 18-bit signed Q17


def octant_table(log_np):
    """cos/sin table for angles 2*pi*r/Np, r = 0 .. Np/8-1 (first octant, 45 deg excluded)."""
    np_ = 1 << log_np
    n = max(np_ // 8, 1)
    c = [int(round(math.cos(2 * math.pi * r / np_) * TW_SCALE)) for r in range(n)]
    s = [int(round(math.sin(2 * math.pi * r / np_) * TW_SCALE)) for r in range(n)]
    return c, s


K45 = int(round(math.sqrt(0.5) * TW_SCALE))   # 92681, used when the reflected index is Np/8


def twiddle(e, log_np, table):
    """W_Np^e = cos - j sin, from the octant table exactly as rtl/fft/fft_twmul.v maps it."""
    c_t, s_t = table
    np_ = 1 << log_np
    e %= np_
    o = e >> (log_np - 3)
    r = e & ((np_ >> 3) - 1)
    rr = (np_ >> 3) - r if (o & 1) else r
    if rr == (np_ >> 3):
        C = S = K45
    else:
        C, S = c_t[rr], s_t[rr]
    cs = {0: (C, S), 1: (S, C), 2: (-S, C), 3: (-C, S),
          4: (-C, -S), 5: (-S, -C), 6: (S, -C), 7: (C, -S)}[o]
    return cs[0], -cs[1]          # (wr, wi)


def gen_tw(outdir):
    """Writes one twiddle ROM file per FFT size, sizes 2^3 to 2^16.

    Each line is one 36-bit word in 9 hex digits, the cosine in the upper 18 bits and the sine in the lower 18 bits
    (both two's complement), for the angles of the first octant only; the file of size Np has Np/8 lines.
    """
    os.makedirs(outdir, exist_ok=True)
    for log_np in range(3, 17):
        c, s = octant_table(log_np)
        path = os.path.join(outdir, "fft_tw18_l%02d.hex" % log_np)
        with open(path, "w", newline="\n") as f:
            for ci, si in zip(c, s):
                word = ((ci & ((1 << TW) - 1)) << TW) | (si & ((1 << TW) - 1))
                f.write("%09x\n" % word)
        print("wrote", path, len(c), "entries")


def _sat(v, w):
    """Clips v to the range of a w-bit two's complement number."""
    lo, hi = -(1 << (w - 1)), (1 << (w - 1)) - 1
    return np.clip(v, lo, hi)


def _check_width(a, w, what):
    """Raises OverflowError when a value in the array a needs more than w bits, which would mean the word growth assumed in the model is too small."""
    lo, hi = -(1 << (w - 1)), (1 << (w - 1)) - 1
    if a.min() < lo or a.max() > hi:
        raise OverflowError("%s exceeds %d bits" % (what, w))


def model(xr, xi, log_n, iw):
    """Bit-true block model of the whole transform of n = 2^log_n points with iw-bit signed input.

    Returns (re, im, w): the real and imaginary parts in output order (position t holds bin bitrev(t)) and the output width.
    The width grows by one bit at every butterfly, since an add of two numbers needs one bit more, and the twiddle
    multiplication rounds back to the current width, so nothing is lost except by that rounding (and by saturation,
    which should never trigger and is checked by _check_width).
    """
    n = 1 << log_n
    re = np.array(xr, dtype=np.int64).copy()
    im = np.array(xi, dtype=np.int64).copy()
    _check_width(re, iw, "input re")
    _check_width(im, iw, "input im")
    w = iw
    log_np = log_n
    # Each pass of this loop is one radix-2^2 stage: a block of Np points is split first by a plain butterfly (BF2I) and then
    # by a butterfly that also turns the fourth quarter by -j (BF2II), followed by the twiddle multiplication, and the next
    # stage works on blocks a quarter of the size.  An odd log_n ends with one lone BF2I, which is why the loop can break.
    while log_np >= 1:
        np_ = 1 << log_np
        blocks = n // np_
        # BF2I: L = Np/2
        r2 = re.reshape(blocks, 2, np_ // 2)
        i2 = im.reshape(blocks, 2, np_ // 2)
        a_r, b_r = r2[:, 0, :].copy(), r2[:, 1, :].copy()
        a_i, b_i = i2[:, 0, :].copy(), i2[:, 1, :].copy()
        r2[:, 0, :], r2[:, 1, :] = a_r + b_r, a_r - b_r
        i2[:, 0, :], i2[:, 1, :] = a_i + b_i, a_i - b_i
        w += 1
        _check_width(re, w, "stage re")
        _check_width(im, w, "stage im")
        if log_np == 1:
            break
        # BF2II: L = Np/4, input times -j in the 4th quarter
        r4 = re.reshape(blocks, 4, np_ // 4)
        i4 = im.reshape(blocks, 4, np_ // 4)
        br, bi = r4[:, 3, :].copy(), i4[:, 3, :].copy()
        r4[:, 3, :], i4[:, 3, :] = bi, -br
        for h in (0, 2):
            a_r, b_r = r4[:, h, :].copy(), r4[:, h + 1, :].copy()
            a_i, b_i = i4[:, h, :].copy(), i4[:, h + 1, :].copy()
            r4[:, h, :], r4[:, h + 1, :] = a_r + b_r, a_r - b_r
            i4[:, h, :], i4[:, h + 1, :] = a_i + b_i, a_i - b_i
        w += 1
        _check_width(re, w, "stage re")
        _check_width(im, w, "stage im")
        # twiddle W_Np^(n3 * (k1 + 2 k2)) where position q = k1*Np/2 + k2*Np/4 + n3
        if log_np >= 3:
            table = octant_table(log_np)
            q = np.arange(np_)
            k1 = (q >> (log_np - 1)) & 1
            k2 = (q >> (log_np - 2)) & 1
            n3 = q & (np_ // 4 - 1)
            e = n3 * (k1 + 2 * k2)
            wt = np.array([twiddle(int(x), log_np, table) for x in e], dtype=np.int64)
            wr = np.tile(wt[:, 0], blocks)
            wi = np.tile(wt[:, 1], blocks)
            pr = re * wr - im * wi
            pi = re * wi + im * wr
            # Multiplying by a Q17 number leaves 17 extra fraction bits: add half of the last kept bit and shift (round to nearest).
            half = 1 << (TW - 2)
            re = _sat((pr + half) >> (TW - 1), w)
            im = _sat((pi + half) >> (TW - 1), w)
        log_np -= 2
    return re, im, w


def bitrev(t, bits):
    """The number t with its `bits` low bits written in reverse order."""
    return int(format(t, "0%db" % bits)[::-1], 2)


def natural(re, im, log_n):
    """The model's output put into natural bin order as a complex array."""
    idx = np.array([bitrev(t, log_n) for t in range(1 << log_n)])
    out = np.zeros(1 << log_n, dtype=complex)
    out[idx] = re + 1j * im
    return out


def bh4(n):
    """The 4-term Blackman-Harris window of length n (about 92 dB of side lobe suppression), which the sweep applies to its test signals."""
    a = (0.35875, 0.48829, 0.14128, 0.01168)
    k = np.arange(n)
    return (a[0] - a[1] * np.cos(2 * np.pi * k / n) + a[2] * np.cos(4 * np.pi * k / n)
            - a[3] * np.cos(6 * np.pi * k / n))


def db(x):
    """10 log10 of a power ratio, kept finite for zero."""
    return 10 * np.log10(np.maximum(x, 1e-300))


def sweep(quick):
    """Runs the bit-true model on 16k point tones and on noise and prints how accurate it is.

    For each tone it prints the spurious free dynamic range of the model (SFDR, the peak against the largest bin outside
    5 bins around it), the same for a floating point FFT of the same input, the largest difference between the two, and the gain.
    The noise runs show how far below the input noise floor the arithmetic noise of the fixed-point FFT lies.
    `quick` uses six fixed tone positions instead of 27 (24 random ones and three exact bins).
    """
    log_n, iw, frac = 14, 15, 3            # 12-bit ADC, window output with 3 fraction bits
    n = 1 << log_n
    win = bh4(n)
    rng = np.random.default_rng(1)
    bins = [3.3, 1234.37, 1515.3, 4000.5, 6399.71, 8190.2] if quick else \
        list(rng.uniform(2, 8190, 24)) + [1515.3, 4096.0, 1024.0]
    print("Tones: 12-bit ADC, -1 dBFS, BH4 window, 15-bit FFT input, 16k points")
    print("SFDR = peak over the largest bin outside +/-5 bins; 'float' = numpy FFT of the same input;")
    print("FFT error = largest |RTL - float|^2 outside +/-5 bins, relative to the peak")
    print("%10s %6s %10s %12s %12s %10s" % ("bin", "peak", "SFDR dBc", "float dBc", "FFT err dBc",
                                          "gain dB"))
    worst_sfdr, worst_fsp = 1e9, -1e9
    amp = 2047 * 10 ** (-1 / 20)
    for b in bins:
        ph = rng.uniform(0, 2 * np.pi)
        adc = np.round(amp * np.cos(2 * np.pi * b * np.arange(n) / n + ph)).astype(np.int64)
        x = np.round(adc * win * (1 << frac)).astype(np.int64)
        re, im, _ = model(x, np.zeros(n, dtype=np.int64), log_n, iw)
        X = natural(re, im, log_n)[: n // 2]
        R = np.fft.fft(x.astype(float))[: n // 2]
        p, pr = np.abs(X) ** 2, np.abs(R) ** 2
        k0 = int(np.argmax(p))
        mask = np.ones(n // 2, bool)
        mask[max(0, k0 - 5): k0 + 6] = False
        sfdr = db(p[k0]) - db(p[mask].max())
        sfdr_f = db(pr[k0]) - db(pr[mask].max())
        fsp = db((np.abs(X - R) ** 2)[mask].max()) - db(p[k0])
        gain = db(p[k0]) - db(pr[k0])
        worst_sfdr, worst_fsp = min(worst_sfdr, sfdr), max(worst_fsp, fsp)
        print("%10.2f %6d %10.1f %12.1f %12.1f %10.5f" % (b, k0, sfdr, sfdr_f, fsp, gain))
    print("worst SFDR %.1f dBc, worst FFT error outside the main lobe %.1f dBc" %
          (worst_sfdr, worst_fsp))

    print("\nNoise: Gaussian, sigma = 4 LSB (about the AD9866 floor) and 0.5 LSB")
    for sigma in (4.0, 0.5):
        adc = np.clip(np.round(rng.normal(0, sigma, n)), -2048, 2047).astype(np.int64)
        x = np.round(adc * win * (1 << frac)).astype(np.int64)
        re, im, _ = model(x, np.zeros(n, dtype=np.int64), log_n, iw)
        X = natural(re, im, log_n)
        R = np.fft.fft(x.astype(float))
        sig = (np.abs(R) ** 2).mean()
        fe = (np.abs(X - R) ** 2).mean()
        print("  sigma %.1f LSB: FFT arithmetic noise %.1f dB below the input noise floor" %
              (sigma, db(sig) - db(fe)))


def compare(path, log_n=14, iw=15):
    """Checks a simulation dump of the RTL against the model, frame by frame, and returns 0 only when every bin is identical.

    The dump has one row per bin: frame number, real input, real part of the output, imaginary part of the output.
    The RTL's output arrives in bit-reversed order and is put into the model's order here before comparing.
    """
    n = 1 << log_n
    rows = np.loadtxt(path, dtype=np.int64)
    bad = 0
    for fr in np.unique(rows[:, 0]):
        r = rows[rows[:, 0] == fr]
        re, im, _ = model(r[:, 1], np.zeros(n, dtype=np.int64), log_n, iw)
        idx = np.array([bitrev(t, log_n) for t in range(n)])
        mr = np.zeros(n, dtype=np.int64)
        mi = np.zeros(n, dtype=np.int64)
        mr[idx], mi[idx] = re, im
        diff = int(np.count_nonzero((mr != r[:, 2]) | (mi != r[:, 3])))
        print("frame %d: %d of %d bins differ from the model" % (fr, diff, n))
        bad += diff
    print("bit-exact" if bad == 0 else "MISMATCH")
    return 0 if bad == 0 else 1


def main():
    """Command line entry: gen-tw, sweep or compare (see the module docstring)."""
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("gen-tw")
    g.add_argument("--outdir", default=os.path.join(os.path.dirname(__file__), "..", "rtl", "fft", "tw"))
    s = sub.add_parser("sweep")
    s.add_argument("--quick", action="store_true")
    c = sub.add_parser("compare")
    c.add_argument("file")
    a = ap.parse_args()
    if a.cmd == "gen-tw":
        gen_tw(os.path.normpath(a.outdir))
    elif a.cmd == "compare":
        return compare(a.file)
    else:
        sweep(a.quick)
    return 0


if __name__ == "__main__":
    sys.exit(main())
