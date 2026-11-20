// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The committed receiver back-end testbench fixture (`sim/rx_backend/tb_rx_backend_scn.vh`) must be
//! exactly what the bit-exact model produces today; otherwise the RTL testbench would compare the
//! RTL against a stale model. Regenerate with `cargo run -p tr-dsp --example r4_check, quick`.

#[path = "../examples/r4_common/scenario.rs"]
mod scenario;

#[test]
fn quick_fixture_is_current() {
    let s = scenario::quick();
    let res = scenario::run(&s);
    let want = scenario::emit_vh(&s, &res, "`cargo run -p tr-dsp --example r4_check -- quick`");
    let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../sim/rx_backend/tb_rx_backend_scn.vh");
    let have = std::fs::read_to_string(&path).unwrap_or_default().replace("\r\n", "\n");
    assert!(
        have == want,
        "{} is stale: run `cargo run -p tr-dsp --example r4_check -- quick`",
        path.display()
    );
}
