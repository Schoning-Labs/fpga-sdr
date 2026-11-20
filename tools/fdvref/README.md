<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# Reference build of codec2 1.2.0 (comparison of the Rust port with the C implementation)

Done once, 2026-10-13, with the owner's permission, on the development PC (Windows 11). Results:
`docs/FREEDV.md` section 4. No upstream C code is in this repository and none is linked into the
product; the C programs were built and run outside it, only their *output* is committed
(`fw/tr-codec2/tests/vectors`, `fw/tr-freedv/tests/vectors`, both with a README).

## What was built

| | |
|---|---|
| Source | `git clone --branch 1.2.0 https://github.com/drowe67/codec2` (commit `06d4c11e699b0351765f10398abb4f663a984f36`, 2023-07-20) |
| Compiler | gcc 13.3.0 (Ubuntu 24.04 under WSL 2, already installed), `-O3 -fPIC -D_GNU_SOURCE=1`, x86-64 |
| Build | `build_codec2.sh` here. cmake is not on the PC (the one in the Visual Studio Build Tools was not used: codec2 needs POSIX tools), so the script does by hand what `CMakeLists.txt` does: `generate_codebook` makes the eight `codebook*.c`, `config.h` and `codec2/version.h` are written, the sources compiled, the tools linked. `_GNU_SOURCE` is defined as cmake does, which makes `POW10F` the glibc `exp10f` |
| Tools used | `c2enc 700C`, `c2dec 700C`, `freedv_tx 700D\|700E [--testframes]`, `freedv_rx --vv [--testframes] [--txtrx f] 700D\|700E`, `ch` (channel; only for the first look at SNR scaling, the signals in the vectors use the Rust channel) |
| Inputs | `tools/fetch_freedv_test.sh` files (speech `hts1a.raw`, `ve9qrp.raw`, `ve9qrp_10s.raw`; sample modem signals `ve9qrp_700d.wav`, `ve9qrp_700e.wav`) |

`c2enc`/`c2dec` write a 7 byte header when the file name ends in `.c2`; the vectors use `.bit`
(no header, 4 bytes per frame).

## How each vector was made

All `freedv_rx` runs: `freedv_rx --vv [--testframes] --txtrx X.txt 700D|700E X.raw X.out 2> X.trace`
on a raw 16-bit 8 kHz file; `tools/fdvref/trace2bin.py X.trace tests/vectors/X.trace` turns the stderr trace
into the committed compact file.

* `fw/tr-codec2/tests/vectors`: `c2enc 700C S.raw S.bit`, `c2dec 700C S.bit S_dec.raw` for
  `S` = `hts1a` and `ve9qrp`; the committed decoder reference is the first 6 s of `ve9qrp`.
* `fw/tr-freedv/tests/vectors`: the signal files are made by the Rust example
  `cargo run --release -p tr-freedv --example fdvnoise -- ...` (the same code the tests call,
  `tests/common/mod.rs`):
  * `fdvnoise ch ve9qrp_700d.wav chd.raw -33 1 7 30`, `... ve9qrp_700e.wav che.raw -35 3 8 30`
  * `fdvnoise ch ve9qrp_700d.wav ofd.raw -40 none 0 30`, `... ve9qrp_700e.wav ofe.raw 40 none 0 30`
  * `fdvnoise tf 700D tfd.raw -25 0 9 30`, `fdvnoise tf 700E tfe.raw -30 3 10 30` (run with `--testframes`;
    the error counts are in `tfd.counts`, `tfe.counts`)
  * `fdvnoise tx 700D ve9qrp_10s.raw txd.raw 10`, `... 700E ... txe.raw 10`
  * `s700d`, `s700e`: the two sample WAVs themselves (header removed), whole; the first 4 s of
    the C output are kept as `*_speech_4s.raw`.

To redo a comparison with fresh C output (new upstream release, other signals): build with the
script, make the signal file, run `freedv_rx --vv` on it, convert with `trace2bin.py`, and compare
with `fdvtrace` (`cargo run --release -p tr-freedv --example fdvtrace -- 700D in.raw out.raw --trace t`),
which prints one line per call in the format of `freedv_rx --vv`.

## Rust tools written for the comparison

* `fw/tr-codec2/examples/c2tool.rs`: `c2tool enc|dec in out`, the command line of `c2enc`/`c2dec 700C`.
* `fw/tr-freedv/examples/fdvtrace.rs`: the behaviour of `freedv_rx` (same calls with the same
  `nin`, speech out, `--vv` style trace, text channel, `--testframes` counts).
* `fw/tr-freedv/examples/fdvnoise.rs`: the signals above.
