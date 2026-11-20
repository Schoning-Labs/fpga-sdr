/* SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Franz Schöning, https://www.schoning.com
 *
 * Extends riscv-rt's own link.x with a `.ramfunc` output section. link.x owns the top-level SECTIONS
 * block, so this file is not INCLUDEd by it; it is passed to the linker as its own -T and merged in
 * with the standard `INSERT AFTER` directive. The section holds code that must execute from DLM and
 * not from FLASH, because it drives the SPI flash controller directly (fw/tr-loader/src/flash.rs).
 * The load address (AT>) is FLASH, so the bytes are part of the stage-0 image, and the run address
 * (>) is DLM, so `flash::copy_ramfunc()` (called once when stage-0 starts, in the way riscv-rt itself
 * copies `.data`) can copy them there before anything calls into them. The script only matters under
 * board-ae350 (build.rs passes `-Tramfunc-ae350.x` for that feature only), since QEMU has no flash
 * controller to drive and `flash.rs` does not exist under board-qemu at all.
 *
 * The symbols `_ramfunc_start`, `_ramfunc_end` and `_ramfunc_lma` are the start and end of the
 * section in DLM and its address in flash, which is what the copy loop needs.
 */
SECTIONS
{
  .ramfunc : ALIGN(4)
  {
    _ramfunc_start = .;
    *(.ramfunc .ramfunc.*);
    . = ALIGN(4);
    _ramfunc_end = .;
  } > DLM AT> FLASH
  _ramfunc_lma = LOADADDR(.ramfunc);
} INSERT AFTER .data;
