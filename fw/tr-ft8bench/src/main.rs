// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The QEMU entry point of the FT8 CPU benchmark. It replays a recorded trace of the FPGA front end's answers
//! (`tr_modes::frontend::trace`) to the CPU half of the decoder (`tr_modes::frontend::decode::decode_slot`)
//! and prints the instructions retired per stage (`minstret`, with QEMU running at `-icount shift=0`;
//! tools/qemu_s15.sh and docs/S2_BENCH.md explain what that measures) together with the decoded messages.
//! The trace is embedded at build time by `build.rs` from the file named in the `S15_TRACE` environment
//! variable, and the program stops with a failure status when none was given.

#![no_std]
#![no_main]

extern crate alloc;

use core::fmt::Write as _;

use riscv_rt::entry;
use tr_ae350::board::qemu;
use tr_ae350::uart;
use tr_modes::frontend::decode::decode_slot;
use tr_modes::frontend::trace::TraceFabric;

/// The recorded fabric trace; empty when the build was made without `S15_TRACE`.
static TRACE: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/trace.bin"));

// The runtime shared by the three benchmark programs of this crate (heap, panic handler, instruction counter);
// `rt.rs` takes the size of its heap from the `HEAP_BYTES` of the program that includes it.
#[path = "rt.rs"]
mod rt;
const HEAP_BYTES: usize = 20 << 20;
use rt::{instret, HEAP};

/// Replays the trace through `decode_slot` once and prints, in this order, the `effort` line, a `DECODE` line per
/// message, one `RESULT` line with the instruction counts of the stages, a `CAND` line per candidate with the
/// work of the decoding ladder, a `LADDER` line with the sums, and the peak heap use. tools/qemu_s15.sh parses
/// these lines. The run ends with a pass status, or a failure status when there is no trace.
#[entry]
fn main() -> ! {
    let mut con = &uart::CONSOLE;
    con.init(24_000_000, 115_200);
    // The FPU has to be on before the first f32 instruction, or the core traps.
    unsafe { tr_ae350::fpu::enable() };
    let _ = writeln!(con, "fpga-sdr S15 FT8 CPU-part benchmark (QEMU), trace {} bytes", TRACE.len());
    if TRACE.is_empty() {
        let _ = writeln!(con, "no trace embedded (set S15_TRACE, see tools/qemu_s15.sh)");
        qemu::exit_fail(2);
    }
    let (mut fab, audio, mut params) = TraceFabric::open(TRACE);
    params.clock = Some(instret);
    let _ = writeln!(con, "effort {}", tr_modes::frontend::effort::effort_spec(&params.effort));
    let t0 = instret();
    let (decodes, st) = decode_slot(&mut fab, &audio, &params, &instret);
    let total = instret() - t0;
    for d in &decodes {
        let text = mfsk_core::msg::wsjt77::unpack77(d.result.message77()).unwrap_or_default();
        let _ = writeln!(con, "DECODE pass {} {:.1} Hz {:+.2} s {}", d.pass, d.result.freq_hz, d.result.dt_sec, text);
    }
    let _ = writeln!(
        con,
        "RESULT total={total} candidates={} fine_sync={} ldpc={} subtract={} fabric_words={} pass0={} pass1={} ncand={},{} nsync_pass={},{} decodes={} max_cand={} passes={}",
        st.candidates, st.fine_sync, st.ldpc, st.subtract, st.fabric, st.per_pass_total[0], st.per_pass_total[1],
        st.n_cand[0], st.n_cand[1], st.n_nsync_pass[0], st.n_nsync_pass[1], decodes.len(), params.max_cand, params.passes
    );
    // Per candidate, the work of the decoding ladder (belief propagation, OSD and a-priori passes), with the
    // instructions counted by the same `minstret`.
    for l in &st.log {
        let w = &l.work;
        let _ = writeln!(
            con,
            "CAND pass={} q={} outcome={} sweep2={} bp_runs={} osd_searches={} npre2={} ap_bp={} ap_osd={} i_bp={} i_osd={} i_ap={} i_other={}",
            l.pass, l.q, l.outcome, l.osd_sweep as u8, w.bp_runs, w.osd_searches, w.osd_npre2, w.ap_bp_runs, w.ap_osd_searches,
            w.ticks_bp, w.ticks_osd, w.ticks_ap, w.ticks_other
        );
    }
    let _ = writeln!(
        con,
        "LADDER i_bp={} i_osd={} i_ap={} osd_attempts={} osd_searches={} ap_osd_searches={}",
        st.ticks_bp, st.ticks_osd, st.ticks_ap, st.osd_attempts, st.osd_searches, st.ap_osd_searches
    );
    let peak = unsafe { (*HEAP.state.get()).2 };
    let _ = writeln!(con, "HEAP peak {peak} bytes");
    let _ = writeln!(con, "S15 bench done");
    qemu::exit_pass();
}
