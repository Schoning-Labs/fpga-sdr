// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The two representations of one `hw/regmap/*.toml` file.
//!
//! The first group of types (`BlockFile`, `BlockMeta`, `RegisterDef`, `FieldDef`) is exactly what
//! `serde` reads out of the TOML, with the numbers still as signed 64-bit values and the access
//! types still as strings. [`validate`] turns that into the second group (`Block`, `Register`,
//! `Field`, `Access`), where every number is a checked `u32`, a register without fields has been
//! given one implicit 32-bit field, and every address and bit position is known not to overlap
//! another one. The two generators (`verilog.rs` and `rust_gen.rs`) only ever see the second
//! group. The file format is described in docs/REGMAP.md.

use serde::Deserialize;
use std::collections::BTreeSet;

/// One whole TOML file: a `[block]` table and any number of `[[register]]` tables.
#[derive(Debug, Deserialize)]
pub struct BlockFile {
    pub block: BlockMeta,
    #[serde(rename = "register", default)]
    pub registers: Vec<RegisterDef>,
}

/// The `[block]` table: name, address page and a free-text description.
#[derive(Debug, Deserialize)]
pub struct BlockMeta {
    /// Lowercase snake_case, used for the Rust module name and as the Verilog macro prefix.
    pub name: String,
    /// Absolute byte address of the block's register page.
    pub base: i64,
    /// Size of the page in bytes; no register may lie outside it.
    pub size: i64,
    /// How settled the layout is (`"test"`, `"draft"` or `"final"`, see docs/REGMAP.md),
    /// copied into the generated files.
    pub status: String,
    #[serde(default)]
    pub description: String,
}

/// One `[[register]]` table as written. A register is either a plain 32-bit value (give it an
/// `access` and optionally a `reset`) or a set of bit fields (give it `[[register.field]]`
/// tables instead), and `count` and `stride` turn it into an array of identical registers.
#[derive(Debug, Deserialize)]
pub struct RegisterDef {
    pub name: String,
    /// Byte offset inside the block's page, word aligned.
    pub offset: i64,
    /// Number of instances; 1 (the default) means an ordinary single register.
    #[serde(default = "one")]
    pub count: i64,
    /// Byte distance between instances, required when `count` is more than 1 and refused
    /// otherwise.
    #[serde(default)]
    pub stride: Option<i64>,
    /// Only meaningful when `field` is empty: the whole register is one implicit
    /// 32-bit field named `value`.
    #[serde(default)]
    pub access: Option<String>,
    #[serde(default)]
    pub reset: Option<i64>,
    #[serde(default)]
    pub description: String,
    #[serde(rename = "field", default)]
    pub fields: Vec<FieldDef>,
}

/// Serde default for `RegisterDef::count`.
fn one() -> i64 {
    1
}

/// One `[[register.field]]` table as written.
#[derive(Debug, Deserialize)]
pub struct FieldDef {
    pub name: String,
    /// `"7:0"` (msb:lsb) or `"0"` (single bit).
    pub bits: String,
    /// `"RW"`, `"RO"` or `"W1C"`.
    pub access: String,
    /// Value after reset, unshifted (it has to fit in the field's width).
    #[serde(default)]
    pub reset: i64,
    #[serde(default)]
    pub description: String,
}

/// Access type of a field (and, for a fieldless register, of its one implicit field).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Access {
    /// Read and write.
    Rw,
    /// Read only; a write is ignored by the hardware.
    Ro,
    /// Write 1 to clear: reading gives the bit, writing a 1 clears it, writing a 0 does nothing.
    /// Typical for interrupt and error flags.
    W1c,
}

impl Access {
    /// Parses the spelling used in the TOML files (`RW`, `RO` or `W1C`).
    pub fn parse(s: &str) -> Result<Self, String> {
        match s {
            "RW" => Ok(Access::Rw),
            "RO" => Ok(Access::Ro),
            "W1C" => Ok(Access::W1c),
            other => Err(format!("unknown access type {other:?} (expected RW, RO or W1C)")),
        }
    }

    /// The TOML spelling again, used in the comments of the generated files.
    pub fn as_str(self) -> &'static str {
        match self {
            Access::Rw => "RW",
            Access::Ro => "RO",
            Access::W1c => "W1C",
        }
    }
}

/// A validated field: bit range, access, reset, mask (unshifted, i.e. covering `width` bits at
/// bit 0), description.
#[derive(Debug, Clone)]
pub struct Field {
    pub name: String,
    /// Bit position of the field's lowest bit.
    pub lsb: u32,
    /// Number of bits, 1 to 32.
    pub width: u32,
    pub access: Access,
    /// Reset value of the field alone, not shifted to `lsb`.
    pub reset: u32,
    pub description: String,
}

impl Field {
    /// Bit position of the field's highest bit.
    pub fn msb(&self) -> u32 {
        self.lsb + self.width - 1
    }

    /// Mask covering `width` bits at bit 0 (not shifted to `lsb`).
    pub fn mask(&self) -> u32 {
        if self.width >= 32 {
            u32::MAX
        } else {
            (1u32 << self.width) - 1
        }
    }
}

/// A validated register (or register array).
#[derive(Debug, Clone)]
pub struct Register {
    pub name: String,
    /// Byte offset of the first instance inside the block's page.
    pub offset: u32,
    /// Number of instances (1 for an ordinary register).
    pub count: u32,
    /// Byte distance between successive array instances; `4` (one word) when `count == 1`.
    pub stride: u32,
    /// Reset value of the whole word (the fields' reset values put in place).
    pub reset: u32,
    pub description: String,
    /// Always non-empty: a fieldless register is normalised to one implicit field named
    /// `value` spanning bits 31:0.
    pub fields: Vec<Field>,
    /// True when `fields` holds only that implicit `value` field, so the generators emit plain
    /// 32-bit accessors instead of per-field ones.
    pub implicit_value_field: bool,
}

impl Register {
    /// True for a register declared with `count` above 1.
    pub fn is_array(&self) -> bool {
        self.count > 1
    }

    /// True when at least one field is write-1-to-clear.
    pub fn has_w1c(&self) -> bool {
        self.fields.iter().any(|f| f.access == Access::W1c)
    }

    /// True when every field is read-write, which is the only case where a read-modify-write of
    /// the whole word is safe.
    pub fn all_rw(&self) -> bool {
        self.fields.iter().all(|f| f.access == Access::Rw)
    }

    /// True when at least one field can be written as a plain value.
    pub fn any_rw(&self) -> bool {
        self.fields.iter().any(|f| f.access == Access::Rw)
    }
}

/// A validated block: base/size plus its registers, with every address and bit position
/// checked for overlap.
#[derive(Debug, Clone)]
pub struct Block {
    pub name: String,
    /// Absolute byte address of the page.
    pub base: u32,
    /// Size of the page in bytes.
    pub size: u32,
    pub status: String,
    pub description: String,
    pub registers: Vec<Register>,
}

/// Parses a field's `bits` string (`"7:0"` as msb:lsb, or a single bit number) and returns
/// `(lsb, width)`.
fn parse_bits(bits: &str) -> Result<(u32, u32), String> {
    if let Some((hi, lo)) = bits.split_once(':') {
        let hi: u32 = hi.trim().parse().map_err(|_| format!("bad bit range {bits:?}"))?;
        let lo: u32 = lo.trim().parse().map_err(|_| format!("bad bit range {bits:?}"))?;
        if hi < lo {
            return Err(format!("bit range {bits:?} has msb below lsb"));
        }
        Ok((lo, hi - lo + 1))
    } else {
        let bit: u32 = bits.trim().parse().map_err(|_| format!("bad bit spec {bits:?}"))?;
        Ok((bit, 1))
    }
}

/// Checks one parsed TOML file and converts it to a [`Block`]. The rules are the ones listed in
/// docs/REGMAP.md "Validation the generator enforces": snake_case names, word-aligned addresses
/// that fit in 32 bits, no two fields sharing a bit, no two registers (or array instances)
/// sharing an address, every register inside the block's page, and resets that fit their field.
/// `source` is the file name and is put in front of every error message.
pub fn validate(file: BlockFile, source: &str) -> Result<Block, String> {
    let ctx = |msg: String| format!("{source}: {msg}");

    let name = file.block.name.clone();
    if name.is_empty() || !name.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_') {
        return Err(ctx(format!(
            "block name {name:?} must be lowercase snake_case (ascii a-z, 0-9, _)"
        )));
    }
    let base: u32 = u32::try_from(file.block.base).map_err(|_| ctx(format!("base {:#x} does not fit in 32 bits", file.block.base)))?;
    let size: u32 = u32::try_from(file.block.size).map_err(|_| ctx(format!("size {:#x} does not fit in 32 bits", file.block.size)))?;
    if base % 4 != 0 {
        return Err(ctx(format!("base {base:#010x} is not word-aligned")));
    }
    if size == 0 {
        return Err(ctx("size must be nonzero".to_string()));
    }

    let mut used_offsets: BTreeSet<u32> = BTreeSet::new();
    let mut used_names: BTreeSet<String> = BTreeSet::new();
    let mut registers = Vec::with_capacity(file.registers.len());

    for r in file.registers {
        if !used_names.insert(r.name.clone()) {
            return Err(ctx(format!("register {:?} defined twice", r.name)));
        }
        if r.name.is_empty() || !r.name.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_') {
            return Err(ctx(format!("register name {:?} must be lowercase snake_case", r.name)));
        }
        let offset: u32 = u32::try_from(r.offset).map_err(|_| ctx(format!("register {:?} offset does not fit in 32 bits", r.name)))?;
        if offset % 4 != 0 {
            return Err(ctx(format!("register {:?} offset {offset:#x} is not word-aligned", r.name)));
        }
        let count: u32 = u32::try_from(r.count).map_err(|_| ctx(format!("register {:?} count does not fit", r.name)))?;
        if count == 0 {
            return Err(ctx(format!("register {:?} count must be at least 1", r.name)));
        }
        let stride: u32 = match r.stride {
            Some(s) => u32::try_from(s).map_err(|_| ctx(format!("register {:?} stride does not fit", r.name)))?,
            None => 4,
        };
        if count > 1 {
            if stride == 0 || stride % 4 != 0 {
                return Err(ctx(format!(
                    "register {:?} has count > 1 so needs a nonzero word-aligned stride",
                    r.name
                )));
            }
        } else if r.stride.is_some() {
            return Err(ctx(format!("register {:?} sets stride but count is 1", r.name)));
        }

        // Fields, or one implicit 32-bit "value" field. The tuple also carries the register's
        // reset value, which is given directly for a fieldless register and otherwise built by
        // putting each field's reset value at its bit position.
        let (fields, implicit_value_field, reg_reset): (Vec<Field>, bool, u32) = if r.fields.is_empty() {
            let access_str = r.access.clone().ok_or_else(|| {
                ctx(format!("register {:?} has no fields, so needs a register-level access", r.name))
            })?;
            let access = Access::parse(&access_str).map_err(|e| ctx(format!("register {:?}: {e}", r.name)))?;
            let reset = r.reset.unwrap_or(0);
            let reset: u32 = u32::try_from(reset).map_err(|_| ctx(format!("register {:?} reset does not fit in 32 bits", r.name)))?;
            (
                vec![Field {
                    name: "value".to_string(),
                    lsb: 0,
                    width: 32,
                    access,
                    reset,
                    description: r.description.clone(),
                }],
                true,
                reset,
            )
        } else {
            if r.access.is_some() || r.reset.is_some() {
                return Err(ctx(format!(
                    "register {:?} has fields, so register-level access/reset are not allowed (reset is the OR of the field resets)",
                    r.name
                )));
            }
            // Which of the 32 bits some field has claimed already, to catch overlapping fields.
            let mut used_bits = [false; 32];
            let mut fields = Vec::with_capacity(r.fields.len());
            let mut field_names: BTreeSet<String> = BTreeSet::new();
            let mut computed_reset: u32 = 0;
            for f in &r.fields {
                if !field_names.insert(f.name.clone()) {
                    return Err(ctx(format!("register {:?} field {:?} defined twice", r.name, f.name)));
                }
                if f.name.is_empty() || !f.name.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_') {
                    return Err(ctx(format!("register {:?} field name {:?} must be lowercase snake_case", r.name, f.name)));
                }
                let (lsb, width) = parse_bits(&f.bits).map_err(|e| ctx(format!("register {:?} field {:?}: {e}", r.name, f.name)))?;
                if lsb + width > 32 {
                    return Err(ctx(format!(
                        "register {:?} field {:?} bits {:?} do not fit in a 32-bit register",
                        r.name, f.name, f.bits
                    )));
                }
                for b in lsb..lsb + width {
                    if used_bits[b as usize] {
                        return Err(ctx(format!(
                            "register {:?} field {:?} overlaps another field at bit {b}",
                            r.name, f.name
                        )));
                    }
                    used_bits[b as usize] = true;
                }
                let access = Access::parse(&f.access).map_err(|e| ctx(format!("register {:?} field {:?}: {e}", r.name, f.name)))?;
                let mask = if width >= 32 { u32::MAX } else { (1u32 << width) - 1 };
                let reset_u32: u32 = u32::try_from(f.reset)
                    .map_err(|_| ctx(format!("register {:?} field {:?} reset does not fit in 32 bits", r.name, f.name)))?;
                if reset_u32 & !mask != 0 {
                    return Err(ctx(format!(
                        "register {:?} field {:?} reset {reset_u32:#x} does not fit in {width} bit(s)",
                        r.name, f.name
                    )));
                }
                computed_reset |= reset_u32 << lsb;
                fields.push(Field {
                    name: f.name.clone(),
                    lsb,
                    width,
                    access,
                    reset: reset_u32,
                    description: f.description.clone(),
                });
            }
            // The generated code lists fields from the least significant bit up, whatever order
            // the TOML file gave them in.
            fields.sort_by_key(|f| f.lsb);
            (fields, false, computed_reset)
        };

        // Address-space overlap check across every instance of this register (and every other
        // register already placed in the block).
        for i in 0..count {
            let inst = offset + i * stride;
            let end = inst.checked_add(4).ok_or_else(|| ctx(format!("register {:?} instance {i} address overflows", r.name)))?;
            if end > size {
                return Err(ctx(format!(
                    "register {:?} instance {i} at offset {inst:#06x} falls outside the block's {size:#x}-byte page",
                    r.name
                )));
            }
            if !used_offsets.insert(inst) {
                return Err(ctx(format!("register {:?} instance {i} at offset {inst:#06x} overlaps another register", r.name)));
            }
        }

        registers.push(Register {
            name: r.name,
            offset,
            count,
            stride: if count > 1 { stride } else { 4 },
            reset: reg_reset,
            description: r.description,
            fields,
            implicit_value_field,
        });
    }

    Ok(Block {
        name,
        base,
        size,
        status: file.block.status,
        description: file.block.description,
        registers,
    })
}

/// Tests of [`validate`]: each one feeds a small TOML text to the parser and checks either the
/// resulting model or the wording of the error.
#[cfg(test)]
mod tests {
    use super::*;

    /// Parses `toml` and validates it the way the generator does, as file name `test.toml`.
    fn parse(toml: &str) -> Result<Block, String> {
        let file: BlockFile = toml::from_str(toml).map_err(|e| e.to_string())?;
        validate(file, "test.toml")
    }

    #[test]
    fn minimal_block_with_no_registers() {
        let block = parse(
            r#"
            [block]
            name = "empty"
            base = 0xE800_0000
            size = 0x1000
            status = "test"
            description = ""
            "#,
        )
        .unwrap();
        assert_eq!(block.registers.len(), 0);
    }

    #[test]
    fn fieldless_register_reset_out_of_range_is_rejected() {
        let err = parse(
            r#"
            [block]
            name = "b"
            base = 0xE800_0000
            size = 0x1000
            status = "test"
            description = ""

            [[register]]
            name = "r"
            offset = 0
            access = "RO"
            reset = 0x1_0000_0000
            "#,
        )
        .unwrap_err();
        assert!(err.contains("does not fit"), "{err}");
    }

    #[test]
    fn overlapping_fields_are_rejected() {
        let err = parse(
            r#"
            [block]
            name = "b"
            base = 0xE800_0000
            size = 0x1000
            status = "test"
            description = ""

            [[register]]
            name = "r"
            offset = 0

            [[register.field]]
            name = "a"
            bits = "3:0"
            access = "RW"
            reset = 0

            [[register.field]]
            name = "b"
            bits = "5:3"
            access = "RW"
            reset = 0
            "#,
        )
        .unwrap_err();
        assert!(err.contains("overlaps"), "{err}");
    }

    #[test]
    fn field_reset_too_wide_is_rejected() {
        let err = parse(
            r#"
            [block]
            name = "b"
            base = 0xE800_0000
            size = 0x1000
            status = "test"
            description = ""

            [[register]]
            name = "r"
            offset = 0

            [[register.field]]
            name = "a"
            bits = "1:0"
            access = "RW"
            reset = 7
            "#,
        )
        .unwrap_err();
        assert!(err.contains("does not fit in 2 bit"), "{err}");
    }

    #[test]
    fn array_register_computes_correct_reset_and_instance_addresses() {
        let block = parse(
            r#"
            [block]
            name = "b"
            base = 0xE800_0000
            size = 0x1000
            status = "test"
            description = ""

            [[register]]
            name = "ch"
            offset = 0x10
            count = 3
            stride = 0x4

            [[register.field]]
            name = "gain"
            bits = "7:0"
            access = "RW"
            reset = 0x80
            "#,
        )
        .unwrap();
        let reg = &block.registers[0];
        assert_eq!(reg.count, 3);
        assert_eq!(reg.stride, 4);
        assert_eq!(reg.offset, 0x10);
        assert_eq!(reg.reset, 0x80);
    }

    #[test]
    fn array_register_colliding_with_another_register_is_rejected() {
        let err = parse(
            r#"
            [block]
            name = "b"
            base = 0xE800_0000
            size = 0x1000
            status = "test"
            description = ""

            [[register]]
            name = "ch"
            offset = 0x10
            count = 4
            stride = 0x4
            access = "RW"
            reset = 0

            [[register]]
            name = "other"
            offset = 0x18
            access = "RW"
            reset = 0
            "#,
        )
        .unwrap_err();
        assert!(err.contains("overlaps another register"), "{err}");
    }

    #[test]
    fn register_outside_block_page_is_rejected() {
        let err = parse(
            r#"
            [block]
            name = "b"
            base = 0xE800_0000
            size = 0x10
            status = "test"
            description = ""

            [[register]]
            name = "r"
            offset = 0x10
            access = "RO"
            reset = 0
            "#,
        )
        .unwrap_err();
        assert!(err.contains("falls outside"), "{err}");
    }

    #[test]
    fn register_with_fields_rejects_explicit_access_or_reset() {
        let err = parse(
            r#"
            [block]
            name = "b"
            base = 0xE800_0000
            size = 0x1000
            status = "test"
            description = ""

            [[register]]
            name = "r"
            offset = 0
            access = "RW"

            [[register.field]]
            name = "a"
            bits = "0"
            access = "RW"
            reset = 0
            "#,
        )
        .unwrap_err();
        assert!(err.contains("register-level access/reset are not allowed"), "{err}");
    }

    #[test]
    fn misaligned_offset_is_rejected() {
        let err = parse(
            r#"
            [block]
            name = "b"
            base = 0xE800_0000
            size = 0x1000
            status = "test"
            description = ""

            [[register]]
            name = "r"
            offset = 2
            access = "RO"
            reset = 0
            "#,
        )
        .unwrap_err();
        assert!(err.contains("not word-aligned"), "{err}");
    }
}
