// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! FreeDV 700D / 700E receive in the firmware (docs/FREEDV.md section 9). No hardware
//! here: [`FreedvRx`] takes the back end's 12 ksps audio blocks and produces 48 kHz speech in a
//! queue of its own; [`crate::radio::Radio`] moves the queue into the audio engine's ring.
//!
//! Chain: 12 kHz block -> converter 2/3 -> 8 kHz modem audio -> `tr_freedv::Rx` (modem, error
//! correction, speech decoder) -> 8 kHz speech or silence or pass-through -> converter x6 -> queue.
//!
//! **The queue.** The audio engine's CPU ring holds 85 ms. A 700D frame decodes to 160 ms of speech
//! at once, so the speech waits here and the main loop tops the ring up from it. The queue holds
//! 32,768 samples (683 ms). Playing starts when two frames of speech are in it (320 ms for 700D, 160
//! ms for 700E), so that a frame that comes late does not empty the ring. Counted: samples that did
//! not fit ([`SpeechQueue::overrun_samples`]) and ring run-dry events ([`FdvOut::underruns`]).
//!
//! **Stack.** One receive step keeps about 20 KB on the stack and [`Rx`] is 37 KB: it lives on the
//! heap, built in place.

use alloc::boxed::Box;
use alloc::string::String;
use alloc::vec;
use alloc::vec::Vec;

use tr_fabric::audio::{stereo_word, AudioOut};
use tr_fabric::mem::FabricMem;
use tr_freedv::ofdm::{Mode, SyncState};
use tr_freedv::resample::Resampler;
use tr_freedv::varicode;
use tr_freedv::{Rx, RxStatus, MAX_NIN, MODE_700D, MODE_700E};
use tr_regs::RegisterSpace;

/// Samples (48 kHz, mono) the speech queue holds: 683 ms.
pub const QUEUE_SAMPLES: usize = 32_768;
/// Passes the received audio through at this gain while the modem is not in sync and squelch is
/// off, so that the operator hears the band while tuning (upstream's 0.25).
pub const PASSTHROUGH_GAIN: f32 = 0.25;

/// The two modes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FdvMode {
    /// FreeDV 700D.
    D700,
    /// FreeDV 700E.
    E700,
}

impl FdvMode {
    /// The OFDM mode definition the modem runs with.
    pub fn ofdm(self) -> &'static Mode {
        match self {
            FdvMode::D700 => &MODE_700D,
            FdvMode::E700 => &MODE_700E,
        }
    }

    /// The mode's name as shown on the screen.
    pub fn name(self) -> &'static str {
        match self {
            FdvMode::D700 => "700D",
            FdvMode::E700 => "700E",
        }
    }
}

/// The 48 kHz speech waiting for the audio engine.
pub struct SpeechQueue {
    buf: Vec<i16>,
    rd: usize,
    len: usize,
    /// Samples dropped because the queue was full.
    pub overrun_samples: u64,
    /// Times the queue was found full by a push (one per episode).
    pub overruns: u32,
    full_before: bool,
    /// Most samples ever in the queue.
    pub peak: usize,
}

impl Default for SpeechQueue {
    fn default() -> Self {
        Self::new()
    }
}

impl SpeechQueue {
    /// A queue without storage, to stand in while the real one is moved.
    const fn placeholder() -> Self {
        SpeechQueue { buf: Vec::new(), rd: 0, len: 0, overrun_samples: 0, overruns: 0, full_before: false, peak: 0 }
    }

    /// An empty queue with its full storage.
    pub fn new() -> Self {
        SpeechQueue { buf: vec![0; QUEUE_SAMPLES], rd: 0, len: 0, overrun_samples: 0, overruns: 0, full_before: false, peak: 0 }
    }

    /// Samples waiting.
    pub fn len(&self) -> usize {
        self.len
    }

    /// True if no sample is waiting.
    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    /// Drops everything waiting. The counters stay.
    pub fn clear(&mut self) {
        self.rd = 0;
        self.len = 0;
    }

    /// Appends one sample. When the queue is full the sample is dropped and counted as an overrun.
    pub fn push(&mut self, s: i16) {
        if self.len == QUEUE_SAMPLES {
            self.overrun_samples += 1;
            if !self.full_before {
                self.overruns += 1;
            }
            self.full_before = true;
            return;
        }
        self.full_before = false;
        self.buf[(self.rd + self.len) & (QUEUE_SAMPLES - 1)] = s;
        self.len += 1;
        self.peak = self.peak.max(self.len);
    }

    /// Moves up to `out.len()` samples, oldest first, out of the queue as stereo words; returns how many.
    pub fn pop_stereo(&mut self, out: &mut [u32]) -> usize {
        let n = out.len().min(self.len);
        for o in out[..n].iter_mut() {
            let s = self.buf[self.rd];
            *o = stereo_word(s, s);
            self.rd = (self.rd + 1) & (QUEUE_SAMPLES - 1);
        }
        self.len -= n;
        n
    }

    /// Puts `n` samples back at the front (the audio ring took fewer than were popped).
    fn unpop(&mut self, n: usize) {
        self.rd = (self.rd + QUEUE_SAMPLES - n) & (QUEUE_SAMPLES - 1);
        self.len += n;
    }
}

/// Longest line of the text channel kept.
pub const TEXT_MAX: usize = 40;

/// The text channel (the sender's call sign): ASCII from the varicode decoder. A carriage return
/// or line feed ends a line; a line that gets longer than [`TEXT_MAX`] loses its oldest characters
/// (a sender that repeats its call sign without a line end).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct FdvText {
    line: String,
    last: String,
    /// Characters received.
    pub chars: u32,
}

impl FdvText {
    /// Takes one received character: line ends close the line, printable ASCII is appended, everything else is ignored.
    pub fn push(&mut self, c: u8) {
        self.chars += 1;
        match c {
            13 | 10 => {
                if !self.line.is_empty() {
                    self.last = core::mem::take(&mut self.line);
                }
            }
            32..=126 => {
                if self.line.len() >= TEXT_MAX {
                    self.line.remove(0);
                }
                self.line.push(c as char);
            }
            _ => {}
        }
    }

    /// What to show: the last complete line, or the line in progress while there is none.
    pub fn display(&self) -> &str {
        if self.last.is_empty() {
            &self.line
        } else {
            &self.last
        }
    }

    /// The line being received.
    pub fn partial(&self) -> &str {
        &self.line
    }
}

/// What the screen shows of the receiver.
#[derive(Clone, Copy, Debug)]
pub struct FdvIndicators {
    /// The mode the receiver runs in.
    pub mode: FdvMode,
    /// Modem synchronization state.
    pub sync: SyncState,
    /// Signal to noise ratio in 3 kHz, dB (-5 while searching).
    pub snr_db: f32,
    /// Frequency offset of the signal from the nominal 1,500 Hz center, Hz.
    pub foff_hz: f32,
    /// Unique word bits wrong in the last frame.
    pub uw_errors: usize,
    /// Modem frames received since sync.
    pub frames: u32,
    /// Of those, frames with at least one bit error.
    pub frames_with_errors: u32,
    /// The last frame decoded had no codeword.
    pub last_frame_error: bool,
    /// Speech is being decoded (not muted by the squelch, not searching).
    pub speech: bool,
}

/// The receive chain. See the module text.
pub struct FreedvRx {
    mode: FdvMode,
    rx: Box<Rx>,
    fifo: Vec<i16>,
    fill: usize,
    down: Resampler,
    up: Resampler,
    /// The decoded speech, 48 kHz mono, for [`FdvOut::pump`].
    pub queue: SpeechQueue,
    last: RxStatus,
    /// Modem steps run since start.
    pub steps: u64,
    last_frame_error: bool,
    speech_now: bool,
    varicode: varicode::Decoder,
    text: FdvText,
}

impl FreedvRx {
    /// A receiver in `mode`, searching for sync, with an empty queue.
    pub fn new(mode: FdvMode) -> Self {
        Self::with_queue(mode, SpeechQueue::new())
    }

    fn with_queue(mode: FdvMode, queue: SpeechQueue) -> Self {
        let mut rx = Box::<Rx>::new_uninit();
        // SAFETY: `Rx::init` initializes the whole value in place, in the box's memory
        // (release builds; 37 KB must not go through a 32 KB stack).
        let rx = unsafe {
            Rx::init(&mut *rx, mode.ofdm());
            rx.assume_init()
        };
        let mut s = FreedvRx {
            mode,
            rx,
            fifo: vec![0; MAX_NIN],
            fill: 0,
            down: Resampler::new_12k_to_8k(),
            up: Resampler::new_8k_to_48k(),
            queue,
            last: RxStatus::default(),
            steps: 0,
            last_frame_error: false,
            speech_now: false,
            varicode: varicode::Decoder::new(),
            text: FdvText::default(),
        };
        s.rx.passthrough_gain = PASSTHROUGH_GAIN;
        s
    }

    /// The current mode.
    pub fn mode(&self) -> FdvMode {
        self.mode
    }

    /// Switches mode: the modem starts again (searching), the queue and the converters are emptied.
    pub fn set_mode(&mut self, mode: FdvMode) {
        let (squelch, level) = (self.rx.squelch, self.rx.snr_squelch_db);
        let mut queue = core::mem::replace(&mut self.queue, SpeechQueue::placeholder());
        queue.clear();
        *self = FreedvRx::with_queue(mode, queue);
        self.rx.squelch = squelch;
        self.rx.snr_squelch_db = level;
    }

    /// Squelch: with it on, speech is muted below `level_db` SNR and while sync is unconfirmed unless
    /// the frame is error free (the reference implementation's rule), and nothing is passed through
    /// while searching.
    pub fn set_squelch(&mut self, on: bool, level_db: f32) {
        self.rx.squelch = on;
        self.rx.snr_squelch_db = level_db;
    }

    /// The squelch setting: on or off, and the SNR threshold in dB.
    pub fn squelch(&self) -> (bool, f32) {
        (self.rx.squelch, self.rx.snr_squelch_db)
    }

    /// Samples of speech a modem frame decodes to, at 48 kHz.
    pub fn frame_samples_48k(&self) -> usize {
        self.rx.speech_per_frame() * 6
    }

    /// One back-end block: 128 samples at 12 ksps.
    pub fn feed_12k(&mut self, block: &[i16]) {
        // 2/3 of the block, with a sample of rounding slack
        let mut tmp = [0i16; 96];
        let mut n = 0;
        self.down.process(block, |s| {
            tmp[n] = s;
            n += 1;
        });
        self.feed_8k(&tmp[..n]);
    }

    /// 8 kHz modem audio in blocks of any size (what [`tr_freedv::RxStream::push`] does, with the
    /// speech going up to 48 kHz into the queue).
    pub fn feed_8k(&mut self, mut samples: &[i16]) {
        let mut out = [0i16; MAX_NIN];
        loop {
            let nin = self.rx.nin();
            let take = (nin - self.fill).min(samples.len());
            self.fifo[self.fill..self.fill + take].copy_from_slice(&samples[..take]);
            self.fill += take;
            samples = &samples[take..];
            if self.fill < nin {
                return;
            }
            let (status, n) = self.rx.rx(&self.fifo[..nin], &mut out);
            self.fill = 0;
            self.after_step(status, &out[..n]);
        }
    }

    /// Takes the result of one modem step: updates the indicators, feeds the text bits to the varicode decoder and the speech to the queue.
    fn after_step(&mut self, status: RxStatus, speech: &[i16]) {
        self.steps += 1;
        self.last = status;
        if status.bits {
            // The text bits of the frame (4 in 700D, 2 in 700E), not error corrected.
            let ntxt = self.rx.mode().ntxtbits;
            let text = &mut self.text;
            self.varicode.push_bits(&self.rx.txt_bits[..ntxt], |c| text.push(c));
            self.last_frame_error = status.bit_errors;
            self.speech_now = status.speech;
        } else if !status.sync {
            self.speech_now = false;
        }
        let queue = &mut self.queue;
        self.up.process(speech, |s| queue.push(s));
    }

    /// The decoded text channel.
    pub fn text(&self) -> &FdvText {
        &self.text
    }

    /// A snapshot of the numbers the screen shows.
    pub fn indicators(&self) -> FdvIndicators {
        let s = self.rx.stats();
        FdvIndicators {
            mode: self.mode,
            sync: s.sync_state,
            snr_db: s.snr_db,
            foff_hz: s.foff_hz,
            uw_errors: s.uw_errors,
            frames: s.frames,
            frames_with_errors: s.frames_with_errors,
            last_frame_error: self.last_frame_error,
            speech: self.speech_now,
        }
    }

    /// True while the receiver's own audio is replaced by decoded speech: the analog audio is
    /// muted for as long as the modem is in sync. The only audio source of the outputs is this
    /// queue, so nothing else is muted here; a hardware mixer would act on this flag.
    pub fn analog_muted(&self) -> bool {
        self.speech_now
    }

    /// Queue level at which playing starts: two frames of speech.
    pub fn prefill(&self) -> usize {
        2 * self.frame_samples_48k()
    }
}

/// The audio engine side: tops its ring up from the queue.
pub struct FdvOut<'a, R: RegisterSpace, M: FabricMem> {
    audio: AudioOut<'a, R, M>,
    playing: bool,
    /// Frames put into the ring since playing started; zero means no underrun can be judged yet.
    pushed: u64,
    /// Times the ring ran dry while playing.
    pub underruns: u32,
    /// Stereo frames given to the audio ring.
    pub frames_out: u64,
}

impl<'a, R: RegisterSpace, M: FabricMem> FdvOut<'a, R, M> {
    /// Starts the audio engine with the given volume (PT8211 DAC, 0 to 255) and S/PDIF and I2S outputs on.
    pub fn new(regs: &'a R, mem: &'a M, volume: u8) -> Self {
        let mut audio = AudioOut::new(regs, mem, tr_fabric::mem::map::AUDIO_RING);
        audio.set_volume(volume);
        audio.set_outputs(true, true, false);
        audio.set_enable(true);
        FdvOut { audio, playing: false, pushed: 0, underruns: 0, frames_out: 0 }
    }

    /// The audio engine, for status readouts.
    pub fn audio(&self) -> &AudioOut<'a, R, M> {
        &self.audio
    }

    /// Engine off (the ring is emptied).
    pub fn stop(&mut self) {
        self.audio.set_enable(false);
        self.playing = false;
    }

    /// True while the engine is playing, that is after the queue reached the prefill level.
    pub fn playing(&self) -> bool {
        self.playing
    }

    /// The queue was emptied on purpose (mode change): wait for two frames again before playing.
    pub fn rebuffer(&mut self) {
        self.playing = false;
    }

    /// Tops the ring up from the queue. Call at least every 40 ms.
    pub fn pump(&mut self, rx: &mut FreedvRx) {
        if !self.playing {
            if rx.queue.len() < rx.prefill() {
                return;
            }
            self.playing = true;
            self.pushed = 0;
        } else if self.pushed > 0 && self.audio.fill() == 0 {
            // The engine played everything we gave it and found the ring empty.
            self.underruns += 1;
            if rx.queue.len() < rx.prefill() {
                self.playing = false;
                return;
            }
        }
        let mut chunk = [0u32; 256];
        loop {
            let want = (self.audio.free() as usize).min(chunk.len());
            if want == 0 || rx.queue.is_empty() {
                break;
            }
            let n = rx.queue.pop_stereo(&mut chunk[..want]);
            let took = self.audio.push(&chunk[..n]);
            if took < n {
                rx.queue.unpop(n - took);
            }
            self.frames_out += took as u64;
            self.pushed += took as u64;
            if took < n {
                break;
            }
        }
    }
}
