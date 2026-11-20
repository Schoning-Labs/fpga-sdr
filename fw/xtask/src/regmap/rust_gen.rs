// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Renders every validated `Block` as the single `fw/tr-regs/src/generated.rs` file: one Rust
//! module per block, and inside it one module per register with its address constants and typed
//! accessors, all written against the `RegisterSpace` trait of `tr-regs` so the same code runs
//! on the real bus and on the mock used in host tests. A register with fields gets a `Value`
//! wrapper with one getter per field (and a `with_<field>` setter for each read-write field), a
//! plain register gets bare `u32` read and write functions. See docs/REGMAP.md "Generated Rust".
//!
//! The output is plain text built with `writeln!` into a `String` (which cannot fail, hence the
//! `unwrap()` calls). It is not formatted here, `regmap/mod.rs` runs it through `rustfmt`
//! afterwards.

use super::model::{Access, Block, Field, Register};
use std::fmt::Write as _;

/// Returns the text of the whole generated file for `blocks` (already sorted by name).
pub fn render(blocks: &[Block]) -> String {
    let mut out = String::new();

    writeln!(out, "// SPDX-License-Identifier: Apache-2.0").unwrap();
    writeln!(out, "// Copyright 2026 Franz Schöning, https://www.schoning.com").unwrap();
    writeln!(out).unwrap();
    writeln!(
        out,
        "// GENERATED FILE -- do not edit by hand. Produced by `cargo run -p xtask -- regmap`"
    )
    .unwrap();
    writeln!(out, "// from hw/regmap/*.toml. See docs/REGMAP.md.").unwrap();
    writeln!(out, "#![allow(dead_code, clippy::identity_op)]").unwrap();
    writeln!(out).unwrap();

    for block in blocks {
        render_block(&mut out, block);
    }

    out
}

/// Writes the module of one block: its documentation, `BASE` and `SIZE`, then one submodule for
/// each register.
fn render_block(out: &mut String, block: &Block) {
    writeln!(out, "/// `{}` register block (base {:#010x}).", block.name, block.base).unwrap();
    if !block.description.trim().is_empty() {
        writeln!(out, "///").unwrap();
        for line in block.description.trim().lines() {
            writeln!(out, "/// {line}").unwrap();
        }
    }
    writeln!(out, "/// status: {}", block.status).unwrap();
    writeln!(out, "pub mod {} {{", block.name).unwrap();
    writeln!(out, "    pub const BASE: u32 = 0x{:08X};", block.base).unwrap();
    writeln!(out, "    pub const SIZE: u32 = 0x{:08X};", block.size).unwrap();
    writeln!(out).unwrap();

    for reg in &block.registers {
        render_register(out, reg);
    }

    writeln!(out, "}}").unwrap();
    writeln!(out).unwrap();
}

/// Writes the submodule of one register: the address constants (an array register gets `OFFSET`,
/// `STRIDE` and `COUNT` and an `addr(index)` function that asserts the index is in range, a single
/// register gets `ADDR` and `addr()`), the reset value, and then the accessors.
fn render_register(out: &mut String, reg: &Register) {
    writeln!(out, "    /// `{}` -- {}", reg.name, one_line(&reg.description)).unwrap();
    writeln!(out, "    pub mod {} {{", reg.name).unwrap();
    writeln!(out, "        use crate::RegisterSpace;").unwrap();
    writeln!(out).unwrap();

    if reg.is_array() {
        writeln!(out, "        pub const OFFSET: u32 = 0x{:08X};", reg.offset).unwrap();
        writeln!(out, "        pub const STRIDE: u32 = 0x{:08X};", reg.stride).unwrap();
        writeln!(out, "        pub const COUNT: u32 = {};", reg.count).unwrap();
    } else {
        writeln!(out, "        pub const ADDR: u32 = 0x{:08X};", reg.offset).unwrap();
    }
    writeln!(out, "        pub const RESET: u32 = 0x{:08X};", reg.reset).unwrap();
    writeln!(out).unwrap();

    if reg.is_array() {
        writeln!(out, "        /// Absolute address of instance `index` (0..COUNT).").unwrap();
        writeln!(out, "        pub fn addr(index: u32) -> u32 {{").unwrap();
        writeln!(out, "            assert!(index < COUNT, \"{} index out of range\");", reg.name).unwrap();
        writeln!(out, "            super::BASE + OFFSET + index * STRIDE").unwrap();
        writeln!(out, "        }}").unwrap();
    } else {
        writeln!(out, "        /// Absolute address.").unwrap();
        writeln!(out, "        pub fn addr() -> u32 {{").unwrap();
        writeln!(out, "            super::BASE + ADDR").unwrap();
        writeln!(out, "        }}").unwrap();
    }
    writeln!(out).unwrap();

    if reg.implicit_value_field {
        render_plain_accessors(out, reg);
    } else {
        render_field_accessors(out, reg);
    }

    writeln!(out, "    }}").unwrap();
    writeln!(out).unwrap();
}

/// Accessors for a register without declared fields: raw `u32` values with no `Value` wrapper.
/// Which functions exist follows the access type: `read` always, `write` for read-write, and
/// `clear` (write-1-to-clear with a mask) for a register that is one bank of W1C bits.
fn render_plain_accessors(out: &mut String, reg: &Register) {
    let field = &reg.fields[0];
    let (idx_param, idx_call) = index_strs(reg);

    match field.access {
        Access::Ro => {
            writeln!(out, "        pub fn read<R: RegisterSpace>(r: &R{idx_param}) -> u32 {{").unwrap();
            writeln!(out, "            r.read32(addr({idx_call}))").unwrap();
            writeln!(out, "        }}").unwrap();
        }
        Access::Rw => {
            writeln!(out, "        pub fn read<R: RegisterSpace>(r: &R{idx_param}) -> u32 {{").unwrap();
            writeln!(out, "            r.read32(addr({idx_call}))").unwrap();
            writeln!(out, "        }}").unwrap();
            writeln!(out, "        pub fn write<R: RegisterSpace>(r: &R{idx_param}, value: u32) {{").unwrap();
            writeln!(out, "            r.write32(addr({idx_call}), value)").unwrap();
            writeln!(out, "        }}").unwrap();
        }
        Access::W1c => {
            writeln!(out, "        pub fn read<R: RegisterSpace>(r: &R{idx_param}) -> u32 {{").unwrap();
            writeln!(out, "            r.read32(addr({idx_call}))").unwrap();
            writeln!(out, "        }}").unwrap();
            writeln!(
                out,
                "        /// Write-1-to-clear every bit currently set (this register has no fields, so the",
            )
            .unwrap();
            writeln!(out, "        /// whole word is one W1C bank).").unwrap();
            writeln!(out, "        pub fn clear<R: RegisterSpace>(r: &R{idx_param}, mask: u32) {{").unwrap();
            writeln!(out, "            r.write32(addr({idx_call}), mask)").unwrap();
            writeln!(out, "        }}").unwrap();
        }
    }
}

/// `(param, call)` fragments for a register's optional array index: e.g. for an array,
/// `(", index: u32", "index")`; for a plain register, `("", "")`.
fn index_strs(reg: &Register) -> (&'static str, &'static str) {
    if reg.is_array() {
        (", index: u32", "index")
    } else {
        ("", "")
    }
}

/// Accessors for a register with declared fields: per-field `_LSB`, `_WIDTH`, `_MASK` and `_RESET`
/// constants, the `Value` wrapper with its getters and `with_` setters, then `read`, `write`
/// (when any field is writable) and either `modify` or `clear_<field>` functions. `modify` is a
/// read-modify-write, so it is only generated when every field is plain read-write; a register
/// with a write-1-to-clear field gets one `clear_<field>` function per such field instead.
fn render_field_accessors(out: &mut String, reg: &Register) {
    for f in &reg.fields {
        let fname = f.name.to_uppercase();
        writeln!(out, "        /// `{}` ({}) -- {}", f.name, f.access.as_str(), one_line(&f.description)).unwrap();
        writeln!(out, "        pub const {fname}_LSB: u32 = {};", f.lsb).unwrap();
        writeln!(out, "        pub const {fname}_WIDTH: u32 = {};", f.width).unwrap();
        writeln!(out, "        pub const {fname}_MASK: u32 = 0x{:08X};", f.mask()).unwrap();
        writeln!(out, "        pub const {fname}_RESET: u32 = 0x{:08X};", f.reset).unwrap();
    }
    writeln!(out).unwrap();

    writeln!(out, "        #[derive(Clone, Copy, Debug, PartialEq, Eq)]").unwrap();
    writeln!(out, "        pub struct Value(pub u32);").unwrap();
    writeln!(out).unwrap();
    writeln!(out, "        impl Value {{").unwrap();
    for f in &reg.fields {
        render_field_methods(out, f);
    }
    writeln!(out, "        }}").unwrap();
    writeln!(out).unwrap();

    let (idx_param, idx_call) = index_strs(reg);
    // `idx_call` prefixed with ", " for use as a trailing call argument (empty when not an array).
    let idx_call_arg = if reg.is_array() { format!(", {idx_call}") } else { String::new() };

    writeln!(out, "        pub fn read<R: RegisterSpace>(r: &R{idx_param}) -> Value {{").unwrap();
    writeln!(out, "            Value(r.read32(addr({idx_call})))").unwrap();
    writeln!(out, "        }}").unwrap();

    if reg.any_rw() {
        writeln!(out, "        pub fn write<R: RegisterSpace>(r: &R{idx_param}, value: Value) {{").unwrap();
        writeln!(out, "            r.write32(addr({idx_call}), value.0)").unwrap();
        writeln!(out, "        }}").unwrap();
    }

    if reg.all_rw() {
        // Safe read-modify-write only when nothing in the register is W1C.
        writeln!(
            out,
            "        pub fn modify<R: RegisterSpace>(r: &R{idx_param}, f: impl FnOnce(Value) -> Value) {{"
        )
        .unwrap();
        writeln!(out, "            write(r{idx_call_arg}, f(read(r{idx_call_arg})))").unwrap();
        writeln!(out, "        }}").unwrap();
    } else if reg.has_w1c() {
        writeln!(
            out,
            "        // No modify(): this register has a write-1-to-clear field, and a read-modify-write"
        )
        .unwrap();
        writeln!(
            out,
            "        // would clear every other set W1C bit at the same time. Use clear_<field>() instead."
        )
        .unwrap();
        for f in &reg.fields {
            if f.access == Access::W1c {
                writeln!(
                    out,
                    "        /// Write-1-to-clear `{}` only.",
                    f.name
                )
                .unwrap();
                writeln!(
                    out,
                    "        pub fn clear_{}<R: RegisterSpace>(r: &R{idx_param}) {{",
                    f.name
                )
                .unwrap();
                writeln!(
                    out,
                    "            r.write32(addr({idx_call}), {}_MASK << {}_LSB);",
                    f.name.to_uppercase(),
                    f.name.to_uppercase()
                )
                .unwrap();
                writeln!(out, "        }}").unwrap();
            }
        }
    }
}

/// Writes the methods of `Value` for one field: a getter (a `bool` for a one-bit field, a `u32`
/// otherwise) and, only for a read-write field, a `with_<field>` setter that returns a changed
/// copy with the other bits untouched.
fn render_field_methods(out: &mut String, f: &Field) {
    let fname = f.name.to_uppercase();
    let ty = if f.width == 1 { "bool" } else { "u32" };

    if f.width == 1 {
        writeln!(out, "            pub fn {}(self) -> bool {{", f.name).unwrap();
        writeln!(out, "                (self.0 >> {fname}_LSB) & 1 != 0").unwrap();
        writeln!(out, "            }}").unwrap();
    } else {
        writeln!(out, "            pub fn {}(self) -> u32 {{", f.name).unwrap();
        writeln!(out, "                (self.0 >> {fname}_LSB) & {fname}_MASK").unwrap();
        writeln!(out, "            }}").unwrap();
    }

    if f.access == Access::Rw {
        if f.width == 1 {
            writeln!(out, "            pub fn with_{}(self, v: {ty}) -> Self {{", f.name).unwrap();
            writeln!(out, "                let bit = (v as u32) << {fname}_LSB;").unwrap();
            writeln!(out, "                Value((self.0 & !({fname}_MASK << {fname}_LSB)) | bit)").unwrap();
            writeln!(out, "            }}").unwrap();
        } else {
            writeln!(out, "            pub fn with_{}(self, v: {ty}) -> Self {{", f.name).unwrap();
            writeln!(
                out,
                "                Value((self.0 & !({fname}_MASK << {fname}_LSB)) | ((v & {fname}_MASK) << {fname}_LSB))"
            )
            .unwrap();
            writeln!(out, "            }}").unwrap();
        }
    }
}

/// First line of a description, for the one-line doc comments in the generated file; a
/// placeholder when the description is empty.
fn one_line(s: &str) -> String {
    let s = s.trim();
    if s.is_empty() {
        "(no description)".to_string()
    } else {
        s.lines().next().unwrap_or("").to_string()
    }
}
