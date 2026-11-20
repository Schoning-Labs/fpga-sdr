# Reference vectors from the C implementation (FreeDV 700D / 700E receiver)

Made 2026-10-13 with **codec2 1.2.0** (github.com/drowe67/codec2, tag `1.2.0`, commit
`06d4c11e699b0351765f10398abb4f663a984f36`), program `freedv_rx`, built with gcc 13.3.0
(`tools/fdvref/README.md` has the build and every command). Used by `tests/c_reference.rs`.
The C code is not part of this repository; these are its outputs.

`freedv_rx --vv` prints one line per call (state, unique word errors, frequency offset, SNR
estimate, decoder iterations, parity checks, flags). `tools/fdvref/trace2bin.py` turns the lines into
`NAME.trace`, 12 bytes per call (format in that script). The test runs our receiver on the same
signal and compares call by call.

| Name | Signal the C receiver ran on | Files |
|---|---|---|
| `s700d`, `s700e` | the FreeDV program's sample recordings `ve9qrp_700d.wav`, `ve9qrp_700e.wav`, 112 s, whole (`tools/fetch_freedv_test.sh`) | `.trace`, `.txt` (text channel output), `_speech_4s.raw` (the first 4 s of speech out, 64 KB) |
| `chd`, `che` | the same recordings, first 30 s, through the test channel (`tests/common`): 700D: -33 Hz, 1 dB SNR in 3 kHz, seed 7; 700E: -35 Hz, 3 dB, seed 8 | `.trace`, `.txt` |
| `ofd`, `ofe` | the same, 30 s, shifted by -40 Hz / +40 Hz, no noise | `.trace`, `.txt` |
| `tfd`, `tfe` | 30 s of test frames from our modulator, channel at gain 0.5: 700D: -25 Hz, 0 dB, seed 9; 700E: -30 Hz, 3 dB, seed 10; `freedv_rx --testframes` | `.trace`, `.txt`, `.counts` (bit and packet error totals it printed) |
| `txd`, `txe` | 10 s of `ve9qrp_10s.raw` through our encoder and modulator with the text "cq cq cq hello world" in the text channel | `.trace`, `.txt` |

The noise comes from the fixed-seed generator in `tests/common/mod.rs`; the test rebuilds the
signal bit for bit, so no signal file is stored. Size of this folder: about 250 KB, of which 128 KB
are the two speech files.

Tolerances in the tests: sync state, flags, unique word errors, samples asked for per call, LDPC
iterations and parity checks: equal in every call. Frequency offset 0.1 Hz and SNR estimate 0.1 dB (the
printed resolution; SNR only compared below 40 dB). Speech: at most 2 steps apart (measured 1), 99 %
identical. Test frames: uncoded error totals equal, coded error totals within 3 % (frames the
decoder gives up on, 100 iterations, can end in different bits; the total differed by 4 of 240).
