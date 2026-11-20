// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The firmware for the board (docs/P2_FT8_FW.md): FT8, FreeDV receive and general receive (LISTEN) on one screen
//! and one main loop.
//!
//! It checks the blocks of the chip, starts receiver 0 on the FT8 dial frequency with the audio of the back end
//! going into its DDR3 ring, starts the spectrum and the waterfall window, draws the screen into the frame buffers,
//! cuts each 15 s slot out of the audio by HL2 time, decodes it (in the chip's FT8 engines when they answer, in
//! software otherwise) and runs the contact logic. The operator works it from the serial console (keys below), from a
//! USB mouse and keyboard, or from the PC's mouse and keyboard over the network, and the screen shows the same state.
//!
//! The HL2 link session (`tr_station::hl2session`) brings the radio up: DHCP answer, discovery, raw mode, filter
//! relays, RX gain, start, and again after a loss. Its module text lists every command it can send to the HL2.
//! The clock is set by SNTP over the RJ45 unit and by hand (`u` + hhmmss) when no network time is there.
//!
//! Transmitting: with TX enabled the firmware fills the TX ring, switches the TX chain and the framer of the Tang
//! on, and sets register 0x31 of the HL2 to 1 (TX samples into the virtual DAC of the HL2) or, when built with
//! `TR_TX_ECHO=1`, to 5 (echo: the HL2 returns the samples in the RX stream and the station decodes its own
//! message). It never keys the HL2 and never selects its real DAC, because no such command is in this firmware, so
//! nothing is radiated (docs/P2_FT8_FW.md section 6).
//!
//! Console keys: t TX enable, c CQ, h halt, s TX slot, 0-9 answer decode line, [ ] band, - + TX audio frequency,
//! u hhmmss set the clock, , . clock 100 ms back or forward, m FreeDV screen.
//!
//! FreeDV receive (docs/FREEDV.md section 9): `m` (or the FreeDV button of the screen) switches to the FreeDV screen.
//! TX is switched off first and stays off, and FT8 slots, decodes and the clock stop until `m` brings the FT8 screen
//! back. It is receive only, and nothing in FreeDV mode arms or keys anything. Keys there: d e 700D/700E, q squelch,
//! - + squelch level, [ ] band, < > dial 100 Hz, m on to LISTEN.
//!
//! LISTEN (docs/LISTEN.md): `m` on the FreeDV screen (or the LISTEN buttons of the screens) switches to general
//! receive: LSB, USB, CW, AM, SAM and FM on receiver 1 with free tuning, with the audio going to the headphone DAC,
//! S/PDIF, I2S and HDMI. TX is switched off first and stays off, and FT8 slots, decodes and the clock stop, as for
//! FreeDV. Keys there: arrows left/right tune by the step, up/down volume, Shift+up/down squelch level, Page Up/Down
//! 100 kHz, Home/End or [ ] band, l k w a g f for LSB USB CW AM SAM FM, b filter, , . step, o AGC, q squelch, m back
//! to FT8. The arrow and page keys of the serial console (terminal escape sequences) give the same codes as the USB
//! and network keyboards.

#![no_std]
#![no_main]

extern crate alloc;

use core::fmt::Write as _;
use core::panic::PanicInfo;
use core::time::Duration;

use slint::platform::software_renderer::Rgb565Pixel;
use riscv::interrupt::Exception;
use riscv_rt::{entry, exception, TrapFrame};
use tr_ae350::uart;
use tr_app::ddr::Ddr;
use tr_app::screen::{Screen, HEIGHT, WIDTH};
use tr_fabric::hl2link::Hl2Packets;
use tr_fabric::mem::map;
use tr_fabric::system::{CycleClock, System};
use tr_fabric::video::{FrameBuffers, Video};
use tr_gui::ft8::{ClockStatus, Ft8Event, WATERFALL_RECT};
use tr_regs::Mmio;
use tr_station::chipdec::{describe, Budget, ChipDecoder, ChipEvent, RxPlan, SecondPass};
use tr_station::hl2session::{Hl2Session, MsgLayer, ProgramState, SessionConfig, TxSink};
use tr_station::rfagc::{AgcConfig, AgcMode, FullBandLevel, RfAgc, WidebandLevel};
use tr_station::fdvstation::{self, FdvAction, FdvStation};
use tr_station::hl2session::filter_band;
use tr_station::keys::{event_for, is_transmit_event, ManualClock};
use tr_station::listen::{self as listen, ListenRadio, ListenStation};
use tr_station::radio::{decode_slot, Radio};
use tr_station::station::{slot_of, Action, Station, StationConfig};

static REGS: Mmio = Mmio;
static DDR: Ddr = Ddr;

/// The operator's call and locator, given at build time: `TR_CALL=K1ABC TR_GRID=FN42 cargo build`.
/// Without a call the TX switch stays locked.
const MY_CALL: &str = match option_env!("TR_CALL") {
    Some(c) => c,
    None => "N0CALL",
};
const MY_GRID: &str = match option_env!("TR_GRID") {
    Some(g) => g,
    None => "AA00",
};

/// Where TX samples end inside the HL2 while TX is enabled: its virtual DAC, or echo.
const TX_SINK: TxSink = match option_env!("TR_TX_ECHO") {
    Some(_) => TxSink::Echo,
    None => TxSink::VirtualDac,
};

/// The HL2's message-layer program, saved to the HL2's flash sector when HELLO reports another
/// version or goes unanswered (docs/HL2_CONTROL.md). Embedded only when HL2_MSG_BIN names msg.bin
/// and HL2_MSG_VERSION gives its version at build time (build.rs, which also computes the CRC-32).
#[cfg(feature = "hl2-msg-load")]
mod hl2_image {
    include!(concat!(env!("OUT_DIR"), "/hl2_image.rs"));
}
#[cfg(feature = "hl2-msg-load")]
const HL2_PROGRAM: Option<tr_station::hl2session::Hl2Image<'static>> =
    Some(tr_station::hl2session::Hl2Image { bytes: include_bytes!(env!("HL2_MSG_BIN")), version: hl2_image::HL2_MSG_VERSION, crc32: hl2_image::HL2_MSG_CRC32 });
#[cfg(not(feature = "hl2-msg-load"))]
const HL2_PROGRAM: Option<tr_station::hl2session::Hl2Image<'static>> = None;

/// Decode in software even if the chip has the FT8 engines: `TR_FT8_SOFT=1 cargo build`.
const FORCE_SOFT: bool = option_env!("TR_FT8_SOFT").is_some();
/// Slots in a row without a decode from the chip before the firmware gives up on it and decodes in software.
const CHIP_STRIKES: u32 = 3;

/// Heap in DDR3 (docs/ARCHITECTURE.md 5.4), placed below the test words of the memory probe at 0x0FF0_0000.
const HEAP_BASE: usize = 0x0100_0000;
const HEAP_LEN: usize = 200 << 20;
/// UART input clock, in Hz. It is not verified on the hardware; set it to the value the ladder program reports (docs/LADDER.md).
const UART_CLOCK_HZ: u32 = tr_ae350::board::active::UART_CLOCK_HZ;
/// Candidates the software decoder tries per slot. The value is a compromise to be tuned from the measured decode time on the board.
const MAX_CANDIDATES: usize = 30;

/// The software decoder (mfsk-core, one pass, receiver 0): the fall-back whenever the chip's engines
/// are not there, do not answer, or miss a slot. `ms_since_slot_start` is how long ago the slot began.
fn decode_in_software(radio: &Radio<Mmio, Ddr>, clock: &CycleClock<Mmio>, station: &mut Station, slot: i64, ms_since_slot_start: i64) {
    let mut con = &uart::CONSOLE;
    let (audio, n) = radio.slot_audio(ms_since_slot_start);
    if n == 0 {
        // Nothing was received for this slot because the HL2 is not streaming. Decoding the zeros takes about 14 s of
        // main-loop time on the board for nothing, and that stops the network input.
        let _ = writeln!(con, "slot {}: no audio received, software decoder not run", slot);
        station.on_decodes(slot, &[]);
        return;
    }
    let t0 = clock.cycles();
    let heard = decode_slot(&audio, slot, MAX_CANDIDATES);
    let ms = (clock.cycles() - t0) / 120_000; // the cycle counter runs at 120 MHz
    let _ = writeln!(con, "slot {}: software decoder, {} samples, {} decodes in {} ms, S-meter {:.0} dBFS", slot, n, heard.len(), ms, radio.smeter_dbfs());
    station.on_decodes(slot, &heard);
    for (i, h) in heard.iter().rev().enumerate().take(10) {
        let _ = writeln!(con, "  [{}] {:>3} dB {:+.1} s {:>4.0} Hz  {}", i, h.snr_db, h.dt_s, h.audio_hz, h.text);
    }
}

#[panic_handler]
fn panic(info: &PanicInfo) -> ! {
    let mut con = &uart::CONSOLE;
    let _ = writeln!(con, "PANIC: {info}");
    loop {}
}

#[exception(Exception::IllegalInstruction)]
unsafe fn illegal_instruction(_frame: &TrapFrame) -> ! {
    // The first suspect for an illegal instruction is the numbers of the Andes cache CSRs (tr-ae350 cctl.rs), which are not confirmed.
    let mut con = &uart::CONSOLE;
    let _ = writeln!(con, "ILLEGAL INSTRUCTION mepc={:#x} mcause={:#x}", tr_ae350::mepc(), tr_ae350::mcause());
    loop {}
}

/// The layout of a USB keyboard (docs/USB_HOST.md section 6). `Layout::De` for a German one.
const USB_KEY_LAYOUT: tr_usbh::hid::Layout = tr_usbh::hid::Layout::Us;

#[entry]
fn main() -> ! {
    let mut con = &uart::CONSOLE;
    con.init(UART_CLOCK_HZ, 184_320); // 184,320 baud is the rate the board tools listen at (the flash loader divides for 50 MHz at an 80 MHz UART clock)
    let _ = writeln!(con, "\r\nfpga-sdr FT8 firmware, call {MY_CALL} {MY_GRID}");
    unsafe { tr_ae350::fpu::enable() };
    unsafe { tr_ae350::cctl::enable_caches() };
    unsafe { tr_app::heap::init(HEAP_BASE, HEAP_LEN) };

    let sys = System::new(&REGS);
    let st = sys.status();
    let _ = writeln!(con, "chip id {:#010x} build {:08x}, register bus {}, DDR3 {}, PLLs {}", sys.id(), sys.build(), if sys.bus_test() { "ok" } else { "FAULT" }, if st.ddr3_init { "up" } else { "NOT UP" }, if st.plls_locked { "locked" } else { "NOT LOCKED" });

    let _ = writeln!(con, "receivers in the chip: {} (register layout holds {})", st.num_rx, tr_fabric::system::MAX_RECEIVERS);
    // USB audio device (docs/USB_AUDIO.md): one status line at start. The logic streams without firmware; the
    // reader of the PC's playback samples (speech for transmit) is not in the main loop yet.
    let _ = tr_fabric::usb::UsbAudio::new(&REGS).status_line(&mut con);
    let _ = writeln!(con);
    // USB host on the Pmod board (docs/USB_HOST.md): mouse and keyboard work the screen, a headset gets the
    // receiver audio. Its microphone only reaches the speech FIFO once something selects it
    // (`UsbHost::set_speech_from_mic`); nothing here transmits.
    let usb_host_present = tr_fabric::usbh::UsbHost::new(&REGS).present();
    let mut usb_host = tr_usbh::host::Host::new();
    let mut usb_keys: alloc::collections::VecDeque<u8> = alloc::collections::VecDeque::new();
    let _ = writeln!(con, "USB host: {}", if usb_host_present { "in the chip" } else { "not in this chip" });
    let mut radio = Radio::new(&REGS, &DDR);
    for c in radio.check() {
        let _ = writeln!(con, "block {:<10} id {:#010x} {}", c.name, c.id, if c.ok() { "ok" } else { "UNEXPECTED" });
    }
    let mut station_cfg = StationConfig::new(MY_CALL, MY_GRID);
    // In echo mode the slots we transmit in carry our own signal: decode them too.
    station_cfg.decode_own_slots = matches!(TX_SINK, TxSink::Echo);
    let mut station = Station::new(station_cfg);
    radio.start_receive(station.dial_hz());
    if let Err(e) = radio.start_display(WATERFALL_RECT) {
        let _ = writeln!(con, "waterfall window not placed: {e:?}");
    }
    let _ = writeln!(con, "zoom receiver in the chip: {}; waterfall window shows: {:?}", radio.zoom_running(), radio.waterfall_shown());
    let _ = writeln!(con, "receiver 0 on {} Hz; FT8 engines in the chip: {}", station.dial_hz(), radio.ft8_engines_present());
    // The chip's FT8 front end decodes receiver 0 when it is there and answers; otherwise (and with
    // TR_FT8_SOFT) the software decoder does. Chosen once, here; never given up on: a bad slot falls back to software for that slot only.
    let mut chip = if radio.ft8_engines_present() && !FORCE_SOFT {
        match ChipDecoder::new(&REGS, &DDR, &[RxPlan { rx: 0, operator: true }], Budget::AE350) {
            Ok(c) => Some(c),
            Err(e) => {
                let _ = writeln!(con, "FT8 front end did not accept its set-up ({e:?}): decoding in software");
                None
            }
        }
    } else {
        None
    };
    let _ = writeln!(con, "FT8 decoder: {}", if chip.is_some() { "chip front end" } else { "software" });
    let mut chip_pending: Option<i64> = None;
    // The slot whose first decodes the chip path has already given the station (more may follow).
    let mut chip_partial: Option<i64> = None;
    let mut chip_warned: u32 = 0;

    match HL2_PROGRAM {
        Some(p) => writeln!(con, "HL2 program: built in, {} bytes, version 0x{:08x}, CRC-32 {:08x}", p.bytes.len(), p.version, p.crc32),
        None => writeln!(con, "HL2 program: not built in (build with HL2_MSG_BIN and HL2_MSG_VERSION to update the HL2's saved program)"),
    }
    .ok();
    let mut session = Hl2Session::new(&REGS, Hl2Packets::new(&REGS), SessionConfig { tx_sink: TX_SINK, hl2_program: HL2_PROGRAM, ..SessionConfig::default() }, station.dial_hz());
    let mut session_phase = session.phase();
    let mut session_msg_layer = MsgLayer::Off;
    let mut session_program = session.hl2_status().program;
    // RF AGC (docs/HL2_CONTROL.md): the HL2's RX gain from the full-band waterfall lines; starts manual at the session's gain
    let mut rfagc = RfAgc::new(SessionConfig::default().rx_gain_db, AgcConfig::default());
    let mut wideband = FullBandLevel::new(&REGS, &DDR);

    let clock = CycleClock::new(&REGS);
    let slint_clock = CycleClock::new(&REGS);
    let screen = Screen::new(move || Duration::from_micros(slint_clock.cycles() / 120));
    let mut fb = FrameBuffers::new(&REGS, &DDR, map::FRAME_BUFFER);
    let mut manual = ManualClock::default();
    // The HL2 is on SFP0 (the lane is started here, and the session runs on the registers of the HL2 link); the home
    // network is the RJ45 unit, where SNTP sets the clock (docs/HL2_SFP.md).
    let mut sfplane = tr_app::sfplane::SfpLane::new(&REGS);
    // on the heap: the store holds the input service's receive buffer (about 9 KB), and the stack is 32 KB (memory-ae350.x)
    let net_store = alloc::boxed::Box::leak(alloc::boxed::Box::new(tr_net::nettime::NetStore::new()));
    // no stored address setting exists in this firmware yet (None); the address and the name come from the chip's ID (docs/NET_ID.md)
    let mut rj45 = tr_app::rj45net::Rj45Net::new(&REGS, net_store, clock.cycles() / 120, None);
    let _ = writeln!(con, "{}", rj45.identity());
    // the PC's mouse and keyboard over the home network (docs/NETINPUT.md): input only, never a transmit key
    let mut netin = tr_input::NetInputService::new(USB_KEY_LAYOUT);
    rj45.serve_udp(tr_input::UDP_PORT);
    let mut netin_addr_shown = false;
    let mut net_tx_dropped = 0u32;
    // Measurements for the 5 s line (docs/NETINPUT.md section 6): the longest main-loop pass, the RJ45 receive ring.
    let mut last_pass_ms = (clock.cycles() / 120_000) as i64;
    let mut longest_pass_ms = 0i64;
    let mut eth_drop_room = 0u32;
    let mut eth_drop_bad = 0u32;
    // The network and the PC's input are served from inside the long jobs too (decoders, waits on the chip): about
    // every 20 ms, through `tr_modes::yield_hook` (docs/NETINPUT.md section 6).
    let mut yield_last_us = 0u64;
    // LISTEN (docs/LISTEN.md): the station, and its receiver and audio while the screen is shown. The audio ring holds
    // 85 ms, so the audio is topped up from the main loop, the yield hook and the screen drawing.
    let mut listen_on = false;
    let mut lst = ListenStation::new();
    let mut lradio: Option<ListenRadio<Mmio, Ddr>> = None;
    let mut listen_filter_group = None;
    let mut next_listen_log_ms = 0i64;
    let mut listen_longest_pass_ms = 0i64;
    let mut ansi = tr_input::AnsiKeys::new();
    macro_rules! listen_audio {
        () => {{
            if let Some(l) = lradio.as_mut() {
                l.service(clock.cycles() / 120);
            }
        }};
    }
    macro_rules! net_service {
        () => {{
            let now_us = clock.cycles() / 120;
            rj45.poll(now_us);
            let mut sink = tr_app::netinput::ScreenSink::new(&screen, &mut usb_keys, USB_KEY_LAYOUT);
            netin.poll(&mut tr_app::netinput::RjSocket(&mut rj45), &mut sink, (now_us / 1000) as u32);
        }};
    }
    macro_rules! with_yield {
        ($body:expr) => {{
            let mut hook = || {
                let now_us = clock.cycles() / 120;
                if now_us.wrapping_sub(yield_last_us) >= 20_000 {
                    yield_last_us = now_us;
                    net_service!();
                    listen_audio!();
                }
            };
            tr_modes::yield_hook::scope(&mut hook, || $body)
        }};
    }
    let _ = writeln!(con, "netinput: UDP port {} on the RJ45 address (printed when DHCP gives it); PC program tools/radio_input.py", tr_input::UDP_PORT);
    let mut next_frame_ms = 0i64;
    let mut next_status_ms = 1_000i64;
    let mut next_hl2_dbg_ms = 0i64;
    let mut display_on = false;
    let mut swap_timeouts_shown = 0u32;
    let video = Video::new(&REGS);
    let _ = writeln!(con, "keys: t TX enable, c CQ, h halt, s TX slot, 0-9 answer line, [ ] band, - + TX Hz, u hhmmss clock, , . clock +-0.1 s, m FreeDV");
    let _ = writeln!(con, "LISTEN keys: arrows tune and volume, Page Up/Down 100 kHz, Home/End band, l k w a g f LSB USB CW AM SAM FM, b filter, , . step, o AGC, q squelch, e d waterfall sensitivity up/down, r v waterfall contrast wider/narrower, x z waterfall speed faster/slower, m FT8");

    // FreeDV receive mode: while on, the FT8 slot logic, decoders and clock keys are idle.
    let mut freedv_on = false;
    let mut fdv = FdvStation::new();
    let mut next_fdv_log_ms = 0i64;

    // Into LISTEN (the callers have switched TX off): receiver 1 and the audio start, the waterfall window shows the
    // zoom receiver on the tuned frequency, the HL2's band filter follows the frequency.
    macro_rules! enter_listen {
        () => {{
            chip_pending = None;
            chip_partial = None;
            lradio = Some(ListenRadio::start(&REGS, &DDR, &lst));
            radio.set_listen_speed_for_start(lst.waterfall_speed());
            lst.zoom = match radio.start_display_listen(WATERFALL_RECT, lst.freq_hz(), listen::zoom_span(lst.mode())) {
                Ok(z) => z,
                Err(e) => {
                    let _ = writeln!(con, "waterfall window not placed: {e:?}");
                    false
                }
            };
            session.on_action(&Action::Retune { dial_hz: lst.freq_hz() });
            listen_filter_group = Some(filter_band(lst.freq_hz()));
            screen.set_listen(true);
            listen_on = true;
            let _ = writeln!(con, "LISTEN: {} Hz {}, receiver {}, waterfall {}; TX off", lst.freq_hz(), lst.mode().name(), listen::RX, if lst.zoom { "on the zoom receiver" } else { "none (no zoom receiver)" });
        }};
    }
    // Out of LISTEN: receiver 1 and the audio stop; the caller sets up the next screen.
    macro_rules! leave_listen {
        () => {{
            if let Some(mut l) = lradio.take() {
                l.stop();
            }
            listen_on = false;
            listen_filter_group = None;
            screen.set_listen(false);
        }};
    }

    // The radio starts on the LISTEN screen (all modes), and FT8 and FreeDV are one key (`m`) or button away.
    // Built with TR_START_FT8=1 it starts on the FT8 screen.
    if option_env!("TR_START_FT8").is_none() {
        enter_listen!();
    }
    loop {
        let mono_ms = (clock.cycles() / 120_000) as i64;
        let pass_ms = mono_ms - last_pass_ms;
        last_pass_ms = mono_ms;
        longest_pass_ms = longest_pass_ms.max(pass_ms);
        listen_longest_pass_ms = listen_longest_pass_ms.max(pass_ms);
        listen_audio!();
        if pass_ms >= 1_000 {
            let _ = writeln!(con, "loop: the last pass took {pass_ms} ms (the network and input were served every ~20 ms inside it)");
        }
        let mut actions: alloc::vec::Vec<Action> = alloc::vec::Vec::new();

        // The PC's mouse and keyboard over the network (docs/NETINPUT.md) go first, into the same screen and key queue as
        // the USB host's; the screen's events below then include the clicks they made.
        net_service!();
        if !netin_addr_shown {
            if let Some(a) = rj45.address() {
                netin_addr_shown = true;
                let _ = writeln!(con, "netinput: listening on {}.{}.{}.{} UDP port {}", a[0], a[1], a[2], a[3], tr_input::UDP_PORT);
            }
        }

        // The operator: console keys, and the screen's own controls once a pointer exists.
        let mut events = screen.take_events();
        // Network input is input only: while the network has just pressed a button or key, the screen's transmit
        // events (TX enable, CQ, TX slot, answering a line, TX frequency) are dropped, so a click from the PC cannot
        // arm or key anything.
        if netin.tx_guard_active(mono_ms as u32) {
            events.retain(|e| {
                if is_transmit_event(e) {
                    net_tx_dropped = net_tx_dropped.wrapping_add(1);
                    let _ = writeln!(con, "netinput: {e:?} from the network dropped (receive only)");
                    false
                } else {
                    true
                }
            });
        }
        netin.events_taken();
        // USB mouse and keyboard: pointer events go to the screen (whose buttons answer in the next pass);
        // a key with an ASCII character also acts as the same console key.
        if usb_host_present {
            let mut bus = tr_fabric::usbh::UsbHost::new(&REGS);
            usb_host.poll(&mut bus, mono_ms as u32, &mut |e| match e {
                tr_usbh::host::Event::Input { event, .. } => {
                    screen.input(event, USB_KEY_LAYOUT);
                    if let tr_usbh::hid::InputEvent::Key { usage, down: true, mods } = event {
                        // ASCII characters, and codes for the arrow, page and Home/End keys (the same as the network's)
                        if let Some(c) = tr_input::console_code(USB_KEY_LAYOUT, usage, mods) {
                            if usb_keys.len() < 32 {
                                usb_keys.push_back(c);
                            }
                        }
                    }
                }
                other => {
                    let _ = writeln!(con, "USB host: {other:?}");
                }
            });
        }
        let mut fdv_events = screen.take_fdv_events();
        let mut listen_events = screen.take_listen_events();
        loop {
            // the serial console's escape sequences (arrows, Page Up/Down) become the USB keyboard's codes
            let key = if let Some(b) = con.try_read_byte() {
                match ansi.feed(b) {
                    Some(k) => k,
                    None => continue,
                }
            } else if let Some(k) = usb_keys.pop_front() {
                k
            } else {
                break;
            };
            if listen_on {
                if let Some(e) = listen::event_for(key) {
                    listen_events.push(e);
                }
                continue;
            }
            if freedv_on {
                if let Some(e) = fdvstation::event_for(key, &fdv) {
                    fdv_events.push(e);
                }
                continue;
            }
            if manual.key(key, mono_ms) {
                continue;
            }
            if let Some(e) = event_for(key, &station) {
                events.push(e);
            }
        }
        for e in events {
            if e == Ft8Event::SwitchToFreedv {
                // TX off first (the existing switch-off path), then the receiver and the screen change over.
                for a in station.force_tx_off() {
                    radio.apply(&a);
                    session.on_action(&a);
                }
                chip_pending = None;
                chip_partial = None;
                radio.enter_freedv(fdv.dial_hz(), fdv.sideband(), fdv.mode(), fdv.squelch());
                if let Err(e) = radio.start_display_freedv(WATERFALL_RECT) {
                    let _ = writeln!(con, "waterfall window not placed: {e:?}");
                }
                session.on_action(&Action::Retune { dial_hz: fdv.dial_hz() });
                screen.set_freedv(true);
                freedv_on = true;
                let _ = writeln!(con, "FreeDV receive: {} {} Hz, waterfall {:?}; TX off", fdv.mode().name(), fdv.dial_hz(), radio.waterfall_shown());
                break;
            }
            if e == Ft8Event::SwitchToListen {
                // TX off first, as for FreeDV; receiver 0 stays on the FT8 dial
                for a in station.force_tx_off() {
                    radio.apply(&a);
                    session.on_action(&a);
                }
                enter_listen!();
                break;
            }
            if e == Ft8Event::TxEnableToggle && !station.tx_enabled() && MY_CALL == "N0CALL" {
                let _ = writeln!(con, "TX stays off: no call sign built in (TR_CALL)");
                continue;
            }
            actions.extend(station.on_event(e));
        }
        for e in fdv_events {
            for a in fdv.on_event(e) {
                if a == FdvAction::SwitchToFt8 {
                    radio.leave_freedv(station.dial_hz());
                    if let Err(e) = radio.start_display(WATERFALL_RECT) {
                        let _ = writeln!(con, "waterfall window not placed: {e:?}");
                    }
                    session.on_action(&Action::Retune { dial_hz: station.dial_hz() });
                    screen.set_freedv(false);
                    freedv_on = false;
                    let _ = writeln!(con, "FT8 receive: {} Hz", station.dial_hz());
                    break;
                }
                if a == FdvAction::SwitchToListen {
                    // FreeDV's audio stops and receiver 0 goes back to the FT8 dial; then LISTEN starts
                    radio.leave_freedv(station.dial_hz());
                    screen.set_freedv(false);
                    freedv_on = false;
                    enter_listen!();
                    break;
                }
                if let Some(dial_hz) = fdvstation::apply(&mut radio, &a) {
                    session.on_action(&Action::Retune { dial_hz });
                    let _ = writeln!(con, "FreeDV dial {} Hz", dial_hz);
                }
            }
            if listen_on {
                break;
            }
        }
        // LISTEN: the operator's changes go to receiver 1, the waterfall and the HL2's band filter.
        for e in listen_events {
            if !listen_on {
                break;
            }
            let c = lst.on_event(e);
            if c.rf_gain_step != 0 {
                rfagc.step(c.rf_gain_step);
            }
            if c.rf_agc_toggle {
                let m = if rfagc.mode() == AgcMode::Auto { AgcMode::Manual } else { AgcMode::Auto };
                rfagc.set_mode(m, mono_ms);
                let _ = writeln!(con, "LISTEN: RF AGC {:?}, RX gain {} dB", m, rfagc.gain_db());
            }
            if c.to_ft8 || c.to_freedv {
                leave_listen!();
                if c.to_ft8 {
                    if let Err(e) = radio.start_display(WATERFALL_RECT) {
                        let _ = writeln!(con, "waterfall window not placed: {e:?}");
                    }
                    session.on_action(&Action::Retune { dial_hz: station.dial_hz() });
                    let _ = writeln!(con, "FT8 receive: {} Hz", station.dial_hz());
                } else {
                    radio.enter_freedv(fdv.dial_hz(), fdv.sideband(), fdv.mode(), fdv.squelch());
                    if let Err(e) = radio.start_display_freedv(WATERFALL_RECT) {
                        let _ = writeln!(con, "waterfall window not placed: {e:?}");
                    }
                    session.on_action(&Action::Retune { dial_hz: fdv.dial_hz() });
                    screen.set_freedv(true);
                    freedv_on = true;
                    let _ = writeln!(con, "FreeDV receive: {} {} Hz; TX off", fdv.mode().name(), fdv.dial_hz());
                }
                break;
            }
            if let Some(l) = lradio.as_mut() {
                l.apply(&lst, &c);
            }
            if c.waterfall {
                // the operator's waterfall floor and range (docs/LISTEN.md section 8); they stay for the other screens' zoom waterfalls
                let (floor_db, range_db) = lst.waterfall_scale();
                radio.set_waterfall_scale(floor_db, range_db);
                let _ = writeln!(con, "LISTEN: waterfall sensitivity {:+} dB from automatic, contrast (range) {} dB", -floor_db, range_db);
            }
            if c.speed {
                // frames per line change in place: no restart of the zoom receiver or the audio (docs/LISTEN.md section 9)
                radio.set_listen_speed(lst.waterfall_speed());
                let _ = writeln!(con, "LISTEN: waterfall speed {:.1} lines/s (preset {})", lst.waterfall_speed_x10() as f32 / 10.0, lst.waterfall_speed());
            }
            if c.mode {
                // the waterfall's span follows the mode (12 kHz for SSB and CW, 24 kHz for AM, SAM and FM)
                radio.set_listen_speed_for_start(lst.waterfall_speed());
                lst.zoom = radio.start_display_listen(WATERFALL_RECT, lst.freq_hz(), listen::zoom_span(lst.mode())).unwrap_or(false);
            } else if c.freq {
                radio.set_listen_zoom_centre(lst.freq_hz());
            }
            if c.freq {
                // the HL2's band filter: a register write only when the filter group changes
                let g = filter_band(lst.freq_hz());
                if listen_filter_group != Some(g) {
                    listen_filter_group = Some(g);
                    session.on_action(&Action::Retune { dial_hz: lst.freq_hz() });
                    let _ = writeln!(con, "LISTEN: HL2 band filter for {} Hz", lst.freq_hz());
                }
            }
            listen_audio!();
        }
        session.poll(mono_ms);
        // RF AGC: a new full-band line is a new reading; gain writes at most 4 a second, through the session
        if let Some(r) = wideband.poll() {
            rfagc.on_level(mono_ms, r);
        }
        if let Some(g) = rfagc.poll_write(mono_ms) {
            session.set_rx_gain_db(g);
        }
        if session.hl2_status().msg_layer != session_msg_layer {
            session_msg_layer = session.hl2_status().msg_layer;
            let _ = writeln!(con, "HL2 message layer: {:?}{}", session_msg_layer, if session_msg_layer == MsgLayer::Absent { " (no answer to HELLO: port 1025 only, no telemetry)" } else { "" });
        }
        if session.hl2_status().program != session_program {
            session_program = session.hl2_status().program;
            let ms = session.last_update_ms().filter(|_| matches!(session_program, ProgramState::Updated | ProgramState::Failed(_)));
            let _ = writeln!(con, "HL2 program: {}{}", session_program, ms.map(|m| alloc::format!(" ({m} ms)")).unwrap_or_default());
        }
        // One line every 5 s about the HL2 link until the stream runs.
        if mono_ms >= next_hl2_dbg_ms {
            next_hl2_dbg_ms = mono_ms + 5_000;
            let st = System::new(&REGS).status();
            let c = tr_fabric::hl2link::Hl2Link::new(&REGS).counters();
            let eth = tr_fabric::eth::Eth(&REGS);
            let eth_rx = if eth.present() {
                let (room, bad) = eth.dropped();
                eth_drop_room += u32::from(room);
                eth_drop_bad += u32::from(bad);
                eth.counts().0
            } else {
                0
            };
            let _ = writeln!(con, "HL2 dbg: {} | rx_dead {} bus_timeout {} | raw {} other {} crc {} gaps {} | ring {} flood stops {} | RJ45 rx {} frames, dropped {} no room {} bad | {} datagrams seen {} applied, {} rejected, {} stale, {} TX keys and {} TX screen events dropped | longest pass {} ms", session.status().0, st.rx_domain_dead, st.bus_timeout, c.raw_frames, c.other_frames, c.crc_errors, c.gaps, c.ring_frames, session.stats.flood_stops, eth_rx, eth_drop_room, eth_drop_bad, netin.input.seen, netin.input.applied, netin.input.rejected, netin.input.stale, netin.input.tx_blocked, net_tx_dropped, longest_pass_ms);
            longest_pass_ms = 0;
            let a = rfagc.state();
            let _ = writeln!(con, "{} | RF AGC {:?}, gain {} dB ({}), level {}", session.hl2_report(), a.mode, a.gain_db, a.reason.name(), a.level.map(|l| alloc::format!("{:.1} dBFS total, {:.1} dBFS peak column", l.total_dbfs, l.peak_dbfs)).unwrap_or_else(|| "none".into()));
        }
        if session.phase() != session_phase {
            session_phase = session.phase();
            let _ = writeln!(con, "{}", session.status().0);
        }
        if session.take_link_lost() && (station.tx_enabled() || radio.tx.is_armed()) {
            let _ = writeln!(con, "HL2 stream lost: TX off");
            actions.extend(station.force_tx_off());
        }
        if radio.tx_forbidden() && (station.tx_enabled() || radio.tx.is_armed()) {
            let _ = writeln!(con, "HL2 trip or over-temperature: TX off");
            actions.extend(station.force_tx_off());
        }

        // Network time first, and the clock set by hand otherwise.
        let mono_us = clock.cycles() / 120;
        sfplane.poll(|us| tr_fabric::mem::FabricMem::delay_us(&DDR, us), mono_ms);
        while let Some(e) = sfplane.take_event() {
            let _ = writeln!(con, "{e}");
        }
        rj45.poll(mono_us);
        while let Some(e) = rj45.take_event() {
            let _ = writeln!(con, "{e}");
        }
        let net_time = rj45.state(mono_us);
        let utc = rj45.utc_ms(mono_us).or(manual.now_utc_ms(mono_ms));
        if !freedv_on && !listen_on {
            actions.extend(station.tick(utc));
        }
        for a in &actions {
            match a {
                Action::StartDecode { slot } => {
                    if chip.as_ref().is_some_and(|c| c.expects(*slot)) {
                        // The chip's search of this slot ends with the slot; the result comes below.
                        chip_pending = Some(*slot);
                    } else {
                        with_yield!(decode_in_software(&radio, &clock, &mut station, *slot, slot_of(utc.unwrap_or(0)).1 as i64));
                    }
                }
                other => {
                    let _ = writeln!(con, "{other:?}");
                    radio.apply(other);
                    session.on_action(other);
                }
            }
        }
        // The chip front end: arms each slot, takes the finished search, decodes through the scheduler.
        if let (Some(c), Some(utc), false) = (chip.as_mut(), utc, freedv_on || listen_on) {
            let (cur_slot, ms) = slot_of(utc);
            match with_yield!(c.poll(cur_slot, ms as i64, &|| {
                tr_modes::yield_hook::call();
                riscv::register::mcycle::read64()
            })) {
                Some(ChipEvent::Partial { slot, pass, heard, .. }) => {
                    // The operator's decodes as soon as they exist (first pass, then what the
                    // second pass added); the slot's `Decoded` follows with the rest.
                    let _ = writeln!(con, "slot {slot}: pass {}, {} decodes, {} ms after the slot end", pass + 1, heard.len(), ms as i64 + (cur_slot - slot - 1) * 15_000);
                    let _ = write!(con, "{}", describe(&heard[..heard.len().min(10)]));
                    if chip_pending == Some(slot) || chip_partial == Some(slot) {
                        chip_pending = None;
                        chip_partial = Some(slot);
                        station.on_decodes(slot, &heard);
                    }
                }
                Some(ChipEvent::Decoded(d)) => {
                    let _ = writeln!(con, "slot {}: chip front end, {} receiver(s), operator first", d.slot, d.rx.len());
                    for r in &d.rx {
                        let _ = writeln!(con, "  rx {}: {} candidates, {} decodes{}{}", r.rx, r.candidates, r.heard.len(), r.error.map(|e| alloc::format!(", CHIP ERROR {e:?}")).unwrap_or_default(), match r.second_pass {
                            SecondPass::NotRun => alloc::string::String::new(),
                            SecondPass::Chip => alloc::format!(", second pass {} candidates, {} more decodes", r.candidates2, r.heard.len() - r.first_pass),
                            SecondPass::Software(e) => alloc::format!(", second pass IN SOFTWARE this slot (chip: {e:?}), {} more decodes", r.heard.len() - r.first_pass),
                            SecondPass::NoBudget => alloc::string::String::from(", no second pass (CPU cap)"),
                        });
                    }
                    for rep in &d.reports {
                        let _ = writeln!(con, "  job rx {}: {} Mcycles of {} cap, next {} candidates{}", rep.rx, rep.spent / 1_000_000, rep.cap / 1_000_000, rep.next_max_cand, if rep.cut.is_some() { ", CUT" } else { "" });
                    }
                    if let Some(op) = d.rx.iter().find(|r| r.operator) {
                        // What `Partial` has not handed out yet.
                        let rest = &op.heard[d.operator_delivered.min(op.heard.len())..];
                        let _ = write!(con, "{}", describe(&rest[..rest.len().min(10)]));
                        if chip_partial == Some(d.slot) {
                            chip_partial = None;
                            station.on_decodes(d.slot, rest);
                        } else if chip_pending == Some(d.slot) {
                            chip_pending = None;
                            if op.error.is_none() {
                                station.on_decodes(d.slot, &op.heard);
                            } else {
                                // The chip failed this slot: the audio is still in the capture.
                                with_yield!(decode_in_software(&radio, &clock, &mut station, d.slot, ms as i64 + (cur_slot - d.slot) * 15_000));
                            }
                        }
                    }
                }
                Some(ChipEvent::Missed { slot }) => {
                    let _ = writeln!(con, "slot {slot}: the chip's search never finished");
                    if chip_pending == Some(slot) {
                        chip_pending = None;
                        with_yield!(decode_in_software(&radio, &clock, &mut station, slot, ms as i64 + (cur_slot - slot) * 15_000));
                    }
                }
                None => {}
            }
            // The chip is never given up on: a bad slot is decoded in software above and the chip is tried again in the
            // next slot, and the console says so every CHIP_STRIKES.
            if c.bad_slots >= CHIP_STRIKES && c.bad_slots != chip_warned {
                chip_warned = c.bad_slots;
                if c.bad_slots % CHIP_STRIKES == 0 {
                    let _ = writeln!(con, "FT8 front end: {} slots in a row decoded in software; still trying the chip each slot", c.bad_slots);
                }
            }
        }
        radio.set_now_ms(mono_ms as u64);
        radio.service();
        listen_audio!();
        // LISTEN: one line every 5 s (frequency, mode, filter, S-meter, audio, the longest main-loop pass)
        if listen_on && mono_ms >= next_listen_log_ms {
            next_listen_log_ms = mono_ms + 5_000;
            if let Some(l) = lradio.as_mut() {
                let _ = writeln!(con, "{}", l.status_line(&lst, listen_longest_pass_ms));
            }
            // the zoom waterfall: lines made, ring write line, window 0, level, what the last line held (docs/LISTEN.md section 8)
            let _ = writeln!(con, "LISTEN {}", radio.zoom_report());
            listen_longest_pass_ms = 0;
        }
        if freedv_on && mono_ms >= next_fdv_log_ms {
            next_fdv_log_ms = mono_ms + 5_000;
            if let Some(f) = radio.freedv() {
                let i = f.rx.indicators();
                let _ = writeln!(
                    con,
                    "FreeDV {}: {:?}, SNR {:.1} dB, offset {:+.1} Hz, frames {} ({} with errors), text {:?}, queue {} ms, ring underruns {}, queue overruns {}, blocks lost {}",
                    i.mode.name(), i.sync, i.snr_db, i.foff_hz, i.frames, i.frames_with_errors, f.rx.text().display(), f.rx.queue.len() / 48, f.out.underruns, f.rx.queue.overruns, radio.ring_lost()
                );
            }
            let _ = writeln!(con, "FreeDV {}", radio.zoom_report());
        }

        // The back buffer is free once the compositor's `fb_active` shows the last swap.
        if mono_ms >= next_frame_ms && fb.back_free(mono_ms as u32) {
            next_frame_ms = mono_ms + 100;
            let (link, link_ok) = session.status();
            let status = match net_time {
                tr_net::nettime::TimeState::Synced { age_s } => ClockStatus::Synced { age_s: age_s as _ },
                _ if utc.is_some() => ClockStatus::Manual,
                tr_net::nettime::TimeState::Waiting => ClockStatus::Waiting,
                tr_net::nettime::TimeState::NoNetwork => ClockStatus::NoNetwork,
            };
            if listen_on {
                let mut ls = lst.screen(lradio.as_ref(), &link, link_ok);
                ls.rf_gain_db = rfagc.gain_db();
                ls.rf_agc_auto = rfagc.mode() == AgcMode::Auto;
                ls.hl2_text = session.hl2_line();
                screen.apply_listen(&ls);
            } else if freedv_on {
                screen.apply_fdv(&fdv.screen(&radio, &link, link_ok));
            } else {
                screen.apply(&station.screen(utc, status, &link, link_ok));
            }
            // SAFETY: the back buffer is `WIDTH * HEIGHT` RGB565 pixels of DDR3 that only this
            // loop writes; the logic reads the other buffer until `present` swaps them.
            let buffer = unsafe { core::slice::from_raw_parts_mut(fb.back_addr() as *mut Rgb565Pixel, WIDTH * HEIGHT) };
            // LISTEN: drawn line by line, the audio ring topped up every 5 ms on the way (a full frame takes long)
            let drawn = if listen_on {
                let mut last_us = clock.cycles() / 120;
                screen.render_with(buffer, || {
                    let now_us = clock.cycles() / 120;
                    if now_us.wrapping_sub(last_us) >= 5_000 {
                        last_us = now_us;
                        listen_audio!();
                    }
                })
            } else {
                screen.render(buffer)
            };
            if let Some((first, lines)) = drawn {
                fb.present(first, lines, mono_ms as u32);
                if !display_on {
                    // The first frame is in DDR3 and shown from the next vertical blank on; the
                    // compositor's color bars give way to the picture at the same blank.
                    radio.show_display();
                    display_on = true;
                    let _ = writeln!(con, "HDMI: compositor on, first frame presented");
                }
            }
        }

        net_service!();
        listen_audio!();

        // Compositor health once a second, on the console only when it is not clean.
        if display_on && mono_ms >= next_status_ms {
            next_status_ms = mono_ms + 1_000;
            let s = video.status();
            if !s.healthy() || fb.swap_timeouts != swap_timeouts_shown {
                swap_timeouts_shown = fb.swap_timeouts;
                let _ = writeln!(
                    con,
                    "HDMI: underrun {} (lines {}), lane error {}, frames {}, swaps not confirmed {}",
                    s.underrun, s.underrun_count, s.lane_error, s.frame_count, fb.swap_timeouts
                );
                video.clear_status();
            }
        }
    }
}
