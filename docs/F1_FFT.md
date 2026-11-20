<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# F1: full-band spectrum FFT

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Work package F1 in [PLAN.md](PLAN.md); system context in [ARCHITECTURE.md](ARCHITECTURE.md) section 3.3.

## Decision

**Our own streaming FFT**, `rtl/fft/fft_r22sdf.v`: radix-2^2 single-path delay feedback (R2^2SDF),
decimation in frequency, full-precision data path, 18-bit twiddles. Not ZipCPU `dblclockfft`, not the
Gowin FFT IP.

Why:

1. **It keeps up with the stream and nothing else checked does out of the box.** The requirement is one
   sample per `adc_valid` (76.8 Msps average, bursts on consecutive 150 MHz cycles), every sample in a
   transform, 4,687.5 transforms per second. The Gowin IP is a load / compute / unload block core; its
   documented architecture cannot take a continuous stream. `dblclockfft` can, but see 2 and 3.
2. **It is the smallest.** 24 DSP multipliers and about 0.52 Mbit of block RAM (35 of 340 BSRAM blocks)
   for 16,384 points. `dblclockfft` needs about 3.2 Mbit for the same size (six times more: an input and
   an output buffer plus a full, non-symmetric twiddle table in every stage, and a double-buffered bit
   reversal) and 36 multipliers, many wider than one DSP.
3. **It is the most accurate at that size.** Nothing is rounded except in the six twiddle multipliers,
   so the FFT's own error stays 105 to 114 dB below a tone and 38 dB below the ADC noise floor. The
   measured spurious-free dynamic range (SFDR) equals that of a double-precision FFT of the same 12-bit
   samples: the ADC, not the FFT, sets it. `dblclockfft` in its default configuration adds about 10 dB
   more error (measured at 2,048 points, below).
4. It is plain Verilog, simulates in iverilog, passes Verilator lint (only style warnings about
   power-up values), and has no licence question.

## Options compared

| | Own R2^2SDF (chosen) | ZipCPU dblclockfft | Gowin FFT IP |
|---|---|---|---|
| What it is | 7 radix-2^2 stage pairs, one delay-feedback memory per stage, 6 twiddle multipliers | generator (C++) writing radix-2 pipelined Verilog, one stage per bit | encrypted generated core, IPUG503 v1.4E |
| Continuous stream, 1 sample per valid, gaps allowed | **yes** (tested: 51 % bursty and every cycle) | yes (`i_ce`) | **no** for the documented "Low Resource" architecture: `start`, load, `busy`, unload. *Estimate* for one butterfly: about 147,000 cycles per 16k transform = about 1,000 transforms/s at 150 MHz, one in five frames. The 1.9.11.03 install also ships an undocumented "High Performance" variant (`data/5a_high`); its throughput is unknown |
| Size limit | any power of two | any | 8 to 16,384 points (we need exactly 16,384) |
| Real input | yes: first delay line stores the real part only | no (README: real mode not started) | no |
| Accuracy, 12-bit tone, windowed | SFDR 90.8 to 97.6 dBc over 25 non-coherent tones, equal to a float FFT of the same samples within 0.7 dB; FFT error 105 to 114 dB below the tone (bit-true model sweep) | at 2,048 points, default growth (15 in, 21 out): error 93 to 95 dB below the tone outside its main lobe, signal to FFT noise 76 dB (ours at 2,048 points: 103.5 to 106 dB, 85.6 dB). 16k adds 3 more rounding stages | not measurable (encrypted, no licence yet) |
| Accuracy, noise input | FFT noise 38 dB below the input noise floor (sigma 4 LSB) | 26 dB below (2,048 points) | unknown |
| DSP | **24** multipliers, all <= 27 x 18 (one DSP each) | 36 multipliers (3 per stage, 12 stages); twiddles grow to 19-26 bits, wider than the 18-bit port | 2 MULTADDALU18X18 at 1,024 points (GW2A) |
| Block RAM, 16k | **about 0.52 Mbit**: 35 BSRAM blocks (yosys) | **about 3.2 Mbit** (1.7 without bit reversal), from its per-stage memories; 31 blocks already at 2,048 points (yosys) | 4 DP BSRAM at 1,024 points; 16k not documented |
| Logic, 16k | about 3,300 LUT + 2,900 carry-chain bits + 5,300 registers (yosys, multipliers excluded) | at 2,048 points with logic multipliers (`-p 0`): 16,700 LUT + 16,600 carry bits + 30,900 registers (yosys) | 656 LUT, 210 registers at 1,024 points |
| Simulates in iverilog / Verilator without encrypted models | yes / yes | yes (checked: the pre-generated 2,048-point core runs in iverilog 12) / yes (its own test bench is Verilator) | **no**: `pragma protect` with Gowin's key; only Gowin's tools decrypt it |
| Licence | GPL-3.0-or-later (ours) | LGPL-3.0-or-later: compatible with GPL-3.0-or-later | Gowin proprietary; generated files cannot be committed (A 7) |
| Source of the numbers | measured: testbenches + yosys `synth_gowin -family gw5a` | measured at 2,048 points (iverilog, yosys); 16k from its architecture | Gowin's user guide IPUG503-1.4E and the installed IP files |

Notes on the comparison:

- The `dblclockfft` generator was not built here (no C++ compiler on this PC). The 2,048-point core in
  its repository was run with coefficient files written from the generator's formula (`gen_coeffs` in
  `sw/fftlib.cpp`), fed the same windowed 12-bit tones and noise as our model. Its accuracy can be
  raised with more internal bits (`-x`, `-m`), which widens every memory and multiplier further.
- Gowin's numbers are the vendor's own (1,024 points on GW2A-55). The IP could only be generated and
  measured with Gowin EDA Standard, which is not licensed yet (PLAN T1).

## Measured results (done-test)

`sim/fft/tb_fft_r22sdf.v`: 16,384 points, real input, 15-bit input (12-bit ADC sample times a 4-term
Blackman-Harris window, 3 fraction bits), 29-bit output. Six frames as one continuous stream, the first
three with `in_valid` high on a random 51 % of cycles, the rest every cycle. Each output frame is compared
bin by bin with a double-precision FFT of the same integer samples computed in the testbench.

| Test | Result | Pass limit |
|---|---|---|
| Tone 7.103 MHz (bin 1,515.3), -1 dBFS, bursty | peak in bin **1,515**; **SFDR 93.3 dBc**; FFT error outside the main lobe -112.6 dBc | right bin, SFDR >= 85 dBc, error <= -100 dBc |
| Tone 29.999 MHz (bin 6,399.71), -1 dBFS, every cycle | peak in bin **6,400**; **SFDR 94.4 dBc**; FFT error -106.9 dBc | same |
| Gaussian noise, sigma 4 LSB | mean bin power 66.32 dB (theory 66.36 dB); **FFT noise 38.1 dB below the input noise floor**; Parseval (output power = N x input power) within 0.002 dB | >= 30 dB below; Parseval within 0.01 dB |
| Full-scale DC (-2,048 on every sample) | output -2^28, exactly the largest 29-bit value; no overflow | error <= 1e-4 of peak |
| Full-scale tone on bin 4,096 | peak bin 4,096, no overflow | same |
| Gain | -0.0004 dB against the float FFT (twiddles scaled by (2^17 - 1) / 2^17, six times) | reported |
| Latency | 63 clock cycles from the last input sample of a frame to its first output word (39 before the timing work in gowin/reports/README.md: 3 more per twiddle multiplier, then 1 more in its second pass) | reported |

`sim/fft/tb_fft_r22sdf_cplx.v` covers what the full-band test does not: complex input (the zoom FFT of
PLAN F3: 4,096 points, 17-bit input) and an odd size (2,048 points, ends in a single radix-2 stage), with
random full-scale complex samples and a negative-frequency tone. Signal to FFT error 88.3 to 88.6 dB,
tone in the right bin, no overflow.

The RTL output is **bit-exact** with the Python model `tools/fft_r22sdf.py` (all 5 x 16,384 bins).
Model sweep over 27 tones (`python tools/fft_r22sdf.py sweep`), same configuration:

- 25 non-coherent tones: SFDR 90.8 to 97.6 dBc; a double-precision FFT of the same samples gives the same
  within 0.7 dB. The SFDR limit is the 12-bit quantization of the input, not the FFT.
- a tone exactly on a bin (1,024.0) gives 74.7 dBc, float FFT 74.6 dBc: an exactly periodic 12-bit
  signal puts its quantization error into harmonics. Real ADC noise dithers this away.
- FFT error outside the main lobe: -105.4 dBc worst, -111 dBc typical.
- noise at sigma 0.5 LSB (quantization level): FFT noise still 23 dB below the input floor.

## Resources (estimate from yosys, not place-and-route)

`sim/fft/yosys_gw5a.ys`: yosys 0.69 `synth_gowin -family gw5a`, full-band configuration (LOG_N 14, IW 15,
real input). yosys does not map multipliers to GW5A DSP blocks, so `fft_mul` is a black box: 24
instances, each at most 27 x 18 bits = one DSP multiplier.

| Resource | Used | GW5AST-138 has | Share |
|---|---|---|---|
| DSP multipliers 27 x 18 | 24 | 298 DSP blocks | 8 % |
| Block RAM (18 kbit primitives: 8 DPB, 15 DPX9B, 6 SDPX9B, 6 SPX9) | 35 | 340 | 10 % |
| LUT RAM (RAM16SDP4) | 48 | | |
| LUT (LUT1-LUT4) + MUX2 | 3,257 + 167 | 138,240 | about 4.4 % with the carry bits |
| Carry-chain adder bits (ALU) | 2,865 | | |
| Registers | 5,304 | 138,240 | 3.8 % |

The earlier *estimate* in ARCHITECTURE 3.3 (56 DSP, 36 BSRAM halves) is replaced by these numbers.
Timing at 150 MHz (Gowin place-and-route, `gowin/reports/fft_r22sdf/`): 91.2 MHz before the
timing work, 140.4 after its first pass, **151.7 MHz** after the second. The second pass closed the
butterfly's one-sample loop (delay line -> add -> select -> the same delay line): `fft_delay.v`
now registers its input (and, for the RAM delay lines, its output a second time), keeping the
delay at L samples, so the loop runs flip-flop to flip-flop; the butterfly's phase and -j flags
are in four copies each; and the twiddle multiplier's octant mapping takes two clocks and its
saturation flags come from the unrounded sums (latency 8 clocks instead of 7). Outputs are
unchanged sample for sample (checked against the previous RTL with random bursty input).

## How it works

- Stage pair p (p = 0 .. 6 for 16k) works on frames of Np = N / 4^p samples. BF2I: delay Np/2; the
  first half of each frame goes into the delay line, the second half meets its partner, the sum leaves,
  the difference goes into the line and leaves during the next half. BF2II: delay Np/4, same, and the
  input is multiplied by -j (swap and negate, no multiplier) in the last quarter. Then one complex
  multiply by W_Np^(n3 (k1 + 2 k2)).
- Every stage counts samples, not cycles, so gaps in `in_valid` only pause it. Each stage's counter
  starts at minus its sample latency, so no start signal travels down the pipeline.
- Data width grows one bit per stage (15 in, 29 out); the magnitude of any real input at most
  2^(IW-1) cannot overflow. The multiplier input is at most 27 bits (after stage 12).
- Twiddle ROMs hold only the first octant (cos, sin; 2,048 x 36 bits for Np = 16,384, 512 for 4,096,
  then LUT-sized); the other octants and 45 degrees come from symmetry. Files
  `rtl/fft/tw/fft_tw18_lNN.hex`, written by `python tools/fft_r22sdf.py gen-tw`.
- Delay lines of 32 samples or fewer are registers; longer ones are simple dual-port RAM whose read is
  issued one cycle early, so the word is ready whenever the next sample arrives.

## Interface for F2 and F3

| Port | Meaning |
|---|---|
| `in_valid`, `in_re[IW-1:0]`, `in_im` | one sample per high cycle; `in_im` ignored when `REAL_IN = 1`. Frames are consecutive blocks of N valid samples counted from reset |
| `out_valid` | one word per input sample, a fixed number of cycles later. The first N - 1 after reset are suppressed; then output frame f is the transform of input frame f. Frame f comes out while frame f + 1 goes in (the last word of a frame needs the next input) |
| `out_index` | position in the frame, 0 .. N - 1; `out_first` marks 0 |
| `out_bin` | frequency bin of the word = bit-reverse of `out_index` (output order is bit-reversed) |
| `out_re`, `out_im` | IW + LOG_N bits, unscaled DFT: sum of x[n] e^(-j 2 pi k n / N) |

For F2 (full band, real input): bins 8,192 and up are mirror images; they are the words with odd
`out_index`, so F2 can drop them. There is no natural-order reorder buffer in F1 on purpose: F2 can
compute power first and reorder (or address its per-bin memory by `out_bin`) with narrower words than
the 58-bit complex output. The window (8,192-entry symmetric ROM) belongs to F2 and must deliver 15-bit
samples (12 bits times the window, 3 fraction bits).

For F3 (zoom, complex): `LOG_N = 12`, `REAL_IN = 0`, `IW` up to 17 (multiplier input stays <= 27 bits);
keep the input magnitude at most 2^(IW-1).

## How to run

From the repository root:

```sh
bash tools/check.sh                                            # runs both testbenches (about 1 minute)
iverilog -g2012 -o /tmp/fft.vvp sim/fft/tb_fft_r22sdf.v && vvp /tmp/fft.vvp
vvp /tmp/fft.vvp +dump && python tools/fft_r22sdf.py compare fft_dump.txt   # bit-exact check
python tools/fft_r22sdf.py sweep            # 27-tone and noise accuracy sweep of the model (numpy)
python tools/fft_r22sdf.py gen-tw           # rewrite the twiddle ROM files
yosys -s sim/fft/yosys_gw5a.ys | tail -40   # resource estimate (about 4 minutes)
```

`TW_DIR` (default `rtl/fft/tw/`) is the ROM file directory relative to where the simulator or
synthesiser runs; the Gowin project must set it to match its own working directory.

## Open

- Timing at 150 MHz and real resource numbers need Gowin place-and-route (PLAN T1, then R3 style).
- `fft_mul` is where a Gowin DSP wrapper goes if GowinSynthesis does not infer the 27 x 18 mode by
  itself (PLAN R3 does the same for the receiver bank).
- GowinSynthesis support for `$readmemh` ROM initialisation with a relative path is assumed, not tried.
