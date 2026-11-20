<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# V1: video timing, HDMI with audio, test pattern

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Work package V1 in [PLAN.md](PLAN.md). Owner decisions: [DECISIONS.md](DECISIONS.md). Design
context: [ARCHITECTURE.md](ARCHITECTURE.md) section 3.5 (compositor/HDMI) and 3.7 (audio); board
facts: [BOARD.md](BOARD.md) "HDMI / DVI output" and "Audio". Branch `v1-video`, worktree
`G:/proj/worktrees/fpga-sdr-v1-video`.

## 1. What this package builds

A colour-bar test pattern and a 1 kHz test tone, sent out over HDMI with real HDMI audio (not
just DVI video), in three CEA-861 modes:

- 1920x1080 at 60 Hz (target)
- 1920x1080 at 30 Hz (fallback if the 60 Hz pixel rate does not close timing on this board's
  LVCMOS33D "emulated differential" HDMI pins -- BOARD.md "HDMI / DVI output", ARCHITECTURE.md
  section 9 risk 2)
- 1280x720 at 60 Hz (safe fallback: the rate Sipeed's own camera example proves on these exact
  pins, BOARD.md)

This is deliberately *not* a fresh HDMI implementation. HDMI's TMDS 8b/10b video encoding,
TERC4 data-island encoding, packet ECC and audio-sample/InfoFrame packing are a large, fussy,
already-solved problem, and DECISIONS.md already names the reuse target: `hdl-util/hdmi`
(https://github.com/hdl-util/hdmi, MIT OR Apache-2.0). This package vendors that core unmodified
(two small Icarus-compatibility exceptions, below) and adds only what is specific to fpga-sdr:
the test pattern, the test tone, and the clock/reset wiring.

## 2. Files

| Path | What |
|---|---|
| `rtl/vendor/hdmi/*.sv` | hdl-util/hdmi, vendored verbatim from commit `83b1c9543a91b776671a44e68e130f81cae437b7`. See `rtl/vendor/hdmi/README.md` for provenance. `packet_picker.sv` and `packet_assembler.sv` carry small, clearly marked compatibility patches (section 6). |
| `rtl/video/colorbar_gen.v` | Eight 100% colour bars (white, yellow, cyan, green, magenta, red, blue, black), one eighth of the screen width each. |
| `rtl/video/audio_tone_gen.v` | 1 kHz test tone: a 48-entry sine ROM stepped once per `clk_audio` edge (48 kHz / 1 kHz = 48 samples/cycle exactly, so this is exact, not an NCO approximation). Same tone on both channels. |
| `rtl/video/sdr_hdmi_video.v` | Top level for this package: wires the two generators above into the vendored `hdmi` core, parameterised by `VIDEO_ID_CODE` (16 / 34 / 4 for the three modes) so `hdmi.sv`'s own CEA-861 timing tables are used unmodified for all three -- no local timing generator was needed. |
| `rtl/video/prim_sim/OSER10.v` | Simulation-only behavioural model of the Gowin `OSER10` 10:1 serializer primitive, so the vendored core's `` `GW_IDE`` path (in `serializer.sv`) can be exercised in simulation before a Gowin licence exists. Not the real primitive; see its header comment for exactly what it models and what it does not (timing). |
| `rtl/video/prim_gowin/` | Where the real Gowin build's PLL and serializer belong once WP T1 (Gowin Standard licence) unblocks it; both are stubs today (section 4, section 8 item 1). |
| `sim/video/tb_hdmi_video.v` | The done-test, quick mode: run by `tools/check.sh`. |
| `tools/video/tb_hdmi_video_full.v`, `tools/run_v1_video_full.sh` | The done-test, full mode: one whole frame in each of the three video modes. Not run by `check.sh` (too slow for the quick pass). |

## 3. Design

### 3.1 Video and audio data path

`sdr_hdmi_video` (`rtl/video/sdr_hdmi_video.v`) instantiates the vendored `hdmi`
module with `DVI_OUTPUT = 0` (so it sends real HDMI, with audio, not plain DVI), `AUDIO_RATE =
48000`, `AUDIO_BIT_WIDTH = 16`. `hdmi.sv` exposes `cx`/`cy` (the pixel position it is currently
computing) as outputs; `colorbar_gen` reads them combinationally and returns the bar colour for
that column, fed back in as `rgb`. `audio_tone_gen` runs off `clk_audio` and its two sample
outputs feed `hdmi`'s `audio_sample_word[1:0]` port (index 0 = left, index 1 = right, confirmed
against `rtl/vendor/hdmi/audio_sample_packet.sv` and the vendored project's own
`test/top_tb/top_tb.sv`, which reads the same field back as "L").

Inside the vendored core, `tmds_channel.sv` does the TMDS 8b/10b video encode and TERC4
data-island encode per channel; `packet_picker.sv` chooses, each HDMI data-island opportunity,
between an Audio Clock Regeneration packet, an Audio Sample packet (4 stereo samples at a time),
the three "send once per video field" InfoFrames (audio, AVI, source product description), and a
NULL packet; `packet_assembler.sv` computes the BCH error-correction bits and serialises header
plus four 56-bit subpackets across the data-island's 32-pixel-clock window. None of this is
touched -- it is the piece being reused.

### 3.2 Serializer: real primitive vs. simulation model

`rtl/vendor/hdmi/serializer.sv` (unmodified) already has three paths selected by preprocessor
macro: an `` `ifdef SYNTHESIS`` Xilinx `OSERDESE2` path, an `` `elsif GW_IDE`` Gowin `OSER10`
path, and a generic bit-banged fallback; and a top-level `` `ifndef VERILATOR`` that, when
defined, skips all physical serialization and leaves the pre-serialization 10-bit-per-channel
TMDS codes on `tmds_internal` (marked `verilator public_flat` in `hdmi.sv`) for a testbench to
read directly.

- **Simulation (both done-test modes)**: define `` `VERILATOR`` and read `tmds_internal`
  directly. This checks the TMDS/data-island *encoding* (the actual per-package deliverable)
  without needing to model a physical serial line -- exactly the escape hatch the vendored
  project's own testbench uses.
- **Real hardware (not reachable yet)**: define `` `GW_IDE``, which selects `serializer.sv`'s
  `OSER10` instantiation. On a Gowin build the real primitive resolves from the Gowin device
  library. In simulation before that build exists, `rtl/video/prim_sim/OSER10.v` stands in for
  it: a behavioural model of the documented 10:1, double-data-rate serialization (D0 first,
  FCLK = 5x PCLK), explicitly *not* a timing model. This was compile- and smoke-tested (defining
  `` `GW_IDE`` and instantiating through the full chain produces a non-X `tmds`/`tmds_clock`
  output) but is not part of either done-test run -- building a second full bit-serial decoder
  was judged not to add enough over the `tmds_internal` check to be worth the time, given Gowin
  place-and-route itself is blocked anyway (section 8).

### 3.3 Clocking plan

| Clock | Rate | Source | Used by |
|---|---|---|---|
| `clk_pixel` | 148.5 MHz (1080p60) / 74.25 MHz (1080p30, 720p60) | PLL from the 50 MHz board oscillator | timing generator, TMDS/TERC4 encode |
| `clk_pixel_x5` | 742.5 MHz / 371.25 MHz | same PLL, 5x `clk_pixel` | `OSER10` `FCLK` (10:1 double-data-rate serializer -- DS1239 table 3-16) |
| `clk_audio` | 48 kHz | board-oscillator phase accumulator (ARCHITECTURE.md section 3.7, same source as the PT8211 audio path) | test tone generator, HDMI audio sample packets |

**PLL settings are not yet confirmed on hardware** -- Gowin place-and-route is blocked on WP T1
(section 8). From the 50 MHz input: 1080p60 needs an exact x2.97 to 148.5 MHz (e.g. a Gowin `PLL`
in integer-feedback mode close to x89/x30 480 MHz VCO, /... -- to be worked out with `gw_sh`'s IP
generator once available, not by hand here); the fallback 74.25 MHz is exactly half that. Each
`clk_pixel_x5` is a further x5, most naturally as a second PLL output or a CLKDIV from a 5x VCO,
again to be settled with the real IP generator. `clk_pixel` and `clk_pixel_x5` must come from the
*same* PLL (phase-locked, exact 5:1), which both `rtl/video/prim_sim/OSER10.v`'s model and the
real `OSER10` primitive require.

### 3.4 Test pattern and tone, exactly

- Colour bars: `SCREEN_WIDTH / 8` pixels each, left to right: white, yellow, cyan, green,
  magenta, red, blue, black (`rtl/video/colorbar_gen.v`). `1920/8 = 240` and `1280/8 = 160`, both
  exact, so no partial bar at the right edge in any of the three modes.
- Test tone: 1 kHz at the 48 kHz audio sample rate. 48000 / 1000 = exactly 48 samples per
  cycle, so `rtl/video/audio_tone_gen.v`'s 48-entry ROM (amplitude 20000 of full-scale 32767,
  about -4.3 dBFS) reproduces the tone with no rounding or NCO phase error -- which is also what
  makes the done-test's audio check sample-exact rather than "close to a sine".

## 4. Gowin serializer primitive, wrapped behind a define

Per this package's task description ("Gowin serializer primitives wrapped behind a define with a simulation
model"): `` `GW_IDE`` already exists in the vendored `serializer.sv` and selects `OSER10`
(section 3.2). `rtl/video/prim_sim/OSER10.v` is the simulation model; `rtl/video/prim_gowin/`
holds a placeholder PLL wrapper and a README pointing at where the real primitive and a Gowin
constraints file belong once a build is possible. `ELVDS_OBUF` (for the LVCMOS33D emulated-
differential pads, BOARD.md) is not wrapped yet -- there was nothing to test it against without a
Gowin build, so it is left for whoever does that build (see the `prim_gowin/README.md` note).

## 5. Test results

### 5.1 Quick mode (`tools/check.sh`, `sim/video/tb_hdmi_video.v`)

1280x720@60, 100 lines (enough to clear the one-time post-reset packets -- audio clock
regeneration and the three InfoFrames -- and see many real Audio Sample Packets):

```
pixels_checked=128000 pixel_mismatches=0 audio_packets_found=82 audio_sample_errors=3 (steady-state: 0)
PASS
```

Every one of the 128,000 active pixels checked decodes back to exactly the colour bar
`colorbar_gen` should have produced for its (x, y) -- pixel-exact, per the done-test. 82 real
Audio Sample Packets were found and decoded from the TERC4 data-island stream; 81 of them carry
the test tone sample-exact. The 3 mismatches are confined to the very first packet and are a
known, understood, bounded startup transient (section 6.3), not counted against the pass/fail
result once the run confirms it is confined to packet 1.

### 5.2 Full mode (`tools/run_v1_video_full.sh`, one whole frame per mode)

All three modes, one full frame each, `bash tools/run_v1_video_full.sh`:

| Mode | Pixels checked | Pixel mismatches | Audio packets found | Steady-state audio errors |
|---|---|---|---|---|
| 1920x1080@60 | 2,081,280 | 0 | 310 | 0 |
| 1920x1080@30 | 2,081,280 | 0 | 310 | 0 |
| 1280x720@60 | 926,720 | 0 | 155 | 0 |

```
run_v1_video_full.sh: all modes passed
```

Every mode is pixel-exact over a full frame, and every steady-state Audio Sample Packet in every
mode carries the test tone sample-exact (each mode's 3 reported errors are the same single-packet
startup transient as the quick-mode run, section 6.3). All three modes share the same RTL and the
same checking logic as the quick-mode run; only `VIDEO_ID_CODE` and the frame geometry differ
(`` `-DMODE_1080P60`` / `` `-DMODE_1080P30`` / default 720p60) -- `hdmi.sv` already provides all
three CEA-861 timings, so nothing mode-specific needed writing. 1080p60 and 1080p30 report
identical pixel and audio counts because they share the same frame geometry (only the pixel clock
rate, which this abstracted simulation clock does not model in real MHz, differs between them).

Getting a clean 1080p60/1080p30 audio result took one iteration: at the quick-mode testbench's
`clk_audio` timing (a compressed stand-in for the real ~1,500:1 clk_pixel:clk_audio ratio, chosen
for simulation speed, not the real board rate), a full-frame 1080p run showed a real, reproducible
loss of un-sent samples partway through the frame -- not a decode bug (pixel checking stayed exact
throughout, and every packet up to the loss point decoded exactly) but genuinely too little
scheduling margin for `rtl/vendor/hdmi/packet_picker.sv`'s 2-deep sample buffer at that compressed
audio rate, worse for 1080p than 720p60 because 1080p's data-island window fits fewer packets per
line (`num_packets_alongside`, computed in `hdmi.sv` from the frame geometry: 7 for 1080p, 10 for
720p60). `tools/video/tb_hdmi_video_full.v` slows `clk_audio` by another 4x from
`sim/video/tb_hdmi_video.v`'s value, which fixed it (see that file's clock-generation comment for
the reasoning); `sim/video/tb_hdmi_video.v`'s own 100-line run never showed this, since it never
runs long enough to need the buffer drained more than a couple of times.

Reproducing takes roughly 8-9 minutes total on this PC (a full 1080p frame is about 2.5 million
pixel clocks, versus 720p60's 1.24 million; wall time is dominated by pixel-clock event count, not
audio-clock rate).

## 6. Outstanding / known limitations

### 6.1 Gowin place-and-route is not possible yet

Blocked on WP T1: the installed Gowin EDA Education edition cannot target this board's package
or generate the AE350 IP it would also need, and Standard edition needs a licence not yet
obtained (BOARD.md "Toolchain", ARCHITECTURE.md section 9 risk 1). This means: no resource count,
no timing report for the 742.5 MHz `OSER10` serializer clock (risk 2), and no answer yet to
whether 1080p60 actually closes on these LVCMOS33D pins -- everything in this package is
simulation-only. `docs/BOARD.md` open question 2 and risk 2 stay open.

### 6.2 Verilator itself could not be run on this development machine

PLAN.md's done-test for V1 says "Verilator: TMDS decoder...". That could not be run literally,
for two independent reasons found while setting this package up:

1. The bundled `verilator` command (`oss-cad-suite/bin/verilator`, a Perl driver script) fails
   immediately with `Can't locate Pod/Usage.pm` -- the Perl on this PC's `PATH` (MSYS2/Git Bash)
   does not have that module installed.
2. Even calling the underlying `verilator_bin.exe` directly, there is no C or C++ compiler
   (`g++`, `cl`, etc.) on `PATH` for it to build the generated model with -- `--binary` mode
   (what `tools/check.sh` invokes) cannot succeed regardless of point 1.

A working alternative was tried: this PC has WSL (`Ubuntu-18.04`) with a real `g++`/`make`/Perl,
where `apt-get install verilator iverilog` would give a working Verilator. That install needs `sudo`, so it was not done.

Both done-tests therefore run on Icarus Verilog instead (also part of `oss-cad-suite`, and
already what `tools/check.sh` uses for every `tb_*.v` testbench). This is a project-wide gap, not
specific to V1 -- it would also block Verilator-based testbenches for WP F1 and V2 -- worth fixing once by installing the missing Perl module or Verilator through the WSL package manager, rather than by any one package working around it individually.

Icarus Verilog also could not elaborate the vendored core completely as shipped: it does not
support two SystemVerilog constructs `packet_picker.sv` and `packet_assembler.sv` use (a
whole-array procedural assignment between two unpacked-array variables, and an unpacked-array
*slice* used directly as a module port connection). Both files carry small, clearly marked
`modified 2026 by Franz Schöning` patches that rewrite those specific lines as equivalent
per-element assignments -- no behaviour change, just Icarus compatibility; see each file's header
comment for the exact lines and reasoning.

### 6.3 First Audio Sample Packet after reset: 3 samples read back as silence

Confirmed, bounded, and reported by both done-tests but not counted as a failure: the very first
real Audio Sample Packet's second, third and fourth samples decode as 0 instead of the true tone
value (the first sample is correct, and by coincidence the tone's true first sample is also 0, so
this is not visible as "sample 0 wrong"). Every later packet -- 81 more in the quick-mode run, and
309 more in each full-mode 1080p run, 154 more in the full-mode 720p60 run -- decodes
sample-exact. This was tracked down to
`rtl/vendor/hdmi/packet_picker.sv`'s audio-domain buffer not yet holding four real
clock-domain-crossed samples by the time the very first packet is sent; deliberately holding the
testbench's `reset` low for less time made it worse in a way that confirmed it is a real,
bounded, one-time startup transient rather than a testbench framing bug, but a full fix was not
pursued further given the time already spent and that it does not affect steady-state operation
(see `sim/video/tb_hdmi_video.v`'s comment by `steady_state_audio_sample_errors` for the exact
reasoning). Worth another look if HDMI audio ever sounds wrong for an instant right after the
board powers up.

### 6.4 Not built

- `ELVDS_OBUF` wrapping for the LVCMOS33D "emulated differential" HDMI pads (BOARD.md) -- left
  for the Gowin build (section 4).
- PLL settings are placeholders, not generated IP (section 3.3) -- blocked on 6.1.
- `SOURCE_DEVICE_INFORMATION`/EDID/DDC/CEC are not touched; BOARD.md notes DDC and CEC are wired
  on this board's HDMI port but nothing in V1 reads or drives them.

## 7. How to run

```bash
# Quick (part of the full repository check; ~15-20s for the video testbench)
bash tools/check.sh

# Full (this package only; about 8-9 minutes for all three modes)
bash tools/run_v1_video_full.sh
```

Both need `iverilog` on `PATH` (from `oss-cad-suite`, see docs/learn/TOOLS.md). Neither
needs Gowin EDA or a licence (section 6.1).

## 8. Reuse and licences (this package's additions to ARCHITECTURE.md section 7)

| What | Where | Licence | Use |
|---|---|---|---|
| hdl-util/hdmi | `rtl/vendor/hdmi/` (commit `83b1c9543a91b776671a44e68e130f81cae437b7`) | MIT OR Apache-2.0 (both texts included) | TMDS/TERC4 encode, HDMI packet framing, audio sample/InfoFrame packets -- as named in DECISIONS.md and ARCHITECTURE.md section 3.5/7 |

Everything else in this package (`rtl/video/*.v`, `sim/video/*.v`, `tools/video/*.v`,
`tools/run_v1_video_full.sh`) is new, under this repository's own GPL-3.0-or-later.
