// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The host: one state machine per port, driven from the main loop with the time in ms
//! (docs/USB_HOST.md section 2). Connect detection, reset, enumeration, the class set-up, then
//! reports to events. The logic underneath is seen through [`Bus`] (the register page, or a
//! simulated device in the tests).

use crate::desc::{self, AudioAlt, Config, DeviceDesc};
use crate::hid::{InputEvent, Keyboard, Mouse, MouseLayout};

/// Number of USB ports on the Pmod board.
pub const PORTS: usize = 2;
/// Bytes of a configuration descriptor that are read (more is cut off; the parser takes what is there).
pub const CFG_MAX: usize = 512;

/// State that the logic puts a port in.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    Off = 0,
    Reset = 1,
    Run = 2,
    Suspend = 3,
    Resume = 4,
}

/// Kind of transaction the logic starts.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Setup = 0,
    Out = 1,
    In = 2,
}

/// Result codes of a transaction (`usbh.port_status.result`).
/// The transaction finished normally.
pub const R_DONE: u8 = 1;
/// The device answered with NAK.
pub const R_NAK: u8 = 2;
/// The device answered with STALL.
pub const R_STALL: u8 = 3;
/// The device did not answer.
pub const R_NO_ANSWER: u8 = 4;
/// The answer arrived damaged.
pub const R_DAMAGED: u8 = 5;
/// The port was not running when the transaction started.
pub const R_NOT_RUNNING: u8 = 6;

/// What the logic reports about one port.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct PortStatus {
    /// Level of the D+ line.
    pub dp: bool,
    /// Level of the D- line.
    pub dn: bool,
    /// The device was disconnected since the last read.
    pub gone: bool,
    /// A transaction is still running.
    pub busy: bool,
    /// Result code of the last transaction (`R_DONE` and the others).
    pub result: u8,
    /// One bit per interrupt slot, set when the slot has stopped (three polls without an answer, or STALL).
    pub slot_err: u8,
}

/// How the logic streams audio to or from a device.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AudioSetup {
    /// Port the device is on.
    pub port: u8,
    /// Endpoint number, without the direction bit.
    pub ep: u8,
    /// One channel instead of two.
    pub mono: bool,
    /// Three bytes per sample instead of two.
    pub bytes3: bool,
    /// Speaker only: most samples per frame.
    pub max_samples: u8,
}

/// What the stack needs from the logic. `fw/tr-fabric/src/usbh.rs` is the real one.
pub trait Bus {
    /// Reads the port's state (this clears the logic's event flags).
    fn status(&mut self, port: usize) -> PortStatus;
    /// Sets the state, the speed and the device address of a port.
    fn set_port(&mut self, port: usize, mode: Mode, low_speed: bool, address: u8);
    /// Starts a transaction; `status().busy` until it is finished. `data`: 8 bytes for SETUP, 0 to
    /// 64 for OUT, ignored for IN. `nak_limit` in frames, 0 = for ever.
    fn start(&mut self, port: usize, kind: Kind, ep: u8, toggle: bool, data: &[u8], nak_limit: u8);
    /// Takes one record out of the port's receive FIFO: (source, length). Source 0 = the IN
    /// transaction, 1 and 2 = interrupt slots 0 and 1.
    fn pop_record(&mut self, port: usize, buf: &mut [u8]) -> Option<(u8, usize)>;
    /// Interrupt slot: `Some((endpoint, interval in ms))` or off.
    fn set_slot(&mut self, port: usize, slot: usize, poll: Option<(u8, u8)>);
    /// Starts or stops streaming to the speaker.
    fn set_speaker(&mut self, cfg: Option<AudioSetup>);
    /// Starts or stops streaming from the microphone.
    fn set_mic(&mut self, cfg: Option<AudioSetup>);
    /// Whether D+ and D- are exchanged.
    fn swap(&self) -> bool;
    /// Exchanges D+ and D- (for a device or cable with the pair crossed).
    fn set_swap(&mut self, swap: bool);
}

/// What a connected device is used for.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Info {
    /// Vendor ID.
    pub vendor: u16,
    /// Product ID.
    pub product: u16,
    /// The device runs at low speed.
    pub low_speed: bool,
    /// The device has a keyboard.
    pub keyboard: bool,
    /// The device has a mouse.
    pub mouse: bool,
    /// The mouse has a wheel.
    pub wheel: bool,
    /// The format the speaker stream is sent in.
    pub speaker: Option<AudioAlt>,
    /// The format the microphone sends; `rate` is what the resampler must be told.
    pub mic: Option<AudioAlt>,
}

/// Why a device is not fully used, for a message to the operator.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Problem {
    /// A hub: not supported.
    Hub,
    /// Audio class 2.0: not supported (HID parts of the device still work).
    Audio2,
    /// Playback only at rates other than 48 kHz, or in a format that is not 16 or 24 bit PCM.
    SpeakerFormat,
    /// The speaker endpoint is asynchronous; its feedback is not read, so it may click now and then.
    AsyncSpeaker,
    /// A second headset: the first one keeps the audio.
    AudioBusy,
    /// Enumeration failed three times (and with D+ and D- exchanged).
    Enumeration,
    /// The device dropped off three times shortly after it was connected: it probably needs more
    /// current than the board's 5 V converter gives.
    Power,
    /// Nothing on the device that this host can use.
    Nothing,
}

/// What the host reports to the main loop.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Event {
    /// A device finished enumeration and is ready to use.
    Connected { port: u8, info: Info },
    /// The device on the port went away.
    Disconnected { port: u8 },
    /// A key or pointer event from a device.
    Input { port: u8, event: InputEvent },
    /// Something about the device on the port cannot be used.
    Problem { port: u8, what: Problem },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum State {
    Empty,
    Debounce,
    Reset,
    Recovery,
    GetDev8,
    SetAddr,
    AddrSettle,
    GetDev,
    GetCfg9,
    GetCfg,
    SetCfg,
    Class,
    Running,
    /// Nothing more to do with this device until it is pulled.
    Parked,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Step {
    SetIdle { iface: u8 },
    /// Read the report descriptor of the interface behind `slot` and decide how its reports look.
    GetReport { iface: u8, len: u16, slot: u8, boot: bool },
    /// Boot or report protocol, as `GetReport` decided (keyboard: always boot).
    SetProtocol { iface: u8, slot: u8 },
    SetIface { iface: u8, alt: u8, speaker: bool },
    SetFreq { ep_addr: u8, hz: u32 },
    Unmute { unit: u8, iface: u8 },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Stage {
    Idle,
    Setup,
    DataIn,
    DataOut,
    StatusIn,
    StatusOut,
}

#[derive(Clone, Copy, Debug)]
enum Drv {
    None,
    Keyboard(Keyboard),
    Mouse(Mouse),
}

const MAX_STEPS: usize = 16;

struct Port {
    state: State,
    t: u32,
    low_speed: bool,
    tries: u8,
    drops: u8,
    t_up: u32,
    // control transfer
    stage: Stage,
    flying: bool,
    setup: [u8; 8],
    out: [u8; 4],
    toggle: bool,
    want: usize,
    got: usize,
    rec: Option<usize>,
    waits: u8,
    mp0: u8,
    buf: [u8; CFG_MAX],
    // the device
    dev: DeviceDesc,
    cfg: Config,
    info: Info,
    steps: [Option<Step>; MAX_STEPS],
    n_steps: usize,
    step: usize,
    drv: [Drv; 2],
    slot_ep: [(u8, u8); 2],
    slot_boot: [bool; 2],
    spk_ok: bool,
    mic_ok: bool,
}

impl Port {
    const fn new() -> Self {
        Port {
            state: State::Empty,
            t: 0,
            low_speed: false,
            tries: 0,
            drops: 0,
            t_up: 0,
            stage: Stage::Idle,
            flying: false,
            setup: [0; 8],
            out: [0; 4],
            toggle: false,
            want: 0,
            got: 0,
            rec: None,
            waits: 0,
            mp0: 8,
            buf: [0; CFG_MAX],
            dev: DeviceDesc { usb_bcd: 0, class: 0, max_packet0: 8, vendor: 0, product: 0, configurations: 0 },
            cfg: Config {
                value: 0,
                total_len: 0,
                hid: [None; desc::MAX_HID],
                speaker: None,
                mic: None,
                speaker_mute: None,
                mic_mute: None,
                audio: false,
                audio2: false,
                speaker_unusable: false,
            },
            info: Info { vendor: 0, product: 0, low_speed: false, keyboard: false, mouse: false, wheel: false, speaker: None, mic: None },
            steps: [None; MAX_STEPS],
            n_steps: 0,
            step: 0,
            drv: [Drv::None; 2],
            slot_ep: [(0, 0); 2],
            slot_boot: [false; 2],
            spk_ok: false,
            mic_ok: false,
        }
    }

    fn ctl<B: Bus>(&mut self, bus: &mut B, p: usize, bm: u8, req: u8, value: u16, index: u16, len: u16, out: &[u8]) {
        self.setup = [bm, req, value as u8, (value >> 8) as u8, index as u8, (index >> 8) as u8, len as u8, (len >> 8) as u8];
        self.out = [0; 4];
        self.out[..out.len()].copy_from_slice(out);
        self.want = (len as usize).min(CFG_MAX);
        self.got = 0;
        self.rec = None;
        self.stage = Stage::Setup;
        self.flying = true;
        self.waits = 0;
        bus.start(p, Kind::Setup, 0, false, &self.setup, 50);
    }

    /// Moves the control transfer on. `Some(Ok(bytes read))` or `Some(Err(result code))` when it has ended.
    fn ctl_poll<B: Bus>(&mut self, bus: &mut B, p: usize, st: &PortStatus) -> Option<Result<usize, u8>> {
        if self.stage == Stage::Idle {
            return None;
        }
        if self.flying {
            if st.busy {
                return None;
            }
            self.flying = false;
            if st.result != R_DONE {
                self.stage = Stage::Idle;
                return Some(Err(st.result));
            }
        }
        let read = self.setup[0] & 0x80 != 0;
        let mut go = |s: &mut Self, kind: Kind, toggle: bool, n: usize| {
            s.flying = true;
            s.rec = None;
            s.waits = 0;
            let data = s.out;
            bus.start(p, kind, 0, toggle, &data[..n], 250);
        };
        match self.stage {
            Stage::Setup => {
                if self.want == 0 {
                    self.stage = Stage::StatusIn;
                    go(self, Kind::In, true, 0);
                } else if read {
                    self.stage = Stage::DataIn;
                    self.toggle = true;
                    go(self, Kind::In, true, 0);
                } else {
                    self.stage = Stage::DataOut;
                    let n = self.want.min(4);
                    go(self, Kind::Out, true, n);
                }
                None
            }
            Stage::DataIn | Stage::StatusIn => {
                // the data came as a record; it is in the FIFO before the transaction says "done"
                let Some(n) = self.rec.take() else {
                    self.waits += 1;
                    if self.waits > 20 {
                        self.stage = Stage::Idle;
                        return Some(Err(R_DAMAGED));
                    }
                    return None;
                };
                if self.stage == Stage::StatusIn {
                    self.stage = Stage::Idle;
                    return Some(Ok(0));
                }
                self.toggle = !self.toggle;
                if n < self.mp0 as usize || self.got >= self.want {
                    self.stage = Stage::StatusOut;
                    go(self, Kind::Out, true, 0);
                } else {
                    let t = self.toggle;
                    go(self, Kind::In, t, 0);
                }
                None
            }
            Stage::DataOut => {
                self.stage = Stage::StatusIn;
                go(self, Kind::In, true, 0);
                None
            }
            Stage::StatusOut => {
                self.stage = Stage::Idle;
                Some(Ok(self.got))
            }
            Stage::Idle => None,
        }
    }

    /// A record of the IN transaction: its bytes go behind what has been read so far.
    fn ctl_data(&mut self, d: &[u8]) {
        if self.stage == Stage::DataIn {
            let n = d.len().min(CFG_MAX - self.got);
            self.buf[self.got..self.got + n].copy_from_slice(&d[..n]);
            self.got += n;
        }
        self.rec = Some(d.len());
    }

    fn push(&mut self, s: Step) {
        if self.n_steps < MAX_STEPS {
            self.steps[self.n_steps] = Some(s);
            self.n_steps += 1;
        }
    }
}

/// The USB host: one state machine per port.
pub struct Host {
    ports: [Port; PORTS],
    spk_port: Option<u8>,
    mic_port: Option<u8>,
    swap_tried: bool,
}

impl Default for Host {
    fn default() -> Self {
        Self::new()
    }
}

impl Host {
    /// A host with every port empty.
    pub const fn new() -> Self {
        Host { ports: [Port::new(), Port::new()], spk_port: None, mic_port: None, swap_tried: false }
    }

    /// What is on a port, if it is up.
    pub fn info(&self, port: usize) -> Option<Info> {
        (self.ports[port].state == State::Running).then_some(self.ports[port].info)
    }

    /// The port with the speaker, and the one with the microphone.
    pub fn audio_ports(&self) -> (Option<u8>, Option<u8>) {
        (self.spk_port, self.mic_port)
    }

    /// Call from the main loop, every few ms or faster. `now_ms` may wrap.
    pub fn poll<B: Bus>(&mut self, bus: &mut B, now_ms: u32, sink: &mut impl FnMut(Event)) {
        for p in 0..PORTS {
            self.poll_port(bus, p, now_ms, sink);
        }
    }

    fn drop_device<B: Bus>(&mut self, bus: &mut B, p: usize, now: u32, sink: &mut impl FnMut(Event), was_up: bool) {
        bus.set_slot(p, 0, None);
        bus.set_slot(p, 1, None);
        if self.spk_port == Some(p as u8) {
            bus.set_speaker(None);
            self.spk_port = None;
        }
        if self.mic_port == Some(p as u8) {
            bus.set_mic(None);
            self.mic_port = None;
        }
        bus.set_port(p, Mode::Off, false, 0);
        let port = &mut self.ports[p];
        for d in port.drv.iter_mut() {
            match d {
                Drv::Keyboard(k) => k.release_all(&mut |e| sink(Event::Input { port: p as u8, event: e })),
                Drv::Mouse(m) => m.release_all(&mut |e| sink(Event::Input { port: p as u8, event: e })),
                Drv::None => {}
            }
            *d = Drv::None;
        }
        if was_up {
            sink(Event::Disconnected { port: p as u8 });
            // a device that keeps dropping off right after it came up: the supply
            if now.wrapping_sub(port.t_up) < 3000 {
                port.drops += 1;
                if port.drops == 3 {
                    sink(Event::Problem { port: p as u8, what: Problem::Power });
                }
            } else {
                port.drops = 0;
            }
        }
        port.stage = Stage::Idle;
        port.flying = false;
        port.state = State::Empty;
        port.tries = 0;
    }

    /// Enumeration went wrong: again from the reset, three times; then the other way up; then give up.
    fn retry<B: Bus>(&mut self, bus: &mut B, p: usize, now: u32, sink: &mut impl FnMut(Event)) {
        let others_idle = (0..PORTS).all(|q| q == p || matches!(self.ports[q].state, State::Empty | State::Parked));
        let port = &mut self.ports[p];
        port.stage = Stage::Idle;
        port.flying = false;
        port.tries += 1;
        if port.tries < 3 {
            bus.set_port(p, Mode::Reset, port.low_speed, 0);
            port.state = State::Reset;
            port.t = now;
        } else if !self.swap_tried && others_idle {
            // a board the other way up shows a full-speed device as low speed, and the reverse
            self.swap_tried = true;
            let s = bus.swap();
            bus.set_swap(!s);
            bus.set_port(p, Mode::Off, false, 0);
            port.tries = 0;
            port.state = State::Empty;
        } else {
            if self.swap_tried && others_idle {
                // the other way up did not help either: back as it was
                let s = bus.swap();
                bus.set_swap(!s);
                self.swap_tried = false;
            }
            bus.set_port(p, Mode::Off, false, 0);
            port.state = State::Parked;
            sink(Event::Problem { port: p as u8, what: Problem::Enumeration });
        }
    }

    fn poll_port<B: Bus>(&mut self, bus: &mut B, p: usize, now: u32, sink: &mut impl FnMut(Event)) {
        let st = bus.status(p);
        let pu = p as u8;

        // records: the IN transaction's data, and reports
        let mut tmp = [0u8; 64];
        for _ in 0..32 {
            let Some((src, n)) = bus.pop_record(p, &mut tmp) else { break };
            let n = n.min(64);
            let port = &mut self.ports[p];
            match src {
                0 => port.ctl_data(&tmp[..n]),
                1 | 2 if port.state == State::Running => match &mut port.drv[src as usize - 1] {
                    Drv::Keyboard(k) => k.report(&tmp[..n], &mut |e| sink(Event::Input { port: pu, event: e })),
                    Drv::Mouse(m) => m.report(&tmp[..n], &mut |e| sink(Event::Input { port: pu, event: e })),
                    Drv::None => {}
                },
                _ => {}
            }
        }

        let state = self.ports[p].state;
        let present = st.dp != st.dn;
        // gone, at any point after the reset
        if !matches!(state, State::Empty | State::Debounce | State::Reset) && (st.gone || (state == State::Parked && !present)) {
            self.drop_device(bus, p, now, sink, state == State::Running);
            return;
        }
        let done = self.ports[p].ctl_poll(bus, p, &st);
        if let Some(Err(code)) = done {
            // a STALL in the class set-up only means "this device does not do that"
            if !(state == State::Class && code == R_STALL) {
                if matches!(state, State::Running | State::Parked) {
                    return;
                }
                self.retry(bus, p, now, sink);
                return;
            }
        }
        let port = &mut self.ports[p];
        let since = now.wrapping_sub(port.t);
        match state {
            State::Empty => {
                if present {
                    port.low_speed = st.dn;
                    port.t = now;
                    port.state = State::Debounce;
                }
            }
            State::Debounce => {
                if !present || port.low_speed != st.dn {
                    port.state = State::Empty;
                } else if since >= 100 {
                    bus.set_port(p, Mode::Reset, port.low_speed, 0);
                    port.t = now;
                    port.state = State::Reset;
                }
            }
            State::Reset => {
                if since >= 50 {
                    bus.set_port(p, Mode::Run, port.low_speed, 0);
                    port.t = now;
                    port.state = State::Recovery;
                }
            }
            State::Recovery => {
                if since >= 20 {
                    port.mp0 = 8;
                    port.ctl(bus, p, 0x80, 6, 0x0100, 0, 8, &[]);
                    port.state = State::GetDev8;
                }
            }
            State::GetDev8 => {
                if let Some(Ok(n)) = done {
                    match desc::parse_device(&port.buf[..n]) {
                        Some(d) if n >= 8 => {
                            port.mp0 = d.max_packet0;
                            port.ctl(bus, p, 0x00, 5, pu as u16 + 1, 0, 0, &[]);
                            port.state = State::SetAddr;
                        }
                        _ => self.retry(bus, p, now, sink),
                    }
                }
            }
            State::SetAddr => {
                if done.is_some() {
                    bus.set_port(p, Mode::Run, port.low_speed, pu + 1);
                    port.t = now;
                    port.state = State::AddrSettle;
                }
            }
            State::AddrSettle => {
                if since >= 5 {
                    port.ctl(bus, p, 0x80, 6, 0x0100, 0, 18, &[]);
                    port.state = State::GetDev;
                }
            }
            State::GetDev => {
                if let Some(Ok(n)) = done {
                    match desc::parse_device(&port.buf[..n]) {
                        Some(d) if n >= 18 => {
                            port.dev = d;
                            if d.class == desc::CLASS_HUB {
                                port.state = State::Parked;
                                sink(Event::Problem { port: pu, what: Problem::Hub });
                            } else {
                                port.ctl(bus, p, 0x80, 6, 0x0200, 0, 9, &[]);
                                port.state = State::GetCfg9;
                            }
                        }
                        _ => self.retry(bus, p, now, sink),
                    }
                }
            }
            State::GetCfg9 => {
                if let Some(Ok(n)) = done {
                    if n >= 9 && port.buf[1] == desc::DT_CONFIG {
                        let total = u16::from_le_bytes([port.buf[2], port.buf[3]]).min(CFG_MAX as u16);
                        port.ctl(bus, p, 0x80, 6, 0x0200, 0, total, &[]);
                        port.state = State::GetCfg;
                    } else {
                        self.retry(bus, p, now, sink);
                    }
                }
            }
            State::GetCfg => {
                if let Some(Ok(n)) = done {
                    match desc::parse_config(&port.buf[..n]) {
                        Some(c) => {
                            port.cfg = c;
                            port.ctl(bus, p, 0x00, 9, c.value as u16, 0, 0, &[]);
                            port.state = State::SetCfg;
                        }
                        None => self.retry(bus, p, now, sink),
                    }
                }
            }
            State::SetCfg => {
                if done.is_some() {
                    self.plan(p, sink);
                    self.ports[p].state = State::Class;
                    self.class_step(bus, p, now, sink, None);
                }
            }
            State::Class => {
                if let Some(r) = done {
                    self.class_step(bus, p, now, sink, Some(r));
                }
            }
            State::Running => {
                // a slot that has stopped (three polls without an answer, or STALL) is started again once
                if st.slot_err != 0 {
                    for s in 0..2 {
                        if st.slot_err >> s & 1 != 0 {
                            bus.set_slot(p, s, None);
                            bus.set_slot(p, s, Some(port.slot_ep[s]));
                        }
                    }
                }
            }
            State::Parked => {}
        }
    }

    /// Decides what to do with the device's interfaces.
    fn plan(&mut self, p: usize, sink: &mut impl FnMut(Event)) {
        let pu = p as u8;
        let (spk_free, mic_free) = (self.spk_port.is_none(), self.mic_port.is_none());
        let port = &mut self.ports[p];
        let c = port.cfg;
        port.n_steps = 0;
        port.step = 0;
        port.drv = [Drv::None; 2];
        port.spk_ok = false;
        port.mic_ok = false;
        port.info = Info { vendor: port.dev.vendor, product: port.dev.product, low_speed: port.low_speed, ..Info::default() };
        // HID: a boot keyboard first, then mice; two slots
        let mut slot = 0usize;
        for pass in 0..2 {
            for h in c.hid.iter().flatten() {
                if slot >= 2 {
                    break;
                }
                let keyboard = h.boot && h.protocol == 1;
                if pass == 0 && keyboard {
                    port.push(Step::SetIdle { iface: h.iface });
                    port.push(Step::SetProtocol { iface: h.iface, slot: slot as u8 });
                    port.drv[slot] = Drv::Keyboard(Keyboard::new());
                } else if pass == 1 && !keyboard && h.protocol == 2 {
                    port.push(Step::SetIdle { iface: h.iface });
                    port.push(Step::GetReport { iface: h.iface, len: h.report_len, slot: slot as u8, boot: h.boot });
                    if h.boot {
                        port.push(Step::SetProtocol { iface: h.iface, slot: slot as u8 });
                    }
                } else {
                    continue;
                }
                port.slot_ep[slot] = (h.ep, h.interval_ms.clamp(1, 32));
                port.slot_boot[slot] = h.boot;
                slot += 1;
            }
        }
        // audio
        if c.audio2 {
            sink(Event::Problem { port: pu, what: Problem::Audio2 });
        }
        if c.speaker_unusable {
            sink(Event::Problem { port: pu, what: Problem::SpeakerFormat });
        }
        if (c.speaker.is_some() && !spk_free) || (c.mic.is_some() && !mic_free) {
            sink(Event::Problem { port: pu, what: Problem::AudioBusy });
        }
        if let (Some(a), true) = (c.speaker, spk_free) {
            port.push(Step::SetIface { iface: a.iface, alt: 0, speaker: true });
            if let Some(m) = c.speaker_mute {
                port.push(Step::Unmute { unit: m.unit, iface: m.control_iface });
            }
            port.push(Step::SetIface { iface: a.iface, alt: a.alt, speaker: true });
            if a.freq_control {
                port.push(Step::SetFreq { ep_addr: a.ep, hz: a.rate });
            }
            port.spk_ok = true;
            if a.sync == 1 {
                sink(Event::Problem { port: pu, what: Problem::AsyncSpeaker });
            }
        }
        if let (Some(a), true) = (c.mic, mic_free) {
            port.push(Step::SetIface { iface: a.iface, alt: 0, speaker: false });
            if let Some(m) = c.mic_mute {
                port.push(Step::Unmute { unit: m.unit, iface: m.control_iface });
            }
            port.push(Step::SetIface { iface: a.iface, alt: a.alt, speaker: false });
            if a.freq_control {
                port.push(Step::SetFreq { ep_addr: a.ep | 0x80, hz: a.rate });
            }
            port.mic_ok = true;
        }
    }

    /// The answer to the step before (if any), then the next step, or the end of the set-up.
    fn class_step<B: Bus>(&mut self, bus: &mut B, p: usize, now: u32, sink: &mut impl FnMut(Event), last: Option<Result<usize, u8>>) {
        let pu = p as u8;
        let port = &mut self.ports[p];
        if let (Some(r), Some(Some(step))) = (last, port.steps.get(port.step.wrapping_sub(1))) {
            match (*step, r) {
                (Step::GetReport { slot, boot, .. }, r) => {
                    let parsed = match r {
                        Ok(n) => MouseLayout::parse(&port.buf[..n]),
                        Err(_) => None,
                    };
                    port.drv[slot as usize] = match (parsed, boot) {
                        (Some(l), _) => Drv::Mouse(Mouse::new(l)),
                        (None, true) => Drv::Mouse(Mouse::new(MouseLayout::BOOT)),
                        (None, false) => Drv::None,
                    };
                }
                // a streaming interface that cannot be switched on is not used
                (Step::SetIface { alt, speaker, .. }, Err(_)) if alt != 0 => {
                    if speaker {
                        port.spk_ok = false;
                    } else {
                        port.mic_ok = false;
                    }
                }
                _ => {}
            }
        }
        if port.step < port.n_steps {
            let step = port.steps[port.step].unwrap();
            port.step += 1;
            match step {
                Step::SetIdle { iface } => port.ctl(bus, p, 0x21, 0x0A, 0, iface as u16, 0, &[]),
                Step::GetReport { iface, len, .. } => {
                    let len = if len == 0 { 64 } else { len.min(CFG_MAX as u16) };
                    port.ctl(bus, p, 0x81, 6, 0x2200, iface as u16, len, &[])
                }
                Step::SetProtocol { iface, slot } => {
                    let boot = match port.drv[slot as usize] {
                        Drv::Mouse(m) => m.layout == MouseLayout::BOOT,
                        _ => true,
                    };
                    port.ctl(bus, p, 0x21, 0x0B, if boot { 0 } else { 1 }, iface as u16, 0, &[])
                }
                Step::SetIface { iface, alt, .. } => port.ctl(bus, p, 0x01, 11, alt as u16, iface as u16, 0, &[]),
                Step::SetFreq { ep_addr, hz } => {
                    port.ctl(bus, p, 0x22, 0x01, 0x0100, ep_addr as u16, 3, &[hz as u8, (hz >> 8) as u8, (hz >> 16) as u8])
                }
                Step::Unmute { unit, iface } => port.ctl(bus, p, 0x21, 0x01, 0x0100, (unit as u16) << 8 | iface as u16, 1, &[0]),
            }
            return;
        }
        // all steps done: switch the logic on
        let c = port.cfg;
        for s in 0..2 {
            match port.drv[s] {
                Drv::Keyboard(_) => port.info.keyboard = true,
                Drv::Mouse(m) => {
                    port.info.mouse = true;
                    port.info.wheel |= m.layout.wheel.size != 0;
                }
                Drv::None => continue,
            }
            bus.set_slot(p, s, Some(port.slot_ep[s]));
        }
        if let (Some(a), true) = (c.speaker, port.spk_ok) {
            let frame = a.channels as u16 * a.subframe as u16;
            bus.set_speaker(Some(AudioSetup {
                port: pu,
                ep: a.ep,
                mono: a.channels == 1,
                bytes3: a.subframe == 3,
                max_samples: (a.max_packet / frame).clamp(48, 49) as u8,
            }));
            port.info.speaker = Some(a);
            self.spk_port = Some(pu);
        }
        if let (Some(a), true) = (c.mic, port.mic_ok) {
            bus.set_mic(Some(AudioSetup { port: pu, ep: a.ep, mono: a.channels == 1, bytes3: a.subframe == 3, max_samples: 0 }));
            port.info.mic = Some(a);
            self.mic_port = Some(pu);
        }
        let i = port.info;
        port.t_up = now;
        port.tries = 0;
        if i.keyboard || i.mouse || i.speaker.is_some() || i.mic.is_some() {
            port.state = State::Running;
            self.swap_tried = false;
            sink(Event::Connected { port: pu, info: i });
        } else {
            port.state = State::Parked;
            if !c.audio2 && !c.speaker_unusable {
                sink(Event::Problem { port: pu, what: Problem::Nothing });
            }
        }
    }
}
