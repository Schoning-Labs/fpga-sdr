// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// A sample block round-trips: an iverilog testbench and a Rust test agree on every address and
// field. This is the Rust half; the Verilog half is
// sim/regmap/tb_example_regmap.v. Both check the generated output against the same numbers,
// transcribed by hand from hw/regmap/example.toml (docs/REGMAP.md documents the format); if
// `xtask regmap` ever produces something that drifts from the TOML for only one of the two
// languages, one of these two testbenches catches it.
//
// Needs the `mock` feature, turned on for test builds by tr-regs's own
// `[dev-dependencies]` self-reference (fw/tr-regs/Cargo.toml).

use tr_regs::generated::example;
use tr_regs::mock::MockRegisterSpace;
use tr_regs::RegisterSpace;

#[test]
fn block_base_and_size() {
    assert_eq!(example::BASE, 0xE8EE_0000);
    assert_eq!(example::SIZE, 0x0000_1000);
}

#[test]
fn id_is_read_only_at_its_reset_value() {
    assert_eq!(example::id::ADDR, 0x0000_0000);
    assert_eq!(example::id::RESET, 0x1CE5_0001);
    assert_eq!(example::id::addr(), 0xE8EE_0000);

    let regs = MockRegisterSpace::new(example::BASE);
    // The mock starts every word at 0; preload the documented reset value, as firmware would
    // find it after the fabric itself resets.
    regs.poke(example::id::addr(), example::id::RESET);
    assert_eq!(example::id::read(&regs), example::id::RESET);
}

#[test]
fn ctrl_fields_and_round_trip() {
    assert_eq!(example::ctrl::ADDR, 0x0000_0004);
    assert_eq!(example::ctrl::RESET, 0x0000_0000);
    assert_eq!(example::ctrl::ENABLE_LSB, 0);
    assert_eq!(example::ctrl::ENABLE_WIDTH, 1);
    assert_eq!(example::ctrl::MODE_LSB, 1);
    assert_eq!(example::ctrl::MODE_WIDTH, 2);

    let regs = MockRegisterSpace::new(example::BASE);

    // Reset state: both fields read back at their field reset (0).
    let v = example::ctrl::read(&regs);
    assert_eq!(v, example::ctrl::Value(example::ctrl::RESET));
    assert!(!v.enable());
    assert_eq!(v.mode(), 0);

    // Setting one field must not disturb the other, and the bit position must match the
    // Verilog side exactly: mode occupies bits [2:1], so mode = 3 sets bits 2 and 1 only.
    let v = v.with_enable(true).with_mode(3);
    example::ctrl::write(&regs, v);
    assert_eq!(regs.read32(example::ctrl::addr()), 0b111); // enable (bit 0) | mode=3 (bits 2:1)
    let v2 = example::ctrl::read(&regs);
    assert!(v2.enable());
    assert_eq!(v2.mode(), 3);

    // modify() is available: ctrl has no W1C fields.
    example::ctrl::modify(&regs, |v| v.with_enable(false));
    assert!(!example::ctrl::read(&regs).enable());
    assert_eq!(example::ctrl::read(&regs).mode(), 3, "modify() must not disturb the other field");
}

#[test]
fn status_w1c_fields_write_only_their_own_bit() {
    // `MockRegisterSpace` is a plain read/write memory cell (docs/REGMAP.md): unlike real W1C
    // hardware, its `write32` does not itself know to leave untouched bits alone, so this test
    // checks the thing that actually matters at the software boundary instead of relying on
    // the mock to emulate clear-on-write-1 silicon behaviour: that `clear_<field>()` writes
    // exactly that field's own mask, never a value built by reading the register first. A
    // generic read-modify-write `modify()` would instead write back whatever the *other* W1C
    // bits currently read as, which on real hardware clears them too -- exactly the hazard
    // `status` has no `modify()` to avoid (see fw/tr-regs/src/generated.rs).
    assert_eq!(example::status::ADDR, 0x0000_0008);
    assert_eq!(example::status::OVERFLOW_LSB, 0);
    assert_eq!(example::status::ERROR_LSB, 1);

    let regs = MockRegisterSpace::new(example::BASE);

    regs.poke(example::status::addr(), 0b11);
    example::status::clear_overflow(&regs);
    assert_eq!(
        regs.read32(example::status::addr()),
        1 << example::status::OVERFLOW_LSB,
        "clear_overflow() must write only its own bit's mask, regardless of error's current state"
    );

    regs.poke(example::status::addr(), 0b11);
    example::status::clear_error(&regs);
    assert_eq!(
        regs.read32(example::status::addr()),
        1 << example::status::ERROR_LSB,
        "clear_error() must write only its own bit's mask, regardless of overflow's current state"
    );
}

#[test]
fn channel_array_addressing_and_gain_field() {
    assert_eq!(example::channel::OFFSET, 0x0000_0010);
    assert_eq!(example::channel::STRIDE, 0x0000_0004);
    assert_eq!(example::channel::COUNT, 4);
    assert_eq!(example::channel::RESET, 0x0000_0080);
    assert_eq!(example::channel::GAIN_LSB, 0);
    assert_eq!(example::channel::GAIN_WIDTH, 8);

    // Every instance address, matching sim/regmap/tb_example_regmap.v exactly.
    assert_eq!(example::channel::addr(0), 0xE8EE_0010);
    assert_eq!(example::channel::addr(1), 0xE8EE_0014);
    assert_eq!(example::channel::addr(2), 0xE8EE_0018);
    assert_eq!(example::channel::addr(3), 0xE8EE_001C);

    let regs = MockRegisterSpace::new(example::BASE);
    for i in 0..example::channel::COUNT {
        regs.poke(example::channel::addr(i), example::channel::RESET);
    }

    // Writing one channel's gain must not touch its neighbours.
    example::channel::modify(&regs, 2, |v| v.with_gain(0x55));
    assert_eq!(example::channel::read(&regs, 2).gain(), 0x55);
    assert_eq!(example::channel::read(&regs, 0).gain(), 0x80, "channel 0 must be untouched");
    assert_eq!(example::channel::read(&regs, 1).gain(), 0x80, "channel 1 must be untouched");
    assert_eq!(example::channel::read(&regs, 3).gain(), 0x80, "channel 3 must be untouched");
}

#[test]
#[should_panic(expected = "index out of range")]
fn channel_array_index_out_of_range_panics() {
    let regs = MockRegisterSpace::new(example::BASE);
    let _ = example::channel::read(&regs, example::channel::COUNT);
}
