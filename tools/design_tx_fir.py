# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
"""Designs the first filter stage of the transmit chain and writes its coefficients for the Verilog.

The transmit chain (docs/ARCHITECTURE.md section 3.6) turns the 48 kHz complex baseband that the firmware produces into the
76.8 MHz sample stream the Hermes-Lite 2 plays out, in two steps: this FIR interpolates by 4 (48 kHz to 192 kHz), and a
5-stage CIC filter interpolates by another 400 (192 kHz to 76.8 MHz).  The FIR is a polyphase filter, which means the 40
taps are split into 4 phases of 10 taps and each output sample uses only one phase, so only a quarter of the multiplications
are done that a plain filter at 192 kHz would need.

What the script does:
  1. Designs the taps with the Parks-McClellan method (scipy's remez): flat from 0 to 12 kHz, and stopband from 36 kHz
     (the first image of the 48 kHz input) up, weighted 60 times as strongly as the passband.
  2. Checks analytically, before it writes anything, that the two test tones used by the testbench have every image at least
     80 dB down once the CIC that follows is counted in as well (it stops with an error if not, and then NUMTAPS has to be
     raised by hand, in steps of 4).  The owner's limit for spurious signals is 70 dB (docs/DECISIONS.md), so 80 dB leaves a margin
     for the rounding of the coefficients.  The real figure, with quantized coefficients and fixed-point arithmetic, comes
     from simulating the whole chain (sim/tx/tb_tx_chain.v), and docs/X1_TX.md has the reasoning and the measured numbers.
  3. Rounds the taps to 18-bit signed integers (COEFW, the width of the HL2's own interpolating FIR) and writes them to
     rtl/tx/fir_coeffs.vh, which rtl/tx/tx_fir_interp4.v includes.

Run from the repository root (the output path is relative to it): `py tools/design_tx_fir.py`.  It needs numpy and scipy.
The Python that comes with oss-cad-suite (C:/tools/oss-cad-suite/lib/python3.exe on the author's PC) does not have them,
so use another Python, for example the `py` launcher.
"""

import numpy as np
from scipy import signal

FS_BB  = 48e3         # sample rate of the baseband from the firmware
FS_FIR = 192e3       # after this stage (interpolate x4)
R_CIC  = 400          # next stage's interpolation factor
FS_OUT = FS_FIR * R_CIC   # 76.8 MHz

FP    = 12e3          # passband edge (single-sided); test tones must sit inside +-FP
FSTOP = FS_BB - FP     # first image edge, 36 kHz: an image of a tone at FP lands here, so the stopband has to start no later

NUMTAPS = 40           # multiple of 4 for an even polyphase split
COEFW   = 18           # signed coefficient width (matches the HL2 firX8R8/FirInterp convention)


def design(numtaps):
    """Parks-McClellan taps for the 192 kHz filter, scaled to unity gain at DC.

    The two band edges are 0 to FP (wanted, gain 1) and FSTOP to half of 192 kHz (unwanted, gain 0).  The stopband weight of 60
    makes the optimizer spend its ripple budget there, since the passband only has to be flat to a small fraction of a dB
    while the images have to be tens of dB down.
    """
    bands = [0, FP, FSTOP, FS_FIR / 2]
    h = signal.remez(numtaps, bands, [1, 0], weight=[1, 60], fs=FS_FIR)
    return h / np.sum(h)  # unity DC gain


def cic_db(f, R, N=5):
    """Gain in dB of an N-stage CIC interpolator by R at frequency f (Hz) of the output rate FS_OUT, with 0 dB at DC.

    The magnitude of one stage pair is sin(R x) / (R sin x) with x = pi f / FS_OUT, raised to the power N.
    """
    f = np.asarray(f, dtype=float)
    out = np.ones_like(f)
    nz = np.abs(f) > 1e-9
    x = np.pi * f[nz] / FS_OUT
    out[nz] = (np.sin(R * x) / (R * np.sin(x))) ** N
    return 20 * np.log10(np.abs(out))


def fir_db(h, f):
    """Gain in dB of the FIR with taps h at the frequencies f (Hz), evaluated directly from the sum of the taps times e^(-jwn)."""
    w = 2 * np.pi * f / FS_FIR
    n = np.arange(len(h))
    H = np.array([np.sum(h * np.exp(-1j * n * wi)) for wi in np.atleast_1d(w)])
    return 20 * np.log10(np.abs(H))


def worst_combined_spur(h, f0_list):
    """Worst-case FIR+CIC image level (dBc) over every image of every tone in f0_list,
    0-38.4 MHz, found via the interpolate-by-4-then-by-400 image relationship: an image of
    tone f0 lands at f0 + k*48 kHz for every integer k, attenuated by the FIR's response at
    that frequency folded into its own 192 kHz period, times the CIC's response there."""
    worst = -999.0
    worst_at = None
    for f0 in f0_list:
        for k in range(-800, 801):
            f = f0 + k * 48e3
            if f < 0 or f > 38.4e6 or k == 0:
                continue
            # The FIR runs at 192 kHz, so its response repeats every 192 kHz, and f is folded into -96 kHz to +96 kHz.
            f_mod = ((f + FS_FIR / 2) % FS_FIR) - FS_FIR / 2
            db = fir_db(h, np.array([f_mod]))[0] + cic_db(np.array([f]), R_CIC)[0]
            if db > worst:
                worst, worst_at = db, (f0, k, f)
    return worst, worst_at


if __name__ == "__main__":
    h = design(NUMTAPS)
    worst, at = worst_combined_spur(h, [7031.25, -8203.125])  # the testbench's two test tones
    droop = cic_db(np.array([FP]), R_CIC)[0]
    print(f"NUMTAPS={NUMTAPS}: analytical worst-case FIR+CIC image = {worst:.1f} dBc at {at}")
    print(f"CIC passband droop at {FP/1e3:.0f} kHz = {droop:.3f} dB "
          f"(small enough that no separate droop-compensation stage is needed)")
    if worst > -80.0:
        raise SystemExit(f"margin too thin ({worst:.1f} dBc); raise NUMTAPS")

    # Q17 integers (the sign bit leaves 17 fraction bits): unity DC gain is the largest positive code, 131071.
    scale = 2 ** (COEFW - 1) - 1
    hq = np.clip(np.round(h * scale).astype(int), -2 ** (COEFW - 1), 2 ** (COEFW - 1) - 1)
    NP = NUMTAPS // 4

    # Relative to the repository root, where the script has to be run.  The file holds one array per phase,
    # filled by taps p, p+4, p+8 ... of the filter, which is how a polyphase interpolator splits its taps.
    out_path = "rtl/tx/fir_coeffs.vh"
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("// SPDX-License-Identifier: Apache-2.0\n")
        f.write("// Copyright 2026 Franz Schöning, https://www.schoning.com\n")
        f.write("//\n")
        f.write("// Auto-generated by tools/design_tx_fir.py -- do not hand-edit.\n")
        f.write(f"// Interpolate-by-4 polyphase FIR, 48 kHz -> 192 kHz: {NUMTAPS} taps total,\n")
        f.write(f"// {NP} taps/phase, Parks-McClellan passband 0-{FP/1e3:.0f} kHz, stopband from\n")
        f.write(f"// {FSTOP/1e3:.0f} kHz, Q{COEFW-1} signed coefficients. See docs/X1_TX.md.\n")
        f.write("//\n")
        f.write("// Icarus Verilog (oss-cad-suite) does not support unpacked array parameters\n")
        f.write("// ('{...} initializers), so these are plain `reg` arrays set once in an\n")
        f.write("// `initial` block instead of `localparam ... [0:N] = '{...}`.\n")
        f.write("// The four arrays carry syn_romstyle = \"distributed_rom\" so that they are built from LUT RAM cells instead of\n")
        f.write("// four block RAMs, which would be wasted on ten words each.\n")
        for p in range(4):
            f.write(f"(* syn_romstyle = \"distributed_rom\" *) reg signed [{COEFW-1}:0] PHASE{p}_COEF [0:{NP-1}];\n")
        f.write("initial begin\n")
        for p in range(4):
            for k, c in enumerate(hq[p::4]):
                sign = "" if c >= 0 else "-"
                f.write(f"    PHASE{p}_COEF[{k}] = {sign}{COEFW}'sd{abs(int(c))};\n")
        f.write("end\n")
    print(f"wrote {out_path}")
