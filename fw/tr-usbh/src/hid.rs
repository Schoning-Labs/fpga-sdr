// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Keyboard and mouse (docs/USB_HOST.md section 6).
//!
//! Keyboard: the 8-byte boot report (HID 1.11 appendix B.1): modifiers, a reserved byte, six key
//! codes. [`Keyboard::report`] compares a report with the one before and gives key-down and
//! key-up events; [`key_char`] turns a key code into a character for a layout.
//!
//! Mouse: [`MouseLayout::parse`] reads a report descriptor (HID 1.11 section 6.2.2) for where the
//! buttons, X, Y and the wheel are; [`MouseLayout::BOOT`] is the 3-byte boot report (appendix B.2).

/// Modifier bits of the boot keyboard report.
pub const MOD_LCTRL: u8 = 0x01;
pub const MOD_LSHIFT: u8 = 0x02;
pub const MOD_LALT: u8 = 0x04;
pub const MOD_LGUI: u8 = 0x08;
pub const MOD_RCTRL: u8 = 0x10;
pub const MOD_RSHIFT: u8 = 0x20;
/// Right Alt: AltGr on a German keyboard.
pub const MOD_RALT: u8 = 0x40;
pub const MOD_RGUI: u8 = 0x80;
pub const MOD_SHIFT: u8 = MOD_LSHIFT | MOD_RSHIFT;
pub const MOD_CTRL: u8 = MOD_LCTRL | MOD_RCTRL;

/// Key codes (HID usage tables, keyboard page) of keys without a character.
pub mod key {
    pub const ENTER: u8 = 0x28;
    pub const ESCAPE: u8 = 0x29;
    pub const BACKSPACE: u8 = 0x2A;
    pub const TAB: u8 = 0x2B;
    pub const F1: u8 = 0x3A;
    pub const F12: u8 = 0x45;
    pub const INSERT: u8 = 0x49;
    pub const HOME: u8 = 0x4A;
    pub const PAGE_UP: u8 = 0x4B;
    pub const DELETE: u8 = 0x4C;
    pub const END: u8 = 0x4D;
    pub const PAGE_DOWN: u8 = 0x4E;
    pub const RIGHT: u8 = 0x4F;
    pub const LEFT: u8 = 0x50;
    pub const DOWN: u8 = 0x51;
    pub const UP: u8 = 0x52;
    pub const KP_ENTER: u8 = 0x58;
}

/// An event that the keyboard and mouse drivers hand to the rest of the firmware.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InputEvent {
    /// Relative pointer movement, in the mouse's counts.
    PointerMove { dx: i16, dy: i16 },
    /// Button 0 left, 1 right, 2 middle.
    Button { button: u8, down: bool },
    /// Wheel clicks; positive = away from the user.
    Wheel { delta: i8 },
    /// A key went down or up. `usage` is the key code, `mods` the modifier bits at that moment.
    Key { usage: u8, down: bool, mods: u8 },
}

/// Keyboard layout that turns key codes into characters.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Layout {
    #[default]
    Us,
    De,
}

// Key codes 0x04 .. 0x38, plain and shifted. 0 = no character.
const US_PLAIN: &[u8; 53] = b"abcdefghijklmnopqrstuvwxyz1234567890\n\x1b\x08\t -=[]\\\0;'`,./";
const US_SHIFT: &[u8; 53] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ!@#$%^&*()\n\x1b\x08\t _+{}|\0:\"~<>?";
// German: y and z change places; the rest as printed on a German keyboard. Dead keys (^ and the
// accents) give their own character.
const DE_PLAIN: [char; 53] = [
    'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x',
    'z', 'y', '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '\n', '\x1b', '\x08', '\t', ' ', 'ß', '´', 'ü', '+',
    '#', '#', 'ö', 'ä', '^', ',', '.', '-',
];
const DE_SHIFT: [char; 53] = [
    'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X',
    'Z', 'Y', '!', '"', '§', '$', '%', '&', '/', '(', ')', '=', '\n', '\x1b', '\x08', '\t', ' ', '?', '`', 'Ü', '*',
    '\'', '\'', 'Ö', 'Ä', '°', ';', ':', '_',
];

/// The character a key gives, or `None` (function keys, arrows, modifiers, an unknown key).
/// Enter is '\n', Escape 0x1B, Backspace 0x08, Tab '\t'. Ctrl and a letter gives the control
/// character (Ctrl+C = 0x03).
pub fn key_char(layout: Layout, usage: u8, mods: u8) -> Option<char> {
    let shift = mods & MOD_SHIFT != 0;
    let c = match usage {
        0x04..=0x38 => {
            let i = (usage - 0x04) as usize;
            match layout {
                Layout::Us => (if shift { US_SHIFT[i] } else { US_PLAIN[i] }) as char,
                Layout::De => {
                    if mods & MOD_RALT != 0 {
                        match usage {
                            0x14 => '@',
                            0x08 => '€',
                            0x10 => 'µ',
                            0x1F => '²',
                            0x20 => '³',
                            0x24 => '{',
                            0x25 => '[',
                            0x26 => ']',
                            0x27 => '}',
                            0x2D => '\\',
                            0x30 => '~',
                            _ => '\0',
                        }
                    } else if shift {
                        DE_SHIFT[i]
                    } else {
                        DE_PLAIN[i]
                    }
                }
            }
        }
        // the key next to the left shift on a 102-key board
        0x64 => match (layout, shift, mods & MOD_RALT != 0) {
            (Layout::De, _, true) => '|',
            (Layout::De, false, _) => '<',
            (Layout::De, true, _) => '>',
            (Layout::Us, false, _) => '\\',
            (Layout::Us, true, _) => '|',
        },
        // the number pad, as with NumLock on
        0x54 => '/',
        0x55 => '*',
        0x56 => '-',
        0x57 => '+',
        0x58 => '\n',
        0x59..=0x61 => (b'1' + (usage - 0x59)) as char,
        0x62 => '0',
        0x63 => match layout {
            Layout::Us => '.',
            Layout::De => ',',
        },
        _ => '\0',
    };
    if c == '\0' {
        return None;
    }
    if mods & MOD_CTRL != 0 && mods & MOD_RALT == 0 && c.is_ascii_alphabetic() {
        return Some(((c as u8) & 0x1F) as char);
    }
    Some(c)
}

/// Boot keyboard: remembers the last report.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Keyboard {
    last: [u8; 8],
}

impl Keyboard {
    /// A keyboard with no key down.
    pub const fn new() -> Self {
        Keyboard { last: [0; 8] }
    }

    /// One report. Calls `sink` for every key that went up, then for every key that went down.
    /// A report full of 0x01 (too many keys held) is ignored. Modifier keys give events with the
    /// key codes 0xE0 to 0xE7.
    pub fn report(&mut self, r: &[u8], sink: &mut impl FnMut(InputEvent)) {
        if r.len() < 3 {
            return;
        }
        let mut now = [0u8; 8];
        let n = r.len().min(8);
        now[..n].copy_from_slice(&r[..n]);
        if now[2..].iter().any(|k| *k == 1) {
            return;
        }
        let mods = now[0];
        for bit in 0..8 {
            let m = 1u8 << bit;
            if self.last[0] & m != 0 && mods & m == 0 {
                sink(InputEvent::Key { usage: 0xE0 + bit, down: false, mods });
            }
        }
        for k in self.last[2..].iter().filter(|k| **k > 3) {
            if !now[2..].contains(k) {
                sink(InputEvent::Key { usage: *k, down: false, mods });
            }
        }
        for bit in 0..8 {
            let m = 1u8 << bit;
            if self.last[0] & m == 0 && mods & m != 0 {
                sink(InputEvent::Key { usage: 0xE0 + bit, down: true, mods });
            }
        }
        for k in now[2..].iter().filter(|k| **k > 3) {
            if !self.last[2..].contains(k) {
                sink(InputEvent::Key { usage: *k, down: true, mods });
            }
        }
        self.last = now;
    }

    /// The device is gone: every key that was down goes up.
    pub fn release_all(&mut self, sink: &mut impl FnMut(InputEvent)) {
        self.report(&[0; 8], sink);
    }
}

/// A field of a report: bit position after the report ID byte, and width (0 = not there).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Field {
    /// Bit position, counted from the first bit after the report ID byte.
    pub bit: u16,
    /// Width in bits, 0 if the report has no such field.
    pub size: u8,
}

/// Where the buttons, the movement and the wheel are in the reports of one mouse.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct MouseLayout {
    /// The reports of this layout start with this ID byte.
    pub report_id: Option<u8>,
    /// One bit per button, the first is the left one.
    pub buttons: Field,
    /// Relative movement in x.
    pub x: Field,
    /// Relative movement in y.
    pub y: Field,
    /// Wheel movement.
    pub wheel: Field,
}

impl MouseLayout {
    /// The boot protocol's report: buttons, X, Y.
    pub const BOOT: MouseLayout = MouseLayout {
        report_id: None,
        buttons: Field { bit: 0, size: 3 },
        x: Field { bit: 8, size: 8 },
        y: Field { bit: 16, size: 8 },
        wheel: Field { bit: 0, size: 0 },
    };

    /// Reads a report descriptor. `None`: no relative X and Y found (not a mouse, or a tablet).
    /// With several reports (a keyboard with a mouse part) the first one that has X and Y is used.
    pub fn parse(d: &[u8]) -> Option<MouseLayout> {
        let (mut page, mut size, mut count) = (0u32, 0u32, 0u32);
        let mut usages = [0u32; 8];
        let mut n_usages = 0usize;
        let mut usage_min = 0u32;
        let mut bit = 0u32;
        let mut cur = MouseLayout::default();
        let mut done: Option<MouseLayout> = None;
        let mut i = 0;
        while i < d.len() {
            let p = d[i];
            if p == 0xFE {
                // long item: skipped
                if i + 1 >= d.len() {
                    break;
                }
                i += 3 + d[i + 1] as usize;
                continue;
            }
            let n = match p & 3 {
                3 => 4,
                k => k as usize,
            };
            if i + 1 + n > d.len() {
                break;
            }
            let mut v = 0u32;
            for k in 0..n {
                v |= (d[i + 1 + k] as u32) << (8 * k);
            }
            match p & 0xFC {
                0x04 => page = v,
                0x74 => size = v,
                0x94 => count = v,
                0x84 => {
                    // a new report: the one before is complete
                    if cur.x.size != 0 && cur.y.size != 0 && done.is_none() {
                        done = Some(cur);
                    }
                    bit = 0;
                    cur = MouseLayout { report_id: Some(v as u8), ..MouseLayout::default() };
                }
                0x08 => {
                    if n_usages < usages.len() {
                        usages[n_usages] = if n == 4 { v } else { (page << 16) | v };
                        n_usages += 1;
                    }
                }
                0x18 => usage_min = if n == 4 { v } else { (page << 16) | v },
                0x80 => {
                    // Input. Bit 0: constant; bit 1: variable; bit 2: relative.
                    let constant = v & 1 != 0;
                    if !constant && v & 2 != 0 {
                        if page == 9 && cur.buttons.size == 0 && size == 1 {
                            // buttons 1.. : only if the range starts at button 1
                            if usage_min == (9 << 16) | 1 || (n_usages > 0 && usages[0] == (9 << 16) | 1) {
                                cur.buttons = Field { bit: bit as u16, size: count.min(8) as u8 };
                            }
                        }
                        for k in 0..count {
                            let u = if n_usages == 0 { 0 } else { usages[(k as usize).min(n_usages - 1)] };
                            let f = Field { bit: (bit + k * size) as u16, size: size.min(16) as u8 };
                            let relative = v & 4 != 0;
                            match u {
                                0x0001_0030 if relative && cur.x.size == 0 => cur.x = f,
                                0x0001_0031 if relative && cur.y.size == 0 => cur.y = f,
                                0x0001_0038 if relative && cur.wheel.size == 0 => cur.wheel = f,
                                _ => {}
                            }
                        }
                    }
                    bit += size * count;
                    n_usages = 0;
                    usage_min = 0;
                }
                // Output, Feature, Collection, End Collection: local items end here
                0x90 | 0xB0 | 0xA0 | 0xC0 => {
                    n_usages = 0;
                    usage_min = 0;
                }
                _ => {}
            }
            i += 1 + n;
        }
        if done.is_none() && cur.x.size != 0 && cur.y.size != 0 {
            done = Some(cur);
        }
        done
    }

    fn get(r: &[u8], f: Field) -> i16 {
        if f.size == 0 {
            return 0;
        }
        let mut v = 0u32;
        for k in 0..f.size as usize {
            let b = f.bit as usize + k;
            if b / 8 < r.len() && r[b / 8] >> (b % 8) & 1 != 0 {
                v |= 1 << k;
            }
        }
        // sign-extend
        let sh = 32 - f.size as u32;
        (((v << sh) as i32) >> sh) as i16
    }

    /// The length in bytes a report must have, without the ID byte.
    pub fn bytes(&self) -> usize {
        let end = |f: Field| if f.size == 0 { 0 } else { (f.bit as usize + f.size as usize + 7) / 8 };
        end(self.buttons).max(end(self.x)).max(end(self.y)).max(end(self.wheel))
    }
}

/// A mouse: remembers the buttons.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Mouse {
    /// Where the fields are in this mouse's reports.
    pub layout: MouseLayout,
    buttons: u8,
}

impl Mouse {
    /// A mouse with no button down.
    pub const fn new(layout: MouseLayout) -> Self {
        Mouse { layout, buttons: 0 }
    }

    /// Decodes one report and passes the events it holds (movement, wheel, button changes) to `sink`.
    pub fn report(&mut self, r: &[u8], sink: &mut impl FnMut(InputEvent)) {
        let l = self.layout;
        let r = match l.report_id {
            Some(id) => {
                if r.first() != Some(&id) {
                    return;
                }
                &r[1..]
            }
            None => r,
        };
        if r.len() < l.bytes().min(3) {
            return;
        }
        let mut b = 0u8;
        for k in 0..l.buttons.size.min(3) {
            let bit = l.buttons.bit as usize + k as usize;
            if bit / 8 < r.len() && r[bit / 8] >> (bit % 8) & 1 != 0 {
                b |= 1 << k;
            }
        }
        let (dx, dy) = (MouseLayout::get(r, l.x), MouseLayout::get(r, l.y));
        if dx != 0 || dy != 0 {
            sink(InputEvent::PointerMove { dx, dy });
        }
        for k in 0..3 {
            if (b ^ self.buttons) >> k & 1 != 0 {
                sink(InputEvent::Button { button: k, down: b >> k & 1 != 0 });
            }
        }
        self.buttons = b;
        let w = MouseLayout::get(r, l.wheel);
        if w != 0 {
            sink(InputEvent::Wheel { delta: w.clamp(-127, 127) as i8 });
        }
    }

    /// The device is gone: every button that was down goes up.
    pub fn release_all(&mut self, sink: &mut impl FnMut(InputEvent)) {
        for k in 0..3 {
            if self.buttons >> k & 1 != 0 {
                sink(InputEvent::Button { button: k, down: false });
            }
        }
        self.buttons = 0;
    }
}

#[cfg(test)]
mod tests {
    extern crate std;
    use super::*;
    use std::vec::Vec;

    /// Pixart optical mouse 093A:2510, the report descriptor printed in the Linux kernel's
    /// Documentation/hid/hidintro.rst (hexdump of /sys/bus/hid/devices/0003:093A:2510.0002).
    pub const PIXART_MOUSE: [u8; 52] = [
        0x05, 0x01, 0x09, 0x02, 0xa1, 0x01, 0x09, 0x01, 0xa1, 0x00, 0x05, 0x09, 0x19, 0x01, 0x29, 0x03, 0x15, 0x00,
        0x25, 0x01, 0x75, 0x01, 0x95, 0x03, 0x81, 0x02, 0x75, 0x05, 0x95, 0x01, 0x81, 0x01, 0x05, 0x01, 0x09, 0x30,
        0x09, 0x31, 0x09, 0x38, 0x15, 0x81, 0x25, 0x7f, 0x75, 0x08, 0x95, 0x03, 0x81, 0x06, 0xc0, 0xc0,
    ];

    fn events(f: impl FnOnce(&mut dyn FnMut(InputEvent))) -> Vec<InputEvent> {
        let mut v = Vec::new();
        f(&mut |e| v.push(e));
        v
    }

    #[test]
    fn pixart_mouse_layout() {
        let l = MouseLayout::parse(&PIXART_MOUSE).unwrap();
        assert_eq!(l.report_id, None);
        assert_eq!(l.buttons, Field { bit: 0, size: 3 });
        assert_eq!(l.x, Field { bit: 8, size: 8 });
        assert_eq!(l.y, Field { bit: 16, size: 8 });
        assert_eq!(l.wheel, Field { bit: 24, size: 8 });
        assert_eq!(l.bytes(), 4);
    }

    #[test]
    fn mouse_reports() {
        let mut m = Mouse::new(MouseLayout::parse(&PIXART_MOUSE).unwrap());
        let e = events(|s| m.report(&[0x01, 5, 0xFE, 0], &mut |e| s(e)));
        assert_eq!(e, [InputEvent::PointerMove { dx: 5, dy: -2 }, InputEvent::Button { button: 0, down: true }]);
        let e = events(|s| m.report(&[0x03, 0, 0, 0xFF], &mut |e| s(e)));
        assert_eq!(e, [InputEvent::Button { button: 1, down: true }, InputEvent::Wheel { delta: -1 }]);
        let e = events(|s| m.release_all(&mut |e| s(e)));
        assert_eq!(e.len(), 2);
    }

    #[test]
    fn mouse_with_report_id_and_12_bit_axes() {
        // constructed: report 1 keyboard-like (skipped), report 2 a mouse with 5 buttons, 12-bit X and Y, wheel
        let d = [
            0x05, 0x01, 0x09, 0x06, 0xa1, 0x01, 0x85, 0x01, 0x05, 0x07, 0x19, 0xe0, 0x29, 0xe7, 0x15, 0x00, 0x25, 0x01,
            0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0xc0, // keyboard part
            0x05, 0x01, 0x09, 0x02, 0xa1, 0x01, 0x85, 0x02, 0x09, 0x01, 0xa1, 0x00, 0x05, 0x09, 0x19, 0x01, 0x29, 0x05,
            0x15, 0x00, 0x25, 0x01, 0x95, 0x05, 0x75, 0x01, 0x81, 0x02, 0x95, 0x01, 0x75, 0x03, 0x81, 0x01, 0x05, 0x01,
            0x09, 0x30, 0x09, 0x31, 0x16, 0x01, 0xf8, 0x26, 0xff, 0x07, 0x75, 0x0c, 0x95, 0x02, 0x81, 0x06, 0x09, 0x38,
            0x15, 0x81, 0x25, 0x7f, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06, 0xc0, 0xc0,
        ];
        let l = MouseLayout::parse(&d).unwrap();
        assert_eq!(l.report_id, Some(2));
        assert_eq!(l.buttons, Field { bit: 0, size: 5 });
        assert_eq!(l.x, Field { bit: 8, size: 12 });
        assert_eq!(l.y, Field { bit: 20, size: 12 });
        assert_eq!(l.wheel, Field { bit: 32, size: 8 });
        let mut m = Mouse::new(l);
        // x = -3 (0xFFD), y = 0x123
        let e = events(|s| m.report(&[2, 0x04, 0xFD, 0x3F, 0x12, 0x01], &mut |e| s(e)));
        assert_eq!(
            e,
            [
                InputEvent::PointerMove { dx: -3, dy: 0x123 },
                InputEvent::Button { button: 2, down: true },
                InputEvent::Wheel { delta: 1 }
            ]
        );
        // a report with another ID is not the mouse's
        assert!(events(|s| m.report(&[1, 0xFF, 0, 0, 0, 0], &mut |e| s(e))).is_empty());
    }

    #[test]
    fn a_keyboard_descriptor_is_not_a_mouse() {
        let d = [0x05, 0x01, 0x09, 0x06, 0xa1, 0x01, 0x05, 0x07, 0x19, 0xe0, 0x29, 0xe7, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0xc0];
        assert_eq!(MouseLayout::parse(&d), None);
        assert_eq!(MouseLayout::parse(&[0x05]), None);
        assert_eq!(MouseLayout::parse(&[]), None);
    }

    #[test]
    fn keyboard_reports() {
        let mut k = Keyboard::new();
        let e = events(|s| k.report(&[MOD_LSHIFT, 0, 0x04, 0, 0, 0, 0, 0], &mut |e| s(e)));
        assert_eq!(
            e,
            [
                InputEvent::Key { usage: 0xE1, down: true, mods: MOD_LSHIFT },
                InputEvent::Key { usage: 0x04, down: true, mods: MOD_LSHIFT }
            ]
        );
        // a second key, the first still held
        let e = events(|s| k.report(&[MOD_LSHIFT, 0, 0x04, 0x05, 0, 0, 0, 0], &mut |e| s(e)));
        assert_eq!(e, [InputEvent::Key { usage: 0x05, down: true, mods: MOD_LSHIFT }]);
        // roll-over error: ignored
        assert!(events(|s| k.report(&[0, 0, 1, 1, 1, 1, 1, 1], &mut |e| s(e))).is_empty());
        let e = events(|s| k.report(&[0; 8], &mut |e| s(e)));
        assert_eq!(e.len(), 3);
        assert!(e.iter().all(|e| matches!(e, InputEvent::Key { down: false, .. })));
    }

    #[test]
    fn layouts() {
        assert_eq!(key_char(Layout::Us, 0x04, 0), Some('a'));
        assert_eq!(key_char(Layout::Us, 0x04, MOD_RSHIFT), Some('A'));
        assert_eq!(key_char(Layout::Us, 0x1F, MOD_LSHIFT), Some('@'));
        assert_eq!(key_char(Layout::Us, 0x38, 0), Some('/'));
        assert_eq!(key_char(Layout::Us, 0x1C, 0), Some('y'));
        assert_eq!(key_char(Layout::De, 0x1C, 0), Some('z'));
        assert_eq!(key_char(Layout::De, 0x1D, MOD_LSHIFT), Some('Y'));
        assert_eq!(key_char(Layout::De, 0x14, MOD_RALT), Some('@'));
        assert_eq!(key_char(Layout::De, 0x2D, 0), Some('ß'));
        assert_eq!(key_char(Layout::De, 0x2D, MOD_RALT), Some('\\'));
        assert_eq!(key_char(Layout::De, 0x24, MOD_LSHIFT), Some('/'));
        assert_eq!(key_char(Layout::De, 0x33, 0), Some('ö'));
        assert_eq!(key_char(Layout::De, 0x38, 0), Some('-'));
        assert_eq!(key_char(Layout::De, 0x64, MOD_RALT), Some('|'));
        assert_eq!(key_char(Layout::Us, 0x06, MOD_LCTRL), Some('\x03'));
        assert_eq!(key_char(Layout::Us, key::ENTER, 0), Some('\n'));
        assert_eq!(key_char(Layout::Us, key::F1, 0), None);
        assert_eq!(key_char(Layout::Us, key::LEFT, 0), None);
        assert_eq!(key_char(Layout::De, 0x59, 0), Some('1'));
    }
}
