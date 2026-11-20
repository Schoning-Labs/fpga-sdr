// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! A USB mouse works the firmware's window (docs/USB_HOST.md section 6): relative moves bring the
//! pointer over a button, a press and release click it, on the FT8 view and on the FreeDV view; the
//! pointer is drawn and stays on the screen. Events are the ones `tr_usbh::hid` makes from reports.

use std::time::Instant;

use slint::platform::software_renderer::Rgb565Pixel;
use slint::ComponentHandle;
use tr_gui::app_1920x1080::{connect_events, connect_fdv_events, set_freedv, set_pointer, AppScreen1920x1080};
use tr_gui::fdv::{self, FdvEvent};
use tr_gui::ft8::{self, Ft8Event};
use tr_gui::input::{dispatch, key_text, Pointer};
use tr_gui::platform::{new_window, render_rgb565, FramebufferPlatform};
use tr_usbh::hid::{InputEvent, Layout, Mouse, MouseLayout, MOD_LSHIFT, MOD_RALT};

const W: usize = 1920;
const H: usize = 1080;

/// Sends the mouse reports that move the pointer to `to`, in steps a real mouse makes (at most 127 a report).
fn move_to(ui: &AppScreen1920x1080, mouse: &mut Mouse, p: &mut Pointer, to: (u32, u32)) {
    while (p.x, p.y) != (to.0 as i32, to.1 as i32) {
        let dx = (to.0 as i32 - p.x).clamp(-127, 127) as i8;
        let dy = (to.1 as i32 - p.y).clamp(-127, 127) as i8;
        mouse.report(&[0, dx as u8, dy as u8], &mut |e| {
            if dispatch(ui.window(), p, e, Layout::Us) {
                set_pointer(ui, p);
            }
        });
    }
}

/// A left button press and release at the current pointer position.
fn click(ui: &AppScreen1920x1080, mouse: &mut Mouse, p: &mut Pointer) {
    for buttons in [1u8, 0] {
        mouse.report(&[buttons, 0, 0], &mut |e| {
            dispatch(ui.window(), p, e, Layout::Us);
        });
    }
}

#[test]
fn a_mouse_clicks_both_views_and_the_pointer_is_drawn() {
    let start = Instant::now();
    FramebufferPlatform::install(move || start.elapsed()).expect("one Slint platform per process");
    let window = new_window(W as u32, H as u32);
    let ui = AppScreen1920x1080::new().unwrap();
    let events = connect_events(&ui);
    let fdv_events = connect_fdv_events(&ui);
    ui.show().unwrap();
    let mut buffer = vec![Rgb565Pixel(0); W * H];
    slint::platform::update_timers_and_animations();
    assert!(render_rgb565(&window, &mut buffer, W));
    let before: Vec<u16> = buffer.iter().map(|p| p.0).collect();

    let mut mouse = Mouse::new(MouseLayout::BOOT);
    let mut p = Pointer::new(W as u32, H as u32);
    assert!(!p.shown);

    // FT8 view: the TX enable switch and the CQ button
    move_to(&ui, &mut mouse, &mut p, ft8::TX_ENABLE_AT);
    assert!(p.shown);
    click(&ui, &mut mouse, &mut p);
    move_to(&ui, &mut mouse, &mut p, ft8::CQ_AT);
    click(&ui, &mut mouse, &mut p);
    assert_eq!(*events.borrow(), [Ft8Event::TxEnableToggle, Ft8Event::Cq]);

    // the pointer is drawn with its tip at the position, white inside a black edge, and nothing else changed
    slint::platform::update_timers_and_animations();
    assert!(render_rgb565(&window, &mut buffer, W));
    let (px, py) = (p.x as usize, p.y as usize);
    assert_eq!(buffer[(py + 9) * W + px + 3].0, 0xFFFF, "white inside the arrow");
    assert_eq!(buffer[(py + 9) * W + px].0, 0x0000, "black edge");
    let changed = (0..W * H).filter(|i| buffer[*i].0 != before[*i]).map(|i| (i % W, i / W)).collect::<Vec<_>>();
    assert!(!changed.is_empty());
    assert!(changed.iter().all(|(x, y)| (px..px + 24).contains(x) && (py..py + 28).contains(y)), "only the pointer was drawn");

    // FreeDV view
    set_freedv(&ui, true);
    move_to(&ui, &mut mouse, &mut p, fdv::SQUELCH_AT);
    click(&ui, &mut mouse, &mut p);
    move_to(&ui, &mut mouse, &mut p, fdv::MODE_E_AT);
    click(&ui, &mut mouse, &mut p);
    assert_eq!(fdv_events.borrow().len(), 2);
    assert!(matches!(fdv_events.borrow()[0], FdvEvent::SquelchToggle));

    // the pointer cannot leave the screen
    for _ in 0..40 {
        dispatch(ui.window(), &mut p, InputEvent::PointerMove { dx: 127, dy: 127 }, Layout::Us);
    }
    assert_eq!((p.x, p.y), (W as i32 - 1, H as i32 - 1));
    for _ in 0..40 {
        dispatch(ui.window(), &mut p, InputEvent::PointerMove { dx: -127, dy: -127 }, Layout::Us);
    }
    assert_eq!((p.x, p.y), (0, 0));
    // wheel and keys are accepted
    dispatch(ui.window(), &mut p, InputEvent::Wheel { delta: -1 }, Layout::Us);
    dispatch(ui.window(), &mut p, InputEvent::Key { usage: 0x04, down: true, mods: 0 }, Layout::De);
    dispatch(ui.window(), &mut p, InputEvent::Key { usage: 0x04, down: false, mods: 0 }, Layout::De);
}

#[test]
fn key_texts() {
    assert_eq!(key_text(Layout::Us, 0x04, MOD_LSHIFT).unwrap().as_str(), "A");
    assert_eq!(key_text(Layout::De, 0x2F, 0).unwrap().as_str(), "ü");
    assert_eq!(key_text(Layout::De, 0x14, MOD_RALT).unwrap().as_str(), "@");
    let enter: slint::SharedString = slint::platform::Key::Return.into();
    assert_eq!(key_text(Layout::Us, 0x28, 0), Some(enter));
    let left: slint::SharedString = slint::platform::Key::LeftArrow.into();
    assert_eq!(key_text(Layout::Us, 0x50, 0), Some(left));
    assert_eq!(key_text(Layout::Us, 0x3A, 0), None); // F1: no use for it yet
}
