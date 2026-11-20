#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
"""
Analytical worst-case alias rejection of the zoom receiver's decimation chain (rtl/zoom/zoom_ddc.v: cic_fixed by 10, then
cic_var_pow2 by 2^span_shift, then a second CIC (zoom_cic_narrow, for the narrowest spans), then zoom_fir_half by 2).

The zoom receiver shows a narrow slice of the 0 to 38.4 MHz input spectrum, from 3.072 MHz wide down to 3 kHz wide (eleven
spans, numbered 0 to 10), and a strong signal outside that slice must not fold into it.  This script finds, for each span,
the input frequency that gets through the chain with the least attenuation while landing inside the displayed band, and
predicts how many dB down it will be.

Method: every candidate frequency at the ADC (N_SCAN points, starting just past the edge of the wanted band, since anything
inside it is the wanted signal) is folded through the stages in sequence, as tools/analyze_alias.py does for the receivers, and
scored by the combined attenuation: cic_fixed's response at that frequency, plus cic_var_pow2's response at the frequency
that is left after cic_fixed (and zoom_cic_narrow's after that), plus the FIR's response at the frequency that is left after
the CIC stages.  Only candidates whose final landing frequency falls inside the displayed band count, and the one with the
least combined attenuation is the worst case.  Scoring against the whole chain at once is needed because a frequency that
is bad for one stage need not be bad for the others, and the combined worst case often has one stage attenuating poorly
while the other two are close to their passbands, which a search that takes each stage on its own never evaluates.

The FIR response uses the quantized coefficients from rtl/zoom/zoom_fir_half_coeffs.hex, the same ones the Verilog uses.

Run from anywhere: python tools/analyze_zoom_alias.py  (needs numpy)
Writes: sim/zoom/zoom_alias_config.vh (the worst-case frequency and the predicted dB for each span, which
sim/zoom/zoom_alias_sim.v includes directly) and prints the table per span.
"""
import os

import numpy as np

# The chain's parameters, which have to match the Verilog instances named in the comments.
FS_ADC = 76.8e6
CIC1_D, CIC1_N = 10, 9   # rtl/zoom/zoom_ddc.v cic_fixed instance
CIC2_N = 11               # rtl/zoom/zoom_ddc.v cic_var_pow2 instance
CIC2_MAX_SHIFT = 6        # its largest decimation, 64
CIC3_N = 11               # rtl/zoom/zoom_cic_narrow.v: span index 7 to 10, decimation 2 to 16 behind cic_var_pow2 at 64
FIR_TAPS, FIR_COEFF_WIDTH = 63, 20   # rtl/zoom/zoom_fir_half.v / tools/gen_zoom_fir_coeffs.py
USABLE_FRACTION = 0.8     # docs/F3_ZOOM.md section 3

SPAN_SHIFTS = list(range(11))  # span index 0..10: 3.072 MHz down to 3 kHz
N_SCAN = 400_000  # candidate ADC-domain frequencies scanned per span

HERE = os.path.dirname(os.path.abspath(__file__))
VH_PATH = os.path.normpath(os.path.join(HERE, "..", "sim", "zoom", "zoom_alias_config.vh"))
FIR_HEX_PATH = os.path.normpath(os.path.join(HERE, "..", "rtl", "zoom", "zoom_fir_half_coeffs.hex"))


def load_fir_coeffs():
    """Read the actual quantized coefficients zoom_fir_half.v uses (not a
    freshly designed ideal filter), so this analysis matches the real RTL.  The file has one two's complement
    hex word per line, FIR_COEFF_WIDTH bits wide, and each is scaled to a fraction of full scale."""
    scale = float(2 ** (FIR_COEFF_WIDTH - 1))
    vals = []
    with open(FIR_HEX_PATH) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            u = int(line, 16)
            if u >= (1 << (FIR_COEFF_WIDTH - 1)):
                u -= (1 << FIR_COEFF_WIDTH)
            vals.append(u / scale)
    assert len(vals) == FIR_TAPS, f"expected {FIR_TAPS} coefficients, got {len(vals)}"
    return np.array(vals)


def cic_mag_db(f, D, N, Fs):
    """|H(f)| in dB of an order-N, decimate-by-D CIC, DC-normalized to 0 dB,
    input sampled at Fs. f may be a numpy array."""
    f = np.asarray(f, dtype=float)
    x = np.pi * f / Fs
    num = np.sin(np.pi * f * D / Fs)
    den = D * np.sin(x)
    with np.errstate(divide="ignore", invalid="ignore"):
        h = np.where(np.abs(np.sin(x)) < 1e-12, 1.0, num / den)
    return 20 * np.log10(np.maximum(np.abs(h) ** N, 1e-15))


def fir_mag_db(f, Fs_in, coeffs):
    """|H(f)| in dB of the FIR (direct summation -- exact, any frequency,
    no grid needed), input sampled at Fs_in. f may be a numpy array."""
    f = np.asarray(f, dtype=float)
    w = 2 * np.pi * np.mod(f / Fs_in, 1.0)
    n = np.arange(len(coeffs))
    # one exp() matrix instead of a Python loop: (len(f), len(coeffs))
    H = np.exp(-1j * np.outer(w, n)) @ coeffs
    return 20 * np.log10(np.maximum(np.abs(H), 1e-15))


def fold(f, Fout):
    """Fold frequency array f (Hz) into [-Fout/2, Fout/2]."""
    return f - np.round(f / Fout) * Fout


def worst_combined_case(shift, fir_coeffs, edge_guard=1.001):
    """Score every candidate ADC-domain frequency by the FULL chain's
    combined attenuation, restricted to candidates that actually land
    inside the displayed band (see the module docstring for the reason
    the stages are not scored one at a time). Returns
    (worst_db, f_rf_hz, landing_freq_hz), or three Nones if no candidate lands inside."""
    # The decimation of cic_var_pow2 is at most 64; spans beyond that (shift 7 to 10) get the rest from zoom_cic_narrow.
    d2 = 2 ** min(shift, CIC2_MAX_SHIFT)
    d3 = 2 ** max(shift - CIC2_MAX_SHIFT, 0)
    Fs_cic1_out = FS_ADC / CIC1_D
    Fs_cic2_mid = Fs_cic1_out / d2            # between cic_var_pow2 and zoom_cic_narrow
    Fs_cic2_out = Fs_cic2_mid / d3            # the rate in front of zoom_fir_half
    final_rate = Fs_cic2_out / 2
    displayed_span = USABLE_FRACTION * final_rate
    edge = displayed_span / 2.0

    # Candidates start just past the edge: anything at |f_rf| <= edge is the
    # WANTED signal itself (baseband tuning), not an alias source. A uniform
    # scan over 38.4 MHz is too coarse for the narrow spans (their alias bands
    # are a few kHz wide), so a dense scan of the first 400 kHz is added: every
    # alias band of zoom_cic_narrow and of the FIR lies there, and the bands
    # further out are behind the nulls of cic_var_pow2 as well.
    f_rf = np.linspace(edge * edge_guard, FS_ADC / 2, N_SCAN)
    if d3 > 1:
        f_rf = np.concatenate([np.linspace(edge * edge_guard, 400e3, N_SCAN), f_rf])

    # r1, r2 and r3 are the responses (dB, negative) of the stages at the frequency that reaches each of them, f1 and f2 the
    # frequencies after folding, and f3 the final landing frequency in the output band.  The response of a stage depends on
    # the absolute value of the frequency, because a real filter treats +f and -f the same.
    r1 = cic_mag_db(f_rf, CIC1_D, CIC1_N, FS_ADC)
    f1 = fold(f_rf, Fs_cic1_out)
    if d2 > 1:
        r2 = cic_mag_db(np.abs(f1), d2, CIC2_N, Fs_cic1_out)
        f2 = fold(f1, Fs_cic2_mid)
    else:
        r2 = np.zeros_like(f1)
        f2 = f1
    if d3 > 1:
        r2 = r2 + cic_mag_db(np.abs(f2), d3, CIC3_N, Fs_cic2_mid)
        f2 = fold(f2, Fs_cic2_out)
    r3 = fir_mag_db(np.abs(f2), Fs_cic2_out, fir_coeffs)
    f3 = fold(f2, final_rate)

    total = r1 + r2 + r3
    inside = np.abs(f3) <= edge
    if not inside.any():
        return None, None, None
    idx_candidates = np.where(inside)[0]
    i = idx_candidates[np.argmax(total[idx_candidates])]  # least (combined) attenuation
    return -total[i], f_rf[i], f3[i]


def main():
    """Runs the worst-case search for each span, prints the table and writes the Verilog include for the alias simulation."""
    fir_coeffs = load_fir_coeffs()

    results = {}
    print(f"{'span':>10}  {'worst combined':>16}  {'interferer (ADC)':>18}  {'lands at':>12}")
    for shift in SPAN_SHIFTS:
        Fs_cic2_out = FS_ADC / CIC1_D / (2 ** shift)
        final_rate = Fs_cic2_out / 2
        displayed_span = USABLE_FRACTION * final_rate

        worst_db, f_rf, lands_at = worst_combined_case(shift, fir_coeffs)
        results[shift] = (displayed_span, worst_db, f_rf, lands_at)
        print(f"{displayed_span/1e3:>7.2f}k  {worst_db:>13.1f} dB  {f_rf/1e6:>15.4f} MHz  {lands_at/1e3:>9.2f} kHz")

    # Verilog config for sim/zoom/zoom_alias_sim.v: per span the displayed width, the interferer's frequency, the predicted
    # attenuation and the total decimation (10 from cic_fixed, 2^shift from the variable stages, 2 from the FIR).
    os.makedirs(os.path.dirname(VH_PATH), exist_ok=True)
    with open(VH_PATH, "w") as f:
        f.write("// SPDX-License-Identifier: Apache-2.0\n")
        f.write("// Copyright 2026 Franz Schöning, https://www.schoning.com\n")
        f.write("// Generated by tools/analyze_zoom_alias.py -- do not edit by hand.\n")
        f.write(f"localparam integer ZOOM_ALIAS_N_SPANS = {len(SPAN_SHIFTS)};\n")
        for shift in SPAN_SHIFTS:
            displayed_span, worst_db, f_rf, lands_at = results[shift]
            total_decim = CIC1_D * (2 ** shift) * 2
            f.write(f"localparam real ZOOM_ALIAS_SPAN_{shift}_HZ         = {displayed_span:.3f};\n")
            f.write(f"localparam real ZOOM_ALIAS_INTERFERER_{shift}_HZ   = {f_rf:.3f};\n")
            f.write(f"localparam real ZOOM_ALIAS_PREDICTED_{shift}_DB    = {worst_db:.3f};\n")
            f.write(f"localparam integer ZOOM_ALIAS_TOTAL_DECIM_{shift}  = {total_decim};\n")
    print(f"\nWritten to {VH_PATH}")


if __name__ == "__main__":
    main()
