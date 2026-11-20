<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# WP C2: stage-0 loader

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

What `fw/tr-loader`, `fw/tr-image`, `fw/tr-loader-send`, `fw/tr-loader-testfw` and `xtask image`
implement (docs/PLAN.md WP C2). Follows docs/C1_AE350.md's convention: every fact this WP depends
on that is not actually stated in a Gowin/Andes document is marked **NOT VERIFIED** and repeated
in [Unverified and assumed facts](#unverified-and-assumed-facts-confirm-on-the-board). Checked
2026-09-25.

## Sources

| Key | Source |
|---|---|
| MUG1029 | Gowin RiscV_AE350_SOC Software Programming Manual MUG1029-1.3E. Chapter 10 ("SPI") was fetched and converted to text for this WP (as docs/C1_AE350.md's MUG1029 entry describes doing for its own chapters); not committed, see docs/BOARD.md on redistribution. Table/section numbers below are from that chapter. |
| BOARD | docs/BOARD.md (flash chip count/size, SPI base address, reset vector) |
| C1 | docs/C1_AE350.md (`tr-ae350`: UART/PLIC/timer drivers and the QEMU vs. AE350 board split this WP reuses) |
| ARCH | docs/ARCHITECTURE.md section 5.4 (memory map: flash region, DDR3 code region) |
| SPI-NOR | The industry-standard SPI NOR flash command set (write-enable 0x06, read-status 0x05, page-program 0x02, 64 KiB block-erase 0xD8) -- originally ST's M25Pxx, now shared by essentially every SPI NOR part (Winbond, GigaDevice, Macronix, ISSI, ...). Not a Gowin/Andes document; MUG1029 chapter 10 documents the *controller* that issues these bytes, never the flash-side opcodes themselves. |

## What was built

- `fw/tr-image`: the boot image format (header + CRC32), `no_std` by default with a `std` feature
  for host tooling. Host-tested (`cargo test`).
- `xtask image` (`fw/xtask/src/image.rs`): packs a built RV32 ELF (or an already-flat binary)
  into a `tr-image`-format file.
- `fw/tr-loader-layout` (WP LS6): the flash layout, the CPU-to-chip address mapping, the erase/write guard and the
  shared erase/write loops, with host tests on a model chip.
- `fw/tr-loader`: the stage-0 loader itself -- `no_std`, `board-ae350`/`board-qemu` features
  mirroring `tr-ae350`. `protocol.rs` (UART framing, board-agnostic), `layout.rs` (flash/DDR3
  address constants, per board), `flash.rs`/`settings.rs` (board-ae350 only: the SPI flash
  controller driver and the A/B active-slot record). `src/bin/stage0.rs` is the actual boot entry
  point.
- `fw/tr-loader-send`: PC-side sender (`std`), talks to either a real serial port or (for the
  QEMU done-test) a raw TCP socket standing in for the emulated UART.
- `fw/tr-loader-testfw`: a QEMU-only test payload (`fw/tr-loader-testfw/src/bin/payload.rs`) used
  only by `tools/qemu_c2.sh`.
- `tools/qemu_c2.sh`: the done-test, wired into `tools/check.sh`.

## Image format

`fw/tr-image/src/lib.rs`. A 28-byte little-endian header immediately followed by the payload:

| Offset | Field | Notes |
|---|---|---|
| 0 | `magic` (u32) | `u32::from_le_bytes(*b"TRLD")`, so a hex dump of a packed file's first 4 bytes reads "TRLD" |
| 4 | `version` (u16) | 1 |
| 6 | `flags` (u16) | reserved, 0 |
| 8 | `load_addr` (u32) | destination address the payload is copied to |
| 12 | `entry` (u32) | address execution jumps to (usually `load_addr`) |
| 16 | `length` (u32) | payload length in bytes |
| 20 | `payload_crc32` (u32) | CRC32 of the payload |
| 24 | `header_crc32` (u32) | CRC32 of bytes 0..24 |

CRC32 is the standard reflected algorithm (polynomial 0xEDB88320, init/final XOR 0xFFFFFFFF) --
the same one zlib/gzip/PNG/Ethernet FCS use, checkable against any of those tools; not a
fpga-sdr-specific choice. A small `const fn`-built 256-entry table, no external crate.

Not encrypted or signed (`flags` is reserved for that later, per `tr_image::ImageHeader`'s doc
comment) -- out of scope for this WP; the owner has not asked for it and nothing in
docs/DECISIONS.md requires it yet.

## Packing an image

```sh
cd fw
cargo run -p xtask -- image --input target/riscv32imafc-unknown-none-elf/debug/some_binary \
    --output some_binary.img
# or, for a flat (non-ELF) input, --load-addr/--entry are required (there is no header to read
# them from):
cargo run -p xtask -- image --input some.bin --load-addr 0x80400000 --entry 0x80400000 \
    --output some.img
```

For an ELF input, `--load-addr`/`--entry` default to the lowest `PT_LOAD` segment's address and
the ELF entry point. ELF flattening (concatenating every `PT_LOAD` segment's file contents at
their address, zero-filling gaps -- the same thing `objcopy -O binary` does) is implemented with
the `object` crate (pure Rust; this repo's toolchain does not install `llvm-tools-preview`, and
adding a second way to get a flat binary -- shelling out to `objcopy`/`llvm-objcopy` -- was worse
than the one extra crates.io dependency, which `xtask` already had a precedent for: `toml`,
`serde`).

## Protocol

Implemented in `fw/tr-loader/src/protocol.rs`; this section is the wire-level spec it follows.

**Entry: a UART timeout window, not a button or strap.** At every stage-0 start, before doing
anything else observable, the loader waits up to 2 seconds (5 on board-qemu, see
`HANDSHAKE_WINDOW_MS`) for the host to send the 4 sync bytes (`protocol::SYNC`,
`[0xA5, 0x5A, 0xC3, 0x3C]` -- deliberately not `"TRLD"`, see
["Fixing `tools/qemu_c2.sh` flakiness"](#fixing-toolsqemu_c2sh-flakiness-under-host-cpu-load-branch-c2-flaky)
below) on the UART. If they arrive in time, it enters loader mode. If not (real hardware only), it
falls back to loading the active flash slot.

**A gated handshake, not "fire and forget"** (branch `c2-sync`, fixing a start-up race found the
same way the "Fixing `tools/qemu_c2.sh` flakiness" bugs below were -- running `tools/qemu_c2.sh`
repeatedly under host CPU load): `fw/tr-loader-send` used to write the sync bytes and the whole
image the instant its
transport connected, with nothing to tell it the loader was actually there to read them yet. On a
real board that races a human starting the tool before (or right as) they reset the board; under
QEMU it is even more certain to lose, since a TCP connect to QEMU's `-chardev socket` succeeds as
soon as the listener is up, well before the guest CPU has booted far enough to execute
`bin/stage0.rs::main`'s `con.init(...)` and reach its receive loop -- bytes written before that are
simply gone, and the loader (having never seen them) just re-offers the handshake every
`HANDSHAKE_WINDOW_MS` forever, logged as repeated "no handshake seen" lines. This was a start-up
race, not a protocol bug, so the fix is in the host tool, not (only) the test script:

- The loader appends a fixed token, `protocol::PROMPT_MARKER` (`"SYNC-PROMPT"`), to every
  handshake-prompt line it prints (the "send the sync bytes... within Nms" line, re-printed every
  `HANDSHAKE_WINDOW_MS` while no handshake has completed).
- The loader prints a fixed acknowledgement line, `protocol::ACK_MARKER` (`"READY"`), the instant
  `wait_for_handshake` actually matches all 4 sync bytes -- before it starts polling for the image
  header.
- `tr-loader-send` now waits to see `PROMPT_MARKER` before sending the sync bytes at all (so it
  never writes into the dead time before the loader is polling), then waits to see `ACK_MARKER`
  before sending the image. If a fresh `PROMPT_MARKER` shows up while it is still waiting for
  `ACK_MARKER` -- the loader looped back without ever matching the sync bytes it was sent -- it
  re-sends the sync bytes on that new prompt rather than waiting out the whole handshake budget on
  one lost attempt. An overall `--handshake-timeout-secs` (default 30s) bounds the whole wait with
  a clear error ("no \"READY\" acknowledgement from the loader within Ns...") if the loader never
  answers at all (wrong port/device, loader not running, wiring fault).
- `PROMPT_MARKER`/`ACK_MARKER` are duplicated as matching constants in `protocol.rs` and
  `tr-loader-send/src/main.rs`, the same way `SYNC` already was and for the same reason:
  `tr-loader` is `no_std`/board-only and cannot be a normal dependency of a host `std` binary.
- Separately, on a heavily loaded host the transport connection itself was sometimes seen to
  accept and then immediately reset (a Windows "An existing connection was forcibly closed by the
  remote host" / os error 10054) before a single byte of the loader's prompt had been read back --
  a transient connection-level failure, not a protocol one. `tr-loader-send` now reconnects
  (`handshake`/`try_handshake` in `main.rs`) and starts the prompt/ack wait over whenever this
  happens *before* `ACK_MARKER` has been seen, still bounded by the same
  `--handshake-timeout-secs`. This is always safe pre-ack, since nothing has been written to the
  wire yet that the loader could be mid-way through parsing; a connection failure *after* the image
  has been sent is not retried the same way (see `run`'s own comment in `main.rs`), since the
  loader has no way to tell a resumed connection from a second, overlapping transfer.

This does not change the wire protocol once the handshake has started -- `SYNC`, the header/payload
framing, and the run/flash command byte are all unchanged; only the timing of *when*, and how
persistently, the host is allowed to start sending is different.

Why a timeout window rather than one of the board's 4 buttons or a strap pin: docs/BOARD.md lists
the buttons ("4 buttons, 6 LEDs, 3 PMOD headers... (DOCK, WIKI)") but does not give their GPIO pin
assignments -- wiring stage-0 to a specific button now would add another **NOT VERIFIED** hardware
dependency purely for this WP's convenience, on top of the ones already listed in
docs/C1_AE350.md. The UART timeout needs nothing beyond UART2, which WP C1 already implemented and
confirmed under QEMU. It is also identically testable on both QEMU and the real board (the same
code path, not "works on QEMU, unverified on hardware"), whereas a button/strap can only ever be
exercised on the real board. Finally, it is not the *only* recovery path: normal boot's own CRC
check on the active flash slot (see [Flash layout](#flash-layout)) already falls back to offering
the handshake again if the flash image is bad, so a button is not needed as a "the firmware is
broken" escape hatch either. A button/strap could be added later, in addition, once BOARD.md's
GPIO facts are confirmed (PLAN WP B1) -- this WP does not rule it out, it just does not need it.

2 seconds is a judgement call, not a hardware fact: long enough that a host tool connecting right
as the board/VM boots has no realistic chance of missing it, at the cost of a one-time 2-second
delay on every cold boot with nothing attached to the UART. `HANDSHAKE_WINDOW_MS` in
`bin/stage0.rs` is where to change it.

**Receiving an image**, once the handshake has succeeded:

1. Read exactly 28 header bytes, polling (blocking) -- no timeout past this point, since a host
   that has just completed the handshake is assumed to keep sending; a stalled host hangs the
   loader rather than the loader guessing a timeout that might be too short for a slow link.
2. Parse and check the header (`ImageHeader::from_bytes`: magic, header CRC, version, in that
   order -- the first mismatch found is what gets reported).
3. Bounds-check `load_addr`/`length` against the board's destination window (`layout::DEST_BASE`/
   `DEST_LEN` -- DDR3's documented code region on the real board, a QEMU RAM window on QEMU) --
   **before** a single payload byte is written, so a structurally valid but out-of-range header
   cannot write outside that window.
4. Read exactly `length` payload bytes, writing them directly to `load_addr` (no intermediate
   buffer -- both boards' destination is ordinary addressable memory, so there is no need to size
   a buffer to the largest possible image, and no heap is needed either).
5. CRC-check the payload in place. A mismatch is refused with a specific message (e.g. "image
   rejected: payload crc mismatch: header says 0x..., computed 0x...") and the loop returns to
   offering the handshake again -- this is the done-test's "a corrupt image is refused with a
   clear message".
6. Read one command byte: `'R'` (run: jump to `entry` immediately, from RAM) or `'F'` (flash:
   program the image into the inactive flash slot, board-ae350 only -- see
   [Flash layout](#flash-layout)). Anything else is refused the same way a bad CRC is.

The run/flash choice is a **transport-time command byte**, not a header field: it is the sender's
choice for *this transfer*, not a property of the image itself (the same packed file can
legitimately be sent with `'R'` once, during development, and `'F'` later, to install it) --
keeping it out of the header also keeps the header format identical to what ends up stored in a
flash slot (see below).

## Flash layout

**Changed by WP LS6 (2026-10-12).** The first version of this section laid the slots out from chip offset
0 (stage-0 at 0x0, slots at 0x1_0000 and 0x71_0000) on the assumption that the AE350's flash was a chip of
its own. It is not: the board has one SPI flash for both the FPGA bitstream and the processor's program,
the AE350's flash pins are the FPGA's configuration pins, and Gowin's own procedure writes the bitstream at
chip offset 0 and the processor's program at 0x60_0000 (MUG1030 2.6.8 and 3.4.5). A bitstream is 5.04 MiB. **The old layout would have erased the FPGA's
configuration on the first flash write**; nothing had ever written to a board, so nothing was lost.

The layout, the address mapping and the write guard are now the host-tested crate `fw/tr-loader-layout`
(re-exported as `tr_loader::layout`). All offsets are **chip addresses**, the addresses the flash chip itself
is given:

| Region | Chip offset | Size | Written by |
|---|---|---|---|
| FPGA bitstream | 0x00_0000 | 6 MiB (bitstream 5.04 MiB) | Gowin programmer only |
| Stage-0 loader | 0x60_0000 | 64 KiB | Gowin programmer only |
| Image slot A | 0x61_0000 | 4 MiB | the loader (`F` command) |
| Image slot B | 0xA1_0000 | 4 MiB | the loader |
| Settings sector (active slot) | 0xE1_0000 | 64 KiB | the loader |
| free | 0xE2_0000 | 1.87 MiB | nobody |

16 MiB chip (BOARD: 128 Mbit; the loader prints the chip's JEDEC id at start-up, the first real answer).
4 MiB per slot is generous (a whole instrument program of 1.2 MB fits; nothing of ours is
flash-resident yet), and a slot stays on whole 64 KiB erase blocks.

**How the CPU's address maps onto the chip: `CPU = 0x8000_0000 + (chip - 0x60_0000)`.** The processor's
0x8000_0000 (reset vector, memory-mapped flash window) is chip offset 0x60_0000, where the stage-0 loader
is written. This is an inference from Gowin's procedure, not a figure from a manual (an inference that other
AE350 projects on this board make as well). The slots are therefore at CPU 0x8001_0000 (A), 0x8041_0000 (B) and 0x8081_0000
(settings), all inside the 256 MB window. The loader does not rely on it blindly: at start-up it reads 64
bytes of its own code from chip offset 0x60_0000 with the chip's read command and compares them with what
the processor sees at 0x8000_0000, and prints "flash mapping: ... confirmed" or "DIFFERS". If they differ,
images are read by read commands with chip addresses (no mapping needed), and the programmer's address for
the loader is what to look at. Writes and their read-back use chip addresses and read commands only.

**The write guard.** Nothing below chip offset 0x61_0000 can be erased or programmed. Three layers:
(1) `xfer` in `flash.rs`, the one routine that sends a command to the chip, refuses a page-program or
block-erase opcode whose range is not wholly inside 0x61_0000 to 0xE2_0000 (`layout::write_allowed`,
`erase_allowed`); (2) the shared loops `layout::store_image`, `erase_region` and `write_region` check the
whole range before the first block is touched; (3) the slot is chosen by `layout::slot_chip`, which can only
return the two slot addresses. Host tests (`cargo test -p tr-loader-layout`, 14 tests): every 4 KiB step from
offset 0 to the first slot is refused for lengths from one byte to the whole chip; ranges that straddle the
boundary, wrap past 4 GiB or run past the settings sector are refused; a model chip holding a recognisable
bitstream and loader is unchanged after full-slot writes in both slots, after refused writes and after a
write cut off half way; the header is the last program of an image; the stage-0 size equals the linker
script's `FLASH` length; the guard calls are present in the driver source.

**Slot contents are exactly the packed image format**: a slot holds the same 28-byte header immediately
followed by payload bytes that `cargo xtask image` would write to a file, or that `protocol::receive_image`
validates over the UART -- `flash::read_and_validate_slot` (normal boot) runs the same magic/version/CRC
checks `protocol::receive_image` does. The payload is programmed first and the header last, so a write cut
off half way leaves a slot that does not look valid.

**A/B update pattern**: a new image received with the `'F'` command is always written to the *inactive* slot
(`bin/stage0.rs::handle_flash_write`), verified by read commands, and only then does the settings sector's
one-record active-slot flag flip to it. A write that fails partway (power loss, a bad page) leaves the
previously-working slot untouched and still bootable. Normal boot tries the active slot first, then falls
back to the other one if it fails validation, before finally giving up and re-offering the UART handshake
(`bin/stage0.rs::normal_boot_from_flash`).

**Stage-0 never rewrites itself or the bitstream.** How stage-0 and the bitstream first get onto the chip is
the Gowin programmer's job (`programmer_cli --run 54 ... --spiaddr 0x000000` for the bitstream, `--run 56
--mcuFile ... --spiaddr 0x600000` for the loader; tools/ladder_fw.sh prints the commands, never tried).

## Linker layout: XIP, not BUILD_LOAD

`fw/tr-ae350/memory-ae350.x` (WP C1) links a *`BUILD_LOAD`* image: everything, including `.text`,
loaded whole into DDR3 by GDB/eBIOS, per that file's own comment -- appropriate for developing the
main firmware, but not usable for stage-0, which **is** the AE350 reset-vector code (MUG1029 table
16-12: reset vector 0x8000_0000) and must execute directly from flash (XIP) because nothing has
loaded anything into DDR3 yet when it starts. `fw/tr-loader/memory-loader-ae350.x` is therefore a
separate, genuinely different script: `REGION_TEXT`/`REGION_RODATA` point at a `FLASH` region
(`ORIGIN = 0x8000_0000, LENGTH = 64K`), so `.text`/`.rodata`'s load address equals their run
address; `REGION_DATA`/`REGION_BSS`/`REGION_HEAP`/`REGION_STACK` point at DLM
(`0xA020_0000`, 64 KiB, MUG1029 table 3-1) -- one region for all of them, since this crate's own
`.data`/`.bss` are a few bytes and it needs no heap, the same simplification
`fw/tr-ae350/memory-qemu.x` already uses for its single RAM region.

**Two crates in the same dependency graph each providing a linker-searched `memory.x` is a real
footgun** (`tr-ae350`'s own build.rs already owns "the" `memory.x` for every other firmware
binary in this workspace, by design -- see that file's comment): `riscv-rt`'s bundled `link.x`
always does `INCLUDE memory.x`, resolved via whatever `-L` search paths are on the final link
command, in the order given, first match wins. `fw/tr-loader/build.rs` and `fw/tr-ae350/build.rs`
both emit a `memory.x` into their own `OUT_DIR` and both end up on that search path when linking
`stage0` (tr-loader depends on tr-ae350). This was not left to chance: verified empirically before
writing the real linker scripts, by building `tr-loader` with a placeholder `memory.x` at a
distinctive address (`0x8010_0000`) and checking the linked ELF's entry point actually landed
there rather than at either of tr-ae350's own addresses. It did -- the crate whose binary is being
linked gets its own build script's search path searched before its dependencies' -- confirming
`fw/tr-loader`'s own `memory-loader-ae350.x`/`memory-loader-qemu.x` safely take priority. Not
something to rely on by accident in a future crate; if a fourth firmware-binary crate is ever
added, giving it its own `memory.x` should be re-verified the same way, not assumed.

## AE350 SPI controller (`fw/tr-loader/src/flash.rs`)

MUG1029 chapter 10 "SPI". The AE350 has one SPI controller (docs/BOARD.md AE350 table: `SPI
0xF0F0_0000`) that talks to the board's one flash chip -- the same chip that holds the FPGA's bitstream (WP LS6 corrected
the first version, which called it a separate chip; see "Flash layout"). Register offsets (Table 10-2, all relative to
`0xF0F0_0000`): `TRANSFMT` 0x10, `DIRECTIO` 0x14, `TRANSCTRL` 0x20, `CMD` 0x24, `ADDR` 0x28, `DATA`
0x2C, `CTRL` 0x30, `STATUS` 0x34, `MEMCTRL` 0x50 (memory-mapped-read command select, table 10-16 --
not programmed by this WP; see below). `flash.rs`'s constants are a direct transcription of these
and of the `TRANSCTRL` field layout (Table 10-6: `CmdEn` bit 30, `AddrEn` bit 29, `TransMode` bits
27:24, `WrTranCnt` bits 20:12) and `STATUS`'s `SPIActive` bit 0 (Table 10-12).

**Reads are automatic (XIP), writes are manual.** "SPI Memory Access Control Register... defines
the SPI commands for memory-mapped AHB/EILM read accesses" (MUG1029 10.2.2) -- the controller
already answers ordinary CPU loads/instruction-fetches to the flash address range by driving the
bus itself; this is why `flash::read_and_validate_slot` and stage-0's own instruction fetches are
both just plain memory accesses, no `flash.rs` primitives involved. Writing/erasing requires
manually sequencing `CMD`/`ADDR`/`DATA`/`TRANSCTRL` (Table 10-6/10-8/10-9/10-10): set up the
transfer shape, then "a write operation in the SPI Command register triggers an SPI transfer" --
the opcode byte written to `CMD` is what starts the whole transaction.

**The flash-side opcodes (0x06 write-enable, 0x05 read-status, 0x02 page-program, 0xD8 64 KiB
block-erase) are not in MUG1029 at all** -- the controller is generic SPI master hardware; what
bytes it sends is up to software. These are the industry-standard SPI NOR command set (SPI-NOR
source above), the conservative choice given the actual flash part on this board is
**NOT VERIFIED** (docs/BOARD.md "Memory and storage": part number unknown).

**Why part of this runs from RAM.** Driving a manual SPI transaction and the automatic read engine
both use the *same physical SPI pins* to the *same physical chip*; they cannot usefully act at
once. If code still executing from flash (via the automatic engine) calls a function that switches
to manual mode, the next instruction fetch after that call still needs the automatic engine, on a
bus the manual engine was just driving -- the classic XIP self-programming hazard, not specific to
this chip (every XIP-flash MCU vendor's app note gives the same advice). Every function in
`flash.rs` that touches the SPI registers is marked `#[link_section = ".ramfunc"]`; a second
linker script, `fw/tr-loader/ramfunc-ae350.x` (passed as an extra `-T`, merged into `riscv-rt`'s
own `link.x` with the standard `INSERT AFTER .data` directive, since that script -- not this one
-- owns the top-level `SECTIONS` block), places `.ramfunc`'s run address in DLM with its load
address in flash; `flash::copy_ramfunc()` copies it there once, at stage-0 start-up
(`bin/stage0.rs::main`, before anything else), mirroring how `riscv-rt` itself copies `.data`.
Each primitive completes one full, self-contained SPI transaction (asserted, transacted,
deasserted by the hardware on completion) before returning, so the bus is always idle -- safe for
the automatic engine to resume -- by the time control returns to flash-resident orchestration code
between primitive calls.

**Data Merge / FIFO note** (Table 10-10, 10-2.2): the reset default packs 4 bytes into each 32-bit
write to `DATA`; only the first `WrTranCnt` bytes of everything queued are actually clocked onto
the wire for that transaction, and leftovers "stay in the TX FIFO for the next transfer" --
`flash.rs` resets both FIFOs (`CTRL.TXFIFORST`/`RXFIFORST`) before every transaction specifically
to avoid a partially-consumed final word leaking into the next one.

## What ran under QEMU vs. what did not

`tools/qemu_c2.sh` builds stage-0 (`--features board-qemu`) and a tiny test payload
(`fw/tr-loader-testfw`), packs the payload with `cargo xtask image`, and runs two scenarios
against `qemu-system-riscv32 -M virt` with its serial port redirected to a TCP socket
(`-chardev socket`) that `fw/tr-loader-send` connects to in place of a real UART cable. Confirmed,
every run:

- **A valid image sent over the emulated UART is received, CRC-checked, and started**: the sender
  connects, waits for stage-0's "send the sync bytes... SYNC-PROMPT" prompt, sends the sync bytes,
  waits for stage-0's "READY" acknowledgement, then sends a packed image with the `'R'` command
  byte; stage-0 then prints "OK crc, starting at 0x80400000"; the payload (jumped to at that
  address) prints "payload ok" and shuts QEMU down cleanly (the same `board::qemu::exit_pass()`
  mechanism WP C1's smoke test uses).
- **A corrupt image is refused with a clear message**: the same image with its last payload byte
  flipped (the header itself still parses -- magic/header-crc/version all still valid -- so only
  the payload CRC check catches it) produces "image rejected: payload crc mismatch: header says
  0x..., computed 0x...", the payload never runs, and stage-0 loops back to offering the handshake
  again.

### Fixing `tools/qemu_c2.sh` flakiness under host CPU load (branch `c2-flaky`)

This test was found to fail intermittently -- "expected 'payload ok', did not see it" or a valid
image reported as corrupted -- specifically when other work was also loading the PC's CPU, and to
always pass when re-run alone. Reproduced deliberately by running this script repeatedly while
several CPU-hog processes ran in the background. Two distinct, independent bugs were found this
way, both real (not QEMU artifacts), fixed on branch `c2-flaky`:

1. **The handshake sync bytes and the image's own magic number were the same 4 bytes** (`SYNC` in
   `protocol.rs` and `tr_image::MAGIC` were both `"TRLD"`, chosen separately for the same
   "reads as TRLD in a hex dump" reason, without noticing the collision). Under CPU load, this
   loop's own polling can go unscheduled for a while; if a handshake attempt was cut off after
   matching only some of the 4 sync bytes, the unmatched remainder was left in the input stream
   immediately followed by the image's own header -- whose first 4 bytes could then complete a
   *false* sync match on the next attempt, silently misreading everything after it 4 bytes out of
   place (reported as "bad magic", which is what was actually observed). Fixed by giving `SYNC` a
   value (`[0xA5, 0x5A, 0xC3, 0x3C]`) that shares no byte with `MAGIC`, which makes this specific
   false match structurally impossible rather than merely unlikely; `wait_for_handshake` was also
   changed to extend its timeout whenever a byte makes progress on a partial match (an idle
   timeout, not a fixed total budget), as defense in depth against the same kind of premature
   cutoff, with no effect on genuine silence (real hardware's no-host-attached fallback timing is
   unchanged).
2. **The test script reused fixed TCP ports (27001/27002) across runs, and `kill` on this
   Windows/Git-Bash setup does not reliably terminate a native `qemu-system-riscv32.exe`
   process.** The corrupt-image scenario in particular never exits on its own (it is designed to
   loop forever refusing images), so it depends entirely on the script's own `kill` to end -- if
   that silently failed to actually kill the process (observed directly: a process that `kill`
   had already been sent to was still alive and listening one interval later), a later run's QEMU
   would fail to bind that port, or its sender would connect to the wrong, stale QEMU instance --
   possibly one already mid-transfer from an earlier run, i.e. actual byte-stream corruption
   between two unrelated attempts. This is very likely the dominant real-world cause of the
   original bug report (more so than bug 1, which requires a truncated handshake specifically).
   Fixed by deriving each run's two ports from the script's own PID (`$$`) so a stale process left
   over from a previous run can never collide with the current run's ports, and by escalating the
   shutdown sequence (`kill`, then `kill -9`, then `taskkill //F //PID` on that one tracked PID --
   never by image name) so a stuck QEMU process is actually removed rather than merely signaled.
   `--relay-secs` and the post-send poll timeout were also both increased (from 4s/10s to 20s/25s)
   to give a loaded host realistic room to finish before the harness gives up on it.

**Does this matter on real hardware?** Bug 2 is a test-harness-only issue (no analog on real
hardware: a physical board doesn't have a stale QEMU process squatting a TCP port). Bug 1's root
cause -- an ambiguous sync pattern that can accidentally match other data right after a truncated
handshake attempt -- is a genuine protocol design flaw, not QEMU-specific: a real UART can lose or
delay bytes too (a busy host machine, a marginal cable, a driver hiccup), and the old `SYNC`==
`MAGIC` collision would have made a truncated real handshake exactly as capable of falsely
resyncing onto a real image's header. The fix (distinct sync/magic values, idle-based timeout) is
a genuine correctness improvement for real hardware as well, though it was found and is only
exercised via this QEMU test -- WP B3 (real-hardware bring-up) should still re-check the handshake
under real, not emulated, conditions.

**Honesty note on verification**: this fix reduced but had not yet been confirmed to fully
eliminate the failure under sustained heavy CPU load at the time this section was last edited --
see the branch's own commit message and the work package's final report for the actual pass count
achieved and what, if anything, remained open.

**Not run anywhere yet** (real hardware only, PLAN WP B3): everything in `flash.rs`/`settings.rs`
(QEMU's `virt` machine has no SPI flash controller model at all, so this is not "untested", it is
"cannot be tested this way" -- no `#[cfg(feature = "board-qemu")]` variant of these modules
exists, matching `docs/C1_AE350.md`'s `cctl.rs` precedent for the same situation); the real
flash-resident `.text`/`.rodata` XIP execution path (QEMU boots stage-0 as ordinary RAM via
`-kernel`, not from anything resembling flash); the `'F'` (flash-write) protocol command (under
`board-qemu` it is refused outright with "flash-write is board-only, not available under QEMU",
which is itself as far as this WP takes that path in the emulator); the real button/strap-free
UART timeout's actual real-hardware timing (2 seconds is untested against a real terminal's
latency); and how stage-0 itself is first written to the AE350's flash chip (BOARD.md open
question 7, out of scope here).

## Unverified and assumed facts (confirm on the board)

Everything below is used by this WP but is not stated in MUG1029/MUG1031, or is an assumption this
WP made and is flagging rather than silently relying on. None of it blocks C2 (PLAN.md's done-test
only requires the QEMU scenarios above), but all of it should be checked as part of PLAN WP B3:

1. The actual flash chip's opcodes, page size (assumed 256 bytes) and erase granularity (assumed
   to support a 64 KiB block erase) -- part number **NOT VERIFIED** (docs/BOARD.md). If the real
   chip disagrees, `flash.rs`'s constants (`PAGE_SIZE`, `ERASE_SIZE`, the opcode constants) are
   the only things that should need to change.
2. UART2's baud/uclk setup (`bin/stage0.rs` reuses the same `24_000_000` placeholder
   `fw/tr-app/src/bin/qemu_smoke.rs` does) -- already flagged **NOT VERIFIED** by docs/C1_AE350.md;
   repeated here since stage-0 is the first thing to actually rely on it working at cold boot
   with no PC attached yet, if WP B3 exercises that scenario.
3. That DDR3 is already initialized and usable by the time stage-0 (the very first code to run
   after reset) touches it -- assumed, not found stated outright in MUG1029/MUG1031, but supported
   by `fw/tr-ae350/memory-ae350.x`'s own comment: its `BUILD_LOAD` development flow has GDB load
   code directly into DDR3 *before* any firmware has run, which would not work if DDR3 needed a
   software init sequence first. Treated here as "the Gowin DDR3 IP self-initializes as part of
   FPGA configuration", consistent with WP C1's framing.
4. That code may execute from DLM. MUG1031 describes ILM and DLM as separate local memories
   (instruction vs. data, by name) without stating outright that DLM is execute-capable; this WP
   places `.ramfunc` there anyway (see [AE350 SPI controller](#ae350-spi-controller-fwtr-loadersrcflashrs))
   because it is small, already reserved for stage-0's own stack, and DLM/ILM's exact
   execute-permission distinction (if any -- RV32 without PMP configured does not itself forbid
   executing from any mapped region) is not spelled out anywhere docs/BOARD.md or
   docs/C1_AE350.md cite. If DLM turns out not to be execute-capable on this chip, the fix is
   moving `.ramfunc`'s `>` region from `DLM` to `ILM` (`0xA000_0000`, also 64 KiB, currently
   unused -- see docs/C1_AE350.md's memory map row for it) in `ramfunc-ae350.x`; nothing else
   should need to change.
5. The 2-second handshake window's real-hardware latency budget (a judgement call, see
   [Protocol](#protocol), not a hardware fact to begin with).
6. (WP LS6) That the processor's 0x8000_0000 is chip offset 0x60_0000 (the loader checks it at start-up and says
   so), that the Gowin programmer's `--spiaddr` writes where it is told, the chip's size (16 MiB assumed; the
   JEDEC id is printed), and that the AE350's SPI configuration register reports the FIFO depth as assumed.

## Two possible faults found in review (2026-10-10), fixed by WP LS6 (2026-10-12)

A review of this loader at commit ec04d2b found two possible faults. Both are fixed here (not yet run on a board):

1. **Flash page write may overrun the SPI controller's transmit buffer.** The first `flash.rs` put a whole
   256-byte page into the controller's transmit FIFO before it started the transfer. Gowin's AE350 manual gives
   the FIFO depth as "configuration dependent", from 2 words up (MUG1029 table 10-21). *Fix:* `flash::chunk()`
   reads the configuration register (0x7C) and a transfer never holds more bytes than the smaller of the two
   FIFOs (at most 64); `layout::write_region` cuts a write into such pieces that never cross a page. The
   transfer routine, the write-enable check (status bit 1), the bounded waits and the JEDEC id are in
   `fw/tr-loader/src/flash.rs`.
2. **The start-up function may not be in flash.** With the original linker scripts `_start_rust` (section
   `.init.rust`) landed in the data memory (DLM) with no copy in flash. *Fix:* `fw/tr-loader/init-rust-ae350.x`
   keeps the section in flash right after `.text`; build.rs passes it for board-ae350. Checked with objdump on the release build: `_start` 0x8000_0000, `_start_rust`
   0x8000_570c (flash), `.rodata` after it, only the SPI routines (`.ramfunc`, 440 bytes, load address
   0x8000_6be8) at DLM 0xA020_0000 with no call back into flash; code and constants 27.6 KiB of the 64 KiB.
   `fw/tr-ladder` uses the same script.
