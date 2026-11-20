<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# S1: `tr-hl2` (docs/PLAN.md)

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

`fw/tr-hl2` -- HL2 protocol: discovery, register writes, start/stop, the register bridge
(Etherbone) and I2C over it, the transmit-safety byte, N2ADR filter selection, and a minimal
DHCP server for the HL2 link. `no_std` core with a `std` feature (on by default, so plain
`cargo test` builds and runs the PC path) for the PC networking used here.

Wire format: `docs/rawfront/PROTOCOL.md` and `software/rawstream/rawcap/src/protocol.rs` in the
Hermes-Lite2 repo (`hl2-rawfront-release` branch, local worktree
`G:/proj/worktrees/Hermes-Lite2-hl2-rawfront-release`).

## What's implemented

| Module | Content |
|---|---|
| `protocol` | Wire format core: discovery request/reply, start/stop, port-1025 register write, raw-frame header parse (versions 1-3), 12-bit sample unpacking. Ported from rawcap's `protocol.rs` and trimmed to what S1 needs (no TX-frame building: S1 never sends TX frames) |
| `bridge` | Register/memory bridge (Etherbone subset, PROTOCOL.md section 8): packet build/parse on caller buffers (no allocation), status-block and front-end-register-block address constants, I2C_XFER encode/decode |
| `filter` | N2ADR filter board control (ARCHITECTURE.md section 8): register-0x00 bit constants, Quisk's per-band table, the MCP23008 I2C address/register for reading the output latch back |
| `dhcp` | Minimal one-lease DHCP server (ARCHITECTURE.md section 3.1: Tang 10.99.0.1, HL2 10.99.0.2). Pure packet parsing/building, no socket -- host-tested only, not run against the live HL2 here (see "DHCP" below) |
| `pc` (feature `std`) | Everything that needs a socket: discovery, `Hl2Client` (register writes, start/stop), `BridgeClient` (Etherbone + I2C read/probe, polls `I2C_STATUS` for completion), `capture` (two-thread stream receiver with sequence/index gap counting), `goertzel` (single-frequency power estimate, no FFT dependency, for the AM-band level check) |
| `src/bin/hl2ctl.rs` | Manual test tool: `discover`, `status`, `stream`, `filter`, `amband`, `capture`, `done-test` subcommands |
| `tests/hardware.rs` | The same done-test steps as `#[ignore]`d `cargo test` cases, for scripting once the board is on the bench |

`capture` (added 2026-09-25, alongside `protocol::rx_gain_value`/`Hl2Client::set_rx_gain_db` for
register 0x0A, RX gain -12 to +48 dB) sets RX gain, runs the same capture path as `stream`/
`amband`, and writes the raw samples to a flat little-endian `i16` file -- used for the
noise-floor references in `captures/` (gitignored, not part of the done-test).

32 host tests pass (`cargo test -p tr-hl2`); the no_std core also cross-builds cleanly for
`riscv32imafc-unknown-none-elf` with `--no-default-features` (not part of `tools/check.sh` yet --
`tr-hl2` isn't wired into `tr-fabric`/`tr-app` in this work package, so check.sh's cross-build
step doesn't need to cover it, but the crate is ready for that wiring).

## Safety

Enforced in code, not just by convention:

- **No function anywhere in this crate builds a write to `TX_PERMIT`** (bridge front-end block
  offset 0x04, the only register that can request the transmit key bit).
  `bridge::build_write_read` also refuses (`None`) any write whose address range touches it, as a
  second, independent check -- see `bridge.rs` tests `refuses_tx_permit_write`.
- `pc::client::Hl2Client::write_command_register` refuses (`PermissionDenied`) any write to
  register 0x31 (duplex) that sets the real-DAC bit (bit 1) -- see `pc/client.rs` test
  `refuses_real_dac_bit`. Echo mode (bit 2) and the plain duplex-enable bit (bit 0, virtual DAC)
  are allowed: neither drives the AD9866 transmit DAC or a PA/relay output.
- No function reaches the flash-sector interface (bridge address `0x4003_0000`) or the boot
  ROM's gdb/console/flash datagrams (PROTOCOL.md section 11) at all.
- Nothing here flashes or reconfigures HL2 gateware.

## How to run

```sh
cd fw
cargo build --release -p tr-hl2 --bin hl2ctl
```

Discover the HL2 (broadcasts from the given local interface address):

```sh
target/release/hl2ctl.exe discover --iface-ip <this PC's IP on the HL2 link>
```

Then, with the HL2's IP from that (`<hl2-ip>`) and the same local interface IP (`<iface-ip>`):

```sh
target/release/hl2ctl.exe status    --ip <hl2-ip>
target/release/hl2ctl.exe stream    --ip <hl2-ip> --iface-ip <iface-ip> --seconds 10
target/release/hl2ctl.exe filter    --ip <hl2-ip> --band 80m
target/release/hl2ctl.exe amband    --ip <hl2-ip> --iface-ip <iface-ip> --seconds 0.3
target/release/hl2ctl.exe capture   --ip <hl2-ip> --iface-ip <iface-ip> --out <file> --seconds 3 --gain-db <db>
target/release/hl2ctl.exe done-test --ip <hl2-ip> --iface-ip <iface-ip>   # runs all of the above except capture
```

Or as `cargo test`-style cases once the board is reachable:

```sh
HL2_IP=<hl2-ip> HL2_IFACE_IP=<iface-ip> cargo test -p tr-hl2 -- --ignored --nocapture
```

`--release` matters for `stream`/`amband`/`done-test`: the receive path and the Goertzel AM-band
analysis are real-time/CPU-bound at 76.8 Msps and a debug build can fall behind.

If frames are lost that a fresh `discover`+`status` shows the HL2 itself didn't report losing
(`hl2_overflow_frames`/`hl2_gap_frames` in the `stream` output), check the NIC settings in
`docs/rawfront/TOOLCHAIN.md` section 8 (jumbo frames 9014, flow control off, high-performance
power plan) -- the settings were not applied or verified by this work (`nic_setup.ps1` changes system network settings).

## Live test results (2026-09-25, link up)

The PC's "Ethernet" adapter (Realtek 2.5GbE, link-local address) came up at 1 Gbps, HL2
powered on, no antenna connected. `discover` found it:

```
hl2ctl: found 169.254.19.221 mac 00:1c:c0:00:00:01 gateware 74.2 image-marker 0xD1 (raw front-end) receivers 0 board-id 5 stopped
```

**Gateware check (before anything else ran):** major.minor 74.2, image marker `0xD1`. That is the
raw front-end release image (`is_rawfront_image()` true; stock/factory images report marker 0 and
4 receivers, PROTOCOL.md section 2) -- confirmed before running any of the done-test steps, per
the task's stop-and-report condition. Safe to proceed.

`hl2ctl done-test --ip 169.254.19.221 --iface-ip 169.254.202.183`:

| Done-test item | Result |
|---|---|
| Status read | **PASS** -- status block ID matches "HL2B", capabilities 0x7C (raw=1 duplex=1 aux=1 cpu=1 frontend-block=1), transmit-safety byte 0x01, ILK_STATUS all clear (tx_on=0, pa_dac_on=0, trip_latched=0) |
| 10 s stream, 0 gaps | **FAIL** (gaps present, see below) |
| Filter bits written + MCP23008 latch read back over I2C | **PASS** -- wrote register 0x00 = 0x00840000 (80 m), MCP23008 OLAT read back 0b1000010, matched; write-off readback 0b0000000 also matched |
| AM-band level, register bit 23 on vs off | Ran; no firm reading -- see below |

**10 s stream -- why it fails, and what it isn't:** three separate runs (`stream`, the
`cargo test --ignored` hardware test, and inside `done-test`) each lost 700-1,350 frames out of
~127,000-128,000 (roughly 0.5-1%), all with `hl2_overflow_frames=0` and `hl2_gap_frames=0` --
meaning the HL2 itself did not report losing or overflowing those frames. Checked against the
NIC counters (`nic_setup.ps1 -Counters`): the adapter's own `ReceivedDiscardedPackets` counter
rose by the same number as `lost_frames` in every run, and a dry run of `nic_setup.ps1` shows
**Receive Buffers = 512** (not the driver maximum) with everything else (jumbo frame 9014, flow
control disabled) already correct. This matches TOOLCHAIN.md section 8's own note almost exactly:
"On one PCIe Realtek gigabit card the receive ring (512 buffers) overflowed and lost 2-4% of
frames." **This is not a `tr-hl2` bug** -- the socket already requests a 32 MB `SO_RCVBUF` and the
receive path is a dedicated non-blocking thread; the drop happens in the NIC driver before any
application code sees the packet. The fix is `nic_setup.ps1 -AdapterName "Ethernet" -Apply` from
an **elevated** PowerShell to raise Receive Buffers to the driver maximum (and, separately, the
Windows power plan is "Balanced" here, not "High performance" as TOOLCHAIN.md recommends) -- both
are system-settings changes left to the owner to run.

**AM-band level, bit 23:** two readings, and they disagree, which is itself the expected outcome
with no antenna connected:

- Standalone `amband --seconds 0.3`: AM broadcast band (0.6-1.6 MHz) HPF-off -72.5 dB, HPF-on
  -69.2 dB, delta +3.3 dB -- read as "AM band is STRONGER with bit 23 on" (bit 23 = high-pass
  bypassed when set).
- The same test inside `done-test` (run moments later): HPF-off -71.6 dB, HPF-on -71.4 dB, delta
  +0.2 dB -- under the tool's 3 dB measurable floor, reported as "likely unmeasurable with no
  antenna connected."

Both are noise-floor measurements (no antenna, no real RF into the receiver), and the delta swings
between a clear 3+ dB reading and near-zero from one 0.3 s capture to the next. **ARCHITECTURE.md
section 8's high-pass polarity question stays open** -- this needs an antenna and a real signal
(or at least a longer, averaged capture) to settle, exactly as the task anticipated might happen.

**Not a fabricated pass**: the summary line above is `hl2ctl`'s own PASS/FAIL text, unedited.

## Noise-floor captures

Two raw captures saved for later offline use (`fw/tr-hl2/src/bin/hl2ctl.rs`'s new `capture`
subcommand, RX gain register 0x0A via `protocol::rx_gain_value`/`Hl2Client::set_rx_gain_db`), no
antenna connected, into `captures/` (gitignored, see `captures/README.md` for the full table):

| File | RX gain | Samples written | Frames lost |
|---|---|---|---|
| `noisefloor_gain-12db_3s.bin` | -12 dB (minimum) | 149,343,232 | 13,551 |
| `noisefloor_gain+48db_3s.bin` | +48 dB (maximum) | 155,782,704 | 12,138 |

Both show the same NIC receive-ring loss as the stream test above (confirmed against
`ReceivedDiscardedPackets`), so the files have gaps rather than being one continuous run -- fine
for a noise-floor level or FFT check, not gap-free. 582 MB total, well under the 2 GB budget.

## DHCP

ARCHITECTURE.md section 3.1 describes the DHCP server as board firmware's job (giving the HL2 an
address within about a second of power-up, instead of the ~15 s link-local fallback); it isn't
something the PC side of S1 needs to run, since on a PC the HL2 gets a link-local address on its
own (as seen above -- the PC's own link-local address came up the same way once the link was
up). `dhcp::DhcpServer` is implemented and host-tested (parse a hand-built DISCOVER/REQUEST,
check the OFFER/ACK bytes) so it's ready for `tr-fabric`/`tr-app` to drive over a UDP socket on
the board; it was not exercised against the real HL2 here, matching the PLAN done-test list
(discovery/DHCP/streaming/etc. items are all "on the real HL2" for status/stream/filter/AM-band
specifically, not DHCP).
