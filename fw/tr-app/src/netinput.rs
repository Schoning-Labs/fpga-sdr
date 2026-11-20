// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The PC's mouse and keyboard on the radio's screen (docs/NETINPUT.md): glue between the RJ45 unit's service socket
//! ([`Rj45Net::service_recv`]), the parser and applier of `tr_input`, and the screen. The logic is in `tr-input`,
//! where it has host tests, so this file only connects the pieces.

use alloc::collections::VecDeque;

use tr_input::{Datagrams, Sink};
use tr_regs::RegisterSpace;
use tr_usbh::hid::{InputEvent, Layout};

use crate::rj45net::Rj45Net;
use crate::screen::Screen;

/// Keys waiting for the console key handler (the USB keyboard's queue is the same one).
pub const KEY_QUEUE_LIMIT: usize = 32;

/// `tr_input`'s datagram source and sink on the RJ45 unit.
pub struct RjSocket<'r, 'a, R: RegisterSpace>(pub &'r mut Rj45Net<'a, R>);

impl<R: RegisterSpace> Datagrams for RjSocket<'_, '_, R> {
    fn recv(&mut self, buf: &mut [u8]) -> Option<(usize, ([u8; 4], u16))> {
        self.0.service_recv(buf).map(|(n, ip, port)| (n, (ip, port)))
    }

    fn send(&mut self, to: ([u8; 4], u16), data: &[u8]) -> bool {
        self.0.service_send(to.0, to.1, data)
    }
}

/// Events into the screen exactly as the USB host's mouse and keyboard do it ([`Screen::input`]); a key with an
/// ASCII character is also a console key.
pub struct ScreenSink<'s> {
    screen: &'s Screen,
    keys: &'s mut VecDeque<u8>,
    layout: Layout,
}

impl<'s> ScreenSink<'s> {
    /// A sink that feeds `screen` and queues console keys in `keys`; `layout` is the keyboard layout setting.
    pub fn new(screen: &'s Screen, keys: &'s mut VecDeque<u8>, layout: Layout) -> Self {
        ScreenSink { screen, keys, layout }
    }
}

impl Sink for ScreenSink<'_> {
    fn pointer(&self) -> (i32, i32) {
        let p = self.screen.pointer();
        (p.x, p.y)
    }

    fn input(&mut self, e: InputEvent) {
        self.screen.input(e, self.layout);
    }

    fn console_key(&mut self, c: u8) {
        if self.keys.len() < KEY_QUEUE_LIMIT {
            self.keys.push_back(c);
        }
    }
}
