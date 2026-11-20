// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Mouse and keyboard into Slint (docs/USB_HOST.md section 6): the events of the USB host stack
//! (`tr_usbh::hid::InputEvent`) become Slint window events, so every `TouchArea` and focus item of
//! the screens works with a real pointer and real keys.
//!
//! A mouse only says how far it moved; [`Pointer`] keeps the position and holds it on the screen.
//! The pointer is drawn by the screen itself (a small element on top, `AppModel.pointer-*`).

use slint::platform::{Key, PointerEventButton, WindowEvent};
use slint::{LogicalPosition, SharedString, Window};
use tr_usbh::hid::{self, InputEvent, Layout};

/// Position of the pointer, in pixels.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Pointer {
    /// Column of the pointer, 0 at the left edge.
    pub x: i32,
    /// Row of the pointer, 0 at the top edge.
    pub y: i32,
    width: i32,
    height: i32,
    /// Something has moved it: it is shown from then on.
    pub shown: bool,
}

impl Pointer {
    /// In the middle of a screen of `width` x `height` pixels, not shown yet.
    pub const fn new(width: u32, height: u32) -> Self {
        Pointer { x: width as i32 / 2, y: height as i32 / 2, width: width as i32, height: height as i32, shown: false }
    }

    fn position(&self) -> LogicalPosition {
        LogicalPosition::new(self.x as f32, self.y as f32)
    }
}

/// The text Slint wants for a key: its character, or Slint's code for a key without one.
pub fn key_text(layout: Layout, usage: u8, mods: u8) -> Option<SharedString> {
    let special = match usage {
        hid::key::ENTER | hid::key::KP_ENTER => Some(Key::Return),
        hid::key::ESCAPE => Some(Key::Escape),
        hid::key::BACKSPACE => Some(Key::Backspace),
        hid::key::TAB => Some(Key::Tab),
        hid::key::DELETE => Some(Key::Delete),
        hid::key::INSERT => Some(Key::Insert),
        hid::key::HOME => Some(Key::Home),
        hid::key::END => Some(Key::End),
        hid::key::PAGE_UP => Some(Key::PageUp),
        hid::key::PAGE_DOWN => Some(Key::PageDown),
        hid::key::LEFT => Some(Key::LeftArrow),
        hid::key::RIGHT => Some(Key::RightArrow),
        hid::key::UP => Some(Key::UpArrow),
        hid::key::DOWN => Some(Key::DownArrow),
        0xE0 | 0xE4 => Some(Key::Control),
        0xE1 => Some(Key::Shift),
        0xE5 => Some(Key::ShiftR),
        0xE2 => Some(Key::Alt),
        0xE6 => Some(Key::AltGr),
        _ => None,
    };
    if let Some(k) = special {
        return Some(k.into());
    }
    let c = hid::key_char(layout, usage, mods & !hid::MOD_CTRL)?;
    let mut buf = [0u8; 4];
    Some(SharedString::from(&*c.encode_utf8(&mut buf)))
}

/// Hands one event to the window. Returns true when the drawn pointer has to move (it moved, or
/// it appears for the first time).
pub fn dispatch(window: &Window, pointer: &mut Pointer, event: InputEvent, layout: Layout) -> bool {
    match event {
        InputEvent::PointerMove { dx, dy } => {
            let (x, y) = ((pointer.x + dx as i32).clamp(0, pointer.width - 1), (pointer.y + dy as i32).clamp(0, pointer.height - 1));
            let moved = (x, y) != (pointer.x, pointer.y) || !pointer.shown;
            pointer.x = x;
            pointer.y = y;
            pointer.shown = true;
            window.dispatch_event(WindowEvent::PointerMoved { position: pointer.position() });
            moved
        }
        InputEvent::Button { button, down } => {
            let button = match button {
                0 => PointerEventButton::Left,
                1 => PointerEventButton::Right,
                _ => PointerEventButton::Middle,
            };
            let position = pointer.position();
            // Slint wants to know where the pointer is before a press
            window.dispatch_event(WindowEvent::PointerMoved { position });
            window.dispatch_event(if down {
                WindowEvent::PointerPressed { position, button }
            } else {
                WindowEvent::PointerReleased { position, button }
            });
            false
        }
        InputEvent::Wheel { delta } => {
            // one click of the wheel = 40 pixels
            window.dispatch_event(WindowEvent::PointerScrolled { position: pointer.position(), delta_x: 0.0, delta_y: delta as f32 * 40.0 });
            false
        }
        InputEvent::Key { usage, down, mods } => {
            if let Some(text) = key_text(layout, usage, mods) {
                window.dispatch_event(if down { WindowEvent::KeyPressed { text } } else { WindowEvent::KeyReleased { text } });
            }
            false
        }
    }
}
