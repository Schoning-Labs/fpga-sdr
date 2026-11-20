/* SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Franz Schöning, https://www.schoning.com
 *
 * The origin equals `qemu::DEST_BASE` (0x8040_0000) in fw/tr-loader/src/layout.rs, which is where
 * stage-0 puts a received image under QEMU, so this test payload has to be linked to run from there.
 * Its entry address (the `--entry` of `cargo run -p xtask -- image`, which defaults to the ELF entry)
 * is this same address, because riscv-rt's `_start` is the first thing in the image, as in every other
 * riscv-rt binary in this repository. The region lies clear of stage-0's own window
 * 0x8000_0000..0x8040_0000 (memory-loader-qemu.x), so stage-0 can never overwrite itself while
 * receiving it.
 */

MEMORY
{
  RAM (rwx) : ORIGIN = 0x80400000, LENGTH = 1M
}

REGION_ALIAS("REGION_TEXT", RAM);
REGION_ALIAS("REGION_RODATA", RAM);
REGION_ALIAS("REGION_DATA", RAM);
REGION_ALIAS("REGION_BSS", RAM);
REGION_ALIAS("REGION_HEAP", RAM);
REGION_ALIAS("REGION_STACK", RAM);

_max_hart_id = 0;
_hart_stack_size = 16K;
_stack_start = ORIGIN(RAM) + LENGTH(RAM);
_heap_size = 0;
