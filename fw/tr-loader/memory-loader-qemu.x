/* SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Franz Schöning, https://www.schoning.com
 *
 * Linker memory map for stage-0 under `qemu-system-riscv32 -M virt` (tools/qemu_c2.sh). QEMU's
 * virt machine has no flash model (docs/C2_LOADER.md "What ran under QEMU vs. what did not"), so
 * this is plain RAM at the `-kernel` load address (0x8000_0000, the same QEMU convention that
 * fw/tr-ae350/memory-qemu.x documents). It is not a real XIP layout, since QEMU has nothing to
 * execute in place from. The region is deliberately small (4 MiB) and ends where the window of
 * `qemu::DEST_BASE` (0x8040_0000) in fw/tr-loader/src/layout.rs begins: a received test image is
 * written to that separate window at run time (it is not linked here at all), so it can never
 * overlap stage-0's own code or stack while stage-0 is still running.
 */

MEMORY
{
  RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 4M
}

REGION_ALIAS("REGION_TEXT", RAM);
REGION_ALIAS("REGION_RODATA", RAM);
REGION_ALIAS("REGION_DATA", RAM);
REGION_ALIAS("REGION_BSS", RAM);
REGION_ALIAS("REGION_HEAP", RAM);
REGION_ALIAS("REGION_STACK", RAM);

_max_hart_id = 0;
_hart_stack_size = 64K;
_stack_start = ORIGIN(RAM) + LENGTH(RAM);
_heap_size = 0;
