// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The FT8 firmware's code under QEMU (`fw/tr-app/qemu_p2.sh`), on the instruction set of the target and against a
//! simulated fabric, because QEMU's `virt` machine has no register window and no DDR3 lanes.
//!
//! What runs is the start-up, the heap, the FPU, the Slint FT8 screen rendered by the software renderer into two
//! frame buffers that are shown in turn, the two clicks of the operator (TX enable and CQ) sent to the screen as
//! pointer events, the station logic, the radio glue and the drivers on the mock register space, the FT8 encoder
//! feeding the TX ring, the simulated chip looping the ring back into the audio ring of the receiver, and the
//! software FT8 decoder. The test passes when the station's own CQ comes back in the decode list
//! (`tr_station::selftest`), the screen drew, and its waterfall rectangle is in the key color.
//!
//! After that comes the FreeDV receive mode (docs/FREEDV.md section 9). The screen switches to the FreeDV view, a
//! 700D signal with a call sign in its text channel goes through the simulated back-end ring, the firmware FreeDV
//! chain, the audio ring and a model of the audio engine, and the operator's clicks on the FreeDV screen reach the
//! station. The run also measures the instructions per second of the FreeDV chain (700D and 700E, from `minstret`)
//! and how deep the stack went.
//!
//! What does not run here is anything of the real chip: the register bus, the DDR3 bridge and its 10 us rule in
//! real time, the cache commands, the HL2 link, the video output and the interrupts.

#![no_std]
#![no_main]

extern crate alloc;

use alloc::vec;
use alloc::vec::Vec;
use core::fmt::Write as _;
use core::panic::PanicInfo;
use core::time::Duration;

use riscv_rt::entry;
use slint::platform::software_renderer::Rgb565Pixel;
use tr_ae350::board::qemu;
use tr_ae350::{timer, uart};
use tr_app::screen::{Screen, HEIGHT, WIDTH};
use tr_fabric::mem::map;
use tr_fabric::mock::MockFabric;
use tr_fabric::video::FrameBuffers;
use tr_regs::generated::video as vid;
use tr_gui::fdv::{FdvEvent, FdvScreenState};
use tr_gui::ft8::{Ft8Event, Ft8ScreenState, CQ_AT, TX_ENABLE_AT, WATERFALL_RECT};
use tr_station::freedv::{FdvMode, FreedvRx};
use tr_station::selftest::{freedv_signal_12k, run, run_freedv, FdvUi, Ui};

// QEMU is started with 128 MB of RAM at 0x8000_0000; the linker script uses the first 32 MB.
const HEAP_BASE: usize = 0x8200_0000;
const HEAP_LEN: usize = 96 << 20;

#[panic_handler]
fn panic(info: &PanicInfo) -> ! {
    let mut con = &uart::CONSOLE;
    let _ = writeln!(con, "PANIC: {info}");
    qemu::exit_fail(1);
}

struct QemuUi<'a> {
    fabric: &'a MockFabric,
    /// Simulated time for the swap time-out, ms.
    t_ms: u32,
    screen: Screen,
    fb: FrameBuffers<'a, MockFabric, MockFabric>,
    buffers: [Vec<Rgb565Pixel>; 2],
    back: usize,
    frames: u32,
    lines: u32,
    key_ok: bool,
    drawn_ok: bool,
    last_rows: usize,
    /// FreeDV view: frames drawn, whether its first frame had the waterfall rectangle in key colour,
    /// and the operator events as they reached the screen.
    fdv_frames: u32,
    fdv_key_ok: bool,
    fdv_clicks_seen: u32,
}

impl QemuUi<'_> {
    /// Renders what changed and shows it (the simulated compositor takes the new base at once).
    fn draw(&mut self) {
        let buffer = &mut self.buffers[self.back];
        if let Some((first, lines)) = self.screen.render(buffer) {
            let (x0, y0, w, h) = WATERFALL_RECT;
            let key_pixels = |buffer: &[Rgb565Pixel]| {
                let mut key = 0u32;
                for y in y0..y0 + h {
                    for x in x0..x0 + w {
                        key += (buffer[y as usize * WIDTH + x as usize].0 == 0xF81F) as u32;
                    }
                }
                key
            };
            if self.frames == 0 {
                self.key_ok = key_pixels(buffer) == w * h;
                let background = buffer[0].0;
                self.drawn_ok = buffer.iter().filter(|p| p.0 != background).count() > 100_000;
            }
            if self.screen.freedv() {
                if self.fdv_frames == 0 {
                    self.fdv_key_ok = key_pixels(buffer) == w * h;
                }
                self.fdv_frames += 1;
            }
            self.frames += 1;
            self.lines += lines;
            self.fb.present(first, lines, self.t_ms);
            // The simulated compositor takes the new base at its next vertical blank.
            self.fabric.poke(vid::fb_active::addr(), self.fabric.reg(vid::fb_base::addr()));
            assert!(self.fb.back_free(self.t_ms), "the simulated compositor confirmed the swap");
            self.back = 1 - self.back;
        }
    }
}

impl FdvUi for QemuUi<'_> {
    fn poll(&mut self, t_ms: i64) -> Vec<FdvEvent> {
        // The operator: squelch off at 0.1 s, on again at 0.2 s, as clicks on the screen.
        if t_ms == 100 || t_ms == 200 {
            self.screen.click(tr_gui::fdv::SQUELCH_AT);
        }
        let e = self.screen.take_fdv_events();
        self.fdv_clicks_seen += e.len() as u32;
        e
    }

    fn show(&mut self, state: &FdvScreenState) {
        self.t_ms = self.t_ms.wrapping_add(500);
        self.screen.apply_fdv(state);
        self.draw();
    }
}

impl Ui for QemuUi<'_> {
    fn poll(&mut self, t_ms: i64) -> Vec<Ft8Event> {
        // The operator: TX enable at 0.1 s, CQ at 0.2 s, as clicks on the screen.
        match t_ms {
            100 => self.screen.click(TX_ENABLE_AT),
            200 => self.screen.click(CQ_AT),
            _ => {}
        }
        self.screen.take_events()
    }

    fn show(&mut self, state: &Ft8ScreenState) {
        self.t_ms = self.t_ms.wrapping_add(500);
        self.screen.apply(state);
        self.last_rows = state.decodes.len();
        self.draw();
    }
}

/// Instructions retired for one waterfall line (the generator: window, FFT, levels, palette
/// indices) and for building it. Exact when QEMU runs with `-icount shift=0` (qemu_p2.sh does).
/// At 6.25 lines per second this is the whole CPU cost of the waterfall except the ring write
/// (about 300 stores and one cache write-back of 1.2 KB per line).
fn measure_waterfall(con: &mut impl core::fmt::Write) {
    use riscv::register::minstret;
    use tr_station::waterfall::{WaterfallGen, WINDOW};
    let cols = WATERFALL_RECT.2 as usize;
    let i0 = minstret::read64();
    let mut gen = WaterfallGen::new(cols);
    let build = minstret::read64() - i0;
    let mut x = 12_345u32;
    let samples: Vec<i16> = (0..WINDOW)
        .map(|_| {
            x = x.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            ((x >> 16) as i16) / 4
        })
        .collect();
    let mut line = vec![0u8; cols];
    gen.line(&samples, &mut line);
    let i1 = minstret::read64();
    for _ in 0..8 {
        gen.line(&samples, &mut line);
    }
    let per_line = (minstret::read64() - i1) / 8;
    // 6.25 lines/s; the AE350 core clock is 800 MHz (ARCHITECTURE 5.5), IPC 0.7 to 1.0 assumed.
    let load = |ipc: f64| per_line as f64 * 6.25 / (800e6 * ipc) * 100.0;
    let _ = writeln!(con, "waterfall line: {per_line} instructions (tables: {build}); at 6.25 lines/s {:.2} % of an 800 MHz core at IPC 1.0, {:.2} % at 0.7", load(1.0), load(0.7));
}

// QEMU stack: 64 KiB below 0x8200_0000 (memory-qemu.x).
const STACK_TOP: usize = 0x8200_0000;
const STACK_BOTTOM: usize = STACK_TOP - 64 * 1024;
const PAINT: u32 = 0xA5A5_A5A5;
static STACK_SP: core::sync::atomic::AtomicUsize = core::sync::atomic::AtomicUsize::new(0);

/// Fills the unused stack with a pattern, to see later how deep it went.
fn paint_stack() {
    let sp: usize;
    // SAFETY: reads the stack pointer only.
    unsafe { core::arch::asm!("mv {}, sp", out(reg) sp) };
    STACK_SP.store(sp, core::sync::atomic::Ordering::Relaxed);
    let mut a = STACK_BOTTOM;
    while a + 4 <= sp - 1024 {
        // SAFETY: below the stack pointer, in the stack region, nothing lives there yet.
        unsafe { core::ptr::write_volatile(a as *mut u32, PAINT) };
        a += 4;
    }
}

/// Bytes of stack used at the deepest point so far (from the first overwritten pattern word).
fn stack_used() -> usize {
    let mut a = STACK_BOTTOM;
    // SAFETY: reads inside the stack region.
    while a < STACK_TOP && unsafe { core::ptr::read_volatile(a as *const u32) } == PAINT {
        a += 4;
    }
    STACK_TOP - a
}

/// Instructions the FreeDV chain needs per second of audio (12 kHz in, speech at 48 kHz out), on
/// the target instruction set, as docs/FREEDV.md section 6 measures the bare decode: the signal
/// of `freedv_signal_12k`, block by block through `FreedvRx::feed_12k`. Without the ring reads and
/// the audio ring writes, which the mock fabric would make dominant (plain loads and stores on the
/// board).
fn measure_freedv(con: &mut impl core::fmt::Write) -> usize {
    use riscv::register::minstret;
    let mut deepest = 0usize;
    for mode in [FdvMode::D700, FdvMode::E700] {
        // The signal first (the modulator is bigger on the stack than the receiver and not part of the
        // firmware), then the stack is painted: what is used after it is the receiver alone.
        let x12 = freedv_signal_12k(mode, 6);
        paint_stack();
        let base = STACK_TOP - STACK_SP.load(core::sync::atomic::Ordering::Relaxed);
        let mut rx = FreedvRx::new(mode);
        let built = stack_used().saturating_sub(base);
        rx.set_squelch(true, -2.0);
        let mut worst = 0u64;
        let mut total = 0u64;
        let mut sink = [0u32; 256];
        for b in x12.chunks(128) {
            let i0 = minstret::read64();
            rx.feed_12k(b);
            let d = minstret::read64() - i0;
            total += d;
            worst = worst.max(d);
            // the audio engine takes the speech away
            while rx.queue.pop_stereo(&mut sink) > 0 {}
        }
        let per_s = total / 6;
        let load = |ipc: f64| per_s as f64 / (800e6 * ipc) * 100.0;
        let ind = rx.indicators();
        let _ = writeln!(
            con,
            "FreeDV cost {}: {} instructions per second of audio ({:.1} M/s), longest block {} instructions; {:.1} % of an 800 MHz core at IPC 0.7, {:.1} % at 1.0; sync {:?}, {} frames, text {:?}",
            mode.name(),
            per_s,
            per_s as f64 / 1e6,
            worst,
            load(0.7),
            load(1.0),
            ind.sync,
            ind.frames,
            rx.text().display()
        );
        let after = stack_used().saturating_sub(base);
        let _ = writeln!(con, "FreeDV stack {}: {} bytes below the caller while building the receiver, {} after running it", mode.name(), built, after);
        deepest = deepest.max(after);
    }
    deepest
}

#[entry]
fn main() -> ! {
    let mut con = &uart::CONSOLE;
    con.init(24_000_000, 115_200);
    unsafe { tr_ae350::fpu::enable() };
    unsafe { tr_app::heap::init(HEAP_BASE, HEAP_LEN) };
    let _ = writeln!(con, "fpga-sdr P2: FT8 firmware under QEMU, simulated fabric");
    paint_stack();

    let fabric = MockFabric::new();
    let screen = Screen::new(|| Duration::from_micros(timer::now() * 1_000_000 / qemu::TIMER_HZ as u64));
    let mut ui = QemuUi {
        fabric: &fabric,
        t_ms: 0,
        screen,
        fb: FrameBuffers::new(&fabric, &fabric, map::FRAME_BUFFER),
        buffers: [vec![Rgb565Pixel(0); WIDTH * HEIGHT], vec![Rgb565Pixel(0); WIDTH * HEIGHT]],
        back: 1,
        frames: 0,
        lines: 0,
        key_ok: false,
        drawn_ok: false,
        last_rows: 0,
        fdv_frames: 0,
        fdv_key_ok: false,
        fdv_clicks_seen: 0,
    };
    let _ = writeln!(con, "screen ok (Slint software renderer, 1920x1080 RGB565, two buffers)");

    measure_waterfall(&mut con);

    let t0 = timer::now();
    let report = run(&fabric, &mut ui, &mut con);
    let secs = (timer::now() - t0) / qemu::TIMER_HZ as u64;

    let _ = writeln!(
        con,
        "screen: {} frames, {} lines redrawn, first frame drawn: {}, waterfall rectangle key colour: {}, decode lines shown at the end: {}",
        ui.frames, ui.lines, ui.drawn_ok, ui.key_ok, ui.last_rows
    );

    let _ = writeln!(con, "stack after the FT8 part: {} bytes used (sp at start {:#x}, top {:#x})", stack_used(), STACK_SP.load(core::sync::atomic::Ordering::Relaxed), STACK_TOP);
    // ---- FreeDV receive: the stack is painted again here, so that what follows shows the depth the FreeDV part alone
    // reaches below this point.
    ui.screen.set_freedv(true);
    let t1 = timer::now();
    let fdv_fabric = MockFabric::new();
    let fdv_report = run_freedv(&fdv_fabric, 8, &mut ui, &mut con);
    let fdv_secs = (timer::now() - t1) / qemu::TIMER_HZ as u64;
    let _ = writeln!(
        con,
        "FreeDV screen: {} frames drawn, waterfall rectangle key colour: {}, operator clicks that reached the station: {}, QEMU time {} s",
        ui.fdv_frames, ui.fdv_key_ok, ui.fdv_clicks_seen, fdv_secs
    );
    let used = measure_freedv(&mut con);
    let _ = writeln!(con, "stack: the FreeDV receiver (built, run for 6 s of signal each in 700D and 700E) went {used} bytes deeper than the main loop; the FT8 decoder alone takes about 60 KB of the 64 KB stack, the board DLM is 64 KB (link script says 32 KB)");
    let _ = writeln!(con, "heap peak {} KiB, run time {} s of QEMU time", tr_app::heap::peak() / 1024, secs);
    if report.pass() && ui.key_ok && ui.drawn_ok && ui.frames >= 10 && ui.last_rows == 2 && fdv_report.pass() && ui.fdv_key_ok && ui.fdv_frames >= 5 && ui.fdv_clicks_seen == 2 && used < 48 * 1024 {
        let _ = writeln!(con, "P2 QEMU PASS");
        qemu::exit_pass();
    }
    let _ = writeln!(con, "P2 QEMU FAIL: {report:?} {fdv_report:?}");
    qemu::exit_fail(2);
}
