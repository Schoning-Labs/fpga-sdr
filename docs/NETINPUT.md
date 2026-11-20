<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# Network input: the PC's mouse and keyboard on the radio's screen

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Owner, 2026-10-21: "I just need to be able to control the radio from the PC until I can get a USB port adapter.
Everything stays on the radio HDMI GUI." The screen is not streamed. The HDMI monitor stays the display. A small PC
program sends mouse and keyboard events over the home network; the firmware feeds them into the same path as the USB
host's mouse and keyboard (`Screen::input`, the console key queue).

Input only. The network path never enables transmit (section 3).

## 1. Parts

| Part | Where |
|---|---|
| Packet format, parser, applier, key block, service loop | `fw/tr-input` (no_std, host tests in `tests/netinput.rs`) |
| UDP socket on the RJ45 unit | `fw/tr-net/src/nettime.rs` (`set_service_port`, `service_recv`, `service_send`), `fw/tr-app/src/rj45net.rs` |
| Glue to the screen | `fw/tr-app/src/netinput.rs`, main loop in `fw/tr-app/src/bin/ft8fw.rs` |
| PC program | `tools/radio_input.py`, test `tools/test_radio_input.py` |

The board's address comes from DHCP (RJ45 unit, `docs/NET_ID.md`). The UDP port is `tr_input::UDP_PORT` = **21600**
(`fw/tr-input/src/lib.rs`; `PORT` in `tools/radio_input.py` follows it). No FPGA change.

## 2. Packet format

Numbers are big-endian. A datagram is a header and, for kind 1, events.

```
datagram = "TRIN" version(1) kind sequence(u16) events...
kind     = 0 hello (PC to board, no events) | 1 events (0 to 64 events; none = heartbeat) | 2 status (board to PC)
```

| Tag | Event | Bytes after the tag |
|---|---|---|
| 01 | pointer moves by (dx, dy) pixels | dx i16, dy i16 |
| 02 | pointer to (x, y); x < 1920, y < 1080 | x u16, y u16 |
| 03 / 04 | button down / up; 0 left, 1 right, 2 middle | button u8 |
| 05 | wheel clicks, positive away from the user | delta i8 |
| 06 / 07 | key down / up | USB HID usage (keyboard page) u8, modifier bits u8 (as in a USB boot report) |
| 08 | release every button and key | none |

Keys are HID usages, the same event the USB keyboard gives, so the screen and the console key handler see no difference
(the firmware turns a usage into a character with `USB_KEY_LAYOUT`, US). The PC program takes letters and digits from
the Windows key code, so they match what is typed; punctuation follows the US key positions.

Status (board to PC, 18 bytes): header with kind 2 and the sequence number of the last datagram applied, then datagrams
applied since start-up (u32), pointer x (u16), pointer y (u16), transmit keys dropped (u16, saturating).

Rules of the receiver:

- A datagram that is too short, longer than 512 bytes, has the wrong magic, version or kind, a truncated or unknown event,
  more than 64 events, a button above 2 or a position off the screen is dropped whole. Nothing of it is applied.
- A sequence number equal to or behind the last one applied (16-bit wrap-around) is dropped. A hello, or 3 s of silence,
  starts a new sequence.
- Per main-loop pass: at most 16 datagrams and about 192 events; the rest waits in the socket (32 datagrams, 8 KB).
  The loop takes 0.1 s to 0.3 s per pass (screen drawing), so the PC program sends about 25 datagrams per second at most.
- Runs of pointer movement in one pass are merged into one movement; a button, wheel or key flushes the movement first,
  so a click happens where the pointer was moved to.
- Held buttons and keys are let go after 3 s without any datagram (the PC program sends a heartbeat every 250 ms while
  captured), and on event 08.
- Reply: a hello is answered at once; applied events get a status at most every 200 ms, sent to the last sender.
  The hello is a broadcast (255.255.255.255 and each local /24) so the PC needs no address; the board answers by unicast.

Console of the board: at start-up `netinput: UDP port 21600 ...`, when DHCP gives an address
`netinput: listening on a.b.c.d UDP port 21600`, and the 5 s `HL2 dbg` line ends with the datagrams applied, rejected,
stale, and the transmit keys and screen transmit events dropped.

## 3. Safety (binding)

Transmit is built but has never been tested end to end, so the firmware keeps it locked and the HL2 is never keyed by this work. Two layers:

1. **Keys.** `tr_input::is_tx_key` drops, before they reach the screen or the console key queue, every key (HID usage)
   that gives one of these characters on the US or the German layout, plain, with Shift or with AltGr, case ignored,
   including the number pad:

   `t` TX enable, `c` CQ, `s` TX slot, `0` to `9` answer decode line, `-` `+` `=` TX audio frequency (FT8 screen),
   `u` (starts the clock entry, whose digits would be answer keys).

   This is the exact set `tr_station::keys::event_for` maps to transmit events, plus `u`. The test
   `the_network_input_blocks_every_transmit_key` in tr-station fails when `event_for` gets a transmit key that is not
   on the list. Allowed on purpose: `h` halt (stops transmitting), `m` next screen (switches transmit off), `[` band down,
   `,` `.` clock steps, FreeDV keys (`d e q < >`), LISTEN keys (`l k w a g f b o q`, arrows, Page Up/Down, Home/End;
   docs/LISTEN.md), Escape, Enter, function keys. `]` is blocked: it is `+` on a German keyboard.
   Keys without a character (arrows, Page Up/Down, Home/End) reach the console key queue as codes 0x80 to 0x89
   (`tr_input::console_code`, the same for the USB keyboard).
2. **Screen buttons.** The mouse can click the screen's own buttons, which give the same events as the keys. For 1 s after
   any button or key from the network, the main loop drops the screen's transmit events (`is_transmit_event`: TX enable,
   CQ, TX slot, answer click on a decode line, TX frequency) and prints a line. Halt, band and FreeDV switch pass.
   A genuine USB-mouse click inside that second is dropped as well.

The network code has no path to the HL2 session, the TX ring or the TX switch. Datagrams come in on one UDP port from
the LAN the router serves; there is no authentication, so anybody on the home network can move the pointer and press
the allowed keys (the two layers above hold for them as well).

## 4. How to run

1. Radio running with this firmware, RJ45 cable in the home network. The console shows the listening address.
2. On the PC (Windows 11, Python 3.10, no packages): `py tools/radio_input.py`. It broadcasts a hello, finds the board and
   opens a window. `--ip 192.168.2.160` skips the search; `--probe` only asks the board and prints its answer;
   `--absolute` makes the window the screen (pointer position instead of movement); `--speed 1.5` scales relative movement.
3. Click in the window. The title reads "captured, Esc+F12 to release", the PC cursor is hidden and confined to the window,
   and the pointer arrow on the HDMI screen moves like a laptop pad. Left, right, middle button, wheel and keys go through.
   **Esc and F12 together release.** Leaving the window (Alt+Tab) releases as well.
4. Windows may ask once whether Python may use the network: allow it for the private network, otherwise the board's answers
   do not arrive.

## 5. Tests

- `cd fw && cargo test -p tr-input`: parser (every event, every malformed case), scripted streams through
  `NetInputService::poll` (merging, clamping, absolute moves, click order, keys, transmit keys, stale and malformed
  datagrams, flood, held keys, guard, status), and the golden datagrams `fw/tr-input/tests/golden.bin`
  (`TR_INPUT_WRITE_GOLDEN=1` rewrites it).
- `cd fw && cargo test -p tr-net --test dhcp_sntp`: the service socket takes a unicast and a broadcast datagram and answers.
- `cd fw && cargo test -p tr-station --lib keys`: the block list covers `event_for`.
- `py -m unittest tools/test_radio_input.py` (repository root): the PC program's packets equal the golden file, status
  reader, event queue, loopback against a stand-in board.

## 6. Stalls of the main loop (board test 2026-10-21)

Observed: hello and events got no answer for long stretches; the board's counters stayed at 0. Cause, from the code:

- The main loop served the network once per pass. A pass includes the decoders: the software decoder ran on a slot with
  **0 samples** (HL2 not streaming) and took 13,961 ms; the chip front end's job ran 1,017 Mcycles inline per slot.
- The RJ45 unit's receive ring is **1024 words = 4 KB** (`rtl/net/eth_top.v`, `rxm`), one header word per frame. A small
  broadcast frame (ARP, mDNS, SSDP: 60 to 100 bytes) takes 16 to 26 words, so the ring holds 40 to 60 of them. A home LAN
  sends that in one to two seconds. During a stall the ring is full, the unit drops every frame (`rx_dropped`, "no room"),
  and a datagram from the PC gets in only when it arrives right after the loop drained the ring. That is the
  "answers sometimes, mostly not" seen.

Changes:

1. Measurement, in the 5 s `HL2 dbg` line: `RJ45 rx N frames, dropped A no room B bad`, `D datagrams seen` (taken from the
   service socket, before the parser), `longest pass N ms` (since the last line). A pass of 1 s or more also prints
   `loop: the last pass took N ms`.
2. No software decode of an empty slot (`slot N: no audio received, software decoder not run`).
3. `tr_modes::yield_hook` (in the vendored mfsk-core, `src/yield_hook.rs`): long jobs call it between steps, and the main loop
   registers a function around each decode (`with_yield!` in `ft8fw.rs`) that runs the RJ45 poll and the input service at
   most every 20 ms. Call points: each time step of the software decoder's spectrogram, each candidate's triage, every clock
   read the chip front end's scheduler makes (stage boundaries per candidate), and every poll of the chip's FT8 engines
   (`Ddr::delay_us`). The main loop also serves the network once more after drawing the screen.
4. While events from the network wait in the screen (a click during a decode), the transmit guard holds until the main
   loop has taken them (`events_taken`), not only for 1 s.
5. `tools/radio_input.py` sends the hello every 0.5 s for 15 s (`--timeout`), prints how many were sent, where, and what came
   back, and in the window asks again when no status came for 2 s.

Still not interruptible (no point in the code to yield): the 192,000-point FFT of the software decoder, one candidate's
belief propagation and OSD, and Slint's drawing of a frame. Pointer movement is applied during the job, but the arrow on the
screen is drawn by the main loop, so it moves when the loop draws (the draw is not part of the yield).
NOT VERIFIED on the board: how long the steps between yield points are; read `longest pass` and the `loop:` lines.
The yield runs inside the decoder's stack depth; the stack is 32 KB and was never measured.

## 7. Open

- NOT VERIFIED on a board: the RJ45 receive ring has not been tested with bursts, and the unit is known to accept broadcast
  frames only from the DHCP exchange. If the hello gets no answer, use `--ip`.
- Pointer latency is the main-loop pass (0.1 to 0.3 s), not the network.
- The Windows firewall may block the board's answers until Python is allowed.
