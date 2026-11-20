// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Writes the receiver back-end testbench fixtures from the bit-exact model
//! (docs/R4_BACKEND.md section 6).
//!
//! `cargo run -p tr-dsp --example r4_check, quick`
//!     writes `sim/rx_backend/tb_rx_backend_scn.vh` (committed; `tests/r4_fixture.rs` checks it is
//!     current), the fixture `tools/check.sh` runs.
//! `cargo run --release -p tr-dsp --example r4_check, full <dir>`
//!     writes `<dir>/scn_<k>.vh` for the full scenarios plus `<dir>/exp_<k>_rx<r>.txt` (one output
//!     per line, "s0 s1 stamp_offset") for diffing against a testbench dump;
//!     `tools/run_r4_full.sh` runs them.
//! `cargo run -p tr-dsp --example r4_check, dump <dir>` writes the quick scenario's expected
//!     outputs the same way (`<dir>/exp_q_rx<r>.txt`).
//! `cargo run -p tr-dsp --example r4_check, chain <cycles> <file>` writes the receiver-bank ->
//!     back-end scenario include for `sim/rx_backend/r4_chain.v` (`tools/run_r4_full.sh` runs it).
//! `cargo run -p tr-dsp --example r4_check, trace <rx> [decim|post]` prints the quick
//!     scenario's 24 ksps channel-filter outputs (or decimator outputs, or post-processor
//!     intermediates) of one receiver, for tracing against `tb_rx_backend.v +trace=<rx>`.

#[path = "r4_common/scenario.rs"]
mod scenario;
#[path = "r4_common/chain.rs"]
mod chain;

use std::path::PathBuf;

fn repo() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn write_expected(dir: &PathBuf, tag: &str, res: &[scenario::RxResult]) {
    for (r, e) in res.iter().enumerate() {
        std::fs::write(dir.join(format!("exp_{tag}_rx{r}.txt")), e.lines.join("\n") + "\n").unwrap();
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(|s| s.as_str()) {
        Some("quick") => {
            let s = scenario::quick();
            let res = scenario::run(&s);
            let path = repo().join("sim/rx_backend/tb_rx_backend_scn.vh");
            std::fs::write(&path, scenario::emit_vh(&s, &res, "`cargo run -p tr-dsp --example r4_check -- quick`")).unwrap();
            for (r, e) in res.iter().enumerate() {
                println!("rx{r}: {} outputs, hash {:08x}", e.count, e.hash);
            }
            println!("wrote {}", path.display());
        }
        Some("full") => {
            let dir = PathBuf::from(args.get(2).expect("full <dir>"));
            std::fs::create_dir_all(&dir).unwrap();
            for (k, s) in scenario::full().iter().enumerate() {
                let res = scenario::run(s);
                std::fs::write(dir.join(format!("scn_{k}.vh")), scenario::emit_vh(s, &res, "`r4_check full`")).unwrap();
                write_expected(&dir, &k.to_string(), &res);
                let total: u64 = res.iter().map(|e| e.count).sum();
                println!("scenario {k} ({}): {total} outputs", s.name);
            }
        }
        Some("dump") => {
            let dir = PathBuf::from(args.get(2).expect("dump <dir>"));
            std::fs::create_dir_all(&dir).unwrap();
            let s = scenario::quick();
            write_expected(&dir, "q", &scenario::run(&s));
        }
        Some("chain") => {
            let cycles: usize = args.get(2).map(|s| s.parse().unwrap()).unwrap_or(chain::QUICK_CYCLES);
            let path = PathBuf::from(args.get(3).expect("chain <cycles> <file>"));
            let coeffs = tr_rxmodel::fir::load_coeffs_hex(&repo().join("rtl/rx/fir_coeffs.hex")).unwrap();
            let ch = chain::chain(cycles);
            let res = chain::run(&ch, &coeffs);
            std::fs::write(&path, chain::emit_vh(&ch, &res, "`cargo run -p tr-dsp --example r4_check -- chain`")).unwrap();
            for (r, e) in res.iter().enumerate() {
                println!("rx{r}: {} outputs, hash {:08x}", e.count, e.hash);
            }
            println!("wrote {}", path.display());
        }
        Some("trace") => {
            // 24 ksps channel-filter outputs of one receiver of the quick scenario
            let r: usize = args.get(2).expect("trace <rx>").parse().unwrap();
            let ident = args.get(3).map(|s| s == "decim").unwrap_or(false);
            let idb = tr_dsp::backend::CoefBank::identity();
            let s = scenario::quick();
            let spec = &s.rx[r];
            let banks: Vec<_> = s.banks.iter().map(|b| b.build()).collect();
            let mut rx = tr_dsp::backend::Receiver::new(spec.cfg);
            let mut stim = tr_dsp::backend::stim::Stim::new(spec.stim);
            for _ in 0..spec.n_in {
                let (i, q) = stim.next();
                let bank = match spec.swap {
                    Some((at, b)) if rx.n24 >= at as u64 => b,
                    _ => spec.bank,
                };
                rx.push(i, q, if ident { &idb } else { &banks[(r / 4) * 6 + bank as usize] });
                if let Some(y) = rx.last_y {
                    if args.get(3).map(|s| s == "post").unwrap_or(false) {
                        let t = rx.post_trace();
                        println!("P y {} {} M {} L {} a {} ga {} th {} fr {} dc {}", y.0, y.1, t[0], t[1], t[2], t[3], t[4], t[5], t[6]);
                    } else {
                        println!("{} {}", y.0, y.1);
                    }
                }
            }
        }
        _ => {
            eprintln!("usage: r4_check quick | full <dir> | dump <dir>");
            std::process::exit(2);
        }
    }
}
