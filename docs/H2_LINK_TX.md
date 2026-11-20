<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# H2: HL2 link transmit path

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Work package H2 (`docs/PLAN.md`), branch `h2h3` (bundled with H3). Covers ARCHITECTURE.md section 3.1's transmit side (TX sample
framer, one-sample-per-`adc_valid` rate lock and fill trim, CPU transmit queue, MAC TX, RGMII TX)
and section 3.6 points 1-5 (framing, rate, safety). Receive (H1) is unchanged; this WP only adds to
it (two new output fields on `eth_frame_rx.v`/`hl2_link_rx_top.v`, described below).

## 1. Design

**2026-10-21 (docs/HL2_SFP.md):** the HL2 is on SFP0; the frames leave through gmii_tx_out.v to the lane's PCS instead of rgmii_tx_phy.v, clk_tx is the lane's transmit clock.


### 1.1 Block diagram and clock domains

```
tx_chain.v (WP X1, not owned here) --pace_out--> tx_rate_lock.v --in_sample/in_valid-->
    tx_sample_framer.v --clk_dsp->clk_tx--> [arbiter] <-- cpu_tx_queue.v
                                                |
                                          crc32_append.v --> rgmii_tx_phy.v --> RGMII TX pins
```

- `clk_dsp` (120 MHz): sample intake, byte packing, the safety mux.
- `clk_tx` (125 MHz, WP H3's PLL): frame assembly, arbitration, the RGMII TX pins.
- The chip top level (WP P1) is what instantiates `tx_chain.v` and connects its `pace`/`out_data`/
  `out_valid` to this WP's `pace_out`/`in_sample`/`in_valid` -- see 1.2's note on scope.

### 1.2 Scope: tx_chain.v stays a separate module, on purpose

ARCHITECTURE.md 3.6 lists "the chain advances one output sample per `adc_valid`" and the rate
lock/fill trim as this WP's job, and `tx_chain.v`'s own header (WP X1) says the same from its side:
wiring `pace` and consuming `out_data`/`out_valid` is H2's job, not X1's. This WP does **not**
instantiate `tx_chain.v` itself: `hl2_link_tx_top.v` exposes a plain `pace_out` output and
`in_sample`/`in_valid` inputs, with the same contract `tx_chain.v` already has (`in_valid` must
equal `pace_out`, `in_sample` the 12-bit value tx_chain would produce that cycle) -- the chip top
level (WP P1) wires the two together. `sim/h2_link_tx/tb_h2_link_tx.v` drives this WP end to end
with a substitute producer instead: a free-running (sample index) mod 4096 counter, advanced once
per `pace_out` pulse and looped straight back as `in_valid`. This is deliberate, not a shortcut:

- WP X1 already has its own done-test proving the DSP chain correct (two-tone spurious-free
  range, output zeroed within one sample of disable/trip); re-deriving that here would duplicate
  it, not add coverage.
- What this WP owns -- the framer, the safety mux, the header/checksum/CRC content, the byte-pair
  FIFO crossing, the arbiter, and the rate lock -- does not care what the 12-bit values *mean*,
  only that exactly one arrives per accepted pace pulse. A synthetic counter exercises every one of
  those mechanisms exactly as a real baseband signal would, and gives the loopback test in 4.1 an
  independent, checkable value at the far end (PLAN.md's own done-test wording, "every sample
  matching") that a real waveform would not.
- A follow-up integration check (WP P1, once the chip top level exists) should still confirm
  `tx_chain.v` wired to this WP's real `pace_out` produces sane RF baseband end-to-end; that is a
  wiring proof, not a re-test of either module's own logic.

### 1.3 Files (`rtl/hl2link/`)

| File | Role |
|---|---|
| `tx_sample_framer.v` | Sample intake and packing (`clk_dsp`), frame assembly and byte-serial emission (`clk_tx`). See 1.4. |
| `tx_rate_lock.v` | Generates `pace_out` from H1's `samp_out_valid`, with the fill-trim correction. See 1.5. |
| `cpu_tx_queue.v` | 4 KB firmware-queued frame buffer, lower priority than the sample framer. See 1.6. |
| `crc32_append.v` | Appends the Ethernet FCS to whichever producer the arbiter grants. See 1.7. |
| `rgmii_tx_phy.v` | Preamble/SFD/IFG framing and the byte-to-DDR-nibble split, mirroring `rgmii_rx_phy.v`'s structure for the transmit direction. |
| `gowin_oddr5.v` | The one new Gowin-specific primitive this WP needs (RGMII TX DDR output, 5 bits). See 1.8. |
| `hl2_link_tx_top.v` | Ties the above together plus the arbiter. See 1.9. |
| `rx_tx_fill_bridge.v` | Carries H1's newly-parsed TX-sink-fill field to this WP's clock domain. See 1.10. |

### 1.4 Sample framer (`tx_sample_framer.v`)

Packs 12-bit samples 2-at-a-time into PROTOCOL.md 5.2's 3-byte format, crosses to `clk_tx` as
whole pairs (24 bits) rather than individual bytes (one write per accepted pair, not one per
`clk_dsp` cycle at the input's full burst rate, and no separate byte-grouping needed on the read
side -- see the file's own header), and assembles one PROTOCOL.md 6.2 frame (magic 0x5A, version
1, sequence, 48-bit TX index, N=5,970 samples) every N accepted samples. N=5,970 is exactly the
figure ARCHITECTURE.md 3.1's own line-budget section gives for the TX direction: UDP payload
16 + 3(cid)5,970/2 = 8,971 B fits a 9,000 B jumbo MTU.

The safety mux (ARCHITECTURE.md 3.6 point 5) substitutes zero for the real sample, at the point
samples are packed, whenever `cfg_tx_enable` is low or `cfg_trip` is high -- frames keep flowing
(the far end's FIFO fill mechanism stays alive), they simply carry silence, "at once" (within the
one sample the mux sits in front of).

A credit counter (0-3) crosses "one frame's worth of pairs is now in the byte FIFO" from `clk_dsp`
to `clk_tx` as a single toggle-handshake bit (`cdc_word.v`, W=1) -- not the pair data itself, which
the FIFO itself already carries. The frame FSM on the `clk_tx` side only starts sending once
credit is nonzero, guaranteeing (given the FIFO's own depth margin, `FIFO_AW`) that the bytes it is
about to pop already exist.

### 1.5 Rate lock (`tx_rate_lock.v`)

See the file's own header for the full derivation; in short:

- `pace_out = rx_adc_valid` (H1's `samp_out_valid`) by default, which already rate-locks TX to RX
  1:1 since both trace back to the same physical clock one hop apart.
- A trim closes the residual start-up deficit (fill starts at 0, target 12,000): a proportional
  controller re-evaluated fresh every received fill update (not accumulated -- an accumulated
  version wound up like a classic integrator, see the file's own account of that bug), rate-limited
  to `COOLDOWN` clk_dsp cycles between corrections. The rate limit matters more than the gain: the
  link's own spare bit-rate margin (PROTOCOL.md 5.7's line budget), not clk_dsp's raw cycle count,
  is what actually bounds how fast a deficit can close without dropping samples -- a first version
  ignored this and corrected on every idle clk_dsp cycle (150 M/s of theoretical headroom against
  about 700 kbit/s of *real* spare link capacity), which silently dropped exactly as many samples
  as it "gained", caught by the echoed test pattern drifting from its expected value one sample per
  correction once the trim engaged.

### 1.6 CPU transmit queue (`cpu_tx_queue.v`)

A single 4 KB buffer (ARCHITECTURE.md 3.1: "CPU transmit queue (BSRAM, 4 KB)"), one frame in
flight at a time: firmware writes a complete frame (destination MAC through the last payload byte,
not the FCS) through a write-only port, then pulses `send_len_wr`; hardware drains it once the
arbiter grants it the wire, always after the sample framer's own current or pending frame. A
deeper multi-frame ring is a possible later enhancement (ARCHITECTURE.md's own traffic estimate for
this path is well under 1 Mbit/s, control-plane only), not needed by any done-test today. Same
one-write-port/one-read-port memory shape H1's `cpu_rx_ring.v` needed for BSRAM inference
(ARCHITECTURE.md 3.14 C11) -- see that module and H1_LINK_RX.md 1.6 for the lesson this reuses.

Not exercised by `tb_h2_link_tx.v` (which ties `cq_wr_en` low throughout, since PLAN.md's H2
done-test is specifically about the sample framer). Its own dedicated unit test,
`sim/h2_link_tx/tb_cpu_tx_queue.v`, writes two different-length frames back to back plus a 1-byte
frame and checks every byte comes out exact. It found a real bug on its first run, not a test
artefact: the drain FSM's own termination check (`byte_cnt+1==frm_len`) ended every frame one
`clk_tx` cycle early, because `mem_q` (and so `tx_data`) always trails the drain address `dp` by
one cycle (the same registered-read latency `raw_frame_buffer.v` and `cpu_rx_ring.v` already
account for elsewhere) -- every frame this module ever sent would have been missing its last
payload byte, silently replaced by whatever byte follows it in memory once the FCS is appended
after it. Fixed to check `byte_cnt==frm_len` instead (see the module's own comment for the
interval-counting derivation); `tb_cpu_tx_queue.v` now passes exactly.

### 1.7 FCS append (`crc32_append.v`)

Neither producer computes a CRC; this shared block appends it to whichever one the arbiter grants,
so `rgmii_tx_phy.v` always sees one gapless content-then-FCS byte stream.

**FCS byte order**, derived from H1's own receive-side check rather than assumed: `eth_frame_rx.v`
compares a received frame's trailing four bytes, reassembled with the *last-arrived* byte as the
MSB, against `~crc_run` (the running CRC state, not yet complemented). Working that relation
backwards for the transmit side: the four bytes must go out **least-significant byte of
`~crc_run` first** -- also the conventional real-world Ethernet FCS wire order. Verified in this
WP's own testbench by feeding a frame this module built for the far end straight back into
`eth_frame_rx.v`'s own CRC-32 checker (a byte-for-byte round trip, not just an assertion that the
formula looks right).

**FCS defect found and fixed 2026-10-17 (branch `final`).** Until then the first byte of every frame was left out of the
FCS: `crc32_append` cleared `crc32_eth` in the clock of the first content byte, and `crc32_eth` gives `clear`
priority over `enable`, so the FCS on the wire was the CRC-32 of bytes 1 to N-1. Measured on a frame of our transmitter
in `sim/h2_link_tx/tb_h2_link_tx.v` (9,017 bytes with FCS; destination MAC 02:00:00:00:00:02 first): FCS on the wire
`15 69 7f b4`; Python `zlib.crc32` of the 9,013 bytes before it `0x6cbda053` (wire bytes `53 a0 bd 6c`); of the same
bytes without the first one `0xb47f6915` (wire bytes `15 69 7f b4`) = what was sent. All 5 frames of a 500 us run
were wrong. **The earlier "0 errors" of the 50 ms echo run did not cover the FCS:** the HL2 receive chain vendored in
`sim/h2_link_tx/hl2` (`mac_recv`, `ip_recv`, `udp_recv`) never looks at the FCS ("ignore the ethernet crc that
follows"), and the echo comes back through the HL2's own sender. The real HL2 gateware reads the same way, so the
radio would probably have accepted these frames anyway; a switch, a router or a PC network card would have dropped
every one. Fix: `crc_clear = !in_enable && !prev_in_enable` (between frames, never on a content byte), as in
`rtl/n1/fcs_append.v`. The bench now has an FCS monitor on the far end's receive byte stream with its own bit-serial
CRC-32; it fails on the old module and passes on the fixed one (`-DSIM_US=200 -DSETTLE_US=300` is enough for it; the
fill-band check needs the default settle time). The receive side (`eth_frame_rx.v`) was right the other way round:
it clears at the start of the frame (four bytes ahead of the delayed data it checks), uses the standard check
(`~crc == last four bytes, last byte = MSB`), and counted exactly the one injected bad frame and none of the many
good ones coming from the HL2's own sender in `sim/h1_link_rx/tb_h1_link_rx.v`.

### 1.8 RGMII TX DDR output (`gowin_oddr5.v`)

Mirrors `gowin_iddr5.v`'s status: wrapped behind `GOWIN_ODDR`, NOT VERIFIED against Gowin's own
primitive library (WP T1's licence is not something this work could build against), needing a
`gw_sh` check before WP B5 trusts it.

Its behavioural model captures **both** DDR halves at the rising edge together, then releases them
through a clock-level mux -- not one capture per edge (`always @(posedge) <= d_rise;
always @(negedge) <= d_fall;`, this module's first version). The first version raced
`rgmii_tx_phy.v`'s own posedge-triggered shift register: capturing `d_rise` at the same posedge
that updates its upstream source is an ordinary one-cycle pipeline delay (correct), but capturing
`d_fall` at the *next* falling edge sees that same source one full period later -- a whole period
of relative skew a real ODDR primitive (which samples both D0 and D1 together) does not have. That
skew tore one byte's low nibble away from the wrong neighbour once per frame: caught by dumping the
far end's classified bytes and finding the destination MAC preceded by a phantom byte built from
the SFD's low nibble and the real first byte's high nibble. See the file's own header for the full
account.

### 1.9 Top level and arbiter (`hl2_link_tx_top.v`)

The sample framer has priority (ARCHITECTURE.md 3.1). A new frame is only granted while the wire
is fully idle: no content or FCS still streaming, and `rgmii_tx_phy.v` itself reports idle (its own
inter-frame gap has already elapsed) -- so neither producer needs to know about the other or about
the PHY's own IFG timing; the arbiter is the only place that does.

### 1.10 RX-to-TX fill bridge (`rx_tx_fill_bridge.v`)

H1_LINK_RX.md flagged this as left for whoever builds H2: `eth_frame_rx.v` now additionally parses
PROTOCOL.md 6.3 bytes 32-33 (the duplex TX sink's own FIFO fill) into a new `raw_tx_fifo_fill`
output, valid together with `raw_commit`/`raw_version` (version 2 or 3 headers only) -- purely
additive to H1's existing outputs, confirmed not to disturb it by re-running `tb_h1_link_rx.v`
unchanged after the edit (still `PASS`, identical numbers). This bridge module carries that value
from `clk_rx` to `clk_dsp` as a toggle-handshake crossing (`cdc_word.v`), for `tx_rate_lock.v`.

## 2. Interfaces

Same simplification H1 makes (WP T3, the regmap generator, is not done yet): a flat list of
fields, not an AHB slave. `hl2_link_tx_top.v`'s own port list is the interface; the field names
mirror ARCHITECTURE.md 4.1's future 0xE808_0000 TX page (`cfg_tx_enable`, `cfg_trip`,
`cfg_my_mac`/`cfg_my_ip`/`cfg_my_port`, `cfg_hl2_mac`/`cfg_hl2_ip`, the `cq_*` CPU-queue write port,
and the `cnt_*` counters).

## 3. Resource guess

No place-and-route yet at the time this section was written; see section 5 for the measured
numbers.

## 4. Test results

### 4.1 How the testbench is built

`sim/h2_link_tx/tb_h2_link_tx.v` drives `hl2_link_tx_top.v` against the HL2's own duplex/echo RTL
as the far end, per PLAN.md's H2 done-test. The far end does both jobs a real duplex-mode radio
does in this test: `sim/h2_link_tx/hl2/{mac_recv,ip_recv,udp_recv}.v` parse our TX frames,
`sim/h2_link_tx/hl2/txsink.v` (ECHO=1) sinks and plays them back, and `sim/h1_link_rx/hl2/rawstream.v`
(DUPLEX=1, ECHO=1 this time, wired to `txsink.v`'s echo outputs) plus the real send chain already
vendored for H1 carry the echoed samples back to us -- one HL2 image, both directions, so the loop
only closes if H1 (unchanged) and H2 (this WP) are both correct.

Two DDR-pin crossings, one each direction: far end to us reuses H1's own wire-tap technique
unchanged; us to far end feeds `hl2_link_tx_top.v`'s real DDR output pins directly into an instance
of our own `rgmii_rx_phy.v` (+ `gowin_iddr5.v`), standing in for "the far end's RGMII receiver" --
a real Altera/Gowin IDDR simulation model for that side is not reachable from this machine (same
constraint H1_LINK_RX.md already documents) and the vendored `rgmii_recv.v`'s own `SIM=1` branch
is a non-functional stub (it zeroes its decode, unlike `rgmii_send.v`'s `SIM=1`, which only zeroes
pin outputs and keeps its internal shift register live to tap). RGMII DDR decoding and preamble
detection are vendor-neutral, standard operations on the wire; reusing our own already-proven
decoder here does not shortcut anything this WP owns (none of the framer, safety mux, header/
checksum/CRC content, or rate lock live inside `rgmii_rx_phy.v`).

A same-edge race in the testbench's own RGMII line model for the *return* path (identical class of
bug to 1.8's, this time in test infrastructure rather than shipped RTL) was found and fixed the
same way H1_LINK_RX.md's own account describes for its wire model: capture the far end's byte and
enable at the falling edge into a holding register first, rather than reading them directly in the
same always blocks that drive the pins.

### 4.2 Results

`bash tools/check.sh` runs `tb_h2_link_tx.v` at its default `SIM_US` (a short smoke test); the full
50 ms PLAN.md figure is `sim/h2_link_tx/run_long.sh`, run once for this report (25 ms settle + 50 ms
checked window = 75 ms of simulated link time):

```
NOTE: far end return-path (vendored rawstream.v) reported 1 start-up overflow(s), no gap resulted
cnt_tx_frames=964 echo_checked=5744494 echo_mismatches=0
hl2 tx sink: unf=0 ovf=0 bad=0 final_fill=11955
fill_samples=3840192 fill_in_band=3840192 fill_out_of_band=0
cnt_tx_skip=15777 cnt_tx_insert=19577 cnt_tx_fill_updates=5949
H1 return path: gap_events=0 resync_events=0 raw_frames=5949
PASS
```

Reading that against the PLAN.md H2 done-test:

- **Every sample matching.** 5,744,494 echoed samples compared at the far end (its own echo index
  against the played-back value, independent of any of this WP's own counters): **0 mismatches**.
- **No gaps.** H1's own return-path counters stay exactly 0 throughout (0 gap events, 0 resyncs
  over 5,949 good raw frames) -- the loop only closes cleanly if nothing is ever lost either
  direction.
- **Rate lock holding for a long run.** 3,840,192 fill samples taken over the 50 ms checked window
  (after the 25 ms settle -- 4.3 explains why that takes tens of milliseconds, not microseconds):
  **every single one** landed inside 12,000 +/- 2,000 (final fill 11,955, almost exactly on
  target). 15,777 skip and 19,577 insert corrections applied over 5,949 received fill updates --
  the loop keeps nudging continuously, as designed, never needing to swing far to stay in band.
- **0 underflows, 0 overflows** on the HL2's own TX sink (PLAN.md's actual wording): confirmed,
  `unf=0 ovf=0 bad=0`. The one other overflow reported (a *different*, informational-only counter
  -- the vendored return-path sender's own start-up resync overflow, see the testbench's own
  comment at that check) happens once, at start-up, before any duplex/echo traffic exists, and
  produces no gap; it is not what PLAN.md's wording is about.

### 4.3 Why lock takes tens of milliseconds

`tx_rate_lock.v`'s own header has the full reasoning: the link's real spare bit-rate margin over
the raw sample rate itself (PROTOCOL.md 5.7) is small, so closing a 12,000-sample start-up deficit
without dropping data takes on the order of `12,000 * COOLDOWN / clk_dsp_Hz` (about 20 ms at the
default `COOLDOWN`). The testbench settles 25 ms (a fixed margin over that) before it starts
judging the fill against the band, matching PLAN.md's own "after lock" wording rather than
counting the start-up ramp as a failure.

### 4.4 How to run

```sh
bash tools/check.sh                     # short smoke test (tb_h2_link_tx.v's default SIM_US)
iverilog -g2012 -o build/tb_h2_link_tx.vvp sim/h2_link_tx/tb_h2_link_tx.v
vvp build/tb_h2_link_tx.vvp             # same run, standalone
sim/h2_link_tx/run_long.sh              # the full 50 ms PLAN.md run (tens of CPU-minutes)
sim/h2_link_tx/run_long.sh 5000         # an explicit override (microseconds) instead of 50,000
```

## 5. Gowin measured resources and timing

`gowin/res.sh --wrap` (`gowin/reports/README.md` has the method), commit `4ba2b7e`:

```
gowin/res.sh hl2_link_tx_top --clk clk_tx --wrap rtl/hl2link/crc32_eth.v rtl/hl2link/cdc_word.v \
    rtl/hl2link/cdc_sample_fifo.v rtl/hl2link/gowin_oddr5.v rtl/hl2link/rgmii_tx_phy.v \
    rtl/hl2link/tx_sample_framer.v rtl/hl2link/tx_rate_lock.v rtl/hl2link/cpu_tx_queue.v \
    rtl/hl2link/crc32_append.v rtl/hl2link/hl2_link_tx_top.v

hl2_link_tx_top_ooc_wrap: Logic 1464/138240, Register 1596/139140, DSP 0/298, BSRAM 14/340
  -- 149.993(MHz) target, 82.725(MHz) achieved
Block alone: hl2_link_tx_top: Logic 1269, Register 948
```

**This number needs two caveats, not a clean pass/fail against 150 MHz:**

- **Dual clock domain, measured through a single-clock wrapper.** `hl2_link_tx_top.v` has two real
  clocks (`clk_dsp` 150 MHz, `clk_tx` 125 MHz -- WP H3's PLL); `gowin/gen_wrap.py` supports one
  wrapper clock per block (every other block measured in `gowin/reports/README.md` is
  single-clock). Measuring with `--clk clk_tx` gives the `clk_tx`-domain logic (frame assembly,
  arbitration, CRC, RGMII) a correctly-clocked wrapper, but drives the `clk_dsp`-domain logic
  (the sample packer, the rate lock) from the *same* 150 MHz wrapper clock rather than its own --
  close enough numerically (`clk_dsp`'s real clock is also 150 MHz) that the resource counts and
  most paths are meaningful, but this is not a substitute for a real dual-clock timing run.
- **The worst path is inside the measurement wrapper's own shift chain, not this WP's real
  logic**: `in_r_103_s0/Q -> framer_i/hdr_bytes_271_s0/D`, i.e. loading `tx_sample_framer.v`'s
  464-bit per-frame header register (`hdr_bytes`, 1.4's own account) directly from the wrapper's
  input shift-chain registers. In the real design, `cfg_my_mac`/`cfg_hl2_ip`/etc. are
  firmware-set configuration that changes rarely (not every cycle the way the wrapper's shift
  chain toggles them), and `hdr_bytes` is only actually loaded once per TX frame (every ~78 us at
  N=5,970), not every clock -- this critical path is very unlikely to reflect a real operating
  constraint. Confirming that (and finding `hl2_link_tx_top`'s *real* worst path, if it has one
  closer to 150/125 MHz) needs either a smarter wrapper (registering the config inputs once, off
  the shift chain, the way a real AHB register block would) or the actual chip top level's own
  timing run (WP P1) -- not repeated here given the limited number of Gowin runs available here.

Given both caveats, this section's own resource counts (Logic 1269, Register 948, BSRAM 14 for the
block alone) are the reliable part of this measurement; the 82.7 MHz figure is reported for the
record, not as a timing failure this WP is leaving unresolved.

## 6. What H2 leaves for later

- **RGMII delay / real PHY interaction is WP H3's job**, not this one: this WP's `rgmii_tx_phy.v`
  drives the pins edge-aligned (no delay added on our side), matching the board's own strap
  configuration (both TXDLY and RXDLY enabled at the PHY, docs/H3_PHY.md section 1) once H3's pin
  constraints are in place.
- **`gowin_oddr5.v`'s `GOWIN_ODDR` branch is unverified** against the real primitive library, same
  status as `gowin_iddr5.v`'s own `GOWIN_IDDR` branch (WP T1 pending).
- **A deeper CPU transmit queue** (more than one frame in flight) is a possible enhancement, not
  needed by any done-test today (1.6).
- **The chip top level (WP P1)** still needs to wire `tx_chain.v`'s real `pace`/`out_data`/
  `out_valid` to this WP's `pace_out`/`in_sample`/`in_valid`, and instantiate
  `rx_tx_fill_bridge.v` between H1's and H2's top levels (this WP's own testbench does both
  directly, as a stand-in for that future wiring).
