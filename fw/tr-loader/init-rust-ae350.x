/* SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Franz Schöning, https://www.schoning.com
 *
 * riscv-rt's `_start_rust` (the input section `.init.rust`) is not named in riscv-rt's link.x, so the
 * linker places it after the last code section, which with ramfunc-ae350.x is `.ramfunc`. That puts it
 * in DLM, and nothing in flash holds a copy of it, so on a cold start the reset code in flash would
 * jump into RAM that is still empty. QEMU runs everything from RAM and therefore does not show the
 * problem. This script pins `.init.rust` into flash right after `.text`
 * (see docs/C2_LOADER.md). It is also used by fw/tr-ladder, which has its own memory map and the same
 * start-up code.
 */
SECTIONS
{
  .init.rust : ALIGN(4)
  {
    KEEP(*(.init.rust));
  } > FLASH
} INSERT AFTER .text;
