// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
//! `tr-gui`: the user interface of the radio, written in Slint (`ui/`) plus the Rust glue that
//! runs it through Slint's software renderer into a pixel buffer. It is the screen the operator
//! looks at (front panel, FT8, FreeDV and LISTEN views) and it holds no radio logic at all,
//! only UI state (`model::PanelState`, `ft8::Ft8ScreenState`, `fdv::FdvScreenState`,
//! `listen::ListenScreenState`) and the code that pushes that state into the rendered window
//! and turns clicks back into plain events (`Ft8Event`, `FdvEvent`, `ListenEvent`) for the
//! firmware to act on. The firmware owns the radio, this crate owns what is drawn.
//!
//! Each root `.slint` file is compiled by build.rs into its own module (`size_1920x1080`,
//! `ft8_1920x1080`, `app_1920x1080` and so on), and the macros below write the state-push and
//! event-connect glue once per window type, so the windows that share a view cannot drift apart.
//! `platform` provides the Slint platform (a software-rendered window into a pixel buffer) and
//! `input` turns USB mouse and keyboard events into pointer and key events. See
//! `docs/S11_GUI.md` for the full write-up and `tests/screenshots.rs` for the PNG screenshots.
//!
//! The crate is `no_std` except under `cargo test`. The firmware target
//! (`riscv32imafc-unknown-none-elf`) has no `std`, but the host tests need `std::fs` to write
//! PNGs and `std::time::Instant` for the render clock, so, like several `no_std` crates, this
//! one is built as an ordinary `std` crate whenever it is being tested and as `no_std`
//! otherwise (`cargo build`, on any target).
#![cfg_attr(not(test), no_std)]

extern crate alloc;

pub mod fdv;
pub mod ft8;
pub mod input;
pub mod listen;
pub mod model;
pub mod platform;

pub use model::PanelState;

/// Pushes every field of a `PanelState` into a generated panel window's `PanelModel` global.
/// It is defined once and instantiated per size module below, because `panel_1920x1080.slint`
/// and `panel_1024x600.slint` are compiled as two separate Slint programs (build.rs) and so each
/// gets its own, distinct set of generated `PanelModel`, `RxSliceInfo` and `Ft8DecodeInfo` Rust
/// types even though both come from the same `ui/model.slint` source. The macro is the one
/// place the field list is written down, so the two windows cannot drift apart.
macro_rules! impl_apply_state {
    ($window_ty:ident) => {
        /// Pushes `state` into `window`'s `PanelModel` global. Call after any change to `state`
        /// (or once, right after constructing the window, to show its initial content).
        pub fn apply_state(window: &$window_ty, state: &crate::PanelState) {
            use slint::{ComponentHandle, Model, ModelRc, SharedString, VecModel};

            let ui = window.global::<PanelModel>();

            ui.set_vfo_a_main_text(SharedString::from(state.vfo_a_main_text().as_str()));
            ui.set_vfo_a_sub_text(SharedString::from(state.vfo_a_sub_text().as_str()));
            ui.set_vfo_b_main_text(SharedString::from(state.vfo_b_main_text().as_str()));
            ui.set_vfo_b_sub_text(SharedString::from(state.vfo_b_sub_text().as_str()));
            ui.set_active_vfo(state.active_vfo_index());

            ui.set_active_band_index(state.active_band_index);
            ui.set_active_mode_index(state.active_mode_index());
            ui.set_filter_width_text(SharedString::from(state.filter_width_text().as_str()));
            ui.set_active_agc_index(state.active_agc_index());

            ui.set_nr_enabled(state.nr_enabled);
            ui.set_nr_level(state.nr_level as i32);
            ui.set_nb_enabled(state.nb_enabled);
            ui.set_nb_level(state.nb_level as i32);

            let rx_slices: alloc::vec::Vec<RxSliceInfo> = state
                .rx_slice_rows()
                .into_iter()
                .map(|(id, freq_text, mode_text, active, audible, in_passband)| RxSliceInfo {
                    id,
                    freq_text: SharedString::from(freq_text.as_str()),
                    mode_text: SharedString::from(mode_text),
                    active,
                    audible,
                    in_passband,
                })
                .collect();
            let rx_slices: alloc::rc::Rc<dyn Model<Data = RxSliceInfo>> =
                alloc::rc::Rc::new(VecModel::from(rx_slices));
            ui.set_rx_slices(ModelRc::from(rx_slices));

            ui.set_tx_keyed(state.tx_keyed);
            ui.set_tx_inhibited(state.tx_inhibit.is_inhibited());
            ui.set_tx_inhibit_text(SharedString::from(state.tx_inhibit.text().as_str()));

            ui.set_n2adr_filter_text(SharedString::from(state.n2adr_filter_name.as_str()));
            ui.set_n2adr_ok(state.n2adr_ok);
            ui.set_n2adr_warning_text(SharedString::from(state.n2adr_warning.as_str()));

            ui.set_s_meter_db(state.s_meter_dbm);
            ui.set_s_meter_text(SharedString::from(state.s_meter_text().as_str()));
            ui.set_s_meter_dbm_text(SharedString::from(state.s_meter_dbm_text().as_str()));

            let ft8_decodes: alloc::vec::Vec<Ft8DecodeInfo> = state
                .digital_decode_rows()
                .into_iter()
                .map(|(utc, dt, snr, freq_offset, message)| Ft8DecodeInfo {
                    utc_text: SharedString::from(utc.as_str()),
                    dt_text: SharedString::from(dt.as_str()),
                    freq_offset_text: SharedString::from(freq_offset.as_str()),
                    snr_text: SharedString::from(snr.as_str()),
                    message_text: SharedString::from(message.as_str()),
                })
                .collect();
            let ft8_decodes: alloc::rc::Rc<dyn Model<Data = Ft8DecodeInfo>> =
                alloc::rc::Rc::new(VecModel::from(ft8_decodes));
            ui.set_ft8_decodes(ModelRc::from(ft8_decodes));

            ui.set_menu_open(state.menu_open);
            ui.set_menu_selected_index(state.menu_selected_index);
        }
    };
}

/// The panel at 1920x1080, the output size of the radio (docs/DECISIONS.md: the owner's 4K
/// monitor scales it). `ui/panel_1920x1080.slint`.
pub mod size_1920x1080 {
    #![allow(clippy::all)]
    include!(concat!(env!("OUT_DIR"), "/panel_1920x1080.rs"));

    impl_apply_state!(MainWindow1920x1080);
}

/// The panel at 1024x600, for a small LCD on the board's RGB interface (docs/DECISIONS.md).
/// `ui/panel_1024x600.slint`.
pub mod size_1024x600 {
    #![allow(clippy::all)]
    include!(concat!(env!("OUT_DIR"), "/panel_1024x600.rs"));

    impl_apply_state!(MainWindow1024x600);
}

/// The FT8 view glue, for the window that has it: `Ft8Screen1920x1080` on its own, or
/// `AppScreen1920x1080` with the FreeDV and LISTEN views beside it. Names resolve where it is
/// expanded, so the generated types (`Ft8Model`, `Ft8Row`) come from the module using it.
macro_rules! impl_ft8_view {
    ($window_ty:ident) => {
        use alloc::rc::Rc;
        use alloc::vec::Vec;
        use core::cell::RefCell;

        use crate::ft8::{Ft8Event, Ft8ScreenState};

        /// Pushes all of `state` into the window's `Ft8Model` global.
        pub fn apply_state(window: &$window_ty, state: &Ft8ScreenState) {
            apply_state_diff(window, None, state);
        }

        /// Pushes what differs from `shown` (all of it for `None`): a list replaced with an equal
        /// one makes Slint rebuild every row, and with it redraw its area.
        pub fn apply_state_diff(window: &$window_ty, shown: Option<&Ft8ScreenState>, state: &Ft8ScreenState) {
            use slint::{ComponentHandle, Model, ModelRc, SharedString, VecModel};

            let ui = window.global::<Ft8Model>();
            if shown.map(|s| s.band_names != state.band_names).unwrap_or(true) {
                let names: Vec<SharedString> = state.band_names.iter().map(|n| SharedString::from(*n)).collect();
                let names: Rc<dyn Model<Data = SharedString>> = Rc::new(VecModel::from(names));
                ui.set_band_names(ModelRc::from(names));
            }
            ui.set_band_index(state.band_index as i32);
            ui.set_dial_text(SharedString::from(state.dial_text().as_str()));
            ui.set_utc_text(SharedString::from(state.utc_text().as_str()));
            ui.set_clock_level(state.clock.level());
            ui.set_clock_text(SharedString::from(state.clock.text().as_str()));
            ui.set_slot_progress(state.slot_progress.clamp(0.0, 1.0));
            ui.set_slot_is_ours(state.slot_is_ours);
            ui.set_tx_enabled(state.tx_enabled);
            ui.set_transmitting(state.transmitting);
            ui.set_tx_first(state.tx_first);
            ui.set_tx_audio_hz(state.tx_audio_hz as i32);
            ui.set_rx_audio_hz(state.rx_audio_hz as i32);
            ui.set_tx_message(SharedString::from(state.tx_message.as_str()));
            ui.set_qso_text(SharedString::from(state.qso_text.as_str()));
            ui.set_my_call(SharedString::from(state.my_call.as_str()));
            ui.set_link_text(SharedString::from(state.link_text.as_str()));
            ui.set_link_ok(state.link_ok);
            if shown.map(|s| s.decodes != state.decodes).unwrap_or(true) {
                let rows: Vec<Ft8Row> = state
                    .decodes
                    .iter()
                    .map(|d| Ft8Row {
                        utc_text: SharedString::from(d.utc.as_str()),
                        snr_text: SharedString::from(d.snr_text().as_str()),
                        dt_text: SharedString::from(d.dt_text().as_str()),
                        freq_text: SharedString::from(d.freq_text().as_str()),
                        message_text: SharedString::from(d.message.as_str()),
                        kind: d.kind as i32,
                    })
                    .collect();
                let rows: Rc<dyn Model<Data = Ft8Row>> = Rc::new(VecModel::from(rows));
                ui.set_decodes(ModelRc::from(rows));
            }
        }

        /// Events the user raised on the FT8 view, in order, waiting for the firmware to take them.
        pub type EventQueue = Rc<RefCell<Vec<Ft8Event>>>;

        /// Connects every callback of the window's `Ft8Model` to a new queue, which it returns.
        /// The firmware drains the queue each pass of its main loop.
        pub fn connect_events(window: &$window_ty) -> EventQueue {
            use slint::ComponentHandle;

            let q: EventQueue = Rc::new(RefCell::new(Vec::new()));
            let ui = window.global::<Ft8Model>();
            let s = q.clone();
            ui.on_request_band_select(move |i| s.borrow_mut().push(Ft8Event::BandSelect(i as usize)));
            let s = q.clone();
            ui.on_request_tx_enable_toggle(move || s.borrow_mut().push(Ft8Event::TxEnableToggle));
            let s = q.clone();
            ui.on_request_cq(move || s.borrow_mut().push(Ft8Event::Cq));
            let s = q.clone();
            ui.on_request_halt(move || s.borrow_mut().push(Ft8Event::Halt));
            let s = q.clone();
            ui.on_request_decode_click(move |i| s.borrow_mut().push(Ft8Event::DecodeClick(i as usize)));
            let s = q.clone();
            ui.on_request_tx_parity_toggle(move || s.borrow_mut().push(Ft8Event::TxParityToggle));
            let s = q.clone();
            ui.on_request_tx_freq(move |hz| s.borrow_mut().push(Ft8Event::TxFreq(hz.clamp(0, 3_000) as u32)));
            let s = q.clone();
            ui.on_request_switch_to_freedv(move || s.borrow_mut().push(Ft8Event::SwitchToFreedv));
            let s = q.clone();
            ui.on_request_switch_to_listen(move || s.borrow_mut().push(Ft8Event::SwitchToListen));
            q
        }
    };
}

/// The same for the FreeDV view (`FdvScreen1920x1080`, or inside `AppScreen1920x1080`).
macro_rules! impl_fdv_view {
    ($window_ty:ident) => {
        /// Pushes all of `state` into the window's `FdvModel` global.
        pub fn apply_fdv_state(window: &$window_ty, state: &crate::fdv::FdvScreenState) {
            apply_fdv_state_diff(window, None, state);
        }

        /// Pushes what differs from `shown` (all of it for `None`): a list replaced with an equal one
        /// makes Slint rebuild every row, and with it redraw its area.
        pub fn apply_fdv_state_diff(window: &$window_ty, shown: Option<&crate::fdv::FdvScreenState>, state: &crate::fdv::FdvScreenState) {
            use slint::{ComponentHandle, Model, ModelRc, SharedString, VecModel};

            let ui = window.global::<FdvModel>();
            if shown.map(|s| s.band_names != state.band_names).unwrap_or(true) {
                let names: alloc::vec::Vec<SharedString> = state.band_names.iter().map(|n| SharedString::from(*n)).collect();
                let names: alloc::rc::Rc<dyn Model<Data = SharedString>> = alloc::rc::Rc::new(VecModel::from(names));
                ui.set_band_names(ModelRc::from(names));
            }
            ui.set_band_index(state.band_index as i32);
            ui.set_dial_text(SharedString::from(state.dial_text().as_str()));
            ui.set_sideband_text(SharedString::from(state.sideband_text()));
            ui.set_mode_d(state.mode_d);
            ui.set_mode_text(SharedString::from(state.mode_text()));
            ui.set_sync_level(state.sync_level as i32);
            ui.set_sync_text(SharedString::from(state.sync_text()));
            ui.set_snr_text(SharedString::from(state.snr_text().as_str()));
            ui.set_snr_fraction(state.snr_fraction());
            ui.set_foff_text(SharedString::from(state.foff_text().as_str()));
            ui.set_foff_fraction(state.foff_fraction());
            ui.set_uw_text(SharedString::from(state.uw_text().as_str()));
            ui.set_frames_text(SharedString::from(state.frames_text().as_str()));
            ui.set_frame_error(state.last_frame_error);
            ui.set_speech(state.speech);
            ui.set_speech_text(SharedString::from(state.speech_text()));
            ui.set_squelch_on(state.squelch_on);
            ui.set_squelch_text(SharedString::from(state.squelch_text().as_str()));
            ui.set_text_line(SharedString::from(state.text.as_str()));
            ui.set_text_partial(SharedString::from(state.text_partial.as_str()));
            ui.set_text_fresh(state.sync_level != 0);
            ui.set_audio_text(SharedString::from(state.audio_text.as_str()));
            ui.set_audio_ok(state.audio_ok);
            ui.set_link_text(SharedString::from(state.link_text.as_str()));
            ui.set_link_ok(state.link_ok);
            ui.set_scale_note(SharedString::from(state.axis.note));
            ui.set_nominal_x(state.nominal_x() as i32);
            ui.set_signal_visible(state.signal_x().is_some());
            ui.set_signal_x(state.signal_x().unwrap_or(0) as i32);
            if shown.map(|s| s.axis != state.axis).unwrap_or(true) {
                let ticks: alloc::vec::Vec<FdvTick> = state.ticks().into_iter().map(|(x, t)| FdvTick { x: x as i32, text: SharedString::from(t.as_str()) }).collect();
                let ticks: alloc::rc::Rc<dyn Model<Data = FdvTick>> = alloc::rc::Rc::new(VecModel::from(ticks));
                ui.set_ticks(ModelRc::from(ticks));
            }
        }

        /// Events the user raised on the FreeDV view, in order, waiting for the firmware.
        pub type FdvEventQueue = alloc::rc::Rc<core::cell::RefCell<alloc::vec::Vec<crate::fdv::FdvEvent>>>;

        /// Connects every callback of the window's `FdvModel` to a new queue, which it returns.
        pub fn connect_fdv_events(window: &$window_ty) -> FdvEventQueue {
            use crate::fdv::FdvEvent;
            use slint::ComponentHandle;

            let q: FdvEventQueue = alloc::rc::Rc::new(core::cell::RefCell::new(alloc::vec::Vec::new()));
            let ui = window.global::<FdvModel>();
            let s = q.clone();
            ui.on_request_band_select(move |i| s.borrow_mut().push(FdvEvent::BandSelect(i as usize)));
            let s = q.clone();
            ui.on_request_mode(move |d| s.borrow_mut().push(FdvEvent::SelectE(!d)));
            let s = q.clone();
            ui.on_request_squelch_toggle(move || s.borrow_mut().push(FdvEvent::SquelchToggle));
            let s = q.clone();
            ui.on_request_squelch_step(move |d| s.borrow_mut().push(FdvEvent::SquelchStep(d)));
            let s = q.clone();
            ui.on_request_tune(move |d| s.borrow_mut().push(FdvEvent::Tune(d)));
            let s = q.clone();
            ui.on_request_switch_to_ft8(move || s.borrow_mut().push(FdvEvent::SwitchToFt8));
            let s = q.clone();
            ui.on_request_switch_to_listen(move || s.borrow_mut().push(FdvEvent::SwitchToListen));
            q
        }
    };
}

/// The same for the LISTEN view (`ListenScreen1920x1080`, or inside `AppScreen1920x1080`).
macro_rules! impl_listen_view {
    ($window_ty:ident) => {
        /// Pushes all of `state` into the window's `ListenModel` global.
        pub fn apply_listen_state(window: &$window_ty, state: &crate::listen::ListenScreenState) {
            apply_listen_state_diff(window, None, state);
        }

        /// Pushes what differs from `shown` (all of it for `None`); lists only when they changed.
        pub fn apply_listen_state_diff(window: &$window_ty, shown: Option<&crate::listen::ListenScreenState>, state: &crate::listen::ListenScreenState) {
            use slint::{ComponentHandle, Model, ModelRc, SharedString, VecModel};

            let ui = window.global::<ListenModel>();
            let first = shown.is_none();
            if first || shown.map(|s| s.freq_hz) != Some(state.freq_hz) {
                let d: alloc::vec::Vec<i32> = state.digits().iter().map(|v| *v as i32).collect();
                let d: alloc::rc::Rc<dyn Model<Data = i32>> = alloc::rc::Rc::new(VecModel::from(d));
                ui.set_digits(ModelRc::from(d));
                ui.set_lead_zeros(state.lead_zeros() as i32);
                ui.set_freq_text(SharedString::from(state.freq_text().as_str()));
            }
            if shown.map(|s| s.band_names != state.band_names).unwrap_or(true) {
                let names: alloc::vec::Vec<SharedString> = state.band_names.iter().map(|n| SharedString::from(*n)).collect();
                let names: alloc::rc::Rc<dyn Model<Data = SharedString>> = alloc::rc::Rc::new(VecModel::from(names));
                ui.set_band_names(ModelRc::from(names));
            }
            if shown.map(|s| s.filter_names != state.filter_names).unwrap_or(true) {
                let names: alloc::vec::Vec<SharedString> = state.filter_names.iter().map(|n| SharedString::from(n.as_str())).collect();
                let names: alloc::rc::Rc<dyn Model<Data = SharedString>> = alloc::rc::Rc::new(VecModel::from(names));
                ui.set_filter_names(ModelRc::from(names));
            }
            if first {
                let names: alloc::vec::Vec<SharedString> = state.step_names().iter().map(|n| SharedString::from(n.as_str())).collect();
                let names: alloc::rc::Rc<dyn Model<Data = SharedString>> = alloc::rc::Rc::new(VecModel::from(names));
                ui.set_step_names(ModelRc::from(names));
            }
            if shown.map(|s| s.axis != state.axis).unwrap_or(true) {
                let ticks: alloc::vec::Vec<ListenTick> = state.ticks().into_iter().map(|(x, t)| ListenTick { x: x as i32, text: SharedString::from(t.as_str()) }).collect();
                let ticks: alloc::rc::Rc<dyn Model<Data = ListenTick>> = alloc::rc::Rc::new(VecModel::from(ticks));
                ui.set_ticks(ModelRc::from(ticks));
                ui.set_scale_note(SharedString::from(state.axis.note));
                ui.set_centre_x(state.axis.centre_px as i32);
            }
            ui.set_mode_index(state.mode.index() as i32);
            ui.set_band_index(state.band_index as i32);
            ui.set_filter_index(state.filter_index as i32);
            ui.set_step_index(state.step_index as i32);
            let step = crate::listen::STEPS_HZ[state.step_index.min(crate::listen::STEPS_HZ.len() - 1)];
            ui.set_step_text(SharedString::from(crate::listen::step_name(step).as_str()));
            ui.set_agc_on(state.agc_on);
            ui.set_agc_available(state.agc_available());
            ui.set_squelch_on(state.squelch_on);
            ui.set_squelch_text(SharedString::from(state.squelch_text().as_str()));
            ui.set_squelch_open(state.squelch_open);
            ui.set_squelch_fraction(state.squelch_fraction());
            ui.set_volume_pct(state.volume_pct as i32);
            ui.set_volume_text(SharedString::from(state.volume_text().as_str()));
            ui.set_smeter_fraction(state.smeter_fraction());
            ui.set_smeter_text(SharedString::from(state.smeter_text().as_str()));
            let (x0, x1) = state.passband_px();
            ui.set_passband_x0(x0);
            ui.set_passband_x1(x1);
            ui.set_info_text(SharedString::from(state.info_text.as_str()));
            ui.set_audio_text(SharedString::from(state.audio_text.as_str()));
            ui.set_audio_ok(state.audio_ok);
            ui.set_link_text(SharedString::from(state.link_text.as_str()));
            ui.set_link_ok(state.link_ok);
            ui.set_wf_sensitivity_text(SharedString::from(state.wf_sensitivity_text().as_str()));
            ui.set_wf_range_text(SharedString::from(state.wf_range_text().as_str()));
            ui.set_wf_speed_text(SharedString::from(state.wf_speed_text().as_str()));
            ui.set_wf_available(state.axis.waterfall);
            ui.set_rf_gain_text(SharedString::from(state.rf_gain_text().as_str()));
            ui.set_rf_agc_auto(state.rf_agc_auto);
            ui.set_hl2_text(SharedString::from(state.hl2_text.as_str()));
        }

        /// Events the user raised on the LISTEN view, in order, waiting for the firmware.
        pub type ListenEventQueue = alloc::rc::Rc<core::cell::RefCell<alloc::vec::Vec<crate::listen::ListenEvent>>>;

        /// Connects every callback of the window's `ListenModel` to a new queue, which it returns.
        /// Index and step arguments are clamped here, so a bad value never reaches the firmware.
        pub fn connect_listen_events(window: &$window_ty) -> ListenEventQueue {
            use crate::listen::{ListenEvent, ListenMode};
            use slint::ComponentHandle;

            let q: ListenEventQueue = alloc::rc::Rc::new(core::cell::RefCell::new(alloc::vec::Vec::new()));
            let ui = window.global::<ListenModel>();
            let s = q.clone();
            ui.on_request_mode(move |i| {
                if let Some(m) = ListenMode::from_index(i.max(0) as usize) {
                    s.borrow_mut().push(ListenEvent::Mode(m));
                }
            });
            let s = q.clone();
            ui.on_request_filter(move |i| s.borrow_mut().push(ListenEvent::Filter(i.max(0) as usize)));
            let s = q.clone();
            ui.on_request_step(move |i| s.borrow_mut().push(ListenEvent::Step(i.max(0) as usize)));
            let s = q.clone();
            ui.on_request_tune_steps(move |n| s.borrow_mut().push(ListenEvent::TuneSteps(n)));
            let s = q.clone();
            ui.on_request_tune_digit(move |place, dir| s.borrow_mut().push(ListenEvent::TuneDigit { place: place.clamp(0, 7) as u32, dir: dir.signum() }));
            let s = q.clone();
            ui.on_request_waterfall_click(move |x| s.borrow_mut().push(ListenEvent::WaterfallClick(x)));
            let s = q.clone();
            ui.on_request_band_select(move |i| s.borrow_mut().push(ListenEvent::BandSelect(i.max(0) as usize)));
            let s = q.clone();
            ui.on_request_agc_toggle(move || s.borrow_mut().push(ListenEvent::AgcToggle));
            let s = q.clone();
            ui.on_request_squelch_toggle(move || s.borrow_mut().push(ListenEvent::SquelchToggle));
            let s = q.clone();
            ui.on_request_squelch_step(move |d| s.borrow_mut().push(ListenEvent::SquelchStep(d)));
            let s = q.clone();
            ui.on_request_volume_step(move |d| s.borrow_mut().push(ListenEvent::VolumeStep(d)));
            let s = q.clone();
            ui.on_request_switch_to_ft8(move || s.borrow_mut().push(ListenEvent::SwitchToFt8));
            let s = q.clone();
            ui.on_request_switch_to_freedv(move || s.borrow_mut().push(ListenEvent::SwitchToFreedv));
            let s = q.clone();
            ui.on_request_wf_sensitivity_step(move |d| s.borrow_mut().push(ListenEvent::WfSensitivityStep(d.signum())));
            let s = q.clone();
            ui.on_request_wf_sensitivity_auto(move || s.borrow_mut().push(ListenEvent::WfSensitivityAuto));
            let s = q.clone();
            ui.on_request_wf_range_step(move |d| s.borrow_mut().push(ListenEvent::WfRangeStep(d.signum())));
            let s = q.clone();
            ui.on_request_wf_speed_step(move |d| s.borrow_mut().push(ListenEvent::WfSpeedStep(d.signum())));
            let s = q.clone();
            ui.on_request_rf_gain_step(move |d| s.borrow_mut().push(ListenEvent::RfGainStep(d.signum())));
            let s = q.clone();
            ui.on_request_rf_agc_toggle(move || s.borrow_mut().push(ListenEvent::RfAgcToggle));
            q
        }
    };
}

/// The FT8 operating screen at 1920x1080 (docs/P2_FT8_FW.md). `ui/ft8_1920x1080.slint`.
pub mod ft8_1920x1080 {
    #![allow(clippy::all)]
    include!(concat!(env!("OUT_DIR"), "/ft8_1920x1080.rs"));

    impl_ft8_view!(Ft8Screen1920x1080);
}

/// The FreeDV screen at 1920x1080 (docs/FREEDV.md). `ui/fdv_1920x1080.slint`.
pub mod fdv_1920x1080 {
    #![allow(clippy::all)]
    include!(concat!(env!("OUT_DIR"), "/fdv_1920x1080.rs"));

    impl_fdv_view!(FdvScreen1920x1080);
}

/// The LISTEN screen on its own (the host test).
pub mod listen_1920x1080 {
    #![allow(clippy::all)]
    include!(concat!(env!("OUT_DIR"), "/listen_1920x1080.rs"));

    impl_listen_view!(ListenScreen1920x1080);
}

/// The firmware window: the FT8 view, the FreeDV view and the LISTEN view, one of them shown
/// at a time (`set_freedv` and `set_listen` choose which). `ui/app_1920x1080.slint`.
pub mod app_1920x1080 {
    #![allow(clippy::all)]
    include!(concat!(env!("OUT_DIR"), "/app_1920x1080.rs"));

    impl_ft8_view!(AppScreen1920x1080);
    impl_fdv_view!(AppScreen1920x1080);
    impl_listen_view!(AppScreen1920x1080);

    /// Shows the LISTEN view (`true`) over the FT8 or FreeDV view.
    pub fn set_listen(window: &AppScreen1920x1080, on: bool) {
        use slint::ComponentHandle;
        window.global::<AppModel>().set_listen(on);
    }

    /// Shows the FreeDV view (`true`) or the FT8 view.
    pub fn set_freedv(window: &AppScreen1920x1080, on: bool) {
        use slint::ComponentHandle;
        window.global::<AppModel>().set_freedv(on);
    }

    /// Moves the drawn mouse pointer to `pointer` (docs/USB_HOST.md section 6). It stays hidden
    /// until a mouse has moved.
    pub fn set_pointer(window: &AppScreen1920x1080, pointer: &crate::input::Pointer) {
        use slint::ComponentHandle;
        let m = window.global::<AppModel>();
        m.set_pointer_x(pointer.x as f32);
        m.set_pointer_y(pointer.y as f32);
        m.set_pointer_shown(pointer.shown);
    }
}
