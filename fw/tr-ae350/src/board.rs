// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Board addresses, one module per board. Everything else in this crate is written against the
//! `Board` values below and not against literal addresses, so the same driver code (`uart.rs`,
//! `plic.rs`, `timer.rs`) runs on both the real AE350 and QEMU, which has its own UART, PLIC and
//! CLINT addresses.

#[cfg(all(feature = "board-ae350", feature = "board-qemu"))]
compile_error!("tr-ae350: enable exactly one of board-ae350 / board-qemu, not both");
#[cfg(not(any(feature = "board-ae350", feature = "board-qemu")))]
compile_error!("tr-ae350: enable exactly one of board-ae350 / board-qemu");

/// Fixed offsets of the four UART registers this crate uses, and the byte stride between
/// consecutive register numbers (both boards are 16550-compatible with identical bit layouts,
/// see uart.rs; only the base address and the stride differ).
/// Where the UART registers sit.
pub struct UartLayout {
    /// Address of register 0.
    pub base: usize,
    /// Byte distance between register N and register N+1 in 16550 numbering (reg 0 = RBR/THR/DLL,
    /// reg 1 = IER/DLM, reg 2 = IIR/FCR, reg 3 = LCR, reg 4 = MCR, reg 5 = LSR, reg 6 = MSR).
    pub stride: usize,
}

/// Standard RISC-V PLIC layout (priority array at +0, pending bitmap at +0x1000, per-context
/// enable bitmap at +0x2000 + context*0x80, per-context threshold/claim at
/// +0x20_0000 + context*0x1000). Confirmed identical on both boards (see docs/C1_AE350.md).
/// Where the PLIC sits.
pub struct PlicLayout {
    /// Base address of the PLIC.
    pub base: usize,
    /// PLIC context index for this hart's M-mode interrupt target (context 0 on both boards).
    pub context: usize,
}

/// The real board: Tang Mega 138K Pro with the AE350 soft CPU.
#[cfg(feature = "board-ae350")]
pub mod ae350 {
    use super::{PlicLayout, UartLayout};

    /// UART2 (docs/BOARD.md; MUG1029 table 3-1: `0xF030_0000-0xF03F_FFFF UART2`). UART1 exists at
    /// 0xF020_0000 but is not used, because ARCHITECTURE.md (5.1 and 5.2) names only a single
    /// "UART", which matches UART2 in MUG1029 table 3-1, and UART1 stays free for a JTAG or debug
    /// console.
    pub const UART: UartLayout = UartLayout {
        // The 16550 registers start at 0xF030_0020 (MUG1029-1.3E 7.2, table 7-1), and 0xF030_0000 is
        // only the base of the region. Measured on the board:
        // with 0xF030_0000 the transmitter-ready check reads another register and the first byte never
        // leaves, so the firmware waits forever. The register number times `stride` is added to this.
        base: 0xF030_0020,
        // MUG1029 chapter 7 register descriptions give literal byte offsets for each register:
        // RBR/THR/DLL at 0x20, IER/DLM at 0x24, IIR/FCR at 0x28, LCR at 0x2C, MCR at 0x30, LSR at
        // 0x34, MSR at 0x38, a constant 4-byte stride from reg 0 (0x20) to reg 6 (0x38).
        stride: 4,
    };

    /// MUG1029 table 3-1: `0xE400_0000-0xE5FF_FFFF PLIC`.
    pub const PLIC: PlicLayout = PlicLayout {
        base: 0xE400_0000,
        // MUG1029 and MUG1031 give the PLIC address range (table 3-1) and the interrupt source table
        // (table 4-2) but do not spell out the internal register layout or the mapping of contexts to
        // harts and modes. Context 0 is hart 0 in machine mode by the usual PLIC convention, which
        // is also what other Andes core BSPs assume, so this crate uses it, and it is worth
        // confirming on the board.
        context: 0,
    };

    /// MUG1029 table 3-1: `0xE600_0000-0xE60F_FFFF Machine Timer` (PLMT, chapter 15). Table 15-1:
    /// mtime at offset 0x00 (lo) / 0x04 (hi); mtimecmp0 (hart 0) at 0x08 (lo) / 0x0C (hi).
    pub const TIMER_BASE: usize = 0xE600_0000;

    /// Tick rate of the machine timer. MUG1029 15.1.2 only says that `mtime_clk` can run at any
    /// frequency and often shares the RTC clock source, and no board-specific value is given in the
    /// sources behind BOARD.md. This is a placeholder (`clk_ahb`, 80 MHz, from ARCHITECTURE.md
    /// section 2, the nearest documented clock) until it is read back from the hardware or from the
    /// Gowin AE350 IP (.ipc) configuration file. `timer::now()` and `timer::arm_after()` work in
    /// ticks and not in seconds, so nothing in the logic of this crate depends on the value, and
    /// only the worked examples in `docs/C1_AE350.md` turn it into seconds for illustration.
    pub const TIMER_HZ: u32 = 80_000_000;

    /// Input clock of UART2, which sits on the APB bus, 80 MHz. No document says which clock
    /// feeds the UART divider, so this is the assumed value: the ladder program (`fw/tr-ladder`)
    /// finds out on the board, and this constant is then set to what it reports (`docs/LADDER.md`).
    pub const UART_CLOCK_HZ: u32 = 80_000_000;
}

/// QEMU `virt` machine, used to run the target-independent parts of the crate without the board.
#[cfg(feature = "board-qemu")]
pub mod qemu {
    use super::{PlicLayout, UartLayout};

    /// QEMU riscv `virt` machine, ns16550a at 0x1000_0000 (hw/riscv/virt.c `VIRT_UART0`), with plain
    /// byte-addressed 8250/16550 registers (reg-shift 0), so the stride is 1 and not the 4 of the AE350.
    pub const UART: UartLayout = UartLayout {
        base: 0x1000_0000,
        stride: 1,
    };

    /// QEMU riscv `virt` machine PLIC at 0x0c00_0000 (hw/riscv/virt.c `VIRT_PLIC`). Context 0 is
    /// hart 0 M-mode (QEMU numbers M-mode before S-mode per hart); this binary never drops to
    /// S-mode, so context 0 is right for meip.
    pub const PLIC: PlicLayout = PlicLayout {
        base: 0x0c00_0000,
        context: 0,
    };
    /// QEMU riscv `virt` machine UART0 PLIC source (hw/riscv/virt.c `VIRT_UART0_IRQ`).
    pub const UART_IRQ: u32 = 10;

    /// QEMU riscv `virt` machine CLINT at 0x0200_0000 (hw/riscv/virt.c `VIRT_CLINT`), standard
    /// SiFive CLINT layout: msip0 at +0x0000, mtimecmp0 at +0x4000 (8 bytes), mtime at +0xBFF8
    /// (8 bytes), a different layout from the AE350's PLMT (see timer.rs).
    pub const CLINT_BASE: usize = 0x0200_0000;

    /// QEMU's virt machine timebase-frequency is 10 MHz (its generated device tree property
    /// `timebase-frequency = <0x989680>`), fixed by QEMU regardless of `-icount`/host speed.
    pub const TIMER_HZ: u32 = 10_000_000;

    /// QEMU's ns16550a does not rate-limit by the divisor; any value will do.
    pub const UART_CLOCK_HZ: u32 = 24_000_000;

    /// QEMU's "SiFive test finisher" (hw/misc/sifive_test.c) at 0x10_0000: writing the status
    /// word in the low 16 bits (FINISHER_PASS/FAIL/RESET), with an exit code in the high 16 bits
    /// for FAIL, shuts the emulator down instead of leaving it spinning. Used only by
    /// tools/qemu_c1.sh's test binary (src/bin/qemu_smoke.rs), never linked into the real
    /// firmware.
    pub const TEST_FINISHER: usize = 0x10_0000;
    /// Status word that makes the test finisher report success.
    pub const FINISHER_PASS: u32 = 0x5555;
    /// Status word that makes the test finisher report failure.
    pub const FINISHER_FAIL: u32 = 0x3333;

    /// Shuts QEMU down with a success status. Used by tools/qemu_c1.sh's test binary once every
    /// check (UART, timer interrupt, illegal-instruction trap) has passed, so the script does
    /// not have to rely on a timeout to know the run finished. The return type is `!` because no
    /// instruction after this write ever runs (QEMU exits synchronously on it), and the loop is
    /// there in case it somehow did not.
    pub fn exit_pass() -> ! {
        unsafe { core::ptr::write_volatile(TEST_FINISHER as *mut u32, FINISHER_PASS) };
        loop {
            riscv::asm::wfi();
        }
    }

    /// Shuts QEMU down reporting failure, with `code` as the process exit status.
    pub fn exit_fail(code: u16) -> ! {
        let value = FINISHER_FAIL | ((code as u32) << 16);
        unsafe { core::ptr::write_volatile(TEST_FINISHER as *mut u32, value) };
        loop {
            riscv::asm::wfi();
        }
    }
}

/// The board that was selected with the Cargo feature.
#[cfg(feature = "board-ae350")]
pub use ae350 as active;
#[cfg(feature = "board-qemu")]
pub use qemu as active;
