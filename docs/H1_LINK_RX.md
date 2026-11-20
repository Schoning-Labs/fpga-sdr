<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# H1: HL2 link receive path

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Work package H1 (`docs/PLAN.md`), branch `h1-link-rx`.
Covers ARCHITECTURE.md section 3.1's receive side: RGMII RX, MAC with CRC check, classifier,
raw-frame parser, CDC FIFO, gap filler, CPU receive ring, safety-byte register and interrupt.
Transmit (the TX sample framer and CPU transmit queue in the same architecture section) is H2, not
started here.

## 1. Design

**2026-10-21 (docs/HL2_SFP.md):** the HL2 is on SFP0; this chain takes the lane PCS's bytes through gmii_rx_in.v (byte enable) instead of rgmii_rx_phy.v, clk_rx is the lane's recovered clock, and eth_frame_rx counts lost frames by sequence number.


### 1.1 Block diagram and clock domains

```
RGMII pins --clk_rx--> rgmii_rx_phy.v --clk_rx--> eth_frame_rx.v --clk_rx--> raw_frame_buffer.v --clk_dsp--> gap_filler.v --clk_dsp--> samp_out (H1's output)
                                                        |
                                                        `--clk_rx--> cpu_rx_ring.v (read by firmware, clk_rx)
```

- `clk_rx` (125 MHz): the RGMII receive clock, forwarded by the PHY (source-synchronous -- there
  is no separate "our" clock on this side of the link; RGMII RX always runs at whatever clock the
  transmitting end forwards). RGMII deserialisation, the CRC-32 check, classification and raw-frame
  header parsing all happen here, one byte per cycle.
- `clk_dsp` (120 MHz): the board's own free-running clock, unrelated to the HL2's ADC clock
  (ARCHITECTURE.md section 2: "the HL2's samples arrive at 76.8 MHz of *its* clock, which differs
  from ours by a few ppm"). `raw_frame_buffer.v` is the one block that spans both domains; the
  gap filler and everything downstream of it lives entirely in `clk_dsp`.

### 1.2 Files (`rtl/hl2link/`)

| File | Role |
|---|---|
| `gowin_iddr5.v` | RGMII DDR input deserialiser (5 bits: RX_CTL + RXD[3:0]). The one Gowin-specific primitive this WP needs, wrapped behind `` `GOWIN_IDDR `` with a behavioural simulation model as the default -- see 1.3. |
| `rgmii_rx_phy.v` | Pins to byte stream: preamble/SFD strip, `data`/`active`. Adapted from `gateware/rtl/ethernet/rgmii_recv.v` in the HL2 release worktree (GPL-2.0-or-later, VE3NEA), simplified to 1000BASE-T only (no 10/100 Mbit nibble realignment -- the link partner is always the HL2, always gigabit) and re-targeted at `gowin_iddr5.v` instead of Altera's `ddio_in`. |
| `crc32_eth.v` | Fresh implementation of the standard CRC-32/ISO-HDLC (Ethernet FCS) algorithm, streaming, one byte per clock. Not copied from the HL2's own `crc32.v` (a differently-organised but mathematically equivalent implementation) -- written to match the check `gateware/sim/rawstream/tb_rawstream.sv` already uses in software to verify the HL2's own sender, so both sides of the link agree on what "the CRC matches" means. |
| `eth_frame_rx.v` | The classifier, raw-frame header parser and the CRC check itself: one FSM, byte-offset-driven, in `clk_rx`. See 1.4. |
| `raw_frame_buffer.v` | One 8,192-sample ring with a registered read (ARCHITECTURE.md 3.14 C11/WP RB7), the 3-byte-to-2-sample unpacker (PROTOCOL.md 5.2), the commit/drain sequencer, and the two `clk_rx` -> `clk_dsp` async FIFOs (samples, and one 48-bit first-sample-index per committed frame). See 1.5. |
| `cdc_sample_fifo.v` | Vendor-neutral async dual-clock FIFO (Gray-coded pointers, plain dual-port memory) used for both crossings in `raw_frame_buffer.v`. |
| `cdc_word.v` | Toggle-handshake single-word CDC crossing for slow-changing signals (not used by the sample/index path, which needs FIFO-grade correctness under backlog -- available for anything else in this block that needs a simple crossing later, e.g. a firmware-written configuration register). |
| `cpu_rx_ring.v` | The 4 KB CPU receive ring (ARCHITECTURE.md 4.1, 0xE802_0000; ARCHITECTURE.md 3.14 C11/WP RB7), one write-only port (payload bytes, the odd-byte pad and the length word, arbitrated) and one read-only port (the external byte read). Everything `eth_frame_rx.v` does not classify as a raw sample frame. See 1.6. |
| `gap_filler.v` | `clk_dsp`: tracks the expected sample index, zero-fills a detected gap, raises a resync when a jump is too large to fill. See 1.7. |
| `hl2_link_rx_top.v` | Ties the above together, plus the transmit-safety-byte register and its change interrupt (PROTOCOL.md 5.4). |

### 1.3 The one Gowin primitive

RGMII RX needs a DDR input register (IDDR) to recover both nibbles the PHY presents on each
`clk_rx` cycle. `gowin_iddr5.v` wraps this behind `` `GOWIN_IDDR ``; every testbench in `sim/`
uses the `else` branch (a plain behavioural DDR register pair) instead. **The `GOWIN_IDDR` branch
has not been built or simulated against Gowin's own primitive library** -- WP T1 (Gowin EDA
licence) is not done yet, so there is no toolchain on this machine yet to check the instance
template against. It is best-effort from the DS1104/DS1239 primitive tables named in
`docs/BOARD.md`. This needs checking against `gw_sh` (or the primitive user guide) before WP H3
(RTL8211F bring-up) or WP B5 (H1-H3 on hardware) trusts it.

RGMII pin locations themselves are explicitly **not** part of this WP (`docs/BOARD.md` open
question 4, blocking H3, "blocked (needs RX pins from the schematic)") -- `hl2_link_rx_top.v`
exposes plain `rgmii_rxd[3:0]`/`rgmii_rx_ctl` ports; a pin constraints file is H3's job.

### 1.4 Classifier and raw-frame parser (`eth_frame_rx.v`)

Byte-offset classification, assuming no VLAN tag and no IP options (the HL2's `ip_send.v` always
emits a fixed 20-byte IHL=5 header):

| Bytes | Field |
|---|---|
| 0-5 | destination MAC | 6-11 | source MAC | 12-13 | EtherType |
| 14-33 | IPv4 header (20 B) | 34-35 | UDP source port | 36-37 | UDP destination port |
| 42 | first UDP payload byte |

A frame is **raw** iff EtherType = 0x0800, IP protocol = 17 (UDP), IP source address = the
configured HL2 address, UDP source port = 1024 and payload byte 0 = 0xA5 -- exactly
ARCHITECTURE.md 3.1's rule, and all of it is known by the time byte 42 (the raw-frame magic byte,
also raw-header byte 0) has arrived. That means the routing decision never needs to buffer-then-
replay a byte: byte 42 is fed live to whichever downstream consumer it belongs to. Bytes 0-41 are
always fed to the "other" path speculatively; if the frame turns out to be raw, `cpu_rx_ring.v`
simply never receives a `commit` for it and its speculative write pointer rolls back (see 1.6) --
cheap, since classification resolves after only 42 bytes regardless of how large the frame turns
out to be.

Header parsing (raw-header byte 1 = version) fills in the length for versions 1 (20 B, duplex
off -- the only one H1 v. H2 exercises), 2 (40 B) and 3 (48 B), reading the fields common to all
three (sequence, first-sample index, N, overflow count, high water, flags, transmit-safety byte).
The version 3 trailer (TX sink status, echo/interlock status) is not captured -- that is H2's
concern once it exists.

**CRC-32 check**: a standard 4-byte delay (`d1..d4`), CRC computed over everything except those
last four bytes, compared against them reassembled as the transmitted FCS -- the same check
`tb_rawstream.sv` already uses in software, ported to hardware here (see `crc32_eth.v`'s header
comment for the exact reasoning and how it was cross-checked against that testbench's own
algorithm). **A CRC-bad frame is dropped entirely, of either kind** -- neither `raw_frame_buffer.v`
nor `cpu_rx_ring.v` ever commits it. For a raw frame this is exactly the PLAN.md H1 done-test's "a
frame with a flipped bit is dropped and replaced by exactly N zero samples": `gap_filler.v`
downstream sees the resulting index gap and fills it, with no special case needed in the parser at
all.

**Known simplification**: no destination-MAC filter yet. Every frame that clears the PHY
preamble/SFD detector is classified and processed, regardless of destination address.
ARCHITECTURE.md doesn't ask for this filter explicitly, and `DECISIONS.md` fixes the RJ45 as a
point-to-point link to the HL2 alone, so there is only ever one sender -- but a real deployment
should still add it (cheap: capture bytes 0-5, gate on `dest_mac == cfg_local_mac || broadcast`)
before H3/B5 puts this on real hardware where stray traffic is possible.

### 1.5 Raw-frame sample staging and the clock crossing (`raw_frame_buffer.v`)

**Changed by WP RB7** (ARCHITECTURE.md 3.14 C11): originally two BSRAM banks (`MAX_N` = 5,968
samples each), ping-ponged per raw frame with a combinational drain read -- see "what H1 leaves
for later" below for why that never mapped to real block RAM. Now **one 8,192-sample ring**
(`BANK_AW` = 13) with a single write port (the byte unpacker, running continuously across frames --
the write pointer is never reset, there is no second bank to reset it into) and a single registered
read port (the drain sequencer). A frame drains at up to 125 M samples/s (one `clk_rx` cycle per
sample when the sample CDC FIFO has room) while the next frame's bytes arrive at 83.3 M samples/s
(PROTOCOL.md 5.2's 3-bytes-per-2-samples packing at one byte per `clk_rx` cycle), and only one
frame is ever waiting to drain at a time (a raw frame's own arrival period is longer than its own
drain time), so 8,192 / 5,968 = 1.37 frames of ring space is always enough margin -- the write side
never overtakes the read side. A frame's samples are only ever drained -- reach `clk_dsp` at all --
if `eth_frame_rx.v` pulses `commit` for it; a CRC-bad or misclassified frame's bytes simply sit in
the ring until the write pointer wraps back over them, which is the actual mechanism behind
"dropped and replaced by zero samples" (nothing here manufactures the zero-fill; it's purely that
the samples never arrive, and `gap_filler.v` fills the resulting index gap).

The read is registered and **unconditional** (`mem_q <= mem[dp]` every cycle, no enable), matching
`rtl/rx_backend/bk_ram.v`'s proven shape, and kept in its own always block with nothing else in
it -- mixing the drain FSM's bookkeeping into the same block as the memory access was tried first
and defeated BSRAM inference (yosys fell back to distributed flip-flops again, the same failure
C11 exists to avoid); isolating the memory access the way `bk_ram.v` does fixed it. The drain
sequencer stalls by holding the read address `dp` steady whenever the sample CDC FIFO has no room,
rather than gating the read itself. Because the read is registered, a word fetched just before the
FIFO filled is already out of the memory when the stall starts; it is parked in a one-word hold
register (`hold_q`) and written from there when room returns (4.6: an earlier version dropped it).
The sample FIFO's `wr_full` already counts the write being made in the same cycle, which is what a
writer that decides one cycle ahead (`fifo_wr` is a register) needs.

Two async FIFOs cross to `clk_dsp` (`cdc_sample_fifo.v`, a vendor-neutral Gray-coded dual-clock
FIFO built from plain dual-port memory, not a `dcfifo`/`FIFO36E1`-style macro):

- the sample stream itself, tagged `sof` on a committed frame's first sample;
- a much shallower stream of just the 48-bit first-sample index, one word per committed frame.

`gap_filler.v` pops one word from the index FIFO exactly when it pops an `sof`-tagged sample from
the other one, so the two stay matched however far either FIFO backs up. A single mailbox register
(`cdc_word.v`) was considered and rejected for this: it cannot survive a backlog of more than one
frame without a newer index overwriting an older one before the matching sample is even popped.

### 1.6 CPU receive ring (`cpu_rx_ring.v`)

**Changed by WP RB7** (ARCHITECTURE.md 3.14 C11): originally a 16 KB circular byte buffer with a
single byte-wide memory array that could take three separate writes in one clock (one payload byte
during `sof`/`valid`, plus the two length-prefix bytes patched in together at `commit`) -- which is
exactly why it never mapped to BSRAM at all (see "what H1 leaves for later" below). Now **4 KB**
(ARCHITECTURE.md 4.1's address stays 0xE802_0000; the smaller size is this WP's own change), stored
as 16-bit words (two bytes per word) behind exactly two memory ports: **one write-only port and one
read-only port**, the same shape as `rtl/rx_backend/bk_ram.v` and `raw_frame_buffer.v` (this WP's
other block). ARCHITECTURE.md 3.14 describes this as "one write port (the length word written
through the second port)"; two drafts that gave the length word a literal second, independent write
address -- one sharing it with the external read on one shared address bus, one keeping the read
fully independent -- both still asked the memory for two simultaneous writes a cycle (the payload
writer's and the length patch's), which needs a third port no 2-port BSRAM has, so both fell back to
distributed flip-flops instead (confirmed with `tools/yosys_res.sh cpu_rx_ring` in isolation against
each draft: about 32,900 of the module's 33,000-odd register count was this memory alone, essentially
the whole 4 KB stored as individual bits). The fix keeps the "one write port" half literally -- every
write (payload bytes, the odd-byte pad, and the length word) goes through that one port, arbitrated
so only one of them fires in a given cycle -- and turns "the second port" into the external read
instead of a second write. The length word's own write is delayed to exactly the cycle *after*
`eof`/`commit`, which is enough to never collide with anything: a new frame's own first payload write
needs at least two more cycles after its `sof`, and `sof`/`eof` can never land on the same cycle
(both come from the same byte-serial classifier), so the delayed length write always has an empty
cycle to itself. `wr_ptr`, `cnt_frames` and `irq_pkt_rx` move one cycle after the length word's
write is issued, when it has actually landed in memory (the write port is itself registered), so a
reader is never pointed at a frame whose length word has not been written yet (4.6: an earlier
version moved them one cycle too early). Framing is otherwise unchanged: each frame is
stored as a 2-byte big-endian length followed by that many bytes (destination MAC through the last
payload byte -- `eth_frame_rx.v` already excludes the FCS by construction). The length word's home
(one whole word) is reserved at the frame's start; on a CRC failure, or a frame that turns out to be
raw, the whole reservation (length word and any payload words already claimed) is given back so the
next frame reuses exactly the same ring space -- the same commit-or-roll-back principle the original
version used, extended to the length word's own slot. An odd byte count's last, half-full word is
padded with a zero low byte (through the same shared write port, since it is still payload space) so
the next frame's length word always starts on a word boundary; the stored length itself is never
padded. A reader that only ever trusts bytes up to the last committed write pointer (`wr_ptr`) never
sees a torn or wrong-length entry. `irq_pkt_rx` (PLIC line 0) pulses once per committed frame.
`hl2_link_rx_top.v` keeps its own `ring_rd_addr`/`ring_wr_ptr` ports at their original 14-bit width
(`RING_AW`) so nothing upstream has to change; only the low 12 bits address the (now 4 KB) ring, and
`ring_wr_ptr` is zero-extended back up to 14 bits.

The read side here is a plain synchronous byte-address port standing in for the AHB slave WP T3's
register-map generator will eventually wrap this block in -- see "what H1 leaves for later" below.

### 1.7 Gap filler (`gap_filler.v`, `clk_dsp`)

Pops the sample stream; for an ordinary (non-`sof`) sample, passes it straight through. For an
`sof`-tagged sample (the first of a newly committed frame), also pops the matching first-sample
index and compares it against a locally tracked `expected_idx`:

- equal: no gap, pass the sample through, `expected_idx += 1`.
- `0 < gap <= 65,536` (ARCHITECTURE.md 3.1's resync threshold): emit exactly `gap` zero samples
  (`out_is_fill` high), then the real sample, then continue. This is the done-test's "N zero
  samples" path.
- `gap > 65,536`, or the index went backwards: a resync -- `expected_idx` jumps straight to the new
  value, no fill (filling tens of thousands of samples one at a time for no useful reason), counted
  separately (`cnt_resync_events`) and also raises `irq_gap`.
- the very first frame ever seen: nothing to compare against yet, so it just becomes the baseline
  with no gap counted -- correct hardware behaviour, and the reason this WP's own testbench waits
  for one real frame to land before injecting its bit error (see 2.2).

`irq_gap` (PLIC line 1, "status change (safety byte, link, overflow, gap)") covers both a gap and
a resync.

**Throughput: one sample per `clk_dsp` cycle** (150 M/s against the stream's 76.8 M/s). The sample
FIFO's read has one cycle of latency, so the gap filler issues pops ahead into a 4-word input queue,
on credit (a pop only goes out if the queue has room for it even if nothing more is taken out). While
samples flow, a pop goes out every cycle; while the state machine waits for an index or zero-fills,
pops stop once the queue is full. The first version handled one sample at a time (pop, wait, handle):
three cycles per sample, 50 M/s, too slow for the stream (4.6).

### 1.8 Safety byte and its interrupt (`hl2_link_rx_top.v`)

Latched from `raw_tx_status` on every **CRC-good** raw-frame commit (PROTOCOL.md 5.4 says "copied
... on every frame"; read literally that would include CRC-bad frames, but a bad frame's payload,
header and this byte along with it, can't be trusted, and a bad frame never reaches `raw_commit`
here in the first place -- so in practice this only ever latches from a frame `eth_frame_rx.v` has
already checked). A change from the previous latched value pulses `irq_safety_change` (level of
transmit interlock enforcement -- bit 7 trip, bit 6 over-temperature making the TX framer zero
output "in logic, without waiting for firmware" -- is H2's job, once the TX framer exists to act on
it; H1 only carries the byte and raises the interrupt).

## 2. Interfaces

### 2.1 Register interface (placeholder)

`hw/regmap/` is empty -- WP T3 (the `xtask regmap` generator) is not done yet, so there is no
generated address decoder or Rust register crate to plug into. `hl2_link_rx_top.v` exposes a flat
list of fields (configuration input, counters, interrupts, the ring's read port) instead of an AHB
slave; whoever builds T3 and wires this block into the 0xE801_0000/0xE802_0000 address space needs
to map:

| Field | Direction | Notes |
|---|---|---|
| `cfg_hl2_ip[31:0]` | in | learned from discovery or set by firmware; classification only compares against this, nothing here parses discovery replies itself (that's `tr-hl2` in firmware, reading them out of `cpu_rx_ring.v`) |
| `safety_byte[7:0]`, `irq_safety_change` | out | PROTOCOL.md 5.4 mirror register + IRQ |
| `irq_pkt_rx`, `irq_gap` | out | PLIC lines 0 and 1 |
| `cnt_crc_errors/raw_frames/other_frames` | out | `eth_frame_rx.v` |
| `cnt_ring_frames/ring_dropped` | out | `cpu_rx_ring.v` |
| `cnt_gap_events/gap_samples/resync_events` | out | `gap_filler.v` |
| `ring_rd_addr/ring_rd_data/ring_wr_ptr` | in/out/out | the 4 KB ring's byte-addressed read port (WP RB7; the port itself stays 14 bits wide, only the low 12 address the ring -- see 1.6) |
| `samp_out[11:0]/samp_out_valid/samp_out_is_fill` | out, `clk_dsp` | H1's product: the continuous sample stream R1 (receiver bank) consumes |

### 2.2 Open interface decisions not in ARCHITECTURE.md

- **`cfg_hl2_ip` is a bare input, not yet a firmware-writable register with its own CDC.**
  ARCHITECTURE.md 4.2 says register writes cross from `clk_ahb` with a "handshake synchroniser";
  this WP defines the field the classifier needs but leaves that specific crossing to whoever wires
  it into the AHB slave (T3), since there is no AHB slave to attach it to yet.
- **Destination-MAC filtering is not implemented** (1.4's "known simplification").
- **Version 2/3 raw-frame trailers are parsed for length only, not content** -- H2's TX sink status
  and echo/interlock fields are not captured into any register here; H2 should decide whether that
  belongs in `eth_frame_rx.v` or in a block of its own.
- **A second raw-frame commit arriving before the first has finished draining is silently
  dropped** (`raw_frame_buffer.v`'s `commit && !draining` gate). The margin is large at every N in
  PROTOCOL.md's table -- draining N samples takes N `clk_rx` cycles (at most 5,968, 47.7 us),
  comfortably inside the shortest frame period (about 77.7 us at that same N) -- so this never
  triggers for any protocol-compliant stream, and the testbench's own frame-to-frame timing
  confirms real margin (about double), not a near miss. Flagged rather than re-engineered into a
  deeper queue because the margin already holds for every N the protocol allows.

## 3. Resource guess

No place-and-route yet (WP T1/R3 territory); from the design alone:

| Resource | Rough count | Why |
|---|---|---|
| BSRAM | 8,192 x 12 bit ring (raw samples) + 4,096 x 8 bit ring (CPU, as 16-bit words) + ~5 Kbit (sample/index CDC FIFOs) ≈ 15 KB (WP RB7, ARCHITECTURE.md 3.14 C11 -- see 4.4 for the measured yosys count) | against 6,120 Kbit (765 KB) total on GW5AST-138 (`docs/BOARD.md`) -- a small fraction |
| LUT/FF | a few thousand, dominated by the two byte-serial FSMs (`eth_frame_rx.v`, `raw_frame_buffer.v`'s drain sequencer) and the CRC-32 datapath | against 138,240 LUT4 (`docs/BOARD.md`) -- not a concern at this scale |
| DSP | none | no multipliers in this block |

## 4. Test results

### 4.1 How the testbench is built

`sim/h1_link_rx/tb_h1_link_rx.v` instantiates the real HL2 send-side RTL as the far end, exactly as
PLAN.md's H1 done-test specifies: `rawstream.v` plus the real `udp_send`/`ip_send`/`mac_send`/
`crc32`/`rgmii_send` modules from `G:/proj/worktrees/Hermes-Lite2-hl2-rawfront-release` (an
absolute-drive path doesn't work through Icarus's `` `include `` on this machine -- see the
testbench's own header comment -- so this uses a relative path to that sibling worktree, the same
fixed local layout ARCHITECTURE.md already names). `sim/h1_link_rx/dcfifo_sim_stub.v`
stands in for Quartus's `dcfifo` megafunction, which `rawstream.v` instantiates directly: the real
model (`altera_mf.v`) exists on this machine but on the `C:` drive, unreachable the same way, so
this is a from-scratch reimplementation of the documented showahead-FIFO interface `rawstream.v`
actually uses, not a copy of Intel's file.

The send-arbitration glue (the discovery-reply packer state machine, the `tx_ready`/`tx_start`
mux) is copied from that worktree's own `gateware/sim/rawstream/tb_rawstream.sv`, which stands in
for `usopenhpsdr1.v`/`network.v` there for the same reason that testbench gives: those two files
use constructs Icarus rejects. It is what produces the discovery-reply traffic this WP's
"everything else -> CPU ring" check uses -- a real discovery reply's *content* comes from
`usopenhpsdr1.v`, out of scope for a receive-path WP either way, but its *framing* (the same real
`mac_send`/`ip_send`/`udp_send`/`crc32`/`rgmii_send` chain the raw stream also goes through) is
real.

This testbench's own contribution starts at the wire: it taps the far end's fully-framed byte
stream (rgmii_send's internal shift register, valid while `sending` -- `SIM=1` only suppresses the
DDR pin assignment, not the framing logic) and re-serialises it into a genuine DDR-encoded RGMII
bus at the shared 125 MHz clock, which is what `hl2_link_rx_top.v`'s pins actually see. That
exercises the real `gowin_iddr5.v` simulation model and `rgmii_rx_phy.v` preamble detector, not a
shortcut byte interface direct into `eth_frame_rx.v`.

**The 50 ppm clock offset** (PLAN.md's done-test) is applied to the far end's `clk_ad` (its
76.8 MHz ADC/sample clock): half-period 6,510.0912 ps against a nominal 6,510.41667 ps, i.e. about
50 ppm faster, computed in the testbench header comment. `clk_rx` itself is not a place a ppm
offset applies -- RGMII is source-synchronous, so the same 125 MHz clock literally drives both the
far end's transmit logic and the DUT's receive logic in this simulation, exactly as the PHY
forwards one clock to both ends on real hardware. `clk_dsp` (150 MHz) is the DUT's own independent
free-running clock, unrelated to either -- this is what actually stresses the CDC FIFOs
(`cdc_sample_fifo.v`), since it never has a fixed integer relationship to the sample production
rate.

A single bit is flipped in one raw frame's sample payload at the wire tap (not by disturbing the
HL2 RTL's own CRC computation -- the flip happens strictly downstream of `mac_send`, which has
already computed the correct FCS over the *uncorrupted* data, so the corruption is exactly "a bit
got flipped in flight"). The testbench waits for at least one whole good raw frame to land before
arming this: `gap_filler.v` has no "expected index" baseline until it has seen a first real frame,
so corrupting the very first frame ever sent would just become that baseline with no gap counted --
correct hardware behaviour, but it would mean the test checked nothing. (Caught during development:
see the file's own comments at the `wait (cnt_raw_frames >= 1)` line.)

### 4.2 Results

`bash tools/check.sh` (default `SIM_US=3`, i.e. 3 us of streamed and checked link time past the
point where the first good raw frame, the corrupted one and the discovery reply have already gone
by, plus a 40 us settle at the end) **passes**. Output since the fixes in 4.6 (times in fs):

```
t=27968000000: injecting a bit error at frame byte offset 300
discovery reply in CPU ring: length=102 first bytes=02 00 00 00
t=63564000000: irq_safety_change fired, safety_byte=81
samples_checked=3872 fill_samples=968 raw_frames=3 other_frames=1 crc_errors=1
gap_events=1 gap_samples=968 resync_events=0 ring_frames=1 ring_dropped=0
PASS
```

The full 20 ms figure is in 4.6.

Reading that against the PLAN.md H1 done-test:

- **Test pattern.** 3,872 samples checked against an independently-tracked expected value (not the
  DUT's own counter -- see the testbench's own comment on this), **0 mismatches**.
- **Bad-frame handling.** 1 bit flipped in one raw frame -> exactly 1 CRC failure -> exactly 1 gap
  event -> exactly 968 zero-fill samples (N), counted both by the DUT and by the testbench's own
  output checker, and every good frame's 968 samples came out (real samples out = good frames x
  968), at any `SIM_US`.
- **Discovery reply -> CPU ring.** Landed; stored length 102 bytes (matches the frame's own
  destination-MAC-through-payload span exactly, cross-checked against the ring's own start/end
  pointers); its first 6 stored bytes are exactly this testbench's own MY_MAC.
- **Safety-byte interrupt.** Fired within one frame period of the change, with the correct new
  value latched.
- **50 ppm clock offset.** Present throughout (the far end's `clk_ad` runs at that offset for the
  whole run, 1.1 above) -- samples still matched the pattern exactly, so the async sample/index
  FIFOs handle it correctly rather than assuming any fixed ratio.

Getting here found and fixed five real bugs (each has a comment at its fix site explaining the
exact symptom that caught it -- a specific, named number in this testbench's own output
disagreeing with what the design should produce, not something found by inspection): a same-edge
race in the testbench's own RGMII line model that silently swapped byte pairing (`tb_h1_link_rx.v`);
a byte counter that never reset between frames, which broke the bit-error injection's targeting
(`tb_h1_link_rx.v`); a one-cycle skew between "frame ended" and "keep it" that made the CPU ring
roll back every single frame, discovery replies included (`eth_frame_rx.v`); a signed/unsigned
underflow that fed two extra header bytes into the raw sample unpacker, corrupting every raw
frame's worth of samples (`eth_frame_rx.v`); and the CPU ring storing four extra (FCS) bytes per
entry (`eth_frame_rx.v`, `cpu_rx_ring.v`).

Before 4.6 this section quoted 1,581 samples and 613 fill samples for the same run: the gap
filler then produced 50 M samples/s, so less came out in the same window, and the fill had not
finished when the run ended.

### 4.3 How to run

```
bash tools/check.sh                    # full repo check; runs tb_h1_link_rx.v and
                                       # tb_h1_link_rx_backpressure.v at the default SIM_US=3
iverilog -g2012 -o build/tb_h1_link_rx.vvp sim/h1_link_rx/tb_h1_link_rx.v
vvp build/tb_h1_link_rx.vvp            # same H1 run, standalone
sim/h1_link_rx/run_long.sh             # the full 20 ms PLAN.md run; prints vvp's CPU time (4.6)
sim/h1_link_rx/run_long.sh 5000        # an explicit override (microseconds) instead of 20,000
```

`+define+SIM_US=<n>` (`iverilog -DSIM_US=<n> ...`) sets how many microseconds of link time the
test streams and checks, past the point where the first good raw frame, the injected bad one and
the discovery reply have already gone by. `-DTB_HEARTBEAT` prints a status line every simulated
microsecond (`-DTB_HEARTBEAT_PS=<n>` changes the interval), flushed as it goes.
`tb_h1_link_rx_backpressure.v` is the same testbench with the sample FIFO cut to 256 words, so the
968-sample zero fill backs the drain up into a full FIFO (4.6).

### 4.4 WP RB7: HL2 link RX memories (ARCHITECTURE.md 3.14 C11)

The H1 done-test (4.1-4.3) passes unchanged with both memory blocks rebuilt (1.5, 1.6); this WP's
own done-test is `tools/yosys_res.sh hl2_link_rx_top`, which measures whether they actually map to
BSRAM instead of distributed flip-flops. Measured (`synth_gowin -family gw5a`, synthesis only):

```
hl2_link_rx_top: DSP 0, BSRAM(18k) 9, logic 1865 (LUT 1182 incl. LUT1 261, ALU 611, LUTRAM 12 x 6), MUX2 453, FF 1296
```

Against the done-test's limits: **logic 1,865 (limit 3,500), registers 1,296 (limit 3,000), BSRAM 9
(limit 9)** -- all three inside budget, BSRAM exactly at the limit. Down from the pre-C11 baseline
(ARCHITECTURE.md 3.14): logic over 38k, about 131,000 registers.

Getting a passing number here took two more iterations than the design in 1.5/1.6 describes as
final, both caught the same way -- `tools/yosys_res.sh cpu_rx_ring` run against just that one file
in isolation, which reaches a verdict in well under a minute instead of the full top's several
(`hl2_link_rx_top` pulls in `eth_frame_rx.v`'s byte-serial CRC/classifier FSM too, which ABC9's
equivalence check pads out to a far larger netlist than the two memories account for on their own):

1. First draft: `raw_frame_buffer.v`'s ring with a *conditional* registered read (`if (do_issue)
   mem_q <= mem[dp];`, gated by whatever FIFO-backpressure logic happened to be live that cycle),
   with that condition computed in the same always block as the rest of the drain sequencer's
   bookkeeping. Isolated synthesis of `raw_frame_buffer` alone still showed the memory as
   individual flip-flops. Fix: an *unconditional* read (`mem_q <= mem[dp]` every cycle, matching
   `rtl/rx_backend/bk_ram.v`'s own template exactly) in its own always block with nothing else in
   it -- stalling is free anyway, since holding `dp` steady just re-reads the same word.
2. Second and third drafts: `cpu_rx_ring.v`'s length-word write given its own address, either
   sharing one muxed address bus with the external read (one access a cycle for that "port") or
   fully independent from it (two accesses a cycle). Both isolated to the same result: about 32,900
   of the module's flip-flops, essentially the entire 4 KB as individual bits, because both still
   asked the memory for *two simultaneous writes* whenever a frame committed (the general payload
   writer's and the length patch's) -- a third port a 2-port BSRAM does not have, regardless of
   which signal the read shares. Fix: one write port shared by everything that writes (payload
   bytes, the odd-byte pad, and the length word, arbitrated so only one fires per cycle -- see 1.6),
   and a read port that only ever reads.

The general lesson, applicable beyond this WP: a synthesisable dual-port memory in this flow needs
literally two memory-only always blocks, one write-only and one read-only (or one of each doing only
that), each written as close to `bk_ram.v`'s own two lines as possible -- any conditional gating an
address or a read, or any second signal that can drive a write to the same array, seems to be enough
to make yosys's Gowin BRAM inference give up and fall back to flip-flops, silently (no error, just a
much larger `stat` count) rather than refusing to synthesize.

**`tools/yosys_res.sh`'s own `tee -o <file>.stat.txt stat` step failed intermittently** during this
work ("Can't create file ... stat.txt", yosys exiting 1) even on runs that otherwise completed
cleanly and printed the same `stat` output to the `-l` log regardless -- reproduced across three
different output directories (two different drives), so it looks like an environment quirk on this
particular machine (a large `stat` report's write briefly colliding with something else, on a
machine also running other simulations throughout -- see 4.5) rather than anything about the design.
The numbers above are read from the `.log` file's own final `stat` section, which this failure never
affected.

### 4.5 Second goal: `run_long.sh`'s speed

**Superseded by 4.6.** The slow runs below were not slow: every run that reached 74.8 us of
simulated time hung there in a zero-time loop, caused by a combinational loop in the RTL. The "CPU
time" column is also not a CPU measurement: Git Bash's `time` does not see a native Windows child
process's CPU time. The account below is kept as it was written.

The full 20 ms run has still never completed (4.2's own account: over 22 CPU-hours consumed without
finishing, before this WP). The premise checked here -- "the huge register arrays this package
removes ... are a likely cause of the slow simulation" -- **does not hold**: the ~131,000-flip-flop
count ARCHITECTURE.md 3.14 measured is a *synthesis* artefact (what `synth_gowin`/yosys maps an
unsynthesisable-as-BSRAM array down to), not something that exists in Icarus's own behavioural
simulation of the same `reg [W:0] mem [0:N-1]` array -- `vvp` indexes a memory array in one step
either way, regardless of what a downstream synthesis tool would eventually do with it. Measuring
before and after this WP's RTL change would have shown that directly; given what follows below, it
was not worth spending more of this WP's own run_long time doing so on top of everything else.

**Measurements** (`iverilog -DSIM_US=<n> ... && time vvp ...`, `<n>` microseconds of link time past
the setup point 4.1 describes, this WP's finished RTL):

| SIM_US | wall time | CPU time (user+sys) |
|---|---|---|
| 3 (the `tools/check.sh` default) | well under 2 s (4.2) | -- |
| 10 | 0.59 s | 0.05 s |
| 20 | 0.77 s | 0.06 s |
| 25 | 10.9 s | 0.19 s |
| 30 | did not finish in 60 s (`timeout 60`, killed) | 0.18 s at the point it was killed |
| 40 | did not finish in 120 s (killed after consuming over 100 CPU-s) | over 100 s and climbing |
| 100 | did not finish after about 19 minutes wall (killed) | over 1,137 CPU-s |
| 300 | did not finish after about 45 minutes wall (killed) | over 1,846 CPU-s |

Two different things are visible here, and this machine does not let them be told apart cleanly:

- Up to `SIM_US`=20-25, both wall time and actual CPU time are small and grow roughly with `SIM_US`
  itself -- unremarkable.
- Past that point, wall time explodes, but **not consistently against CPU time**: the `SIM_US`=30
  run burned only 0.18 CPU-s across a full 60 wall-seconds (almost entirely *waiting*, not
  computing) before being killed, while the `SIM_US`=40/100/300 runs burned real CPU in close to
  step with their wall time (genuinely computing, not waiting) for as long as they were left
  running. `Get-Process`/`ps` throughout this WP (not just this measurement) showed
  three to five other `vvp`/`yosys` processes active on this machine at any given time, exactly the
  situation 4.2 already flagged for the same reason. A process that is sometimes CPU-starved and
  sometimes not, on the same command, at different points within an hour, is a symptom of that
  contention, not of `SIM_US` itself crossing some threshold in the design.

**What this does and does not rule out.** It does not rule out a genuine superlinear cost inside the
design or testbench past `SIM_US`~30 -- the CPU-bound runs (40/100/300) show real computation
consuming far more time than a linear extrapolation from the `SIM_US`=10-25 baseline would predict
(`SIM_US`=100 at over 1,137 CPU-s against an approximately 0.5 CPU-s linear extrapolation from
`SIM_US`=10's 0.05 CPU-s -- over 2,000x). It does rule out this WP's own memory rebalance as the
cause (simulation cost of a `reg` array does not depend on how it later synthesises), and it does
rule out $display volume (every $display in `tb_h1_link_rx.v` beyond the handful of fixed one-shot
messages already seen in 4.2's own output is behind an `ifdef TB_DEBUG`/`TB_HEARTBEAT` neither
`tools/check.sh` nor `run_long.sh` defines). Nothing read in `tb_h1_link_rx.v` or the vendored
`sim/h1_link_rx/hl2/*.v` sender (rawstream.v and its send chain) contains an unbounded loop, a
growing array or queue, or any construct whose *per-cycle* cost should increase as simulated time
advances -- every process there does a fixed amount of work per clock edge. Given that, and given
this machine's confirmed heavy concurrent load throughout, the most likely explanation is still
contention rather than an algorithmic defect, but the time available for this work did not stretch to
proving it either way with a clean, uncontended measurement -- exactly the position 4.2 was already
in. **Recommendation for whoever runs this next**: repeat the `SIM_US`=40/100 measurements on a
quiet machine (`Get-Process`/`ps` showing no other `vvp`/`yosys` activity) before spending more time
on this; if the same blow-up reproduces with no contention, that is real and worth a proper profiler
(`vvp -profile`, or bisecting `tb_h1_link_rx.v`'s periodic activity -- the discovery-request loop and
the 50 ppm-offset far-end clock are the two things in this testbench whose behaviour actually depends
on how much simulated time has passed) rather than more guessing.

Given the above, **the full 20 ms run was not attempted** in this work: even the CPU-bound
`SIM_US`=300 measurement alone consumed more of this WP's time budget than a full, successful run
would need if `SIM_US`=20's ~0.06 CPU-s/20 us rate held throughout (about 0.06 CPU-s x 1,000 = 60
CPU-s for 20 ms, well under a minute) -- but that rate visibly does not hold past `SIM_US`~30, and
this work cannot yet say by how much, or why.

### 4.6 The 20 ms run: why it never finished, what was fixed, results

**Cause.** Every run hung at the same point, 74.8 us of simulated time, in an endless loop that
never advanced time (single-stepping `vvp`'s scheduler at that instant shows the same handful of
gates re-evaluating forever). Runs of `SIM_US` up to 25 finished only because they ended before
74.8 us. Two RTL bugs combined:

1. **The gap filler was too slow.** It popped one sample from the sample FIFO, waited a cycle for
   it, handled it, and only then popped the next: three `clk_dsp` cycles per sample, 50 M samples/s,
   against a stream of 76.8 M samples/s. The sample FIFO (1,024 words) therefore filled a few frames
   into any stream. Fixed in `gap_filler.v` (1.7): pops go out ahead into a 4-word queue, one
   sample per cycle, 150 M/s.
2. **The FIFO's full flag was a combinational loop.** `cdc_sample_fifo.v` computed `wr_full` from
   the write pointer *after* the write that `wr_full` itself gates. With 1,023 words stored and a
   write pending, it has no stable value: full blocks the write, so it is not full, so the write
   goes ahead, so it is full. That is the zero-time loop the simulator spun in. Fixed: `wr_full`
   now depends only on registers and on `wr_en` (a register in both callers), and the write itself
   is gated by a separate "full now" flag. The same loop was in the testbench's stand-in for the
   HL2's `dcfifo` (`dcfifo_sim_stub.v`); fixed the same way there.

**Hardware consequence: both were real design bugs**, not simulation artefacts.

- In the FPGA the full-flag loop is a ring oscillator. Whenever the sample FIFO fills, the write
  pointer and the memory write enable capture arbitrary mixes of old and new values, corrupting the
  FIFO. yosys says so: `tools/yosys_res.sh hl2_link_rx_top` on the old RTL warns "found logic loop
  in module ... cdc_sample_fifo" for both FIFOs and finds 2 loops (SCCs) in the design; on the fixed
  RTL it finds 0.
- The slow gap filler alone means the board could never have kept up with the HL2's stream: the
  sample FIFO fills within about 75 us, the ring drain stalls, later frames are dropped
  (`raw_frame_buffer.v` drops a commit that arrives while the previous frame is still draining), and
  the output turns into zero fill. With the loop on top, the FIFO would be corrupted as well.

**Found on the way, also fixed** (each showed up once the run went further; each has a comment at
its fix site):

- `raw_frame_buffer.v` lost one sample every time a full sample FIFO stalled it. The memory read is
  registered, so by the time a fetched word appears `dp` has already moved past it, and holding `dp`
  does not keep that word. It is now parked in a one-word hold register (1.5). Shown with a 256-word
  FIFO over 100 us of stream: the old code lost 279 samples (pattern errors, and 1,247 fill samples
  instead of 968); the new code loses none. `tb_h1_link_rx_backpressure.v` now runs this case in
  `tools/check.sh` (the FIFO is full for 557 `clk_rx` cycles during the fill). With the old FIFO
  that run hangs; with the old drain it fails.
- `cpu_rx_ring.v` raised `irq_pkt_rx` and moved `wr_ptr` one cycle before the length word was in
  memory (the write port is registered, so a write lands one cycle after it is issued). A reader
  reacting on the next cycle read an unwritten length word. Both now move one cycle later (1.6). A
  CPU reading over AHB after an interrupt would not have hit this; a faster reader would.
- The testbench's `timescale 1ps / 1fs` was at the top of the file, before the includes. Each
  included file sets its own `timescale 1ns / 1ps`, so the testbench really ran in nanoseconds: all
  its delays, written in picoseconds, were 1,000x too long (clocks at 125 kHz, 76.8 kHz and
  150 kHz). The ratios were right, so the design saw the same thing, but every printed time was in
  the wrong unit. Moved after the includes.
- `#(sim_us * 1_000_000)` was 32-bit integer arithmetic. It overflows above 2,147 us and was
  negative at 20,000, so even without the hang the 20 ms run could never have ended. Now 64-bit.
- The testbench's `CHECK` macro passed when its condition was X (`if (!(cond))`). That is how a
  CPU-ring length word read back as X went unnoticed. Now `!== 1'b1`.
- Discovery requests every 2.4 us (copied from `tb_rawstream.sv`) took about 14 % of the line. At
  N = 968 the raw stream alone takes 98 % (PROTOCOL.md 5.7), so the far end's FIFO grew by about 10
  samples/us and overflowed after about 1.5 ms. That is correct HL2 behaviour (PROTOCOL.md 5.6),
  but the stub `dcfifo` then read one word past empty during the flush (its `rdempty` ignored the
  read made in the same cycle), and the far end stayed in its flush state for good. Discovery
  requests are now every 200 us, the stub's read side is fixed, and the test checks that the far end
  never overflowed.
- The CPU-ring entry is now read back straight after it is written. Read at the end of a long run,
  as before, the 4 KB ring had wrapped and the slot held another frame.

**Resources after the fixes** (`tools/yosys_res.sh hl2_link_rx_top`, same measure as 4.4): logic
1,814, registers 1,318, BSRAM 9 -- against 1,865 / 1,296 / 9 before, all still inside 4.4's limits.

**Checks tightened, none weakened**: exactly 1 CRC error, exactly 1 gap event, 0 resyncs, exactly
968 fill samples both at the DUT's counter and at the output, real samples out equal to good frames
x 968 (no sample lost or duplicated anywhere), far end never overflowed. A 40 us settle after the
stream stops lets these be exact at any `SIM_US`, so the default `check.sh` run checks them too.

**20 ms results** (`sim/h1_link_rx/run_long.sh`, `SIM_US` = 20,000; times in fs):

```
t=27968000000: injecting a bit error at frame byte offset 300
discovery reply in CPU ring: length=102 first bytes=02 00 00 00
t=20052268000000: irq_safety_change fired, safety_byte=81
samples_checked=1539120 fill_samples=968 raw_frames=1589 other_frames=101 crc_errors=1
gap_events=1 gap_samples=968 resync_events=0 ring_frames=101 ring_dropped=0
PASS
```

Against the PLAN.md H1 done-test, with the far end's ADC clock 50 ppm fast throughout:

- **Every sample equals its index mod 4,096 over 20 ms**: 1,539,120 samples checked, 0 mismatches.
  That is exactly 1,589 good frames x 968 real samples plus the 968 fill samples: nothing lost or
  duplicated.
- **A flipped-bit frame is dropped and replaced by exactly N zeros**: 1 CRC failure, 1 gap event,
  exactly 968 zero samples at the output, 0 resyncs.
- **A discovery reply lands in the CPU ring**: length 102 bytes, starting with this end's MAC
  address.
- **A safety-byte change raises the interrupt**: `irq_safety_change` fired within one frame period
  of the change, and the register reads 0x81.

**Run time**: **207 CPU-seconds** for `vvp` (316 s wall, on a machine running other
simulations at the same time), about 10 CPU-seconds per simulated millisecond, measured from the
Windows process's own CPU time. `run_long.sh` now prints this figure itself. Nothing needed making
cheaper.
