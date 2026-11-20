<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# WP P2: the FT8 firmware

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Branch `p2`. PLAN priority item 5 (C3 drivers for the FT8 path, S14 FT8 encoder, FT8 screen, station
logic, one image). **Nothing here has run on the board or against the HL2.** Section 5 has the results.

## 1. What existed before this work package

| Crate | State |
|---|---|
| `tr-regs` | Generated register access for 11 blocks, generic over `RegisterSpace`; a one-page mock for host tests |
| `tr-ae350` | Start-up, traps, PLIC, machine timer, UART, cache write-back and invalidate (CSR numbers not confirmed), memory probe. Builds for the board and for QEMU `virt` |
| `tr-fabric` | Only the SFP link driver (`n1.rs`, hand-kept offsets at 0xE80A_0000) |
| `tr-hl2` | HL2 wire format, discovery, command packets, bridge, filter bits, DHCP server logic; `no_std` core. Never keys |
| `tr-modes` | FT8/FT4/WSPR encode to 12 kHz real audio and decode (mfsk-core, vendored); the bit-exact model of the FPGA front end F5-F7 with the CPU half of the decoder behind the `Fabric` trait; the decode scheduler (S17) |
| `tr-net` | smoltcp glue over a `MacRings` trait, SNTP client, UTC clock with slot-boundary arithmetic; host test DHCP + SNTP |
| `tr-gui` | Slint panel at 1920x1080 and 1024x600, software renderer into RGB565, state pushed from a Rust struct. No input handling, no FT8 operating controls; the decode list is display only. "Simulator" = a host test that renders PNGs |
| `tr-app` | Two QEMU test binaries (hello, FP in traps). No firmware |
| `tr-ft8bench` | The CPU half of the decoder and the scheduler under QEMU from recorded traces, with a heap |
| `tr-sim` | Empty stub |

Runs under QEMU today: start-up, UART, timer interrupt, the DSP kernels, the FT8 CPU half from traces.
QEMU `virt` has no fabric: no register window, no Andes cache CSRs.

## 2. What an FT8 radio needs, end to end

1. **HL2 link up**: DHCP answer, discovery, raw mode on (HL2 register 0x30), band filter bits, start. Packets go
   through the CPU ring and transmit queue of the HL2 link; MAC/IP of the HL2 written to `hl2_link`.
2. **Receive**: receiver 0 of the bank tuned to the dial frequency at 48 ksps; back end in SSB mode with a
   100-3,100 Hz channel filter, 12 ksps output into its DDR3 ring, stamped with the HL2 sample index.
3. **Time**: SNTP over the SFP link gives UTC; one paired reading (UTC, HL2 sample index) turns a slot boundary
   into a sample stamp.
4. **Decode**: at 14.2 s into each slot, the slot's 180,000 samples to the decoder; results to the screen and
   the QSO logic.
5. **Operate**: decode list, click to answer, CQ, TX enable (off at start), TX slot parity, TX audio frequency.
6. **Transmit**: message to 79 tones, GFSK at 48 kHz complex baseband into the TX ring (8,192 words, 171 ms, so
   it is fed while it plays), TX mixer at the dial frequency, link framer on. Keying the HL2 is a command to the
   HL2 that `tr-hl2` deliberately does not have.
7. **Show**: Slint into the frame buffer, waterfall window drawn by the logic, audio monitor.

## 3. Gaps found

In the firmware (closed here unless section 5 says otherwise): drivers for every block above; the FT8 encoder
into the TX ring format; the operating screen with input; slot timing, QSO sequence, TX slot choice; the image.

In the logic (not this work package, listed for the owner; details in section 6):

- The FT8 front end page (0xE80D_0000) is a stub that answers its id. F5 is built but not in the chip, F6 and
  F7 are not built. The first board decodes FT8 **in software** from the back end's audio ring.
- The compositor is a stub: the HDMI output shows colour bars, not the Slint frame buffer.
- The SFP link is a stub in the chip top, so no SNTP on the board yet. `n1.rs` has no generated register file.
- The zoom spectrum is not in the chip: the only waterfall is 0-38.4 MHz across the window.
- No register says "the DDR3 bridge has flushed", so the 10 us wait is always taken.

## 4. Design decisions taken here (defaults, marked for the owner)

| Decision | Default taken | Why |
|---|---|---|
| The 10 us rule (MEM_1GB section 3) | No public function moves a pointer the logic follows. `TxRing::push`, `AudioRing::push` and `FrameBuffer::present` write, write the cache back, wait `BRIDGE_FLUSH_US`, then move the pointer | Callers cannot forget it |
| Who may switch the TX path on | `TxPath::arm` takes an `OperatorTxPermit`, which only `OperatorTxPermit::from_operator_action()` makes; the screen's TX button is the one caller. Off at start, off on HL2 trip | The brief's safety rule |
| Keying the HL2 | Not implemented. With TX enabled the firmware fills the TX ring and switches the Tang's TX chain on; the HL2 stays unkeyed and its DAC unselected | Needs the owner's go, with the hardware present |
| Scheduling | One cooperative loop, no embassy yet | Fewest unknowns for the first board run |
| Decoder on the first board | mfsk-core's software pipeline on the operator's receiver only | The FPGA front end is not in the chip |
| Decode start | 14.2 s into the slot, rest of the slot as zeros (WSJT-X's last decode starts at 14.4 s) | Leaves time to answer in the next slot |
| Late TX start | Up to 1.5 s late, the waveform started at the right place in time (the beginning is cut) | A slow decode still gets its answer out |
| AGC for the FT8 receiver | Back end AGC on (its reset value) | Unknown antenna level before the board |
| PC simulator | Headless: host tests render the screen to PNG and send it pointer events. No window | No new dependencies; a window needs Slint's winit backend |
| Operating the board without mouse or keyboard | Keys on the serial console: `t` TX enable, `c` CQ, `h` halt, `s` TX slot, `0`-`9` answer a decode line, `[` `]` band, `-` `+` TX audio frequency | USB is deferred; the screen's controls already take pointer events for later |
| Clock without the network | Typed on the console: `u` and `hhmmss`, then `,` `.` to move it by 0.1 s. Shown in amber as "clock set by hand" | The SFP link is a stub in the chip; FT8 needs the second within the minute to a few tenths |
| Call sign | Build-time `TR_CALL` and `TR_GRID`. Without them the image is N0CALL and its TX switch stays locked | The owner's call is not in the repository |

## 5. What was built, and how it was tested

| Step | State | Where | Tested how |
|---|---|---|---|
| 1. Drivers (C3) | done for the FT8 path | `fw/tr-fabric`: `system`, `hl2link`, `rxbank`, `backend`, `ft8fe`, `tx`, `spectrum`, `video`, `audio`, `mem`, `mock` | 28 host tests on a mock fabric that logs every register write, memory write, cache command and wait in order: ring pointer arithmetic with wrap and a full ring, the write-back / 10 us / pointer order for TX ring, audio ring and frame buffer (and that the checker catches a pointer moved too early), TX path off at start and untouched without a permit, back-end block reader with lost blocks, packet ring across its end and with a nonsense length, register values of every set-up call |
| 2. FT8 encoder (S14, FT8 part) | done | `fw/tr-modes/src/txbb.rs` | 4 host tests: tones against mfsk-core's packer and the Costas blocks; waveform against mfsk-core's own GFSK generator at 48 ksps (correlation above 0.999); upper sideband (level at -f below 2 %); constant envelope; a late start equals the on-time stream sample for sample; all seven messages of a contact (CQ, locator, report, R report, RR73, RRR, 73) in one slot decoded by the receiver's decoder at the sent frequencies. **No WSJT-X vectors in the repository, so not compared with WSJT-X's own output** |
| 3. FT8 screen | done, 1920x1080 only | `fw/tr-gui/ui/ft8_1920x1080.slint`, `ft8_model.slint`, `src/ft8.rs` | Host test renders it with the software renderer (`docs/img/ft8_1920x1080.png`), checks the waterfall rectangle is pure key colour, the decode rows are drawn, and that clicks at the controls arrive as events: TX enable, CQ, halt, TX slot, band, a decode line, a TX frequency from the scale |
| 4. Station logic | done | `fw/tr-station`: `msg`, `qso`, `station`, `keys` | 13 unit tests (message forms, the contact both ways, a caller that starts with a report, repeats and giving up, a repeated R report, console keys, the hand-set clock) and 6 tests in simulated time over two hand-written decode lists in WSJT-X ALL.TXT layout: which message goes out in which slot, a missed answer, a slow decoder (answer starts 0.7 s late with its beginning cut; too slow = one cycle later), the log entry, no transmission without the TX switch or without a clock, a trip stops a running transmission. **The decode lists are written by hand; the repository holds no recorded decodes** |
| 5. One image | board image builds; QEMU twin runs | `fw/tr-app`: `ft8fw` (board), `ft8fw_qemu`, `heap`, `screen`, `ddr`; `fw/tr-station`: `radio`, `selftest` | Host: the loop-back self-test (station logic, encoder, TX ring driver, a simulated chip that plays the ring and writes it back as receiver audio with HL2 stamps, ring reader, slot cut by HL2 time, software decoder): the station's own CQ comes back in the decode list at 1,500 Hz, 0.00 s. QEMU (`fw/tr-app/qemu_p2.sh`): the same function on the target's instruction set, with the Slint screen rendered into two buffers and the two operator clicks sent to the screen. See section 8 |

Not built: the 1024x600 form of the FT8 screen; a windowed PC simulator; FT4.

## 6. What the firmware needs that the chip or the register map does not have

| Need | Why | State today |
|---|---|---|
| **FT8 front-end registers** (`hw/regmap/ft8.toml`): per receiver enable and slot-buffer base; slot boundary as an HL2 sample index; spectrogram ring base and power shift `sh`; sync search band `ia`/`ib`, start, done flag, result buffer address and count; candidate batch: per lane NCO increment, start sample, go, done, baseband buffer address; pass 2: rotation increment, start offset, soft-symbol buffer address; interrupt status | To fetch candidates as `tr_modes::frontend::decode::Fabric` asks for them | Page answers its id only (stub). F5 built, not in the chip; F6, F7 not built. The firmware decodes in software |
| **Compositor** (V2) | The Slint frame buffer and the waterfall window on the monitor | Built and merged (section 10); not yet on the board |
| **SFP link in the chip top**, and its registers in `hw/regmap/` | SNTP time | Stub in the top; `n1.rs` has hand-kept offsets at 0xE80A_0000 |
| **Zoom spectrum in the chip** | A waterfall of the 3 kHz the decoder hears | Not in the chip. The firmware computes the audio waterfall itself (section 10) |
| **"Bridge flushed" status bit** (system page) | To move a ring pointer as soon as the DDR3 bridge has written, instead of always waiting 10 us | Does not exist. At 100 ms of TX ahead the wait costs nothing that matters |
| **Read pointer for the HL2 CPU receive ring** (or a sequence count per frame) | The reader cannot tell a full lap from no new frame | Does not exist; the driver resyncs on a length that makes no sense |
| **TX ring low-water level register** | Low water is "8-word FIFO nearly empty", too late to refill | Fixed in the logic; the firmware does not use the flag and keeps 100 ms queued |
| **HL2 keying** (a command to the HL2, not a Tang register) | To radiate | Deliberately absent from `tr-hl2` and from this firmware |

## 7. What needs the board

- Everything in the chip: the register bus from the AE350, the DDR3 bridge with the rings, the cache commands (their CSR numbers are not confirmed; the image prints the trap address if one is wrong), the UART clock (set `UART_CLOCK_HZ` to what the ladder program reports), whether 10 us is enough.
- The HL2 link session is written (section 9) and tested against a model only; the real HL2 has to confirm it.
- The software decoder's time on the AE350 (the image prints it per slot) and with it the candidate count; whether the screen redraw and a 1 to 2 s decode in one loop are acceptable, or the decoder has to yield.
- Receive level: AGC setting of the back end for FT8, S-meter reading against a known signal.
- The stamps: the bank's own pipeline delay is not subtracted (only the channel filter's 5.3 ms); it shows as a constant DT offset in the decodes.
- Transmit: the TX ring through the real chain into the HL2 **in echo mode** (the station then decodes its own message, `decode_own_slots`); the rate lock; and, only on the owner's instruction, keying.

## 8. Results under QEMU

`fw/tr-app/qemu_p2.sh`, 2026-10-12, release builds, `qemu-system-riscv32 -M virt -m 128M`: **PASS**.

| Item | Result |
|---|---|
| Board image `ft8fw` | builds for riscv32imafc; ELF 1,894,080 bytes (with symbols) |
| Screen | 31 frames drawn by the software renderer; waterfall rectangle pure key colour; both operator clicks (TX enable, CQ) arrived as events |
| Transmission | `CQ K1XYZ FN42` started at 0.5 s into the slot; all 606,720 TX ring words played; the ring ran empty once (at the end); 0 faults against the write-back / 10 us / pointer order |
| Reception | 170,049 of 180,000 samples of the slot in hand at 14.2 s; decoded `CQ K1XYZ FN42` at 1,500.0 Hz, 0.00 s |
| TX path | off before the click, off again after the operator switched it off |
| Heap | peak 40.6 MB (two frame buffers 8 MB, capture, decoder, the mock's own tables) |
| Run time | 30 s |

Seen in the run, for the board: almost every frame redraws nearly the whole screen (1,056 of 1,080 lines on
average), because the clock at the top and the status line at the bottom change together and the renderer
reports one bounding box. On the board that is a 4 MB cache write-back per frame; draw less often or split
the region if it costs too much.

(Wrong cause, corrected in section 9: it was the decode list being replaced on every frame.)

## 9. WP P3: the HL2 link session, and the frame redraw

Branch `p3`. **Nothing here has run against the real HL2.**

### 9.1 The session

`fw/tr-station/src/hl2session.rs` on `hl2net.rs` (UDP over IPv4 and ARP on whole frames, about 150 lines; no
smoltcp on this link) and on the packet driver `tr_fabric::hl2link::Hl2Packets`. Wire format from `tr-hl2`
(WP S1); behaviour from the raw front-end image's PROTOCOL.md sections 1 to 6 and 12.

| Phase | What the firmware does |
|---|---|
| Address | Answers the HL2's DHCP request (10.99.0.2, `tr_hl2::dhcp`). An HL2 that already has an address (169.254.x.x after 15 s, or static) needs nothing: it is found by discovery at whatever address it has |
| Discovery | `EF FE 02` broadcast to port 1025 every 0.5 s. The reply must carry marker 0xD1; another image is left alone and shown as such |
| Set-up | stop; register 0x30 = raw mode, 948 samples per frame; register 0x00 = filter relays of the band; register 0x0A = RX gain (20 dB). Each write up to three times until the HL2's reply comes. HL2 address written to the link's registers first (the chip's classifier matches on it) |
| Start | `EF FE 04 81` to port 1024 from port 51,000, the port the chip's TX framer uses |
| Watch | No raw frame counted for 1 s, or no Ethernet link: TX is switched off, and the session starts again at discovery |
| Band change | register 0x00 again |

**Every command the firmware can send to the HL2, and when:**

| Datagram | When |
|---|---|
| DHCP OFFER and ACK, ARP reply | when the HL2 asks |
| discovery (port 1025) | while looking for the HL2 |
| stop (port 1024) | before set-up; when the stream is lost |
| register 0x30 (raw mode on, frame size), 0x00 (filter relay bits 23:17 only), 0x0A (RX gain) | set-up; 0x00 again on a band change |
| start (port 1024) | after set-up |
| register 0x31 = 1 (TX samples into the HL2's virtual DAC; or 5, echo, if built with `TR_TX_ECHO`) | only when the operator switches TX on, and only while the stream runs |
| register 0x31 = 0 | when TX goes off: operator, HL2 trip, stream lost |

Nothing else. One function (`command_allowed`) checks every register write and passes only these values;
register 0x31 with bit 1 (real DAC) does not pass, register 0x09 (TX gain, PA enable) does not pass, and
there is no code for port 1027 (the register bridge with `TX_PERMIT`, the only way to key the HL2). After a
lost stream the session does not set register 0x31 again by itself; the operator has to switch TX on again.

Tested (`fw/tr-station/tests/hl2_session.rs`, 6 tests, plus 4 unit tests): against a model of the HL2 on an
in-memory Ethernet segment, written from PROTOCOL.md, that records every datagram it gets. Power-up with
DHCP to streaming in under 1.5 s with exactly the datagrams above in order; an HL2 with a link-local address;
lost datagrams repeated; the factory image left alone and picked up after a re-flash; a power-cycled HL2
noticed within 1.1 s and brought back; a pulled cable; band change; the TX switch (0x31 = 5, then 0); no
write of 0x31 without the switch; valid IP checksums.

The board image `ft8fw` runs the session in its loop and shows its state on the screen and the console.
The QEMU twin does not run it (QEMU has no HL2; the model lives in the host test).

**The board and the real HL2 must confirm:**

- That the HL2 answers a discovery broadcast sent from 10.99.0.1 while it holds a 169.254.x.x address.
- That its reply to a register write parses as the 60-byte `EF FE` datagram assumed here.
- That DHCP works with the answer sent to the broadcast address (the HL2's client code was not read).
- That 948 samples per frame is right for the chip's receive side with both header lengths (20 and 48 bytes).
- RX gain 20 dB is a guess; the right value depends on the antenna.
- That one frame in flight in the chip's CPU transmit queue is enough (a busy queue drops the datagram; the
  session repeats it).
- What register 0x31 = 1 does to the chip's TX rate lock (it needs the HL2's TX FIFO fill from the long
  header, which the HL2 sends only with bit 0 of 0x31 set).

### 9.2 Frame redraw

Cause: `apply_state` gave Slint a new band list and a new decode list on every call. A new list makes Slint
rebuild every row, so the whole decode list (lines 136 to 1,060) was redrawn each frame. The clock and the
waterfall rectangle were not the cause. Fix: the lists are replaced only when they differ from what the
screen shows (`apply_state_diff`; `tr_app::screen::Screen` keeps the shown state). Host test: a clock tick
redraws fewer than 100 lines, the same state redraws nothing, a new decode line redraws the list.

Under QEMU (`fw/tr-app/qemu_p2.sh`, 2026-10-12, PASS as before): 7,662 lines redrawn in 31 frames, against
32,726 before. That count includes the two full first frames (one per buffer, 2,160 lines) and the frames
in which the transmission starts and the decode list changes; an ordinary frame redraws the clock and the
slot bar. Board image `ft8fw` with the session: ELF 1,912,156 bytes.

## 10. WP FWVID: the final video map, and an audio waterfall in software

Branch `fwvid`. **Nothing here has run on the board.** Tests: `cargo test -p tr-fabric` (35), `-p tr-station` lib and `loopback`, and `fw/tr-app/qemu_p2.sh` (PASS, 2026-10-12).

### 10.1 Video driver on the final map (`fw/tr-fabric/src/video.rs`)

| V2_COMPOSITOR.md section 6 | Where |
|---|---|
| RGB565 buffer, stride 3,840, base a multiple of 8 | `FrameBuffers::new` writes `fb_stride`, asserts the alignment |
| Key colour 0xF81F in every window rectangle | the screen paints it; `Video::start` also writes the `key` register |
| Cache write-back, then the 10 us wait, then `fb_base` | `FrameBuffers::present` (unchanged order) |
| Swap = write `fb_base`, wait for `fb_active` | `FrameBuffers::back_free(now_ms)`: the old buffer is drawn into only after `fb_active` shows the new base; no answer in 100 ms counts a `swap_timeouts` and goes on |
| `ctrl.enable` | `Radio::show_display`, called after the first frame is presented (until then the compositor shows its colour bars) |
| Palette | 24-bit 0xRRGGBB, `palette_index` with the palette-select bit; `default_palette()` is now 24-bit |
| Windows | `win_src` added; waterfall only in windows 0 and 1, geometry checked (`WindowError`) |
| Underrun, lane error | `Video::status()`, `clear_status()`; the board image checks once a second and prints on the console when a flag is set or a swap was not confirmed |

### 10.2 The audio waterfall

The FPGA waterfall spans 0 to 38.4 MHz. Until the zoom spectrum is in the chip the firmware makes its own.

- **Line** (`fw/tr-station/src/waterfall.rs`): the newest 2,048 samples of the 12 ksps receiver audio, Hann window, zero-padded to 4,096, real FFT; every column of the window takes the strongest bin it covers; 0 to 3,000 Hz across the 1,172 columns, so the screen's frequency scale matches. One line per 1,920 samples (one FT8 symbol, 6.25 lines per second). Level: dB re full scale; the line's mean (smoothed over about 1.6 s) is the noise floor and sits at palette index 40, 6 index steps per dB, so the picture does not depend on receiver gain.
- **FFT**: its own small radix-2 (heap tables). The decoder's (`tr_modes::fft`) is f64, recursive and allocates per call; `tr_dsp::fft` builds about 50 KB of tables on the stack, the board's stack is 32 KB.
- **Ring** (`fw/tr-fabric/src/wfring.rs`): lines in the compositor's format, column 0 in the top byte of the 64-bit lane word, which in the CPU's little-endian view is memory byte `(c & !7) + 7 - (c & 7)`.
- **Scrolling (changed 2026-10-12, branch `zoom`):** each waterfall window now has its own ring base and its own scroll line (V2_COMPOSITOR.md section 10). The software waterfall is a plain ring of 2,048 lines of its own (`map::SOFT_WATERFALL_RING`, 0x1140_0000): a new line goes into the next ring line, then `wf_win_line[0]` moves to it. The earlier trick (spectrum stopped, `wf_ring_base` moved up a line at a time, the visible rows copied back every 10 minutes) is gone. `Radio::start_display` now sets the full-band writer's ring (`map::WATERFALL_RING`) and starts the full-band spectrum at 30 lines per second, so the hardware waterfall runs alongside and another window can show it.
- Lines come from `Radio::service`; a long decode is caught up on the next call (16 lines at a time), a longer stop skips lines.

**CPU cost**, QEMU with `-icount shift=0` (`minstret`), release: **736,350 instructions per line** (tables: 826,655 once). At 6.25 lines/s that is 4.6 M instructions/s, 0.58 % of an 800 MHz core at IPC 1.0, 0.82 % at IPC 0.7. The ring write (about 300 stores, one 1.2 KB write-back, the 10 us wait) is not in the number; the wait adds 0.006 %.

**Tests.** `tr-fabric`: byte order against a model of the compositor's read, the scroll across copy-backs (every row, every column, 70 lines), the write-back / 10 us / `wf_ring_base` order, refusals. `tr-station`: FFT against a direct DFT; pure tones at 210 to 2,937 Hz land within one column; all 79 symbols of a noisy FT8 message land within one column (74 of 78 required, measured on the symbols 1 to 78); noise floor stays at its index over a 40 dB gain range; the loop-back self-test finds the CQ's tone in the rows the compositor would read (60+ rows) and no strong column elsewhere. The QEMU twin still passes.

### 10.3 What the board must confirm

- The CPU's view of a lane word is little-endian (assumed everywhere, here for the waterfall bytes): if the picture is mirrored in groups of 8 columns, flip `mem_offset_of_column`.
- The full-band spectrum running next to the software waterfall: `underrun_count` stays 0, the spectrum's line counter moves.
- `fb_active` changes after a swap, also while `ctrl.enable` is 0 (otherwise the first swaps time out after 100 ms, harmless but slow); `underrun_count` stays 0 with the 1,172 x 656 waterfall window and the Slint layer.
- The palette write order (index, then data) and that the palette takes effect while the picture runs.
- Whether the noise-floor index 40 and 6 per dB look right on a real band.

### 10.4 What the compositor or register map lacks

- (Done 2026-10-12: a ring base and a scroll line per waterfall window.)
- The zoom spectrum (then this software waterfall can go).
- No "bridge flushed" bit: the 10 us wait is still always taken.

## 11. WP FWFT8: decoding through the chip's FT8 front end

Branch `fwft8`; the second pass on branch `pass2` (`docs/FT8_PASS2.md`). **Nothing here has run on the board.** Tests: `cargo test -p tr-fabric --lib ft8fe` (7), `cargo test --release -p tr-station --test chip_decode` (8, needs `captures/ft8/` from `tools/fetch_test_audio.sh`), `fw/tr-app/qemu_p2.sh` (PASS on `fwft8`; not re-run for `pass2`, the twin does not use the chip path).

### 11.1 Driver (`fw/tr-fabric/src/ft8fe.rs`)

`Ft8Engines`: `setup_rx` (bases as lane-word addresses, band, triggers, enable last, read-back check), `start_slot`, `take_sync` (clears only its receiver's event, invalidates, reads the 8-word records), `pass1` / `pass2` (two lanes), `read_baseband` / `read_symbols`, `read_audio`. Built in: wait for `cand_busy` = 0 before any `cand_*` write; finish on `irq_status.cand_done`, cleared before the next command; every read of logic-written memory is preceded by the cache invalidate; a pass-1 receipt goes stale when a new pass 1 starts (pass 2 and the reads refuse it). Waits give up after 100 ms (`Error::Busy` / `Timeout`). Interrupt 11 is not used: the loop polls `irq_status`. DDR3 map for the engines (new, `ft8fe::map`): capture rings 0x1300_0000 (1 MB each), spectrograms 0x1380_0000 (2 MB apart), records 0x1480_0000 (64 KB each), baseband 0x1490_0000, soft symbols 0x1491_0000. Host tests run on `ft8fe::chip_mock::FakeChip`: the page's register semantics plus a data cache the logic's writes bypass, counting `cand_*` writes while busy and stale reads (both 0 in every test).

### 11.2 Decode path (`fw/tr-station/src/chipdec.rs`, `fw/tr-modes/src/frontend/decode.rs`)

- `Fabric` got `lanes()`, `baseband_batch`, `symbols_batch`, `failed()` (defaults keep every old fabric's call order). `decode_slot` now handles candidates in batches of `lanes()`: pass 1 for the pair, the CPU's fine search on each, pass 2 for the pair.
- `ChipFabric` = `Fabric` over the driver. `ChipDecoder` is the per-slot rhythm and runs the S17 scheduler (operator first, cap, candidate policy) over the receivers of a plan, up to 8. Each slot: boundary = `cap_wr_ptr` now - ms into the slot x 12 + 64 (channel filter delay), written for slot N+1 after slot N's search was taken (about 50 ms into N+1; the engine catches up); search done -> records -> candidates -> pairs -> LDPC/OSD.
- **Fall-back.** `ft8fw` uses the chip when the id register says engines are present, the set-up reads back and `TR_FT8_SOFT` is not set; otherwise the old software decoder. A slot the chip does not deliver (search never done after 4 s, or a command error) is decoded in software from the CPU-side capture; 3 such slots in a row switch to software for good.
- **Two passes for the operator's receiver, both through the chip (2026-10-12, `docs/FT8_PASS2.md`).** The CPU subtracts the first pass's decodes and writes the residual to DDR3; the chip replays it through the spectrogram engine and searches it (`p2_cmd`, about 0.14 s), and the candidate engine filters it like any audio ring. `ChipDecoder::second_pass` is on when the page says version 2 or later. `ChipDecoder::poll` now works in steps (one receiver or one pass per call) and hands the operator's decodes out as `ChipEvent::Partial` as soon as each pass has them; `ChipEvent::Decoded` closes the slot. A chip step of the second pass that fails costs that slot a second pass on the software models (`ModelFabric`, about 83 % of a software decode, cut by the CPU cap if it does not fit); the next slot uses the chip again. `HybridFabric` is gone.

### 11.3 Results on the host (chip model = F5-F7 bit-exact models behind the register page)

| Check | Result |
|---|---|
| `qso1`, 60 candidates | 3 decodes, equal to the model fabric's (message, frequency, time to the bit) |
| `qso3_busy`, 70 candidates (scheduler's second-slot count) | 15 decodes, equal to the model fabric's; 6 of WSJT-X's 8 |
| `qso3_busy`, both passes through the chip (60 candidates) | 19 decodes = the model's two-pass result to the bit, **all 8 of WSJT-X's**; the first pass's 15 handed out before the second pass starts |
| `qso1`, both passes through the chip (70 candidates, the slot after) | equal to the model's two-pass result |
| The chip never finishes the replay | that slot: second pass on the software models after 1 s, same 19 decodes; the slot after: through the chip again |
| Page version 1 (no second pass in the chip) | one pass, no `p2_cmd` written |
| Eight receivers (3 recordings, operator = receiver 3) | each equal to its single run, operator first, no cut |
| Chip never finishes a command / never finishes a search | `Error::Timeout` on the receiver / `Missed` after 4 s; strikes counted |

The 2 WSJT-X messages that one pass lacks: `K1BZM DK8NE -10` is not among the first 70 candidates (a single pass finds it at 100 or more), `KD2UGC F6GCP R-23` hides under a stronger signal 7 Hz away and needs subtraction.

### 11.4 CPU cost per receiver and slot

Not measured on the target with the driver. The CPU part is the 124-174 M instructions per receiver and slot of FT8_CPU section 3.2 (60 candidates, one pass; fine sync 48 M, ladder 72-113 M, words 11 M). The driver replaces the trace's 11 M for the words: about 3,800 words per candidate at roughly 25 instructions each with conversion plus the invalidates, 6-7 M per 60 candidates (estimate). Eight receivers: 1.4-1.6 G instructions as in FT8_CPU. Chip time is added in cycles because the driver waits (not overlapped with the CPU's fine search): about 46 ms per receiver (30 pairs x 1.53 ms), 0.37 s for eight.

Timing: the first decodes (operator) are out about 0.4 s after the slot ends (search, then 30 pairs and the ladder for one receiver), earlier than the software path (14.2 s start plus 1-2 s).

### 11.5 What the chip side lacks

- (Done: the second pass, `docs/FT8_PASS2.md`.)
- Early decode: the `trig` registers are set up by the driver but unused (default 0); the firmware waits for the full 372 rows. A partial slot would also need a stance on the ring's not-yet-written tail.
- The slot boundary is in capture samples, so the firmware converts UTC with one register read (jitter of a few ms).

### 11.6 What the board must confirm

Whether `cap_wr_ptr` counts 12 samples/ms from the back end's audio and the +64 filter-delay term gives DT near 0; that `irq_status.cand_done` and `sync_done` behave as the doc says (including `start_slot` with a boundary already in the past); the Andes cache CSR numbers (now used for 25 KB invalidates per pass); the real mcycle cost of one pair (the budget uses `mcycle` as in `Budget::AE350`); whether `cap_overflow` stays 0; that the DDR3 areas of 11.1 are free.

## Recheck against the chip as built (2026-10-13, branch ahb80)

Done on the host with the real recordings (`tools/fetch_test_audio.sh`; the tests in `tr-station` (`chip_decode`, 8 tests) and `tr-modes`
(`s15_frontend`, `wsjtx_samples`) pass; a test that cannot find a recording now prints `SKIPPED <test>: ...` on the real standard
error, and `TR_REQUIRE_RECORDINGS=1` turns that into a failure). The `check_ft8_*.sh` scripts print `SKIPPED` the same way.

| Assumption | Chip as built | Firmware |
|---|---|---|
| Register access | AHB 80 MHz, +2 clk_dsp clocks per leg, about 245 ns | blocking AHB handshake; nothing counts clocks of it; waits use the 120 MHz cycle counter. Fine |
| `system.status.num_rx` | bits 19:16, 4 in the target chip | read once; 0 reads as 8. Fine |
| Block ids | video 0x56490002, zoom 0x5A4D0002, FT8 0x46380002 (all from `hw/regmap`, one source for RTL and `tr-regs`) | the checks use the generated constants. Fine |
| Candidate engine | one lane run twice: a pair of candidates (pass 1 and 2) 449,603 clocks = 3.75 ms | command timeout 100 ms. Comment corrected |
| Sync search | 65 to 70 ms per receiver, 8 receivers about 0.56 s | wait of 1.5 s for the sibling receivers, miss after 4 s. Fine; comments corrected |
| Second pass | replay 13.9 M + search 8.2 M clocks = 185 ms at 120 MHz | wait 1 s. Comment corrected |
| Arbiters, one more clock per burst | video line fetch (180-word bursts) and waterfall: under 1 % | frame swap given up after 100 ms against one or two frames (17/33 ms). Fine |
| Cycle counter | 120 MHz | `ft8fw` still divided by 150,000 for the software decoder's time in ms: fixed (120,000) |

Only the board can confirm: the real time of a register access and of the candidate command, the sync search time with video
running, the UART input clock and the machine-timer rate (ladder program), that the instruction fetch from the flash at the
40 MHz flash clock is fast enough for the loader, and the software decoder's time.
