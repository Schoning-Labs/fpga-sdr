<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->

# HL2 control

This page describes how the Rust code controls the Hermes-Lite 2 (HL2) and its N2ADR filter board through the
HL2's own processor. The code is in `fw/tr-hl2` (modules `msg`, `control`, `cpuload` and `sim`) and runs unchanged on the
AE350 firmware and on the PC. The HL2 side is the raw front-end gateware with the message-layer firmware
`firmware/hl2neo/msg` (version 0x0003_0001) of the Hermes-Lite2 repository, branch `hl2-rawfront-release`.

## What the HL2 offers

The HL2 listens on four UDP ports. Port 1024 starts and stops the raw sample stream, port 1025 takes command
register writes, port 1026 takes transmit samples, and port 1027 carries several things that the radio sorts by
the first byte of each datagram. On port 1027 a datagram starting with 0x4E goes to the register bridge
(Etherbone, in logic, works without firmware), and a datagram starting with "H" goes to the message-layer
firmware on the HL2's NEORV32 processor.

The message layer adds reliable requests, I2C transfers and scans in one request, telemetry every 100 ms and
events when the interlock or an input changes. Everything it does can also be done through the bridge, with
one exception in the other direction: the processor's copy of the status block has no RX gain register, so the
RX gain can only be read back through the bridge.

## Which layers the Rust code uses

`msg::MsgClient` speaks the message layer exactly as `msg.c` implements it. It keeps one reliable datagram in
flight, because the firmware caches only the last response, and packs up to eight queued requests into that
datagram as long as the requests and their responses both fit in 240 bytes. It retransmits after 100, 200,
400 and 800 ms and gives up after 3 s. It sets the reset flag on the first datagram of a session, after a
timeout, after an out-of-step answer and after a new boot ID. It acknowledges events and delivers each one
once, and keeps the latest telemetry.

`control::Hl2Control` is the API the station code calls. It wraps one `MsgClient` and adds the one bridge read
for the RX gain. Both are state machines without a socket: the caller passes every datagram received from port
1027 to `handle_datagram` and sends whatever `poll_transmit` returns to port 1027, calling it until it returns
nothing. Port 1025 is not used by this API, since the message layer's CMD request reaches the same command bus.

`sim::Hl2Sim` is a port of `msg.c` and the request handlers of `main.c` over a register, I2C and command bus
model, with the MCP23008 of the filter board on bus 2 at 0x20. `sim::Bench` joins an `Hl2Control` and an
`Hl2Sim` through two links that can lose, duplicate and reorder datagrams. The module is built for tests, for
`std`, and for no_std users with the feature `sim`.

## API

Every operation returns a tag at once, or an error if the policy refuses it. A refused operation queues and
sends nothing. The result arrives later from `poll_completion` as a `Completion` with the same tag and a
`Result<Response, MsgError>`.

| Call | Request | Result |
|---|---|---|
| `Hl2Control::new(seed)` | HELLO and a filter latch read, queued at once | `Response::Hello`, then `I2cXfer` |
| `hello()`, `ping(bytes)` | HELLO, PING (up to 32 bytes) | `Hello`, `Ping` |
| `set_telemetry_period(ms)` | TELEMETRY | `TelemetrySet` |
| `set_rx_gain_db(db)` | CMD 0x0A, -12 to +48 dB | `Cmd` |
| `request_rx_gain_readback()`, `rx_gain_readback()` | bridge read of the RX gain register | dB, or none seen since power-up |
| `set_band_filter(band)`, `set_filter_bits(bits)` | CMD 0x00, filter relay bits 23:17 | `Cmd` |
| `set_rx_antenna(on)` | CMD 0x00 bit 13 | `Cmd` |
| `read_filter_latch()` | I2C read of the MCP23008 output latch | `I2cXfer`, low byte equals `filter::expected_olat(frontend_reg())` |
| `i2c_read`, `i2c_write`, `i2c_probe`, `i2c_scan` | I2C XFER and SCAN on buses 1 to 3 | `I2cXfer { outcome, data }`, `I2cScan(bitmap)` |
| `read_register(addr, count)` | READ, 1 to 32 words | `Read` |
| `write_register(addr, value)` | WRITE, LED or FAN only | `Write { words }` |
| `clear_trips()` | CLEAR_TRIPS | `ClearTrips { ilk_status }` |
| `read_limits()`, `set_limits(limits)` | LIMITS | `Limits` |

`telemetry()` returns the latest telemetry with the documented conversions: `temperature_c()` uses
degC = (3.26 x code / 4096 - 0.5) / 0.01, `bias_current_a()` uses A = (3.26 x code / 4096) / 50 / 0.04, the
forward and reverse power codes are uncalibrated, `interlock()` decodes ILK_STATUS, `inputs()` decodes the
debounced key, PTT and TX inhibit inputs and the pin levels, and `safety()` is the transmit-safety byte.
`poll_event()` returns interlock and input events. `msg().restarts()` counts firmware restarts.

The firmware sets the telemetry period back to 100 ms when it restarts. Register 0x00 is written as a full
value from a shadow. `Hl2Control::new` seeds that shadow from the MCP23008 output latch, read over I2C with
the HELLO, so the first filter or antenna call leaves the other relays as they were. Bits 11 (band volts on the
fan pin) and 12 (sync clocks off) are not in the latch and start as the stock value 0. The latch read arrives
from `poll_completion` like any other result, with a tag the caller never got. If it fails (no filter board), the
shadow stays 0.

## Safety rules

Transmit stays locked, and there is no unlocked mode. `control::check_request` runs inside `MsgClient::submit`,
so every request passes it before anything is queued.

- The message layer has no request type for the transmit permission (class 3 opcode 1) or the bias unlock
  (class 3 opcode 3).
- The command bus accepts only register 0x00 with the filter, RX antenna, sync-off and band-volts bits, and
  register 0x0A with an RX gain code. Register 0x09 (PA enable, TX gain, T/R relay), 0x0E (TX-time LNA gain),
  0x31 (real DAC), 0x3A (reboot), 0x3B (AD9866 registers), 0x3C and 0x3D (I2C through the command bus) and every
  other address are refused.
- Register writes go only to the front-end block's LED and FAN registers. The firmware itself would also write
  the transmit permission, the bias unlock, the watchdog, the command registers and the processor control
  block, so the client refuses all of these.
- I2C writes to the bias pots and configuration EEPROM (bus 2, address 0x2C) are refused. Reads there pass only
  with an MCP4662 read command (register byte bits 3:2 = 11), because the register byte of a read is sent as a
  command and could otherwise be an increment or decrement.
- I2C writes to the N2ADR Pico IO board (bus 2, address 0x1D) are refused. Reads and probes there pass.
- LIMITS can only lower the lease time, the longest key-down time and the temperature limit below the values
  last read back from the radio, within the documented ranges. A LIMITS request with all values 0 only reads
  them back and is always allowed.

`control::check_datagram` applies the same policy to a whole outgoing datagram, decoding every message in it
back into a request. The station uses it as the whitelist for port 1027 (below).

The tests in `fw/tr-hl2/tests/hl2ctl_sim.rs` check every refusal and that nothing reaches the simulated radio.

## In the radio firmware

`tr_station::hl2session` opens the message layer after the set-up writes and before it starts the raw stream. It
creates an `Hl2Control`, which sends HELLO and the latch read to port 1027 from the session's own UDP port. Every
datagram to port 1027 passes `msg_datagram_allowed` first, which refuses register bridge datagrams (only the
program update below sends them, through its own whitelist) and checks everything else with
`control::check_datagram`. The radio's chip passes port 1027 answers to the processor, since its raw-frame
classifier takes only frames from port 1024 that start with 0xA5.

### Why the message layer is asked before the stream starts

The HL2 sends port 1027 datagrams (bridge replies, message-layer answers, boot ROM output) only in the gap between
two raw frames, and only when the whole datagram fits before the next frame is due. Its gateware computes that room
as 1.625 x (N - fill - 32) - 80 bytes (`gateware/rtl/rawstream.v`, "Aux room"), and a datagram waits until the room
is at least its length. At 948 samples per frame, which the session uses because the copper SFP module's support
for jumbo frames is not known, a frame occupies the line for 1,508 byte times, and 926 new samples arrive in that
time. The gap after each frame is about 22 samples, less than the gateware's own 32-sample margin, so the room is
always 0. A port 1027 answer therefore never leaves the HL2 while the stream runs; it goes out when the stream
stops. This is why the Tang saw no datagram from port 1027 on the board, while a PC, which talked to the HL2 with
the stream stopped, got every answer. Port 1025 replies are not affected, because the gateware gives them priority
over raw frames. `tr_hl2::protocol::reply_room` computes the room for any frame size; it reaches the longest answer
the code asks for (256 bytes) at about 4,000 samples per frame, and about 540 bytes at 5,968 (jumbo frames).

The session therefore sends HELLO, and does the program update below, while the HL2 is stopped. When HELLO is
answered and the frame size leaves room for the answers, the session sets the telemetry period to 500 ms (again
after every firmware restart), and while streaming RX gain and filter changes go through the message layer's CMD
request. When the frame size leaves no room, as at 948, the session switches the HL2's telemetry off with one
unacknowledged request just before the start, sends nothing more to port 1027 while streaming, and sends RX gain
and filter changes to port 1025. The screen then shows "HL2 telemetry: off while streaming" or the program state.

If HELLO gets no answer within 3 s, the HL2 has no message-layer firmware. The session then drops the client and
stays on port 1025 for everything, as before. The stream starts 3 s later than it would otherwise. The next stream
start asks again.

`Hl2Session::hl2_status` gives the state of the message layer, the state of the HL2's program, the latest telemetry
and the RX gain, and `hl2_line` and `hl2_report` turn them into a line for the screen and a line for the console.

## Updating the HL2's program

The HL2 starts its message-layer program from a flash sector reserved for it (0x1F0000 to 0x1FFFFF), where the boot
ROM finds a 32-byte header with the version and CRC-32 followed by the image. The radio firmware can carry the
program and replace the saved one itself, without a PC. The owner approved this on 2026-11-20 as the one
exception to the rule that the firmware writes no HL2 memory: the RAM of the HL2's CPU, and the saved program in
that sector through the boot ROM. Nothing else on the HL2's flash, its gateware, its boot ROM, its reboot register
or its transmit path is ever written.

### When it runs

In the stopped phase described above, the session compares the firmware version HELLO reports with the version of
the embedded image. If they are equal, the screen shows "HL2 program: up to date" and nothing is written. If they
differ, or HELLO goes unanswered (no program at all), the session runs the update once. There is one update per
stream start and at most two per HL2 start, which the session sees as the HL2's DHCP request. After that the
session goes on with whatever the HL2 runs and never tries again until the HL2 restarts. The screen shows "HL2
program: updating", then "HL2 program: updated" or "HL2 program: failed:" with the reason, and the console prints
every change with the time the update took.

### How it works

`tr_hl2::cpuload::CpuLoader::update` does what `hl2fw.py save` followed by `hl2fw.py boot` does, over the register
bridge and one boot ROM console datagram:

1. It reads the CPU system block, the transmit-safety byte and the inputs, and stops if there is no CPU or if the
   HL2 reports transmit on.
2. It holds the CPU in reset, writes the image from 0x800 in requests of 48 words that read every word back, and
   sets the boot address to 0x800.
3. It restarts the CPU with the stay-in-ROM control bit (control 5, firmware state 0, control 4) and waits until
   the ROM reports itself idle (state 2). `hl2fw.py save` does the same.
4. It clears the result register (0x4001_0014) and reads it back with the firmware state, the safety byte and the
   inputs. It stops here, before anything reaches the flash, if transmit is on, if the ROM is not idle, or if the
   session does not report the HL2 quiet. The session reports it quiet when no raw frame has been counted for
   100 ms.
5. It sends the console datagram `01 'S'` with load address 0x800, length, entry 0x800, version and CRC-32, as
   `hl2fw.py save` does after its `01 'A'` attach (the attach only makes the ROM send its console output, so the
   firmware leaves it out). The ROM computes the CRC-32 of the RAM range and compares it with the one in the
   datagram before it erases anything, then erases the sector, writes the header and the image, and reads
   everything back.
6. It reads the result register every 200 ms until it shows a save ('S' in bits 31:24). The datagram is sent again
   only while the ROM is idle with no result 1.5 s after the last send, which means it was lost, and at most three
   times. After 60 s without a result the update fails and the CPU is left alone, since the ROM may still be
   writing.
7. With result 0 it restarts the CPU normally (control 1, firmware state 0, control 0), as `hl2fw.py boot` does,
   and waits up to 5 s for state 3. The ROM copies the saved program into RAM, checks its CRC and starts it.
8. The session sends HELLO again and compares the version. Only a matching version counts as updated.

The CRC-32 is computed by `fw/tr-app/build.rs` from the file at build time. The update does not start, and nothing
is sent, if the embedded bytes do not match it.

### What may be sent

Every datagram of the update passes `hl2session::update_datagram_allowed` before it leaves. A register bridge
request may write only the RAM from 0x800 to 0x3FFF and the control, boot address, firmware state and result
registers, with the values of the sequence (`cpuload::write_allowed`: control 0, 1, 4, 5, 8 or 9, state and result
0), and may read only the RAM, the system block and the status block. No bridge write reaches the flash sector
registers at 0x4003_0000, the packet interface, the front-end register block where `TX_PERMIT` lives, or the
command bus. The only boot ROM datagram that passes is the save of exactly the embedded image, with its length,
version and CRC (`cpuload::save_datagram_allowed`). The erase datagram `01 'E'` is never built and never passes.

### What happens when it fails

The boot ROM checks the arguments and the CRC before it erases the sector, so a CRC mismatch (result 2) or bad
arguments (result 1) leave the old saved program in place. "Network flashing wins": once the HL2 has seen an
openHPSDR erase or programming packet, the logic refuses every CPU flash command until the FPGA restarts. The ROM
then reports result 5 (locked) without erasing anything. In these three cases the firmware restarts the CPU
normally, the old program runs again, and the screen shows the reason, for example "HL2 program: failed: save:
flash locked (network flashing since the HL2 started)". A locked HL2 needs a power cycle before the next try.

A flash error or verify error (results 3 and 4) happens after the erase. The sector then holds no valid program,
and at the next power-up the boot ROM finds an invalid header or a wrong CRC, reports result 6 or 7 and stays idle
with no program. The firmware therefore restarts the CPU from RAM in that case (control 9, firmware state 0,
control 8), where the new image was written and verified, so the HL2 runs it until it is switched off. After the
next power-up HELLO goes unanswered and the session updates again, within the limit of two tries per HL2 start.

If transmit is on, if the stream is not quiet or if the ROM does not become idle, the update stops before the save
datagram, the CPU is restarted normally and the old program runs again.

### Recovery from a PC

The HL2 repository's `hl2fw.py` puts any saved program right. Stop the radio's stream first (switch the radio off,
or unplug its link), because the HL2 answers whoever sent to port 1027 last:

```sh
python software/hl2fw/hl2fw.py --ip <hl2> --ifaddr <pc> rom          # restart and stay in the boot ROM
python software/hl2fw/hl2fw.py --ip <hl2> --ifaddr <pc> erase        # remove the saved program
python software/hl2fw/hl2fw.py --ip <hl2> --ifaddr <pc> save firmware/hl2neo/build/msg.elf --version 0x00030001
python software/hl2fw/hl2fw.py --ip <hl2> --ifaddr <pc> boot
```

A locked flash (result 5) only clears when the HL2's FPGA restarts.

### Building the firmware with the program

The program is not kept in this repository. It is built from the HL2 repository and embedded when the firmware
is built. `tools/hl2_msg_bin.sh` finds `firmware/hl2neo/build/msg.bin` in a checkout of that repository, given as
an argument or in `HL2_FORK_DIR`, reads the version from `FW_VERSION` in `firmware/hl2neo/msg/main.c`, and prints
the lines that set `HL2_MSG_BIN` and `HL2_MSG_VERSION`. With `--build` it first runs
`python firmware/hl2neo/build.py` there, which needs the xPack RISC-V GCC and also rewrites that repository's boot
ROM files.

```sh
eval "$(tools/hl2_msg_bin.sh /path/to/Hermes-Lite2)"
tools/ladder_fw.sh chip
```

The same by hand:

```sh
export HL2_MSG_BIN=/path/to/Hermes-Lite2/firmware/hl2neo/build/msg.bin
export HL2_MSG_VERSION=0x00030001
tools/ladder_fw.sh chip
```

When `HL2_MSG_BIN` is set, `fw/tr-app/build.rs` switches on the feature `hl2-msg-load`, requires
`HL2_MSG_VERSION` (hex), computes the file's CRC-32 and writes both numbers to `hl2_image.rs` in the build's
output folder, and the firmware embeds the file with `include_bytes!`. The version must be the one the program
reports in HELLO, or every stream start would see a mismatch (the two-tries limit still holds). Without
`HL2_MSG_BIN` the firmware builds as before and prints "HL2 program: not built in" on the console at start.

## RF AGC

`tr_station::rfagc` sets the HL2's RX gain (the AD9866 PGA, -12 to +48 dB in 1 dB steps). It starts in manual
at the session's 20 dB.

### What it measures

The full-band spectrum writes one waterfall line of 1,920 columns covering 0 to 30 MHz into its DDR3 ring about
30 times a second, on every screen, although no window shows it. `FullBandLevel` reads each new line back. A
column byte is the column's power in dB under the level register `spectrum.level`, which the firmware leaves at
its reset value (offset 0, 1 dB per index). `line_level` inverts that mapping for whatever the register holds,
adds half a step, sums the column powers and converts the sum to dBFS of the ADC, where 0 dBFS is the power of a
full-scale sine (amplitude 2,048). The reference levels come from the spectrum's done-test theory in
`docs/F2_SPECTRUM.md`: a 0 dBFS sine puts 105.5 dB into its own bin and 108.5 dB into all bins together. It
also reports the strongest column as dBFS of a sine.

The radio runs the spectrum in max mode, where each column holds its strongest bin rather than the sum of its 3
or 4 bins. A fixed correction of +2.5 dB centers the result. A numerical model of the window and the column
mapping gives these remaining errors: white noise reads 0.7 dB low, and a single carrier between 1.3 dB low and
1.6 dB high, depending on where it falls in its column. With the whole-dB bytes the total is good to about
+/-2 dB.

The measurement cannot see single clipped samples or short peaks, because each line is the average power over
its 33 ms. It does not see 30 to 38.4 MHz either. The ADC clip flag would show clipping directly, but the
gateware sends it only in the raw frame header, and the chip does not pass it to the processor, so the AGC
cannot use it without a change to the logic. The thresholds therefore keep 12 dB or more of headroom below full
scale.

### How it controls

| Setting | Value |
|---|---|
| Attack | total above -22 dBFS, a column above -12 dBFS, or a column at the top of the color scale |
| Attack target | total -28 dBFS, strongest column -18 dBFS, in one step |
| Recovery | 1 dB a second once the total has stayed below -34 dBFS for 4 s |
| Gain writes | at most one every 250 ms |
| Readings ignored | for 150 ms after a write |
| Lowest and highest gain | set by the operator, -12 and +48 dB by default |

Between -34 and -22 dBFS the gain holds. An attack works from the gain last written, not one still waiting, so a
line made before a change cannot take the gain down twice. In manual mode the AGC only passes on the operator's
1 dB steps, again at most one write every 250 ms, and a step in auto mode switches to manual. `RfAgc::state`
reports the mode, the gain, why it last changed (start, manual, overload, strong signal, recovery or limit) and
the last reading. The firmware sends each gain through `Hl2Session::set_rx_gain_db`, which uses the message
layer when it is up and port 1025 otherwise, and keeps it for the next set-up.

The tests are in `fw/tr-station/src/rfagc.rs` and in `fw/tr-station/tests/hl2_session.rs`, where the AGC drives the
simulated HL2 through the session.

## What is not possible

- The ADC clip state cannot be read through this API, and the station cannot read it either. The gateware exposes clipping only as a flag in the raw
  sample frame header (byte 2, bit 2, for the previous frame), not as a register. The radio's chip does not pass it on
  to the processor.
- The RX gain cannot be read through the message layer, since the processor's status mirror holds only the ID,
  version, capabilities, slow ADC codes, inputs and safety byte. `read_register` of the RX gain address returns
  0xFFFF_FFFF, and the readback goes through the bridge instead.
- There is no supply voltage measurement. The slow ADC has temperature, forward power, reverse power and bias
  current only.
- RX-time LNA gain is not a separate setting. Register 0x0E is documented as TX-time LNA gain only and is refused.
- Nothing comes back from port 1027 while the HL2 streams at 948 samples per frame (section "Why the message layer
  is asked before the stream starts"). Telemetry while streaming needs jumbo frames of about 4,000 samples or
  more, which the copper SFP module may not pass.

## Where the firmware differs from PROTOCOL.md

The code follows `msg.c` and `main.c` where the protocol document is shorter.

- Telemetry starts with a u32 packet counter before the radio's millisecond time. The table in section 10.3
  does not list it.
- An event is sent at most six times. After that the firmware drops it, acknowledged or not.
- When the responses to a datagram stop fitting in 240 bytes, the firmware stops executing that datagram and
  the remaining requests get no response at all.
- A reset-flag request whose sequence number equals the firmware's current one keeps the session and gets the
  cached response. A new client that happens to start at that number would get the previous
  client's response; `MsgClient` notices the foreign tags and starts over with the next number.
- After a reset the firmware sends a new event only when the state changes. Only the first session after a
  firmware start gets an event with the idle state.
- The firmware writes any non-zero LIMITS value and leaves the clamping to the gateware.

### Waiting for the stream to die down before an update

When the HELLO answer says the HL2 runs another program than the one the Tang carries, the update does not start at once. A stream from an earlier run can still be arriving (the HL2 keeps streaming until it has handled a Stop), and the save must never go out beside a stream. The session therefore waits until no raw frame has been counted for 100 ms, sends Stop again every 500 ms while it waits, and gives up after 6 s with "failed: HL2 not quiet". The first board test of the update, on 2026-11-20, stopped for exactly this reason before anything was written, because the update asked for a quiet HL2 only at the instant it was started.

### The version number has to be the one inside the program

The HELLO answer reports the version that is compiled into the HL2 program (`FW_VERSION` in `firmware/hl2neo/msg/main.c`), and the Tang compares that number with `HL2_MSG_VERSION` after an update. The version in the saved header is only a label that the save command writes. `HL2_MSG_VERSION` must therefore be the same number as `FW_VERSION` in the `msg.bin` that is embedded. A test that saves the same `msg.bin` under a different header version ends with "HL2 reports version 0x00030001, not 0x00030002", which is what happened in the first test on 2026-11-20 after the wait for a quiet stream worked. To test an update on the real HL2, build a `msg.bin` with a different `FW_VERSION` (a copy of the sources is enough, nothing in the HL2 fork has to change) and give the Tang build that file and that version.

**Result on the board, 2026-11-20:** the Tang found the HL2 on another program version, waited for the stream to die down, loaded the new program into RAM, saved it to the reserved flash sector, restarted the HL2 processor, and HELLO then reported the new version ("HL2 program: updated"). At the next start the same firmware printed "HL2 program: up to date" and wrote nothing.
