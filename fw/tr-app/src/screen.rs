// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The screen on a frame buffer: Slint's software renderer drawing into RGB565 memory that is
//! shown in turn with a second buffer (`tr_fabric::video::FrameBuffers`). One window holds the FT8
//! view, the FreeDV view (docs/FREEDV.md section 9) and the LISTEN view (docs/LISTEN.md);
//! [`Screen::set_freedv`] and [`Screen::set_listen`] switch between them.

use alloc::rc::Rc;
use alloc::vec::Vec;
use core::cell::{Cell, RefCell};
use core::time::Duration;

use slint::platform::software_renderer::{MinimalSoftwareWindow, Rgb565Pixel};
use slint::platform::{PointerEventButton, WindowEvent};
use slint::{ComponentHandle, LogicalPosition};
use tr_gui::app_1920x1080::{apply_fdv_state_diff, apply_listen_state_diff, apply_state_diff, connect_events, connect_fdv_events, connect_listen_events, set_freedv, set_listen, set_pointer, AppScreen1920x1080, EventQueue, FdvEventQueue, ListenEventQueue};
use tr_gui::fdv::{FdvEvent, FdvScreenState};
use tr_gui::ft8::{Ft8Event, Ft8ScreenState};
use tr_gui::input::Pointer;
use tr_gui::listen::{ListenEvent, ListenScreenState};
use tr_gui::platform::{new_window_swapped, render_rgb565_lines, render_rgb565_lines_with, FramebufferPlatform};
use tr_usbh::hid::{InputEvent, Layout};

/// Screen width in pixels.
pub const WIDTH: usize = 1_920;
/// Screen height in pixels.
pub const HEIGHT: usize = 1_080;

/// The Slint window, its three views and the queues of what the operator did.
pub struct Screen {
    window: Rc<MinimalSoftwareWindow>,
    ui: AppScreen1920x1080,
    events: EventQueue,
    fdv_events: FdvEventQueue,
    listen_events: ListenEventQueue,
    /// What the screen shows, so that only what differs is pushed (and redrawn).
    shown: RefCell<Option<Ft8ScreenState>>,
    shown_fdv: RefCell<Option<FdvScreenState>>,
    shown_listen: RefCell<Option<ListenScreenState>>,
    /// Which view is up: FreeDV, or LISTEN over the others.
    freedv: Cell<bool>,
    listen: Cell<bool>,
    pointer: RefCell<Pointer>,
}

impl Screen {
    /// Makes the screen. `now` is the time since start-up (for Slint's timers). Once per program.
    pub fn new(now: impl Fn() -> Duration + 'static) -> Self {
        FramebufferPlatform::install(now).expect("one Slint platform per program");
        let window = new_window_swapped(WIDTH as u32, HEIGHT as u32);
        let ui = AppScreen1920x1080::new().expect("the screen");
        let events = connect_events(&ui);
        let fdv_events = connect_fdv_events(&ui);
        let listen_events = connect_listen_events(&ui);
        ui.show().expect("show");
        Screen {
            window,
            ui,
            events,
            fdv_events,
            listen_events,
            shown: RefCell::new(None),
            shown_fdv: RefCell::new(None),
            shown_listen: RefCell::new(None),
            freedv: Cell::new(false),
            listen: Cell::new(false),
            pointer: RefCell::new(Pointer::new(WIDTH as u32, HEIGHT as u32)),
        }
    }

    /// The FT8 view's state.
    pub fn apply(&self, state: &Ft8ScreenState) {
        let mut shown = self.shown.borrow_mut();
        apply_state_diff(&self.ui, shown.as_ref(), state);
        *shown = Some(state.clone());
    }

    /// The FreeDV view's state.
    pub fn apply_fdv(&self, state: &FdvScreenState) {
        let mut shown = self.shown_fdv.borrow_mut();
        apply_fdv_state_diff(&self.ui, shown.as_ref(), state);
        *shown = Some(state.clone());
    }

    /// Shows the FreeDV view (`true`) or the FT8 view.
    pub fn set_freedv(&self, on: bool) {
        if self.freedv.replace(on) != on {
            set_freedv(&self.ui, on);
        }
    }

    /// The FreeDV view is shown.
    pub fn freedv(&self) -> bool {
        self.freedv.get()
    }

    /// The LISTEN view's state.
    pub fn apply_listen(&self, state: &ListenScreenState) {
        let mut shown = self.shown_listen.borrow_mut();
        apply_listen_state_diff(&self.ui, shown.as_ref(), state);
        *shown = Some(state.clone());
    }

    /// Shows the LISTEN view (`true`) over the FT8 or FreeDV view.
    pub fn set_listen(&self, on: bool) {
        if self.listen.replace(on) != on {
            set_listen(&self.ui, on);
        }
    }

    /// The LISTEN view is shown.
    pub fn listen(&self) -> bool {
        self.listen.get()
    }

    /// What the operator did on the LISTEN view since the last call.
    pub fn take_listen_events(&self) -> Vec<ListenEvent> {
        core::mem::take(&mut *self.listen_events.borrow_mut())
    }

    /// Draws what changed into `buffer` (`WIDTH * HEIGHT` pixels) and returns the lines drawn as
    /// `(first, count)`, `None` if nothing changed.
    pub fn render(&self, buffer: &mut [Rgb565Pixel]) -> Option<(u32, u32)> {
        slint::platform::update_timers_and_animations();
        render_rgb565_lines(&self.window, buffer, WIDTH)
    }

    /// [`Screen::render`] line by line, calling `hook` every few lines (the LISTEN screen keeps its
    /// audio ring fed while a large part of the screen is drawn).
    pub fn render_with(&self, buffer: &mut [Rgb565Pixel], hook: impl FnMut()) -> Option<(u32, u32)> {
        slint::platform::update_timers_and_animations();
        render_rgb565_lines_with(&self.window, buffer, WIDTH, hook)
    }

    /// A pointer click at pixel `(x, y)` (a pointing device, or a test).
    pub fn click(&self, at: (u32, u32)) {
        let position = LogicalPosition::new(at.0 as f32, at.1 as f32);
        self.ui.window().dispatch_event(WindowEvent::PointerMoved { position });
        self.ui.window().dispatch_event(WindowEvent::PointerPressed { position, button: PointerEventButton::Left });
        self.ui.window().dispatch_event(WindowEvent::PointerReleased { position, button: PointerEventButton::Left });
    }

    /// One event of a USB mouse or keyboard (docs/USB_HOST.md section 6): moves the pointer and hands the
    /// event to the view, whose buttons and lists answer through `take_events` / `take_fdv_events`.
    pub fn input(&self, event: InputEvent, layout: Layout) {
        let mut p = self.pointer.borrow_mut();
        if tr_gui::input::dispatch(self.ui.window(), &mut p, event, layout) {
            set_pointer(&self.ui, &p);
        }
    }

    /// Where the pointer is, and whether it is shown.
    pub fn pointer(&self) -> Pointer {
        *self.pointer.borrow()
    }

    /// What the operator did on the FT8 view since the last call.
    pub fn take_events(&self) -> Vec<Ft8Event> {
        core::mem::take(&mut *self.events.borrow_mut())
    }

    /// What the operator did on the FreeDV view since the last call.
    pub fn take_fdv_events(&self) -> Vec<FdvEvent> {
        core::mem::take(&mut *self.fdv_events.borrow_mut())
    }
}
