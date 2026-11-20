// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The radio behind the station logic: carries out [`Action`]s on the `tr-fabric` drivers, keeps
//! the last 21.8 s of the operator's receiver's 12 ksps audio together with its HL2 time
//! ([`SlotCapture`]), cuts a slot out of it, and feeds the TX ring while a transmission plays. The
//! same code runs on the board (real registers and DDR3), under QEMU and in host tests (the mock
//! fabric). The main type is [`Radio`].
//!
//! Receive chain set up here: bank receiver 0 at 48 ksps on the dial frequency; back-end receiver
//! 0 in SSB mode with a 100 to 3,100 Hz channel filter (upper sideband unless asked otherwise, 255
//! taps at 24 ksps), 12 ksps out into its DDR3 ring.
//!
//! **Display.** [`Radio::start_display`] and its relatives set up window 0 of the video compositor
//! as the waterfall of the FT8, FreeDV or LISTEN screen: either the chip's zoom receiver writing
//! the picture itself, or a software waterfall computed from the capture ([`crate::waterfall`]).
//! The zoom waterfalls get their color level from [`crate::wflevel`], followed line by line in
//! [`Radio::service`].
//!
//! **TX.** The TX path is switched on in exactly one place, [`Radio::apply`] for
//! [`Action::ArmTx`], which the station logic produces only for the operator's TX switch. This
//! module never touches the HL2 itself: it sends no command to it, so it cannot key it or select
//! its DAC.

use alloc::string::String;
use alloc::vec;
use alloc::vec::Vec;
use core::fmt::Write as _;

use tr_dsp::backend::design::{bandpass, quantize, FS as FILTER_FS};
use tr_fabric::backend::{Backend, BackendRing, BlockHeader, Demod, RxSetup, BLOCK_SAMPLES, HL2_PER_SAMPLE_12K};
use tr_fabric::ft8fe::Ft8FrontEnd;
use tr_fabric::hl2link::{safety, Hl2Link};
use tr_fabric::mem::{map, FabricMem};
use tr_fabric::rxbank::{Rate, RxBank};
use tr_fabric::spectrum::Spectrum;
use tr_fabric::system::System;
use tr_fabric::tx::{OperatorTxPermit, TxPath, TX_RATE};
use tr_fabric::video::{default_palette, Video, Window, WindowError, WindowKind};
use tr_fabric::video::WaterfallSource;
use tr_fabric::wfring::{mem_offset_of_column, SoftWaterfall, WfError, LINE_BYTES};
use tr_fabric::zoom::{self, Span, Zoom};
use tr_modes::txbb::Ft8Baseband;
use tr_regs::RegisterSpace;

use crate::freedv::{FdvMode, FdvOut, FreedvRx};
use crate::qso::Heard;
use crate::station::Action;
use crate::waterfall::{WaterfallGen, HOP as WATERFALL_HOP, WINDOW as WATERFALL_WINDOW};
use crate::wflevel::{WfLevel, DEFAULT_RANGE_DB};

/// Which sideband the receiver's channel filter takes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Sideband {
    /// 100 to 3,100 Hz above the dial frequency (FT8, and SSB above 10 MHz).
    Upper,
    /// 100 to 3,100 Hz below it (SSB below 10 MHz, and FreeDV there).
    Lower,
}

/// PT8211 DAC volume while FreeDV plays (0 to 255), a fixed value.
pub const FDV_VOLUME: u8 = 160;

/// Samples of one slot at 12 ksps.
pub const SLOT_SAMPLES: usize = 180_000;
/// HL2 samples per millisecond (76.8 Msps).
pub const HL2_PER_MS: i64 = 76_800;
/// The operator's receiver.
pub const RX: u32 = 0;
/// Taps of the FT8 channel filter (at 24 ksps).
const FILTER_TAPS: usize = 255;
/// Back-end ring of the FT8 receiver: 2^11 blocks of 128 samples, 21.8 s.
const RING_LOG2: u32 = 11;
/// TX ring fill the feeder aims for: 100 ms. A halted transmission plays on for at most this.
const TX_AHEAD: u32 = TX_RATE / 10;

/// The newest 2^18 samples (21.8 s) of 12 ksps audio, addressed by HL2 sample index.
pub struct SlotCapture {
    buf: Vec<i16>,
    /// Samples written since the start.
    count: u64,
    /// HL2 index of the sample that will be written next; `None` before the first block.
    next_stamp: Option<u64>,
    /// Samples that were missing between blocks and were filled with zeros.
    pub filled: u64,
}

impl Default for SlotCapture {
    fn default() -> Self {
        Self::new()
    }
}

impl SlotCapture {
    const LEN: usize = 1 << 18;

    /// An empty capture.
    pub fn new() -> Self {
        SlotCapture { buf: vec![0; Self::LEN], count: 0, next_stamp: None, filled: 0 }
    }

    fn put(&mut self, s: i16) {
        self.buf[(self.count as usize) & (Self::LEN - 1)] = s;
        self.count += 1;
    }

    /// One ring block. Blocks lost before it leave a gap in the stamps, which is filled with
    /// zeros so that every sample keeps its place in time; a stamp that jumps back (receiver
    /// restarted) starts the capture again.
    pub fn push(&mut self, hdr: &BlockHeader, samples: &[i16; BLOCK_SAMPLES]) {
        if let Some(next) = self.next_stamp {
            if hdr.stamp < next {
                self.count = 0;
            } else {
                let missing = ((hdr.stamp - next) / HL2_PER_SAMPLE_12K).min(Self::LEN as u64);
                for _ in 0..missing {
                    self.put(0);
                }
                self.filled += missing;
            }
        }
        for &s in samples {
            self.put(s);
        }
        self.next_stamp = Some(hdr.stamp + BLOCK_SAMPLES as u64 * HL2_PER_SAMPLE_12K);
    }

    /// Samples received since the start (including the zeros that stand for lost blocks).
    pub fn count(&self) -> u64 {
        self.count
    }

    /// The `out.len()` samples that end just before sample number `end` (counted from the start);
    /// false, and `out` untouched, if they are not all in the buffer.
    pub fn copy_ending_at(&self, end: u64, out: &mut [i16]) -> bool {
        let n = out.len() as u64;
        if end > self.count || end < n || self.count - (end - n) > Self::LEN as u64 {
            return false;
        }
        for (i, o) in out.iter_mut().enumerate() {
            *o = self.buf[((end - n) as usize + i) & (Self::LEN - 1)];
        }
        true
    }

    /// `out.len()` samples starting at HL2 index `start`; what is not (or no longer) in the
    /// buffer comes out as zeros. Returns how many samples were there.
    pub fn extract(&self, start: i64, out: &mut [i16]) -> usize {
        out.fill(0);
        let Some(next) = self.next_stamp else { return 0 };
        let have = self.count.min(Self::LEN as u64) as i64;
        // Sample `count - 1` has stamp `next - 6400` (one 12 ksps sample is 6,400 HL2 samples).
        let first_k = (start - (next as i64 - have * HL2_PER_SAMPLE_12K as i64)).div_euclid(HL2_PER_SAMPLE_12K as i64);
        let mut n = 0;
        for (i, o) in out.iter_mut().enumerate() {
            let k = first_k + i as i64;
            if (0..have).contains(&k) {
                let pos = self.count as i64 - have + k;
                *o = self.buf[(pos as usize) & (Self::LEN - 1)];
                n += 1;
            }
        }
        n
    }
}

/// One line of the start-up check.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BlockCheck {
    /// Name of the register block.
    pub name: &'static str,
    /// The id the block reports.
    pub id: u32,
    /// The id this firmware was written for.
    pub expected: u32,
}

impl BlockCheck {
    /// True if the chip carries the block version the firmware expects.
    pub fn ok(&self) -> bool {
        self.id == self.expected
    }
}

/// Lines per second of the full-band spectrum (trace and hardware waterfall).
pub const FULL_BAND_LINES_PER_S: u32 = 30;

/// What the FT8 screen's waterfall window shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Ft8Waterfall {
    /// Computed here from the receiver's audio ([`crate::waterfall`]): 0 to 3,000 Hz across the
    /// window, 2.56 Hz per column, the scale the screen is drawn for.
    Software,
    /// The chip's zoom receiver, written by the logic (docs/ZOOM_IN_CHIP.md section 12): its 6 kHz
    /// span at the FT8 column scale, 2.56 Hz per column from the dial frequency up, the same scale
    /// as the software waterfall; a line every 0.55 s (1.83 a second), each over the last 0.55 s.
    /// Falls back to [`Ft8Waterfall::Software`] in a chip without the zoom receiver (or with its
    /// first version, 48 kHz at the narrowest), and for a window whose width is not 3,000 Hz at
    /// that scale ([`ft8_scale_fits`]).
    FpgaZoom,
}

/// The build's choice for the FT8 screen ([`Radio::start_display`]): the chip's zoom waterfall
/// where it fits (see [`Ft8Waterfall::FpgaZoom`]), the software waterfall otherwise.
pub const FT8_WATERFALL: Ft8Waterfall = Ft8Waterfall::FpgaZoom;

/// Center of the zoom receiver above the dial frequency when it is not the FT8 screen's waterfall:
/// the middle of the 0 to 3,000 Hz audio band, Hz.
pub const ZOOM_CENTRE_ABOVE_DIAL_HZ: u32 = 1_500;
/// Waterfall rows per second asked of the zoom receiver (its 48 kHz span makes 14.6 transforms a second).
pub const ZOOM_LINES_PER_S: u32 = 7;
/// The same as the FT8 screen's waterfall: every transform of the 6 kHz span is a row (1.83 a second).
pub const ZOOM_FT8_LINES_PER_S: u32 = 2;
/// Frames per line the zoom writes to end a line that does not end (more than any K used here, 7 at most).
pub const ZOOM_K_RECOVER: u32 = 8;
/// No new zoom line for this long: the line in progress may be stuck (see `tr_fabric::zoom`).
pub const ZOOM_STALL_MS: u64 = 4_000;
/// `ctrl.narrow_gain` of the zoom waterfalls the screens show (FT8, FreeDV, LISTEN): 3 = times 64
/// (36.12 dB). With 16 (the driver's default) the receiver's own noise with no antenna is about 0.3
/// step per component of the power word at 12 kHz and 6 kHz: most columns are exactly 0 and the
/// waterfall stays black at any level (docs/LISTEN.md section 8). Cost: the narrow spans' stage
/// saturates for a tone above about -28 dBFS within about 15 kHz of the center (16: -16 dBFS).
pub const ZOOM_NARROW_GAIN: u32 = 3;

/// True if a waterfall window `w` columns wide shows 3,000 Hz, within 1 %, at the zoom receiver's
/// FT8 column scale (2.56 Hz per column): 1,161 to 1,183 columns. The FT8 screen's is 1,172.
pub const fn ft8_scale_fits(w: u32) -> bool {
    let hz1000 = w as u64 * zoom::FT8_MILLIHZ_PER_COLUMN as u64;
    hz1000 >= 2_970_000 && hz1000 <= 3_030_000
}

/// Why the display could not be started.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DisplayError {
    /// The video window could not be set up.
    Window(WindowError),
    /// The software waterfall ring could not be set up.
    Waterfall(WfError),
}

/// What the waterfall window is set up for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum View {
    /// The FT8 screen, with the waterfall that was asked for.
    Ft8(Ft8Waterfall),
    /// The FreeDV screen.
    Freedv,
}

/// The software waterfall: its ring in DDR3, the line generator and where in the audio it is.
struct WaterfallState<'a, R: RegisterSpace, M: FabricMem> {
    ring: SoftWaterfall<'a, R, M>,
    gen: WaterfallGen,
    /// The next line ends at this sample of the capture (counted from the start).
    next_end: u64,
    /// The audio the next line is computed from.
    window: Vec<i16>,
    /// The line being built, one palette index per column.
    line: Vec<u8>,
}

/// The fabric as the station logic sees it: receiver, audio capture, TX feeder, waterfall and
/// FreeDV chain. Call [`Radio::service`] often.
pub struct Radio<'a, R: RegisterSpace, M: FabricMem> {
    regs: &'a R,
    mem: &'a M,
    /// The TX path (off until [`Action::ArmTx`]).
    pub tx: TxPath<'a, R, M>,
    wf: Option<WaterfallState<'a, R, M>>,
    /// Waterfall lines drawn since the display started.
    pub waterfall_lines: u64,
    /// What the waterfall window shows (set by [`Radio::start_display_with`]).
    shown: Ft8Waterfall,
    /// The zoom receiver is in the chip and was started.
    zoom_on: bool,
    /// Its center above the dial frequency (it follows every retune); negative = below.
    zoom_above_dial_hz: i32,
    /// The back end's audio ring, once the receiver is started.
    ring: Option<BackendRing>,
    /// The receiver's audio, by HL2 time.
    pub capture: SlotCapture,
    /// The FT8 transmission being fed to the TX ring, if one is playing.
    wave: Option<Ft8Baseband>,
    /// Peak of I and Q in the TX ring.
    pub tx_amplitude: i16,
    /// Group delay of the channel filter in HL2 samples (subtracted from the stamps).
    filter_delay: i64,
    /// TX ring words written since start (for reports).
    pub tx_words: u64,
    /// Dial frequency the receiver was last set to (the zoom receiver follows it).
    dial_hz: u32,
    sideband: Sideband,
    /// FreeDV receive, while that mode runs.
    fdv: Option<FdvChain<'a, R, M>>,
    /// The colors of the zoom waterfall in window 0, while it shows one ([`crate::wflevel`]).
    zcol: Option<ZoomColours>,
    /// The operator's waterfall floor (dB) and range (dB), kept across screens.
    wf_floor_db: i32,
    wf_range_db: u32,
    /// LISTEN waterfall speed asked for, lines per second ([`crate::listen::SPEED_PRESETS`]); used by
    /// [`Radio::start_display_listen`] and followed by [`Radio::set_listen_speed`].
    listen_lps: u32,
    /// The LISTEN view is the one shown (not FT8 or FreeDV).
    listen_view: bool,
    /// A lower K waiting for the next new line (see `tr_fabric::zoom`, "Changing K while running").
    zoom_pending_k: Option<u32>,
    /// Milliseconds of the caller's clock ([`Radio::set_now_ms`]) and when a zoom line was last seen.
    now_ms: u64,
    zoom_line_ms: u64,
    /// K was raised to [`ZOOM_K_RECOVER`] to end a line that did not end; the wanted K is pending.
    zoom_recovering: bool,
}

/// The zoom waterfall in window 0 and its color level.
struct ZoomColours {
    /// Visible source columns: `w` columns from `src_x0`.
    src_x0: u32,
    w: u32,
    /// Ring line last looked at (`video.wf_zoom_write_line`).
    last_line: u32,
    /// `zoom.backend_line_count` when the view started.
    start_count: u32,
    /// The level state ([`crate::wflevel`]).
    level: WfLevel,
    /// The visible columns of the last line read back.
    buf: Vec<u8>,
}

/// FreeDV receive: the chain and the audio engine behind it.
pub struct FdvChain<'a, R: RegisterSpace, M: FabricMem> {
    /// The FreeDV receive chain.
    pub rx: FreedvRx,
    /// The audio engine that plays its speech.
    pub out: FdvOut<'a, R, M>,
}

impl<'a, R: RegisterSpace, M: FabricMem> Radio<'a, R, M> {
    /// Takes the fabric over with the TX path off.
    pub fn new(regs: &'a R, mem: &'a M) -> Self {
        Radio {
            regs,
            mem,
            tx: TxPath::new(regs, mem, map::TX_RING),
            wf: None,
            waterfall_lines: 0,
            shown: Ft8Waterfall::Software,
            zoom_on: false,
            zoom_above_dial_hz: ZOOM_CENTRE_ABOVE_DIAL_HZ as i32,
            ring: None,
            capture: SlotCapture::new(),
            wave: None,
            tx_amplitude: 16_000,
            filter_delay: ((FILTER_TAPS as i64 - 1) / 2) * 3_200,
            tx_words: 0,
            dial_hz: 0,
            sideband: Sideband::Upper,
            fdv: None,
            zcol: None,
            wf_floor_db: 0,
            wf_range_db: DEFAULT_RANGE_DB,
            listen_lps: crate::listen::ZOOM_LINES_PER_S,
            listen_view: false,
            zoom_pending_k: None,
            now_ms: 0,
            zoom_line_ms: 0,
            zoom_recovering: false,
        }
    }

    /// The block ids against what this firmware was written for.
    pub fn check(&self) -> [BlockCheck; 9] {
        use tr_regs::generated as g;
        let r = self.regs;
        [
            BlockCheck { name: "system", id: g::system::id::read(r), expected: g::system::id::RESET },
            BlockCheck { name: "hl2_link", id: g::hl2_link::id::read(r), expected: g::hl2_link::id::RESET },
            BlockCheck { name: "rx_bank", id: g::rx_bank::id::read(r), expected: g::rx_bank::id::RESET },
            BlockCheck { name: "rx_backend", id: g::rx_backend::id::read(r), expected: g::rx_backend::id::RESET },
            BlockCheck { name: "spectrum", id: g::spectrum::id::read(r), expected: g::spectrum::id::RESET },
            BlockCheck { name: "video", id: g::video::id::read(r), expected: g::video::id::RESET },
            BlockCheck { name: "tx", id: g::tx::id::read(r), expected: g::tx::id::RESET },
            BlockCheck { name: "audio", id: g::audio::id::read(r), expected: g::audio::id::RESET },
            BlockCheck { name: "ft8", id: g::ft8::id::read(r), expected: g::ft8::id::RESET },
        ]
    }

    /// True if the chip has the FT8 engines (`chipdec::ChipDecoder` then decodes through them).
    pub fn ft8_engines_present(&self) -> bool {
        Ft8FrontEnd::new(self.regs).engines_present()
    }

    /// Starts the FT8 receiver on `dial_hz` (upper sideband).
    pub fn start_receive(&mut self, dial_hz: u32) {
        self.start_receive_sb(dial_hz, Sideband::Upper);
    }

    /// Starts the receiver on `dial_hz` in the given sideband: the same 100 to 3,100 Hz channel
    /// filter, mirrored for the lower sideband (FreeDV needs only 0.7 to 2.3 kHz of it; the width of
    /// this filter is fixed), 12 ksps audio into the DDR3 ring.
    pub fn start_receive_sb(&mut self, dial_hz: u32, sideband: Sideband) {
        let bank = RxBank::new(self.regs);
        let backend = Backend::new(self.regs);
        backend.stop(RX);
        self.sideband = sideband;
        let (lo, hi) = match sideband {
            Sideband::Upper => (100.0, 3_100.0),
            Sideband::Lower => (-3_100.0, -100.0),
        };
        let coef = quantize(&bandpass(FILTER_FS, lo, hi, FILTER_TAPS));
        let n = coef.ntaps as usize;
        backend.load_bank(0, 0, &coef.re[..n], &coef.im[..n], coef.exp);
        bank.set_frequency_hz(RX, dial_hz);
        self.dial_hz = dial_hz;
        bank.start(RX, Rate::K48);
        backend.start(RX, &RxSetup { demod: Demod::Ssb, in_rate: Rate::K48, agc: true, bank: 0 });
        self.ring = Some(backend.open_ring(RX, map::backend_ring(RX), RING_LOG2));
        self.tx.set_frequency_hz(dial_hz);
        Hl2Link::new(self.regs).set_rx_enable(true);
    }

    /// [`Radio::start_display_with`] with the build's choice, [`FT8_WATERFALL`].
    pub fn start_display(&mut self, waterfall: (u32, u32, u32, u32)) -> Result<(), DisplayError> {
        self.start_display_with(waterfall, FT8_WATERFALL)
    }

    /// The logic's waterfall window on the screen's key-color rectangle (`x, y, w, h` in pixels).
    ///
    /// - [`Ft8Waterfall::Software`]: the audio waterfall this module computes ([`crate::waterfall`])
    ///   from the receiver's audio. Waterfall window 0 gets a ring of its own that the CPU writes
    ///   and scrolls (`tr_fabric::wfring`); lines come from [`Radio::service`].
    /// - [`Ft8Waterfall::FpgaZoom`], if the chip has the zoom receiver and the window is 3,000 Hz
    ///   wide at its FT8 scale ([`ft8_scale_fits`]): window 0 shows the zoom receiver's hardware
    ///   waterfall, 6 kHz span at 2.56 Hz per column, the dial frequency at the window's left
    ///   edge; the CPU does nothing per line. Otherwise: as `Software`.
    ///
    /// Either way the full-band spectrum is started, and the zoom receiver if there is one (as
    /// the FT8 waterfall, or else 48 kHz around the middle of the audio band; it follows
    /// [`Action::Retune`]), each hardware waterfall going into its own ring, so another window
    /// can show them. The picture is not switched on here: call [`Radio::show_display`] once the
    /// first frame of the screen has been presented. On an error the window is not placed.
    pub fn start_display_with(&mut self, waterfall: (u32, u32, u32, u32), choice: Ft8Waterfall) -> Result<(), DisplayError> {
        self.start_display_view(waterfall, View::Ft8(choice))
    }

    /// The waterfall window of the FreeDV screen, for the sideband the receiver was started in
    /// ([`Radio::start_receive_sb`]). With the zoom receiver: its 6 kHz span (3.125 Hz per column,
    /// 1.83 lines a second) centered on the middle of the audio band, 1,500 Hz above the dial
    /// frequency (below it for the lower sideband), the window showing the middle of the 1,920
    /// columns: the signal sits in the center of the window, whichever of 700D and 700E it is. The
    /// picture is in RF order, so for the lower sideband audio frequency falls from left to right.
    /// Without the zoom receiver: the software waterfall, 0 to 3,000 Hz of audio, 2.56 Hz per column,
    /// audio order.
    pub fn start_display_freedv(&mut self, waterfall: (u32, u32, u32, u32)) -> Result<(), DisplayError> {
        self.start_display_view(waterfall, View::Freedv)
    }

    /// Starts the zoom receiver with `s`. K goes down only at a line boundary (`tr_fabric::zoom`,
    /// "Changing K while running"): if `k` is below the one the receiver holds (a value this firmware
    /// wrote, at most [`ZOOM_K_RECOVER`]; the reset value is higher), the old K stays for now and the
    /// new one is applied when the next line appears ([`Radio::service`]).
    fn start_zoom_k(&mut self, s: &zoom::Setup, k: u32) {
        let zoom = Zoom::new(self.regs);
        let cur = zoom.averaging_k();
        self.zoom_pending_k = None;
        self.zoom_recovering = false;
        if k < cur && cur <= ZOOM_K_RECOVER {
            zoom.start_with_k(s, cur);
            self.zoom_pending_k = Some(k);
        } else {
            zoom.start_with_k(s, k);
        }
    }

    /// Common part of the FT8 and FreeDV displays: chooses between the zoom and the software
    /// waterfall for `view` and the window width, and starts the spectrum and zoom receivers.
    fn start_display_view(&mut self, waterfall: (u32, u32, u32, u32), view: View) -> Result<(), DisplayError> {
        self.listen_view = false;
        let video = Video::new(self.regs);
        let (x, y, w, h) = waterfall;
        video.set_palette(0, &default_palette());
        // Each hardware writer's ring first, then the spectrum that feeds it.
        video.set_waterfall_ring(map::WATERFALL_RING);
        Spectrum::new(self.regs).start(FULL_BAND_LINES_PER_S, false, false);
        let zoom = Zoom::new(self.regs);
        self.zoom_on = zoom.present();
        let as_ft8 = matches!(view, View::Ft8(Ft8Waterfall::FpgaZoom)) && self.zoom_on && ft8_scale_fits(w);
        let as_freedv = view == View::Freedv && self.zoom_on && w <= zoom::COLUMNS;
        if self.zoom_on {
            video.set_zoom_waterfall_ring(map::ZOOM_WATERFALL_RING);
            if as_ft8 {
                // Column 0 of the zoom line is the dial frequency: 2.56 Hz per column from there.
                self.zoom_above_dial_hz = zoom::FT8_LOW_EDGE_BELOW_CENTRE_HZ as i32;
                let s = zoom::Setup {
                    centre_hz: self.zoom_centre_hz(self.dial_hz),
                    span: Span::FT8,
                    lines_per_s: ZOOM_FT8_LINES_PER_S,
                    mean_per_column: false,
                    peak_hold: false,
                    narrow_gain: ZOOM_NARROW_GAIN,
                    ft8_columns: true,
                };
                self.start_zoom_k(&s, zoom::rounded_k(s.span, s.lines_per_s));
            } else if as_freedv {
                self.zoom_above_dial_hz = match self.sideband {
                    Sideband::Upper => ZOOM_CENTRE_ABOVE_DIAL_HZ as i32,
                    Sideband::Lower => -(ZOOM_CENTRE_ABOVE_DIAL_HZ as i32),
                };
                let s = zoom::Setup {
                    centre_hz: self.zoom_centre_hz(self.dial_hz),
                    span: Span::FT8,
                    lines_per_s: ZOOM_FT8_LINES_PER_S,
                    mean_per_column: false,
                    peak_hold: false,
                    narrow_gain: ZOOM_NARROW_GAIN,
                    ft8_columns: false,
                };
                self.start_zoom_k(&s, zoom::rounded_k(s.span, s.lines_per_s));
            } else {
                self.zoom_above_dial_hz = ZOOM_CENTRE_ABOVE_DIAL_HZ as i32;
                zoom.start(self.zoom_centre_hz(self.dial_hz), Span::K48, ZOOM_LINES_PER_S, false, false);
                zoom.set_level(0, 0x0100);
            }
        }
        self.wf = None;
        self.zcol = None;
        if as_ft8 || as_freedv {
            video.show_hardware_waterfall(0, WaterfallSource::Zoom, map::ZOOM_WATERFALL_RING).map_err(DisplayError::Window)?;
            let src_x0 = if as_freedv { (zoom::COLUMNS - w) / 2 } else { 0 };
            video.set_window(0, &Window { x, y, w, h, kind: WindowKind::Waterfall, zoom: true, src_x0 }).map_err(DisplayError::Window)?;
            self.begin_zoom_colours(src_x0, w);
            self.shown = Ft8Waterfall::FpgaZoom;
        } else {
            let ring = SoftWaterfall::new(self.regs, self.mem, 0, map::SOFT_WATERFALL_RING, h, w).map_err(DisplayError::Waterfall)?;
            video.set_window(0, &Window { x, y, w, h, kind: WindowKind::Waterfall, zoom: false, src_x0: 0 }).map_err(DisplayError::Window)?;
            self.wf = Some(WaterfallState { ring, gen: WaterfallGen::new(w as usize), next_end: WATERFALL_WINDOW as u64, window: vec![0; WATERFALL_WINDOW], line: vec![0; w as usize] });
            self.shown = Ft8Waterfall::Software;
        }
        Ok(())
    }

    /// The waterfall window of the LISTEN screen (docs/LISTEN.md): the zoom receiver centered on
    /// `centre_hz` with `span`, the middle `w` of its 1,920 columns in the window, so the tuned
    /// frequency is in the middle of the window. The full-band spectrum runs as on the other screens.
    /// Returns false, and hides the window, in a chip without the zoom receiver. The FT8 dial and
    /// the FT8 receiver are not touched; [`Radio::start_display`] gives the FT8 screen back.
    pub fn start_display_listen(&mut self, waterfall: (u32, u32, u32, u32), centre_hz: u32, span: Span) -> Result<bool, DisplayError> {
        let video = Video::new(self.regs);
        let (x, y, w, h) = waterfall;
        self.listen_view = false;
        video.set_palette(0, &default_palette());
        video.set_waterfall_ring(map::WATERFALL_RING);
        Spectrum::new(self.regs).start(FULL_BAND_LINES_PER_S, false, false);
        let zoom = Zoom::new(self.regs);
        self.zoom_on = zoom.present();
        self.wf = None;
        self.zcol = None;
        if !self.zoom_on || w > zoom::COLUMNS {
            video.hide_window(0);
            return Ok(false);
        }
        video.set_zoom_waterfall_ring(map::ZOOM_WATERFALL_RING);
        let s = zoom::Setup { centre_hz, span, lines_per_s: self.listen_lps, mean_per_column: false, peak_hold: false, narrow_gain: ZOOM_NARROW_GAIN, ft8_columns: false };
        self.start_zoom_k(&s, crate::listen::speed_k(span, self.listen_lps));
        self.listen_view = true;
        video.show_hardware_waterfall(0, WaterfallSource::Zoom, map::ZOOM_WATERFALL_RING).map_err(DisplayError::Window)?;
        let src_x0 = (zoom::COLUMNS - w) / 2;
        video.set_window(0, &Window { x, y, w, h, kind: WindowKind::Waterfall, zoom: true, src_x0 }).map_err(DisplayError::Window)?;
        self.begin_zoom_colours(src_x0, w);
        self.shown = Ft8Waterfall::FpgaZoom;
        Ok(true)
    }

    /// The zoom waterfall in window 0 starts: its color level from [`crate::wflevel`], written now
    /// and then followed line by line in [`Radio::service`].
    fn begin_zoom_colours(&mut self, src_x0: u32, w: u32) {
        let level = WfLevel::new(self.wf_floor_db, self.wf_range_db);
        let zoom = Zoom::new(self.regs);
        let (off, gain) = level.level();
        zoom.set_level(off, gain);
        let last_line = Video::new(self.regs).zoom_waterfall_line();
        self.zcol = Some(ZoomColours { src_x0, w, last_line, start_count: zoom.line_count(), level, buf: vec![0; w as usize] });
        self.zoom_line_ms = self.now_ms;
    }

    /// The caller's clock, milliseconds (any origin): lets [`Radio::service`] notice a zoom waterfall
    /// that stopped producing lines. Without it that check does nothing.
    pub fn set_now_ms(&mut self, ms: u64) {
        self.now_ms = ms;
    }

    /// The LISTEN waterfall's speed: the preset (lines per second) the next [`Radio::start_display_listen`]
    /// uses; while the LISTEN waterfall is shown, the zoom receiver's frames per line change now with no
    /// restart: a higher K is written at once, a lower one at the next new line (it is applied in
    /// [`Radio::service`]; `tr_fabric::zoom`, "Changing K while running"). The center, the audio and the
    /// automatic floor are not touched.
    pub fn set_listen_speed(&mut self, lines_per_s: u32) {
        self.listen_lps = lines_per_s;
        if !(self.listen_view && self.zoom_on && self.zcol.is_some()) {
            return;
        }
        let zoom = Zoom::new(self.regs);
        let want = crate::listen::speed_k(zoom.span(), lines_per_s);
        let cur = zoom.averaging_k();
        if want > cur {
            zoom.set_averaging_k(want);
            self.zoom_pending_k = None;
        } else if want < cur {
            self.zoom_pending_k = Some(want);
        } else {
            self.zoom_pending_k = None;
        }
    }

    /// The speed the next [`Radio::start_display_listen`] starts with (no register is written now).
    pub fn set_listen_speed_for_start(&mut self, lines_per_s: u32) {
        self.listen_lps = lines_per_s;
    }

    /// The LISTEN waterfall speed asked for, lines per second.
    pub fn listen_speed(&self) -> u32 {
        self.listen_lps
    }

    /// The operator's waterfall floor (dB, + = darker) and range (dB from black to white); they
    /// apply to every zoom waterfall from now on.
    pub fn set_waterfall_scale(&mut self, floor_db: i32, range_db: u32) {
        self.wf_floor_db = floor_db;
        self.wf_range_db = range_db;
        if let Some(z) = self.zcol.as_mut() {
            let (off, gain) = z.level.set(floor_db, range_db);
            Zoom::new(self.regs).set_level(off, gain);
        }
    }

    /// A new line of the zoom waterfall: its visible columns are read back from the ring and the
    /// color level follows the noise floor ([`crate::wflevel`]).
    fn service_zoom_colours(&mut self) {
        let Some(z) = self.zcol.as_mut() else { return };
        let line = Video::new(self.regs).zoom_waterfall_line();
        if line == z.last_line {
            // No new line for a long time: K written below the count of the line in progress would
            // never end it. Raise K so that it ends; the wanted K is written at the next line.
            if self.now_ms.saturating_sub(self.zoom_line_ms) > ZOOM_STALL_MS && !self.zoom_recovering {
                let zoom = Zoom::new(self.regs);
                let cur = zoom.averaging_k();
                if cur < ZOOM_K_RECOVER {
                    if self.zoom_pending_k.is_none() {
                        self.zoom_pending_k = Some(cur);
                    }
                    zoom.set_averaging_k(ZOOM_K_RECOVER);
                }
                self.zoom_recovering = true;
            }
            return;
        }
        z.last_line = line;
        self.zoom_line_ms = self.now_ms;
        self.zoom_recovering = false;
        if let Some(k) = self.zoom_pending_k.take() {
            // a line just ended: the frame count is 0, K can go down
            Zoom::new(self.regs).set_averaging_k(k);
        }
        let base = map::ZOOM_WATERFALL_RING + (line % tr_fabric::wfring::RING_LINES) * LINE_BYTES;
        let (c0, c1) = (z.src_x0, (z.src_x0 + z.w).min(LINE_BYTES));
        let (m0, m1) = (c0 & !7, (c1 + 7) & !7);
        self.mem.invalidate(base + m0, m1 - m0);
        for m in (m0..m1).step_by(4) {
            let v = self.mem.read32(base + m);
            for k in 0..4 {
                // the CPU reads a lane word little-endian; column 0 is its top byte (tr_fabric::wfring)
                let c = mem_offset_of_column(m + k);
                if (c0..c1).contains(&c) {
                    z.buf[(c - c0) as usize] = (v >> (8 * k)) as u8;
                }
            }
        }
        if let Some((off, gain)) = z.level.line(&z.buf) {
            Zoom::new(self.regs).set_level(off, gain);
        }
    }

    /// The operator's waterfall floor and range.
    pub fn waterfall_scale(&self) -> (i32, u32) {
        (self.wf_floor_db, self.wf_range_db)
    }

    /// One line on the zoom waterfall for the console: lines made, the ring's write line, window 0,
    /// the zoom receiver's settings, the level and what the last line held.
    pub fn zoom_report(&self) -> String {
        use tr_regs::generated::{video as vid, zoom as zm};
        let r = self.regs;
        let mut s = String::new();
        let zc = zm::ctrl::read(r);
        let lvl = zm::backend_level::read(r);
        let wc = vid::win_ctrl::read(r, 0);
        let src = match vid::wf_win_ctrl::read(r, 0).line_src() {
            0 => "full band",
            1 => "zoom",
            _ => "CPU",
        };
        let ring = vid::wf_win_ring::read(r, 0) * 8;
        let count = zm::backend_line_count::read(r);
        let _ = write!(
            s,
            "zoom waterfall: zoom id {:#010x} ctrl {:#06x} (enable {}, span {} Hz, gain x{}), lines {}",
            zm::id::read(r),
            zc.0,
            zc.enable() as u8,
            Zoom::new(r).span().hz(),
            1u32 << (2 * zc.narrow_gain()),
            count
        );
        if let Some(z) = self.zcol.as_ref() {
            let _ = write!(s, " ({} since the view started)", count.wrapping_sub(z.start_count));
        }
        let _ = write!(
            s,
            ", ring write line {}, window 0 {} {} source {} ring {:#010x}{} top line {} columns {}+{}, level offset {:+.2} dB gain {}/256",
            Video::new(r).zoom_waterfall_line(),
            if wc.enable() { "on" } else { "OFF" },
            if wc.type_waterfall() { "waterfall" } else { "trace" },
            src,
            ring,
            if ring == map::ZOOM_WATERFALL_RING { "" } else { " (NOT the zoom ring)" },
            vid::wf_win_top::read(r, 0),
            vid::win_src::read(r, 0).x0(),
            vid::win_size::read(r, 0).w(),
            lvl.offset_db64() as u16 as i16 as f32 / 64.0,
            lvl.gain_q8()
        );
        match self.zcol.as_ref() {
            Some(z) => {
                let l = &z.level;
                let st = l.last;
                let db = |b: u8| WfLevel::db64_of_index(b, l.applied()) as f32 / 64.0;
                let _ = write!(
                    s,
                    ", sensitivity {:+} dB, contrast (range) {} dB, speed {:.1} lines/s ({} frames per line{}), last line {} columns {} black, index low {} mean {} peak {} ({:.1} / {:.1} / {:.1} dB of the line), floor estimate {:.1} dB, lines measured {}",
                    -l.floor_db(),
                    l.range_db(),
                    zoom::lines_per_s_at(Zoom::new(r).span(), zm::backend_averaging_k::read(r)),
                    zm::backend_averaging_k::read(r),
                    match self.zoom_pending_k {
                        Some(k) => alloc::format!(", {k} pending"),
                        None => String::new(),
                    },
                    st.columns,
                    st.zeros,
                    st.low,
                    st.mean,
                    st.peak,
                    db(st.low),
                    db(st.mean),
                    db(st.peak),
                    l.floor_estimate_db(),
                    l.lines
                );
            }
            None => {
                let _ = write!(s, ", no zoom waterfall shown");
            }
        }
        s
    }

    /// Moves the LISTEN waterfall's center (the tuned frequency).
    pub fn set_listen_zoom_centre(&self, centre_hz: u32) {
        if self.zoom_on {
            Zoom::new(self.regs).set_centre_hz(centre_hz);
        }
    }

    /// What the waterfall window shows since the last [`Radio::start_display_with`].
    pub fn waterfall_shown(&self) -> Ft8Waterfall {
        self.shown
    }

    /// True if the chip has the zoom receiver and it was started.
    pub fn zoom_running(&self) -> bool {
        self.zoom_on
    }

    /// Center frequency of the zoom receiver for a dial frequency, Hz.
    fn zoom_centre_hz(&self, dial_hz: u32) -> u32 {
        (dial_hz as i64 + self.zoom_above_dial_hz as i64) as u32
    }

    /// HDMI shows the composed picture from the next vertical blank (until now: the compositor's
    /// color bars). Call after the first frame is in DDR3 and presented.
    pub fn show_display(&self) {
        Video::new(self.regs).start(false);
    }

    /// Carries out one action of the station logic. `StartDecode` is the caller's (it owns the
    /// decoder): see [`Radio::slot_audio`].
    pub fn apply(&mut self, action: &Action) {
        match action {
            Action::Retune { dial_hz } => {
                RxBank::new(self.regs).set_frequency_hz(RX, *dial_hz);
                self.tx.set_frequency_hz(*dial_hz);
                self.dial_hz = *dial_hz;
                if self.zoom_on {
                    Zoom::new(self.regs).set_centre_hz(self.zoom_centre_hz(*dial_hz));
                }
            }
            // The one place the TX path is switched on: the station logic produces ArmTx only
            // for the operator's TX switch.
            Action::ArmTx => self.tx.arm(OperatorTxPermit::from_operator_action()),
            Action::DisarmTx => {
                self.wave = None;
                self.tx.disarm();
            }
            Action::StartTx { msg, audio_hz, skip_ms, .. } => {
                self.wave = None;
                if self.tx.is_armed() {
                    if let Some(mut w) = Ft8Baseband::from_message(&msg.f1, &msg.f2, &msg.f3, *audio_hz as f32, self.tx_amplitude) {
                        w.skip(*skip_ms as usize * (TX_RATE as usize / 1_000));
                        self.wave = Some(w);
                    }
                }
            }
            Action::StopTx => self.wave = None,
            Action::StartDecode { .. } => {}
        }
    }

    /// Call often (at least every 50 ms while transmitting): tops the TX ring up to 100 ms and
    /// moves new received audio into the capture. Returns the TX words queued.
    pub fn service(&mut self) -> usize {
        let mut queued = 0;
        if let Some(w) = self.wave.as_mut() {
            let mut chunk = [0u32; 256];
            loop {
                let fill = self.tx.fill();
                let want = (TX_AHEAD.saturating_sub(fill) as usize).min(chunk.len());
                if want == 0 {
                    break;
                }
                let n = w.fill(&mut chunk[..want]);
                if n == 0 || self.tx.push(&chunk[..n]) != n {
                    break;
                }
                queued += n;
            }
            if w.remaining() == 0 {
                self.wave = None;
            }
        }
        self.tx_words += queued as u64;
        if let Some(ring) = self.ring.as_mut() {
            let capture = &mut self.capture;
            let fdv = &mut self.fdv;
            ring.poll(self.regs, self.mem, |h, s| {
                capture.push(h, s);
                if let Some(f) = fdv.as_mut() {
                    f.rx.feed_12k(s);
                }
            });
        }
        if let Some(f) = self.fdv.as_mut() {
            f.out.pump(&mut f.rx);
        }
        self.service_waterfall();
        self.service_zoom_colours();
        queued
    }

    /// One waterfall line for every [`WATERFALL_HOP`] new samples of audio (a decode that keeps the
    /// loop busy for a second or two is caught up on the next call, up to 16 lines at a time; a
    /// longer stop skips the lines it missed).
    fn service_waterfall(&mut self) {
        let Some(wf) = self.wf.as_mut() else { return };
        let count = self.capture.count();
        if count + (2 * WATERFALL_HOP) as u64 <= wf.next_end.saturating_sub(WATERFALL_WINDOW as u64) {
            // The capture started again from zero.
            wf.next_end = (WATERFALL_WINDOW as u64).max(count);
        }
        let mut made = 0;
        while wf.next_end <= count && made < 16 {
            if self.capture.copy_ending_at(wf.next_end, &mut wf.window) {
                wf.gen.line(&wf.window, &mut wf.line);
                wf.ring.push_line(&wf.line);
                self.waterfall_lines += 1;
            }
            wf.next_end += WATERFALL_HOP as u64;
            made += 1;
        }
        if wf.next_end + ((8 * WATERFALL_HOP) as u64) < count {
            wf.next_end = count;
        }
    }

    /// The software waterfall's ring (for tests and reports), if the display is started.
    pub fn waterfall_ring(&self) -> Option<&SoftWaterfall<'a, R, M>> {
        self.wf.as_ref().map(|w| &w.ring)
    }

    /// True while a transmission is being fed.
    pub fn playing(&self) -> bool {
        self.wave.is_some()
    }

    /// The 15 s of audio of the slot that started `ms_since_slot_start` ms ago, as far as it has
    /// been received (the rest is zeros). The HL2's sample index read now ties UTC to the audio's
    /// stamps. Returns the audio and how many samples were there.
    pub fn slot_audio(&self, ms_since_slot_start: i64) -> (Vec<i16>, usize) {
        let now = Hl2Link::new(self.regs).sample_index() as i64;
        let start = now - ms_since_slot_start * HL2_PER_MS + self.filter_delay;
        let mut audio = vec![0i16; SLOT_SAMPLES];
        let n = self.capture.extract(start, &mut audio);
        (audio, n)
    }

    /// Starts FreeDV receive: the receiver in `sideband` on `dial_hz`, its audio through the
    /// FreeDV chain ([`FreedvRx`]) into the audio engine's CPU ring. Nothing here touches the TX
    /// path: the caller has switched TX off first. The audio engine is on until [`Radio::leave_freedv`].
    pub fn enter_freedv(&mut self, dial_hz: u32, sideband: Sideband, mode: FdvMode, squelch: (bool, f32)) {
        self.start_receive_sb(dial_hz, sideband);
        let mut rx = FreedvRx::new(mode);
        rx.set_squelch(squelch.0, squelch.1);
        self.fdv = Some(FdvChain { rx, out: FdvOut::new(self.regs, self.mem, FDV_VOLUME) });
    }

    /// Ends FreeDV receive: the audio engine off, the receiver back on the FT8 dial frequency (upper sideband).
    pub fn leave_freedv(&mut self, ft8_dial_hz: u32) {
        if let Some(mut f) = self.fdv.take() {
            f.out.stop();
        }
        self.start_receive_sb(ft8_dial_hz, Sideband::Upper);
    }

    /// New dial frequency (and sideband) while FreeDV runs. A change of sideband restarts the
    /// receiver (filter and ring) and the modem; the zoom receiver follows either way.
    pub fn freedv_retune(&mut self, dial_hz: u32, sideband: Sideband) {
        if sideband != self.sideband {
            self.start_receive_sb(dial_hz, sideband);
            if let Some(f) = self.fdv.as_mut() {
                let m = f.rx.mode();
                f.rx.set_mode(m);
                f.out.rebuffer();
            }
        } else {
            RxBank::new(self.regs).set_frequency_hz(RX, dial_hz);
            self.dial_hz = dial_hz;
        }
        if self.zoom_on {
            self.zoom_above_dial_hz = match sideband {
                Sideband::Upper => ZOOM_CENTRE_ABOVE_DIAL_HZ as i32,
                Sideband::Lower => -(ZOOM_CENTRE_ABOVE_DIAL_HZ as i32),
            };
            Zoom::new(self.regs).set_centre_hz(self.zoom_centre_hz(dial_hz));
        }
    }

    /// 700D or 700E: the modem starts again.
    pub fn freedv_set_mode(&mut self, mode: FdvMode) {
        if let Some(f) = self.fdv.as_mut() {
            f.rx.set_mode(mode);
            f.out.rebuffer();
        }
    }

    /// Switches the FreeDV squelch on or off and sets its level, dB.
    pub fn freedv_set_squelch(&mut self, on: bool, level_db: f32) {
        if let Some(f) = self.fdv.as_mut() {
            f.rx.set_squelch(on, level_db);
        }
    }

    /// The FreeDV chain, while that mode runs.
    pub fn freedv(&self) -> Option<&FdvChain<'a, R, M>> {
        self.fdv.as_ref()
    }

    /// Blocks the back end's ring overwrote before they were read (the capture and FreeDV both miss them).
    pub fn ring_lost(&self) -> u32 {
        self.ring.as_ref().map(|r| r.lost).unwrap_or(0)
    }

    /// The sideband the receiver was started in.
    pub fn sideband(&self) -> Sideband {
        self.sideband
    }

    /// The HL2 says it may not transmit (trip or over-temperature).
    pub fn tx_forbidden(&self) -> bool {
        Hl2Link::new(self.regs).safety_byte() & (safety::TRIP | safety::OVER_TEMP) != 0
    }

    /// Link state for the screen: text, and whether samples are arriving.
    pub fn link_status(&self) -> (String, bool) {
        let link = Hl2Link::new(self.regs);
        let sys = System::new(self.regs).status();
        let mut s = String::new();
        if sys.rx_domain_dead {
            let _ = write!(s, "HL2: no Ethernet link");
            return (s, false);
        }
        if !link.streaming() {
            let _ = write!(s, "HL2: link up, no samples");
            return (s, false);
        }
        let c = link.counters();
        let _ = write!(s, "HL2: streaming, {} gaps, {} CRC errors", c.gaps, c.crc_errors);
        let sb = link.safety_byte();
        if sb & safety::TRIP != 0 {
            let _ = write!(s, ", TRIP");
        }
        if sb & safety::OVER_TEMP != 0 {
            let _ = write!(s, ", over temperature");
        }
        (s, true)
    }

    /// S-meter of the FT8 receiver in dB relative to full scale.
    pub fn smeter_dbfs(&self) -> f32 {
        Backend::new(self.regs).smeter_db64(RX) as f32 / 64.0
    }
}

/// Software FT8 decode of one slot (mfsk-core's single-pass pipeline, 200 to 3,000 Hz), for a chip
/// without the FT8 engines (see [`Radio::ft8_engines_present`] and `chipdec`).
pub fn decode_slot(audio: &[i16], slot: i64, max_candidates: usize) -> Vec<Heard> {
    tr_modes::decode::ft8::decode_slot_light(audio, 200.0, 3_000.0, 1.3, max_candidates)
        .into_iter()
        .map(|d| Heard { slot, snr_db: libm::roundf(d.snr_db.unwrap_or(0.0)).clamp(-30.0, 50.0) as i8, dt_s: d.dt_sec, audio_hz: d.freq_hz, text: d.message })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn block(seq: u64, base: u64) -> (BlockHeader, [i16; BLOCK_SAMPLES]) {
        let mut s = [0i16; BLOCK_SAMPLES];
        for (k, v) in s.iter_mut().enumerate() {
            *v = ((seq as usize * BLOCK_SAMPLES + k) % 30_000) as i16 + 1;
        }
        (BlockHeader { stamp: base + seq * 128 * HL2_PER_SAMPLE_12K, seq: seq as u32, smeter_db64: 0 }, s)
    }

    #[test]
    fn waterfall_window_takes_the_zoom_receiver_only_when_asked_and_present() {
        use tr_fabric::mock::MockFabric;
        use tr_regs::generated::{spectrum as sp, video as vid, zoom as zm};
        let rect = (20, 124, 1_172, 656);
        // A chip without the zoom receiver: the software waterfall, whatever was asked for.
        let f = MockFabric::new();
        f.log_limit.set(1);
        let mut r = Radio::new(&f, &f);
        r.start_receive(14_074_000);
        r.start_display_with(rect, Ft8Waterfall::FpgaZoom).unwrap();
        assert_eq!(r.waterfall_shown(), Ft8Waterfall::Software);
        assert!(!r.zoom_running() && r.waterfall_ring().is_some());
        assert_eq!(f.reg(vid::wf_win_ctrl::addr(0)), 2);
        assert_eq!(f.reg(vid::wf_win_ring::addr(0)), map::SOFT_WATERFALL_RING / 8);
        assert_eq!(f.reg(zm::ctrl::addr()), 0);
        // The full-band spectrum runs beside it, into its own ring.
        assert_eq!(f.reg(sp::ctrl::addr()) & 1, 1);
        assert_eq!(f.reg(vid::wf_ring_base::addr()), map::WATERFALL_RING / 8);

        // With the zoom receiver, asked for: the hardware zoom waterfall, no software lines.
        let f = MockFabric::new();
        f.log_limit.set(1);
        f.poke(zm::id::addr(), zm::id::RESET);
        let mut r = Radio::new(&f, &f);
        r.start_receive(14_074_000);
        r.start_display_with(rect, Ft8Waterfall::FpgaZoom).unwrap();
        assert_eq!(r.waterfall_shown(), Ft8Waterfall::FpgaZoom);
        assert!(r.zoom_running() && r.waterfall_ring().is_none());
        assert_eq!(f.reg(vid::wf_zoom_ring_base::addr()), map::ZOOM_WATERFALL_RING / 8);
        assert_eq!(f.reg(vid::wf_win_ring::addr(0)), map::ZOOM_WATERFALL_RING / 8);
        assert_eq!(f.reg(vid::wf_win_ctrl::addr(0)), 1);
        // 6 kHz span (span_shift 6, narrow_shift 3), gain 64, the FT8 column scale, enabled; the dial
        // frequency at column 0 (the center 2,999 Hz above it), column 0 at the window's left edge;
        // the color level of crate::wflevel (60 dB, floor at index 32)
        assert_eq!(f.reg(zm::ctrl::addr()), (1 << 11) | (3 << 9) | (3 << 6) | (6 << 1) | 1);
        assert_eq!(f.reg(zm::backend_averaging_k::addr()), 1);
        assert_eq!(f.reg(zm::phase_inc::addr()), tr_fabric::phase_inc(14_076_999));
        assert_eq!(f.reg(zm::backend_level::addr()), (1_092 << 16) | 480);
        assert_eq!(f.reg(vid::win_src::addr(0)), 0);
        r.apply(&Action::Retune { dial_hz: 7_074_000 });
        assert_eq!(f.reg(zm::phase_inc::addr()), tr_fabric::phase_inc(7_076_999));
        r.service();
        assert_eq!(r.waterfall_lines, 0);

        // The build's default is the zoom waterfall too.
        let f = MockFabric::new();
        f.log_limit.set(1);
        f.poke(zm::id::addr(), zm::id::RESET);
        let mut r = Radio::new(&f, &f);
        r.start_receive(14_074_000);
        r.start_display(rect).unwrap();
        assert_eq!(FT8_WATERFALL, Ft8Waterfall::FpgaZoom);
        assert_eq!(r.waterfall_shown(), Ft8Waterfall::FpgaZoom);

        // Asked for the software waterfall, or a window that is not 3,000 Hz wide at the zoom's FT8
        // scale: the software waterfall, the zoom receiver running at 48 kHz for the other window.
        for (rect, choice) in [(rect, Ft8Waterfall::Software), ((20, 124, 900, 656), Ft8Waterfall::FpgaZoom)] {
            let f = MockFabric::new();
            f.log_limit.set(1);
            f.poke(zm::id::addr(), zm::id::RESET);
            let mut r = Radio::new(&f, &f);
            r.start_receive(14_074_000);
            r.start_display_with(rect, choice).unwrap();
            assert_eq!(r.waterfall_shown(), Ft8Waterfall::Software);
            assert!(r.zoom_running() && r.waterfall_ring().is_some());
            assert_eq!(f.reg(zm::ctrl::addr()), (6 << 1) | 1);
            assert_eq!(f.reg(zm::phase_inc::addr()), tr_fabric::phase_inc(14_075_500));
            assert_eq!(f.reg(vid::wf_win_ctrl::addr(0)), 2);
        }
        assert!(ft8_scale_fits(1_172) && ft8_scale_fits(1_161) && ft8_scale_fits(1_183));
        assert!(!ft8_scale_fits(1_160) && !ft8_scale_fits(1_184) && !ft8_scale_fits(1_920));
    }

    #[test]
    fn zoom_waterfall_colours_follow_the_noise_floor() {
        use tr_fabric::mock::MockFabric;
        use tr_fabric::wfring::pack_line;
        use tr_regs::generated::{video as vid, zoom as zm};
        let f = MockFabric::new();
        f.log_limit.set(1);
        f.poke(zm::id::addr(), zm::id::RESET);
        let mut r = Radio::new(&f, &f);
        r.start_receive(14_074_000);
        assert!(r.start_display_listen((20, 124, 1_172, 656), 14_200_000, Span::from_shift(8)).unwrap());
        let level = || {
            let v = f.reg(zm::backend_level::addr());
            ((v & 0xFFFF) as u16 as i16, (v >> 16) as u16)
        };
        assert_eq!(level(), (480, 1_092));
        // The logic writes ring line `n` with the level in the register: columns -4 to +8 dB around
        // `floor_db` of the line (the RTL's color byte), then moves its write line.
        let put_line = |n: u32, floor_db: f32| -> [u8; 1_920] {
            let (off, gain) = level();
            let mut cols = [0u8; 1_920];
            for (c, b) in cols.iter_mut().enumerate() {
                let db64 = ((floor_db + (c * 7 % 13) as f32 - 4.0) * 64.0) as i64;
                *b = (((db64 + off as i64) * gain as i64) >> 14).clamp(0, 255) as u8;
            }
            let base = map::ZOOM_WATERFALL_RING + n * LINE_BYTES;
            pack_line(&cols, |w, v| f.poke_mem(base + 4 * w, v));
            f.poke(vid::wf_zoom_write_line::addr(), n);
            cols
        };
        // far below the first guess (all black at first), then far above it
        for (first, floor_db) in [(1u32, -15.0f32), (40, 70.0)] {
            for n in first..first + 30 {
                put_line(n, floor_db);
                r.service();
            }
            let cols = put_line(first + 30, floor_db);
            let s = crate::wflevel::LineStats::of(&cols[374..374 + 1_172]);
            assert!((s.low as i32 - crate::wflevel::FLOOR_INDEX).abs() <= 6 && s.zeros == 0, "floor {floor_db} dB: {s:?}");
            r.service();
            // what was read back from the ring is the line written (the visible columns)
            assert_eq!(r.zcol.as_ref().unwrap().level.last, s);
        }
        let rep = r.zoom_report();
        assert!(rep.contains("span 12000 Hz, gain x64") && rep.contains("ring write line 70") && rep.contains("window 0 on waterfall source zoom") && rep.contains("columns 374+1172"), "{rep}");
        assert!(!rep.contains("NOT the zoom ring") && rep.contains("lines measured"), "{rep}");
        // the operator's floor: +6 dB darker, written at once
        let before = level();
        r.set_waterfall_scale(6, 60);
        assert_eq!(level().0, before.0 - 6 * 64);
        assert_eq!(r.waterfall_scale(), (6, 60));
    }

    #[test]
    fn listen_speed_changes_k_in_place_and_lowers_it_only_after_a_new_line() {
        use tr_fabric::mock::MockFabric;
        use tr_regs::generated::{video as vid, zoom as zm};
        let f = MockFabric::new();
        f.log_limit.set(1);
        f.poke(zm::id::addr(), zm::id::RESET);
        let mut r = Radio::new(&f, &f);
        r.start_receive(14_074_000);
        let rect = (20, 124, 1_172, 656);
        let k = || f.reg(zm::backend_averaging_k::addr());
        let ssb = Span::from_shift(8);
        // the default, 7 lines per second, asks for every transform at both spans
        assert!(r.start_display_listen(rect, 14_200_000, ssb).unwrap());
        assert_eq!(k(), 1);
        let (ctrl_writes, level) = (f.reg_writes(zm::ctrl::addr()).len(), f.reg(zm::backend_level::addr()));
        // slower (a higher K): written at once, nothing restarted, center and level untouched
        r.set_listen_speed(2);
        assert_eq!(k(), 2);
        r.set_listen_speed(1);
        assert_eq!(k(), 4);
        assert_eq!(f.reg_writes(zm::ctrl::addr()).len(), ctrl_writes, "no restart");
        assert_eq!(f.reg(zm::backend_level::addr()), level);
        assert_eq!(f.reg(zm::phase_inc::addr()), tr_fabric::phase_inc(14_200_000));
        assert!(r.zoom_running() && r.zoom_on);
        // faster (a lower K): held until the next new line, which has just ended (frame count 0)
        r.set_listen_speed(5);
        assert_eq!(k(), 4);
        assert!(r.zoom_report().contains("1 pending"), "{}", r.zoom_report());
        r.service();
        assert_eq!(k(), 4, "no new line yet");
        f.poke(vid::wf_zoom_write_line::addr(), 5);
        r.service();
        assert_eq!(k(), 1);
        assert!(r.zoom_report().contains("speed 3.7 lines/s (1 frames per line)"), "{}", r.zoom_report());
        // a mode change (the span changes, the zoom restarts) from a slow K to a faster one: the old K stays until the next line
        r.set_listen_speed(1);
        assert_eq!(k(), 4);
        r.set_listen_speed_for_start(5);
        assert!(r.start_display_listen(rect, 9_650_000, Span::from_shift(7)).unwrap());
        assert_eq!(k(), 4);
        f.poke(vid::wf_zoom_write_line::addr(), 6);
        r.service();
        assert_eq!(k(), 2, "5 lines per second at 24 kHz is every second transform (3.7 per second)");
        // a line that never ends (K written too low for the line in progress): after 4 s without a new line K is
        // raised so that it ends, then the wanted K is written at the next line
        r.set_now_ms(1_000);
        r.service();
        r.set_now_ms(5_500);
        r.service();
        assert_eq!(k(), 8);
        r.set_now_ms(9_000);
        r.service();
        assert_eq!(k(), 8, "raised once");
        f.poke(vid::wf_zoom_write_line::addr(), 7);
        r.service();
        assert_eq!(k(), 2);
        // leaving LISTEN: the FT8 waterfall wants K 1 and gets it at the next line, not by a lower K at once
        r.set_listen_speed_for_start(1);
        assert!(r.start_display_listen(rect, 9_650_000, Span::from_shift(7)).unwrap());
        assert_eq!(k(), 7);
        r.start_display_with(rect, Ft8Waterfall::FpgaZoom).unwrap();
        assert_eq!(k(), 7);
        f.poke(vid::wf_zoom_write_line::addr(), 8);
        r.service();
        assert_eq!(k(), 1);
    }

    #[test]
    fn capture_returns_samples_by_their_time() {
        let mut c = SlotCapture::new();
        let base = 5_000_000_000u64;
        for seq in 0..100 {
            let (h, s) = block(seq, base);
            c.push(&h, &s);
        }
        let mut out = [0i16; 300];
        // From sample 1,000 on: values 1,001..
        assert_eq!(c.extract(base as i64 + 1_000 * 6_400, &mut out), 300);
        assert_eq!((out[0], out[299]), (1_001, 1_300));
        // Starting 10 samples before the first one: 10 zeros, then the data.
        assert_eq!(c.extract(base as i64 - 10 * 6_400, &mut out), 290);
        assert_eq!((out[9], out[10], out[11]), (0, 1, 2));
        // Past the end: zeros for what has not arrived.
        assert_eq!(c.extract(base as i64 + 12_700 * 6_400, &mut out), 100);
        assert_eq!((out[99], out[100]), (12_800, 0));
    }

    #[test]
    fn capture_keeps_time_across_lost_blocks_and_restarts() {
        let mut c = SlotCapture::new();
        let base = 1_000_000u64;
        for seq in [0u64, 1, 4, 5] {
            let (h, s) = block(seq, base);
            c.push(&h, &s);
        }
        assert_eq!(c.filled, 256);
        let mut out = [0i16; 4];
        c.extract(base as i64 + 255 * 6_400, &mut out); // last of block 1, then the gap
        assert_eq!(out, [256, 0, 0, 0]);
        c.extract(base as i64 + 511 * 6_400, &mut out); // end of the gap, then block 4
        assert_eq!(out, [0, 513, 514, 515]);
        // The receiver restarted: stamps begin again lower. Old audio is dropped.
        let (h, s) = block(0, 500);
        c.push(&h, &s);
        assert_eq!(c.extract(500, &mut out), 4);
        assert_eq!(out, [1, 2, 3, 4]);
        assert_eq!(c.extract(base as i64, &mut out), 0);
    }
}
