/* SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Franz Schöning, https://www.schoning.com
 *
 * Linker memory map for `qemu-system-riscv32 -M virt`. QEMU's virt machine puts DRAM at
 * 0x8000_0000 (its default load address for a `-kernel` ELF passed with `-bios none`, which is
 * how tools/qemu_c1.sh runs this).
 *
 * riscv-rt's `.stack` section (link.x.in) does `. = ABSOLUTE(_stack_start)`, i.e. it deliberately
 * leaves a NOLOAD gap between the end of .bss/.heap and the stack -- normally harmless (it is
 * just reserved address space, not real memory use), but it makes the ELF's last LOAD segment's
 * MemSiz equal to the whole declared RAM length. QEMU's virt machine places its generated device
 * tree right after that segment and refuses to boot if that leaves no room ("Not enough memory
 * to place DTB after kernel/initrd"). Keeping this region well under the `-m` size
 * tools/qemu_c1.sh passes (128M) leaves QEMU room for the DTB; 32M is far more than this smoke
 * test needs.
 */

MEMORY
{
  RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 32M
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
