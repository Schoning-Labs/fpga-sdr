// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
//! Host test of the FreeDV screen (docs/FREEDV.md section 9). The screen is rendered headless
//! with the software renderer the firmware uses, written to docs/img/fdv_1920x1080.png, and
//! operated with pointer events at the positions of the controls. The test checks that the
//! waterfall rectangle stays exactly the key color, that a state change redraws and a click on
//! a control arrives as the right `FdvEvent`. It then does the same for the firmware's window
//! (`AppScreen1920x1080`), which switches between the FT8 view and this one and only redraws
//! the lines that changed.
//!
//! It is one test function because the Slint platform is one per process.

use std::path::PathBuf;
use std::time::Instant;

use slint::platform::software_renderer::Rgb565Pixel;
use slint::platform::{PointerEventButton, WindowEvent};
use slint::{ComponentHandle, LogicalPosition};
use tr_gui::fdv::{self, FdvEvent, FdvScreenState, WfAxis};
use tr_gui::ft8::{self, Ft8Event, Ft8ScreenState};
use tr_gui::platform::{new_window, render_rgb565, render_rgb565_lines, FramebufferPlatform};
use tr_gui::{app_1920x1080 as app, fdv_1920x1080 as fdvmod};

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

fn key_pixels(buffer: &[Rgb565Pixel]) -> usize {
    let (x0, y0, w, h) = ft8::WATERFALL_RECT;
    (y0..y0 + h).flat_map(|y| (x0..x0 + w).map(move |x| (x, y))).filter(|&(x, y)| buffer[y as usize * W + x as usize].0 == 0xF81F).count()
}

/// Pixels in the rectangle that differ from its top-left pixel.
fn ink(buffer: &[Rgb565Pixel], x: u32, y: u32, w: u32, h: u32) -> usize {
    let bg = buffer[y as usize * W + x as usize].0;
    (y..y + h).flat_map(|yy| (x..x + w).map(move |xx| (xx, yy))).filter(|&(xx, yy)| buffer[yy as usize * W + xx as usize].0 != bg).count()
}

#[test]
fn fdv_screen_renders_and_reports_what_the_operator_does() {
    let start = Instant::now();
    FramebufferPlatform::install(move || start.elapsed()).expect("one Slint platform per process");

    // ================================================================ the FreeDV screen on its own
    let window = new_window(W as u32, H as u32);
    let ui = fdvmod::FdvScreen1920x1080::new().unwrap();
    let events = fdvmod::connect_fdv_events(&ui);
    ui.show().unwrap();

    // searching
    let searching = FdvScreenState::default();
    fdvmod::apply_fdv_state(&ui, &searching);
    slint::platform::update_timers_and_animations();
    let mut buffer = vec![Rgb565Pixel(0); W * H];
    assert!(render_rgb565(&window, &mut buffer, W));
    let (x0, y0, w, h) = ft8::WATERFALL_RECT;
    assert_eq!(key_pixels(&buffer), (w * h) as usize, "every pixel of the waterfall rectangle must be the key colour");
    assert_ne!(buffer[(y0 as usize - 1) * W + x0 as usize].0, 0xF81F, "nothing outside it may be");
    let lamp_searching = buffer[140 * W + 1_240].0;

    // locked, in use
    let demo = FdvScreenState::demo();
    fdvmod::apply_fdv_state(&ui, &demo);
    slint::platform::update_timers_and_animations();
    assert!(render_rgb565(&window, &mut buffer, W));
    save_png("fdv_1920x1080.png", &buffer);
    assert_eq!(key_pixels(&buffer), (w * h) as usize);
    assert_ne!(buffer[140 * W + 1_240].0, lamp_searching, "the sync lamp changes colour");
    assert!(ink(&buffer, 1_232, 674, 650, 70) > 400, "the text from the sender is drawn");
    assert!(ink(&buffer, 1_232, 236, 650, 60) > 300, "the SNR is drawn");
    let mut later = demo.clone();
    later.foff_hz = -60.0;
    later.last_frame_error = true;
    later.text = String::from("K1XYZ");
    later.axis = WfAxis::zoom(true);
    later.lower_sideband = true;
    fdvmod::apply_fdv_state_diff(&ui, Some(&demo), &later);
    slint::platform::update_timers_and_animations();
    let mut buffer2 = buffer.clone();
    assert!(render_rgb565(&window, &mut buffer2, W));
    assert_ne!(buffer, buffer2);
    assert_eq!(key_pixels(&buffer2), (w * h) as usize);
    fdvmod::apply_fdv_state_diff(&ui, Some(&later), &demo);
    slint::platform::update_timers_and_animations();
    render_rgb565(&window, &mut buffer, W);

    // the operator's actions arrive as events
    click(ui.window(), fdv::MODE_E_AT);
    click(ui.window(), fdv::MODE_D_AT);
    click(ui.window(), fdv::SQUELCH_AT);
    click(ui.window(), fdv::SQUELCH_DOWN_AT);
    click(ui.window(), fdv::SQUELCH_UP_AT);
    click(ui.window(), fdv::TUNE_DOWN_AT);
    click(ui.window(), fdv::TUNE_UP_AT);
    click(ui.window(), ft8::band_button_at(3));
    click(ui.window(), fdv::TO_FT8_AT);
    assert_eq!(
        *events.borrow(),
        [
            FdvEvent::SelectE(true),
            FdvEvent::SelectE(false),
            FdvEvent::SquelchToggle,
            FdvEvent::SquelchStep(-1),
            FdvEvent::SquelchStep(1),
            FdvEvent::Tune(-100),
            FdvEvent::Tune(100),
            FdvEvent::BandSelect(3),
            FdvEvent::SwitchToFt8
        ]
    );
    // a click in the waterfall or on the indicators asks for nothing
    events.borrow_mut().clear();
    click(ui.window(), (x0 + 500, y0 + 300));
    click(ui.window(), (1_500, 300));
    assert!(events.borrow().is_empty());
    ui.hide().unwrap();

    // ================================================================ the firmware's window
    let window = new_window(W as u32, H as u32);
    let ui = app::AppScreen1920x1080::new().unwrap();
    let ft8_events = app::connect_events(&ui);
    let fdv_events = app::connect_fdv_events(&ui);
    ui.show().unwrap();
    app::apply_state(&ui, &Ft8ScreenState::demo());
    app::apply_fdv_state(&ui, &demo);
    slint::platform::update_timers_and_animations();
    let mut ft8_view = vec![Rgb565Pixel(0); W * H];
    assert!(render_rgb565(&window, &mut ft8_view, W));
    assert_eq!(key_pixels(&ft8_view), (w * h) as usize);
    // FT8 shows: a click on "FreeDV >" asks to switch; the FreeDV controls do nothing
    click(ui.window(), fdv::MODE_E_AT);
    assert!(ft8_events.borrow().is_empty() || !ft8_events.borrow().contains(&Ft8Event::SwitchToFreedv));
    assert!(fdv_events.borrow().is_empty(), "the FreeDV view is not there while FT8 is shown");
    ft8_events.borrow_mut().clear();
    click(ui.window(), fdv::TO_FREEDV_AT);
    assert_eq!(*ft8_events.borrow(), [Ft8Event::SwitchToFreedv]);

    app::set_freedv(&ui, true);
    slint::platform::update_timers_and_animations();
    let (first, lines) = render_rgb565_lines(&window, &mut buffer, W).expect("the view changed");
    assert!(first < 20 && lines > 1_000, "switching redraws the screen: {first}+{lines}");
    assert_eq!(key_pixels(&buffer), (w * h) as usize);
    let different = buffer.iter().zip(&ft8_view).filter(|(a, b)| a != b).count();
    assert!(different > 100_000, "the two views look different ({different} pixels)");
    assert!(ink(&buffer, 1_232, 674, 650, 70) > 400, "the sender's text is drawn in the firmware's window too");
    fdv_events.borrow_mut().clear();
    ft8_events.borrow_mut().clear();
    click(ui.window(), fdv::MODE_E_AT);
    click(ui.window(), fdv::TO_FT8_AT);
    assert_eq!(*fdv_events.borrow(), [FdvEvent::SelectE(true), FdvEvent::SwitchToFt8]);
    assert!(ft8_events.borrow().is_empty());
    app::set_freedv(&ui, false);
    slint::platform::update_timers_and_animations();
    let (_, lines) = render_rgb565_lines(&window, &mut buffer, W).expect("back to FT8");
    assert!(lines > 1_000);
    assert_eq!(buffer, ft8_view, "back to the FT8 view: the same picture as before");
    ui.hide().unwrap();
}
