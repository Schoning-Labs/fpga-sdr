/* SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Franz Schöning, https://www.schoning.com
 *
 * Memory map of the ladder program (fw/tr-ladder). It is the memory map of the loader, fw/tr-loader/memory-loader-ae350.x, with a
 * flash window of 1 MB instead of 64 KB. The image executes in place from the SPI flash: code and constants
 * run from the flash at the reset vector 0x8000_0000, and data, bss and the stack live in the 64 KB DLM (the
 * processor's local data memory) at 0xA020_0000. The programmer writes this image at chip offset 0x60_0000,
 * above the bitstream. There is no .ramfunc section because this program never writes the flash.
 * build.rs puts this file on the linker search path as memory.x, where riscv-rt's link.x picks it up.
 */

/* The two memory regions: execute-in-place flash, and the DLM for everything that is written. */
MEMORY
{
  FLASH (rx) : ORIGIN = 0x80000000, LENGTH = 1M
  DLM   (rw) : ORIGIN = 0xA0200000, LENGTH = 64K
}

/* Which region riscv-rt's link.x uses for each kind of section. */
REGION_ALIAS("REGION_TEXT", FLASH);
REGION_ALIAS("REGION_RODATA", FLASH);
REGION_ALIAS("REGION_DATA", DLM);
REGION_ALIAS("REGION_BSS", DLM);
REGION_ALIAS("REGION_HEAP", DLM);
REGION_ALIAS("REGION_STACK", DLM);

/* One hart, a 16 KB stack that grows down from the top of the DLM, and no heap (the program never allocates). */
_max_hart_id = 0;
_hart_stack_size = 16K;
_stack_start = ORIGIN(DLM) + LENGTH(DLM);
_heap_size = 0;
