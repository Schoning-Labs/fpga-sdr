// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
//! Host test of the LISTEN screen (docs/LISTEN.md). The screen is rendered headless with the
//! software renderer the firmware uses and written to docs/img/listen_1920x1080.png, and so is
//! an AM screen on a chip without a zoom receiver (listen_am_1920x1080.png). The test operates it
//! with pointer and wheel events at the positions of the controls and checks that each one arrives
//! as the right `ListenEvent`, that the waterfall rectangle stays exactly the key color, and that
//! the large frequency digits, the waterfall controls and the RF gain controls are drawn where
//! they should be.
//!
//! It then runs the firmware's window (`AppScreen1920x1080`): the buttons of the FT8 and FreeDV
//! screens that lead to LISTEN, the switch to it, line-by-line rendering with the hook of
//! `render_rgb565_lines_with`, and that the LISTEN view inside the firmware's window renders to
//! the same pixels as the stand-alone screen.
//!
//! It is one test function because the Slint platform is one per process.

use std::path::PathBuf;
use std::time::Instant;

use slint::platform::software_renderer::Rgb565Pixel;
use slint::platform::{PointerEventButton, WindowEvent};
use slint::{ComponentHandle, LogicalPosition};
use tr_gui::fdv;
use tr_gui::ft8::{self, Ft8Event, Ft8ScreenState};
use tr_gui::listen::{self, ListenAxis, ListenEvent, ListenMode, ListenScreenState};
use tr_gui::platform::{new_window, new_window_swapped, render_rgb565, render_rgb565_lines, render_rgb565_lines_with, FramebufferPlatform};
use tr_gui::{app_1920x1080 as app, listen_1920x1080 as lmod};

const W: usize = 1920;
const H: usize = 1080;

fn save_png(name: &str, buffer: &[Rgb565Pixel]) {
    let rgb: Vec<u8> = buffer
        .iter()
        .flat_map(|p| {
            let (r5, g6, b5) = ((p.0 >> 11) & 0x1f, (p.0 >> 5) & 0x3f, p.0 & 0x1f);
            [((r5 << 3) | (r5 >> 2)) as u8, ((g6 << 2) | (g6 >> 4)) as u8, ((b5 << 3) | (b5 >> 2)) as u8]
        })
        .collect();
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../docs/img").join(name);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let mut enc = png::Encoder::new(std::io::BufWriter::new(std::fs::File::create(&path).unwrap()), W as u32, H as u32);
    enc.set_color(png::ColorType::Rgb);
    enc.set_depth(png::BitDepth::Eight);
    enc.write_header().unwrap().write_image_data(&rgb).unwrap();
}

fn click(window: &slint::Window, at: (u32, u32)) {
    let position = LogicalPosition::new(at.0 as f32, at.1 as f32);
    window.dispatch_event(WindowEvent::PointerMoved { position });
    window.dispatch_event(WindowEvent::PointerPressed { position, button: PointerEventButton::Left });
    window.dispatch_event(WindowEvent::PointerReleased { position, button: PointerEventButton::Left });
}

/// One wheel click away from the user (`tr_gui::input::dispatch` sends 40 pixels per click).
fn wheel(window: &slint::Window, at: (u32, u32), clicks: i32) {
    let position = LogicalPosition::new(at.0 as f32, at.1 as f32);
    window.dispatch_event(WindowEvent::PointerMoved { position });
    window.dispatch_event(WindowEvent::PointerScrolled { position, delta_x: 0.0, delta_y: clicks as f32 * 40.0 });
}

fn key_pixels(buffer: &[Rgb565Pixel]) -> usize {
    let (x0, y0, w, h) = ft8::WATERFALL_RECT;
    (y0..y0 + h).flat_map(|y| (x0..x0 + w).map(move |x| (x, y))).filter(|&(x, y)| buffer[y as usize * W + x as usize].0 == 0xF81F).count()
}

/// Pixels in the rectangle that differ from its top-left pixel.
fn ink(buffer: &[Rgb565Pixel], x: u32, y: u32, w: u32, h: u32) -> usize {
    let bg = buffer[y as usize * W + x as usize].0;
    (y..y + h).flat_map(|yy| (x..x + w).map(move |xx| (xx, yy))).filter(|&(xx, yy)| buffer[yy as usize * W + xx as usize].0 != bg).count()
}

/// Rows of the rectangle that hold any pixel brighter than mid gray (the digits are near white).
fn bright_rows(buffer: &[Rgb565Pixel], x: u32, y: u32, w: u32, h: u32) -> usize {
    (y..y + h).filter(|&yy| (x..x + w).any(|xx| (buffer[yy as usize * W + xx as usize].0 >> 11) > 24)).count()
}

#[test]
fn listen_screen_renders_and_reports_what_the_operator_does() {
    let start = Instant::now();
    FramebufferPlatform::install(move || start.elapsed()).expect("one Slint platform per process");
    let (x0, y0, w, h) = ft8::WATERFALL_RECT;

    // ================================================================ the LISTEN screen on its own
    let window = new_window(W as u32, H as u32);
    let ui = lmod::ListenScreen1920x1080::new().unwrap();
    let events = lmod::connect_listen_events(&ui);
    ui.show().unwrap();
    let demo = ListenScreenState::demo();
    lmod::apply_listen_state(&ui, &demo);
    slint::platform::update_timers_and_animations();
    let mut buffer = vec![Rgb565Pixel(0); W * H];
    assert!(render_rgb565(&window, &mut buffer, W));
    save_png("listen_1920x1080.png", &buffer);
    assert_eq!(key_pixels(&buffer), (w * h) as usize, "every pixel of the waterfall rectangle must be the key colour");
    assert_ne!(buffer[(y0 as usize - 1) * W + x0 as usize].0, 0xF81F, "nothing outside it may be");
    // the frequency digits are large: 120 px font, the glyphs well over 70 px tall
    let tall = bright_rows(&buffer, 1_236, 110, 660, 160);
    assert!(tall > 70, "frequency digits {tall} px tall");
    assert!(ink(&buffer, 1_428, 452, 460, 50) > 300, "the S-meter figure is drawn");
    assert!(ink(&buffer, 1_228, 504, 660, 30) > 1_000, "the S-meter bar is drawn");
    // sensitivity, contrast and speed: label above, - value + below; Auto at the right
    for x in [1_228, 1_418, 1_608] {
        assert!(ink(&buffer, x, 910, 150, 28) > 60, "label at {x}");
        assert!(ink(&buffer, x + 48, 942, 84, 44) > 60, "value at {x}");
    }
    assert!(ink(&buffer, 1_798, 942, 90, 44) > 200, "Auto");
    // RF gain: label, - value +, AUTO; the HL2 line under the link line in the top bar
    assert!(ink(&buffer, 980, 898, 100, 26) > 60, "RF gain label");
    assert!(ink(&buffer, 1_036, 930, 92, 48) > 60, "RF gain value");
    assert!(ink(&buffer, 980, 990, 204, 58) > 200, "AUTO");
    assert!(ink(&buffer, 1_500, 48, 404, 26) > 60, "HL2 line");
    // the row is inside the right panel (x 1228 to 1888) and nothing is drawn past it
    assert_eq!(ink(&buffer, 1_890, 900, 12, 160), 0);
    // the pass band bar on the scale: LSB, left of the tuned frequency
    let (p0, p1) = demo.passband_px();
    assert!(p1 < demo.axis.centre_px as i32 && p0 < p1);
    let bar = buffer[(788 + 4) * W + x0 as usize + ((p0 + p1) / 2) as usize].0;
    assert_eq!(bar, buffer[(788 + 4) * W + x0 as usize + p0 as usize + 2].0);
    assert_ne!(bar, buffer[(788 + 4) * W + x0 as usize + demo.axis.centre_px as usize + 60].0, "right of the tuned frequency is outside the pass band");

    // AM on 9.650 MHz, a chip without the zoom receiver, squelch on and closed
    let am = ListenScreenState {
        freq_hz: 9_650_000,
        mode: ListenMode::Am,
        band_index: 10,
        filter_names: vec![String::from("6 kHz"), String::from("9 kHz"), String::from("4 kHz")],
        filter_index: 1,
        step_index: 3,
        passband: (-4_500, 4_500),
        axis: ListenAxis::none(),
        squelch_on: true,
        squelch_open: false,
        squelch_db: -96.0,
        smeter_dbfs: -104.0,
        agc_on: false,
        ..demo.clone()
    };
    lmod::apply_listen_state_diff(&ui, Some(&demo), &am);
    slint::platform::update_timers_and_animations();
    let mut buffer2 = buffer.clone();
    assert!(render_rgb565(&window, &mut buffer2, W));
    save_png("listen_am_1920x1080.png", &buffer2);
    assert_ne!(buffer, buffer2);
    assert_eq!(key_pixels(&buffer2), (w * h) as usize);
    lmod::apply_listen_state_diff(&ui, Some(&am), &demo);
    slint::platform::update_timers_and_animations();
    render_rgb565(&window, &mut buffer2, W);

    // the operator's actions arrive as events
    for i in 0..6 {
        click(ui.window(), listen::mode_button_at(i));
    }
    click(ui.window(), listen::filter_button_at(2));
    click(ui.window(), listen::step_button_at(6));
    click(ui.window(), listen::AGC_AT);
    click(ui.window(), listen::SQUELCH_AT);
    click(ui.window(), listen::VOLUME_DOWN_AT);
    click(ui.window(), listen::VOLUME_UP_AT);
    click(ui.window(), listen::band_button_at(10));
    click(ui.window(), listen::digit_at(1, true)); // the 1 MHz digit, upper half
    click(ui.window(), listen::digit_at(5, false)); // the 100 Hz digit, lower half
    wheel(ui.window(), listen::digit_at(4, true), 1); // the 1 kHz digit, wheel away from the user
    wheel(ui.window(), listen::digit_at(7, true), -1); // the 1 Hz digit, wheel toward the user
    click(ui.window(), (x0 + 586 + 160, y0 + 300)); // the waterfall, 160 px right of the middle
    wheel(ui.window(), (x0 + 100, y0 + 100), -1);
    click(ui.window(), listen::TO_FT8_AT);
    click(ui.window(), listen::TO_FREEDV_AT);
    click(ui.window(), listen::WF_SENS_DOWN_AT);
    click(ui.window(), listen::WF_SENS_UP_AT);
    click(ui.window(), listen::WF_RANGE_DOWN_AT);
    click(ui.window(), listen::WF_RANGE_UP_AT);
    click(ui.window(), listen::WF_SPEED_DOWN_AT);
    click(ui.window(), listen::WF_SPEED_UP_AT);
    click(ui.window(), listen::WF_AUTO_AT);
    click(ui.window(), listen::RF_GAIN_DOWN_AT);
    click(ui.window(), listen::RF_GAIN_UP_AT);
    click(ui.window(), listen::RF_AGC_AT);
    let want: Vec<ListenEvent> = ListenMode::ALL
        .iter()
        .map(|m| ListenEvent::Mode(*m))
        .chain([
            ListenEvent::Filter(2),
            ListenEvent::Step(6),
            ListenEvent::AgcToggle,
            ListenEvent::SquelchToggle,
            ListenEvent::VolumeStep(-5),
            ListenEvent::VolumeStep(5),
            ListenEvent::BandSelect(10),
            ListenEvent::TuneDigit { place: 6, dir: 1 },
            ListenEvent::TuneDigit { place: 2, dir: -1 },
            ListenEvent::TuneDigit { place: 3, dir: 1 },
            ListenEvent::TuneDigit { place: 0, dir: -1 },
            ListenEvent::WaterfallClick(586 + 160),
            ListenEvent::TuneSteps(-1),
            ListenEvent::SwitchToFt8,
            ListenEvent::SwitchToFreedv,
            ListenEvent::WfSensitivityStep(-1),
            ListenEvent::WfSensitivityStep(1),
            ListenEvent::WfRangeStep(-1),
            ListenEvent::WfRangeStep(1),
            ListenEvent::WfSpeedStep(-1),
            ListenEvent::WfSpeedStep(1),
            ListenEvent::WfSensitivityAuto,
            ListenEvent::RfGainStep(-1),
            ListenEvent::RfGainStep(1),
            ListenEvent::RfAgcToggle,
        ])
        .collect();
    assert_eq!(*events.borrow(), want);
    // a click on the S-meter or the information lines asks for nothing
    events.borrow_mut().clear();
    click(ui.window(), (1_500, 515));
    click(ui.window(), (1_500, 930));
    assert!(events.borrow().is_empty());
    ui.hide().unwrap();

    // ================================================================ the firmware's window
    let window = new_window_swapped(W as u32, H as u32);
    let ui = app::AppScreen1920x1080::new().unwrap();
    let ft8_events = app::connect_events(&ui);
    let fdv_events = app::connect_fdv_events(&ui);
    let listen_events = app::connect_listen_events(&ui);
    ui.show().unwrap();
    app::apply_state(&ui, &Ft8ScreenState::demo());
    app::apply_listen_state(&ui, &demo);
    slint::platform::update_timers_and_animations();
    let mut ft8_view = vec![Rgb565Pixel(0); W * H];
    assert!(render_rgb565_lines(&window, &mut ft8_view, W).is_some());
    // the FT8 screen's LISTEN button
    click(ui.window(), fdv::FT8_TO_LISTEN_AT);
    assert_eq!(*ft8_events.borrow(), [Ft8Event::SwitchToListen]);
    // FreeDV screen's LISTEN button
    app::set_freedv(&ui, true);
    slint::platform::update_timers_and_animations();
    click(ui.window(), fdv::TO_LISTEN_AT);
    assert_eq!(*fdv_events.borrow(), [fdv::FdvEvent::SwitchToListen]);

    // LISTEN over FreeDV, drawn line by line with the hook: the hook runs, the picture is the LISTEN view
    app::set_listen(&ui, true);
    slint::platform::update_timers_and_animations();
    let mut back = ft8_view.clone();
    let mut hooks = 0;
    let (first, lines) = render_rgb565_lines_with(&window, &mut back, W, || hooks += 1).expect("the view changed");
    assert!(first < 20 && lines > 1_000, "switching redraws the screen: {first}+{lines}");
    assert!(hooks >= 1_000 / 16, "the hook ran {hooks} times");
    assert_eq!(key_pixels(&back), (w * h) as usize);
    let same = back.iter().zip(&buffer).filter(|(a, b)| a == b).count();
    assert_eq!(same, W * H, "the firmware's LISTEN view equals the stand-alone one");
    click(ui.window(), listen::mode_button_at(3));
    assert_eq!(*listen_events.borrow(), [ListenEvent::Mode(ListenMode::Am)]);
    ui.hide().unwrap();
}
