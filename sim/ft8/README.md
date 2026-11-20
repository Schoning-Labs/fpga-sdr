<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->

# FT8 front end testbenches

The Verilog benches in this folder check the FT8 blocks of the chip (the spectrogram engine, the sync search and the candidate stage under `rtl/ft8`) against the bit-true Rust model of the same blocks in `fw/tr-modes`, and every bench is run by `tools/check.sh` like the other `tb_*.v` files of the repository.

## Vector files

The folder `vectors/` holds the numbers the benches compare against. Two kinds are committed, because they do not come from anyone's recording: `f7_synth_cands.hex`, `f7_synth_pass1.hex` and `f7_synth_pass2.hex` are made from a small pseudo-random signal by `ft8-frontend f7-synth`, and `ft8_w3840_full.hex` is the table of window values of the 3,840 point transform, which is computed from a formula.

Seven more are not committed, and they have to be made once on each machine before the benches that read them can run:

| File | What it holds | Read by |
|---|---|---|
| `qso1_small_audio.hex`, `qso3_busy_small_audio.hex` | the first 3,840 samples of the recording, one 16 bit sample per line | `tb_ft8_frame_core.v`, `tb_ft8_spectrogram.v` |
| `qso1_small_power.hex`, `qso3_busy_small_power.hex` | the first 5 x 1,024 power words of the model's spectrogram of the recording | `tb_ft8_frame_core.v`, `tb_ft8_spectrogram.v` |
| `f6_qso1_spec_lw.hex` | lane words 200 to 221 of all 372 spectrogram rows of `qso1` | `tb_ft8_sync.v` |
| `f6_qso1_sync295.hex`, `f6_qso1_sync372.hex` | the model's sync records for bins 401 to 431 over the first 295 and the first 372 rows of `qso1` | `tb_ft8_sync.v` |

These files hold samples of two recordings from the WSJT-X sample set (`qso1.wav` and `qso3_busy.wav`, by Joe Taylor K1JT and the WSJT team, GPL-3.0-or-later) or numbers calculated from them, which is why they are made on the machine that runs the benches and are not part of this Apache-2.0 repository.

## Making them

```
bash tools/fetch_test_audio.sh
bash tools/make_ft8_vectors.sh
```

The first script downloads the recordings into `captures/ft8/` (which git ignores), and the second one builds the host tool `ft8-frontend` and writes the seven files into `sim/ft8/vectors/`, where git ignores them as well. It needs cargo and a network connection for the first step, and takes under a minute once the tool is built. `tools/check.sh` runs the second script by itself when the recordings are present, and it skips a bench whose vector files are missing, so a checkout without the recordings still passes everything that does not need them.

The files made this way are identical to the ones the benches were first written against, which was checked by making them again and comparing every line.
