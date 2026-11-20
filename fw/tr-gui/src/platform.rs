// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
//! The `slint::platform::Platform` implementation this crate needs to run without an OS
//! (docs/ARCHITECTURE.md 5.6: Slint's software renderer, rendering into a framebuffer). It is the
//! same code path on the firmware target and in the host screenshot tests: both create a
//! `MinimalSoftwareWindow` with `new_window`, push a state into it (the `apply_state` functions
//! generated in src/lib.rs), and call one of the `render_rgb565*` functions to fill an
//! `Rgb565Pixel` buffer, which on the radio is a frame buffer of the video block.
//!
//! The clock source does not live here. `duration_since_start` is answered by a closure the
//! caller supplies, because on the AE350 (the RISC-V soft CPU) that means the machine timer and
//! on the host it means `std::time::Instant`, and this crate stays agnostic to which.
//! The `render_rgb565_lines*` variants report which lines were drawn, so the firmware only has
//! to flush those to the display.

extern crate alloc;

use alloc::boxed::Box;
use alloc::rc::Rc;
use core::cell::RefCell;
use core::time::Duration;

use slint::platform::software_renderer::{MinimalSoftwareWindow, RepaintBufferType, Rgb565Pixel};
use slint::platform::{Platform, SetPlatformError, WindowAdapter};
use slint::PlatformError;

/// A `RefCell` behind an unsafe `Sync` so it can sit in a `static` (docs/ARCHITECTURE.md 5.6, no
/// OS, no threads; this crate already requires Slint's own `unsafe-single-threaded` feature for
/// the same reason). Safety: every access is from the one thread this firmware ever runs on,
/// there is no interrupt handler and no second core touching the GUI (docs/ARCHITECTURE.md 5.3:
/// the GUI event loop runs at `embassy-executor` thread level, never from an interrupt handler).
struct SingleThreadCell<T>(RefCell<T>);
unsafe impl<T> Sync for SingleThreadCell<T> {}

/// The window `create_window_adapter` hands out to the next generated component that is
/// constructed. `new_window` sets it, and there is normally exactly one, created once at
/// start-up. A second call (done by the tests, to render several screens in one process) simply
/// replaces it before the next component is constructed.
static PENDING_WINDOW: SingleThreadCell<Option<Rc<MinimalSoftwareWindow>>> =
    SingleThreadCell(RefCell::new(None));

/// Minimal `Platform`: no event loop of its own (docs/ARCHITECTURE.md 5.6) and no input source,
/// the mouse and keyboard events come from the USB host stack through `crate::input`. The
/// caller drives rendering directly with `render_rgb565`.
pub struct FramebufferPlatform<F: Fn() -> Duration> {
    now: F,
}

impl<F: Fn() -> Duration + 'static> FramebufferPlatform<F> {
    /// Installs this as the process-wide Slint platform. Must be called at most once per
    /// process, before the first generated panel component is constructed.
    pub fn install(now: F) -> Result<(), SetPlatformError> {
        slint::platform::set_platform(Box::new(FramebufferPlatform { now }))
    }
}

impl<F: Fn() -> Duration> Platform for FramebufferPlatform<F> {
    fn create_window_adapter(&self) -> Result<Rc<dyn WindowAdapter>, PlatformError> {
        let window = PENDING_WINDOW
            .0
            .borrow_mut()
            .take()
            .unwrap_or_else(|| MinimalSoftwareWindow::new(RepaintBufferType::ReusedBuffer));
        Ok(window)
    }

    fn duration_since_start(&self) -> Duration {
        (self.now)()
    }
}

/// Creates a window of the given pixel size and arranges for the next generated component's
/// `::new()` call to pick it up. Returns the same `Rc` for rendering afterwards. Call this after
/// `FramebufferPlatform::install`, immediately before constructing the panel component.
pub fn new_window(width: u32, height: u32) -> Rc<MinimalSoftwareWindow> {
    let window = MinimalSoftwareWindow::new(RepaintBufferType::ReusedBuffer);
    window.set_size(slint::PhysicalSize::new(width, height));
    *PENDING_WINDOW.0.borrow_mut() = Some(window.clone());
    window
}

/// Renders the given window's current contents into `buffer` (row-major, `width` pixels wide,
/// `buffer.len() / width` rows tall), but only if it actually needs a redraw. Returns whether it
/// drew anything, so a caller can tell a skipped frame from a drawn one.
pub fn render_rgb565(window: &MinimalSoftwareWindow, buffer: &mut [Rgb565Pixel], width: usize) -> bool {
    let mut drew = false;
    window.draw_if_needed(|renderer| {
        renderer.render(buffer, width);
        drew = true;
    });
    drew
}

/// Like [`new_window`], for a display with two frame buffers shown in turn (the board's video
/// block, `tr_fabric::video::FrameBuffers`): each render then also redraws what changed in the
/// frame before, so both buffers stay complete.
pub fn new_window_swapped(width: u32, height: u32) -> Rc<MinimalSoftwareWindow> {
    let window = MinimalSoftwareWindow::new(RepaintBufferType::SwappedBuffers);
    window.set_size(slint::PhysicalSize::new(width, height));
    *PENDING_WINDOW.0.borrow_mut() = Some(window.clone());
    window
}

/// Like [`render_rgb565`], and says which lines were drawn: `Some((first_line, lines))`, or `None`
/// if nothing needed a redraw. The caller flushes exactly those lines before showing the buffer.
pub fn render_rgb565_lines(window: &MinimalSoftwareWindow, buffer: &mut [Rgb565Pixel], width: usize) -> Option<(u32, u32)> {
    let mut drawn = None;
    window.draw_if_needed(|renderer| {
        let region = renderer.render(buffer, width);
        let (origin, size) = (region.bounding_box_origin(), region.bounding_box_size());
        drawn = Some((origin.y.max(0) as u32, size.height));
    });
    drawn
}

/// The frame buffer as Slint's line provider, calling `hook` every [`HOOK_LINES`] lines drawn.
struct HookedLines<'b, F: FnMut()> {
    buffer: &'b mut [Rgb565Pixel],
    width: usize,
    hook: F,
    lines: usize,
}

/// Lines drawn between two calls of the hook of [`render_rgb565_lines_with`].
pub const HOOK_LINES: usize = 16;

impl<F: FnMut()> slint::platform::software_renderer::LineBufferProvider for HookedLines<'_, F> {
    type TargetPixel = Rgb565Pixel;

    fn process_line(&mut self, line: usize, range: core::ops::Range<usize>, render_fn: impl FnOnce(&mut [Rgb565Pixel])) {
        let start = line * self.width;
        render_fn(&mut self.buffer[start + range.start..start + range.end]);
        self.lines += 1;
        if self.lines % HOOK_LINES == 0 {
            (self.hook)();
        }
    }
}

/// [`render_rgb565_lines`] drawn line by line, calling `hook` every [`HOOK_LINES`] lines: a full
/// 1,920 x 1,080 frame takes long on the board, and the hook keeps the audio ring fed meanwhile
/// (the LISTEN screen). Draws the same pixels.
pub fn render_rgb565_lines_with(window: &MinimalSoftwareWindow, buffer: &mut [Rgb565Pixel], width: usize, hook: impl FnMut()) -> Option<(u32, u32)> {
    let mut drawn = None;
    window.draw_if_needed(|renderer| {
        let region = renderer.render_by_line(HookedLines { buffer, width, hook, lines: 0 });
        let (origin, size) = (region.bounding_box_origin(), region.bounding_box_size());
        drawn = Some((origin.y.max(0) as u32, size.height));
    });
    drawn
}
