/* SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Franz Schöning, https://www.schoning.com
 *
 * Linker memory map for the real Tang Mega 138K Pro dock (Gowin GW5AST-LV138, AE350 hard core).
 * Region names are riscv-rt's convention (REGION_TEXT etc.), picked up by fw/tr-ae350/build.rs.
 *
 * Addresses:
 * - DDR3 code/data region 0x0000_0000-0x00FF_FFFF and DLM 0xA020_0000: docs/ARCHITECTURE.md
 *   section 5.4 (memory map) and MUG1029 table 3-1 (DLM 0xA0200000-0xA020FFFF, 64 KB).
 * - ILM 0xA000_0000-0xA000FFFF (MUG1029 table 3-1) is reserved here but not wired into a region
 *   yet: ARCHITECTURE.md 5.4 keeps it for "trap vector and hot interrupt code if caches miss too
 *   often (measured first)", which is later work.
 *
 * This links a *development* image loaded into DDR3 by GDB/eBIOS (MUG1029 table 5-1,
 * BUILD_LOAD, SaG file ae350-ddr.sag), the first step of bring-up (a UART hello loaded by GDB, and
 * only then a boot from flash). The hardware reset vector is 0x8000_0000 (flash, MUG1029 table
 * 16-12); booting from flash goes through the stage-0 loader.
 *
 * DDR3 size: the default bitstream reaches the board's whole 1 GB,
 * 0x0000_0000-0x3FFF_FFFF (it repeats above, up to 0x7FFF_FFFF), so every DDR3 row of
 * docs/ARCHITECTURE.md 5.4 exists. DDR_FABRIC below is the part of that map above the heap: frame
 * buffers 0x1000_0000, waterfall rings 0x1100_0000, IQ/audio/TX rings 0x1200_0000, raw capture
 * 0x2000_0000-0x3FFF_FFFF. Nothing is linked into it; it is named here so the map is in one place.
 * The 256 MB fall-back bitstream (TR_DDR=256) has 0x0000_0000-0x0FFF_FFFF only: DDR_CODE and
 * DDR_HEAP are valid on it, DDR_FABRIC is not. tr_ae350::memprobe tells the two apart at start-up.
 */

MEMORY
{
  DDR_CODE (rwx) : ORIGIN = 0x00000000, LENGTH = 16M
  DDR_HEAP (rw)  : ORIGIN = 0x01000000, LENGTH = 240M
  DDR_FABRIC (rw) : ORIGIN = 0x10000000, LENGTH = 768M
  DLM (rw)       : ORIGIN = 0xA0200000, LENGTH = 64K
}

REGION_ALIAS("REGION_TEXT", DDR_CODE);
REGION_ALIAS("REGION_RODATA", DDR_CODE);
REGION_ALIAS("REGION_DATA", DDR_CODE);
REGION_ALIAS("REGION_BSS", DDR_CODE);
REGION_ALIAS("REGION_HEAP", DDR_HEAP);
REGION_ALIAS("REGION_STACK", DLM);

/* MUG1031 section 3.1: single Andes A25 hart (no SMP) -> riscv-rt "single-hart" feature, hart 0. */
_max_hart_id = 0;
/* Half of the 64 KB DLM; not measured, the benchmark harness is where real stack use on the board is to be measured. */
_hart_stack_size = 32K;
_stack_start = ORIGIN(DLM) + LENGTH(DLM);
/* C1's test binaries do not allocate; a real heap is set up by whichever crate needs one. */
_heap_size = 0;
