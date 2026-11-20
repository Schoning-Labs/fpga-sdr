#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
"""Regenerates the ROM files used by the spectrum display (rtl/spectrum/, docs/F2_SPECTRUM.md, docs/ARCHITECTURE.md section 3.3)
and by the zoom backend inside rtl/spectrum/spectrum_pipeline.v (docs/F3_ZOOM.md).

The spectrum pipeline takes the FFT output, which has far more bins than the screen has columns (6,400 full-band bins and
3,277 zoom bins against 1,920 columns), and reduces the bins of each column to one value.  The FFT delivers its bins in
bit-reversed order, so the hardware needs to know for every bin whether it is the first of its column to arrive (it then starts
the column's sum, and otherwise adds to it), and for every column how many bins it holds (the divisor for the mean).
Files written:

  rtl/spectrum/tw/window_coeffs.hex   4-term Blackman-Harris window, every 8th sample of the
                                       symmetric half + one endpoint (1,025 entries),
                                       unsigned Q1.17, 18 bit; rtl/spectrum/spectrum_window.v
                                       interpolates the 7 points in between
  rtl/spectrum/tw/log2_frac.hex       log2(1+f) lookup for rtl/spectrum/log2_core.v (shared by
                                       both spectrum backends), 512 x 12 bit unsigned Q0.12
  rtl/spectrum/tw/col_first.hex       1 bit per full-band bin (0..6399): 1 if this bin is the
                                       first of its screen column to *arrive* at the FFT output
                                       (arrival order is bit-reversed, not bin order)
  rtl/spectrum/tw/col_bins.hex        3 bits per screen column (0..1919): how many bins (3 or 4)
                                       of the 6400 fall in that column
  rtl/zoom/zcol_first.hex             same idea as col_first.hex, for the zoom backend's 3,277
                                       usable bins (docs/F3_ZOOM.md)
  rtl/zoom/zcol_bins.hex              same idea as col_bins.hex, for the zoom backend's 1,920
                                       screen columns

Bin -> column mapping (full-band): column = floor(bin * NUM_COLS / NUM_BINS) = floor(bin * 3 /
10), exact because NUM_COLS/NUM_BINS = 1920/6400 = 0.3. The RTL computes this with the classic
unsigned divide-by-10 multiply/shift (n * 52429) >> 19, exact for n < 65536; this script uses the
same formula so the ROMs it writes match the RTL's own column assignment bit for bit (also
checked directly against plain integer division below). The zoom backend's own bin -> column
mapping (3,277 bins onto the same 1,920 columns, which is not a small exact fraction) uses a
multiply-shift constant found by brute-force search instead, see find_mul_shift() below.

Run from the repository root (the output paths are relative to it), needs only the standard library:
python tools/gen_spectrum_tables.py
It is not part of tools/check.sh, because regenerating the tables is a deliberate step that has to be reviewed,
and the testbenches read the committed ROM files and do not regenerate them.
"""

import math

LOG_N = 14
N = 1 << LOG_N                 # 16384, full-band FFT size (docs/F1_FFT.md)
NUM_BINS = 6400                 # 0-30 MHz of the 8192 unique real-FFT bins
NUM_COLS = 1920                 # screen columns

WIN_BITS = 18                   # unsigned Q1.17, matches SPEC.md rounding to 15-bit windowed sample
WIN_SCALE = 1 << 17

LOG2_FRAC_BITS = 9              # 512-entry mantissa table
LOG2_FRAC_W = 12                # unsigned Q0.12 stored value

OUT_DIR = "rtl/spectrum/tw/"   # relative to the repository root, where the script is run


def bitrev(x, bits):
    """The number x with its `bits` low bits written in reverse order (the FFT's output order)."""
    r = 0
    for b in range(bits):
        r |= ((x >> b) & 1) << (bits - 1 - b)
    return r


def col_of_bin(bin_):
    """The screen column of a full-band bin, computed the way the RTL does it."""
    # exact for bin < 65536 (Hacker's Delight unsigned divide-by-10, verified below against //10)
    n = bin_ * 3
    q = (n * 52429) >> 19
    assert q == n // 10, (bin_, q, n // 10)
    return q


def window_val(i):
    """Sample i of the 4-term Blackman-Harris window of N = 16384 points (the continuous formula)."""
    return (0.35875 - 0.48829 * math.cos(2 * math.pi * i / N)
            + 0.14128 * math.cos(4 * math.pi * i / N)
            - 0.01168 * math.cos(6 * math.pi * i / N))


WIN_DECIM = 8            # keep every 8th sample and interpolate linearly in rtl/spectrum/spectrum_window.v.
                          # That stores 1,025 entries instead of 8,192 (7 block RAMs fewer) at a worst-case
                          # interpolation error of 64/8 * 1.7e-7 = 1.4e-6, far below the 18-bit
                          # coefficient's own step (1/131072 = 7.6e-6), so the window's -92 dB side lobes
                          # are unaffected.


def gen_window():
    """Writes window_coeffs.hex and prints the error that the RTL's linear interpolation makes against the true window."""
    # Every WIN_DECIM-th sample of the first half (i = 0, 8, ..., 8184), PLUS one extra sample at
    # i = 8192 (the symmetric point where w[8192] = w[N-1-8192] = w[8191], continuous formula
    # evaluated directly) so rtl/spectrum/spectrum_window.v's interpolator never needs a boundary
    # special case: entry k covers i = 8*k for k = 0 .. 1024 (1,025 entries).
    half = N // 2
    n_entries = half // WIN_DECIM + 1
    lines = []
    peak = 0.0
    for k in range(n_entries):
        i = k * WIN_DECIM
        w = window_val(i)
        peak = max(peak, w)
        code = int(round(w * WIN_SCALE))
        if code < 0 or code >= (1 << WIN_BITS):
            raise SystemExit(f"window coeff out of range at i={i}: {code}")
        lines.append(code)
    # Check the interpolation error the RTL's linear interpolation (between consecutive stored
    # samples) makes against the true continuous window, at every one of the 8,192 fine-grained
    # sample points that a ROM storing every sample would hold directly.
    max_step_err = 0.0
    for i in range(half):
        k = i // WIN_DECIM
        frac = (i % WIN_DECIM) / WIN_DECIM
        interp = lines[k] + frac * (lines[k + 1] - lines[k])
        true_code = window_val(i) * WIN_SCALE
        max_step_err = max(max_step_err, abs(interp - true_code) / WIN_SCALE)
    print(f"window: {len(lines)} entries (every {WIN_DECIM}th sample + endpoint), "
          f"peak {peak:.6f} (code {lines[-1]}, full scale {WIN_SCALE}), "
          f"worst linear-interpolation error {max_step_err:.3e} (vs 18-bit LSB {1.0/WIN_SCALE:.3e})")
    path = OUT_DIR + "window_coeffs.hex"
    with open(path, "w", encoding="utf-8") as f:
        f.write(
            "// SPDX-License-Identifier: Apache-2.0\n"
            "// Copyright 2026 Franz Schöning, https://www.schoning.com\n"
            "//\n"
            "// 4-term Blackman-Harris window (rtl/spectrum/spectrum_window.v), N = 16384:\n"
            "// w[i] = 0.35875 - 0.48829 cos(2pi i/N) + 0.14128 cos(4pi i/N) - 0.01168 cos(6pi i/N).\n"
            "// RB6 (docs/ARCHITECTURE.md 3.14 change C6b): only every 8th sample of the symmetric\n"
            "// first half is stored (i = 0, 8, .., 8192; entry k = w[8k], k = 0 .. 1024), plus the\n"
            "// endpoint at the symmetric point (w[8192] = w[N-1-8192]); the RTL linearly\n"
            "// interpolates the 7 points in between. Unsigned Q1.17 (scale 131072), 18-bit hex,\n"
            "// one entry per line. Written by tools/gen_spectrum_tables.py; do not hand-edit.\n"
            "// See docs/F2_SPECTRUM.md.\n"
        )
        for c in lines:
            f.write(f"{c:05x}\n")
    print(f"wrote {path} ({len(lines)} lines)")


def gen_log2_frac():
    """Writes log2_frac.hex, the table that turns the mantissa of a number into the fraction of its base-2 logarithm."""
    # log2(1+f) at the midpoint of each bucket, f = (k + 0.5) / 2^LOG2_FRAC_BITS, k = 0 .. 2^bits-1
    n = 1 << LOG2_FRAC_BITS
    lines = []
    worst = 0.0
    for k in range(n):
        f = (k + 0.5) / n
        val = math.log2(1.0 + f)
        code = int(round(val * (1 << LOG2_FRAC_W)))
        code = min(code, (1 << LOG2_FRAC_W) - 1)
        lines.append(code)
        worst = max(worst, abs(val - code / (1 << LOG2_FRAC_W)))
    print(f"log2_frac: {n} entries, worst quantization {worst:.6f} log2 units "
          f"({worst * 20 * math.log10(2):.4f} dB)")
    path = OUT_DIR + "log2_frac.hex"
    with open(path, "w", encoding="utf-8") as f:
        f.write(
            "// SPDX-License-Identifier: Apache-2.0\n"
            "// Copyright 2026 Franz Schöning, https://www.schoning.com\n"
            "//\n"
            f"// log2(1+f) at the midpoint of {n} buckets over f in [0,1), unsigned Q0.{LOG2_FRAC_W}\n"
            "// (scale 4096), used by rtl/spectrum/log2_core.v (shared by both the full-band and\n"
            "// zoom spectrum backends) to turn a leading-one position plus mantissa into a\n"
            "// log2(value) estimate. Written by tools/gen_spectrum_tables.py; do not hand-edit.\n"
            "// do not hand-edit. See docs/F2_SPECTRUM.md.\n"
        )
        for c in lines:
            f.write(f"{c:03x}\n")
    print(f"wrote {path} ({len(lines)} lines)")


def gen_column_tables():
    """Writes col_first.hex and col_bins.hex for the full-band spectrum, after checking them by replaying a frame."""
    arrival = [bitrev(b, LOG_N) for b in range(NUM_BINS)]
    col = [col_of_bin(b) for b in range(NUM_BINS)]
    # first_bin[c]: the bin of column c with the earliest arrival time.  The arrival time of the bin stored so
    # far has to be looked up (arrival[first_bin[c]]) and compared, and comparing against its bin number would flag
    # the wrong bin in many columns, which would restart those columns' sums part-way through the frame and lose bins
    # (see docs/F2_SPECTRUM.md, "The noise-floor fault").
    first_bin = [None] * NUM_COLS
    count = [0] * NUM_COLS
    for b in range(NUM_BINS):
        c = col[b]
        count[c] += 1
        if first_bin[c] is None or arrival[b] < arrival[first_bin[c]]:
            first_bin[c] = b
    if any(c not in (3, 4) for c in count):
        raise SystemExit(f"unexpected bins-per-column counts: {sorted(set(count))}")
    is_first = [1 if first_bin[col[b]] == b else 0 for b in range(NUM_BINS)]

    # Independent check: replay one frame in arrival order (out_index 0, 2, 4, ... -> bin =
    # bitrev(out_index)) exactly the way the RTL reduces it (flag set: overwrite, else add) and
    # confirm every column ends up holding the sum of all of its bins.
    acc = [None] * NUM_COLS
    for idx in range(0, N, 2):
        b = bitrev(idx, LOG_N)
        if b >= NUM_BINS:
            continue
        c = col[b]
        term = 1 << b % 40           # distinct per-bin value so any dropped bin is visible
        acc[c] = term if is_first[b] else (None if acc[c] is None else acc[c] + term)
    for c in range(NUM_COLS):
        want = sum(1 << b % 40 for b in range(NUM_BINS) if col[b] == c)
        if acc[c] != want:
            raise SystemExit(f"col_first check failed at column {c}")

    print(f"columns: {NUM_COLS}, bins-per-column min {min(count)} max {max(count)}, "
          f"total bins mapped {sum(count)} (expect {NUM_BINS})")

    path = OUT_DIR + "col_first.hex"
    with open(path, "w", encoding="utf-8") as f:
        f.write(
            "// SPDX-License-Identifier: Apache-2.0\n"
            "// Copyright 2026 Franz Schöning, https://www.schoning.com\n"
            "//\n"
            "// 1 bit per full-band bin (0..6399): 1 if this bin is the first of its screen column\n"
            "// to arrive at the FFT output within a frame (FFT output order is bit-reversed, so\n"
            "// arrival order is not bin order). rtl/spectrum/spectrum_pipeline.v uses this to know\n"
            "// whether to start or accumulate the column's per-frame reduction. Written by\n"
            "// tools/gen_spectrum_tables.py; do not hand-edit. See docs/F2_SPECTRUM.md.\n"
        )
        for v in is_first:
            f.write(f"{v:01x}\n")
    print(f"wrote {path} ({len(is_first)} lines)")

    path = OUT_DIR + "col_bins.hex"
    with open(path, "w", encoding="utf-8") as f:
        f.write(
            "// SPDX-License-Identifier: Apache-2.0\n"
            "// Copyright 2026 Franz Schöning, https://www.schoning.com\n"
            "//\n"
            "// 3 bits per screen column (0..1919): number of full-band bins (3 or 4) that map to\n"
            "// this column (6400 bins / 1920 columns = 3.33). Used as the mean-mode divisor\n"
            "// (with K) in rtl/spectrum/spectrum_pipeline.v. Written by tools/gen_spectrum_tables.py;\n"
            "// do not hand-edit. See docs/F2_SPECTRUM.md.\n"
        )
        for v in count:
            f.write(f"{v:01x}\n")
    print(f"wrote {path} ({len(count)} lines)")


ZOOM_LOG_N          = 12                          # rtl/zoom/zoom_spectrum.v's FFT size
ZOOM_N              = 1 << ZOOM_LOG_N              # 4096
ZOOM_USABLE_HALF    = (ZOOM_N * 4) // 10           # 1638, matches zoom_spectrum.v's USABLE_HALF
ZOOM_NUM_BINS       = 2 * ZOOM_USABLE_HALF + 1     # 3277: the displayed, alias-protected bins
ZOOM_NUM_COLS       = 1920                          # same column count as the full-band line buffer
ZOOM_OUT_DIR        = "rtl/zoom/"

# Multiply-shift constant for column = floor(rel * ZOOM_NUM_COLS / ZOOM_NUM_BINS), found below
# since 1920/3277 is not a small exact fraction the way 1920/6400 = 3/10 is (col_of_bin above).
# rtl/spectrum/spectrum_pipeline.v's own zoom backend hardcodes the same (mult, shift) pair as ZOOM_COL_MULT/ZOOM_COL_SHIFT
# localparams, which have to be kept in sync with what this prints if ZOOM_NUM_COLS or ZOOM_NUM_BINS ever
# change.
def find_mul_shift(num, den, max_x, max_shift=32):
    """The smallest shift s (and the multiplier m for it) for which (x * m) >> s equals (x * num) // den for every x up to max_x."""
    for s in range(1, max_shift + 1):
        m = round((num << s) / den)
        if m <= 0:
            continue
        if all((x * m) >> s == (x * num) // den for x in range(max_x + 1)):
            return m, s
    raise SystemExit(f"no exact multiply-shift constant found for {num}/{den} up to {max_x}")


def zoom_rel(bin_):
    """The contiguous frequency index (0 .. 2*USABLE_HALF, DC in the middle) of a usable zoom FFT bin."""
    # Remaps the zoom FFT's wraparound bin numbering (0 = DC, positive frequencies 1..USABLE_HALF,
    # then a gap of alias-unprotected bins, then negative frequencies (N-USABLE_HALF)..(N-1)) onto
    # a contiguous frequency axis 0 .. 2*USABLE_HALF, DC at USABLE_HALF -- see
    # rtl/zoom/zoom_spectrum.v's own out_usable derivation for the same bin ranges.
    if bin_ <= ZOOM_USABLE_HALF:
        return bin_ + ZOOM_USABLE_HALF
    return bin_ - (ZOOM_N - ZOOM_USABLE_HALF)


def gen_zoom_column_tables():
    """Writes zcol_first.hex and zcol_bins.hex for the zoom spectrum, with the same replay check as the full-band tables."""
    zoom_mult, zoom_shift = find_mul_shift(ZOOM_NUM_COLS, ZOOM_NUM_BINS, ZOOM_NUM_BINS - 1)

    def col_of_rel(rel):
        q = (rel * zoom_mult) >> zoom_shift
        assert q == (rel * ZOOM_NUM_COLS) // ZOOM_NUM_BINS, (rel, q)
        return q

    usable_bins = list(range(0, ZOOM_USABLE_HALF + 1)) + list(range(ZOOM_N - ZOOM_USABLE_HALF, ZOOM_N))
    assert len(usable_bins) == ZOOM_NUM_BINS

    bin_of_rel = [None] * ZOOM_NUM_BINS
    for b in usable_bins:
        bin_of_rel[zoom_rel(b)] = b
    assert all(x is not None for x in bin_of_rel)

    arrival_of_rel = [bitrev(bin_of_rel[r], ZOOM_LOG_N) for r in range(ZOOM_NUM_BINS)]
    col_of_relidx  = [col_of_rel(r) for r in range(ZOOM_NUM_BINS)]

    count = [0] * ZOOM_NUM_COLS
    first_rel = [None] * ZOOM_NUM_COLS
    for r in range(ZOOM_NUM_BINS):
        c = col_of_relidx[r]
        count[c] += 1
        if first_rel[c] is None or arrival_of_rel[r] < arrival_of_rel[first_rel[c]]:
            first_rel[c] = r
    if min(count) < 1:
        raise SystemExit(f"a zoom column got no bins at all: counts {count}")
    is_first = [1 if first_rel[col_of_relidx[r]] == r else 0 for r in range(ZOOM_NUM_BINS)]

    # Independent check: replay one full FFT frame (all N output words this time -- the zoom FFT
    # is complex, so unlike the full-band real FFT there is no mirror half to skip) in arrival
    # order exactly the way the RTL reduces it, and confirm every column ends up holding the sum
    # of all of its (usable) bins.
    usable_set = set(usable_bins)
    acc = [None] * ZOOM_NUM_COLS
    for idx in range(ZOOM_N):
        b = bitrev(idx, ZOOM_LOG_N)
        if b not in usable_set:
            continue
        r = zoom_rel(b)
        c = col_of_relidx[r]
        term = 1 << (r % 40)
        acc[c] = term if is_first[r] else (None if acc[c] is None else acc[c] + term)
    for c in range(ZOOM_NUM_COLS):
        want = sum(1 << (r % 40) for r in range(ZOOM_NUM_BINS) if col_of_relidx[r] == c)
        if acc[c] != want:
            raise SystemExit(f"zoom col_first check failed at column {c}")

    print(f"zoom columns: {ZOOM_NUM_COLS}, bins-per-column min {min(count)} max {max(count)}, "
          f"total bins mapped {sum(count)} (expect {ZOOM_NUM_BINS}), "
          f"column mult/shift = {zoom_mult}/{zoom_shift}")

    path = ZOOM_OUT_DIR + "zcol_first.hex"
    with open(path, "w", encoding="utf-8") as f:
        f.write(
            "// SPDX-License-Identifier: Apache-2.0\n"
            "// Copyright 2026 Franz Schöning, https://www.schoning.com\n"
            "//\n"
            "// 1 bit per usable zoom bin (0..3276, indexed by the contiguous \"rel\" frequency\n"
            "// index rtl/spectrum/spectrum_pipeline.v's own zoom backend computes from out_bin -- see zoom_rel() in\n"
            "// tools/gen_spectrum_tables.py): 1 if this bin is the first of its screen column to\n"
            "// arrive at the zoom FFT's output within a frame (arrival order is bit-reversed, not\n"
            "// bin order, same convention as rtl/spectrum/tw/col_first.hex).\n"
            "// Written by tools/gen_spectrum_tables.py; do not hand-edit.\n"
        )
        for v in is_first:
            f.write(f"{v:01x}\n")
    print(f"wrote {path} ({len(is_first)} lines)")

    path = ZOOM_OUT_DIR + "zcol_bins.hex"
    with open(path, "w", encoding="utf-8") as f:
        f.write(
            "// SPDX-License-Identifier: Apache-2.0\n"
            "// Copyright 2026 Franz Schöning, https://www.schoning.com\n"
            "//\n"
            "// 3 bits per zoom screen column (0..1919): number of usable zoom bins (3,277 total)\n"
            "// that map to this column. Used as the mean-mode divisor (with K) in\n"
            "// rtl/spectrum/spectrum_pipeline.v's own zoom backend, the same role rtl/spectrum/tw/col_bins.hex plays for\n"
            "// the full-band pipeline. Written by\n"
            "// tools/gen_spectrum_tables.py; do not hand-edit.\n"
        )
        for v in count:
            f.write(f"{v:01x}\n")
    print(f"wrote {path} ({len(count)} lines)")


def main():
    """Writes all six ROM files."""
    gen_window()
    gen_log2_frac()
    gen_column_tables()
    gen_zoom_column_tables()


if __name__ == "__main__":
    main()
