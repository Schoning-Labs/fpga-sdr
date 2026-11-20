// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! 16550-compatible UART driver, generic over the register base address and the byte stride, so
//! the same code drives the UART2 of the AE350 (MUG1029 chapter 7: "Programmable timing compatible
//! with 16C550A UART", 4-byte register stride) and the ns16550a of the QEMU `virt` machine (1-byte
//! stride). Both have the same bit layout for the registers used here, which was checked bit for
//! bit for the LSR against MUG1029 table 7-18 (`ERRF` 7, `TEMT` 6, `THRE` 5, `LBreak` 4, `FE` 3,
//! `PE` 2, `OE` 1, `DR` 0) and matches the classic 16450/16550 LSR exactly.
//!
//! Only polled I/O and the one interrupt-enable bit the console needs are implemented: baud setup
//! through the divisor latch, FIFO enable and reset, transmit, receive, and the "received data
//! available" interrupt that goes through the PLIC. Modem control lines, DMA and the AE350-only
//! ID, HWCFG and OSC registers (MUG1029 offsets 0x00, 0x10 and 0x14) are not used and not
//! implemented.

use crate::board::UartLayout;
use core::ptr::{read_volatile, write_volatile};

// 16550 register numbers (not byte offsets: multiply by `layout.stride` for the address). The
// MUG1029 chapter 7 register descriptions give the offsets 0x20, 0x24, 0x28, 0x2C, 0x30, 0x34 and
// 0x38, all 4 apart: reg 0 = RBR (read), THR (write) and DLL (with DLAB = 1), reg 1 = IER and DLM
// (with DLAB = 1), reg 2 = IIR (read) and FCR (write), reg 3 = LCR, reg 4 = MCR, reg 5 = LSR and
// reg 6 = MSR.
const REG_RBR_THR_DLL: usize = 0;
const REG_IER_DLM: usize = 1;
const REG_IIR_FCR: usize = 2;
const REG_LCR: usize = 3;
#[allow(dead_code)]  // MCR (modem control) is not used by the console
const REG_MCR: usize = 4;
const REG_LSR: usize = 5;

// Line Status Register bits (MUG1029 Table 7-18).
const LSR_DR: u8 = 1 << 0; // data ready: a byte is waiting in RBR/RXFIFO
const LSR_THRE: u8 = 1 << 5; // transmit holding register (TXFIFO) empty: TX is ready

// Line Control Register bits (MUG1029 Table 7-15).
const LCR_DLAB: u8 = 1 << 7;
const LCR_WLS_8: u8 = 0b11; // word length select = 8 bits, no parity, 1 stop (WLS[1:0]=3, PEN=0, STB=0)

// FIFO Control Register bits (MUG1029 Table 7-12).
const FCR_FIFO_ENABLE: u8 = 1 << 0;
const FCR_RX_FIFO_RESET: u8 = 1 << 1;
const FCR_TX_FIFO_RESET: u8 = 1 << 2;

// Interrupt Enable Register bits (MUG1029 Table 7-7).
const IER_ERBI: u8 = 1 << 0; // "received data available" + character-timeout interrupt

/// Driver for one 16550-compatible UART, reached through its [`UartLayout`].
pub struct Uart {
    layout: &'static UartLayout,
}

impl Uart {
    /// # Safety
    /// `layout` must describe a real 16550-compatible UART at that address (true of both board
    /// modules in board.rs); the caller must not construct two `Uart`s over the same registers
    /// concurrently from different contexts (no locking here, this is a single-hart, mostly
    /// polled driver, see docs/C1_AE350.md).
    pub const unsafe fn new(layout: &'static UartLayout) -> Self {
        Uart { layout }
    }

    unsafe fn reg_addr(&self, reg: usize) -> *mut u8 {
        (self.layout.base + reg * self.layout.stride) as *mut u8
    }

    unsafe fn read_reg(&self, reg: usize) -> u8 {
        read_volatile(self.reg_addr(reg))
    }

    unsafe fn write_reg(&self, reg: usize, val: u8) {
        write_volatile(self.reg_addr(reg), val);
    }

    /// Programs 8N1 at `baud`, assuming the UART clock (`uclk`) input is `uclk_hz`. FIFOs are
    /// enabled and reset.
    ///
    /// The divisor is `uclk / (baud * 16)`, the standard 16550 relationship, with the OSC register
    /// left at its reset value of 0x10 = 16 (MUG1029 table 7-4). MUG1029 7.2.2 documents the divisor
    /// latch (DLL and DLM) and the Over Sample Control register (OSC, 0x14: "OSC = 0: ratio is 32;
    /// OSC >= 8: ratio is OSC") but never states the exact formula that ties `uclk`, the divisor
    /// and OSC to the baud rate, so a real terminal is the way to confirm it on a new board.
    pub fn init(&self, uclk_hz: u32, baud: u32) {
        const OVERSAMPLE: u32 = 16; // OSC reset value, MUG1029 Table 7-4
        let divisor = (uclk_hz / (baud * OVERSAMPLE)).max(1);
        unsafe {
            // FIFO enable + reset both FIFOs (MUG1029 Table 7-12).
            self.write_reg(
                REG_IIR_FCR,
                FCR_FIFO_ENABLE | FCR_RX_FIFO_RESET | FCR_TX_FIFO_RESET,
            );
            // Open the divisor latch, program it, close it again with 8N1 word format.
            self.write_reg(REG_LCR, LCR_DLAB);
            self.write_reg(REG_RBR_THR_DLL, (divisor & 0xff) as u8);
            self.write_reg(REG_IER_DLM, ((divisor >> 8) & 0xff) as u8);
            self.write_reg(REG_LCR, LCR_WLS_8);
            // No interrupts enabled yet; enable_rx_interrupt() turns on ERBI for the PLIC path.
            self.write_reg(REG_IER_DLM, 0);
        }
    }

    /// Blocks until the transmit holding register is free, then writes one byte.
    pub fn write_byte(&self, byte: u8) {
        unsafe {
            while self.read_reg(REG_LSR) & LSR_THRE == 0 {}
            self.write_reg(REG_RBR_THR_DLL, byte);
        }
    }

    /// Writes a string, sending a carriage return before every line feed.
    pub fn write_str(&self, s: &str) {
        for b in s.bytes() {
            if b == b'\n' {
                self.write_byte(b'\r');
            }
            self.write_byte(b);
        }
    }

    /// Non-blocking read: `Some(byte)` if the receiver has data, `None` otherwise.
    pub fn try_read_byte(&self) -> Option<u8> {
        unsafe {
            if self.read_reg(REG_LSR) & LSR_DR != 0 {
                Some(self.read_reg(REG_RBR_THR_DLL))
            } else {
                None
            }
        }
    }

    /// Enables the "received data available" interrupt (ERBI, MUG1029 Table 7-7), routed to the
    /// PLIC on both boards (see plic.rs and board::active::UART_IRQ on QEMU).
    pub fn enable_rx_interrupt(&self) {
        unsafe {
            self.write_reg(REG_LCR, self.read_reg(REG_LCR) & !LCR_DLAB); // DLAB=0: IER, not DLM
            self.write_reg(REG_IER_DLM, IER_ERBI);
        }
    }
}

// `Write` is implemented for `&Uart` and not for `Uart`, because the driver has no mutable state
// and `CONSOLE` below is a `static`, so a `&mut Uart` is not available. Callers write
//   let mut con = &tr_ae350::uart::CONSOLE;
//   writeln!(con, "mcause = {:#x}", mcause).ok();
// where the `let mut` belongs to the reference binding and not to the `Uart` itself.
impl core::fmt::Write for &Uart {
    fn write_str(&mut self, s: &str) -> core::fmt::Result {
        Uart::write_str(self, s);
        Ok(())
    }
}

/// The board's one console UART (AE350: UART2; QEMU: `virt`'s UART0), at its fixed address.
pub static CONSOLE: Uart = unsafe { Uart::new(&crate::board::active::UART) };
