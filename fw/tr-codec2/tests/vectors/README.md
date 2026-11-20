# Reference vectors from the C implementation (Codec 2 700C)

Made 2026-10-13 with **codec2 1.2.0** (github.com/drowe67/codec2, tag `1.2.0`, commit
`06d4c11e699b0351765f10398abb4f663a984f36`), built with gcc 13.3.0 (`tools/fdvref/README.md`).
Used by `tests/c_reference.rs`. The C code is not part of this repository; these are its outputs.

| File | What | Command |
|---|---|---|
| `hts1a.bit` (300 B) | 75 frames of 28 bits, 4 bytes each | `c2enc 700C raw/hts1a.raw hts1a.bit` |
| `hts1a_dec.raw` (48 KB) | 3 s of 8 kHz 16-bit little-endian speech | `c2dec 700C hts1a.bit hts1a_dec.raw` |
| `ve9qrp.bit` (11 KB) | 2,811 frames (112 s) | `c2enc 700C raw/ve9qrp.raw ve9qrp.bit` |
| `ve9qrp_dec_6s.raw` (96 KB) | the first 150 frames of the C decoder's output for `ve9qrp.bit` | `c2dec 700C ve9qrp.bit x.raw`, first 96,000 bytes |

The speech inputs `hts1a.raw` and `ve9qrp.raw` are upstream's `raw/` files; the encoder test fetches them with
`tools/fetch_freedv_test.sh` (not committed) and skips without them. The decoder test needs only the files here.

Tolerances in the tests: decoder samples differ by at most 2 (measured: 1), at least 99 % identical
(measured 99.9 %); encoder frames identical to the bit in at least 99 % (measured: 100 % of
`hts1a`, 99.3 % of `ve9qrp`).
