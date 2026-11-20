<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# FreeDV (work package S9)

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Branch `freedv`. Owner decisions: FreeDV is the next mode after FT8, receive first; speech for transmit will
come in over USB and over an Ethernet remote link, both not built, voice transmit on hold
([DECISIONS.md](DECISIONS.md)). **Nothing here has run on the board.** No C or C++ is in the product: the
codec and the modem are Rust translations of the reference implementation.

State in one table:

| Part | State |
|---|---|
| Codec 2 700C decoder and encoder (`fw/tr-codec2`) | done, host tests |
| FreeDV 700D and 700E receive: modem, error correction, squelch rule, indicators (`fw/tr-freedv`) | done, host tests, decodes the reference implementation's signals |
| Modulator (for tests now, for transmit later) | done without the transmit clipper and band-pass filter |
| Sample-rate converter 12 kHz to 8 kHz, 8 kHz to 12 and 48 kHz | done |
| CPU cost on the target's instruction set | measured under QEMU (section 6) |
| FreeDV 1600 | not done (section 8) |
| Firmware mode, screen, audio queue, text channel | done, host tests and QEMU twin, never on the board (section 9) |
| Text channel (call sign in the signal) | done, varicode decoder (section 9) |
| Port against the official C implementation (codec2 1.2.0 built once and run) | done: decisions identical call by call, speech equal to 1 step of 16 bits (section 4) |

## 1. Which modes first

**700D and 700E, both.** They are the two FreeDV modes in daily use on HF, they share everything except a
table of numbers (carriers, symbol length, frame length, code), and both use the same speech codec. 700D is
the weak-signal mode (works to about -2 dB SNR, 160 ms frames, slow to lock); 700E is the fast-fading mode
(needs about 3 dB more, 80 ms frames, locks within one frame, 1.5 kHz wide).

**1600 not now.** It needs a second modem (FDMDV: 16 DQPSK carriers with pilot, about 2,000 lines of C) and a
second codec mode (Codec 2 1300: LSP scalar quantisers and LPC-based synthesis, none of which 700C uses). It
is the old mode and is used less every year. It is about as much work again as 700D/E. Left for a later
package.

**2020 is out of scope** (neural codec).

| | 700D | 700E |
|---|---|---|
| Carriers, QPSK | 17 | 21 |
| Carrier spacing | 55.6 Hz | 71.4 Hz |
| Occupied band (audio) | 1.0 to 2.0 kHz | 0.71 to 2.29 kHz |
| Symbol with cyclic prefix | 18 + 2 ms | 14 + 6 ms |
| Modem frame | 8 symbols, 160 ms | 4 symbols, 80 ms |
| Bits per frame: unique word / text / payload | 10 / 4 / 224 | 12 / 2 / 112 |
| Error correction | LDPC (224,112) | LDPC (112,56) |
| Codec frames (28 bits, 40 ms) per modem frame | 4 | 2 |

## 2. Structure of the Rust port

Source: codec2 release 1.2.0 (github.com/drowe67/codec2), which holds the codec and FreeDV's reference
implementation. Two crates, both `no_std`, no heap, `f32`, only `libm` as a dependency.

**`fw/tr-codec2`: Codec 2 700C.**

| Module | What it is | From |
|---|---|---|
| `newamp1` | harmonic amplitudes resampled to 20 points on a mel scale, mean removed, two 9-bit vector quantiser stages, 4-bit energy, 6-bit pitch; decoder interpolation between 40 ms frames; minimum-phase phase from the amplitudes | `newamp1.c`, `quantise.c`, `mbest.c` |
| `tables` | the two 512 x 20 vector quantiser tables and the energy table (82 KB of constants) | `codebook/train_120_*.txt`, `newamp1_energy_q.txt` |
| `synth` | harmonic phases from a pulse excitation, background-noise postfilter, sinusoidal synthesis by inverse FFT with overlap-add, ear protection | `phase.c`, `postfilter.c`, `sine.c`, `codec2.c` |
| `analysis`, `nlp` | encoder: windowed spectrum, pitch estimator, pitch refinement, amplitudes, voicing | `sine.c`, `nlp.c` |
| `fft` | radix-2 complex FFT (own code) | - |

The encoder was added because the tables are shared and transmit needs it; it also made the round-trip tests
possible.

Tables: `src/tables.rs` is made from upstream's text files, values unchanged, by
`awk 'NR>1 && NF>0 { printf "   "; for(i=1;i<=NF;i++) printf " %s,", $i; printf "
" }' train_120_1.txt`
(the first line of each file is the size) inside a `pub static VQ_STAGE1: [f32; K * M] = [ ... ];` frame, the
same for `train_120_2.txt` and `newamp1_energy_q.txt`. `tr-freedv/src/ldpc_tables.rs` holds the `H_rows`
arrays of `HRA_112_112.c` and `HRA_56_56.c` as they are.

**`fw/tr-freedv`: FreeDV 700D and 700E.**

| Module | What it is | From |
|---|---|---|
| `ofdm` | mode numbers; pilot waveform; coarse search (frame timing over one frame at -40, 0, +40 Hz, then +/-20 Hz in 1 Hz steps); per frame: fine timing, frequency tracking from the pilot rows, phase and amplitude per carrier from the pilots (two rows, or twelve pilots once 700D is locked), QPSK decisions, sample-clock slip; unique word; the two sync state machines; modulator | `ofdm.c`, `ofdm_mode.c` |
| `ldpc` | the two codes, encoder, sum-product decoder, QPSK symbols to bit likelihoods, golden-prime interleaver | `mpdecode_core.c`, `interldpc.c`, `gp_interleaver.c`, `HRA_*.c` |
| `lib` | `Rx` (modem audio in, speech out, status, indicators, squelch), `RxStream` (blocks of any size), `Tx` | `freedv_700.c`, `freedv_api.c` |
| `resample` | polyphase converter by small integer ratios (own code) | - |

Deviations from upstream, all inside the receiver (nothing that changes what is sent or accepted):

- The receive buffer holds real samples (the input is real audio); upstream holds complex. Same sums.
- The frequency correction phase is advanced by recurrence instead of one `cos`/`sin` per sample.
- The frame timing correlation only converts the samples it reads.
- Fixed arrays instead of allocated lists in the LDPC decoder. Its phi function is upstream's step table (first
  built with the exact function; the comparison with the C receiver showed that the table matters, section 4).
- Where C computes in double (its constants `PI`, `TWO_PI` and the LDPC constants are doubles) and the result
  matters, the port does too, in a few places: the harmonic count of an unvoiced frame, the pitch and the
  excitation phase of the decoder, the LDPC `max_star`. Single precision there gave different results (section 4).
- When squelch holds a frame back, upstream outputs no samples; this port outputs the same number of zeros, so
  the audio queue keeps its timing.
- Upstream's quirks are kept where they affect behaviour: the amplitude estimate, the stop rule of the
  decoder, Es/No fixed at 3 for the likelihoods.

**LDPC and the FT8 code.** Checked: not reusable. The FT8 decoder in the vendored mfsk-core is written
around the (174,91) code (its matrix, its CRC, its ordered-statistics fallback) and needs `alloc`. FreeDV's
codes are repeat-accumulate codes given as a table of the data part only, decoded with upstream's own
message schedule and stop rule, which the test vectors depend on. The FreeDV decoder is 150 lines.

**Sample rates.** FreeDV works at 8 kHz. The back end's audio ring is 12 ksps and the audio outputs are
48 kHz. `resample::Resampler` does 12 to 8 (x2/3) in front and 8 to 48 (x6) behind, 24 taps per phase,
flat within 0.2 dB from 700 to 2,300 Hz. All three rates come from the HL2's clock, so there is no drift
between input and output and no rate matching is needed.

**Interface for transmit** (left clean, not wired): `Tx::tx_speech(&[i16] 8 kHz speech) -> 8 kHz modem
audio`, `Tx::tx_bits` for bits, `Tx::set_eq`. What transmit still needs is in section 8.

## 3. Licence

- codec2 (codec and FreeDV code) is **LGPL-2.1** ("version 2.1 as published by the Free Software
  Foundation", no "or later"). A translation into Rust is a modified version of the library, so the
  translated code stays under LGPL-2.1.
- fpga-sdr is **GPL-3.0-or-later**. The combination is allowed by **section 3 of the LGPL 2.1**: any copy of
  the library may be distributed under the ordinary GPL, version 2 **or any later version**, instead. The
  firmware image that contains the two crates is distributed under GPL-3.0-or-later on that basis. This is
  the standard way LGPL-2.1 code enters a GPL-3 program; no permission from the authors is needed.
- The two crates keep **`LGPL-2.1-only`** as their own licence (in `Cargo.toml` and in every file's SPDX
  line), so the port can be given back to the codec2 project. Converting them to GPL would be allowed but
  cannot be undone for that copy, and gains nothing.
- Each translated file names the upstream files it came from, their authors and copyright years, carries the
  LGPL notice, and the line "Modified 2026 by Franz Schöning: translated from C to Rust" (LGPL 2.1 section
  2b: modified files must say so). The LDPC decoder also names Matthew C. Valenti (Iterative Solutions Coded
  Modulation Library, LGPL-2.1-or-later) and the codes' author Bill Cowley.
- Files added: `fw/tr-codec2/NOTICE`, `fw/tr-codec2/COPYING.LGPL-2.1`, `fw/tr-freedv/NOTICE`,
  `fw/tr-freedv/COPYING.LGPL-2.1` (the licence text as upstream ships it).
- For a binary release: ship the GPL-3 text (already `LICENSE`), the two `NOTICE` files and the LGPL text,
  and offer the source as for the rest of the firmware. Nothing more.
- Test recordings are downloaded by `tools/fetch_freedv_test.sh`, not committed. The LDPC test vectors and
  tables are small parts of the LGPL sources and are committed with their notice.
- "FreeDV" and "Codec 2" are names of David Rowe's projects. Use them to say what the radio is compatible
  with, not as product names.

## 4. What is proven, and how

Run: `bash tools/fetch_freedv_test.sh`, then `cargo test -p tr-codec2 -p tr-freedv` in `fw/`. The tests
need no C program: the reference implementation's output is committed as small vectors (below).

| Proof | Result |
|---|---|
| **LDPC decoder against the test vectors that ship with each code** in codec2 (decoder input, decoded codeword) | both codes: output equal bit for bit |
| **Upstream's own 700D test signal** (`raw/testframes_700d.raw`, made by the C transmitter, input of upstream's backwards-compatibility test; 5 frames of known bits) | 4 frames demodulated with 0 of 224 bit errors before error correction and all parity checks met (the fifth is used up by the search) |
| **The FreeDV program's sample signals** (`freedv-gui/wav/ve9qrp_700d.wav`, `ve9qrp_700e.wav`: 112 s of speech each, sent by the C transmitter with its clipper and filter) | 700D: 696 of 702 frames, 700E: 1,402 of 1,405 frames in confirmed sync (the rest is lock time); a codeword in every frame; sync never lost |
| **Our encoder against the C encoder**: the codec bits decoded from those two signals compared with what our encoder makes of the same speech file | equal in 99.8 % of the first vector quantiser stage, 99.5 % of the second, 99.9 % of energy and of pitch/voicing (about 2,800 values each). The rest is rounding: the encoders run on different arithmetic |
| Test frames through our modulator and a channel: no noise; level 0.05 to 1.0; frequency offsets -52 to +47 Hz | 0 bit errors, frequency estimate within 0.1 Hz |
| The same with white noise (SNR in 3 kHz, 20 s each) | 700D at 3 dB: 0.8 % before, 0 after correction; at 0 dB: 4.3 % before, 0.2 % after. 700E at 5 dB: 1.2 % before, 0 after; at 2 dB: 8.9 % before, 3.1 % after |
| Sender's sample clock 200 ppm off | sync held for 60 s, 0 errors, estimate 197 ppm |
| Indicators | frequency offset within 0.1 Hz; SNR estimate 8.6 dB for 8 dB sent |
| Noise alone, squelch on | never confirmed sync, no speech |
| Speech, encoder to decoder through modulator, 12 Hz offset, 6 dB SNR, the 12 kHz converter pair | 700D: every received frame carries exactly the encoder's bits. 700E: all frames after the first 0.8 s (see below) |
| Codec alone: synthetic vowels at 100 to 240 Hz; upstream speech through encoder and decoder | pitch found within 4 %; loudness contour correlation 0.88 to 0.92; long-term spectrum within 3.7 dB per band |

### Against the official C implementation (2026-10-13)

codec2 1.2.0 (the release the port was made from) was built and run once on the development PC, outside this
repository (`tools/fdvref/README.md`: gcc 13.3.0 under WSL; `cmake` was not available, so the script does what
its `CMakeLists.txt` does). Its tools `c2enc 700C`, `c2dec 700C`, `freedv_tx`, `freedv_rx --vv` and `ch` were run
on the speech files and sample signals the tests use, and the Rust code on the same files. What the C programs
printed is committed in `fw/tr-codec2/tests/vectors` (160 KB) and `fw/tr-freedv/tests/vectors` (225 KB), with a
README each, and `tests/c_reference.rs` in both crates compares against them (no C needed). The last column is
what the tests assert.

| Comparison | Result | Test tolerance |
|---|---|---|
| **(a) Speech decoder**, `c2dec 700C` against `Decoder700c` on the same bit streams: 4 files, 1.1 million samples (`hts1`, `hts1a`, `kristoff`, 112 s of `ve9qrp`) | **Equal to float rounding**: largest difference 1 step of the 16 bit output, rms 0.03 steps, 99.9 % of the samples identical, SNR of the difference 95 to 97 dB. Before the fixes below: 17 dB on the short files, 7 dB on the 112 s file | at most 2 steps, 99 % identical, SNR over 80 dB |
| **(b) Speech encoder**, `c2enc 700C` against `Encoder700c`: quantiser indexes (two 9 bit vector quantiser stages, 4 bit energy, 6 bit pitch) | **Bit exact** on `hts1`, `hts1a`, `kristoff` (350 frames). `ve9qrp` (112 s): 2,791 of 2,811 frames bit exact; the other 20 differ in one field by one step (energy by 1; one voicing flip; one pitch by 6 steps): a pitch or an energy at a decision boundary, where the two programs round differently. Not chased: encoder only, transmit only | 99 % of frames bit exact, energy within 1 |
| **(c) Receiver on the FreeDV program's sample signals** (`ve9qrp_700d.wav`, `ve9qrp_700e.wav`, 112 s each), `freedv_rx` against `Rx`, call by call (702 and 1,405 calls) | **Identical decisions in every call**: sync state, trial/sync flags, unique word errors, samples asked for next, LDPC iterations and parity checks, frame count (700 and 1,403 frames, none without a codeword), first sync in the same call (the third), frequency offset to the printed 0.1 Hz. **Speech equal to float rounding** (largest difference 1 step, 99.9 % identical). **Text channel identical** (410 and 411 characters, "cq cq cq hello world"). SNR estimate equal to 0.1 dB, except on these noise-free files where it is 80 dB and differs by up to 0.8 dB (it divides by noise that is rounding error) | as left; SNR compared only below 40 dB |
| **(d) Noise and frequency offset**: both receivers on the same noisy files made by the C channel tool `ch` (SNR in 3 kHz, offset): 700D 4 dB +25 Hz, 1 dB -33 Hz; 700E 7 dB +20 Hz, 3 dB -35 Hz; and offsets alone, -40 Hz (700D) and +40 Hz (700E) | **Identical decisions in every call** in all six. Frames without a codeword (C / Rust): 8 / 8 and 33 / 33 (700D), 29 / 29 and 127 / 127 (700E); same iteration counts, same text, speech equal to 1 step even in those frames. Frequency estimate within 0.1 Hz of the C value in every call (and of the offset applied: -32.98 and +24.99 Hz) | as (c) |
| **(d2) Test frames** (known bits, `--testframes`) over `ch` noise: 700D 3 dB +20 Hz, 0 dB -25 Hz; 700E 6 dB +20 Hz, 3 dB -30 Hz, 112 s each | **Identical error counts**: uncoded 1186 / 1186, 6723 / 6723, 977 / 977, 6730 / 6730 bit errors (C counts the unique word bits too; the port now does), coded 8 / 8, 24 / 24, 1 / 1, 16 / 16 | - |
| **(e) Our modulator read by the C receiver**: 10 s of speech and text from `Encoder700c` + `Tx` (clean), and test frames from `Tx` over noise (700D 0 dB -25 Hz, 700E 3 dB -30 Hz, 30 s) | The C receiver finds every frame without error and prints the text "cq cq cq hello world"; the traces of both receivers are identical. Test frames: call by call identical, uncoded counts equal; coded errors 240 (C) against 236 (Rust) in 700D, 28 / 28 in 700E: in 3 of the 25 frames the decoder gives up on (100 iterations) the bits of the last iteration differ in a few places | uncoded equal, coded within 3 % |

**Defects of the port found by the comparison, all fixed** (each was a place where C evaluates in double or uses
a different function than the first translation):

1. **Number of harmonics of an unvoiced frame** was 50, C has 49 (`floorf(M_PI / Wo)`: the quotient is evaluated in
   double; in `f32` it comes out as exactly 50). The speech decoder draws one random phase per harmonic, so after the
   first unvoiced frame the two decoders drew different random numbers for the rest of the file, and every
   noise-like part of the speech (unvoiced sound, background) was different noise in the two programs: the same
   spectrum, but 17 dB SNR of the difference.
2. **Pitch decoding** used `libm`'s single-precision `exp10f`/`log10f`, 1 to 3 steps of the last digit off the C
   library's. The excitation phase integrates the pitch for as long as the decoder runs, so the error added up:
   after a minute the pitch pulses of voiced sound were a fraction of a period away from the C decoder's (7 dB SNR
   of the difference over 112 s). The pitch is now computed with the C code's sequence of float and double steps.
3. **Excitation phase wrap** (`TWO_PI` is a double constant) done in `f32` added a rounding error each frame to the
   same phase. Same effect as 2.
4. **LDPC phi function**: the first translation used the exact function, upstream uses a step table (`phi0.c`). On
   weak signals the decoders then differed in iteration count in every second frame, and in about 1 frame in 100
   one gave up (100 iterations) where the other found the codeword in 4. The table (103 entries, made by evaluating
   upstream's function over its input range) is in `tr-freedv/src/phi_table.rs`.
5. **`max_star`** of the likelihood calculation (double constants in C) in `f32`: in frames the decoder gives up on, a
   few bits differed. Now double as in C (soft double arithmetic on the target: about 1 % of the receiver).
6. **SNR estimate after lock**: upstream smooths from the value it had (0 at start) and does not restart at -5 when
   it loses sync; the port restarted at -5, so the first 2 to 6 frames after each lock read up to 2 dB too low. That
   decides squelch only in those frames.
7. The test-frame bit counter did not count the unique word bits that upstream's does (a statistic only).

**Still different from the C program:** (i) speech samples differ by up to 1 step of 16 bits (float rounding of
different `sinf`/`cosf`/FFT code; nothing to fix); (ii) the encoder differs in 1 frame in 140 by a step in one
field; (iii) the SNR estimate of signals above 40 dB; (iv) the bits of frames the LDPC decoder gives up on can
differ in a few places; (v) with squelch active, zeros instead of no samples (section 2); (vi) not tested: fading
channels (`ch --mpg|--mpp|--mpd` need upstream's fading sample files, made by an Octave script; Octave was not on
the PC).

**Listening samples** (8 kHz WAV, written by the tests): `captures/freedv/out/` in the worktree.

| File | What |
|---|---|
| `decoded_ve9qrp_700d.wav`, `decoded_ve9qrp_700e.wav` | the FreeDV program's sample signals decoded by our receiver: **the ones to listen to** |
| `roundtrip_700D_ve9qrp_6dB.wav`, `roundtrip_700E_ve9qrp_6dB.wav` | our encoder and modulator, 6 dB SNR, our receiver; `..._modem_signal.wav` is what the receiver heard |
| `codec_roundtrip_ve9qrp_10s_700c.wav`, `codec_roundtrip_hts1a_700c.wav` | codec only |

Harness for any recording (8 or 12 kHz WAV in, speech WAV out, one status line per second):
`cargo run --release -p tr-freedv --example freedv_rx -- 700D in.wav out.wav [--squelch -2]`.

**Found while testing (upstream behaviour, kept):** the coarse frequency search has a 1 Hz grid. 700E then
corrects at most 0.1 Hz per frame, so a left-over error of 1 Hz takes 0.8 s to remove and frames can fail
in that time at low SNR. A finer first estimate (interpolating the correlation peak) would fix it without
changing compatibility. Not done.

## 5. Test plan from here

1. The tests above stay as the regression set (10 s on the host).
2. Owner listens to the two `decoded_...` files.
3. Done (section 4); fading channels remain.
4. Off-air: record 12 kHz audio from the back end on a FreeDV frequency (14.236 MHz, 7.177 MHz) and run the
   harness. No published off-air recording was used: the upstream repositories hold only signals made by
   the transmitter program.
5. On the board: section 8.

## 6. CPU cost for one receiver

Measured under QEMU on the target's instruction set (`tools/qemu_freedv.sh`, `-icount shift=0`, `minstret`,
release build, the method of [S2_BENCH.md](S2_BENCH.md)); 2026-10-13, repeated the same day after the
changes of section 4 (LDPC step table, double arithmetic in a few places), which made weak-signal decoding
3 to 13 % dearer than with the exact phi function and the first tables. The whole receive path: 12 kHz in,
converter, modem, error correction, speech decoder, converter to 48 kHz.

| Case | Receiver | + 12 to 8 kHz | + 8 to 48 kHz | Total, M instr/s | Mcycles/s at IPC 0.7 | Share of the 800 MHz core |
|---|---|---|---|---|---|---|
| 700D, clean signal | 26.2 | 3.3 | 6.4 | 35.9 | 51 | 6.4 % |
| 700D, 2 dB SNR | 39.1 | 3.3 | 6.4 | 48.8 | 70 | 8.7 % |
| 700D, searching (noise only) | 35.0 | 3.3 | 6.4 | 44.7 | 64 | 8.0 % |
| 700E, clean signal | 29.9 | 3.3 | 6.4 | 39.6 | 57 | 7.1 % |
| 700E, 2 dB SNR | 42.4 | 3.3 | 6.4 | 52.2 | 75 | 9.3 % |
| 700E, searching (noise only) | 36.9 | 3.3 | 6.4 | 46.7 | 67 | 8.3 % |

Longest single step: 12.2 M instructions (a 700D frame whose error correction ran to its limit of 100
iterations; 9.9 M before the changes of section 4), 22 ms at IPC 0.7, once per 160 ms. A search step is
5.6 M (700D) or 3.0 M (700E). So the receiver can run in the cooperative loop as the FT8 decoder does, in
steps of at most 22 ms.

Against the budget ([CPU_BUDGET.md](CPU_BUDGET.md) section 6: normal use 311 Mcycles/s = 38.9 % with FT8 on
8 receivers, target 40 %): FreeDV on the operator's receiver costs 51 to 75 Mcycles/s. That receiver then
does not decode FT8 (30 Mcycles/s saved), so the net is +21 to +45 Mcycles/s: **41.5 to 44.5 % with FT8
still running on 7 other receivers, above the 40 % target by up to 4.5 points.** With the target chip's 4
receivers (FT8 on 3 others: 90 instead of 240 Mcycles/s) the total is 212 to 236 Mcycles/s, **26.5 to
29.5 %**. So it fits the target chip with room; on the 8-receiver variant with FT8 everywhere it does not
fit the normal-use target unless the FT8 cap is lowered.

Not optimised. Where the instructions go, and what could be cut if needed: the search correlates every
second sample position of a frame at three frequencies (halve by searching every fourth, as upstream does on
its small target); the 48 kHz converter is 24 taps per output (two stages would halve it); iterations could
be capped at 10 or 20 as upstream does on its small target (the decoder then no longer takes the same
decisions as the reference on weak signals, section 4).

Memory: receiver 37 KB of state, codec tables 82 KB of constants, no heap. Stack: building the receiver with
`Rx::init` takes 1.5 KB, one receive step 15.3 KB (700D and 700E, measured under QEMU with the benchmark:
the stack is painted before each step; section 9).

## 7. What the chip and the audio path lack

Nothing blocks FreeDV receive. Points for the integration:

| Point | State |
|---|---|
| Speech to the audio outputs | Through the audio engine's CPU ring (48 kHz stereo, 4,096 frames = 85 ms). One 700D frame decodes to 160 ms of speech at once, more than the ring holds: the firmware keeps a queue of its own (about 0.5 s) and tops the ring up. A deeper ring, or a low-water level that can be set, would make that simpler. Not required |
| The receiver's own audio while FreeDV plays | Today the only source of the outputs is the CPU ring, so the firmware plays the speech instead of the receiver audio. When the hardware mixer (A2) is built it needs a mute per receiver, or the operator hears the modem signal under the speech |
| Receiver set-up | Back end in SSB (upper sideband above 10 MHz, lower below, as FreeDV stations do), channel filter at least 600 to 2,400 Hz (the FT8 set-up 100 to 3,100 Hz is fine), 12 ksps ring. AGC may stay on: the modem is level independent (tested 0.05 to 1.0 of full scale) and the frame is 80 or 160 ms; a slow AGC is better than a fast one |
| Lower sideband | A FreeDV signal received on the wrong sideband is inverted in frequency and does not lock. The back end's sideband switch covers it; no change needed |
| Transmit (on hold) | The TX ring takes 48 kHz complex baseband. FreeDV gives 8 kHz real audio, so the firmware needs the 8 to 48 kHz converter and a single-sideband modulator (a Hilbert filter or the back end's SSB transmit path, if one is built) |

## 8. What is left

1. **Firmware integration (step 4 of the task description): done, see section 9.** (Original plan, kept:) A FreeDV mode in `tr-station`: receiver set-up
   as in section 7; `BackendRing::poll` blocks (128 samples at 12 ksps) into `Resampler::new_12k_to_8k`, into
   `RxStream::push`; the speech through `Resampler::new_8k_to_48k` into a queue that feeds
   `AudioOut::push` as stereo words. Mode select 700D / 700E and squelch level in a FreeDV panel in `tr-gui`
   in the FT8 screen's style: sync state (search, trial, locked), SNR, frequency offset, frames with errors,
   and a tuning aid (the offset in Hz is what the operator turns to zero). Console keys for the board
   without a mouse. The image must check the stack: one receive step keeps about 20 KB on the stack.
2. **FreeDV 1600** (section 1). Its sample signal is fetched already (`ve9qrp_1600.wav`).
3. **Text channel**: done, section 9 (`tr_freedv::varicode`).
4. **Transmit**: clipper and band-pass filter of the modulator (`ofdm_hilbert_clipper`, they set the
   signal's peak-to-average ratio and with it the power the amplifier gives), the single-sideband path, the
   speech input (owner decision: USB and Ethernet remote, both not built), text channel encoder.
5. Optional: the finer first frequency estimate (section 4), the cuts of section 6.
6. Comparison with the reference decoder: done (section 4). Fading channels not compared.
7. `docs/PLAN.md` row S9 still says "last (owner order)": to be updated by whoever merges this.

## 9. In the firmware (branch `fdvfw`, receive only)

**Nothing here has run on the board or against the HL2.** No transmit code path was added; the modulator
interface, the TX defaults and the HL2 command filter are untouched. Switching to FreeDV switches TX off first
(`Station::force_tx_off`) and nothing in FreeDV mode arms or keys anything.

| Part | Where |
|---|---|
| Receive chain: 12 kHz ring blocks, converter 2/3, `Rx`, converter x6, speech queue, audio ring top-up | `fw/tr-station/src/freedv.rs` (`FreedvRx`, `SpeechQueue`, `FdvOut`), `radio.rs` (`enter_freedv`, `leave_freedv`, `freedv_retune`, `Radio::service`) |
| Operator layer (band, tuning, 700D/700E, squelch), console keys, screen state | `fw/tr-station/src/fdvstation.rs` |
| Text channel: varicode code 1 (PSK31 table), 4 bits per 700D frame, 2 per 700E | `fw/tr-freedv/src/varicode.rs`, `FdvText` |
| Screen: `FdvView`, and `AppScreen1920x1080` holding the FT8 or the FreeDV view in one window | `fw/tr-gui/ui/fdv_*.slint`, `app_1920x1080.slint`, `src/fdv.rs`; screenshot `docs/img/fdv_1920x1080.png` |
| Image | `ft8fw` (name kept), both modes, `m` switches; QEMU twin `ft8fw_qemu` |

**Receiver set-up.** Same back-end set-up as FT8: bank receiver 0 at 48 ksps, SSB, 255-tap channel filter 100 to
3,100 Hz at 24 ksps, 12 ksps ring. The 0.7 to 2.3 kHz of 700E and the 1.0 to 2.0 kHz of 700D lie inside it, so
no new filter (S18) is needed. Lower sideband (80 m and 40 m) uses the same filter mirrored (-3,100 to -100 Hz,
`Radio::start_receive_sb`); a sideband change restarts the receiver. AGC stays on.

**Audio path.** The modem output (speech, or silence, or the received audio at 0.25 gain while not in sync and
squelch is off, as upstream does) goes up to 48 kHz into a queue of 32,768 samples (683 ms). The audio engine ring
holds 85 ms and a 700D frame is 160 ms, so the main loop (`Radio::service`) fills the ring to full from the queue
on every call. Playing starts when two frames of speech are queued (320 ms in 700D, 160 ms in 700E); then
a frame that is late by up to one frame length does not empty the ring. Counted and shown on the screen:
ring run-dry events (`FdvOut::underruns`), samples that did not fit the queue (`SpeechQueue::overruns`),
blocks the back end ring lost. The main loop must call `service` at least every 40 ms (ring 85 ms); a
full-screen redraw on the board that takes longer shows up as an underrun. The audio engine has no mixer: the
receiver own audio is "muted" by construction (the ring only ever holds what `Rx` outputs, speech while in sync);
`FreedvRx::analog_muted()` says when, for the hardware mixer (A2) when it exists. PT8211 volume 160 and
S/PDIF and I2S on are placeholders to be set from the board.

**Squelch.** On by default at SNR > -2 dB (the level the tests use), 1 dB steps from -10 to +20, and the
reference rule (unconfirmed sync only when the frame is error free).

**Waterfall.** With the zoom receiver in the chip: its 6 kHz span (3.125 Hz per column, 1.83 lines/s) centred
on the middle of the audio band (1,500 Hz above the dial frequency; below it for lower sideband), the window
showing the middle 1,172 of the 1,920 columns, so the signal sits in the centre of the window; the screen
marks its centre (1,500 Hz plus the modem offset estimate) next to the nominal 1,500 Hz. The zoom picture is in
RF order, so on lower sideband the audio scale runs backwards (the screen scale labels follow). Without the zoom:
the software waterfall of FT8 (0 to 3,000 Hz). The 3 kHz span would give twice the resolution at half the line
rate; one constant to change if wanted.

**Keys.** FT8 screen: `m` to FreeDV. FreeDV screen: `d` `e` 700D/700E, `q` squelch, `-` `+` level, `[` `]` band,
`<` `>` dial 100 Hz (tune until the frequency offset bar is centred), `m` back to FT8. The screen buttons do the same.
Bands (defaults, to be confirmed): 80 m 3.643 MHz LSB, 40 m 7.177 LSB, 20 m 14.236 USB, 17 m 18.118, 15 m 21.313,
10 m 28.330.

**Tests.**

| Test | What it shows |
|---|---|
| `tr-freedv` varicode (4) | every ASCII code round trips; known codes; text in frames of 1, 2, 4 and 7 bits; a bit error costs one character; a code that never ends is dropped |
| `tr-station/tests/freedv_path.rs` (6) | The FreeDV program sample signals (30 s of `ve9qrp_700d.wav` and `_700e.wav`) as 12 kHz blocks in the mock fabric ring, run through `Radio::service`, the audio ring played by an engine model: **the played speech equals the FreeDV crate own chain (converter, `RxStream`, converter) sample for sample**, ring underruns 0, queue overruns 0, blocks lost 0, left = right; the same with a 60 ms main loop; a 300 ms stall is counted as an underrun; squelch off with passthrough, lower sideband; a call sign sent in the text bits of generated 700D and 700E signals comes out (and into the screen state); register values of the receiver and the zoom window for both sidebands, TX stays off |
| `tr-station/tests/loopback.rs` | the same chain as the self-test function the QEMU twin runs, with the operator script through the station logic |
| `tr-gui/tests/fdv_screen.rs` | headless render of the screen and of the firmware window: waterfall rectangle pure key colour, indicators drawn, every control sends its event, FT8 and FreeDV views switch and FT8 comes back pixel for pixel |
| `fw/tr-app/qemu_p2.sh` | FT8 self-test still passes (CQ decoded at 1,500.0 Hz, 0.00 s) and the FreeDV part below |

**Under QEMU** (`qemu_p2.sh`, `-icount shift=0`, 2026-10-13): 8 s of 700D with call sign through ring, chain and audio
ring: 48 frames, locked, 0 frames without a codeword, text "VK5DGR", ring underruns 0, queue overruns 0, engine
starved 0, TX off; screen switched to the FreeDV view, 16 frames drawn, waterfall rectangle key colour, the two operator
squelch clicks reached the station. The signal is random payload bits, so the speech is noise-like; speech content
was checked on the host against the crate chain.

**CPU in the firmware chain** (`FreedvRx::feed_12k`, 6 s of signal, 800 MHz, IPC 0.7 as in section 6):

| Mode | Instructions per second of audio | Core | Longest block |
|---|---|---|---|
| 700D | 37.2 M | 6.6 % (4.7 % at IPC 1.0) | 6.9 M (8.7 ms) |
| 700E | 40.6 M | 7.2 % (5.1 % at IPC 1.0) | 3.6 M (4.5 ms) |

This is the bare chain (12k to 8k, modem, codec, 8k to 48k, text) and matches section 6 (35.8 and 39.7). Not
measured, because the mock fabric would dominate it: the ring block reads (94 blocks/s, 34 loads each) and the audio ring
writes (48,000 words/s plus one cache write-back per call); on the board these are plain loads and stores, a
few hundred thousand instructions per second. One block takes under 9 ms, so the loop can stay at 50 ms.

**Stack.** `Rx` is 37 KB. `Rx::new` built its three parts as locals and copied them: 37 KB of stack in the firmware image
(measured under QEMU: 37,072 bytes below the caller), and 74 KB in the benchmark image, where the copy and the locals
did not share space, more than the whole 64 KB of the board's stack (the DLM; the link script says `_hart_stack_size = 32K`,
but with one hart the stack pointer starts at the top of the DLM and nothing guards the bottom). The FT8 decoder already takes
about 60 KB of that (QEMU twin: 63.5 KB). Fixed 2026-10-13: `Rx::init(&mut MaybeUninit<Rx>, mode)` (also `RxStream::init`)
builds each part in the place it is to live (the receiver is zeroed there, the few non-zero fields written through
pointers, the FFT tables filled in place). Measured with `tools/qemu_freedv.sh` (the benchmark prints `STACK build` and
`rx_stack_bytes`): **building the receiver 74,064 bytes before, 1,472 bytes after; one receive step 15.3 KB** (both before
and after), so the receiver peaks at 15.3 KB instead of 37 KB (firmware) or 74 KB (benchmark). `Rx::new` and `RxStream::new`
remain for host code and tests and still pass the whole struct by value (38 KB in the benchmark image). **One line is left for
whoever owns `fw/tr-station/src/freedv.rs` (line 234) and the QEMU twin `fw/tr-app/src/bin/ft8fw_qemu.rs`: call
`Rx::init(&mut slot, mode.ofdm())` instead of `slot.write(Rx::new(mode.ofdm()))`** (not done here: those files belong to
another work package). Until then the firmware build still takes the 37 KB.

**What the board must confirm.** Everything of the chip (nothing ran there); that the audio engine runs from the HL2
clock (no rate matching is done; an unmatched clock shows as slow growth of the queue until an overrun is counted);
that the 85 ms ring is enough with the real loop and screen redraw time; PT8211 volume and which digital outputs to enable;
that the zoom window centres on a real 700D signal; that FT8 resumes cleanly after FreeDV (the receiver and its ring are
restarted, the chip FT8 front end is not touched, its first slot may be missed); the real calling frequencies and sidebands.

**What the chip or drivers lack.** Nothing blocks receive. A hardware mixer with a mute per receiver (A2) would make "mute the
analogue audio" a switch; today it is by construction. A deeper audio ring or a settable low-water level would let the main loop
call `service` less often.
