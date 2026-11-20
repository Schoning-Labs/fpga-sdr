<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# Register map: format and generator

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

WP T3 (docs/PLAN.md). One source of truth for the fabric's memory-mapped registers
(docs/ARCHITECTURE.md 4.1): a TOML file per block in `hw/regmap/`, from which
`cargo run -p xtask -- regmap` generates a Verilog `` `include `` file of address/field macros
and the `tr-regs` Rust crate. Hand-kept copies are not allowed -- if a number in RTL or firmware
does not come from one of these generated files, it is wrong by definition.

## Files

```
hw/regmap/<block>.toml                  -- one file per fabric register block, hand-written
hw/regmap/generated/<block>_regs.vh     -- generated: Verilog `define macros
fw/tr-regs/src/generated.rs             -- generated: one Rust module per block
```

`<block>` is a lowercase snake_case name (`rx_bank`, `hl2_link`, ...) that becomes both the
Verilog macro prefix (upper-cased: `RX_BANK_...`) and the Rust module name.

Run the generator after editing any `hw/regmap/*.toml`:

```sh
cd fw && cargo run -p xtask -- regmap
```

`tools/check.sh` runs the same command and fails the build if it changes anything under
`hw/regmap/generated/` or `fw/tr-regs/src/generated.rs` that was not already committed -- see
"Why generated files are committed" below.

## TOML format

```toml
[block]
name = "rx_bank"          # lowercase snake_case; must be unique across hw/regmap/
base = 0xE803_0000        # must match docs/ARCHITECTURE.md 4.1
size = 0x0001_0000        # byte size of the block's address window (4.1: "one 64 KB page per block")
status = "draft"          # "test" | "draft" | "final" -- see below
description = "..."       # free text, becomes doc comments in both generated files

[[register]]
name = "ctrl"              # lowercase snake_case, unique within the block
offset = 0x004             # byte offset from base; must be a multiple of 4
count = 8                  # optional, default 1: this register repeats (an array)
stride = 0x008             # required when count > 1: byte distance between instances
description = "..."

[[register.field]]
name = "enable"             # lowercase snake_case, unique within the register
bits = "0"                  # a single bit, or "msb:lsb" e.g. "7:0"
access = "RW"                # "RW" | "RO" | "W1C"
reset = 0                    # value the field holds after reset, must fit in its width
description = "..."
```

A register with no `[[register.field]]` entries is shorthand for one implicit 32-bit field
named `value` spanning the whole word; give it `access` and `reset` directly instead (see
`our_mac_hi` in `hw/regmap/hl2_link.toml`, or `id` in any block, for examples). A register that
does have fields may not also set a register-level `access` or `reset`: its reset value is the
OR of its fields' individual resets, computed by the generator.

### Access types

- **RW** -- read/write. Ordinary control field.
- **RO** -- read-only. Hardware drives it; a write is ignored (the generator does not emit a
  setter for it).
- **W1C** -- write-1-to-clear. Hardware sets it; firmware clears it by writing a `1` to that bit
  specifically. Writing `0` to a W1C bit must leave it alone -- this is a real hardware property
  of the bit, not something the TOML or generator enforces, but it is why a register containing
  a W1C field gets no generic `modify()` in the generated Rust: a read-modify-write would read
  back whatever the *other* W1C bits currently hold and write that back too, clearing them as a
  side effect. See `hw/regmap/example.toml`'s `status` register and
  `fw/tr-regs/tests/example_regmap.rs` for the pattern this is guarding against, and why the
  generated `clear_<field>()` accessor always writes an isolated single-field mask instead.

### Validation the generator enforces

Any violation is a hard error (`cargo run -p xtask -- regmap` exits non-zero and names the
file):

- Block names are unique; block address ranges (`base` .. `base + size`) do not overlap.
- Register and field names are unique within their scope; both are lowercase snake_case.
- Register offsets, and `stride` when `count > 1`, are word-aligned (multiples of 4).
- Every register instance (`offset + i * stride` for `i` in `0..count`) fits inside the block's
  `size` and does not collide with any other register's instances in the same block.
- Field bit ranges fit within a 32-bit register and do not overlap another field in the same
  register.
- A field's `reset` value fits in its declared width.

### `status`

- `"test"` -- not a real fabric block; exists only to exercise the generator (`example.toml`).
- `"draft"` -- address and size are fixed by docs/ARCHITECTURE.md 4.1, but the register/field
  layout is this WP's proposal, not yet checked against the block's own RTL work package. The
  six blocks docs/ARCHITECTURE.md already describes registers for (`rx_bank`, `hl2_link`,
  `spectrum`, `video`, `audio`, `tx`) start this way; whoever builds that block's own WP edits
  its TOML file and moves it to `"final"` once the register port is real.
- `"final"` -- the layout is locked; RTL and firmware depend on it as written.

## Generated Verilog

`hw/regmap/generated/<block>_regs.vh`, guarded by `` `ifndef ``/`` `define `` so it can be
`` `include ``d from more than one module. Macros (all upper-case, `<REG>` and `<FIELD>` are the
TOML names upper-cased):

```verilog
`<BLOCK>_BASE                       // block base address
`<BLOCK>_SIZE                       // block size in bytes

`<BLOCK>_<REG>_ADDR                 // offset from base (plain register)
`<BLOCK>_<REG>_ABS_ADDR             // base + offset

`<BLOCK>_<REG>_OFFSET               // offset of instance 0 (array register: count > 1)
`<BLOCK>_<REG>_STRIDE               // byte distance between instances
`<BLOCK>_<REG>_COUNT                // number of instances
`<BLOCK>_<REG>_ADDR(i)               // offset of instance i
`<BLOCK>_<REG>_ABS_ADDR(i)           // base + offset of instance i

`<BLOCK>_<REG>_RESET                 // register reset value

`<BLOCK>_<REG>_<FIELD>_LSB            // field's least significant bit
`<BLOCK>_<REG>_<FIELD>_MSB            // field's most significant bit
`<BLOCK>_<REG>_<FIELD>_WIDTH          // field width in bits
```

A fieldless register (the implicit `value` field) gets `_ADDR`/`_RESET` but no
`_<FIELD>_*` macros, since there is nothing to name.

## Generated Rust

`fw/tr-regs/src/generated.rs`: one `pub mod <block>` per block, one nested `pub mod <register>`
per register. Every accessor is generic over the `RegisterSpace` trait (`fw/tr-regs/src/lib.rs`)
instead of touching memory directly, so the exact same generated code runs against `Mmio` (real
MMIO, AE350 target only) and against a `MockRegisterSpace` (host tests). This is what makes the
WP T3 done-test possible without hardware: `sim/regmap/tb_example_regmap.v` (iverilog) and
`fw/tr-regs/tests/example_regmap.rs` (`cargo test`) both check the generated output for
`hw/regmap/example.toml` against the same numbers, transcribed by hand from that TOML file into
each testbench.

Shape, per register:

- **Plain register, no fields** (`access` set directly): `read()` (if RO or RW), `write(value:
  u32)` (if RW), or `clear(mask: u32)` (if W1C, writes `mask` verbatim -- see the access-type
  note above on why this is not a read-modify-write).
- **Register with fields**: a `Value(pub u32)` wrapper type. Every field gets a getter
  (`fn <field>(self) -> bool` for a 1-bit field, `-> u32` otherwise); an RW field also gets
  `with_<field>(self, v) -> Self`. The register gets `read() -> Value`; `write(value: Value)` if
  any field is RW; `modify(f: impl FnOnce(Value) -> Value)` **only if every field is RW** (a
  read-modify-write is safe there); a register with any W1C field instead gets
  `clear_<field>()` per W1C field, each writing only that field's own bit(s).
- **Array register** (`count > 1`): every function above takes an extra `index: u32` parameter
  first, and there is an `addr(index) -> u32` helper. `addr()` (and every accessor) panics if
  `index >= COUNT`.

### `RegisterSpace` and the mock

```rust
pub trait RegisterSpace {
    fn read32(&self, addr: u32) -> u32;
    fn write32(&self, addr: u32, value: u32);
}
```

`tr_regs::Mmio` implements it with `core::ptr::read_volatile`/`write_volatile` against the
literal address -- only meaningful on the AE350 target, where the whole 128 MB fabric window is
mapped I/O. `tr_regs::mock::MockRegisterSpace` implements it with a fixed 64 KB array of `Cell<u32>`
(no `alloc`, so it stays `no_std`-compatible); construct one with `MockRegisterSpace::new(block::BASE)`
and it accepts any address inside that block's page.

The mock is a **plain memory cell**: `write32` overwrites the whole word, unlike real W1C
hardware which only clears the bits written as `1`. A test that cares about W1C behaviour should
check the value a `clear_<field>()` accessor writes (it must be exactly that field's own mask,
independent of the register's current contents) rather than relying on the mock to apply
clear-on-write-1 semantics -- see `fw/tr-regs/tests/example_regmap.rs`.

`mock` is a Cargo feature, off by default so it never reaches firmware; `fw/tr-regs/Cargo.toml`
turns it on for test builds only via a `[dev-dependencies]` self-reference (`tr-regs = { path =
".", features = ["mock"] }`). This also makes `tr_regs::mock` visible to `tests/*.rs`
integration tests, which -- unlike unit tests in `src/` -- link against the crate as an ordinary
dependency and would not otherwise see anything gated behind plain `#[cfg(test)]`.

## Why generated files are committed

Both `hw/regmap/generated/*.vh` and `fw/tr-regs/src/generated.rs` are committed rather than
produced at build time, because:

- RTL work (other WPs' `iverilog`/Gowin builds) needs the `.vh` files in place without those
  toolchains ever invoking Cargo.
- A `build.rs` that regenerates `tr-regs` on every `cargo build` would make the crate's public
  API a moving target depending on what happens to be in `hw/regmap/` at build time, which is
  surprising for a crate other crates depend on.

The risk this trades away is staleness: someone edits a `.toml` and forgets to regenerate.
`tools/check.sh` closes that gap -- it always reruns `cargo run -p xtask -- regmap` and fails if
that changes anything under either generated path that was not already the committed content
(`git status --porcelain` on those two paths, so a new file that was never committed is caught
the same as a changed one). In other words: generated files are committed, but never trusted
blindly -- every `check.sh` run re-derives them from the TOML and compares.

## Reset values that differ between the TOML and the chip

The `reset` values in the TOML files are what the generator turns into the `*_RESET` constants of the Verilog and Rust output, so they are kept as they are, but three registers of the chip as built start from a different value, and a reader who trusts the constants alone would be misled. The transmit baseband ring base (`TX RING_BASE`, TOML 0x1200_0000), the audio ring base (`AUDIO RING_BASE`, TOML 0x1200_0000) and the audio volume (`AUDIO VOLUME`, TOML 128) all reset to 0 in `rtl/top/block_regs.v`, and the firmware writes the volume at start-up and both ring addresses before it starts the engines. The video frame buffer base and stride (`VIDEO FB_BASE`, `FB_STRIDE`) need a remark too, although the chip does match the TOML there: the chip uses the compositor's own register file in `rtl/video/compositor.v`, which does reset to the TOML values 0x1000_0000 and 3,840, while the small unused `video_regs` module in `block_regs.v` resets both to 0. Each of these registers carries a comment in its TOML file saying the same.

## Example

`hw/regmap/example.toml` is not a real fabric block (`status = "test"`); it exists to exercise
every shape the format supports -- a read-only register, a read/write register with two fields,
a register with two independent W1C flags, and a small register array -- so the generator has
real material to run over and the WP T3 done-test has one block both toolchains can check
against. Its base address (`0xE8EE_0000`) is chosen to sit inside the fabric's 128 MB register
window (docs/ARCHITECTURE.md 4.1) but outside every real block's page, so it can never collide
with one.
