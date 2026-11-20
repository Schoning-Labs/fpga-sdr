// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The start-up program of the first-power-on ladder (docs/LADDER.md), meant to be the first firmware that runs
//! on the AE350 processor of a new board build, and written so that it depends on as little of the system as
//! possible and so that its output shows which parts of the design already work.
//!
//! The structure and the test routines (a report printed once for every guess of the UART's input clock,
//! register page checks, clock rates measured against the oscillator's millisecond counter, DDR3 address-line
//! and pattern tests) use our register page (rtl/top/ladder_regs.v), our clocks, the
//! DDR3 size probe of `tr_ae350::memprobe` and smaller memory tests.
//!
//! The program runs in place from flash (memory-ladder.x) with data and stack in the DLM, so it needs neither
//! DDR3 nor the UART loader to start. It finds out which ladder bitstream is loaded (register 0x04: step 1, 2
//! or 3) and prints one line at once for every guess of the UART's input clock (the memory tests take a while,
//! and without these lines the console would stay silent for about a minute), then runs the checks of that
//! step into a buffer and prints the report again and again, once per guess, each time with a header that
//! names the guess. Exactly one guess is readable at 115,200 baud, and that one tells which clock the UART
//! really gets.
//!
//! LED 5 is toggled once per printed report, so it blinks as long as the processor is alive; the LEDs are
//! active low on the board and the bitstream inverts them (rtl/top/ladder_top.v).

#![no_std]
#![no_main]

use core::fmt::Write as _;
use core::panic::PanicInfo;
use core::ptr::{read_volatile, write_volatile};

use riscv_rt::entry;
use tr_ae350::{cctl, memprobe, timer, uart};

// ---------------------------------------------------------------- the register page (rtl/top/ladder_regs.v)
// Byte offsets of the 32-bit registers, counted from the start of the fabric register window.
const REG_BASE: u32 = 0xE800_0000;
const REG_ID: u32 = 0x00; // 'LADR'
const REG_STEP: u32 = 0x04; // 1, 2 or 3
const REG_BUILD: u32 = 0x08; // first 8 hex digits of the commit
const REG_LED: u32 = 0x0C; // rw, bits 5:0; bit 5 is LED 5
const REG_STATUS: u32 = 0x10; // 0 DDR3 ready, 1 DSP PLL, 2 video PLL, 3 DDR3 PLL lock
const REG_SCRATCH: u32 = 0x14; // rw
const REG_MS: u32 = 0x40; // milliseconds of the 50 MHz oscillator (16 bit, Gray-coded crossing)
const REG_AUDIO: u32 = 0x44; // PT8211 frames sent (16 bit), step 3
const REG_DSP: u32 = 0x48; // DSP clock / 2^17
const REG_PIX: u32 = 0x4C; // pixel clock / 2^17
const REG_AHB: u32 = 0x50; // AHB clock / 2^17
const REG_DDR: u32 = 0x54; // DDR-bus clock / 2^17
const REG_RTC: u32 = 0x58; // RTC clock / 2^12
const REG_VFRAMES: u32 = 0x5C; // video frames (16 bit), step 2 and 3
/// The ASCII letters "LADR", which REG_ID reads back when the loaded bitstream is a ladder build.
const ID_LADR: u32 = 0x4C41_4452;

// Bits of REG_STATUS.
const ST_DDR3_READY: u32 = 1 << 0;
const ST_DSP_LOCK: u32 = 1 << 1;
const ST_VID_LOCK: u32 = 1 << 2;
const ST_DDR3_PLL: u32 = 1 << 3;

/// Clocks the ladder PLLs make (gowin/p1/ip/*.mod; gowin/ladder/ladder.sdc).
const HZ_DSP: u64 = 120_000_000;
const HZ_PIX: u64 = 148_750_000;
const HZ_AHB: u64 = 80_000_000;
const HZ_DDR: u64 = 50_000_000;
const HZ_RTC: u64 = 10_000_000;

/// Guesses for the UART's input clock. The AE350's APB clock is 80 MHz in this design and the DDR-bus clock
/// 50 MHz; the first guess is the APB clock, the second is the 100 MHz bus clock of earlier versions of the design,
/// and the rest are other frequencies that are plausible for a UART clock. No document says which clock divides
/// down to the UART (docs/C1_AE350.md), and tr-ae350 and tr-loader assume 24 MHz as a placeholder. Setting
/// `LADDER_UCLK_HZ=<Hz>` at build time keeps only that one guess, which is what to do once the real clock is known.
const GUESSES: [u32; 7] = [80_000_000, 100_000_000, 50_000_000, 24_000_000, 25_000_000, 20_000_000, 10_000_000];
const FIXED: Option<&str> = option_env!("LADDER_UCLK_HZ");

/// DDR3 byte addresses of the tests (docs/MEM_1GB.md): the address-line test marks a word at `ADDR_BASE` + 2^k
/// up to 512 MB, the data test covers 64 KiB at `MEM_BASE` and 16 KiB at `TOP_BASE`, the last 16 KiB of the 1 GB.
/// The program runs from flash without a cache, so loops are slow, and more words would only lengthen the
/// time before the first report.
const ADDR_BASE: usize = 0x0000_0000;
const ADDR_MAX_K: u32 = 29;
const MEM_BASE: usize = 0x0100_0000;
const MEM_WORDS: usize = 16 * 1024;
const TOP_BASE: usize = 0x3FFF_C000;
const TOP_WORDS: usize = 4 * 1024;

/// Reads the 32-bit fabric register at byte offset `off` of the register page.
fn rd(off: u32) -> u32 {
    // SAFETY: the fabric register window of the AE350's extended AHB slave port (docs/ARCHITECTURE.md 4.1).
    unsafe { read_volatile((REG_BASE + off) as *const u32) }
}

/// Writes the 32-bit fabric register at byte offset `off` of the register page.
fn wr(off: u32, v: u32) {
    // SAFETY: as `rd`.
    unsafe { write_volatile((REG_BASE + off) as *mut u32, v) }
}

/// A fixed-size text buffer that implements `core::fmt::Write`, so that `writeln!` works without an allocator.
/// Text that does not fit is cut off silently. A report is built here first and sent to the UART afterwards,
/// once per clock guess, which keeps the checks from being run again for every guess.
struct Buf {
    b: [u8; 3072],
    n: usize,
}

impl Buf {
    const fn new() -> Self {
        Buf { b: [0; 3072], n: 0 }
    }
    fn clear(&mut self) {
        self.n = 0;
    }
    fn as_str(&self) -> &str {
        core::str::from_utf8(&self.b[..self.n]).unwrap_or("?")
    }
}

impl core::fmt::Write for Buf {
    fn write_str(&mut self, s: &str) -> core::fmt::Result {
        let room = self.b.len() - self.n;
        let k = s.len().min(room);
        self.b[self.n..self.n + k].copy_from_slice(&s.as_bytes()[..k]);
        self.n += k;
        Ok(())
    }
}

/// Prints the panic message on the console (the clock guess last set stays in force) and then sleeps for good.
#[panic_handler]
fn panic(info: &PanicInfo) -> ! {
    let mut con = &uart::CONSOLE;
    let _ = writeln!(con, "PANIC: {info}");
    loop {
        riscv::asm::wfi();
    }
}

/// Counts the check lines that passed and failed.
#[derive(Clone, Copy, Default)]
struct Tally {
    pass: u32,
    fail: u32,
}

impl Tally {
    /// Counts one check and writes its report line, `name: PASS (detail)` or `name: FAIL (detail)`, to `w`.
    fn line(&mut self, w: &mut Buf, name: &str, ok: bool, detail: core::fmt::Arguments) {
        if ok {
            self.pass += 1;
        } else {
            self.fail += 1;
        }
        let _ = writeln!(w, "{name}: {} ({detail})", if ok { "PASS" } else { "FAIL" });
    }
}

fn yn(b: bool) -> &'static str {
    if b {
        "yes"
    } else {
        "no"
    }
}

/// Parses a plain decimal number (the build-time `LADDER_UCLK_HZ`); anything else, or an overflow, gives `None`.
fn parse_u32(s: &str) -> Option<u32> {
    let mut v: u32 = 0;
    for c in s.bytes() {
        if !c.is_ascii_digit() {
            return None;
        }
        v = v.checked_mul(10)?.checked_add((c - b'0') as u32)?;
    }
    Some(v)
}

/// Reads one of the 16-bit free-running counters of the register page (the upper half of the word is dropped).
fn counter(reg: u32) -> u16 {
    rd(reg) as u16
}

/// Waits `ms` with the oscillator's counter; false if the counter does not advance (then there is no time base).
fn wait_ms(ms: u16) -> bool {
    let start = counter(REG_MS);
    // The spin limit is only a way out when the counter is stuck, it is far longer than any wait asked for here.
    let mut spins = 0u32;
    loop {
        if counter(REG_MS).wrapping_sub(start) >= ms {
            return true;
        }
        spins += 1;
        if spins > 3_000_000 {
            return false;
        }
    }
}

/// Delays by about `ms` milliseconds: exactly, with the oscillator's counter, when the register page answers,
/// and otherwise with a rough busy loop (its length is a guess for a core running from flash without a cache).
fn delay_ms(ms: u16, have_page: bool) {
    if !(have_page && wait_ms(ms)) {
        for _ in 0..(ms as u32 * 5_000) {
            core::hint::spin_loop();
        }
    }
}

/// Rate in Hz of a counter that counts every `2^shift` clocks, seen as `count` over `ms` milliseconds.
fn rate_hz(count: u16, shift: u32, ms: u16) -> u64 {
    (count as u64) * (1u64 << shift) * 1000 / (ms.max(1) as u64)
}

/// True when `got` is within `pct` percent of `want`, in either direction.
fn within(got: u64, want: u64, pct: u64) -> bool {
    got * 100 >= want * (100 - pct) && got * 100 <= want * (100 + pct)
}

/// Pushes the cache lines of the range out to DDR3 and drops them, so that the next read really comes from the memory.
fn flush(addr: usize, len: usize) {
    // SAFETY: cache maintenance of the tested range; the caches are off at reset, the commands then do nothing.
    unsafe {
        cctl::dcache_writeback(addr, len);
        cctl::dcache_invalidate(addr, len);
    }
}

// ---------------------------------------------------------------- DDR3 tests
/// Outcome of a memory test: wrong words, words tested, and the first error as (address, wanted, read).
#[derive(Clone, Copy, Default)]
struct MemResult {
    errors: u32,
    words: u32,
    first: Option<(usize, u32, u32)>,
}

/// One step of a 32-bit xorshift generator, a cheap source of pseudo-random test words.
fn xorshift(s: &mut u32) -> u32 {
    *s ^= *s << 13;
    *s ^= *s >> 17;
    *s ^= *s << 5;
    *s
}

/// The word that pattern number `pat` puts at address `a`. The random pattern advances `seed` on every call, so
/// the read pass must start from the same seed as the write pass and visit the words in the same order.
fn pattern(pat: u32, a: usize, seed: &mut u32) -> u32 {
    match pat {
        0 => 0x5555_5555,
        1 => 0xAAAA_AAAA,
        2 => (a as u32).rotate_left(7) ^ 0xA5A5_A5A5,
        _ => xorshift(seed),
    }
}

/// Data test of `words` 32-bit words at `base`: four patterns (0x5555_5555, 0xAAAA_AAAA, the word's own address
/// rotated, pseudo-random), each written in full, pushed to DDR3 and read back.
///
/// # Safety
/// `base..base + 4 * words` must be memory this program uses for nothing else.
unsafe fn mem_test(base: usize, words: usize) -> MemResult {
    let base = base as *mut u32;
    let mut res = MemResult::default();
    // Words written between two flushes, so that the cache holds only a small part of the range at any time.
    const CHUNK: usize = 4 * 1024;
    for pat in 0..4u32 {
        let mut seed = 0x1234_5678u32;
        let mut i = 0;
        while i < words {
            let n = CHUNK.min(words - i);
            for j in 0..n {
                let a = base.add(i + j);
                write_volatile(a, pattern(pat, a as usize, &mut seed));
            }
            flush(base.add(i) as usize, n * 4);
            i += n;
        }
        let mut seed = 0x1234_5678u32;
        for i in 0..words {
            let a = base.add(i);
            let want = pattern(pat, a as usize, &mut seed);
            let got = read_volatile(a);
            if got != want {
                res.errors += 1;
                if res.first.is_none() {
                    res.first = Some((a as usize, want, got));
                }
            }
        }
    }
    res.words = words as u32;
    res
}

/// Address-line test: one marked word at `base` and one at each `base + 2^k` bytes for k = 2 up to `max_k`;
/// two address lines that are shorted or open show as a marker that changed.
///
/// # Safety
/// Those words must be memory this program uses for nothing else.
unsafe fn addr_test(base: usize, max_k: u32) -> MemResult {
    let mut res = MemResult::default();
    // Every marker differs from all the others, and `k == 0` stands for `base` itself.
    let mark = |k: u32| 0xC0DE_0000u32 ^ (k * 0x0101_0101);
    let addr = |k: u32| if k == 0 { base } else { base + (1usize << k) };
    let order = || core::iter::once(0u32).chain(2..=max_k);
    for k in order() {
        write_volatile(addr(k) as *mut u32, mark(k));
    }
    for k in order() {
        flush(addr(k), 4);
    }
    for k in order() {
        let got = read_volatile(addr(k) as *const u32);
        res.words += 1;
        if got != mark(k) {
            res.errors += 1;
            if res.first.is_none() {
                res.first = Some((addr(k), mark(k), got));
            }
        }
    }
    res
}

/// Writes the report line of one memory test, with the first wrong word in the detail when there was one.
fn mem_line(t: &mut Tally, w: &mut Buf, name: &str, r: MemResult, ok_detail: core::fmt::Arguments) {
    match r.first {
        None => t.line(w, name, true, ok_detail),
        Some((a, want, got)) => t.line(w, name, false, format_args!("{} wrong, first at {a:#010x}: wanted {want:#010x}, read {got:#010x}", r.errors)),
    }
}

/// The DDR3 checks of steps 2 and 3, run once (they take seconds from flash without a cache).
fn ddr3_checks(w: &mut Buf, t: &mut Tally) {
    // SAFETY: this program runs from flash and uses DDR3 for nothing but these tests.
    let sz = unsafe { memprobe::size_probe() };
    let ok = memprobe::size_line(w, sz, memprobe::DDR3_SIZE_K);
    if ok {
        t.pass += 1;
    } else {
        t.fail += 1;
    }
    let a = unsafe { addr_test(ADDR_BASE, ADDR_MAX_K) };
    mem_line(t, w, "DDR3 address lines", a, format_args!("{} words at {ADDR_BASE:#x} + 2^k, k up to {ADDR_MAX_K} ({} MB)", a.words, 1u32 << (ADDR_MAX_K - 20)));
    let m = unsafe { mem_test(MEM_BASE, MEM_WORDS) };
    mem_line(t, w, "DDR3 memory test", m, format_args!("{} KiB at {MEM_BASE:#010x}, four patterns", MEM_WORDS * 4 / 1024));
    let m = unsafe { mem_test(TOP_BASE, TOP_WORDS) };
    mem_line(t, w, "DDR3 top of memory", m, format_args!("{} KiB at {TOP_BASE:#010x}, four patterns", TOP_WORDS * 4 / 1024));
}

// The report being built and the stored lines of the DDR3 tests; they are statics so that they live in the
// DLM's bss and not on the stack.
static mut REPORT: Buf = Buf::new();
static mut MEMLINES: Buf = Buf::new();

/// The register checks, some for every step and some only for the later ones: PLL locks, the register write and
/// read back, the clock rates, the machine timer, and from step 2 on the video frame counter and from step 3 on the
/// audio frame counter. Together they take about 600 ms.
fn fabric_checks(rep: &mut Buf, t: &mut Tally, step: u32) {
    let st = rd(REG_STATUS);
    t.line(
        rep,
        "PLL locks",
        st & (ST_DSP_LOCK | ST_VID_LOCK | ST_DDR3_PLL) == (ST_DSP_LOCK | ST_VID_LOCK | ST_DDR3_PLL),
        format_args!("DDR3 {}, DSP {}, video {}", yn(st & ST_DDR3_PLL != 0), yn(st & ST_DSP_LOCK != 0), yn(st & ST_VID_LOCK != 0)),
    );
    t.line(rep, "DDR3 controller", st & ST_DDR3_READY != 0, format_args!("initialised and calibrated: {}", yn(st & ST_DDR3_READY != 0)));

    // register write and read back: two complementary patterns through the scratch word
    let mut got = [0u32; 2];
    for (i, p) in [0xA5A5_5A5Au32, 0x5A5A_A5A5].into_iter().enumerate() {
        wr(REG_SCRATCH, p);
        got[i] = rd(REG_SCRATCH);
    }
    wr(REG_SCRATCH, 0);
    t.line(rep, "register write and read back", got == [0xA5A5_5A5A, 0x5A5A_A5A5], format_args!("wrote 0xa5a55a5a, 0x5a5aa5a5, read {:#010x}, {:#010x}", got[0], got[1]));

    // Clock rates against the oscillator over about 200 ms: every counter is read before and after the wait, and
    // the elapsed time comes from the millisecond counter, so the wait itself does not have to be exact. The
    // fabric counters count every 2^17th clock (the RTC counter every 2^12th), see `rate_hz`.
    let (m0, d0, p0, a0, r0, c0) = (counter(REG_MS), counter(REG_DSP), counter(REG_PIX), counter(REG_AHB), counter(REG_DDR), counter(REG_RTC));
    let timebase = wait_ms(200);
    let (m1, d1, p1, a1, r1, c1) = (counter(REG_MS), counter(REG_DSP), counter(REG_PIX), counter(REG_AHB), counter(REG_DDR), counter(REG_RTC));
    let ms = m1.wrapping_sub(m0);
    t.line(rep, "oscillator time base", timebase, format_args!("{ms} ms counted, expected about 200"));
    let rates = [
        ("DSP clock", rate_hz(d1.wrapping_sub(d0), 17, ms), HZ_DSP),
        ("pixel clock", rate_hz(p1.wrapping_sub(p0), 17, ms), HZ_PIX),
        ("AHB clock", rate_hz(a1.wrapping_sub(a0), 17, ms), HZ_AHB),
        ("DDR-bus clock", rate_hz(r1.wrapping_sub(r0), 17, ms), HZ_DDR),
        ("RTC clock", rate_hz(c1.wrapping_sub(c0), 12, ms), HZ_RTC),
    ];
    for (name, got, want) in rates {
        t.line(rep, name, timebase && within(got, want, 5), format_args!("{} kHz, expected {}", got / 1000, want / 1000));
    }

    // the machine timer against the oscillator: tr-ae350 and the loader assume 80 MHz (board.rs, not verified),
    // so this line only reports the measured rate and never counts as a pass or a fail
    let (ma, ta) = (counter(REG_MS), timer::now());
    delay_ms(100, true);
    let (mb, tb) = (counter(REG_MS), timer::now());
    let dms = mb.wrapping_sub(ma).max(1) as u64;
    let _ = writeln!(rep, "machine timer: INFO ({} Hz counted; tr-ae350 assumes {})", tb.wrapping_sub(ta) * 1000 / dms, tr_ae350::board::active::TIMER_HZ);

    if step >= 2 {
        let v0 = counter(REG_VFRAMES);
        let ok_time = wait_ms(200);
        let n = counter(REG_VFRAMES).wrapping_sub(v0);
        t.line(rep, "HDMI video frames", ok_time && (10..=14).contains(&n), format_args!("{n} frames in 200 ms, expected 12 (colour bars on the monitor)"));
    }
    if step >= 3 {
        let a0 = counter(REG_AUDIO);
        let ok_time = wait_ms(100);
        let n = counter(REG_AUDIO).wrapping_sub(a0) as u64;
        t.line(rep, "audio frames (PT8211)", ok_time && within(n, 4_800, 5), format_args!("{n} frames in 100 ms, expected 4800 (1 kHz tone on the headphone output)"));
    }
}

/// Entry point after riscv-rt's start-up code. Never returns: it prints the guess lines, then loops over the
/// checks and the report for as long as the board is powered.
#[entry]
fn main() -> ! {
    let mut con = &uart::CONSOLE;
    let fixed = FIXED.and_then(parse_u32);
    let n_guess = if fixed.is_some() { 1 } else { GUESSES.len() };
    let guess = |gi: usize| fixed.unwrap_or(GUESSES[gi]);

    // At once, before any test: one line per guess, so that whoever watches the console sees right away which
    // guess is readable.
    for gi in 0..n_guess {
        con.init(guess(gi), 115_200);
        let _ = writeln!(con, "\r\n=== tr-ladder: this line is readable if the UART clock is {} kHz (115200 baud, 8N1); tests running, the report follows in about a minute ===", guess(gi) / 1000);
        delay_ms(100, false);
    }

    // Without the ladder identifier the register page is either absent or from another bitstream, and then no
    // register is touched except for the identifier itself.
    let have_page = rd(REG_ID) == ID_LADR;
    let step = if have_page { rd(REG_STEP) } else { 0 };
    let mut mem_tally = Tally::default();
    let mut mem_done = false;
    let mut led = 0u32;
    let mut cycle: u32 = 0;
    loop {
        // SAFETY: single hart, no interrupts, the two statics are used only here.
        let rep = unsafe { &mut *core::ptr::addr_of_mut!(REPORT) };
        let mem = unsafe { &mut *core::ptr::addr_of_mut!(MEMLINES) };
        rep.clear();
        let mut t = Tally::default();
        if have_page {
            let build = rd(REG_BUILD);
            let _ = writeln!(rep, "tr-ladder: ladder step {step}, bitstream commit {build:08x}, report {cycle}");
            t.line(rep, "register page", true, format_args!("identifier {:#010x}", rd(REG_ID)));
            fabric_checks(rep, &mut t, step);
            if step >= 2 {
                // The DDR3 tests run once, because they take seconds; later reports repeat their stored lines.
                if !mem_done {
                    mem.clear();
                    ddr3_checks(mem, &mut mem_tally);
                    mem_done = true;
                }
                let _ = rep.write_str(mem.as_str());
                t.pass += mem_tally.pass;
                t.fail += mem_tally.fail;
            } else {
                let _ = writeln!(rep, "DDR3 tests: not in step 1 (step 2 adds the size probe and the memory test)");
            }
        } else {
            let _ = writeln!(rep, "tr-ladder: the processor runs, but the register page at {REG_BASE:#010x} does not answer with the ladder identifier (read {:#010x}): the bitstream is not a ladder build", rd(REG_ID));
            t.fail += 1;
        }
        let _ = writeln!(rep, "result: {} passed, {} failed{}", t.pass, t.fail, if t.fail == 0 { "" } else { "  <<< LOOK AT THE FAIL LINES" });
        led ^= 0x20;
        if have_page {
            wr(REG_LED, led);
        }

        for gi in 0..n_guess {
            con.init(guess(gi), 115_200);
            let _ = writeln!(con, "\r\n=== tr-ladder: this line is readable if the UART clock is {} kHz (115200 baud, 8N1) ===", guess(gi) / 1000);
            let _ = con.write_str(rep.as_str());
            delay_ms(200, have_page);
        }
        delay_ms(1000, have_page);
        cycle += 1;
    }
}
