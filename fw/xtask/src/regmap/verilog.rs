// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Renders one validated `Block` as a Verilog `` `include `` file of `` `define `` macros, which
//! the RTL includes to get the block's base address, each register's offset, absolute address and
//! reset value, and each field's bit position, so that no address is typed into Verilog by hand.
//! The macro names are built from the upper-cased block, register and field names (for a block
//! `tx` with a register `ctrl` and a field `enable`: `TX_BASE`, `TX_CTRL_ADDR`,
//! `TX_CTRL_ENABLE_LSB`). The exact output is described in docs/REGMAP.md "Generated Verilog".
//!
//! The text is written line by line with `writeln!` into a `String`, which cannot fail, hence the
//! many `unwrap()` calls.

use super::model::Block;
use std::fmt::Write as _;

/// Returns the complete text of the `.vh` file for `block`: a header, an include guard, the
/// block's `_BASE` and `_SIZE`, then for every register its address macros (an array register
/// also gets `_STRIDE`, `_COUNT` and an `_ADDR(i)` macro that takes the instance number), its
/// reset value and the `_LSB`, `_MSB` and `_WIDTH` of each field.
pub fn render(block: &Block) -> String {
    let prefix = block.name.to_uppercase();
    let mut out = String::new();

    writeln!(out, "// SPDX-License-Identifier: Apache-2.0").unwrap();
    writeln!(out, "// Copyright 2026 Franz Schöning, https://www.schoning.com").unwrap();
    writeln!(out).unwrap();
    writeln!(
        out,
        "// GENERATED FILE -- do not edit by hand. Produced by `cargo run -p xtask -- regmap`"
    )
    .unwrap();
    writeln!(out, "// from hw/regmap/{}.toml. See docs/REGMAP.md.", block.name).unwrap();
    if !block.description.trim().is_empty() {
        writeln!(out, "//").unwrap();
        for line in block.description.trim().lines() {
            writeln!(out, "// {line}").unwrap();
        }
    }
    writeln!(out, "// status: {}", block.status).unwrap();
    writeln!(out).unwrap();

    // The include guard lets a module include the same file twice without redefining the macros.
    let guard = format!("SDR_REGMAP_{prefix}_VH");
    writeln!(out, "`ifndef {guard}").unwrap();
    writeln!(out, "`define {guard}").unwrap();
    writeln!(out).unwrap();

    writeln!(out, "`define {prefix}_BASE 32'h{:08X}", block.base).unwrap();
    writeln!(out, "`define {prefix}_SIZE 32'h{:08X}", block.size).unwrap();
    writeln!(out).unwrap();

    for reg in &block.registers {
        let reg_prefix = format!("{prefix}_{}", reg.name.to_uppercase());
        writeln!(out, "// {} -- {}", reg.name, one_line(&reg.description)).unwrap();
        if reg.is_array() {
            writeln!(
                out,
                "`define {reg_prefix}_OFFSET 32'h{:08X}",
                reg.offset
            )
            .unwrap();
            writeln!(out, "`define {reg_prefix}_STRIDE 32'h{:08X}", reg.stride).unwrap();
            writeln!(out, "`define {reg_prefix}_COUNT {}", reg.count).unwrap();
            writeln!(
                out,
                "`define {reg_prefix}_ADDR(i) (`{reg_prefix}_OFFSET + (i)*`{reg_prefix}_STRIDE)"
            )
            .unwrap();
            writeln!(
                out,
                "`define {reg_prefix}_ABS_ADDR(i) (`{prefix}_BASE + `{reg_prefix}_ADDR(i))"
            )
            .unwrap();
        } else {
            writeln!(out, "`define {reg_prefix}_ADDR 32'h{:08X}", reg.offset).unwrap();
            writeln!(
                out,
                "`define {reg_prefix}_ABS_ADDR (`{prefix}_BASE + `{reg_prefix}_ADDR)"
            )
            .unwrap();
        }
        writeln!(out, "`define {reg_prefix}_RESET 32'h{:08X}", reg.reset).unwrap();

        // A register without declared fields is one plain 32-bit value, so it has no field macros.
        if !reg.implicit_value_field {
            for field in &reg.fields {
                let field_prefix = format!("{reg_prefix}_{}", field.name.to_uppercase());
                writeln!(out, "`define {field_prefix}_LSB {}", field.lsb).unwrap();
                writeln!(out, "`define {field_prefix}_MSB {}", field.msb()).unwrap();
                writeln!(out, "`define {field_prefix}_WIDTH {}", field.width).unwrap();
            }
        }
        writeln!(out).unwrap();
    }

    writeln!(out, "`endif // {guard}").unwrap();

    out
}

/// First line of a description, for the one-line comment above each register; a placeholder when
/// the description is empty.
fn one_line(s: &str) -> String {
    let s = s.trim();
    if s.is_empty() {
        "(no description)".to_string()
    } else {
        s.lines().next().unwrap_or("").to_string()
    }
}
