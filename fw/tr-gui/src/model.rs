// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
//! `PanelState`: the whole front-panel UI state as a plain Rust struct, independent of Slint.
//! Whatever drives the panel (the screenshot tests here, the firmware on the radio) owns one of
//! these, changes it as the radio's actual state changes, and calls `apply_state()` (generated
//! per window in src/lib.rs) to push it into the running window. No radio logic lives here,
//! the struct is a data shape and nothing in this file decides what the values should be.
//!
//! Besides the struct this module holds the small enums it uses (`Vfo`, `Mode`, `AgcMode`,
//! `TxInhibitReason`), the per-receiver `RxSlice`, the FT8 `DigitalDecode` row, and the text
//! formatting (grouped frequencies, S-unit labels) that is done once here so the `.slint` side
//! only lays text out.

extern crate alloc;

use alloc::format;
use alloc::string::String;
use alloc::vec::Vec;

/// Which VFO is the one currently being tuned and listened to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Vfo {
    A,
    B,
}

/// Demodulator mode, in the order the mode buttons show them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    Lsb,
    Usb,
    Cw,
    Am,
    Fm,
    Digital,
}

impl Mode {
    /// Every mode, in the order of the mode buttons (so the position is the button index).
    pub const ALL: [Mode; 6] = [Mode::Lsb, Mode::Usb, Mode::Cw, Mode::Am, Mode::Fm, Mode::Digital];

    /// The text on the mode button.
    pub fn label(self) -> &'static str {
        match self {
            Mode::Lsb => "LSB",
            Mode::Usb => "USB",
            Mode::Cw => "CW",
            Mode::Am => "AM",
            Mode::Fm => "FM",
            Mode::Digital => "DIGI",
        }
    }

    fn index(self) -> i32 {
        Self::ALL.iter().position(|m| *m == self).unwrap_or(0) as i32
    }
}

/// AGC speed, in the order the AGC buttons show them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AgcMode {
    Off,
    Slow,
    Medium,
    Fast,
}

impl AgcMode {
    const ALL: [AgcMode; 4] = [AgcMode::Off, AgcMode::Slow, AgcMode::Medium, AgcMode::Fast];

    fn index(self) -> i32 {
        Self::ALL.iter().position(|m| *m == self).unwrap_or(0) as i32
    }
}

/// Why TX is inhibited right now. The HL2's own interlock (docs/ARCHITECTURE.md 3.6) is the
/// final authority; this only names the reason it last reported, for the operator to read.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TxInhibitReason {
    /// Ready to transmit: not inhibited.
    Ready,
    /// The radio holds no transmit lease from the HL2.
    NoLease,
    /// The HL2's protection circuit tripped.
    Trip,
    OverTemperature,
    NoMicInput,
    /// A reason the HL2 reported that has no variant of its own; the text is shown as is.
    Other(String),
}

impl TxInhibitReason {
    /// True for every reason except `Ready`.
    pub fn is_inhibited(&self) -> bool {
        !matches!(self, TxInhibitReason::Ready)
    }

    /// The short text the operator reads next to the TX control.
    pub fn text(&self) -> String {
        match self {
            TxInhibitReason::Ready => String::from("ready"),
            TxInhibitReason::NoLease => String::from("no TX lease"),
            TxInhibitReason::Trip => String::from("HL2 trip"),
            TxInhibitReason::OverTemperature => String::from("over temperature"),
            TxInhibitReason::NoMicInput => String::from("no mic input"),
            TxInhibitReason::Other(s) => s.clone(),
        }
    }
}

/// One of up to 8 independent receivers (docs/ARCHITECTURE.md 3.2).
#[derive(Clone, Debug)]
pub struct RxSlice {
    /// 0..7, matches the FPGA receiver index (`rx_bank` port).
    pub id: u8,
    /// Center frequency of the receiver in Hz; 0 for a receiver that is not tuned.
    pub frequency_hz: u32,
    pub mode: Mode,
    /// Built and tuned to something (a receiver instance may exist but be idle).
    pub active: bool,
    /// Routed to an audio output right now (docs/ARCHITECTURE.md 5.5: not every receiver is).
    pub audible: bool,
    /// Falls inside the currently selected N2ADR filter passband.
    pub in_passband: bool,
}

impl RxSlice {
    fn freq_text(&self) -> String {
        format_hz_grouped(self.frequency_hz)
    }
}

/// One decoded FT8 (or FT4, WSPR and similar) message. Formatting is done once here so the
/// `.slint` side only lays rows out.
#[derive(Clone, Debug)]
pub struct DigitalDecode {
    /// Start of the slot the message was received in, as shown ("18:32:15").
    pub utc: String,
    /// Time offset from the expected slot start, in seconds (WSJT-X convention, typically
    /// -1.5 to +1.5 for FT8).
    pub dt_s: f32,
    /// Audio frequency of the signal within the passband, in Hz.
    pub freq_offset_hz: i16,
    /// Signal-to-noise ratio in dB, measured in a 2500 Hz bandwidth (WSJT-X convention).
    pub snr_db: i8,
    pub message: String,
}

impl DigitalDecode {
    fn freq_offset_text(&self) -> String {
        if self.freq_offset_hz >= 0 {
            format!("+{}", self.freq_offset_hz)
        } else {
            format!("{}", self.freq_offset_hz)
        }
    }

    fn snr_text(&self) -> String {
        if self.snr_db >= 0 {
            format!("+{} dB", self.snr_db)
        } else {
            format!("{} dB", self.snr_db)
        }
    }

    fn dt_text(&self) -> String {
        // `{:+.1}` needs `std`, so the text is built by hand to keep this working under `no_std`.
        // The sign is handled apart from the magnitude, otherwise "-0.3" would lose its sign
        // when integer division truncates -3/10 to 0.
        let tenths = libm::roundf(self.dt_s * 10.0) as i32;
        let sign = if tenths < 0 { "-" } else { "+" };
        let abs_tenths = tenths.abs();
        format!("{}{}.{}", sign, abs_tenths / 10, abs_tenths % 10)
    }
}

/// The whole front-panel UI state: what the panel window shows, field by field.
#[derive(Clone, Debug)]
pub struct PanelState {
    /// Frequency of VFO A in Hz.
    pub vfo_a_hz: u32,
    /// Frequency of VFO B in Hz.
    pub vfo_b_hz: u32,
    pub active_vfo: Vfo,

    /// Index into the band buttons (160 m first, "Gen" last).
    pub active_band_index: i32,
    pub mode: Mode,
    /// Receive filter width in Hz.
    pub filter_width_hz: u32,
    pub agc: AgcMode,

    /// Noise reduction on or off.
    pub nr_enabled: bool,
    /// Noise reduction strength, as the level next to the NR button shows it.
    pub nr_level: u8,
    /// Noise blanker on or off.
    pub nb_enabled: bool,
    /// Noise blanker strength, as the level next to the NB button shows it.
    pub nb_level: u8,

    /// Up to 8 entries (docs/ARCHITECTURE.md 3.2: N = 4 to 8 receiver instances).
    pub rx_slices: Vec<RxSlice>,

    /// The transmitter is keyed right now.
    pub tx_keyed: bool,
    pub tx_inhibit: TxInhibitReason,

    /// Name of the N2ADR low-pass filter the HL2 filter board has selected (docs/ARCHITECTURE.md 8).
    pub n2adr_filter_name: String,
    /// False when a receiver sits outside the selected filter.
    pub n2adr_ok: bool,
    /// Text for the filter indicator when `n2adr_ok` is false; empty otherwise.
    pub n2adr_warning: String,

    /// Signal level of the active receiver in dBm.
    pub s_meter_dbm: f32,

    /// Newest first; `digital_decode_rows` does not sort.
    pub digital_decodes: Vec<DigitalDecode>,

    pub menu_open: bool,
    /// Highlighted menu entry, -1 for none.
    pub menu_selected_index: i32,
}

impl Default for PanelState {
    fn default() -> Self {
        PanelState {
            vfo_a_hz: 14_074_000,
            vfo_b_hz: 14_150_000,
            active_vfo: Vfo::A,
            active_band_index: 5,
            mode: Mode::Usb,
            filter_width_hz: 2_400,
            agc: AgcMode::Medium,
            nr_enabled: false,
            nr_level: 5,
            nb_enabled: false,
            nb_level: 3,
            rx_slices: Vec::new(),
            tx_keyed: false,
            tx_inhibit: TxInhibitReason::NoLease,
            n2adr_filter_name: String::from("20 m LPF"),
            n2adr_ok: true,
            n2adr_warning: String::new(),
            s_meter_dbm: -73.0,
            digital_decodes: Vec::new(),
            menu_open: false,
            menu_selected_index: -1,
        }
    }
}

impl PanelState {
    /// 0 for VFO A, 1 for VFO B, the value the panel's `active-vfo` property takes.
    pub fn active_vfo_index(&self) -> i32 {
        match self.active_vfo {
            Vfo::A => 0,
            Vfo::B => 1,
        }
    }

    /// Position of the mode in the mode buttons.
    pub fn active_mode_index(&self) -> i32 {
        self.mode.index()
    }

    /// Position of the AGC speed in the AGC buttons.
    pub fn active_agc_index(&self) -> i32 {
        self.agc.index()
    }

    /// The large part of VFO A's display: everything but the last 3 (Hz) digits, dot-grouped.
    pub fn vfo_a_main_text(&self) -> String {
        split_freq(self.vfo_a_hz).0
    }

    /// The small part of VFO A's display: its last 3 digits.
    pub fn vfo_a_sub_text(&self) -> String {
        split_freq(self.vfo_a_hz).1
    }

    /// The large part of VFO B's display.
    pub fn vfo_b_main_text(&self) -> String {
        split_freq(self.vfo_b_hz).0
    }

    /// The small part of VFO B's display.
    pub fn vfo_b_sub_text(&self) -> String {
        split_freq(self.vfo_b_hz).1
    }

    /// Filter width as "2.4 kHz" from 1000 Hz up, as "500 Hz" below.
    pub fn filter_width_text(&self) -> String {
        if self.filter_width_hz >= 1_000 {
            format!("{:.1} kHz", self.filter_width_hz as f32 / 1_000.0)
        } else {
            format!("{} Hz", self.filter_width_hz)
        }
    }

    /// S-unit label of the current level ("S7", "S9+20").
    pub fn s_meter_text(&self) -> String {
        s_meter_label(self.s_meter_dbm)
    }

    /// The current level as "-73 dBm".
    pub fn s_meter_dbm_text(&self) -> String {
        format!("{:.0} dBm", self.s_meter_dbm)
    }

    /// Keeps the first `n` receiver slices. The chip has `tr_fabric::system::System::num_rx`
    /// receivers (4 in the default build), not always the 8 the register layout holds, and the
    /// list in the panel follows its model.
    pub fn limit_receivers(&mut self, n: usize) {
        self.rx_slices.truncate(n);
    }

    /// `(id, frequency text, mode text, active, audible, in_passband)` for every receiver slice.
    pub fn rx_slice_rows(&self) -> Vec<(i32, String, &'static str, bool, bool, bool)> {
        self.rx_slices
            .iter()
            .map(|s| (s.id as i32, s.freq_text(), s.mode.label(), s.active, s.audible, s.in_passband))
            .collect()
    }

    /// `(utc, dt, snr, freq_offset, message)` for every decode, in the order of
    /// `digital_decodes`, which is expected to be newest first. This does not sort.
    pub fn digital_decode_rows(&self) -> Vec<(String, String, String, String, String)> {
        self.digital_decodes
            .iter()
            .map(|d| (d.utc.clone(), d.dt_text(), d.snr_text(), d.freq_offset_text(), d.message.clone()))
            .collect()
    }

    /// A representative state for the host screenshot tests. It is demo data and not a default
    /// the firmware should start from.
    pub fn demo() -> Self {
        let rx_slices = alloc::vec![
            RxSlice { id: 0, frequency_hz: 14_074_000, mode: Mode::Digital, active: true, audible: false, in_passband: true },
            RxSlice { id: 1, frequency_hz: 14_230_000, mode: Mode::Usb, active: true, audible: true, in_passband: true },
            RxSlice { id: 2, frequency_hz: 7_074_000, mode: Mode::Digital, active: true, audible: false, in_passband: false },
            RxSlice { id: 3, frequency_hz: 3_573_000, mode: Mode::Cw, active: true, audible: false, in_passband: true },
            RxSlice { id: 4, frequency_hz: 0, mode: Mode::Usb, active: false, audible: false, in_passband: true },
            RxSlice { id: 5, frequency_hz: 0, mode: Mode::Usb, active: false, audible: false, in_passband: true },
            RxSlice { id: 6, frequency_hz: 0, mode: Mode::Usb, active: false, audible: false, in_passband: true },
            RxSlice { id: 7, frequency_hz: 0, mode: Mode::Usb, active: false, audible: false, in_passband: true },
        ];

        // Newest first (index 0 is the latest slot), as `digital_panel.slint` expects.
        let digital_decodes = alloc::vec![
            DigitalDecode { utc: String::from("18:32:15"), dt_s: 0.1, freq_offset_hz: 412, snr_db: -8, message: String::from("CQ DL1ABC JO62") },
            DigitalDecode { utc: String::from("18:32:15"), dt_s: -0.2, freq_offset_hz: 1_203, snr_db: 3, message: String::from("W1AW K1ABC -12") },
            DigitalDecode { utc: String::from("18:32:15"), dt_s: 0.4, freq_offset_hz: 2_006, snr_db: -14, message: String::from("CQ JA1XYZ PM95") },
            DigitalDecode { utc: String::from("18:32:00"), dt_s: 0.0, freq_offset_hz: -308, snr_db: -6, message: String::from("CQ EA3XYZ JN11") },
            DigitalDecode { utc: String::from("18:32:00"), dt_s: 0.3, freq_offset_hz: 877, snr_db: -18, message: String::from("VE3ABC W1AW R-09") },
            DigitalDecode { utc: String::from("18:31:45"), dt_s: -0.1, freq_offset_hz: 1_655, snr_db: -2, message: String::from("CQ PY2XYZ GG66") },
            DigitalDecode { utc: String::from("18:31:45"), dt_s: 0.2, freq_offset_hz: 233, snr_db: -11, message: String::from("W1AW DL1ABC RRR") },
            DigitalDecode { utc: String::from("18:31:30"), dt_s: -0.3, freq_offset_hz: -1_022, snr_db: -20, message: String::from("CQ VK2XYZ QF56") },
            DigitalDecode { utc: String::from("18:31:30"), dt_s: 0.1, freq_offset_hz: 1_988, snr_db: 1, message: String::from("JA1XYZ K1ABC 73") },
            DigitalDecode { utc: String::from("18:31:15"), dt_s: 0.0, freq_offset_hz: 502, snr_db: -9, message: String::from("CQ G0XYZ IO91") },
        ];

        PanelState {
            vfo_a_hz: 14_074_000,
            vfo_b_hz: 14_230_000,
            active_vfo: Vfo::A,
            active_band_index: 5,
            mode: Mode::Digital,
            filter_width_hz: 2_400,
            agc: AgcMode::Medium,
            nr_enabled: true,
            nr_level: 6,
            nb_enabled: false,
            nb_level: 3,
            rx_slices,
            tx_keyed: false,
            tx_inhibit: TxInhibitReason::NoLease,
            n2adr_filter_name: String::from("30/20 m LPF"),
            n2adr_ok: false,
            n2adr_warning: String::from("RX 2 (40 m) is outside this filter"),
            s_meter_dbm: -55.0,
            digital_decodes,
            menu_open: false,
            menu_selected_index: -1,
        }
    }
}

/// "14074000" -> "14.074.000", matching the dotted-group style used on the frequency display.
fn format_hz_grouped(hz: u32) -> String {
    let digits = format!("{}", hz);
    let mut out = String::with_capacity(digits.len() + digits.len() / 3);
    let first_group = digits.len() % 3;
    let first_group = if first_group == 0 { 3 } else { first_group };
    for (i, ch) in digits.chars().enumerate() {
        if i >= first_group && (i - first_group) % 3 == 0 {
            out.push('.');
        }
        out.push(ch);
    }
    out
}

/// Splits a frequency into (grouped MHz/kHz text, last-3-digit Hz text), for the frequency
/// display's large main and small sub layout: `14_074_000` becomes `("14.074", "000")`.
fn split_freq(hz: u32) -> (String, String) {
    let main = format_hz_grouped(hz / 1_000);
    let sub = format!("{:03}", hz % 1_000);
    (main, sub)
}

/// S-unit label from a dBm level: S0 is -127 dBm, each S-unit is 6 dB up to S9 (-73 dBm), and
/// above that the label is "S9+xx" with xx the dB over S9. This is a display convenience and
/// not a calibrated meter, it takes the level as given.
fn s_meter_label(dbm: f32) -> String {
    if dbm <= -127.0 {
        return String::from("S0");
    }
    if dbm < -73.0 {
        let s = libm::floorf((dbm - -127.0) / 6.0) as i32;
        format!("S{}", s.clamp(0, 9))
    } else {
        let over = libm::roundf(dbm - -73.0) as i32;
        if over <= 0 {
            String::from("S9")
        } else {
            format!("S9+{}", over)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn groups_frequency_digits() {
        assert_eq!(format_hz_grouped(14_074_000), "14.074.000");
        assert_eq!(format_hz_grouped(150_000), "150.000");
        assert_eq!(format_hz_grouped(7_000_000), "7.000.000");
        assert_eq!(format_hz_grouped(500), "500");
    }

    #[test]
    fn s_meter_labels_span_the_scale() {
        assert_eq!(s_meter_label(-127.0), "S0");
        assert_eq!(s_meter_label(-73.0), "S9");
        assert_eq!(s_meter_label(-53.0), "S9+20");
        assert_eq!(s_meter_label(-200.0), "S0");
    }

    #[test]
    fn demo_state_has_eight_rx_slices() {
        assert_eq!(PanelState::demo().rx_slices.len(), 8);
    }

    #[test]
    fn the_receiver_list_follows_the_chips_count() {
        let mut s = PanelState::demo();
        s.limit_receivers(4);
        assert_eq!(s.rx_slice_rows().len(), 4);
        s.limit_receivers(8);
        assert_eq!(s.rx_slices.len(), 4, "a limit never adds receivers");
    }

    #[test]
    fn splits_frequency_into_main_and_sub() {
        assert_eq!(split_freq(14_074_000), (String::from("14.074"), String::from("000")));
        assert_eq!(split_freq(7_074_012), (String::from("7.074"), String::from("012")));
        assert_eq!(split_freq(500), (String::from("0"), String::from("500")));
    }

    #[test]
    fn dt_text_keeps_the_sign_of_small_negative_values() {
        let mut d = DigitalDecode {
            utc: String::new(),
            dt_s: -0.3,
            freq_offset_hz: 0,
            snr_db: 0,
            message: String::new(),
        };
        assert_eq!(d.dt_text(), "-0.3");
        d.dt_s = 0.3;
        assert_eq!(d.dt_text(), "+0.3");
        d.dt_s = 0.0;
        assert_eq!(d.dt_text(), "+0.0");
    }

    #[test]
    fn demo_decodes_are_newest_first() {
        // Every entry's UTC time is at or after the one following it (same-second ties allowed).
        let rows = PanelState::demo().digital_decode_rows();
        let times: Vec<&str> = rows.iter().map(|(utc, ..)| utc.as_str()).collect();
        let mut sorted = times.clone();
        sorted.sort_by(|a, b| b.cmp(a));
        assert_eq!(times, sorted, "digital_decodes must already be newest-first");
    }
}
