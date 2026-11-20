// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
//! Host test of the FT8 operating screen (docs/P2_FT8_FW.md). The screen is rendered with the
//! same software renderer the firmware uses, written to docs/img/ft8_1920x1080.png, and operated
//! with pointer events at the positions of the controls. The test checks the start-up state (TX
//! off), that the waterfall rectangle stays exactly the key color, that a clock tick or a new
//! decode line redraws only the lines it should (`render_rgb565_lines`), and that each click
//! arrives as the right `Ft8Event` without changing the screen by itself.
//!
//! It is one test function because the Slint platform is one per process and single-threaded.

use std::path::PathBuf;
use std::time::Instant;

use slint::platform::software_renderer::Rgb565Pixel;
use slint::platform::{PointerEventButton, WindowEvent};
use slint::{ComponentHandle, LogicalPosition};
use tr_gui::ft8::{self, Ft8Event, Ft8ScreenState};
use tr_gui::ft8_1920x1080::{apply_state, apply_state_diff, connect_events, Ft8Model, Ft8Screen1920x1080};
use tr_gui::platform::{new_window, render_rgb565, render_rgb565_lines, FramebufferPlatform};

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

fn click(ui: &Ft8Screen1920x1080, at: (u32, u32)) {
    let position = LogicalPosition::new(at.0 as f32, at.1 as f32);
    ui.window().dispatch_event(WindowEvent::PointerMoved { position });
    ui.window().dispatch_event(WindowEvent::PointerPressed { position, button: PointerEventButton::Left });
    ui.window().dispatch_event(WindowEvent::PointerReleased { position, button: PointerEventButton::Left });
}

#[test]
fn ft8_screen_renders_and_reports_what_the_operator_does() {
    let start = Instant::now();
    FramebufferPlatform::install(move || start.elapsed()).expect("one Slint platform per process");
    let window = new_window(W as u32, H as u32);
    let ui = Ft8Screen1920x1080::new().unwrap();
    let events = connect_events(&ui);
    ui.show().unwrap();

    // ---- start-up state: TX off
    apply_state(&ui, &Ft8ScreenState::default());
    slint::platform::update_timers_and_animations();
    let mut buffer = vec![Rgb565Pixel(0); W * H];
    assert!(render_rgb565(&window, &mut buffer, W));
    assert!(!ui.global::<Ft8Model>().get_tx_enabled());
    let tx_off_pixel = buffer[(ft8::TX_ENABLE_AT.1 as usize - 30) * W + ft8::TX_ENABLE_AT.0 as usize - 120].0;

    // ---- the waterfall rectangle is untouched key color, so the compositor shows the logic's window
    let (x0, y0, w, h) = ft8::WATERFALL_RECT;
    let key = (y0..y0 + h).flat_map(|y| (x0..x0 + w).map(move |x| (x, y))).filter(|&(x, y)| buffer[y as usize * W + x as usize].0 == 0xF81F).count();
    assert_eq!(key, (w * h) as usize, "every pixel of the waterfall rectangle must be the key colour");
    assert_ne!(buffer[(y0 as usize - 1) * W + x0 as usize].0, 0xF81F, "nothing outside it may be");

    // ---- a screen in use
    let demo = Ft8ScreenState::demo();
    apply_state(&ui, &demo);
    slint::platform::update_timers_and_animations();
    assert!(render_rgb565(&window, &mut buffer, W));
    save_png("ft8_1920x1080.png", &buffer);
    let tx_on_pixel = buffer[(ft8::TX_ENABLE_AT.1 as usize - 30) * W + ft8::TX_ENABLE_AT.0 as usize - 120].0;
    assert_ne!(tx_on_pixel, tx_off_pixel, "the TX switch must look different when on");
    let (rx, ry, rw, rh) = ft8::DECODE_ROWS;
    let text_pixels = |row: u32| {
        let bg = buffer[(ry + row * rh + 1) as usize * W + (rx + rw - 3) as usize].0;
        (ry + row * rh..ry + (row + 1) * rh).flat_map(|y| (rx + 300..rx + rw - 4).map(move |x| (x, y))).filter(|&(x, y)| buffer[y as usize * W + x as usize].0 != bg).count()
    };
    assert!(text_pixels(0) > 200, "decode row 0 shows a message");
    assert!(text_pixels(9) > 200, "decode row 9 shows a message");
    assert_eq!(text_pixels(10), 0, "ten decodes, no eleventh row");

    // ---- a second later only the clock and the slot bar have changed: only their lines are redrawn
    let mut later = demo.clone();
    later.utc_s_of_day = demo.utc_s_of_day.map(|s| s + 1);
    later.slot_progress = 8.0 / 15.0;
    apply_state_diff(&ui, Some(&demo), &later);
    slint::platform::update_timers_and_animations();
    let (first, lines) = render_rgb565_lines(&window, &mut buffer, W).expect("the clock changed");
    assert!(first < 20 && first + lines <= 100, "a clock tick redrew lines {first}..{}", first + lines);
    // The same state again: nothing to draw.
    apply_state_diff(&ui, Some(&later), &later);
    slint::platform::update_timers_and_animations();
    assert_eq!(render_rgb565_lines(&window, &mut buffer, W), None);
    // A new decode line redraws the list.
    let mut more = later.clone();
    more.decodes.insert(0, demo.decodes[1].clone());
    apply_state_diff(&ui, Some(&later), &more);
    slint::platform::update_timers_and_animations();
    let (first, lines) = render_rgb565_lines(&window, &mut buffer, W).expect("a new line");
    assert!(first >= 130 && lines > 300, "list redraw {first}+{lines}");
    apply_state_diff(&ui, Some(&more), &demo);
    slint::platform::update_timers_and_animations();
    render_rgb565(&window, &mut buffer, W);

    // ---- the operator's actions arrive as events, and change nothing by themselves
    click(&ui, ft8::TX_ENABLE_AT);
    assert_eq!(*events.borrow(), [Ft8Event::TxEnableToggle]);
    assert!(ui.global::<Ft8Model>().get_tx_enabled(), "the screen shows what the state says, not the click");
    events.borrow_mut().clear();

    click(&ui, (rx + 400, ry + 4 * rh + rh / 2)); // the line "CQ DL1ABC JO62"
    assert_eq!(demo.decodes[4].message, "CQ DL1ABC JO62");
    click(&ui, ft8::CQ_AT);
    click(&ui, ft8::HALT_AT);
    click(&ui, ft8::TX_SLOT_AT);
    click(&ui, ft8::band_button_at(3));
    let (sx, sy, sw, sh) = ft8::SCALE_RECT;
    click(&ui, (sx + sw / 3, sy + sh / 2)); // a third of 3,000 Hz
    let got = events.borrow().clone();
    assert_eq!(got[..5], [Ft8Event::DecodeClick(4), Ft8Event::Cq, Ft8Event::Halt, Ft8Event::TxParityToggle, Ft8Event::BandSelect(3)]);
    match got[5] {
        Ft8Event::TxFreq(hz) => assert!((995..=1_005).contains(&hz), "TX frequency from the scale: {hz}"),
        other => panic!("expected a TX frequency, got {other:?}"),
    }
    assert_eq!(got.len(), 6);

    // A click inside the waterfall or on empty list space asks for nothing.
    events.borrow_mut().clear();
    click(&ui, (x0 + 500, y0 + 300));
    click(&ui, (rx + 400, ry + 20 * rh));
    assert!(events.borrow().is_empty());
    ui.hide().unwrap();
}
