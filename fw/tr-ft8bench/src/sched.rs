// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The QEMU program that runs one FT8 slot of eight decoder receivers through the decode scheduler
//! (`tr_modes::frontend::sched`), with the fabric of each receiver replayed from a recorded trace and with the
//! QEMU budget counted in `minstret` (315 M instructions per receiver, and 945 M for the operator's receiver,
//! which also gets a second pass).
//!
//! The traces come from `build.rs`, which embeds the files named in the `S17_TRACES` environment variable:
//! trace 0 is the operator's recording, decoded in two passes, and traces 1 to 3 are the recordings qso3_busy,
//! qso1 and qso2, decoded in one pass. Receiver 0 is the operator's receiver and uses trace 0, and receivers 1
//! to 7 use traces 1, 2, 3, 1, 2, 3 and 1. After the slot there is a demonstration job, trace 1 with a cap of
//! 120 M instructions that it cannot meet, which has to be cut at a candidate boundary and report that it was.
//! tools/qemu_s17.sh runs the program and reads its `JOB`, `DECODE`, `SLOT` and `DEMO` lines.

#![no_std]
#![no_main]

extern crate alloc;

use alloc::vec::Vec;
use core::fmt::Write as _;

use riscv_rt::entry;
use tr_ae350::board::qemu;
use tr_ae350::uart;
use tr_modes::frontend::decode::Cut;
use tr_modes::frontend::sched::{run_ft8, Budget, CandPolicy, Job, JobResult, JobRunner, Mode, RxConfig, Scheduler};
use tr_modes::frontend::trace::TraceFabric;

/// The traces packed by `build.rs`: a `u32` count, then for each trace a `u32` length and the bytes (little endian).
static PACK: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/sched.bin"));

// The runtime shared by the three benchmark programs of this crate; `rt.rs` takes the size of its heap from
// `HEAP_BYTES`.
#[path = "rt.rs"]
mod rt;
const HEAP_BYTES: usize = 12 << 20;
use rt::{instret, HEAP};

/// Instruction cap of the demonstration job, lower than the job needs, so that it has to be cut.
const DEMO_CAP: u64 = 120_000_000;

/// Splits `PACK` into the individual traces.
fn traces() -> Vec<&'static [u8]> {
    let u = |p: usize| u32::from_le_bytes([PACK[p], PACK[p + 1], PACK[p + 2], PACK[p + 3]]) as usize;
    let n = u(0);
    let mut pos = 4;
    let mut v = Vec::new();
    for _ in 0..n {
        let len = u(pos);
        v.push(&PACK[pos + 4..pos + 4 + len]);
        pos += 4 + len;
    }
    v
}

/// Runs a scheduler job on the trace of its receiver instead of on a real fabric.
struct Runner {
    /// The trace of each receiver, indexed by receiver number.
    per_rx: Vec<&'static [u8]>,
}

impl JobRunner for Runner {
    fn run(&mut self, job: &Job, clock: &dyn Fn() -> u64) -> JobResult {
        let (mut fab, audio, recorded) = TraceFabric::open(self.per_rx[job.rx]);
        // The trace holds the fabric's answers for the request it was recorded with, so the scheduler has to ask
        // for the same candidate count and the same number of passes.
        assert!(recorded.max_cand == job.params.max_cand && recorded.passes == job.params.passes, "trace/job mismatch, rx {}", job.rx);
        run_ft8(&mut fab, &audio, &job.params, clock)
    }
}

/// The text of a `cut=` field: `none`, or where the job was cut off (pass, candidates done and left, whether the
/// pass was skipped, instructions spent when the cut was decided, and the reserve that decided it).
fn cut_text(c: &Option<Cut>) -> alloc::string::String {
    match c {
        None => alloc::string::String::from("none"),
        Some(c) => alloc::format!(
            "pass{}:done{}:left{}:skipped{}:spent{}:reserve{}",
            c.pass, c.done, c.left, c.pass_skipped as u8, c.spent, c.reserve
        ),
    }
}

/// Runs the eight-receiver slot and then the demonstration job, printing a `JOB` line per receiver (with its
/// `DECODE` lines), a `SLOT` line with the total spent against the total budget, and the `DEMO` lines, and exits
/// QEMU with a pass status, or with a failure status when the four traces are not all there.
#[entry]
fn main() -> ! {
    let mut con = &uart::CONSOLE;
    con.init(24_000_000, 115_200);
    // The FPU has to be on before the first f32 instruction, or the core traps.
    unsafe { tr_ae350::fpu::enable() };
    let t = traces();
    let _ = writeln!(con, "fpga-sdr S17/FO2 decode scheduler (QEMU), {} traces, {} bytes", t.len(), PACK.len());
    if t.len() != 4 {
        let _ = writeln!(con, "need 4 traces (S17_TRACES, see tools/qemu_s17.sh)");
        qemu::exit_fail(2);
    }
    // Trace used by each of the eight receivers; receiver 0 is the operator's.
    let map = [0usize, 1, 2, 3, 1, 2, 3, 1];
    let rx: Vec<RxConfig> = map
        .iter()
        .enumerate()
        .map(|(i, &k)| {
            let (_, _, p) = TraceFabric::open(t[k]);
            RxConfig { mode: Mode::Ft8, operator: i == 0, freq_min: p.freq_min, freq_max: p.freq_max }
        })
        .collect();
    let mut sched = Scheduler::new(Budget::QEMU, CandPolicy::default(), &rx);
    sched.tick = Some(instret);
    let mut runner = Runner { per_rx: map.iter().map(|&k| t[k]).collect() };
    let jobs = sched.jobs(0);
    let t0 = instret();
    let reports = sched.run(&jobs, &mut runner, &instret);
    let total = instret() - t0;
    for r in &reports {
        let _ = writeln!(
            con,
            "JOB rx={} trace={} order={} operator={} max_cand={} passes={} cap={} start={} spent={} first_pass={} decodes={} cut={} next_max_cand={}",
            r.rx, map[r.rx], r.order, r.operator as u8, r.max_cand, r.passes, r.cap, r.start, r.spent, r.first_pass,
            r.messages.len(), cut_text(&r.cut), r.next_max_cand
        );
        for m in &r.messages {
            let _ = writeln!(con, "DECODE rx={} {}", r.rx, m);
        }
    }
    let budget: u64 = reports.iter().map(|r| r.cap).sum();
    let _ = writeln!(con, "SLOT total={total} budget={budget}");

    // Demonstration: the busy recording (receiver 1's trace) with a cap it cannot meet.
    let mut demo_jobs = Scheduler::new(Budget::QEMU, CandPolicy::default(), &rx[1..2]).jobs(0);
    demo_jobs[0].params.cap = DEMO_CAP;
    demo_jobs[0].params.clock = Some(instret);
    let mut demo_runner = Runner { per_rx: alloc::vec![t[1]] };
    let t0 = instret();
    let res = demo_runner.run(&demo_jobs[0], &instret);
    let spent = instret() - t0;
    let _ = writeln!(con, "DEMO cap={DEMO_CAP} spent={spent} decodes={} cut={}", res.messages.len(), cut_text(&res.cut));
    for m in &res.messages {
        let _ = writeln!(con, "DEMO_DECODE {m}");
    }
    let peak = unsafe { (*HEAP.state.get()).2 };
    let _ = writeln!(con, "HEAP peak {peak} bytes");
    let _ = writeln!(con, "S17 bench done");
    qemu::exit_pass();
}
