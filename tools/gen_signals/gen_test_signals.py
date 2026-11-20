#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
"""
Generates the 12-bit signed ADC test-input file for the rx_bank testbench
(sim/tb_rx_bank.v). One file, one simulation run, covering:

  - several simultaneous CW carriers at chosen frequencies and levels, one per
    receiver, so that all 8 receivers can be checked working at once on
    different frequencies and at different output rates
  - a close two-tone pair (both captured by receiver 0) to check that the
    passband captures two closely spaced signals cleanly
  - broadband white noise at a realistic floor, to check the
    passband noise floor and ripple

The weakest tone is -60 dBFS (7.074 MHz).  A 12-bit ADC's quantization noise floor for a
single tone sits around -74 dBFS, so a tone at -100 dBFS could not be resolved at all in a
plain 12-bit sample dump, while -60 dBFS can be resolved and still exercises the selectivity
hard (see docs/RX_DSP.md).

Output: tools/gen_signals/out/adc_test.hex, one 3-hex-digit two's
complement sample per line (12 bits, matches `reg signed [11:0]`), readable
directly with Verilog $readmemh. It also writes adc_test_meta.json describing
every tone (frequency, level, and which receiver and rate targets it) and sim/rx_config.vh
with each receiver's NCO phase increment and rate code, so that the
testbench and the checker script both read the same source of truth.
Run from anywhere (the paths are found from the script's location; needs numpy).
"""
import json
import os

import numpy as np

FS_ADC = 76.8e6
ADC_FULL_SCALE = 2047.0  # 12-bit signed peak magnitude

N_OUT_48K = 192           # output points for the slowest (48 ksps) receivers
TOTAL_DECIM_48K = 1600    # 76.8e6 / 48e3
N_SAMPLES = N_OUT_48K * TOTAL_DECIM_48K  # 307,200 ADC samples (~4.0 ms)
# (iverilog is an interpreted event-driven simulator, so the wall time grows with the number of ADC clocks times the
# 8 parallel receivers.  The length is kept small, so that this test and sim/tb_alias.v's targeted
# alias-rejection test, run back to back by run_sim.sh, finish in a few minutes, and it still gives each
# receiver a few hundred to a few thousand output points, see docs/RX_DSP.md.)

NOISE_DBFS = -50.0  # broadband rms noise level, full 0..38.4 MHz Nyquist

# (freq_hz, level_dbfs, receiver_index, rate_ksps, note)
TONES = [
    (1.839e6, -20.0, 0, 48,  "two-tone pair A (rx0)"),
    (1.841e6, -20.0, 0, 48,  "two-tone pair B (rx0)"),
    (3.573e6, -30.0, 1, 48,  "rx1 target"),
    (7.074e6, -60.0, 2, 96,  "rx2 target (matches task example freq/level)"),
    (10.136e6, -40.0, 3, 96, "rx3 target"),
    (14.074e6, -55.0, 4, 192, "rx4 target (weak, task's other example freq)"),
    (18.100e6, -35.0, 5, 192, "rx5 target"),
    (21.074e6, -45.0, 6, 384, "rx6 target"),
    (28.074e6, -25.0, 7, 384, "rx7 target"),
]

# receiver LO = its target tone frequency (rx0 uses the midpoint of the pair)
RX_LO_HZ = {
    0: (1.839e6 + 1.841e6) / 2,
    1: 3.573e6,
    2: 7.074e6,
    3: 10.136e6,
    4: 14.074e6,
    5: 18.100e6,
    6: 21.074e6,
    7: 28.074e6,
}
RX_RATE = {0: 48, 1: 48, 2: 96, 3: 96, 4: 192, 5: 192, 6: 384, 7: 384}
RATE_CODE = {48: 0, 96: 1, 192: 2, 384: 3}

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(HERE, "out")


def main():
    """Sums the tones and the noise, rounds to 12 bits, and writes the sample file, the metadata and the Verilog config header."""
    os.makedirs(OUT_DIR, exist_ok=True)
    # A fixed seed makes the noise, and so the whole file, the same on every run.
    rng = np.random.default_rng(12345)

    t = np.arange(N_SAMPLES) / FS_ADC
    x = np.zeros(N_SAMPLES)

    for freq, db, rx, rate, note in TONES:
        amp = ADC_FULL_SCALE * (10 ** (db / 20.0))
        x += amp * np.cos(2 * np.pi * freq * t)

    noise_rms = ADC_FULL_SCALE * (10 ** (NOISE_DBFS / 20.0))
    x += rng.normal(0.0, noise_rms, N_SAMPLES)

    xq = np.round(x)
    xq = np.clip(xq, -2048, 2047).astype(np.int32)
    clipped = np.sum((xq == 2047) | (xq == -2048))
    if clipped:
        print(f"WARNING: {clipped} samples clipped at full scale")

    hex_path = os.path.join(OUT_DIR, "adc_test.hex")
    with open(hex_path, "w") as f:
        for v in xq:
            uval = int(v) & 0xFFF
            f.write(f"{uval:03x}\n")

    meta = {
        "fs_adc": FS_ADC,
        "n_samples": N_SAMPLES,
        "adc_full_scale": ADC_FULL_SCALE,
        "noise_dbfs": NOISE_DBFS,
        "tones": [
            {"freq_hz": f, "level_dbfs": db, "rx": rx, "rate_ksps": rate, "note": note}
            for (f, db, rx, rate, note) in TONES
        ],
        "receivers": [
            {
                "index": rx,
                "lo_hz": RX_LO_HZ[rx],
                "rate_ksps": RX_RATE[rx],
                "rate_code": RATE_CODE[RX_RATE[rx]],
            }
            for rx in range(8)
        ],
    }
    meta_path = os.path.join(OUT_DIR, "adc_test_meta.json")
    with open(meta_path, "w") as f:
        json.dump(meta, f, indent=2)

    # Verilog config header for the testbench: NCO phase increments and rate
    # codes for all 8 receivers, computed here (not in Verilog) to keep the
    # testbench free of floating point.
    vh_path = os.path.normpath(os.path.join(HERE, "..", "..", "sim", "rx_config.vh"))
    with open(vh_path, "w") as f:
        f.write("// SPDX-License-Identifier: Apache-2.0\n")
        f.write("// Copyright 2026 Franz Schöning, https://www.schoning.com\n")
        f.write("// Generated by tools/gen_signals/gen_test_signals.py -- do not edit by hand.\n")
        f.write(f"localparam N_SAMPLES = {N_SAMPLES};\n")
        for rx in range(8):
            lo = RX_LO_HZ[rx]
            phase_inc = round(lo / FS_ADC * (2**32))
            rate = RX_RATE[rx]
            f.write(f"localparam signed [31:0] RX{rx}_PHASE_INC = 32'sd{phase_inc}; "
                    f"// {lo/1e6:.4f} MHz\n")
            f.write(f"localparam [1:0] RX{rx}_RATE_SEL = 2'd{RATE_CODE[rate]}; // {rate} ksps\n")

    print(f"Wrote {N_SAMPLES} samples ({N_SAMPLES/FS_ADC*1e3:.2f} ms) to {hex_path}")
    print(f"Verilog config header written to {vh_path}")
    print(f"Metadata written to {meta_path}")
    print(f"Clipped samples: {clipped}")


if __name__ == "__main__":
    main()
