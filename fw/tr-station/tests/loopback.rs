// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Host test of the loop-back self-test (`tr_station::selftest`), the same function
//! the QEMU image runs. A CQ goes out through the station logic, the encoder and the TX ring
//! driver, the simulated chip plays the ring and returns it as receiver audio, and the receive
//! path (ring reader, capture, slot cut by HL2 time, decoder) has to show it in the decode list.

use tr_fabric::mock::MockFabric;
use tr_station::selftest::{run, ScriptedUi};

#[test]
fn a_cq_goes_out_through_the_tx_ring_and_comes_back_through_the_receive_path() {
    let f = MockFabric::new();
    let mut text = String::new();
    let rep = run(&f, &mut ScriptedUi, &mut text);
    println!("{text}");
    assert!(rep.pass(), "{rep:?}");
    assert!(text.contains("transmit \"CQ K1XYZ FN42\" at 1500 Hz, 0 ms late"));
    assert_eq!(text.matches("ArmTx").count(), 1, "the TX path is switched on once, by the operator");
}

#[test]
fn freedv_goes_through_the_whole_station_path() {
    use tr_station::selftest::{run_freedv, ScriptedFdvUi};
    let f = MockFabric::new();
    let mut text = String::new();
    let rep = run_freedv(&f, 12, &mut ScriptedFdvUi, &mut text);
    println!("{text}");
    assert!(rep.pass(), "{rep:?}");
}
