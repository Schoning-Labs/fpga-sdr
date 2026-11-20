/* SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Franz Schöning, https://www.schoning.com
 *
 * Linker memory map for the real stage-0 loader. Unlike fw/tr-ae350/memory-ae350.x (a `BUILD_LOAD`
 * image that GDB loads whole into DDR3, as that file's own comment says), this one describes a
 * genuine XIP image: .text and .rodata execute directly from flash at their link address, because
 * stage-0 is the AE350 reset-vector code (MUG1029 table 16-12: reset vector 0x8000_0000) and nothing
 * has loaded it into RAM yet when it starts. See docs/C2_LOADER.md "Linker layout: XIP, not
 * BUILD_LOAD".
 *
 * Regions:
 * - FLASH: docs/ARCHITECTURE.md 5.4 "stage-0 loader (64 KB)" (docs/C2_LOADER.md "Flash layout").
 *   STAGE0_SIZE in fw/tr-loader-layout/src/lib.rs must equal this LENGTH, and a host test checks it.
 * - DLM (0xA020_0000, 64 KB, MUG1029 table 3-1): .data, .bss, heap and stack. The loader needs very
 *   little (no heap, a small stack, a few flag bytes of .data and .bss), so one region for all of
 *   them, the same pattern fw/tr-ae350/memory-qemu.x uses, is simpler than splitting it further.
 *
 * ramfunc-ae350.x (a second linker script with `INSERT AFTER .data`, which build.rs passes alongside
 * this one only under board-ae350) adds a `.ramfunc` output section that lives in a slice of this
 * same DLM region and has its load address in FLASH. See the module text of fw/tr-loader/src/flash.rs
 * for why the flash-programming primitives have to run from RAM and not from the flash chip they
 * are writing.
 */

MEMORY
{
  FLASH (rx) : ORIGIN = 0x80000000, LENGTH = 64K
  DLM   (rw) : ORIGIN = 0xA0200000, LENGTH = 64K
}

REGION_ALIAS("REGION_TEXT", FLASH);
REGION_ALIAS("REGION_RODATA", FLASH);
REGION_ALIAS("REGION_DATA", DLM);
REGION_ALIAS("REGION_BSS", DLM);
REGION_ALIAS("REGION_HEAP", DLM);
REGION_ALIAS("REGION_STACK", DLM);

/* MUG1031 3.1: single Andes A25 hart. */
_max_hart_id = 0;
/* Generous for a loader that only loops and polls, with no recursion and no large stack buffers
 * (the receive path copies UART bytes straight into DDR3 and never into a stack buffer, see
 * protocol.rs). */
_hart_stack_size = 8K;
_stack_start = ORIGIN(DLM) + LENGTH(DLM);
_heap_size = 0;
