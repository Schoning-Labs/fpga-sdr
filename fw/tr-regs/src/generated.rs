// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

// GENERATED FILE -- do not edit by hand. Produced by `cargo run -p xtask -- regmap`
// from hw/regmap/*.toml. See docs/REGMAP.md.
#![allow(dead_code, clippy::identity_op)]

/// `audio` register block (base 0xe8090000).
///
/// Audio engine (docs/ARCHITECTURE.md 3.7): ring pointers for the 48 kHz stereo ring firmware
/// writes, PT8211 output volume, and low-water status. The ring's sample storage is in DDR3
/// (5.4); this block is pointers and control only.
/// status: draft
pub mod audio {
    pub const BASE: u32 = 0xE8090000;
    pub const SIZE: u32 = 0x00010000;

    /// `id` -- Block identifier/version: 'AU' + version 1 (set by the chip top level).
    pub mod id {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000000;
        pub const RESET: u32 = 0x41550001;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `ctrl` -- Output enable.
    pub mod ctrl {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000004;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `enable` (RW) -- 1 = PT8211 and HDMI audio paths running from the ring.
        pub const ENABLE_LSB: u32 = 0;
        pub const ENABLE_WIDTH: u32 = 1;
        pub const ENABLE_MASK: u32 = 0x00000001;
        pub const ENABLE_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn enable(self) -> bool {
                (self.0 >> ENABLE_LSB) & 1 != 0
            }
            pub fn with_enable(self, v: bool) -> Self {
                let bit = (v as u32) << ENABLE_LSB;
                Value((self.0 & !(ENABLE_MASK << ENABLE_LSB)) | bit)
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `ring_base` -- Ring base address in DDR3 (docs/ARCHITECTURE.md 5.4: within the 0x1200_0000 IQ/audio/TX ring region).
    pub mod ring_base {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000008;
        pub const RESET: u32 = 0x12000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
        pub fn write<R: RegisterSpace>(r: &R, value: u32) {
            r.write32(addr(), value)
        }
    }

    /// `ring_size` -- Ring size in stereo sample frames (power of two).
    pub mod ring_size {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x0000000C;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
        pub fn write<R: RegisterSpace>(r: &R, value: u32) {
            r.write32(addr(), value)
        }
    }

    /// `ring_wptr` -- Write pointer, in frames. Written by firmware after it writes back the new samples' cache lines (docs/ARCHITECTURE.md 4.2, CPU-written ring).
    pub mod ring_wptr {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000010;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
        pub fn write<R: RegisterSpace>(r: &R, value: u32) {
            r.write32(addr(), value)
        }
    }

    /// `ring_rptr` -- Read pointer, in frames. Updated by the fabric consumer; firmware reads it to know how much room remains before overrunning it.
    pub mod ring_rptr {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000014;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `volume` -- Output volume, 0-255 linear (ARCHITECTURE 3.7: the PT8211 itself has no volume control).
    pub mod volume {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000018;
        pub const RESET: u32 = 0x00000080;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
        pub fn write<R: RegisterSpace>(r: &R, value: u32) {
            r.write32(addr(), value)
        }
    }

    /// `status` -- Sticky low-water flag, matching fabric interrupt line 3 (ARCHITECTURE 4.3).
    pub mod status {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x0000001C;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `low_water` (W1C) -- Set when the ring fill drops below the low-water mark; cleared by firmware writing 1 after refilling.
        pub const LOW_WATER_LSB: u32 = 0;
        pub const LOW_WATER_WIDTH: u32 = 1;
        pub const LOW_WATER_MASK: u32 = 0x00000001;
        pub const LOW_WATER_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn low_water(self) -> bool {
                (self.0 >> LOW_WATER_LSB) & 1 != 0
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        // No modify(): this register has a write-1-to-clear field, and a read-modify-write
        // would clear every other set W1C bit at the same time. Use clear_<field>() instead.
        /// Write-1-to-clear `low_water` only.
        pub fn clear_low_water<R: RegisterSpace>(r: &R) {
            r.write32(addr(), LOW_WATER_MASK << LOW_WATER_LSB);
        }
    }

    /// `out_ctrl` -- Digital audio outputs (docs/AUDIO_OUT.md). They carry the engine's 48 kHz stream, zeros while the engine is off or its ring is empty.
    pub mod out_ctrl {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000020;
        pub const RESET: u32 = 0x00000003;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `spdif` (RW) -- 1 = S/PDIF output on PMOD2 pin 12 (B21) running; 0 = pin low.
        pub const SPDIF_LSB: u32 = 0;
        pub const SPDIF_WIDTH: u32 = 1;
        pub const SPDIF_MASK: u32 = 0x00000001;
        pub const SPDIF_RESET: u32 = 0x00000001;
        /// `i2s` (RW) -- 1 = I2S output on PMOD2 pins 9, 10, 7, 8 (bit clock, word clock, data, master clock) running; 0 = pins low.
        pub const I2S_LSB: u32 = 1;
        pub const I2S_WIDTH: u32 = 1;
        pub const I2S_MASK: u32 = 0x00000001;
        pub const I2S_RESET: u32 = 0x00000001;
        /// `tone` (RW) -- 1 = S/PDIF, I2S and HDMI audio carry a 1 kHz test tone (-4.3 dBFS, both channels) instead of the stream. Needs neither the engine nor DDR3. The PT8211 path is not affected.
        pub const TONE_LSB: u32 = 2;
        pub const TONE_WIDTH: u32 = 1;
        pub const TONE_MASK: u32 = 0x00000001;
        pub const TONE_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn spdif(self) -> bool {
                (self.0 >> SPDIF_LSB) & 1 != 0
            }
            pub fn with_spdif(self, v: bool) -> Self {
                let bit = (v as u32) << SPDIF_LSB;
                Value((self.0 & !(SPDIF_MASK << SPDIF_LSB)) | bit)
            }
            pub fn i2s(self) -> bool {
                (self.0 >> I2S_LSB) & 1 != 0
            }
            pub fn with_i2s(self, v: bool) -> Self {
                let bit = (v as u32) << I2S_LSB;
                Value((self.0 & !(I2S_MASK << I2S_LSB)) | bit)
            }
            pub fn tone(self) -> bool {
                (self.0 >> TONE_LSB) & 1 != 0
            }
            pub fn with_tone(self, v: bool) -> Self {
                let bit = (v as u32) << TONE_LSB;
                Value((self.0 & !(TONE_MASK << TONE_LSB)) | bit)
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `out_status` -- State of the digital outputs. The two counters wrap at 255.
    pub mod out_status {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000024;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `pll_lock` (RO) -- 1 = the audio PLL (49.152 MHz) is locked.
        pub const PLL_LOCK_LSB: u32 = 0;
        pub const PLL_LOCK_WIDTH: u32 = 1;
        pub const PLL_LOCK_MASK: u32 = 0x00000001;
        pub const PLL_LOCK_RESET: u32 = 0x00000000;
        /// `run` (RO) -- 1 = S/PDIF and I2S are sending samples (their 8-sample buffer has filled); 0 = they send zeros.
        pub const RUN_LSB: u32 = 1;
        pub const RUN_WIDTH: u32 = 1;
        pub const RUN_MASK: u32 = 0x00000001;
        pub const RUN_RESET: u32 = 0x00000000;
        /// `live` (RO) -- 1 = the last 48 kHz sample came from the audio engine; 0 = the engine delivers nothing and zeros (or the tone) are sent at exactly 48 kHz.
        pub const LIVE_LSB: u32 = 2;
        pub const LIVE_WIDTH: u32 = 1;
        pub const LIVE_MASK: u32 = 0x00000001;
        pub const LIVE_RESET: u32 = 0x00000000;
        /// `slips` (RO) -- Number of slips: one sample taken out or put in over 64 frames by blending, because the stream's 48 kHz and the audio PLL's differ (expected: one every 17 minutes).
        pub const SLIPS_LSB: u32 = 8;
        pub const SLIPS_WIDTH: u32 = 8;
        pub const SLIPS_MASK: u32 = 0x000000FF;
        pub const SLIPS_RESET: u32 = 0x00000000;
        /// `errors` (RO) -- Number of buffer overruns or underruns between the stream and the audio clock (a sample lost or the reader restarted). Expected: 0.
        pub const ERRORS_LSB: u32 = 16;
        pub const ERRORS_WIDTH: u32 = 8;
        pub const ERRORS_MASK: u32 = 0x000000FF;
        pub const ERRORS_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn pll_lock(self) -> bool {
                (self.0 >> PLL_LOCK_LSB) & 1 != 0
            }
            pub fn run(self) -> bool {
                (self.0 >> RUN_LSB) & 1 != 0
            }
            pub fn live(self) -> bool {
                (self.0 >> LIVE_LSB) & 1 != 0
            }
            pub fn slips(self) -> u32 {
                (self.0 >> SLIPS_LSB) & SLIPS_MASK
            }
            pub fn errors(self) -> u32 {
                (self.0 >> ERRORS_LSB) & ERRORS_MASK
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
    }
}

/// `blink` register block (base 0xe80b0000).
///
/// Board link on SFP1 (docs/SFP_LINKS.md section 5): the HL2 sample stream to a second board, control
/// words for the two CPUs, status and counters, and the switch that feeds the receivers of this board
/// from the link. rtl/blink/blink_top.v. All in clk_dsp.
/// status: draft
pub mod blink {
    pub const BASE: u32 = 0xE80B0000;
    pub const SIZE: u32 = 0x00010000;

    /// `id` -- Block identifier: BL + version 1.
    pub mod id {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000000;
        pub const RESET: u32 = 0x424C0001;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `ctrl` -- Board link settings.
    pub mod ctrl {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000004;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `enable` (RW) -- 0 = link logic held in reset, counters cleared.
        pub const ENABLE_LSB: u32 = 0;
        pub const ENABLE_WIDTH: u32 = 1;
        pub const ENABLE_MASK: u32 = 0x00000001;
        pub const ENABLE_RESET: u32 = 0x00000000;
        /// `send_samples` (RW) -- 1 = send the HL2 sample stream of this board over the link (board 1).
        pub const SEND_SAMPLES_LSB: u32 = 1;
        pub const SEND_SAMPLES_WIDTH: u32 = 1;
        pub const SEND_SAMPLES_MASK: u32 = 0x00000001;
        pub const SEND_SAMPLES_RESET: u32 = 0x00000000;
        /// `rx_from_link` (RW) -- 1 = receiver bank, zoom, spectrum and FT8 take the sample stream of the link instead of the HL2 link (board 2). Switch with the receivers disabled.
        pub const RX_FROM_LINK_LSB: u32 = 2;
        pub const RX_FROM_LINK_WIDTH: u32 = 1;
        pub const RX_FROM_LINK_MASK: u32 = 0x00000001;
        pub const RX_FROM_LINK_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn enable(self) -> bool {
                (self.0 >> ENABLE_LSB) & 1 != 0
            }
            pub fn with_enable(self, v: bool) -> Self {
                let bit = (v as u32) << ENABLE_LSB;
                Value((self.0 & !(ENABLE_MASK << ENABLE_LSB)) | bit)
            }
            pub fn send_samples(self) -> bool {
                (self.0 >> SEND_SAMPLES_LSB) & 1 != 0
            }
            pub fn with_send_samples(self, v: bool) -> Self {
                let bit = (v as u32) << SEND_SAMPLES_LSB;
                Value((self.0 & !(SEND_SAMPLES_MASK << SEND_SAMPLES_LSB)) | bit)
            }
            pub fn rx_from_link(self) -> bool {
                (self.0 >> RX_FROM_LINK_LSB) & 1 != 0
            }
            pub fn with_rx_from_link(self, v: bool) -> Self {
                let bit = (v as u32) << RX_FROM_LINK_LSB;
                Value((self.0 & !(RX_FROM_LINK_MASK << RX_FROM_LINK_LSB)) | bit)
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `status` -- Board link state.
    pub mod status {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000008;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `aligned` (RO) -- The comma aligner of lane 1 is locked.
        pub const ALIGNED_LSB: u32 = 0;
        pub const ALIGNED_WIDTH: u32 = 1;
        pub const ALIGNED_MASK: u32 = 0x00000001;
        pub const ALIGNED_RESET: u32 = 0x00000000;
        /// `link_up` (RO) -- Link up: aligned and four good frames in a row.
        pub const LINK_UP_LSB: u32 = 1;
        pub const LINK_UP_WIDTH: u32 = 1;
        pub const LINK_UP_MASK: u32 = 0x00000001;
        pub const LINK_UP_RESET: u32 = 0x00000000;
        /// `remote_link_up` (RO) -- The other board reports its receiver has the link up.
        pub const REMOTE_LINK_UP_LSB: u32 = 2;
        pub const REMOTE_LINK_UP_WIDTH: u32 = 1;
        pub const REMOTE_LINK_UP_MASK: u32 = 0x00000001;
        pub const REMOTE_LINK_UP_RESET: u32 = 0x00000000;
        /// `remote_sending` (RO) -- The other board is sending samples.
        pub const REMOTE_SENDING_LSB: u32 = 3;
        pub const REMOTE_SENDING_WIDTH: u32 = 1;
        pub const REMOTE_SENDING_MASK: u32 = 0x00000001;
        pub const REMOTE_SENDING_RESET: u32 = 0x00000000;
        /// `remote_ctl_full` (RO) -- The control-word receive FIFO of the other board is full.
        pub const REMOTE_CTL_FULL_LSB: u32 = 4;
        pub const REMOTE_CTL_FULL_WIDTH: u32 = 1;
        pub const REMOTE_CTL_FULL_MASK: u32 = 0x00000001;
        pub const REMOTE_CTL_FULL_RESET: u32 = 0x00000000;
        /// `ctl_tx_full` (RO) -- Our control-word send FIFO is full: do not write ctl_tx.
        pub const CTL_TX_FULL_LSB: u32 = 5;
        pub const CTL_TX_FULL_WIDTH: u32 = 1;
        pub const CTL_TX_FULL_MASK: u32 = 0x00000001;
        pub const CTL_TX_FULL_RESET: u32 = 0x00000000;
        /// `ctl_rx_avail` (RO) -- A received control word waits in ctl_rx.
        pub const CTL_RX_AVAIL_LSB: u32 = 6;
        pub const CTL_RX_AVAIL_WIDTH: u32 = 1;
        pub const CTL_RX_AVAIL_MASK: u32 = 0x00000001;
        pub const CTL_RX_AVAIL_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn aligned(self) -> bool {
                (self.0 >> ALIGNED_LSB) & 1 != 0
            }
            pub fn link_up(self) -> bool {
                (self.0 >> LINK_UP_LSB) & 1 != 0
            }
            pub fn remote_link_up(self) -> bool {
                (self.0 >> REMOTE_LINK_UP_LSB) & 1 != 0
            }
            pub fn remote_sending(self) -> bool {
                (self.0 >> REMOTE_SENDING_LSB) & 1 != 0
            }
            pub fn remote_ctl_full(self) -> bool {
                (self.0 >> REMOTE_CTL_FULL_LSB) & 1 != 0
            }
            pub fn ctl_tx_full(self) -> bool {
                (self.0 >> CTL_TX_FULL_LSB) & 1 != 0
            }
            pub fn ctl_rx_avail(self) -> bool {
                (self.0 >> CTL_RX_AVAIL_LSB) & 1 != 0
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
    }

    /// `ctl_tx` -- Write: queue a 32-bit control word for the CPU of the other board. Reads 0.
    pub mod ctl_tx {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000010;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
        pub fn write<R: RegisterSpace>(r: &R, value: u32) {
            r.write32(addr(), value)
        }
    }

    /// `ctl_rx` -- The waiting control word; reading it takes it (status.ctl_rx_avail falls until the next one is ready).
    pub mod ctl_rx {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000014;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `rx_frames` -- Good sample frames received (16 bits, wraps).
    pub mod rx_frames {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000020;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `rx_bad` -- Bad frames of any kind: code error, length, CRC (16 bits).
    pub mod rx_bad {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000024;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `rx_seq_jumps` -- Sample frames whose counter did not follow the one before (16 bits).
    pub mod rx_seq_jumps {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000028;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `align_losses` -- Times the aligner of lane 1 lost its lock (16 bits).
    pub mod align_losses {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x0000002C;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `link_ups` -- Times the link came up (16 bits).
    pub mod link_ups {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000030;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `tx_samples` -- Samples queued for the link (32 bits).
    pub mod tx_samples {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000034;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `rx_samples` -- Real (not fill) samples delivered from the link (32 bits).
    pub mod rx_samples {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000038;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `tx_counts` -- Bits 15:0 sample frames sent, 31:16 control words sent.
    pub mod tx_counts {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x0000003C;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `ctl_counts` -- Bits 15:0 control words received, 31:16 control words missing by their sequence numbers.
    pub mod ctl_counts {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000040;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `ctl_dropped` -- Received control words dropped because ctl_rx was not read (16 bits).
    pub mod ctl_dropped {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000044;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `remote_bad` -- The rx_bad count of the other board, from its status word.
    pub mod remote_bad {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000048;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `gap_events` -- Gaps zero-filled in the stream of the link (source gaps and lost frames).
    pub mod gap_events {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x0000004C;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `gap_samples` -- Samples zero-filled.
    pub mod gap_samples {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000050;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `resyncs` -- Index jumps too large to fill (over 65,536 samples).
    pub mod resyncs {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000054;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `tx_overflows` -- Times the send FIFO was full and samples were left out (the receiver fills them).
    pub mod tx_overflows {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000058;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `rx_overruns` -- Frames dropped at the receiver for lack of room (16 bits).
    pub mod rx_overruns {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x0000005C;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `sample_index_lo` -- Index of the next sample of the stream of the link, bits 31:0. Reading it latches the upper 16 bits.
    pub mod sample_index_lo {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000060;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `sample_index_hi` -- Bits 47:32, latched by the read of sample_index_lo.
    pub mod sample_index_hi {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000064;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }
}

/// `example` register block (base 0xe8ee0000).
///
/// Regmap generator self-test fixture. Not a real fabric block.
/// status: test
pub mod example {
    pub const BASE: u32 = 0xE8EE0000;
    pub const SIZE: u32 = 0x00001000;

    /// `id` -- Fixed block identifier and format version; read-only.
    pub mod id {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000000;
        pub const RESET: u32 = 0x1CE50001;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `ctrl` -- Control: an enable bit and a two-bit mode select.
    pub mod ctrl {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000004;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `enable` (RW) -- 1 = block running.
        pub const ENABLE_LSB: u32 = 0;
        pub const ENABLE_WIDTH: u32 = 1;
        pub const ENABLE_MASK: u32 = 0x00000001;
        pub const ENABLE_RESET: u32 = 0x00000000;
        /// `mode` (RW) -- 0..3, meaning is block-specific.
        pub const MODE_LSB: u32 = 1;
        pub const MODE_WIDTH: u32 = 2;
        pub const MODE_MASK: u32 = 0x00000003;
        pub const MODE_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn enable(self) -> bool {
                (self.0 >> ENABLE_LSB) & 1 != 0
            }
            pub fn with_enable(self, v: bool) -> Self {
                let bit = (v as u32) << ENABLE_LSB;
                Value((self.0 & !(ENABLE_MASK << ENABLE_LSB)) | bit)
            }
            pub fn mode(self) -> u32 {
                (self.0 >> MODE_LSB) & MODE_MASK
            }
            pub fn with_mode(self, v: u32) -> Self {
                Value((self.0 & !(MODE_MASK << MODE_LSB)) | ((v & MODE_MASK) << MODE_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `status` -- Sticky status flags. Each bit is set by hardware and cleared by firmware writing a 1 to it (write-1-to-clear); see docs/REGMAP.md on why a register with W1C fields gets no modify().
    pub mod status {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000008;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `overflow` (W1C) -- Set when an input overran; cleared by writing 1.
        pub const OVERFLOW_LSB: u32 = 0;
        pub const OVERFLOW_WIDTH: u32 = 1;
        pub const OVERFLOW_MASK: u32 = 0x00000001;
        pub const OVERFLOW_RESET: u32 = 0x00000000;
        /// `error` (W1C) -- Set on an internal error; cleared by writing 1.
        pub const ERROR_LSB: u32 = 1;
        pub const ERROR_WIDTH: u32 = 1;
        pub const ERROR_MASK: u32 = 0x00000001;
        pub const ERROR_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn overflow(self) -> bool {
                (self.0 >> OVERFLOW_LSB) & 1 != 0
            }
            pub fn error(self) -> bool {
                (self.0 >> ERROR_LSB) & 1 != 0
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        // No modify(): this register has a write-1-to-clear field, and a read-modify-write
        // would clear every other set W1C bit at the same time. Use clear_<field>() instead.
        /// Write-1-to-clear `overflow` only.
        pub fn clear_overflow<R: RegisterSpace>(r: &R) {
            r.write32(addr(), OVERFLOW_MASK << OVERFLOW_LSB);
        }
        /// Write-1-to-clear `error` only.
        pub fn clear_error<R: RegisterSpace>(r: &R) {
            r.write32(addr(), ERROR_MASK << ERROR_LSB);
        }
    }

    /// `channel` -- Per-channel gain, four instances at consecutive words (docs/ARCHITECTURE.md 3.2's per-receiver phase_inc/ctrl pair is the real-block version of this shape).
    pub mod channel {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000010;
        pub const STRIDE: u32 = 0x00000004;
        pub const COUNT: u32 = 4;
        pub const RESET: u32 = 0x00000080;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "channel index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `gain` (RW) -- Unsigned gain code, 0-255.
        pub const GAIN_LSB: u32 = 0;
        pub const GAIN_WIDTH: u32 = 8;
        pub const GAIN_MASK: u32 = 0x000000FF;
        pub const GAIN_RESET: u32 = 0x00000080;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn gain(self) -> u32 {
                (self.0 >> GAIN_LSB) & GAIN_MASK
            }
            pub fn with_gain(self, v: u32) -> Self {
                Value((self.0 & !(GAIN_MASK << GAIN_LSB)) | ((v & GAIN_MASK) << GAIN_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: Value) {
            r.write32(addr(index), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, index: u32, f: impl FnOnce(Value) -> Value) {
            write(r, index, f(read(r, index)))
        }
    }
}

/// `ft8` register block (base 0xe80d0000).
///
/// FT8/FT4 decoder front end (docs/ARCHITECTURE.md 3.12): slot capture and spectrogram (F5), Costas
/// sync search (F6), candidate engine (F7). All DDR3 addresses are lane-word addresses (8 bytes each).
/// status: draft
pub mod ft8 {
    pub const BASE: u32 = 0xE80D0000;
    pub const SIZE: u32 = 0x00010000;

    /// `id` -- Block identifier: F8 + version 2 (version 1 had no second pass: no p2_* registers).
    pub mod id {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000000;
        pub const RESET: u32 = 0x46380002;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `irq_status` -- Events; interrupt line 11 = OR of irq_status & irq_enable. Write 1 to clear.
    pub mod irq_status {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000004;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `sync_done` (W1C) -- Per receiver: a sync search finished, all its records are in DDR3 (rows searched: sync_rows).
        pub const SYNC_DONE_LSB: u32 = 0;
        pub const SYNC_DONE_WIDTH: u32 = 8;
        pub const SYNC_DONE_MASK: u32 = 0x000000FF;
        pub const SYNC_DONE_RESET: u32 = 0x00000000;
        /// `cand_done` (W1C) -- The candidate command finished, every output word is in DDR3.
        pub const CAND_DONE_LSB: u32 = 8;
        pub const CAND_DONE_WIDTH: u32 = 1;
        pub const CAND_DONE_MASK: u32 = 0x00000001;
        pub const CAND_DONE_RESET: u32 = 0x00000000;
        /// `frame` (W1C) -- A spectrogram frame was written (which: frame_last; 25 per second per receiver).
        pub const FRAME_LSB: u32 = 9;
        pub const FRAME_WIDTH: u32 = 1;
        pub const FRAME_MASK: u32 = 0x00000001;
        pub const FRAME_RESET: u32 = 0x00000000;
        /// `p2_done` (W1C) -- Second pass: the residual's spectrogram is written and its sync search finished, all records are in DDR3 at p2_rec_base.
        pub const P2_DONE_LSB: u32 = 10;
        pub const P2_DONE_WIDTH: u32 = 1;
        pub const P2_DONE_MASK: u32 = 0x00000001;
        pub const P2_DONE_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn sync_done(self) -> u32 {
                (self.0 >> SYNC_DONE_LSB) & SYNC_DONE_MASK
            }
            pub fn cand_done(self) -> bool {
                (self.0 >> CAND_DONE_LSB) & 1 != 0
            }
            pub fn frame(self) -> bool {
                (self.0 >> FRAME_LSB) & 1 != 0
            }
            pub fn p2_done(self) -> bool {
                (self.0 >> P2_DONE_LSB) & 1 != 0
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        // No modify(): this register has a write-1-to-clear field, and a read-modify-write
        // would clear every other set W1C bit at the same time. Use clear_<field>() instead.
        /// Write-1-to-clear `sync_done` only.
        pub fn clear_sync_done<R: RegisterSpace>(r: &R) {
            r.write32(addr(), SYNC_DONE_MASK << SYNC_DONE_LSB);
        }
        /// Write-1-to-clear `cand_done` only.
        pub fn clear_cand_done<R: RegisterSpace>(r: &R) {
            r.write32(addr(), CAND_DONE_MASK << CAND_DONE_LSB);
        }
        /// Write-1-to-clear `frame` only.
        pub fn clear_frame<R: RegisterSpace>(r: &R) {
            r.write32(addr(), FRAME_MASK << FRAME_LSB);
        }
        /// Write-1-to-clear `p2_done` only.
        pub fn clear_p2_done<R: RegisterSpace>(r: &R) {
            r.write32(addr(), P2_DONE_MASK << P2_DONE_LSB);
        }
    }

    /// `irq_enable` -- Which irq_status bits drive interrupt line 11.
    pub mod irq_enable {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000008;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `sync_done` (RW) -- Per receiver.
        pub const SYNC_DONE_LSB: u32 = 0;
        pub const SYNC_DONE_WIDTH: u32 = 8;
        pub const SYNC_DONE_MASK: u32 = 0x000000FF;
        pub const SYNC_DONE_RESET: u32 = 0x00000000;
        /// `cand_done` (RW) -- Candidate command done.
        pub const CAND_DONE_LSB: u32 = 8;
        pub const CAND_DONE_WIDTH: u32 = 1;
        pub const CAND_DONE_MASK: u32 = 0x00000001;
        pub const CAND_DONE_RESET: u32 = 0x00000000;
        /// `frame` (RW) -- Spectrogram frame written.
        pub const FRAME_LSB: u32 = 9;
        pub const FRAME_WIDTH: u32 = 1;
        pub const FRAME_MASK: u32 = 0x00000001;
        pub const FRAME_RESET: u32 = 0x00000000;
        /// `p2_done` (RW) -- Second pass done.
        pub const P2_DONE_LSB: u32 = 10;
        pub const P2_DONE_WIDTH: u32 = 1;
        pub const P2_DONE_MASK: u32 = 0x00000001;
        pub const P2_DONE_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn sync_done(self) -> u32 {
                (self.0 >> SYNC_DONE_LSB) & SYNC_DONE_MASK
            }
            pub fn with_sync_done(self, v: u32) -> Self {
                Value(
                    (self.0 & !(SYNC_DONE_MASK << SYNC_DONE_LSB))
                        | ((v & SYNC_DONE_MASK) << SYNC_DONE_LSB),
                )
            }
            pub fn cand_done(self) -> bool {
                (self.0 >> CAND_DONE_LSB) & 1 != 0
            }
            pub fn with_cand_done(self, v: bool) -> Self {
                let bit = (v as u32) << CAND_DONE_LSB;
                Value((self.0 & !(CAND_DONE_MASK << CAND_DONE_LSB)) | bit)
            }
            pub fn frame(self) -> bool {
                (self.0 >> FRAME_LSB) & 1 != 0
            }
            pub fn with_frame(self, v: bool) -> Self {
                let bit = (v as u32) << FRAME_LSB;
                Value((self.0 & !(FRAME_MASK << FRAME_LSB)) | bit)
            }
            pub fn p2_done(self) -> bool {
                (self.0 >> P2_DONE_LSB) & 1 != 0
            }
            pub fn with_p2_done(self, v: bool) -> Self {
                let bit = (v as u32) << P2_DONE_LSB;
                Value((self.0 & !(P2_DONE_MASK << P2_DONE_LSB)) | bit)
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `status` -- Engine state.
    pub mod status {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x0000000C;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `spec_busy` (RO) -- The spectrogram engine is working on a frame.
        pub const SPEC_BUSY_LSB: u32 = 0;
        pub const SPEC_BUSY_WIDTH: u32 = 1;
        pub const SPEC_BUSY_MASK: u32 = 0x00000001;
        pub const SPEC_BUSY_RESET: u32 = 0x00000000;
        /// `sync_busy` (RO) -- A sync search is running or queued.
        pub const SYNC_BUSY_LSB: u32 = 1;
        pub const SYNC_BUSY_WIDTH: u32 = 1;
        pub const SYNC_BUSY_MASK: u32 = 0x00000001;
        pub const SYNC_BUSY_RESET: u32 = 0x00000000;
        /// `cand_busy` (RO) -- A candidate command is running. Write cand_cmd and the cand_* registers only while 0.
        pub const CAND_BUSY_LSB: u32 = 2;
        pub const CAND_BUSY_WIDTH: u32 = 1;
        pub const CAND_BUSY_MASK: u32 = 0x00000001;
        pub const CAND_BUSY_RESET: u32 = 0x00000000;
        /// `cap_overflow` (RO) -- Sticky until reset: the slot capture dropped an audio sample.
        pub const CAP_OVERFLOW_LSB: u32 = 3;
        pub const CAP_OVERFLOW_WIDTH: u32 = 1;
        pub const CAP_OVERFLOW_MASK: u32 = 0x00000001;
        pub const CAP_OVERFLOW_RESET: u32 = 0x00000000;
        /// `p2_busy` (RO) -- Second pass: from p2_cmd until its records are in DDR3 (irq_status.p2_done). A p2_cmd written while 1 is ignored.
        pub const P2_BUSY_LSB: u32 = 4;
        pub const P2_BUSY_WIDTH: u32 = 1;
        pub const P2_BUSY_MASK: u32 = 0x00000001;
        pub const P2_BUSY_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn spec_busy(self) -> bool {
                (self.0 >> SPEC_BUSY_LSB) & 1 != 0
            }
            pub fn sync_busy(self) -> bool {
                (self.0 >> SYNC_BUSY_LSB) & 1 != 0
            }
            pub fn cand_busy(self) -> bool {
                (self.0 >> CAND_BUSY_LSB) & 1 != 0
            }
            pub fn cap_overflow(self) -> bool {
                (self.0 >> CAP_OVERFLOW_LSB) & 1 != 0
            }
            pub fn p2_busy(self) -> bool {
                (self.0 >> P2_BUSY_LSB) & 1 != 0
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
    }

    /// `frame_last` -- The spectrogram frame written last.
    pub mod frame_last {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000010;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `rx` (RO) -- Receiver.
        pub const RX_LSB: u32 = 0;
        pub const RX_WIDTH: u32 = 3;
        pub const RX_MASK: u32 = 0x00000007;
        pub const RX_RESET: u32 = 0x00000000;
        /// `frame` (RO) -- Frame number in its slot, 0-371.
        pub const FRAME_LSB: u32 = 8;
        pub const FRAME_WIDTH: u32 = 9;
        pub const FRAME_MASK: u32 = 0x000001FF;
        pub const FRAME_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn rx(self) -> u32 {
                (self.0 >> RX_LSB) & RX_MASK
            }
            pub fn frame(self) -> u32 {
                (self.0 >> FRAME_LSB) & FRAME_MASK
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
    }

    /// `sync_cmd` -- Writing queues a sync search for one receiver (for a second pass over a residual spectrogram; the searches at the triggers and at the slot end start by themselves).
    pub mod sync_cmd {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000014;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `rx` (RW) -- Receiver.
        pub const RX_LSB: u32 = 0;
        pub const RX_WIDTH: u32 = 3;
        pub const RX_MASK: u32 = 0x00000007;
        pub const RX_RESET: u32 = 0x00000000;
        /// `rows` (RW) -- Spectrogram rows to search, 1-372.
        pub const ROWS_LSB: u32 = 8;
        pub const ROWS_WIDTH: u32 = 9;
        pub const ROWS_MASK: u32 = 0x000001FF;
        pub const ROWS_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn rx(self) -> u32 {
                (self.0 >> RX_LSB) & RX_MASK
            }
            pub fn with_rx(self, v: u32) -> Self {
                Value((self.0 & !(RX_MASK << RX_LSB)) | ((v & RX_MASK) << RX_LSB))
            }
            pub fn rows(self) -> u32 {
                (self.0 >> ROWS_LSB) & ROWS_MASK
            }
            pub fn with_rows(self, v: u32) -> Self {
                Value((self.0 & !(ROWS_MASK << ROWS_LSB)) | ((v & ROWS_MASK) << ROWS_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `sync_clocks` -- Length of the last sync search in 120 MHz clocks.
    pub mod sync_clocks {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000018;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `p2_frame` -- Second pass: frames of the residual's spectrogram written so far.
    pub mod p2_frame {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x0000001C;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `value` (RO) -- 0-372.
        pub const VALUE_LSB: u32 = 0;
        pub const VALUE_WIDTH: u32 = 9;
        pub const VALUE_MASK: u32 = 0x000001FF;
        pub const VALUE_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn value(self) -> u32 {
                (self.0 >> VALUE_LSB) & VALUE_MASK
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
    }

    /// `cand_cmd` -- Writing starts a candidate command on the two lanes (only while status.cand_busy = 0).
    pub mod cand_cmd {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000020;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `pass2` (RW) -- 0 = pass 1 (slot audio to baseband), 1 = pass 2 (baseband to soft symbols).
        pub const PASS2_LSB: u32 = 0;
        pub const PASS2_WIDTH: u32 = 1;
        pub const PASS2_MASK: u32 = 0x00000001;
        pub const PASS2_RESET: u32 = 0x00000000;
        /// `lanes` (RW) -- Bit per lane: 1 = this lane takes part.
        pub const LANES_LSB: u32 = 1;
        pub const LANES_WIDTH: u32 = 2;
        pub const LANES_MASK: u32 = 0x00000003;
        pub const LANES_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn pass2(self) -> bool {
                (self.0 >> PASS2_LSB) & 1 != 0
            }
            pub fn with_pass2(self, v: bool) -> Self {
                let bit = (v as u32) << PASS2_LSB;
                Value((self.0 & !(PASS2_MASK << PASS2_LSB)) | bit)
            }
            pub fn lanes(self) -> u32 {
                (self.0 >> LANES_LSB) & LANES_MASK
            }
            pub fn with_lanes(self, v: u32) -> Self {
                Value((self.0 & !(LANES_MASK << LANES_LSB)) | ((v & LANES_MASK) << LANES_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `cand_cap_base` -- Pass 1: base of the audio ring to replay (a receiver's cap_base, or a ring of residual audio the CPU wrote: 4 samples of 16 bits per lane word, 2^19 samples).
    pub mod cand_cap_base {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000024;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
        pub fn write<R: RegisterSpace>(r: &R, value: u32) {
            r.write32(addr(), value)
        }
    }

    /// `cand_first_sample` -- Pass 1: ring sample index of the slot's first sample (the receiver's slot_boundary).
    pub mod cand_first_sample {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000028;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
        pub fn write<R: RegisterSpace>(r: &R, value: u32) {
            r.write32(addr(), value)
        }
    }

    /// `cand_clocks` -- Length of the last candidate command in 120 MHz clocks.
    pub mod cand_clocks {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x0000002C;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `p2_cmd` -- Second pass (docs/FT8_PASS2.md). Writing starts it: the spectrogram engine transforms the slot of residual audio in the area at p2_base into the area's spectrogram part (372 frames, between the live frames), then the sync engine searches that spectrogram and writes its records to the area's record part; irq_status.p2_done when they are in DDR3. Write p2_base first. Ignored while status.p2_busy.
    pub mod p2_cmd {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000030;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `rx` (RW) -- The receiver whose band (ia, ib) and power shift apply.
        pub const RX_LSB: u32 = 0;
        pub const RX_WIDTH: u32 = 3;
        pub const RX_MASK: u32 = 0x00000007;
        pub const RX_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn rx(self) -> u32 {
                (self.0 >> RX_LSB) & RX_MASK
            }
            pub fn with_rx(self, v: u32) -> Self {
                Value((self.0 & !(RX_MASK << RX_LSB)) | ((v & RX_MASK) << RX_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `p2_base` -- Second pass: the 4 MB area of DDR3 it works in, a lane-word address that is a multiple of 2^19 (the low 19 bits are not stored and read 0). In lane words from the base: 0 the residual audio the CPU wrote (180,000 samples from slot sample 0, 4 samples of 16 bits per lane word, 45,000 lane words; also cand_cap_base, with cand_first_sample = 0, for the second pass's candidates); 0x1_0000 the residual's spectrogram (372 frames x 512 lane words); 0x4_0000 its sync records (4 lane words per carrier bin from band.ia of p2_cmd.rx).
    pub mod p2_base {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000034;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `value` (RW) -- Lane-word address; bits 18:0 read 0.
        pub const VALUE_LSB: u32 = 0;
        pub const VALUE_WIDTH: u32 = 27;
        pub const VALUE_MASK: u32 = 0x07FFFFFF;
        pub const VALUE_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn value(self) -> u32 {
                (self.0 >> VALUE_LSB) & VALUE_MASK
            }
            pub fn with_value(self, v: u32) -> Self {
                Value((self.0 & !(VALUE_MASK << VALUE_LSB)) | ((v & VALUE_MASK) << VALUE_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `cand_inc` -- Per lane. Pass 1: NCO increment round((f0 + 21.875 Hz) x 2^32 / 12,000). Pass 2: rotation increment round((21.875 Hz - delf) x 2^32 / 200).
    pub mod cand_inc {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000040;
        pub const STRIDE: u32 = 0x00000010;
        pub const COUNT: u32 = 2;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "cand_inc index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> u32 {
            r.read32(addr(index))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: u32) {
            r.write32(addr(index), value)
        }
    }

    /// `cand_i0` -- Per lane, pass 2: start sample in the baseband.
    pub mod cand_i0 {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000044;
        pub const STRIDE: u32 = 0x00000010;
        pub const COUNT: u32 = 2;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "cand_i0 index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `value` (RW) -- Signed 16 bit, in 200 sps baseband samples.
        pub const VALUE_LSB: u32 = 0;
        pub const VALUE_WIDTH: u32 = 16;
        pub const VALUE_MASK: u32 = 0x0000FFFF;
        pub const VALUE_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn value(self) -> u32 {
                (self.0 >> VALUE_LSB) & VALUE_MASK
            }
            pub fn with_value(self, v: u32) -> Self {
                Value((self.0 & !(VALUE_MASK << VALUE_LSB)) | ((v & VALUE_MASK) << VALUE_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: Value) {
            r.write32(addr(index), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, index: u32, f: impl FnOnce(Value) -> Value) {
            write(r, index, f(read(r, index)))
        }
    }

    /// `cand_bb_base` -- Per lane: the candidate's baseband, 3,200 lane words {im, re} (pass 1 writes it, pass 2 reads it).
    pub mod cand_bb_base {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000048;
        pub const STRIDE: u32 = 0x00000010;
        pub const COUNT: u32 = 2;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "cand_bb_base index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> u32 {
            r.read32(addr(index))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: u32) {
            r.write32(addr(index), value)
        }
    }

    /// `cand_sym_base` -- Per lane, pass 2: where the 632 soft-symbol lane words {im, re} go (79 symbols x 8 tones).
    pub mod cand_sym_base {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x0000004C;
        pub const STRIDE: u32 = 0x00000010;
        pub const COUNT: u32 = 2;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "cand_sym_base index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> u32 {
            r.read32(addr(index))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: u32) {
            r.write32(addr(index), value)
        }
    }

    /// `ctrl` -- Per receiver: capture and spectrogram on, power shift.
    pub mod ctrl {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000200;
        pub const STRIDE: u32 = 0x00000040;
        pub const COUNT: u32 = 8;
        pub const RESET: u32 = 0x00001000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "ctrl index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `enable` (RW) -- 1 = this receiver's 12 ksps audio is captured and its spectrogram computed.
        pub const ENABLE_LSB: u32 = 0;
        pub const ENABLE_WIDTH: u32 = 1;
        pub const ENABLE_MASK: u32 = 0x00000001;
        pub const ENABLE_RESET: u32 = 0x00000000;
        /// `pwr_shift` (RW) -- Spectrogram power shift sh (docs/ARCHITECTURE.md 3.12 (b)), 0-31.
        pub const PWR_SHIFT_LSB: u32 = 8;
        pub const PWR_SHIFT_WIDTH: u32 = 5;
        pub const PWR_SHIFT_MASK: u32 = 0x0000001F;
        pub const PWR_SHIFT_RESET: u32 = 0x00000010;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn enable(self) -> bool {
                (self.0 >> ENABLE_LSB) & 1 != 0
            }
            pub fn with_enable(self, v: bool) -> Self {
                let bit = (v as u32) << ENABLE_LSB;
                Value((self.0 & !(ENABLE_MASK << ENABLE_LSB)) | bit)
            }
            pub fn pwr_shift(self) -> u32 {
                (self.0 >> PWR_SHIFT_LSB) & PWR_SHIFT_MASK
            }
            pub fn with_pwr_shift(self, v: u32) -> Self {
                Value(
                    (self.0 & !(PWR_SHIFT_MASK << PWR_SHIFT_LSB))
                        | ((v & PWR_SHIFT_MASK) << PWR_SHIFT_LSB),
                )
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: Value) {
            r.write32(addr(index), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, index: u32, f: impl FnOnce(Value) -> Value) {
            write(r, index, f(read(r, index)))
        }
    }

    /// `cap_base` -- Per receiver: base of the audio capture ring (2^17 lane words = 1 MB, 4 samples per word).
    pub mod cap_base {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000204;
        pub const STRIDE: u32 = 0x00000040;
        pub const COUNT: u32 = 8;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "cap_base index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> u32 {
            r.read32(addr(index))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: u32) {
            r.write32(addr(index), value)
        }
    }

    /// `spec_base` -- Per receiver: base of the spectrogram (372 frames x 512 lane words = 1.5 MB, two 32-bit power words per lane word).
    pub mod spec_base {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000208;
        pub const STRIDE: u32 = 0x00000040;
        pub const COUNT: u32 = 8;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "spec_base index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> u32 {
            r.read32(addr(index))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: u32) {
            r.write32(addr(index), value)
        }
    }

    /// `slot_boundary` -- Per receiver: capture sample count (cap_wr_ptr units) of the slot's first sample. Writing it starts a new slot: frame counter to 0, sync triggers re-armed.
    pub mod slot_boundary {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x0000020C;
        pub const STRIDE: u32 = 0x00000040;
        pub const COUNT: u32 = 8;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "slot_boundary index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> u32 {
            r.read32(addr(index))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: u32) {
            r.write32(addr(index), value)
        }
    }

    /// `rec_base` -- Per receiver: where the sync records go, 4 lane words per carrier bin from band.ia (8 x 32-bit words, docs/ARCHITECTURE.md 3.12 (c)).
    pub mod rec_base {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000210;
        pub const STRIDE: u32 = 0x00000040;
        pub const COUNT: u32 = 8;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "rec_base index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> u32 {
            r.read32(addr(index))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: u32) {
            r.write32(addr(index), value)
        }
    }

    /// `band` -- Per receiver: sync search band in 3.125 Hz bins.
    pub mod band {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000214;
        pub const STRIDE: u32 = 0x00000040;
        pub const COUNT: u32 = 8;
        pub const RESET: u32 = 0x03C00020;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "band index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `ia` (RW) -- First carrier bin.
        pub const IA_LSB: u32 = 0;
        pub const IA_WIDTH: u32 = 10;
        pub const IA_MASK: u32 = 0x000003FF;
        pub const IA_RESET: u32 = 0x00000020;
        /// `ib` (RW) -- Last carrier bin, at most 1,009.
        pub const IB_LSB: u32 = 16;
        pub const IB_WIDTH: u32 = 10;
        pub const IB_MASK: u32 = 0x000003FF;
        pub const IB_RESET: u32 = 0x000003C0;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn ia(self) -> u32 {
                (self.0 >> IA_LSB) & IA_MASK
            }
            pub fn with_ia(self, v: u32) -> Self {
                Value((self.0 & !(IA_MASK << IA_LSB)) | ((v & IA_MASK) << IA_LSB))
            }
            pub fn ib(self) -> u32 {
                (self.0 >> IB_LSB) & IB_MASK
            }
            pub fn with_ib(self, v: u32) -> Self {
                Value((self.0 & !(IB_MASK << IB_LSB)) | ((v & IB_MASK) << IB_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: Value) {
            r.write32(addr(index), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, index: u32, f: impl FnOnce(Value) -> Value) {
            write(r, index, f(read(r, index)))
        }
    }

    /// `trig` -- Per receiver: early sync searches, started when that many frames of the slot are written (0 = off). The search over all 372 always runs.
    pub mod trig {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000218;
        pub const STRIDE: u32 = 0x00000040;
        pub const COUNT: u32 = 8;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "trig index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `trig1` (RW) -- First early search, in frames (295 = 11.8 s).
        pub const TRIG1_LSB: u32 = 0;
        pub const TRIG1_WIDTH: u32 = 9;
        pub const TRIG1_MASK: u32 = 0x000001FF;
        pub const TRIG1_RESET: u32 = 0x00000000;
        /// `trig2` (RW) -- Second early search, in frames (337 = 13.5 s).
        pub const TRIG2_LSB: u32 = 16;
        pub const TRIG2_WIDTH: u32 = 9;
        pub const TRIG2_MASK: u32 = 0x000001FF;
        pub const TRIG2_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn trig1(self) -> u32 {
                (self.0 >> TRIG1_LSB) & TRIG1_MASK
            }
            pub fn with_trig1(self, v: u32) -> Self {
                Value((self.0 & !(TRIG1_MASK << TRIG1_LSB)) | ((v & TRIG1_MASK) << TRIG1_LSB))
            }
            pub fn trig2(self) -> u32 {
                (self.0 >> TRIG2_LSB) & TRIG2_MASK
            }
            pub fn with_trig2(self, v: u32) -> Self {
                Value((self.0 & !(TRIG2_MASK << TRIG2_LSB)) | ((v & TRIG2_MASK) << TRIG2_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: Value) {
            r.write32(addr(index), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, index: u32, f: impl FnOnce(Value) -> Value) {
            write(r, index, f(read(r, index)))
        }
    }

    /// `cap_wr_ptr` -- Per receiver: audio samples captured since reset (the ring position is this mod 2^19).
    pub mod cap_wr_ptr {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x0000021C;
        pub const STRIDE: u32 = 0x00000040;
        pub const COUNT: u32 = 8;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "cap_wr_ptr index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> u32 {
            r.read32(addr(index))
        }
    }

    /// `frame_ptr` -- Per receiver: spectrogram frames of the current slot written so far.
    pub mod frame_ptr {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000220;
        pub const STRIDE: u32 = 0x00000040;
        pub const COUNT: u32 = 8;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "frame_ptr index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `value` (RO) -- 0-372.
        pub const VALUE_LSB: u32 = 0;
        pub const VALUE_WIDTH: u32 = 9;
        pub const VALUE_MASK: u32 = 0x000001FF;
        pub const VALUE_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn value(self) -> u32 {
                (self.0 >> VALUE_LSB) & VALUE_MASK
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
    }

    /// `sync_rows` -- Per receiver: rows of the sync search that set irq_status.sync_done last.
    pub mod sync_rows {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000224;
        pub const STRIDE: u32 = 0x00000040;
        pub const COUNT: u32 = 8;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "sync_rows index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `value` (RO) -- 1-372.
        pub const VALUE_LSB: u32 = 0;
        pub const VALUE_WIDTH: u32 = 9;
        pub const VALUE_MASK: u32 = 0x000001FF;
        pub const VALUE_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn value(self) -> u32 {
                (self.0 >> VALUE_LSB) & VALUE_MASK
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
    }
}

/// `hl2_link` register block (base 0xe8010000).
///
/// HL2 link control (docs/ARCHITECTURE.md 3.1): our/HL2 addressing, the raw-frame header mirror,
/// the safety byte and its change interrupt, receive counters, and TX framer enable/trim. Packet
/// memory for the CPU receive ring and transmit queue is the separate block at 0xE802_0000.
/// status: draft
pub mod hl2_link {
    pub const BASE: u32 = 0xE8010000;
    pub const SIZE: u32 = 0x00010000;

    /// `id` -- Block identifier/version: 'HL' + version 1 (set by the chip top level, rtl/top/hl2_link_regs.v).
    pub mod id {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000000;
        pub const RESET: u32 = 0x484C0001;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `ctrl` -- Link enable and addressing mode.
    pub mod ctrl {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000004;
        pub const RESET: u32 = 0x00000002;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `rx_enable` (RW) -- 1 = classifier and raw-frame parser running.
        pub const RX_ENABLE_LSB: u32 = 0;
        pub const RX_ENABLE_WIDTH: u32 = 1;
        pub const RX_ENABLE_MASK: u32 = 0x00000001;
        pub const RX_ENABLE_RESET: u32 = 0x00000000;
        /// `dhcp_enable` (RW) -- 1 = firmware's minimal DHCP server answers the HL2 (ARCHITECTURE 3.1); 0 = link-local only.
        pub const DHCP_ENABLE_LSB: u32 = 1;
        pub const DHCP_ENABLE_WIDTH: u32 = 1;
        pub const DHCP_ENABLE_MASK: u32 = 0x00000001;
        pub const DHCP_ENABLE_RESET: u32 = 0x00000001;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn rx_enable(self) -> bool {
                (self.0 >> RX_ENABLE_LSB) & 1 != 0
            }
            pub fn with_rx_enable(self, v: bool) -> Self {
                let bit = (v as u32) << RX_ENABLE_LSB;
                Value((self.0 & !(RX_ENABLE_MASK << RX_ENABLE_LSB)) | bit)
            }
            pub fn dhcp_enable(self) -> bool {
                (self.0 >> DHCP_ENABLE_LSB) & 1 != 0
            }
            pub fn with_dhcp_enable(self, v: bool) -> Self {
                let bit = (v as u32) << DHCP_ENABLE_LSB;
                Value((self.0 & !(DHCP_ENABLE_MASK << DHCP_ENABLE_LSB)) | bit)
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `our_mac_hi` -- Our MAC address, upper 16 bits (in bits [15:0]); used to build TX frame headers in logic.
    pub mod our_mac_hi {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000008;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
        pub fn write<R: RegisterSpace>(r: &R, value: u32) {
            r.write32(addr(), value)
        }
    }

    /// `our_mac_lo` -- Our MAC address, lower 32 bits.
    pub mod our_mac_lo {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x0000000C;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
        pub fn write<R: RegisterSpace>(r: &R, value: u32) {
            r.write32(addr(), value)
        }
    }

    /// `our_ip` -- Our IPv4 address on the HL2 link. Reset value is 10.99.0.1 (ARCHITECTURE 3.1's default Tang address).
    pub mod our_ip {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000010;
        pub const RESET: u32 = 0x0A630001;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
        pub fn write<R: RegisterSpace>(r: &R, value: u32) {
            r.write32(addr(), value)
        }
    }

    /// `hl2_mac_hi` -- HL2's MAC address, upper 16 bits (in bits [15:0]). Firmware writes it from the discovery reply (read-write: nothing in logic learns it); the TX framer addresses raw TX frames to it.
    pub mod hl2_mac_hi {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000014;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
        pub fn write<R: RegisterSpace>(r: &R, value: u32) {
            r.write32(addr(), value)
        }
    }

    /// `hl2_mac_lo` -- HL2's MAC address, lower 32 bits, learned from its discovery reply.
    pub mod hl2_mac_lo {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000018;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
        pub fn write<R: RegisterSpace>(r: &R, value: u32) {
            r.write32(addr(), value)
        }
    }

    /// `hl2_ip` -- HL2's IPv4 address, either assigned by our DHCP server (10.99.0.2 by default) or learned from discovery.
    pub mod hl2_ip {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x0000001C;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
        pub fn write<R: RegisterSpace>(r: &R, value: u32) {
            r.write32(addr(), value)
        }
    }

    /// `status` -- Link and discovery status, read-only except the change flag.
    pub mod status {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000020;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `discovered` (RO) -- 1 = at least one frame has been routed to the CPU receive ring; the HL2's discovery reply is such a frame, which is where the name comes from (the MAC and IP above are valid once the firmware has written them).
        pub const DISCOVERED_LSB: u32 = 0;
        pub const DISCOVERED_WIDTH: u32 = 1;
        pub const DISCOVERED_MASK: u32 = 0x00000001;
        pub const DISCOVERED_RESET: u32 = 0x00000000;
        /// `streaming` (RO) -- 1 = raw ADC frames are arriving and passing CRC.
        pub const STREAMING_LSB: u32 = 1;
        pub const STREAMING_WIDTH: u32 = 1;
        pub const STREAMING_MASK: u32 = 0x00000001;
        pub const STREAMING_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn discovered(self) -> bool {
                (self.0 >> DISCOVERED_LSB) & 1 != 0
            }
            pub fn streaming(self) -> bool {
                (self.0 >> STREAMING_LSB) & 1 != 0
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
    }

    /// `safety_byte` -- Mirror of the safety byte from the most recent raw-frame header (PROTOCOL 5.4), and its change flag.
    pub mod safety_byte {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000024;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `value` (RO) -- Raw safety byte. Bit 7 = trip, bit 6 = over-temperature (checked in logic, not just here: ARCHITECTURE 3.1 item 5).
        pub const VALUE_LSB: u32 = 0;
        pub const VALUE_WIDTH: u32 = 8;
        pub const VALUE_MASK: u32 = 0x000000FF;
        pub const VALUE_RESET: u32 = 0x00000000;
        /// `changed` (W1C) -- Set whenever `value` changes since the last clear; drives fabric interrupt line 1 (ARCHITECTURE 4.3).
        pub const CHANGED_LSB: u32 = 8;
        pub const CHANGED_WIDTH: u32 = 1;
        pub const CHANGED_MASK: u32 = 0x00000001;
        pub const CHANGED_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn value(self) -> u32 {
                (self.0 >> VALUE_LSB) & VALUE_MASK
            }
            pub fn changed(self) -> bool {
                (self.0 >> CHANGED_LSB) & 1 != 0
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        // No modify(): this register has a write-1-to-clear field, and a read-modify-write
        // would clear every other set W1C bit at the same time. Use clear_<field>() instead.
        /// Write-1-to-clear `changed` only.
        pub fn clear_changed<R: RegisterSpace>(r: &R) {
            r.write32(addr(), CHANGED_MASK << CHANGED_LSB);
        }
    }

    /// `rx_seq` -- Sequence number of the most recent committed raw frame (since 2026-10-21; it read 0 before).
    pub mod rx_seq {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000028;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `rx_first_sample_hi` -- First-sample index of the most recent raw frame, upper 16 bits of the 48-bit index (bits [15:0]).
    pub mod rx_first_sample_hi {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x0000002C;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `rx_first_sample_lo` -- First-sample index of the most recent raw frame, lower 32 bits of the 48-bit index.
    pub mod rx_first_sample_lo {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000030;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `gap_count` -- Running count of gap-fill events (lost or CRC-failed frames, ARCHITECTURE 3.1 item 4). Free-running; firmware differences successive reads.
    pub mod gap_count {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000034;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `crc_error_count` -- Running count of frames dropped for a bad CRC-32. Free-running.
    pub mod crc_error_count {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000038;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `tx_ctrl` -- TX sample framer enable.
    pub mod tx_ctrl {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x0000003C;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `enable` (RW) -- 1 = framer sends real TX samples; 0 = framer sends zeros regardless of the TX chain (ARCHITECTURE 3.6 item 5, HL2's own interlock stays the final authority).
        pub const ENABLE_LSB: u32 = 0;
        pub const ENABLE_WIDTH: u32 = 1;
        pub const ENABLE_MASK: u32 = 0x00000001;
        pub const ENABLE_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn enable(self) -> bool {
                (self.0 >> ENABLE_LSB) & 1 != 0
            }
            pub fn with_enable(self, v: bool) -> Self {
                let bit = (v as u32) << ENABLE_LSB;
                Value((self.0 & !(ENABLE_MASK << ENABLE_LSB)) | bit)
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `tx_fifo_fill` -- HL2 TX FIFO fill estimate reported back in the v3 header (PROTOCOL 6.3), for the trim loop (ARCHITECTURE 3.6 item 3, target 12,000 of 16,384).
    pub mod tx_fifo_fill {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000040;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `tx_trim` -- Signed count of samples the trim loop has added (+) or dropped (-) since the last read, to hold tx_fifo_fill near its target.
    pub mod tx_trim {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000044;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `raw_frame_count` -- Running count of CRC-good raw sample frames (counter cnt_raw_frames). Free-running.
    pub mod raw_frame_count {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000048;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `other_frame_count` -- Running count of CRC-good frames routed to the CPU receive ring (counter cnt_other_frames). Free-running.
    pub mod other_frame_count {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x0000004C;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `ring_frames` -- CPU receive ring frame counters (counters cnt_ring_frames and cnt_ring_dropped), free-running.
    pub mod ring_frames {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000050;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `committed` (RO) -- Frames committed to the ring.
        pub const COMMITTED_LSB: u32 = 0;
        pub const COMMITTED_WIDTH: u32 = 16;
        pub const COMMITTED_MASK: u32 = 0x0000FFFF;
        pub const COMMITTED_RESET: u32 = 0x00000000;
        /// `dropped` (RO) -- Frames dropped because the ring was full.
        pub const DROPPED_LSB: u32 = 16;
        pub const DROPPED_WIDTH: u32 = 16;
        pub const DROPPED_MASK: u32 = 0x0000FFFF;
        pub const DROPPED_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn committed(self) -> u32 {
                (self.0 >> COMMITTED_LSB) & COMMITTED_MASK
            }
            pub fn dropped(self) -> u32 {
                (self.0 >> DROPPED_LSB) & DROPPED_MASK
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
    }

    /// `gap_sample_count` -- Running count of zero samples the gap filler inserted. Free-running.
    pub mod gap_sample_count {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000054;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `resync_count` -- Running count of index jumps too large to fill (resyncs). Free-running.
    pub mod resync_count {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000058;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `ring_wptr` -- CPU receive ring write pointer, byte offset into the 4 KB ring at 0xE802_0000 (ring_wr_ptr). Each frame is a 2-byte big-endian length followed by the frame bytes.
    pub mod ring_wptr {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x0000005C;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `sample_index_lo` -- HL2 sample index of the next expected ADC sample (gap filler), low 32 bits. Read lo first: that latches hi.
    pub mod sample_index_lo {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000060;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `sample_index_hi` -- HL2 sample index, high 16 bits in [15:0], as latched by the last sample_index_lo read.
    pub mod sample_index_hi {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000064;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `our_port` -- Our UDP source port for raw TX frames to the HL2 (tx_sample_framer cfg_my_port).
    pub mod our_port {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000068;
        pub const RESET: u32 = 0x0000C738;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
        pub fn write<R: RegisterSpace>(r: &R, value: u32) {
            r.write32(addr(), value)
        }
    }

    /// `tx_counts` -- Rate lock: samples inserted and skipped to hold the HL2 TX FIFO fill (free-running, low 16 bits each).
    pub mod tx_counts {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x0000006C;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `inserted` (RO) -- Samples inserted (cnt_tx_insert).
        pub const INSERTED_LSB: u32 = 0;
        pub const INSERTED_WIDTH: u32 = 16;
        pub const INSERTED_MASK: u32 = 0x0000FFFF;
        pub const INSERTED_RESET: u32 = 0x00000000;
        /// `skipped` (RO) -- Samples skipped (cnt_tx_skip).
        pub const SKIPPED_LSB: u32 = 16;
        pub const SKIPPED_WIDTH: u32 = 16;
        pub const SKIPPED_MASK: u32 = 0x0000FFFF;
        pub const SKIPPED_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn inserted(self) -> u32 {
                (self.0 >> INSERTED_LSB) & INSERTED_MASK
            }
            pub fn skipped(self) -> u32 {
                (self.0 >> SKIPPED_LSB) & SKIPPED_MASK
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
    }

    /// `seq_lost` -- Raw frames missing by the HL2's frame sequence number (every frame lost before the commit: line, module, FCS, code error, length). Owner requirement: 0.
    pub mod seq_lost {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000070;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `loss_a` -- Sequence restarts and frames with a code error.
    pub mod loss_a {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000074;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `seq_restarts` (RO) -- Times the sequence went back or a frame had flag 4 (the HL2 started again): counting starts over.
        pub const SEQ_RESTARTS_LSB: u32 = 0;
        pub const SEQ_RESTARTS_WIDTH: u32 = 16;
        pub const SEQ_RESTARTS_MASK: u32 = 0x0000FFFF;
        pub const SEQ_RESTARTS_RESET: u32 = 0x00000000;
        /// `code_frames` (RO) -- Frames dropped for a code error of the lane (also counted in crc_error_count).
        pub const CODE_FRAMES_LSB: u32 = 16;
        pub const CODE_FRAMES_WIDTH: u32 = 16;
        pub const CODE_FRAMES_MASK: u32 = 0x0000FFFF;
        pub const CODE_FRAMES_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn seq_restarts(self) -> u32 {
                (self.0 >> SEQ_RESTARTS_LSB) & SEQ_RESTARTS_MASK
            }
            pub fn code_frames(self) -> u32 {
                (self.0 >> CODE_FRAMES_LSB) & CODE_FRAMES_MASK
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
    }

    /// `loss_b` -- Length errors and the HL2's own sample loss.
    pub mod loss_b {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000078;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `len_errors` (RO) -- Raw frames with a good FCS dropped: sample bytes not 3N/2, N odd, 0 or above 5,968.
        pub const LEN_ERRORS_LSB: u32 = 0;
        pub const LEN_ERRORS_WIDTH: u32 = 16;
        pub const LEN_ERRORS_MASK: u32 = 0x0000FFFF;
        pub const LEN_ERRORS_RESET: u32 = 0x00000000;
        /// `hl2_missing` (RO) -- Committed raw frames with flag 5: the HL2 itself lost samples before them (its FIFO overflow).
        pub const HL2_MISSING_LSB: u32 = 16;
        pub const HL2_MISSING_WIDTH: u32 = 16;
        pub const HL2_MISSING_MASK: u32 = 0x0000FFFF;
        pub const HL2_MISSING_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn len_errors(self) -> u32 {
                (self.0 >> LEN_ERRORS_LSB) & LEN_ERRORS_MASK
            }
            pub fn hl2_missing(self) -> u32 {
                (self.0 >> HL2_MISSING_LSB) & HL2_MISSING_MASK
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
    }

    /// `loss_c` -- Loss behind the commit (receive chain).
    pub mod loss_c {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x0000007C;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `drain_drops` (RO) -- Committed frames not drained: the previous one was still draining.
        pub const DRAIN_DROPS_LSB: u32 = 0;
        pub const DRAIN_DROPS_WIDTH: u32 = 16;
        pub const DRAIN_DROPS_MASK: u32 = 0x0000FFFF;
        pub const DRAIN_DROPS_RESET: u32 = 0x00000000;
        /// `overruns` (RO) -- Samples written over one not yet drained (ring overrun).
        pub const OVERRUNS_LSB: u32 = 16;
        pub const OVERRUNS_WIDTH: u32 = 16;
        pub const OVERRUNS_MASK: u32 = 0x0000FFFF;
        pub const OVERRUNS_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn drain_drops(self) -> u32 {
                (self.0 >> DRAIN_DROPS_LSB) & DRAIN_DROPS_MASK
            }
            pub fn overruns(self) -> u32 {
                (self.0 >> OVERRUNS_LSB) & OVERRUNS_MASK
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
    }

    /// `loss_d` -- Index FIFO and the HL2's overflow count.
    pub mod loss_d {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000080;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `idx_drops` (RO) -- Frame indices lost because the index FIFO was full.
        pub const IDX_DROPS_LSB: u32 = 0;
        pub const IDX_DROPS_WIDTH: u32 = 16;
        pub const IDX_DROPS_MASK: u32 = 0x0000FFFF;
        pub const IDX_DROPS_RESET: u32 = 0x00000000;
        /// `hl2_ovf` (RO) -- The HL2's own FIFO overflow count from the last raw header (PROTOCOL.md 5.2 bytes 16-17).
        pub const HL2_OVF_LSB: u32 = 16;
        pub const HL2_OVF_WIDTH: u32 = 16;
        pub const HL2_OVF_MASK: u32 = 0x0000FFFF;
        pub const HL2_OVF_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn idx_drops(self) -> u32 {
                (self.0 >> IDX_DROPS_LSB) & IDX_DROPS_MASK
            }
            pub fn hl2_ovf(self) -> u32 {
                (self.0 >> HL2_OVF_LSB) & HL2_OVF_MASK
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
    }
}

/// `hl2_pkt` register block (base 0xe8020000).
///
/// HL2 link packet memory (docs/ARCHITECTURE.md 3.1, 4.1): the 4 KB CPU receive ring of the receive block
/// (rtl/hl2link/cpu_rx_ring.v), read-only, one 32-bit word per 4 bytes of ring, byte k of the ring in
/// bits [8(k%4)+7 : 8(k%4)] (little-endian, so a word copy keeps the stream order). The write pointer
/// is hl2_link.ring_wptr. Reads cross into the RGMII receive clock domain: about 20 AHB clocks each.
/// The upper half is H2's CPU transmit queue (rtl/hl2link/cpu_tx_queue.v, 4 KB, one frame in flight),
/// in the 125 MHz transmit clock domain: write the frame (destination MAC to last payload byte, no FCS)
/// as little-endian words at tx_queue, then its length in bytes to tx_send; tx_status.busy stays high
/// until the frame has gone out.
/// status: draft
pub mod hl2_pkt {
    pub const BASE: u32 = 0xE8020000;
    pub const SIZE: u32 = 0x00010000;

    /// `rx_ring` -- CPU receive ring, 4 bytes per word.
    pub mod rx_ring {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000000;
        pub const STRIDE: u32 = 0x00000004;
        pub const COUNT: u32 = 1024;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "rx_ring index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> u32 {
            r.read32(addr(index))
        }
    }

    /// `tx_queue` -- CPU transmit queue, write-only in effect (reads return 0): byte 4i+k of the frame in bits [8k+7:8k].
    pub mod tx_queue {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00008000;
        pub const STRIDE: u32 = 0x00000004;
        pub const COUNT: u32 = 1024;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "tx_queue index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> u32 {
            r.read32(addr(index))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: u32) {
            r.write32(addr(index), value)
        }
    }

    /// `tx_send` -- Write the frame length to queue the frame written at tx_queue for sending.
    pub mod tx_send {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x0000C000;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `length` (RW) -- Frame length in bytes, without FCS.
        pub const LENGTH_LSB: u32 = 0;
        pub const LENGTH_WIDTH: u32 = 16;
        pub const LENGTH_MASK: u32 = 0x0000FFFF;
        pub const LENGTH_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn length(self) -> u32 {
                (self.0 >> LENGTH_LSB) & LENGTH_MASK
            }
            pub fn with_length(self, v: u32) -> Self {
                Value((self.0 & !(LENGTH_MASK << LENGTH_LSB)) | ((v & LENGTH_MASK) << LENGTH_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `tx_status` -- CPU transmit queue status.
    pub mod tx_status {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x0000C004;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `busy` (RO) -- 1 = a queued frame has not finished sending; do not write tx_queue.
        pub const BUSY_LSB: u32 = 0;
        pub const BUSY_WIDTH: u32 = 1;
        pub const BUSY_MASK: u32 = 0x00000001;
        pub const BUSY_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn busy(self) -> bool {
                (self.0 >> BUSY_LSB) & 1 != 0
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
    }
}

/// `net` register block (base 0xe9240000).
///
/// Network unit on the RJ45 socket (RTL8211F, RGMII at 100 Mbit/s full duplex): the eth_top register page,
/// in the 100 MHz network clock (about 20 AHB clocks per access). One frame out (2 KB), a 4 KB ring of frames in, MDIO.
/// Chip ID (Gowin OTP DNA, 64 bits) at 0x80 to 0x9C. The layout is fixed and changes only with an entry in docs/DECISIONS.md.
/// status: final
pub mod net {
    pub const BASE: u32 = 0xE9240000;
    pub const SIZE: u32 = 0x00010000;

    /// `id` -- Identifier 'ET' + version 1 (eth_top).
    pub mod id {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000000;
        pub const RESET: u32 = 0x45540001;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `ctrl` -- Bit 0 receiver on, 1 transmitter on, 2 PHY reset pin low, 3 every frame, 4 broadcast, 5 multicast.
    pub mod ctrl {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000004;
        pub const RESET: u32 = 0x00000014;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
        pub fn write<R: RegisterSpace>(r: &R, value: u32) {
            r.write32(addr(), value)
        }
    }

    /// `status` -- Bit 0 a frame waits, 1 transmitter busy, 2 the PHY's receive clock runs, 3 PHY link, 5:4 speed (0 10, 1 100, 2 1000), 6 full duplex (the PHY's in-band report).
    pub mod status {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000008;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `flags` -- Bit 0 frame waiting, 1 frame sent, 2 frame dropped, 3 MDIO done; write 1 to bits 1 to 3 to clear them.
    pub mod flags {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x0000000C;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
        pub fn write<R: RegisterSpace>(r: &R, value: u32) {
            r.write32(addr(), value)
        }
    }

    /// `irq_enable` -- Interrupt enable per flag bit.
    pub mod irq_enable {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000010;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
        pub fn write<R: RegisterSpace>(r: &R, value: u32) {
            r.write32(addr(), value)
        }
    }

    /// `mac_lo` -- Our MAC address bytes 0 to 3 (byte 0 first on the wire, in bits 7:0).
    pub mod mac_lo {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000014;
        pub const RESET: u32 = 0x004A5402;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
        pub fn write<R: RegisterSpace>(r: &R, value: u32) {
            r.write32(addr(), value)
        }
    }

    /// `mac_hi` -- Our MAC address bytes 4 and 5 in bits 15:0.
    pub mod mac_hi {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000018;
        pub const RESET: u32 = 0x00000100;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
        pub fn write<R: RegisterSpace>(r: &R, value: u32) {
            r.write32(addr(), value)
        }
    }

    /// `mdio` -- Write: bit 30 read, 25:21 PHY, 20:16 register, 15:0 value; read: bit 31 busy, 15:0 the value read.
    pub mod mdio {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x0000001C;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
        pub fn write<R: RegisterSpace>(r: &R, value: u32) {
            r.write32(addr(), value)
        }
    }

    /// `tx_len` -- Write: send the frame in the buffer, this many bytes (padded to 60). Read: bit 0 busy.
    pub mod tx_len {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000020;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
        pub fn write<R: RegisterSpace>(r: &R, value: u32) {
            r.write32(addr(), value)
        }
    }

    /// `tx_data` -- The next 4 bytes of the frame to send (byte k in bits 8k+7:8k).
    pub mod tx_data {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000024;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
        pub fn write<R: RegisterSpace>(r: &R, value: u32) {
            r.write32(addr(), value)
        }
    }

    /// `tx_ptr` -- Write: the next tx_data goes to the start of the buffer.
    pub mod tx_ptr {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000028;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
        pub fn write<R: RegisterSpace>(r: &R, value: u32) {
            r.write32(addr(), value)
        }
    }

    /// `rx_len` -- Length of the waiting frame in bytes (FCS not included), 0 when none waits.
    pub mod rx_len {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x0000002C;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `rx_data` -- The next 4 bytes of the waiting frame.
    pub mod rx_data {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000030;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `rx_done` -- Write: the waiting frame is read, the next one comes.
    pub mod rx_done {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000034;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
        pub fn write<R: RegisterSpace>(r: &R, value: u32) {
            r.write32(addr(), value)
        }
    }

    /// `rx_count` -- Good frames received.
    pub mod rx_count {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000038;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `rx_dropped` -- 15:0 frames dropped for lack of room, 31:16 with a bad FCS or length; reading clears both.
    pub mod rx_dropped {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x0000003C;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `tx_count` -- Frames sent.
    pub mod tx_count {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000040;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `dna_raw0` -- Chip ID read, raw bits 31:0 of the OTP shift (register bit k = raw bit k; raw bit 0 is DOUT before the first clock edge).
    pub mod dna_raw0 {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000080;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `dna_raw1` -- Chip ID read, raw bits 63:32.
    pub mod dna_raw1 {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000084;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `dna_raw2` -- Chip ID read, raw bits 95:64.
    pub mod dna_raw2 {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000088;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `dna_raw3` -- Chip ID read, raw bits 127:96.
    pub mod dna_raw3 {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x0000008C;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `dna_raw4` -- Bit 0 is raw bit 128 (one past the register).
    pub mod dna_raw4 {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000090;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `dna_status` -- Bit 0 the OTP read is done (about 150 us after reset), 15:8 the ID width in bits (64 when the reader is in the build).
    pub mod dna_status {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000094;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `dna_id_lo` -- Chip ID (Gowin OTP DNA, MODE 2'b01, valid bits 95:32 of the 128-bit read, SUG283-3.6.1E section 8.9) bits 31:0.
    pub mod dna_id_lo {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000098;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `dna_id_hi` -- Chip ID bits 63:32.
    pub mod dna_id_hi {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x0000009C;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }
}

/// `rx_backend` register block (base 0xe80c0000).
///
/// Receiver back end (docs/ARCHITECTURE.md 3.10, docs/R4_BACKEND.md): per receiver noise blanker,
/// half-band decimation to 24 ksps, 1,024-tap complex channel filter (coefficient bank pool, 6 banks
/// per filter unit), CORDIC demodulator (SSB/CW, AM, SAM, FM, IQ), log-domain AGC, S-meter, squelch,
/// 12 or 24 ksps output with HL2 sample-index stamps.
/// status: draft
pub mod rx_backend {
    pub const BASE: u32 = 0xE80C0000;
    pub const SIZE: u32 = 0x00010000;

    /// `id` -- Block identifier 'RB' and version 1.
    pub mod id {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000000;
        pub const RESET: u32 = 0x52420001;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `status` -- Sticky error flags; each set bit means a sample was lost (should never happen: the engines are sized for 8 receivers at 384 ksps with 1,024 taps).
    pub mod status {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000004;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `ovf_front` (W1C) -- Input FIFO (blanker to decimator) overflowed.
        pub const OVF_FRONT_LSB: u32 = 0;
        pub const OVF_FRONT_WIDTH: u32 = 1;
        pub const OVF_FRONT_MASK: u32 = 0x00000001;
        pub const OVF_FRONT_RESET: u32 = 0x00000000;
        /// `ovf_decim` (W1C) -- A channel-filter input FIFO overflowed.
        pub const OVF_DECIM_LSB: u32 = 1;
        pub const OVF_DECIM_WIDTH: u32 = 1;
        pub const OVF_DECIM_MASK: u32 = 0x00000001;
        pub const OVF_DECIM_RESET: u32 = 0x00000000;
        /// `ovf_filter` (W1C) -- The demodulator input FIFO overflowed.
        pub const OVF_FILTER_LSB: u32 = 2;
        pub const OVF_FILTER_WIDTH: u32 = 1;
        pub const OVF_FILTER_MASK: u32 = 0x00000001;
        pub const OVF_FILTER_RESET: u32 = 0x00000000;
        /// `ovf_ring` (W1C) -- The ring writer's queue overflowed (the DDR3 write lane was blocked for too long).
        pub const OVF_RING_LSB: u32 = 3;
        pub const OVF_RING_WIDTH: u32 = 1;
        pub const OVF_RING_MASK: u32 = 0x00000001;
        pub const OVF_RING_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn ovf_front(self) -> bool {
                (self.0 >> OVF_FRONT_LSB) & 1 != 0
            }
            pub fn ovf_decim(self) -> bool {
                (self.0 >> OVF_DECIM_LSB) & 1 != 0
            }
            pub fn ovf_filter(self) -> bool {
                (self.0 >> OVF_FILTER_LSB) & 1 != 0
            }
            pub fn ovf_ring(self) -> bool {
                (self.0 >> OVF_RING_LSB) & 1 != 0
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        // No modify(): this register has a write-1-to-clear field, and a read-modify-write
        // would clear every other set W1C bit at the same time. Use clear_<field>() instead.
        /// Write-1-to-clear `ovf_front` only.
        pub fn clear_ovf_front<R: RegisterSpace>(r: &R) {
            r.write32(addr(), OVF_FRONT_MASK << OVF_FRONT_LSB);
        }
        /// Write-1-to-clear `ovf_decim` only.
        pub fn clear_ovf_decim<R: RegisterSpace>(r: &R) {
            r.write32(addr(), OVF_DECIM_MASK << OVF_DECIM_LSB);
        }
        /// Write-1-to-clear `ovf_filter` only.
        pub fn clear_ovf_filter<R: RegisterSpace>(r: &R) {
            r.write32(addr(), OVF_FILTER_MASK << OVF_FILTER_LSB);
        }
        /// Write-1-to-clear `ovf_ring` only.
        pub fn clear_ovf_ring<R: RegisterSpace>(r: &R) {
            r.write32(addr(), OVF_RING_MASK << OVF_RING_LSB);
        }
    }

    /// `irq_status` -- Output block ready, one bit per receiver (interrupt line 10 = OR of irq_status & irq_enable).
    pub mod irq_status {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000008;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `block` (W1C) -- Set when the receiver's ring received a complete block; write 1 to clear.
        pub const BLOCK_LSB: u32 = 0;
        pub const BLOCK_WIDTH: u32 = 8;
        pub const BLOCK_MASK: u32 = 0x000000FF;
        pub const BLOCK_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn block(self) -> u32 {
                (self.0 >> BLOCK_LSB) & BLOCK_MASK
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        // No modify(): this register has a write-1-to-clear field, and a read-modify-write
        // would clear every other set W1C bit at the same time. Use clear_<field>() instead.
        /// Write-1-to-clear `block` only.
        pub fn clear_block<R: RegisterSpace>(r: &R) {
            r.write32(addr(), BLOCK_MASK << BLOCK_LSB);
        }
    }

    /// `irq_enable` -- Interrupt enable per receiver.
    pub mod irq_enable {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x0000000C;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `block` (RW) -- 1 = this receiver's block-ready bit drives interrupt line 10.
        pub const BLOCK_LSB: u32 = 0;
        pub const BLOCK_WIDTH: u32 = 8;
        pub const BLOCK_MASK: u32 = 0x000000FF;
        pub const BLOCK_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn block(self) -> u32 {
                (self.0 >> BLOCK_LSB) & BLOCK_MASK
            }
            pub fn with_block(self, v: u32) -> Self {
                Value((self.0 & !(BLOCK_MASK << BLOCK_LSB)) | ((v & BLOCK_MASK) << BLOCK_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `coef_sel` -- Which coefficient bank the coefficient window writes.
    pub mod coef_sel {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000010;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `unit` (RW) -- Filter unit: 0 serves receivers 0-3, 1 serves receivers 4-7.
        pub const UNIT_LSB: u32 = 0;
        pub const UNIT_WIDTH: u32 = 1;
        pub const UNIT_MASK: u32 = 0x00000001;
        pub const UNIT_RESET: u32 = 0x00000000;
        /// `bank` (RW) -- Bank 0-5 of that unit. Never write a bank a receiver of that unit is using (bank_cur).
        pub const BANK_LSB: u32 = 1;
        pub const BANK_WIDTH: u32 = 3;
        pub const BANK_MASK: u32 = 0x00000007;
        pub const BANK_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn unit(self) -> bool {
                (self.0 >> UNIT_LSB) & 1 != 0
            }
            pub fn with_unit(self, v: bool) -> Self {
                let bit = (v as u32) << UNIT_LSB;
                Value((self.0 & !(UNIT_MASK << UNIT_LSB)) | bit)
            }
            pub fn bank(self) -> u32 {
                (self.0 >> BANK_LSB) & BANK_MASK
            }
            pub fn with_bank(self, v: u32) -> Self {
                Value((self.0 & !(BANK_MASK << BANK_LSB)) | ((v & BANK_MASK) << BANK_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `bank_cfg` -- Per coefficient bank (index = unit * 6 + bank): tap count and scale exponent. Write before pointing a receiver at the bank.
    pub mod bank_cfg {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000040;
        pub const STRIDE: u32 = 0x00000004;
        pub const COUNT: u32 = 12;
        pub const RESET: u32 = 0x00000001;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "bank_cfg index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `ntaps` (RW) -- Taps used, 1-1,024.
        pub const NTAPS_LSB: u32 = 0;
        pub const NTAPS_WIDTH: u32 = 11;
        pub const NTAPS_MASK: u32 = 0x000007FF;
        pub const NTAPS_RESET: u32 = 0x00000001;
        /// `exp` (RW) -- Coefficient value = c * 2^-(30 + exp).
        pub const EXP_LSB: u32 = 12;
        pub const EXP_WIDTH: u32 = 4;
        pub const EXP_MASK: u32 = 0x0000000F;
        pub const EXP_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn ntaps(self) -> u32 {
                (self.0 >> NTAPS_LSB) & NTAPS_MASK
            }
            pub fn with_ntaps(self, v: u32) -> Self {
                Value((self.0 & !(NTAPS_MASK << NTAPS_LSB)) | ((v & NTAPS_MASK) << NTAPS_LSB))
            }
            pub fn exp(self) -> u32 {
                (self.0 >> EXP_LSB) & EXP_MASK
            }
            pub fn with_exp(self, v: u32) -> Self {
                Value((self.0 & !(EXP_MASK << EXP_LSB)) | ((v & EXP_MASK) << EXP_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: Value) {
            r.write32(addr(index), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, index: u32, f: impl FnOnce(Value) -> Value) {
            write(r, index, f(read(r, index)))
        }
    }

    /// `ctrl` -- Per receiver: enable, mode, rates, switches, coefficient bank. Change mode and rates only while disabled; bank_sel may change at any time (takes effect at the next 24 ksps sample).
    pub mod ctrl {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000100;
        pub const STRIDE: u32 = 0x00000080;
        pub const COUNT: u32 = 8;
        pub const RESET: u32 = 0x00000B00;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "ctrl index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `enable` (RW) -- 1 = running. A 0-to-1 edge restarts every stage from zero state and relatches the stamp base.
        pub const ENABLE_LSB: u32 = 0;
        pub const ENABLE_WIDTH: u32 = 1;
        pub const ENABLE_MASK: u32 = 0x00000001;
        pub const ENABLE_RESET: u32 = 0x00000000;
        /// `mode` (RW) -- 0 SSB/CW/data (real part), 1 AM, 2 synchronous AM, 3 FM, 4 IQ.
        pub const MODE_LSB: u32 = 1;
        pub const MODE_WIDTH: u32 = 3;
        pub const MODE_MASK: u32 = 0x00000007;
        pub const MODE_RESET: u32 = 0x00000000;
        /// `out24` (RW) -- 0 = 12 ksps output (audio half-band on), 1 = 24 ksps.
        pub const OUT24_LSB: u32 = 4;
        pub const OUT24_WIDTH: u32 = 1;
        pub const OUT24_MASK: u32 = 0x00000001;
        pub const OUT24_RESET: u32 = 0x00000000;
        /// `in_rate` (RW) -- Must equal the bank's rate_sel for this receiver: 0..3 = 48/96/192/384 ksps.
        pub const IN_RATE_LSB: u32 = 5;
        pub const IN_RATE_WIDTH: u32 = 2;
        pub const IN_RATE_MASK: u32 = 0x00000003;
        pub const IN_RATE_RESET: u32 = 0x00000000;
        /// `in_shift` (RW) -- Input left shift before everything else (saturating). 6 for the current bank.
        pub const IN_SHIFT_LSB: u32 = 7;
        pub const IN_SHIFT_WIDTH: u32 = 3;
        pub const IN_SHIFT_MASK: u32 = 0x00000007;
        pub const IN_SHIFT_RESET: u32 = 0x00000006;
        /// `nb_en` (RW) -- Noise blanker on.
        pub const NB_EN_LSB: u32 = 10;
        pub const NB_EN_WIDTH: u32 = 1;
        pub const NB_EN_MASK: u32 = 0x00000001;
        pub const NB_EN_RESET: u32 = 0x00000000;
        /// `agc_en` (RW) -- AGC on; 0 = fixed gain agc_manual (FM always uses agc_manual).
        pub const AGC_EN_LSB: u32 = 11;
        pub const AGC_EN_WIDTH: u32 = 1;
        pub const AGC_EN_MASK: u32 = 0x00000001;
        pub const AGC_EN_RESET: u32 = 0x00000001;
        /// `sq_en` (RW) -- Squelch on.
        pub const SQ_EN_LSB: u32 = 12;
        pub const SQ_EN_WIDTH: u32 = 1;
        pub const SQ_EN_MASK: u32 = 0x00000001;
        pub const SQ_EN_RESET: u32 = 0x00000000;
        /// `bank_sel` (RW) -- Coefficient bank 0-5 of this receiver's filter unit.
        pub const BANK_SEL_LSB: u32 = 13;
        pub const BANK_SEL_WIDTH: u32 = 3;
        pub const BANK_SEL_MASK: u32 = 0x00000007;
        pub const BANK_SEL_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn enable(self) -> bool {
                (self.0 >> ENABLE_LSB) & 1 != 0
            }
            pub fn with_enable(self, v: bool) -> Self {
                let bit = (v as u32) << ENABLE_LSB;
                Value((self.0 & !(ENABLE_MASK << ENABLE_LSB)) | bit)
            }
            pub fn mode(self) -> u32 {
                (self.0 >> MODE_LSB) & MODE_MASK
            }
            pub fn with_mode(self, v: u32) -> Self {
                Value((self.0 & !(MODE_MASK << MODE_LSB)) | ((v & MODE_MASK) << MODE_LSB))
            }
            pub fn out24(self) -> bool {
                (self.0 >> OUT24_LSB) & 1 != 0
            }
            pub fn with_out24(self, v: bool) -> Self {
                let bit = (v as u32) << OUT24_LSB;
                Value((self.0 & !(OUT24_MASK << OUT24_LSB)) | bit)
            }
            pub fn in_rate(self) -> u32 {
                (self.0 >> IN_RATE_LSB) & IN_RATE_MASK
            }
            pub fn with_in_rate(self, v: u32) -> Self {
                Value(
                    (self.0 & !(IN_RATE_MASK << IN_RATE_LSB)) | ((v & IN_RATE_MASK) << IN_RATE_LSB),
                )
            }
            pub fn in_shift(self) -> u32 {
                (self.0 >> IN_SHIFT_LSB) & IN_SHIFT_MASK
            }
            pub fn with_in_shift(self, v: u32) -> Self {
                Value(
                    (self.0 & !(IN_SHIFT_MASK << IN_SHIFT_LSB))
                        | ((v & IN_SHIFT_MASK) << IN_SHIFT_LSB),
                )
            }
            pub fn nb_en(self) -> bool {
                (self.0 >> NB_EN_LSB) & 1 != 0
            }
            pub fn with_nb_en(self, v: bool) -> Self {
                let bit = (v as u32) << NB_EN_LSB;
                Value((self.0 & !(NB_EN_MASK << NB_EN_LSB)) | bit)
            }
            pub fn agc_en(self) -> bool {
                (self.0 >> AGC_EN_LSB) & 1 != 0
            }
            pub fn with_agc_en(self, v: bool) -> Self {
                let bit = (v as u32) << AGC_EN_LSB;
                Value((self.0 & !(AGC_EN_MASK << AGC_EN_LSB)) | bit)
            }
            pub fn sq_en(self) -> bool {
                (self.0 >> SQ_EN_LSB) & 1 != 0
            }
            pub fn with_sq_en(self, v: bool) -> Self {
                let bit = (v as u32) << SQ_EN_LSB;
                Value((self.0 & !(SQ_EN_MASK << SQ_EN_LSB)) | bit)
            }
            pub fn bank_sel(self) -> u32 {
                (self.0 >> BANK_SEL_LSB) & BANK_SEL_MASK
            }
            pub fn with_bank_sel(self, v: u32) -> Self {
                Value(
                    (self.0 & !(BANK_SEL_MASK << BANK_SEL_LSB))
                        | ((v & BANK_SEL_MASK) << BANK_SEL_LSB),
                )
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: Value) {
            r.write32(addr(index), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, index: u32, f: impl FnOnce(Value) -> Value) {
            write(r, index, f(read(r, index)))
        }
    }

    /// `nb` -- Noise blanker threshold and floor time constants.
    pub mod nb {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000104;
        pub const STRIDE: u32 = 0x00000080;
        pub const COUNT: u32 = 8;
        pub const RESET: u32 = 0x000D0960;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "nb index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `thr` (RW) -- Trigger when magnitude > floor * thr / 16 (U4.4).
        pub const THR_LSB: u32 = 0;
        pub const THR_WIDTH: u32 = 8;
        pub const THR_MASK: u32 = 0x000000FF;
        pub const THR_RESET: u32 = 0x00000060;
        /// `k_down` (RW) -- Floor time constant 2^k_down samples while the magnitude is below the floor.
        pub const K_DOWN_LSB: u32 = 8;
        pub const K_DOWN_WIDTH: u32 = 5;
        pub const K_DOWN_MASK: u32 = 0x0000001F;
        pub const K_DOWN_RESET: u32 = 0x00000009;
        /// `k_up` (RW) -- Floor time constant 2^k_up samples while the magnitude is above the floor.
        pub const K_UP_LSB: u32 = 16;
        pub const K_UP_WIDTH: u32 = 5;
        pub const K_UP_MASK: u32 = 0x0000001F;
        pub const K_UP_RESET: u32 = 0x0000000D;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn thr(self) -> u32 {
                (self.0 >> THR_LSB) & THR_MASK
            }
            pub fn with_thr(self, v: u32) -> Self {
                Value((self.0 & !(THR_MASK << THR_LSB)) | ((v & THR_MASK) << THR_LSB))
            }
            pub fn k_down(self) -> u32 {
                (self.0 >> K_DOWN_LSB) & K_DOWN_MASK
            }
            pub fn with_k_down(self, v: u32) -> Self {
                Value((self.0 & !(K_DOWN_MASK << K_DOWN_LSB)) | ((v & K_DOWN_MASK) << K_DOWN_LSB))
            }
            pub fn k_up(self) -> u32 {
                (self.0 >> K_UP_LSB) & K_UP_MASK
            }
            pub fn with_k_up(self, v: u32) -> Self {
                Value((self.0 & !(K_UP_MASK << K_UP_LSB)) | ((v & K_UP_MASK) << K_UP_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: Value) {
            r.write32(addr(index), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, index: u32, f: impl FnOnce(Value) -> Value) {
            write(r, index, f(read(r, index)))
        }
    }

    /// `nb_hold` -- Noise blanker hold length.
    pub mod nb_hold {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000108;
        pub const STRIDE: u32 = 0x00000080;
        pub const COUNT: u32 = 8;
        pub const RESET: u32 = 0x00000026;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "nb_hold index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `samples` (RW) -- Input samples replaced by the last good one after a trigger.
        pub const SAMPLES_LSB: u32 = 0;
        pub const SAMPLES_WIDTH: u32 = 16;
        pub const SAMPLES_MASK: u32 = 0x0000FFFF;
        pub const SAMPLES_RESET: u32 = 0x00000026;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn samples(self) -> u32 {
                (self.0 >> SAMPLES_LSB) & SAMPLES_MASK
            }
            pub fn with_samples(self, v: u32) -> Self {
                Value(
                    (self.0 & !(SAMPLES_MASK << SAMPLES_LSB)) | ((v & SAMPLES_MASK) << SAMPLES_LSB),
                )
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: Value) {
            r.write32(addr(index), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, index: u32, f: impl FnOnce(Value) -> Value) {
            write(r, index, f(read(r, index)))
        }
    }

    /// `agc_attack` -- AGC attack coefficient alpha = a * 2^-(17 + s) (tr_dsp::backend::Alpha::from_time_constant).
    pub mod agc_attack {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x0000010C;
        pub const STRIDE: u32 = 0x00000080;
        pub const COUNT: u32 = 8;
        pub const RESET: u32 = 0x005151CD;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "agc_attack index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `a` (RW) -- Mantissa, 1-131,071. Reset: 2 ms at 24 ksps.
        pub const A_LSB: u32 = 0;
        pub const A_WIDTH: u32 = 17;
        pub const A_MASK: u32 = 0x0001FFFF;
        pub const A_RESET: u32 = 0x000151CD;
        /// `s` (RW) -- Exponent, 0-15.
        pub const S_LSB: u32 = 20;
        pub const S_WIDTH: u32 = 4;
        pub const S_MASK: u32 = 0x0000000F;
        pub const S_RESET: u32 = 0x00000005;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn a(self) -> u32 {
                (self.0 >> A_LSB) & A_MASK
            }
            pub fn with_a(self, v: u32) -> Self {
                Value((self.0 & !(A_MASK << A_LSB)) | ((v & A_MASK) << A_LSB))
            }
            pub fn s(self) -> u32 {
                (self.0 >> S_LSB) & S_MASK
            }
            pub fn with_s(self, v: u32) -> Self {
                Value((self.0 & !(S_MASK << S_LSB)) | ((v & S_MASK) << S_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: Value) {
            r.write32(addr(index), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, index: u32, f: impl FnOnce(Value) -> Value) {
            write(r, index, f(read(r, index)))
        }
    }

    /// `agc_decay` -- AGC decay coefficient alpha = a * 2^-(17 + s).
    pub mod agc_decay {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000110;
        pub const STRIDE: u32 = 0x00000080;
        pub const COUNT: u32 = 8;
        pub const RESET: u32 = 0x00C15D7F;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "agc_decay index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `a` (RW) -- Mantissa, 1-131,071. Reset: 250 ms at 24 ksps.
        pub const A_LSB: u32 = 0;
        pub const A_WIDTH: u32 = 17;
        pub const A_MASK: u32 = 0x0001FFFF;
        pub const A_RESET: u32 = 0x00015D7F;
        /// `s` (RW) -- Exponent, 0-15.
        pub const S_LSB: u32 = 20;
        pub const S_WIDTH: u32 = 4;
        pub const S_MASK: u32 = 0x0000000F;
        pub const S_RESET: u32 = 0x0000000C;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn a(self) -> u32 {
                (self.0 >> A_LSB) & A_MASK
            }
            pub fn with_a(self, v: u32) -> Self {
                Value((self.0 & !(A_MASK << A_LSB)) | ((v & A_MASK) << A_LSB))
            }
            pub fn s(self) -> u32 {
                (self.0 >> S_LSB) & S_MASK
            }
            pub fn with_s(self, v: u32) -> Self {
                Value((self.0 & !(S_MASK << S_LSB)) | ((v & S_MASK) << S_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: Value) {
            r.write32(addr(index), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, index: u32, f: impl FnOnce(Value) -> Value) {
            write(r, index, f(read(r, index)))
        }
    }

    /// `agc_hang` -- AGC hang time.
    pub mod agc_hang {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000114;
        pub const STRIDE: u32 = 0x00000080;
        pub const COUNT: u32 = 8;
        pub const RESET: u32 = 0x00000960;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "agc_hang index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `samples` (RW) -- 24 ksps samples the gain holds after the last attack sample.
        pub const SAMPLES_LSB: u32 = 0;
        pub const SAMPLES_WIDTH: u32 = 16;
        pub const SAMPLES_MASK: u32 = 0x0000FFFF;
        pub const SAMPLES_RESET: u32 = 0x00000960;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn samples(self) -> u32 {
                (self.0 >> SAMPLES_LSB) & SAMPLES_MASK
            }
            pub fn with_samples(self, v: u32) -> Self {
                Value(
                    (self.0 & !(SAMPLES_MASK << SAMPLES_LSB)) | ((v & SAMPLES_MASK) << SAMPLES_LSB),
                )
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: Value) {
            r.write32(addr(index), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, index: u32, f: impl FnOnce(Value) -> Value) {
            write(r, index, f(read(r, index)))
        }
    }

    /// `agc_ref` -- AGC reference: log2 of the target envelope on the 24-bit scale, U5.12 (21.0 = -12 dB of the 16-bit output).
    pub mod agc_ref {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000118;
        pub const STRIDE: u32 = 0x00000080;
        pub const COUNT: u32 = 8;
        pub const RESET: u32 = 0x00015000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "agc_ref index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `level` (RW) -- U5.12.
        pub const LEVEL_LSB: u32 = 0;
        pub const LEVEL_WIDTH: u32 = 17;
        pub const LEVEL_MASK: u32 = 0x0001FFFF;
        pub const LEVEL_RESET: u32 = 0x00015000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn level(self) -> u32 {
                (self.0 >> LEVEL_LSB) & LEVEL_MASK
            }
            pub fn with_level(self, v: u32) -> Self {
                Value((self.0 & !(LEVEL_MASK << LEVEL_LSB)) | ((v & LEVEL_MASK) << LEVEL_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: Value) {
            r.write32(addr(index), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, index: u32, f: impl FnOnce(Value) -> Value) {
            write(r, index, f(read(r, index)))
        }
    }

    /// `agc_gmax` -- Largest AGC gain, log2 S7.12.
    pub mod agc_gmax {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x0000011C;
        pub const STRIDE: u32 = 0x00000080;
        pub const COUNT: u32 = 8;
        pub const RESET: u32 = 0x00014000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "agc_gmax index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `gain` (RW) -- S7.12 (20.0 = +120 dB).
        pub const GAIN_LSB: u32 = 0;
        pub const GAIN_WIDTH: u32 = 20;
        pub const GAIN_MASK: u32 = 0x000FFFFF;
        pub const GAIN_RESET: u32 = 0x00014000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn gain(self) -> u32 {
                (self.0 >> GAIN_LSB) & GAIN_MASK
            }
            pub fn with_gain(self, v: u32) -> Self {
                Value((self.0 & !(GAIN_MASK << GAIN_LSB)) | ((v & GAIN_MASK) << GAIN_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: Value) {
            r.write32(addr(index), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, index: u32, f: impl FnOnce(Value) -> Value) {
            write(r, index, f(read(r, index)))
        }
    }

    /// `agc_gmin` -- Smallest AGC gain, log2 S7.12.
    pub mod agc_gmin {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000120;
        pub const STRIDE: u32 = 0x00000080;
        pub const COUNT: u32 = 8;
        pub const RESET: u32 = 0x000F8000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "agc_gmin index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `gain` (RW) -- S7.12 (-8.0 = -48 dB).
        pub const GAIN_LSB: u32 = 0;
        pub const GAIN_WIDTH: u32 = 20;
        pub const GAIN_MASK: u32 = 0x000FFFFF;
        pub const GAIN_RESET: u32 = 0x000F8000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn gain(self) -> u32 {
                (self.0 >> GAIN_LSB) & GAIN_MASK
            }
            pub fn with_gain(self, v: u32) -> Self {
                Value((self.0 & !(GAIN_MASK << GAIN_LSB)) | ((v & GAIN_MASK) << GAIN_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: Value) {
            r.write32(addr(index), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, index: u32, f: impl FnOnce(Value) -> Value) {
            write(r, index, f(read(r, index)))
        }
    }

    /// `agc_manual` -- Fixed gain used with agc_en = 0 and in FM, log2 S7.12.
    pub mod agc_manual {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000124;
        pub const STRIDE: u32 = 0x00000080;
        pub const COUNT: u32 = 8;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "agc_manual index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `gain` (RW) -- S7.12.
        pub const GAIN_LSB: u32 = 0;
        pub const GAIN_WIDTH: u32 = 20;
        pub const GAIN_MASK: u32 = 0x000FFFFF;
        pub const GAIN_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn gain(self) -> u32 {
                (self.0 >> GAIN_LSB) & GAIN_MASK
            }
            pub fn with_gain(self, v: u32) -> Self {
                Value((self.0 & !(GAIN_MASK << GAIN_LSB)) | ((v & GAIN_MASK) << GAIN_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: Value) {
            r.write32(addr(index), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, index: u32, f: impl FnOnce(Value) -> Value) {
            write(r, index, f(read(r, index)))
        }
    }

    /// `loops` -- Smoothing and loop shifts.
    pub mod loops {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000128;
        pub const STRIDE: u32 = 0x00000080;
        pub const COUNT: u32 = 8;
        pub const RESET: u32 = 0x000F07A7;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "loops index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `k_sm` (RW) -- S-meter smoothing, 2^k_sm samples at 24 ksps.
        pub const K_SM_LSB: u32 = 0;
        pub const K_SM_WIDTH: u32 = 4;
        pub const K_SM_MASK: u32 = 0x0000000F;
        pub const K_SM_RESET: u32 = 0x00000007;
        /// `k_dc` (RW) -- AM/SAM carrier removal, 2^k_dc samples.
        pub const K_DC_LSB: u32 = 4;
        pub const K_DC_WIDTH: u32 = 4;
        pub const K_DC_MASK: u32 = 0x0000000F;
        pub const K_DC_RESET: u32 = 0x0000000A;
        /// `sam_kp` (RW) -- SAM PLL proportional shift.
        pub const SAM_KP_LSB: u32 = 8;
        pub const SAM_KP_WIDTH: u32 = 5;
        pub const SAM_KP_MASK: u32 = 0x0000001F;
        pub const SAM_KP_RESET: u32 = 0x00000007;
        /// `sam_ki` (RW) -- SAM PLL integral shift.
        pub const SAM_KI_LSB: u32 = 16;
        pub const SAM_KI_WIDTH: u32 = 5;
        pub const SAM_KI_MASK: u32 = 0x0000001F;
        pub const SAM_KI_RESET: u32 = 0x0000000F;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn k_sm(self) -> u32 {
                (self.0 >> K_SM_LSB) & K_SM_MASK
            }
            pub fn with_k_sm(self, v: u32) -> Self {
                Value((self.0 & !(K_SM_MASK << K_SM_LSB)) | ((v & K_SM_MASK) << K_SM_LSB))
            }
            pub fn k_dc(self) -> u32 {
                (self.0 >> K_DC_LSB) & K_DC_MASK
            }
            pub fn with_k_dc(self, v: u32) -> Self {
                Value((self.0 & !(K_DC_MASK << K_DC_LSB)) | ((v & K_DC_MASK) << K_DC_LSB))
            }
            pub fn sam_kp(self) -> u32 {
                (self.0 >> SAM_KP_LSB) & SAM_KP_MASK
            }
            pub fn with_sam_kp(self, v: u32) -> Self {
                Value((self.0 & !(SAM_KP_MASK << SAM_KP_LSB)) | ((v & SAM_KP_MASK) << SAM_KP_LSB))
            }
            pub fn sam_ki(self) -> u32 {
                (self.0 >> SAM_KI_LSB) & SAM_KI_MASK
            }
            pub fn with_sam_ki(self, v: u32) -> Self {
                Value((self.0 & !(SAM_KI_MASK << SAM_KI_LSB)) | ((v & SAM_KI_MASK) << SAM_KI_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: Value) {
            r.write32(addr(index), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, index: u32, f: impl FnOnce(Value) -> Value) {
            write(r, index, f(read(r, index)))
        }
    }

    /// `fm_deemph` -- FM de-emphasis one-pole coefficient.
    pub mod fm_deemph {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x0000012C;
        pub const STRIDE: u32 = 0x00000080;
        pub const COUNT: u32 = 8;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "fm_deemph index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `alpha` (RW) -- U0.17, round(2^17 * (1 - exp(-1 / (tau * 24000)))); 0 = off. 50 us: 0x1217C, 75 us: 0xDA3D.
        pub const ALPHA_LSB: u32 = 0;
        pub const ALPHA_WIDTH: u32 = 17;
        pub const ALPHA_MASK: u32 = 0x0001FFFF;
        pub const ALPHA_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn alpha(self) -> u32 {
                (self.0 >> ALPHA_LSB) & ALPHA_MASK
            }
            pub fn with_alpha(self, v: u32) -> Self {
                Value((self.0 & !(ALPHA_MASK << ALPHA_LSB)) | ((v & ALPHA_MASK) << ALPHA_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: Value) {
            r.write32(addr(index), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, index: u32, f: impl FnOnce(Value) -> Value) {
            write(r, index, f(read(r, index)))
        }
    }

    /// `squelch` -- Squelch levels on the S-meter scale (1/64 dB, signed).
    pub mod squelch {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000130;
        pub const STRIDE: u32 = 0x00000080;
        pub const COUNT: u32 = 8;
        pub const RESET: u32 = 0xE600E700;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "squelch index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `open` (RW) -- Opens above this level (-100 dB).
        pub const OPEN_LSB: u32 = 0;
        pub const OPEN_WIDTH: u32 = 16;
        pub const OPEN_MASK: u32 = 0x0000FFFF;
        pub const OPEN_RESET: u32 = 0x0000E700;
        /// `close` (RW) -- Closes below this level (-104 dB).
        pub const CLOSE_LSB: u32 = 16;
        pub const CLOSE_WIDTH: u32 = 16;
        pub const CLOSE_MASK: u32 = 0x0000FFFF;
        pub const CLOSE_RESET: u32 = 0x0000E600;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn open(self) -> u32 {
                (self.0 >> OPEN_LSB) & OPEN_MASK
            }
            pub fn with_open(self, v: u32) -> Self {
                Value((self.0 & !(OPEN_MASK << OPEN_LSB)) | ((v & OPEN_MASK) << OPEN_LSB))
            }
            pub fn close(self) -> u32 {
                (self.0 >> CLOSE_LSB) & CLOSE_MASK
            }
            pub fn with_close(self, v: u32) -> Self {
                Value((self.0 & !(CLOSE_MASK << CLOSE_LSB)) | ((v & CLOSE_MASK) << CLOSE_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: Value) {
            r.write32(addr(index), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, index: u32, f: impl FnOnce(Value) -> Value) {
            write(r, index, f(read(r, index)))
        }
    }

    /// `rx_status` -- S-meter and state.
    pub mod rx_status {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000134;
        pub const STRIDE: u32 = 0x00000080;
        pub const COUNT: u32 = 8;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "rx_status index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `smeter` (RO) -- Level in 1/64 dB relative to an envelope of 2^23 (signed).
        pub const SMETER_LSB: u32 = 0;
        pub const SMETER_WIDTH: u32 = 16;
        pub const SMETER_MASK: u32 = 0x0000FFFF;
        pub const SMETER_RESET: u32 = 0x00000000;
        /// `sq_open` (RO) -- 1 = squelch open.
        pub const SQ_OPEN_LSB: u32 = 16;
        pub const SQ_OPEN_WIDTH: u32 = 1;
        pub const SQ_OPEN_MASK: u32 = 0x00000001;
        pub const SQ_OPEN_RESET: u32 = 0x00000000;
        /// `bank_cur` (RO) -- Bank the channel filter used for its last sample.
        pub const BANK_CUR_LSB: u32 = 17;
        pub const BANK_CUR_WIDTH: u32 = 3;
        pub const BANK_CUR_MASK: u32 = 0x00000007;
        pub const BANK_CUR_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn smeter(self) -> u32 {
                (self.0 >> SMETER_LSB) & SMETER_MASK
            }
            pub fn sq_open(self) -> bool {
                (self.0 >> SQ_OPEN_LSB) & 1 != 0
            }
            pub fn bank_cur(self) -> u32 {
                (self.0 >> BANK_CUR_LSB) & BANK_CUR_MASK
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
    }

    /// `agc_gain` -- Gain applied to the last sample, log2 S.10 (signed 18 bits, sign-extended).
    pub mod agc_gain {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000138;
        pub const STRIDE: u32 = 0x00000080;
        pub const COUNT: u32 = 8;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "agc_gain index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> u32 {
            r.read32(addr(index))
        }
    }

    /// `blanked` -- Input samples the blanker replaced since enable (wraps).
    pub mod blanked {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x0000013C;
        pub const STRIDE: u32 = 0x00000080;
        pub const COUNT: u32 = 8;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "blanked index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> u32 {
            r.read32(addr(index))
        }
    }

    /// `stamp_base_lo` -- HL2 index latched when the first bank sample after enable arrived, bits 31:0.
    pub mod stamp_base_lo {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000140;
        pub const STRIDE: u32 = 0x00000080;
        pub const COUNT: u32 = 8;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "stamp_base_lo index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> u32 {
            r.read32(addr(index))
        }
    }

    /// `stamp_base_hi` -- Same, bits 47:32 in 15:0.
    pub mod stamp_base_hi {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000144;
        pub const STRIDE: u32 = 0x00000080;
        pub const COUNT: u32 = 8;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "stamp_base_hi index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> u32 {
            r.read32(addr(index))
        }
    }

    /// `out_count` -- Output samples produced since enable (wraps).
    pub mod out_count {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000148;
        pub const STRIDE: u32 = 0x00000080;
        pub const COUNT: u32 = 8;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "out_count index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> u32 {
            r.read32(addr(index))
        }
    }

    /// `ring_base` -- Output ring in DDR3: address of slot 0, in 64-bit lane words.
    pub mod ring_base {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000150;
        pub const STRIDE: u32 = 0x00000080;
        pub const COUNT: u32 = 8;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "ring_base index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> u32 {
            r.read32(addr(index))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: u32) {
            r.write32(addr(index), value)
        }
    }

    /// `ring_slots` -- Output ring size in blocks (slots), a power of two (log2 in bits 3:0).
    pub mod ring_slots {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000154;
        pub const STRIDE: u32 = 0x00000080;
        pub const COUNT: u32 = 8;
        pub const RESET: u32 = 0x00000004;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "ring_slots index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `log2` (RW) -- Ring holds 2^log2 blocks.
        pub const LOG2_LSB: u32 = 0;
        pub const LOG2_WIDTH: u32 = 4;
        pub const LOG2_MASK: u32 = 0x0000000F;
        pub const LOG2_RESET: u32 = 0x00000004;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn log2(self) -> u32 {
                (self.0 >> LOG2_LSB) & LOG2_MASK
            }
            pub fn with_log2(self, v: u32) -> Self {
                Value((self.0 & !(LOG2_MASK << LOG2_LSB)) | ((v & LOG2_MASK) << LOG2_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: Value) {
            r.write32(addr(index), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, index: u32, f: impl FnOnce(Value) -> Value) {
            write(r, index, f(read(r, index)))
        }
    }

    /// `ring_ctrl` -- Output ring writer.
    pub mod ring_ctrl {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000158;
        pub const STRIDE: u32 = 0x00000080;
        pub const COUNT: u32 = 8;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "ring_ctrl index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `enable` (RW) -- 1 = write this receiver's blocks to its ring.
        pub const ENABLE_LSB: u32 = 0;
        pub const ENABLE_WIDTH: u32 = 1;
        pub const ENABLE_MASK: u32 = 0x00000001;
        pub const ENABLE_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn enable(self) -> bool {
                (self.0 >> ENABLE_LSB) & 1 != 0
            }
            pub fn with_enable(self, v: bool) -> Self {
                let bit = (v as u32) << ENABLE_LSB;
                Value((self.0 & !(ENABLE_MASK << ENABLE_LSB)) | bit)
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: Value) {
            r.write32(addr(index), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, index: u32, f: impl FnOnce(Value) -> Value) {
            write(r, index, f(read(r, index)))
        }
    }

    /// `ring_wptr` -- Blocks completely written to the ring since ring_ctrl.enable was set (the slot index is this modulo the ring size). A block is counted only after its header is written.
    pub mod ring_wptr {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x0000015C;
        pub const STRIDE: u32 = 0x00000080;
        pub const COUNT: u32 = 8;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "ring_wptr index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> u32 {
            r.read32(addr(index))
        }
    }

    /// `coef` -- Coefficient window into the bank chosen by coef_sel: index 2n = tap n real part, 2n+1 = imaginary part, signed 32 bits. Write-only (reads return 0).
    pub mod coef {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00008000;
        pub const STRIDE: u32 = 0x00000004;
        pub const COUNT: u32 = 2048;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "coef index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> u32 {
            r.read32(addr(index))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: u32) {
            r.write32(addr(index), value)
        }
    }
}

/// `rx_bank` register block (base 0xe8030000).
///
/// Receiver bank (docs/ARCHITECTURE.md 3.2): per-receiver NCO phase increment and control for the
/// CORDIC/CIC/FIR chain in rtl/rx/rx_bank.v (branch rx-dsp). N = 4 to 8 receivers, one register
/// port, one shared IQ output stream (not in this register block; see the IQ writer at
/// 0xE804_0000).
/// status: draft
pub mod rx_bank {
    pub const BASE: u32 = 0xE8030000;
    pub const SIZE: u32 = 0x00010000;

    /// `id` -- Block identifier/version: 'RX' + version 1 (set by the chip top level).
    pub mod id {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000000;
        pub const RESET: u32 = 0x52580001;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `phase_inc` -- Per-receiver NCO phase increment: round(f_Hz / 76.8e6 * 2^32), signed two's complement, relative to the HL2 ADC clock (0.018 Hz steps).
    pub mod phase_inc {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000004;
        pub const STRIDE: u32 = 0x00000008;
        pub const COUNT: u32 = 8;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "phase_inc index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `value` (RW) -- Signed 32-bit phase increment.
        pub const VALUE_LSB: u32 = 0;
        pub const VALUE_WIDTH: u32 = 32;
        pub const VALUE_MASK: u32 = 0xFFFFFFFF;
        pub const VALUE_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn value(self) -> u32 {
                (self.0 >> VALUE_LSB) & VALUE_MASK
            }
            pub fn with_value(self, v: u32) -> Self {
                Value((self.0 & !(VALUE_MASK << VALUE_LSB)) | ((v & VALUE_MASK) << VALUE_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: Value) {
            r.write32(addr(index), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, index: u32, f: impl FnOnce(Value) -> Value) {
            write(r, index, f(read(r, index)))
        }
    }

    /// `ctrl` -- Per-receiver enable and output rate.
    pub mod ctrl {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000008;
        pub const STRIDE: u32 = 0x00000008;
        pub const COUNT: u32 = 8;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "ctrl index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `enable` (RW) -- 1 = receiver running and contributing to the shared IQ output stream.
        pub const ENABLE_LSB: u32 = 0;
        pub const ENABLE_WIDTH: u32 = 1;
        pub const ENABLE_MASK: u32 = 0x00000001;
        pub const ENABLE_RESET: u32 = 0x00000000;
        /// `rate_sel` (RW) -- Output sample rate: 0 = 48 kHz, 1 = 96 kHz, 2 = 192 kHz, 3 = 384 kHz (of HL2 time).
        pub const RATE_SEL_LSB: u32 = 1;
        pub const RATE_SEL_WIDTH: u32 = 2;
        pub const RATE_SEL_MASK: u32 = 0x00000003;
        pub const RATE_SEL_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn enable(self) -> bool {
                (self.0 >> ENABLE_LSB) & 1 != 0
            }
            pub fn with_enable(self, v: bool) -> Self {
                let bit = (v as u32) << ENABLE_LSB;
                Value((self.0 & !(ENABLE_MASK << ENABLE_LSB)) | bit)
            }
            pub fn rate_sel(self) -> u32 {
                (self.0 >> RATE_SEL_LSB) & RATE_SEL_MASK
            }
            pub fn with_rate_sel(self, v: u32) -> Self {
                Value(
                    (self.0 & !(RATE_SEL_MASK << RATE_SEL_LSB))
                        | ((v & RATE_SEL_MASK) << RATE_SEL_LSB),
                )
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: Value) {
            r.write32(addr(index), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, index: u32, f: impl FnOnce(Value) -> Value) {
            write(r, index, f(read(r, index)))
        }
    }
}

/// `sfp` register block (base 0xe80a0000).
///
/// The transceiver of the two SFP+ cages (docs/SFP_LINKS.md): reset and status of both lanes, the cage
/// pins, the I2C pins of the board and its multiplexer select as plain bits (firmware runs the I2C
/// protocol: clock chip, module memories), and the network socket on SFP0: PCS and MAC settings,
/// status, counters and the packet memory. rtl/sfp/sfp_top.v. All in clk_dsp; the page works with
/// the lane clocks stopped.
/// status: draft
pub mod sfp {
    pub const BASE: u32 = 0xE80A0000;
    pub const SIZE: u32 = 0x00010000;

    /// `id` -- Block identifier: SF + version 1.
    pub mod id {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000000;
        pub const RESET: u32 = 0x53460001;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `serdes_ctrl` -- Transceiver resets and line fixes. Start-up order: docs/SFP_LINKS.md 2.3.
    pub mod serdes_ctrl {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000004;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `por_n` (RW) -- 0 = the whole transceiver held in reset (its por_n_i input; only in a build with SFP_POR_FABRIC=1, else no effect). Set to 1 only after the 125 MHz reference runs.
        pub const POR_N_LSB: u32 = 0;
        pub const POR_N_WIDTH: u32 = 1;
        pub const POR_N_MASK: u32 = 0x00000001;
        pub const POR_N_RESET: u32 = 0x00000000;
        /// `ln0_rst_n` (RW) -- 0 = lane 0 (SFP0, network) held in reset, its lane PLL included (pma_rstn_i). Release it to let the PLL lock.
        pub const LN0_RST_N_LSB: u32 = 1;
        pub const LN0_RST_N_WIDTH: u32 = 1;
        pub const LN0_RST_N_MASK: u32 = 0x00000001;
        pub const LN0_RST_N_RESET: u32 = 0x00000000;
        /// `ln1_rst_n` (RW) -- 0 = lane 1 (SFP1, board link) held in reset.
        pub const LN1_RST_N_LSB: u32 = 2;
        pub const LN1_RST_N_WIDTH: u32 = 1;
        pub const LN1_RST_N_MASK: u32 = 0x00000001;
        pub const LN1_RST_N_RESET: u32 = 0x00000000;
        /// `ln0_rx_rst` (RW) -- 1 = receive side of lane 0 in reset (pulse it when the lane does not lock).
        pub const LN0_RX_RST_LSB: u32 = 3;
        pub const LN0_RX_RST_WIDTH: u32 = 1;
        pub const LN0_RX_RST_MASK: u32 = 0x00000001;
        pub const LN0_RX_RST_RESET: u32 = 0x00000000;
        /// `ln1_rx_rst` (RW) -- 1 = receive side of lane 1 in reset.
        pub const LN1_RX_RST_LSB: u32 = 4;
        pub const LN1_RX_RST_WIDTH: u32 = 1;
        pub const LN1_RX_RST_MASK: u32 = 0x00000001;
        pub const LN1_RX_RST_RESET: u32 = 0x00000000;
        /// `ln0_tx_rst` (RW) -- 1 = transmit side of lane 0 in reset.
        pub const LN0_TX_RST_LSB: u32 = 5;
        pub const LN0_TX_RST_WIDTH: u32 = 1;
        pub const LN0_TX_RST_MASK: u32 = 0x00000001;
        pub const LN0_TX_RST_RESET: u32 = 0x00000000;
        /// `ln1_tx_rst` (RW) -- 1 = transmit side of lane 1 in reset.
        pub const LN1_TX_RST_LSB: u32 = 6;
        pub const LN1_TX_RST_WIDTH: u32 = 1;
        pub const LN1_TX_RST_MASK: u32 = 0x00000001;
        pub const LN1_TX_RST_RESET: u32 = 0x00000000;
        /// `ln0_fix` (RW) -- Lane 0 line fixes, in case the board shows them needed: bit 0 transmit bit order reversed within a symbol, 1 receive reversed, 2 transmit inverted, 3 receive inverted.
        pub const LN0_FIX_LSB: u32 = 8;
        pub const LN0_FIX_WIDTH: u32 = 4;
        pub const LN0_FIX_MASK: u32 = 0x0000000F;
        pub const LN0_FIX_RESET: u32 = 0x00000000;
        /// `ln1_fix` (RW) -- Lane 1 line fixes, same bits.
        pub const LN1_FIX_LSB: u32 = 12;
        pub const LN1_FIX_WIDTH: u32 = 4;
        pub const LN1_FIX_MASK: u32 = 0x0000000F;
        pub const LN1_FIX_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn por_n(self) -> bool {
                (self.0 >> POR_N_LSB) & 1 != 0
            }
            pub fn with_por_n(self, v: bool) -> Self {
                let bit = (v as u32) << POR_N_LSB;
                Value((self.0 & !(POR_N_MASK << POR_N_LSB)) | bit)
            }
            pub fn ln0_rst_n(self) -> bool {
                (self.0 >> LN0_RST_N_LSB) & 1 != 0
            }
            pub fn with_ln0_rst_n(self, v: bool) -> Self {
                let bit = (v as u32) << LN0_RST_N_LSB;
                Value((self.0 & !(LN0_RST_N_MASK << LN0_RST_N_LSB)) | bit)
            }
            pub fn ln1_rst_n(self) -> bool {
                (self.0 >> LN1_RST_N_LSB) & 1 != 0
            }
            pub fn with_ln1_rst_n(self, v: bool) -> Self {
                let bit = (v as u32) << LN1_RST_N_LSB;
                Value((self.0 & !(LN1_RST_N_MASK << LN1_RST_N_LSB)) | bit)
            }
            pub fn ln0_rx_rst(self) -> bool {
                (self.0 >> LN0_RX_RST_LSB) & 1 != 0
            }
            pub fn with_ln0_rx_rst(self, v: bool) -> Self {
                let bit = (v as u32) << LN0_RX_RST_LSB;
                Value((self.0 & !(LN0_RX_RST_MASK << LN0_RX_RST_LSB)) | bit)
            }
            pub fn ln1_rx_rst(self) -> bool {
                (self.0 >> LN1_RX_RST_LSB) & 1 != 0
            }
            pub fn with_ln1_rx_rst(self, v: bool) -> Self {
                let bit = (v as u32) << LN1_RX_RST_LSB;
                Value((self.0 & !(LN1_RX_RST_MASK << LN1_RX_RST_LSB)) | bit)
            }
            pub fn ln0_tx_rst(self) -> bool {
                (self.0 >> LN0_TX_RST_LSB) & 1 != 0
            }
            pub fn with_ln0_tx_rst(self, v: bool) -> Self {
                let bit = (v as u32) << LN0_TX_RST_LSB;
                Value((self.0 & !(LN0_TX_RST_MASK << LN0_TX_RST_LSB)) | bit)
            }
            pub fn ln1_tx_rst(self) -> bool {
                (self.0 >> LN1_TX_RST_LSB) & 1 != 0
            }
            pub fn with_ln1_tx_rst(self, v: bool) -> Self {
                let bit = (v as u32) << LN1_TX_RST_LSB;
                Value((self.0 & !(LN1_TX_RST_MASK << LN1_TX_RST_LSB)) | bit)
            }
            pub fn ln0_fix(self) -> u32 {
                (self.0 >> LN0_FIX_LSB) & LN0_FIX_MASK
            }
            pub fn with_ln0_fix(self, v: u32) -> Self {
                Value(
                    (self.0 & !(LN0_FIX_MASK << LN0_FIX_LSB)) | ((v & LN0_FIX_MASK) << LN0_FIX_LSB),
                )
            }
            pub fn ln1_fix(self) -> u32 {
                (self.0 >> LN1_FIX_LSB) & LN1_FIX_MASK
            }
            pub fn with_ln1_fix(self, v: u32) -> Self {
                Value(
                    (self.0 & !(LN1_FIX_MASK << LN1_FIX_LSB)) | ((v & LN1_FIX_MASK) << LN1_FIX_LSB),
                )
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `serdes_status` -- Transceiver status, both lanes.
    pub mod serdes_status {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000008;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `ln0_pll_lock` (RO) -- Lane 0 transmit PLL locked to the reference.
        pub const LN0_PLL_LOCK_LSB: u32 = 0;
        pub const LN0_PLL_LOCK_WIDTH: u32 = 1;
        pub const LN0_PLL_LOCK_MASK: u32 = 0x00000001;
        pub const LN0_PLL_LOCK_RESET: u32 = 0x00000000;
        /// `ln0_cdr_lock` (RO) -- Lane 0 receive clock recovered.
        pub const LN0_CDR_LOCK_LSB: u32 = 1;
        pub const LN0_CDR_LOCK_WIDTH: u32 = 1;
        pub const LN0_CDR_LOCK_MASK: u32 = 0x00000001;
        pub const LN0_CDR_LOCK_RESET: u32 = 0x00000000;
        /// `ln0_signal` (RO) -- Lane 0 signal detected at the receiver.
        pub const LN0_SIGNAL_LSB: u32 = 2;
        pub const LN0_SIGNAL_WIDTH: u32 = 1;
        pub const LN0_SIGNAL_MASK: u32 = 0x00000001;
        pub const LN0_SIGNAL_RESET: u32 = 0x00000000;
        /// `ln0_ready` (RO) -- Lane 0 ready.
        pub const LN0_READY_LSB: u32 = 3;
        pub const LN0_READY_WIDTH: u32 = 1;
        pub const LN0_READY_MASK: u32 = 0x00000001;
        pub const LN0_READY_RESET: u32 = 0x00000000;
        /// `ln0_aligned` (RO) -- Lane 0: our comma aligner is locked.
        pub const LN0_ALIGNED_LSB: u32 = 4;
        pub const LN0_ALIGNED_WIDTH: u32 = 1;
        pub const LN0_ALIGNED_MASK: u32 = 0x00000001;
        pub const LN0_ALIGNED_RESET: u32 = 0x00000000;
        /// `ln1_pll_lock` (RO) -- Lane 1 transmit PLL locked.
        pub const LN1_PLL_LOCK_LSB: u32 = 8;
        pub const LN1_PLL_LOCK_WIDTH: u32 = 1;
        pub const LN1_PLL_LOCK_MASK: u32 = 0x00000001;
        pub const LN1_PLL_LOCK_RESET: u32 = 0x00000000;
        /// `ln1_cdr_lock` (RO) -- Lane 1 receive clock recovered.
        pub const LN1_CDR_LOCK_LSB: u32 = 9;
        pub const LN1_CDR_LOCK_WIDTH: u32 = 1;
        pub const LN1_CDR_LOCK_MASK: u32 = 0x00000001;
        pub const LN1_CDR_LOCK_RESET: u32 = 0x00000000;
        /// `ln1_signal` (RO) -- Lane 1 signal detected.
        pub const LN1_SIGNAL_LSB: u32 = 10;
        pub const LN1_SIGNAL_WIDTH: u32 = 1;
        pub const LN1_SIGNAL_MASK: u32 = 0x00000001;
        pub const LN1_SIGNAL_RESET: u32 = 0x00000000;
        /// `ln1_ready` (RO) -- Lane 1 ready.
        pub const LN1_READY_LSB: u32 = 11;
        pub const LN1_READY_WIDTH: u32 = 1;
        pub const LN1_READY_MASK: u32 = 0x00000001;
        pub const LN1_READY_RESET: u32 = 0x00000000;
        /// `ln1_aligned` (RO) -- Lane 1: our comma aligner is locked.
        pub const LN1_ALIGNED_LSB: u32 = 12;
        pub const LN1_ALIGNED_WIDTH: u32 = 1;
        pub const LN1_ALIGNED_MASK: u32 = 0x00000001;
        pub const LN1_ALIGNED_RESET: u32 = 0x00000000;
        /// `q_cmu0_ok` (RO) -- Quad 1 CMU0 OK (the quad's own status, docs/SFP_LINKS.md 2.3).
        pub const Q_CMU0_OK_LSB: u32 = 16;
        pub const Q_CMU0_OK_WIDTH: u32 = 1;
        pub const Q_CMU0_OK_MASK: u32 = 0x00000001;
        pub const Q_CMU0_OK_RESET: u32 = 0x00000000;
        /// `q_cmu1_ok` (RO) -- Quad 1 CMU1 OK.
        pub const Q_CMU1_OK_LSB: u32 = 17;
        pub const Q_CMU1_OK_WIDTH: u32 = 1;
        pub const Q_CMU1_OK_MASK: u32 = 0x00000001;
        pub const Q_CMU1_OK_RESET: u32 = 0x00000000;
        /// `q_refclk_det0` (RO) -- Quad 1 reference detect, CM0.
        pub const Q_REFCLK_DET0_LSB: u32 = 18;
        pub const Q_REFCLK_DET0_WIDTH: u32 = 1;
        pub const Q_REFCLK_DET0_MASK: u32 = 0x00000001;
        pub const Q_REFCLK_DET0_RESET: u32 = 0x00000000;
        /// `q_refclk_det1` (RO) -- Quad 1 reference detect, CM1.
        pub const Q_REFCLK_DET1_LSB: u32 = 19;
        pub const Q_REFCLK_DET1_WIDTH: u32 = 1;
        pub const Q_REFCLK_DET1_MASK: u32 = 0x00000001;
        pub const Q_REFCLK_DET1_RESET: u32 = 0x00000000;
        /// `ln0_cmu_ok` (RO) -- Lane 0 CMU OK.
        pub const LN0_CMU_OK_LSB: u32 = 20;
        pub const LN0_CMU_OK_WIDTH: u32 = 1;
        pub const LN0_CMU_OK_MASK: u32 = 0x00000001;
        pub const LN0_CMU_OK_RESET: u32 = 0x00000000;
        /// `ln1_cmu_ok` (RO) -- Lane 1 CMU OK.
        pub const LN1_CMU_OK_LSB: u32 = 21;
        pub const LN1_CMU_OK_WIDTH: u32 = 1;
        pub const LN1_CMU_OK_MASK: u32 = 0x00000001;
        pub const LN1_CMU_OK_RESET: u32 = 0x00000000;
        /// `ln0_pma_rx_lock` (RO) -- Lane 0 PMA receive lock.
        pub const LN0_PMA_RX_LOCK_LSB: u32 = 22;
        pub const LN0_PMA_RX_LOCK_WIDTH: u32 = 1;
        pub const LN0_PMA_RX_LOCK_MASK: u32 = 0x00000001;
        pub const LN0_PMA_RX_LOCK_RESET: u32 = 0x00000000;
        /// `ln1_pma_rx_lock` (RO) -- Lane 1 PMA receive lock.
        pub const LN1_PMA_RX_LOCK_LSB: u32 = 23;
        pub const LN1_PMA_RX_LOCK_WIDTH: u32 = 1;
        pub const LN1_PMA_RX_LOCK_MASK: u32 = 0x00000001;
        pub const LN1_PMA_RX_LOCK_RESET: u32 = 0x00000000;
        /// `ln0_tx_gap` (RO) -- Lane 0: a transmit word was not written (buffer almost full) since its transmit reset was released. Sticky.
        pub const LN0_TX_GAP_LSB: u32 = 24;
        pub const LN0_TX_GAP_WIDTH: u32 = 1;
        pub const LN0_TX_GAP_MASK: u32 = 0x00000001;
        pub const LN0_TX_GAP_RESET: u32 = 0x00000000;
        /// `ln0_rx_gap` (RO) -- Lane 0: a receive clock without a word (buffer almost empty) since its receive reset was released. Sticky.
        pub const LN0_RX_GAP_LSB: u32 = 25;
        pub const LN0_RX_GAP_WIDTH: u32 = 1;
        pub const LN0_RX_GAP_MASK: u32 = 0x00000001;
        pub const LN0_RX_GAP_RESET: u32 = 0x00000000;
        /// `ln1_tx_gap` (RO) -- Lane 1: a transmit word was not written since its transmit reset was released. Sticky.
        pub const LN1_TX_GAP_LSB: u32 = 26;
        pub const LN1_TX_GAP_WIDTH: u32 = 1;
        pub const LN1_TX_GAP_MASK: u32 = 0x00000001;
        pub const LN1_TX_GAP_RESET: u32 = 0x00000000;
        /// `ln1_rx_gap` (RO) -- Lane 1: a receive clock without a word since its receive reset was released. Sticky.
        pub const LN1_RX_GAP_LSB: u32 = 27;
        pub const LN1_RX_GAP_WIDTH: u32 = 1;
        pub const LN1_RX_GAP_MASK: u32 = 0x00000001;
        pub const LN1_RX_GAP_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn ln0_pll_lock(self) -> bool {
                (self.0 >> LN0_PLL_LOCK_LSB) & 1 != 0
            }
            pub fn ln0_cdr_lock(self) -> bool {
                (self.0 >> LN0_CDR_LOCK_LSB) & 1 != 0
            }
            pub fn ln0_signal(self) -> bool {
                (self.0 >> LN0_SIGNAL_LSB) & 1 != 0
            }
            pub fn ln0_ready(self) -> bool {
                (self.0 >> LN0_READY_LSB) & 1 != 0
            }
            pub fn ln0_aligned(self) -> bool {
                (self.0 >> LN0_ALIGNED_LSB) & 1 != 0
            }
            pub fn ln1_pll_lock(self) -> bool {
                (self.0 >> LN1_PLL_LOCK_LSB) & 1 != 0
            }
            pub fn ln1_cdr_lock(self) -> bool {
                (self.0 >> LN1_CDR_LOCK_LSB) & 1 != 0
            }
            pub fn ln1_signal(self) -> bool {
                (self.0 >> LN1_SIGNAL_LSB) & 1 != 0
            }
            pub fn ln1_ready(self) -> bool {
                (self.0 >> LN1_READY_LSB) & 1 != 0
            }
            pub fn ln1_aligned(self) -> bool {
                (self.0 >> LN1_ALIGNED_LSB) & 1 != 0
            }
            pub fn q_cmu0_ok(self) -> bool {
                (self.0 >> Q_CMU0_OK_LSB) & 1 != 0
            }
            pub fn q_cmu1_ok(self) -> bool {
                (self.0 >> Q_CMU1_OK_LSB) & 1 != 0
            }
            pub fn q_refclk_det0(self) -> bool {
                (self.0 >> Q_REFCLK_DET0_LSB) & 1 != 0
            }
            pub fn q_refclk_det1(self) -> bool {
                (self.0 >> Q_REFCLK_DET1_LSB) & 1 != 0
            }
            pub fn ln0_cmu_ok(self) -> bool {
                (self.0 >> LN0_CMU_OK_LSB) & 1 != 0
            }
            pub fn ln1_cmu_ok(self) -> bool {
                (self.0 >> LN1_CMU_OK_LSB) & 1 != 0
            }
            pub fn ln0_pma_rx_lock(self) -> bool {
                (self.0 >> LN0_PMA_RX_LOCK_LSB) & 1 != 0
            }
            pub fn ln1_pma_rx_lock(self) -> bool {
                (self.0 >> LN1_PMA_RX_LOCK_LSB) & 1 != 0
            }
            pub fn ln0_tx_gap(self) -> bool {
                (self.0 >> LN0_TX_GAP_LSB) & 1 != 0
            }
            pub fn ln0_rx_gap(self) -> bool {
                (self.0 >> LN0_RX_GAP_LSB) & 1 != 0
            }
            pub fn ln1_tx_gap(self) -> bool {
                (self.0 >> LN1_TX_GAP_LSB) & 1 != 0
            }
            pub fn ln1_rx_gap(self) -> bool {
                (self.0 >> LN1_RX_GAP_LSB) & 1 != 0
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
    }

    /// `cage` -- Cage pins.
    pub mod cage {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x0000000C;
        pub const RESET: u32 = 0x00000003;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `sfp0_tx_disable` (RW) -- 1 = SFP0 module transmitter off (pin R18).
        pub const SFP0_TX_DISABLE_LSB: u32 = 0;
        pub const SFP0_TX_DISABLE_WIDTH: u32 = 1;
        pub const SFP0_TX_DISABLE_MASK: u32 = 0x00000001;
        pub const SFP0_TX_DISABLE_RESET: u32 = 0x00000001;
        /// `sfp1_tx_disable` (RW) -- 1 = SFP1 module transmitter off (pin M20).
        pub const SFP1_TX_DISABLE_LSB: u32 = 1;
        pub const SFP1_TX_DISABLE_WIDTH: u32 = 1;
        pub const SFP1_TX_DISABLE_MASK: u32 = 0x00000001;
        pub const SFP1_TX_DISABLE_RESET: u32 = 0x00000001;
        /// `sfp0_los` (RO) -- SFP0 loss-of-signal pin (V18). Meaningless with a passive cable.
        pub const SFP0_LOS_LSB: u32 = 8;
        pub const SFP0_LOS_WIDTH: u32 = 1;
        pub const SFP0_LOS_MASK: u32 = 0x00000001;
        pub const SFP0_LOS_RESET: u32 = 0x00000000;
        /// `sfp1_los` (RO) -- SFP1 loss-of-signal pin (W18).
        pub const SFP1_LOS_LSB: u32 = 9;
        pub const SFP1_LOS_WIDTH: u32 = 1;
        pub const SFP1_LOS_MASK: u32 = 0x00000001;
        pub const SFP1_LOS_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn sfp0_tx_disable(self) -> bool {
                (self.0 >> SFP0_TX_DISABLE_LSB) & 1 != 0
            }
            pub fn with_sfp0_tx_disable(self, v: bool) -> Self {
                let bit = (v as u32) << SFP0_TX_DISABLE_LSB;
                Value((self.0 & !(SFP0_TX_DISABLE_MASK << SFP0_TX_DISABLE_LSB)) | bit)
            }
            pub fn sfp1_tx_disable(self) -> bool {
                (self.0 >> SFP1_TX_DISABLE_LSB) & 1 != 0
            }
            pub fn with_sfp1_tx_disable(self, v: bool) -> Self {
                let bit = (v as u32) << SFP1_TX_DISABLE_LSB;
                Value((self.0 & !(SFP1_TX_DISABLE_MASK << SFP1_TX_DISABLE_LSB)) | bit)
            }
            pub fn sfp0_los(self) -> bool {
                (self.0 >> SFP0_LOS_LSB) & 1 != 0
            }
            pub fn sfp1_los(self) -> bool {
                (self.0 >> SFP1_LOS_LSB) & 1 != 0
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
    }

    /// `twi` -- The system I2C bus of the board, bit by bit, and its 8-way multiplexer.
    pub mod twi {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000010;
        pub const RESET: u32 = 0x00000003;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `scl` (RW) -- 0 = pull SCL (K25) low, 1 = release it.
        pub const SCL_LSB: u32 = 0;
        pub const SCL_WIDTH: u32 = 1;
        pub const SCL_MASK: u32 = 0x00000001;
        pub const SCL_RESET: u32 = 0x00000001;
        /// `sda` (RW) -- 0 = pull SDA (K26) low, 1 = release it.
        pub const SDA_LSB: u32 = 1;
        pub const SDA_WIDTH: u32 = 1;
        pub const SDA_MASK: u32 = 0x00000001;
        pub const SDA_RESET: u32 = 0x00000001;
        /// `sel` (RW) -- Multiplexer select pins: bit 2 N19, bit 1 P19, bit 0 P26. N19 is the multiplexer's LEAST significant select input, so channel c is written as c bit 0 in field bit 2, c bit 2 in field bit 0 (fw/tr-fabric/src/sfp.rs channel::sel_bits). Channels: 0 SFP0 module, 1 SFP1 module, 3 clock chip PLL0 (transceiver reference), 4 clock chip PLL1.
        pub const SEL_LSB: u32 = 2;
        pub const SEL_WIDTH: u32 = 3;
        pub const SEL_MASK: u32 = 0x00000007;
        pub const SEL_RESET: u32 = 0x00000000;
        /// `scl_in` (RO) -- Level on SCL.
        pub const SCL_IN_LSB: u32 = 8;
        pub const SCL_IN_WIDTH: u32 = 1;
        pub const SCL_IN_MASK: u32 = 0x00000001;
        pub const SCL_IN_RESET: u32 = 0x00000000;
        /// `sda_in` (RO) -- Level on SDA.
        pub const SDA_IN_LSB: u32 = 9;
        pub const SDA_IN_WIDTH: u32 = 1;
        pub const SDA_IN_MASK: u32 = 0x00000001;
        pub const SDA_IN_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn scl(self) -> bool {
                (self.0 >> SCL_LSB) & 1 != 0
            }
            pub fn with_scl(self, v: bool) -> Self {
                let bit = (v as u32) << SCL_LSB;
                Value((self.0 & !(SCL_MASK << SCL_LSB)) | bit)
            }
            pub fn sda(self) -> bool {
                (self.0 >> SDA_LSB) & 1 != 0
            }
            pub fn with_sda(self, v: bool) -> Self {
                let bit = (v as u32) << SDA_LSB;
                Value((self.0 & !(SDA_MASK << SDA_LSB)) | bit)
            }
            pub fn sel(self) -> u32 {
                (self.0 >> SEL_LSB) & SEL_MASK
            }
            pub fn with_sel(self, v: u32) -> Self {
                Value((self.0 & !(SEL_MASK << SEL_LSB)) | ((v & SEL_MASK) << SEL_LSB))
            }
            pub fn scl_in(self) -> bool {
                (self.0 >> SCL_IN_LSB) & 1 != 0
            }
            pub fn sda_in(self) -> bool {
                (self.0 >> SDA_IN_LSB) & 1 != 0
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
    }

    /// `net_ctrl` -- Network socket (SFP0) settings.
    pub mod net_ctrl {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000020;
        pub const RESET: u32 = 0x00000004;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `enable` (RW) -- 0 = PCS and MAC held in reset; counters and ring pointers cleared (write rx_rd_ptr 0 too).
        pub const ENABLE_LSB: u32 = 0;
        pub const ENABLE_WIDTH: u32 = 1;
        pub const ENABLE_MASK: u32 = 0x00000001;
        pub const ENABLE_RESET: u32 = 0x00000000;
        /// `sgmii` (RW) -- 0 = 1000BASE-X, 1 = SGMII (a 1000BASE-T copper module in SGMII mode).
        pub const SGMII_LSB: u32 = 1;
        pub const SGMII_WIDTH: u32 = 1;
        pub const SGMII_MASK: u32 = 0x00000001;
        pub const SGMII_RESET: u32 = 0x00000000;
        /// `autoneg` (RW) -- 1 = auto-negotiation (clause 37, or the SGMII exchange). 0 = none: idle at once, link up when idles arrive.
        pub const AUTONEG_LSB: u32 = 2;
        pub const AUTONEG_WIDTH: u32 = 1;
        pub const AUTONEG_MASK: u32 = 0x00000001;
        pub const AUTONEG_RESET: u32 = 0x00000001;
        /// `restart` (RW) -- Write 1: restart the negotiation. Reads 0.
        pub const RESTART_LSB: u32 = 3;
        pub const RESTART_WIDTH: u32 = 1;
        pub const RESTART_MASK: u32 = 0x00000001;
        pub const RESTART_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn enable(self) -> bool {
                (self.0 >> ENABLE_LSB) & 1 != 0
            }
            pub fn with_enable(self, v: bool) -> Self {
                let bit = (v as u32) << ENABLE_LSB;
                Value((self.0 & !(ENABLE_MASK << ENABLE_LSB)) | bit)
            }
            pub fn sgmii(self) -> bool {
                (self.0 >> SGMII_LSB) & 1 != 0
            }
            pub fn with_sgmii(self, v: bool) -> Self {
                let bit = (v as u32) << SGMII_LSB;
                Value((self.0 & !(SGMII_MASK << SGMII_LSB)) | bit)
            }
            pub fn autoneg(self) -> bool {
                (self.0 >> AUTONEG_LSB) & 1 != 0
            }
            pub fn with_autoneg(self, v: bool) -> Self {
                let bit = (v as u32) << AUTONEG_LSB;
                Value((self.0 & !(AUTONEG_MASK << AUTONEG_LSB)) | bit)
            }
            pub fn restart(self) -> bool {
                (self.0 >> RESTART_LSB) & 1 != 0
            }
            pub fn with_restart(self, v: bool) -> Self {
                let bit = (v as u32) << RESTART_LSB;
                Value((self.0 & !(RESTART_MASK << RESTART_LSB)) | bit)
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `net_status` -- Network socket status.
    pub mod net_status {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000024;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `link_up` (RO) -- Link up: frames can be sent and are received.
        pub const LINK_UP_LSB: u32 = 0;
        pub const LINK_UP_WIDTH: u32 = 1;
        pub const LINK_UP_MASK: u32 = 0x00000001;
        pub const LINK_UP_RESET: u32 = 0x00000000;
        /// `an_done` (RO) -- Negotiation complete.
        pub const AN_DONE_LSB: u32 = 1;
        pub const AN_DONE_WIDTH: u32 = 1;
        pub const AN_DONE_MASK: u32 = 0x00000001;
        pub const AN_DONE_RESET: u32 = 0x00000000;
        /// `rx_sync` (RO) -- Receiver aligned.
        pub const RX_SYNC_LSB: u32 = 2;
        pub const RX_SYNC_WIDTH: u32 = 1;
        pub const RX_SYNC_MASK: u32 = 0x00000001;
        pub const RX_SYNC_RESET: u32 = 0x00000000;
        /// `rx_idle` (RO) -- Idle is being received (three in a row).
        pub const RX_IDLE_LSB: u32 = 3;
        pub const RX_IDLE_WIDTH: u32 = 1;
        pub const RX_IDLE_MASK: u32 = 0x00000001;
        pub const RX_IDLE_RESET: u32 = 0x00000000;
        /// `tx_busy` (RO) -- A frame written with tx_len has not gone out yet.
        pub const TX_BUSY_LSB: u32 = 4;
        pub const TX_BUSY_WIDTH: u32 = 1;
        pub const TX_BUSY_MASK: u32 = 0x00000001;
        pub const TX_BUSY_RESET: u32 = 0x00000000;
        /// `partner` (RO) -- The configuration word of the link partner. SGMII: bit 15 link, 12 full duplex, 11:10 speed (2 = 1000 Mbit/s).
        pub const PARTNER_LSB: u32 = 16;
        pub const PARTNER_WIDTH: u32 = 16;
        pub const PARTNER_MASK: u32 = 0x0000FFFF;
        pub const PARTNER_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn link_up(self) -> bool {
                (self.0 >> LINK_UP_LSB) & 1 != 0
            }
            pub fn an_done(self) -> bool {
                (self.0 >> AN_DONE_LSB) & 1 != 0
            }
            pub fn rx_sync(self) -> bool {
                (self.0 >> RX_SYNC_LSB) & 1 != 0
            }
            pub fn rx_idle(self) -> bool {
                (self.0 >> RX_IDLE_LSB) & 1 != 0
            }
            pub fn tx_busy(self) -> bool {
                (self.0 >> TX_BUSY_LSB) & 1 != 0
            }
            pub fn partner(self) -> u32 {
                (self.0 >> PARTNER_LSB) & PARTNER_MASK
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
    }

    /// `align_losses` -- Times the aligner of lane 0 lost its lock (10 bits).
    pub mod align_losses {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000040;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `code_errors` -- Symbols of lane 0 that are not in the 8b/10b alphabet while its aligner is locked (16 bits, stops at 0xFFFF). Since 2026-10-21.
    pub mod code_errors {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000044;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }
}

/// `spectrum` register block (base 0xe8050000).
///
/// Full-band spectrum (docs/ARCHITECTURE.md 3.3): 16,384-point FFT over the raw 12-bit stream,
/// column reduction, averaging, and the waterfall colour mapping. Output lines land in a
/// double-buffered line buffer and a waterfall ring in DDR3 (not registers, see 3.5); this block
/// is control and status only.
/// status: final
pub mod spectrum {
    pub const BASE: u32 = 0xE8050000;
    pub const SIZE: u32 = 0x00010000;

    /// `id` -- Block identifier/version; rtl/spectrum/spectrum_pipeline.v is version 1.
    pub mod id {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000000;
        pub const RESET: u32 = 0x00000001;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `ctrl` -- Enable and per-column reduction mode.
    pub mod ctrl {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000004;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `enable` (RW) -- 1 = transforms run and lines are produced.
        pub const ENABLE_LSB: u32 = 0;
        pub const ENABLE_WIDTH: u32 = 1;
        pub const ENABLE_MASK: u32 = 0x00000001;
        pub const ENABLE_RESET: u32 = 0x00000000;
        /// `column_mode` (RW) -- 0 = max per column (keeps narrow carriers visible), 1 = mean per column (noise floor), ARCHITECTURE 3.3.
        pub const COLUMN_MODE_LSB: u32 = 1;
        pub const COLUMN_MODE_WIDTH: u32 = 1;
        pub const COLUMN_MODE_MASK: u32 = 0x00000001;
        pub const COLUMN_MODE_RESET: u32 = 0x00000000;
        /// `peak_hold` (RW) -- 1 = averaging BSRAM holds the peak over K transforms instead of the mean.
        pub const PEAK_HOLD_LSB: u32 = 2;
        pub const PEAK_HOLD_WIDTH: u32 = 1;
        pub const PEAK_HOLD_MASK: u32 = 0x00000001;
        pub const PEAK_HOLD_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn enable(self) -> bool {
                (self.0 >> ENABLE_LSB) & 1 != 0
            }
            pub fn with_enable(self, v: bool) -> Self {
                let bit = (v as u32) << ENABLE_LSB;
                Value((self.0 & !(ENABLE_MASK << ENABLE_LSB)) | bit)
            }
            pub fn column_mode(self) -> bool {
                (self.0 >> COLUMN_MODE_LSB) & 1 != 0
            }
            pub fn with_column_mode(self, v: bool) -> Self {
                let bit = (v as u32) << COLUMN_MODE_LSB;
                Value((self.0 & !(COLUMN_MODE_MASK << COLUMN_MODE_LSB)) | bit)
            }
            pub fn peak_hold(self) -> bool {
                (self.0 >> PEAK_HOLD_LSB) & 1 != 0
            }
            pub fn with_peak_hold(self, v: bool) -> Self {
                let bit = (v as u32) << PEAK_HOLD_LSB;
                Value((self.0 & !(PEAK_HOLD_MASK << PEAK_HOLD_LSB)) | bit)
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `averaging_k` -- Transforms averaged per output line. ARCHITECTURE 3.3 example: K = 156 for 30 lines/s at the full 4,687.5 transforms/s rate.
    pub mod averaging_k {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000008;
        pub const RESET: u32 = 0x0000009C;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
        pub fn write<R: RegisterSpace>(r: &R, value: u32) {
            r.write32(addr(), value)
        }
    }

    /// `level` -- Firmware-set offset and gain applied before the 8-bit waterfall colour index (ARCHITECTURE 3.3).
    pub mod level {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x0000000C;
        pub const RESET: u32 = 0x01000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `offset_db64` (RW) -- Signed dB offset, 1/64 dB steps (matches the 16-bit dB line format).
        pub const OFFSET_DB64_LSB: u32 = 0;
        pub const OFFSET_DB64_WIDTH: u32 = 16;
        pub const OFFSET_DB64_MASK: u32 = 0x0000FFFF;
        pub const OFFSET_DB64_RESET: u32 = 0x00000000;
        /// `gain_q8` (RW) -- Unsigned gain, Q8.8 fixed point (0x0100 = 1.0).
        pub const GAIN_Q8_LSB: u32 = 16;
        pub const GAIN_Q8_WIDTH: u32 = 16;
        pub const GAIN_Q8_MASK: u32 = 0x0000FFFF;
        pub const GAIN_Q8_RESET: u32 = 0x00000100;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn offset_db64(self) -> u32 {
                (self.0 >> OFFSET_DB64_LSB) & OFFSET_DB64_MASK
            }
            pub fn with_offset_db64(self, v: u32) -> Self {
                Value(
                    (self.0 & !(OFFSET_DB64_MASK << OFFSET_DB64_LSB))
                        | ((v & OFFSET_DB64_MASK) << OFFSET_DB64_LSB),
                )
            }
            pub fn gain_q8(self) -> u32 {
                (self.0 >> GAIN_Q8_LSB) & GAIN_Q8_MASK
            }
            pub fn with_gain_q8(self, v: u32) -> Self {
                Value(
                    (self.0 & !(GAIN_Q8_MASK << GAIN_Q8_LSB)) | ((v & GAIN_Q8_MASK) << GAIN_Q8_LSB),
                )
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `line_count` -- Free-running count of spectrum lines produced, for firmware pacing against the waterfall writer.
    pub mod line_count {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000010;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `line_status` -- Which of the two spectrum line buffers is ready to read (double-buffered, ARCHITECTURE 3.3).
    pub mod line_status {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000014;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `ready_buffer` (RO) -- Index (0 or 1) of the buffer firmware/compositor should read; the other is being written.
        pub const READY_BUFFER_LSB: u32 = 0;
        pub const READY_BUFFER_WIDTH: u32 = 1;
        pub const READY_BUFFER_MASK: u32 = 0x00000001;
        pub const READY_BUFFER_RESET: u32 = 0x00000000;
        /// `line_done` (W1C) -- Set on every completed line; drives fabric interrupt line 5 (ARCHITECTURE 4.3, firmware-side use only).
        pub const LINE_DONE_LSB: u32 = 1;
        pub const LINE_DONE_WIDTH: u32 = 1;
        pub const LINE_DONE_MASK: u32 = 0x00000001;
        pub const LINE_DONE_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn ready_buffer(self) -> bool {
                (self.0 >> READY_BUFFER_LSB) & 1 != 0
            }
            pub fn line_done(self) -> bool {
                (self.0 >> LINE_DONE_LSB) & 1 != 0
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        // No modify(): this register has a write-1-to-clear field, and a read-modify-write
        // would clear every other set W1C bit at the same time. Use clear_<field>() instead.
        /// Write-1-to-clear `line_done` only.
        pub fn clear_line_done<R: RegisterSpace>(r: &R) {
            r.write32(addr(), LINE_DONE_MASK << LINE_DONE_LSB);
        }
    }
}

/// `system` register block (base 0xe8000000).
///
/// System block (docs/ARCHITECTURE.md 4.1, 4.3): identification, a scratch register, the 16 fabric
/// interrupt lines GP0-GP15 (pending, enable, raw), clock and memory status, and a free-running
/// clk_dsp cycle counter. rtl/top/sys_regs.v, docs/P1_TOP.md.
/// status: draft
pub mod system {
    pub const BASE: u32 = 0xE8000000;
    pub const SIZE: u32 = 0x00010000;

    /// `id` -- Chip identifier: 'TR' + top-level version 1.
    pub mod id {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000000;
        pub const RESET: u32 = 0x54520001;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `build` -- Build identifier: the first 8 hex digits of the git commit the bitstream was built from (gowin/p1/build.sh); 0 in simulation.
    pub mod build {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000004;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `scratch` -- Scratch register for bus tests; no effect.
    pub mod scratch {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000008;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
        pub fn write<R: RegisterSpace>(r: &R, value: u32) {
            r.write32(addr(), value)
        }
    }

    /// `irq_pending` -- Latched interrupt events, one bit per fabric line GP0-GP15 (docs/ARCHITECTURE.md 4.3). A bit is set by a rising edge of its source; the PLIC line is pending AND enable.
    pub mod irq_pending {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000010;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `lines` (W1C) -- Bit n = line GPn has fired since last cleared. Write 1 to clear (after clearing the source block's own status).
        pub const LINES_LSB: u32 = 0;
        pub const LINES_WIDTH: u32 = 16;
        pub const LINES_MASK: u32 = 0x0000FFFF;
        pub const LINES_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn lines(self) -> u32 {
                (self.0 >> LINES_LSB) & LINES_MASK
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        // No modify(): this register has a write-1-to-clear field, and a read-modify-write
        // would clear every other set W1C bit at the same time. Use clear_<field>() instead.
        /// Write-1-to-clear `lines` only.
        pub fn clear_lines<R: RegisterSpace>(r: &R) {
            r.write32(addr(), LINES_MASK << LINES_LSB);
        }
    }

    /// `irq_enable` -- Per-line enable of the pending bits onto the AE350's EXT_INT inputs.
    pub mod irq_enable {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000014;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `lines` (RW) -- Bit n = 1 routes pending line n to PLIC source GPn.
        pub const LINES_LSB: u32 = 0;
        pub const LINES_WIDTH: u32 = 16;
        pub const LINES_MASK: u32 = 0x0000FFFF;
        pub const LINES_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn lines(self) -> u32 {
                (self.0 >> LINES_LSB) & LINES_MASK
            }
            pub fn with_lines(self, v: u32) -> Self {
                Value((self.0 & !(LINES_MASK << LINES_LSB)) | ((v & LINES_MASK) << LINES_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `irq_raw` -- Current level of each interrupt source, before edge latching.
    pub mod irq_raw {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000018;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `lines` (RO) -- Bit n = source of line GPn is high now.
        pub const LINES_LSB: u32 = 0;
        pub const LINES_WIDTH: u32 = 16;
        pub const LINES_MASK: u32 = 0x0000FFFF;
        pub const LINES_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn lines(self) -> u32 {
                (self.0 >> LINES_LSB) & LINES_MASK
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
    }

    /// `status` -- Clock, memory and bus-bridge status.
    pub mod status {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x0000001C;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `ddr3_init` (RO) -- 1 = the AE350's DDR3 controller finished initialisation (DDR3_INIT).
        pub const DDR3_INIT_LSB: u32 = 0;
        pub const DDR3_INIT_WIDTH: u32 = 1;
        pub const DDR3_INIT_MASK: u32 = 0x00000001;
        pub const DDR3_INIT_RESET: u32 = 0x00000000;
        /// `plls_locked` (RO) -- 1 = every fabric PLL reports lock.
        pub const PLLS_LOCKED_LSB: u32 = 1;
        pub const PLLS_LOCKED_WIDTH: u32 = 1;
        pub const PLLS_LOCKED_MASK: u32 = 0x00000001;
        pub const PLLS_LOCKED_RESET: u32 = 0x00000000;
        /// `bus_timeout` (W1C) -- An AHB access to a fabric register timed out (its clock domain gave no answer within 4,096 AHB clocks; the read returned 0xDEAD_BEEF). Write 1 to clear.
        pub const BUS_TIMEOUT_LSB: u32 = 8;
        pub const BUS_TIMEOUT_WIDTH: u32 = 1;
        pub const BUS_TIMEOUT_MASK: u32 = 0x00000001;
        pub const BUS_TIMEOUT_RESET: u32 = 0x00000000;
        /// `rx_domain_dead` (RO) -- 1 = the RGMII receive clock domain did not answer the last access to 0xE802_0000 (no PHY receive clock); accesses there return 0xDEAD_BEEF at once until it answers again.
        pub const RX_DOMAIN_DEAD_LSB: u32 = 9;
        pub const RX_DOMAIN_DEAD_WIDTH: u32 = 1;
        pub const RX_DOMAIN_DEAD_MASK: u32 = 0x00000001;
        pub const RX_DOMAIN_DEAD_RESET: u32 = 0x00000000;
        /// `num_rx` (RO) -- Receivers built into this bitstream (1 to 8; gowin/p1/build.sh TR_NRX, default 4). The per-receiver register arrays of every block keep the 8-receiver layout; receivers at or above this number read 0 and ignore writes. 0 = a bitstream from before this field existed: read it as 8 (fw/tr-fabric/src/system.rs does).
        pub const NUM_RX_LSB: u32 = 16;
        pub const NUM_RX_WIDTH: u32 = 4;
        pub const NUM_RX_MASK: u32 = 0x0000000F;
        pub const NUM_RX_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn ddr3_init(self) -> bool {
                (self.0 >> DDR3_INIT_LSB) & 1 != 0
            }
            pub fn plls_locked(self) -> bool {
                (self.0 >> PLLS_LOCKED_LSB) & 1 != 0
            }
            pub fn bus_timeout(self) -> bool {
                (self.0 >> BUS_TIMEOUT_LSB) & 1 != 0
            }
            pub fn rx_domain_dead(self) -> bool {
                (self.0 >> RX_DOMAIN_DEAD_LSB) & 1 != 0
            }
            pub fn num_rx(self) -> u32 {
                (self.0 >> NUM_RX_LSB) & NUM_RX_MASK
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        // No modify(): this register has a write-1-to-clear field, and a read-modify-write
        // would clear every other set W1C bit at the same time. Use clear_<field>() instead.
        /// Write-1-to-clear `bus_timeout` only.
        pub fn clear_bus_timeout<R: RegisterSpace>(r: &R) {
            r.write32(addr(), BUS_TIMEOUT_MASK << BUS_TIMEOUT_LSB);
        }
    }

    /// `dsp_cycles` -- Free-running clk_dsp (120 MHz) cycle counter, low 32 bits.
    pub mod dsp_cycles {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000020;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }
}

/// `tx` register block (base 0xe8080000).
///
/// TX chain (docs/ARCHITECTURE.md 3.6): baseband ring pointers, interpolate/CORDIC up-mix enable
/// and gain, NCO phase increment, and rate-trim status. The framer that actually sends TX frames
/// to the HL2 is in the hl2_link block (0xE801_0000, tx_ctrl/tx_fifo_fill/tx_trim); this block is
/// the DSP chain feeding it.
/// status: draft
pub mod tx {
    pub const BASE: u32 = 0xE8080000;
    pub const SIZE: u32 = 0x00010000;

    /// `id` -- Block identifier/version: 'TX' + version 1 (set by the chip top level).
    pub mod id {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000000;
        pub const RESET: u32 = 0x54580001;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `ctrl` -- Chain enable.
    pub mod ctrl {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000004;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `enable` (RW) -- 1 = chain outputs real samples from the ring; 0 = chain outputs zero (ARCHITECTURE 3.6 item 5). This gates the FPGA DSP chain only -- it never sets the HL2's key bit or selects the real DAC; see CLAUDE.md and docs/DECISIONS.md.
        pub const ENABLE_LSB: u32 = 0;
        pub const ENABLE_WIDTH: u32 = 1;
        pub const ENABLE_MASK: u32 = 0x00000001;
        pub const ENABLE_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn enable(self) -> bool {
                (self.0 >> ENABLE_LSB) & 1 != 0
            }
            pub fn with_enable(self, v: bool) -> Self {
                let bit = (v as u32) << ENABLE_LSB;
                Value((self.0 & !(ENABLE_MASK << ENABLE_LSB)) | bit)
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `gain` -- Output gain before the 12-bit round (ARCHITECTURE 3.6 item 2).
    pub mod gain {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000008;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `value` (RW) -- Unsigned gain, Q8.8 fixed point.
        pub const VALUE_LSB: u32 = 0;
        pub const VALUE_WIDTH: u32 = 16;
        pub const VALUE_MASK: u32 = 0x0000FFFF;
        pub const VALUE_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn value(self) -> u32 {
                (self.0 >> VALUE_LSB) & VALUE_MASK
            }
            pub fn with_value(self, v: u32) -> Self {
                Value((self.0 & !(VALUE_MASK << VALUE_LSB)) | ((v & VALUE_MASK) << VALUE_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `nco_phase_inc` -- CORDIC up-mix frequency, same format as the receiver bank's phase_inc (docs/ARCHITECTURE.md 3.2, 3.6).
    pub mod nco_phase_inc {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x0000000C;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `value` (RW) -- Signed 32-bit phase increment, round(f_Hz / 76.8e6 * 2^32).
        pub const VALUE_LSB: u32 = 0;
        pub const VALUE_WIDTH: u32 = 32;
        pub const VALUE_MASK: u32 = 0xFFFFFFFF;
        pub const VALUE_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn value(self) -> u32 {
                (self.0 >> VALUE_LSB) & VALUE_MASK
            }
            pub fn with_value(self, v: u32) -> Self {
                Value((self.0 & !(VALUE_MASK << VALUE_LSB)) | ((v & VALUE_MASK) << VALUE_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `ring_base` -- Baseband ring base address in DDR3 (docs/ARCHITECTURE.md 5.4).
    pub mod ring_base {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000010;
        pub const RESET: u32 = 0x12000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
        pub fn write<R: RegisterSpace>(r: &R, value: u32) {
            r.write32(addr(), value)
        }
    }

    /// `ring_size` -- Ring size in complex sample frames (power of two).
    pub mod ring_size {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000014;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
        pub fn write<R: RegisterSpace>(r: &R, value: u32) {
            r.write32(addr(), value)
        }
    }

    /// `ring_wptr` -- Write pointer, in frames. Written by firmware after it writes back the new samples' cache lines (docs/ARCHITECTURE.md 4.2, CPU-written ring).
    pub mod ring_wptr {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000018;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
        pub fn write<R: RegisterSpace>(r: &R, value: u32) {
            r.write32(addr(), value)
        }
    }

    /// `ring_rptr` -- Read pointer, in frames. Updated by the fabric consumer.
    pub mod ring_rptr {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x0000001C;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `status` -- Rate-trim direction and sticky low-water flag, matching fabric interrupt line 4 (ARCHITECTURE 4.3).
    pub mod status {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000020;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `low_water` (W1C) -- Set when the ring fill drops below the low-water mark; cleared by firmware writing 1 after refilling.
        pub const LOW_WATER_LSB: u32 = 0;
        pub const LOW_WATER_WIDTH: u32 = 1;
        pub const LOW_WATER_MASK: u32 = 0x00000001;
        pub const LOW_WATER_RESET: u32 = 0x00000000;
        /// `trimming_up` (RO) -- 1 = the rate-trim loop is currently repeating a sample to hold the HL2 TX FIFO fill near its target (ARCHITECTURE 3.6 item 3).
        pub const TRIMMING_UP_LSB: u32 = 1;
        pub const TRIMMING_UP_WIDTH: u32 = 1;
        pub const TRIMMING_UP_MASK: u32 = 0x00000001;
        pub const TRIMMING_UP_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn low_water(self) -> bool {
                (self.0 >> LOW_WATER_LSB) & 1 != 0
            }
            pub fn trimming_up(self) -> bool {
                (self.0 >> TRIMMING_UP_LSB) & 1 != 0
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        // No modify(): this register has a write-1-to-clear field, and a read-modify-write
        // would clear every other set W1C bit at the same time. Use clear_<field>() instead.
        /// Write-1-to-clear `low_water` only.
        pub fn clear_low_water<R: RegisterSpace>(r: &R) {
            r.write32(addr(), LOW_WATER_MASK << LOW_WATER_LSB);
        }
    }
}

/// `usb` register block (base 0xe80e0000).
///
/// USB audio device on the "Custom USB" socket (docs/USB_AUDIO.md, rtl/usb/usb_regs.v): the board as a
/// class-compliant sound card, 48 kHz 16-bit stereo both ways. The device enumerates and streams
/// without firmware; this page is status, the playback samples for the CPU, and three switches.
/// status: final
pub mod usb {
    pub const BASE: u32 = 0xE80E0000;
    pub const SIZE: u32 = 0x00010000;

    /// `id` -- Block identifier/version: 'US' + version 1.
    pub mod id {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000000;
        pub const RESET: u32 = 0x55530001;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `ctrl` -- Switches.
    pub mod ctrl {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000004;
        pub const RESET: u32 = 0x00000001;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `connect` (RW) -- 1 = the 1.5 kohm pull-up on D+ is on: the PC sees a device. 0 then 1 makes the PC enumerate again.
        pub const CONNECT_LSB: u32 = 0;
        pub const CONNECT_WIDTH: u32 = 1;
        pub const CONNECT_MASK: u32 = 0x00000001;
        pub const CONNECT_RESET: u32 = 0x00000001;
        /// `fifo_en` (RW) -- 1 = playback samples from the PC are stored in the CPU FIFO (fifo_level, fifo_data). 0 = the FIFO is empty and interrupt line 12 is low.
        pub const FIFO_EN_LSB: u32 = 1;
        pub const FIFO_EN_WIDTH: u32 = 1;
        pub const FIFO_EN_MASK: u32 = 0x00000001;
        pub const FIFO_EN_RESET: u32 = 0x00000000;
        /// `monitor` (RW) -- 1 = the PC's playback is added to the stream of the digital outputs (HDMI, S/PDIF, I2S), saturating. Not to the headphone DAC. Not to what the PC records.
        pub const MONITOR_LSB: u32 = 2;
        pub const MONITOR_WIDTH: u32 = 1;
        pub const MONITOR_MASK: u32 = 0x00000001;
        pub const MONITOR_RESET: u32 = 0x00000000;
        /// `loopback` (RW) -- 1 = the PC records its own playback instead of the receiver audio (test: PC to radio and back, sample for sample).
        pub const LOOPBACK_LSB: u32 = 3;
        pub const LOOPBACK_WIDTH: u32 = 1;
        pub const LOOPBACK_MASK: u32 = 0x00000001;
        pub const LOOPBACK_RESET: u32 = 0x00000000;
        /// `speech_src` (RW) -- What fills the CPU FIFO (the speech input): 0 = the PC's playback on the Custom USB socket, 1 = the microphone of a headset on the USB host board (docs/USB_HOST.md section 5; its samples come at the device's own rate).
        pub const SPEECH_SRC_LSB: u32 = 4;
        pub const SPEECH_SRC_WIDTH: u32 = 1;
        pub const SPEECH_SRC_MASK: u32 = 0x00000001;
        pub const SPEECH_SRC_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn connect(self) -> bool {
                (self.0 >> CONNECT_LSB) & 1 != 0
            }
            pub fn with_connect(self, v: bool) -> Self {
                let bit = (v as u32) << CONNECT_LSB;
                Value((self.0 & !(CONNECT_MASK << CONNECT_LSB)) | bit)
            }
            pub fn fifo_en(self) -> bool {
                (self.0 >> FIFO_EN_LSB) & 1 != 0
            }
            pub fn with_fifo_en(self, v: bool) -> Self {
                let bit = (v as u32) << FIFO_EN_LSB;
                Value((self.0 & !(FIFO_EN_MASK << FIFO_EN_LSB)) | bit)
            }
            pub fn monitor(self) -> bool {
                (self.0 >> MONITOR_LSB) & 1 != 0
            }
            pub fn with_monitor(self, v: bool) -> Self {
                let bit = (v as u32) << MONITOR_LSB;
                Value((self.0 & !(MONITOR_MASK << MONITOR_LSB)) | bit)
            }
            pub fn loopback(self) -> bool {
                (self.0 >> LOOPBACK_LSB) & 1 != 0
            }
            pub fn with_loopback(self, v: bool) -> Self {
                let bit = (v as u32) << LOOPBACK_LSB;
                Value((self.0 & !(LOOPBACK_MASK << LOOPBACK_LSB)) | bit)
            }
            pub fn speech_src(self) -> bool {
                (self.0 >> SPEECH_SRC_LSB) & 1 != 0
            }
            pub fn with_speech_src(self, v: bool) -> Self {
                let bit = (v as u32) << SPEECH_SRC_LSB;
                Value((self.0 & !(SPEECH_SRC_MASK << SPEECH_SRC_LSB)) | bit)
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `status` -- State of the device. Bits from the USB clock are synchronised one by one.
    pub mod status {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000008;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `configured` (RO) -- 1 = a PC has enumerated and configured the device.
        pub const CONFIGURED_LSB: u32 = 0;
        pub const CONFIGURED_WIDTH: u32 = 1;
        pub const CONFIGURED_MASK: u32 = 0x00000001;
        pub const CONFIGURED_RESET: u32 = 0x00000000;
        /// `play_on` (RO) -- 1 = the PC has the playback interface switched on (it is sending audio, possibly silence).
        pub const PLAY_ON_LSB: u32 = 1;
        pub const PLAY_ON_WIDTH: u32 = 1;
        pub const PLAY_ON_MASK: u32 = 0x00000001;
        pub const PLAY_ON_RESET: u32 = 0x00000000;
        /// `cap_on` (RO) -- 1 = the PC has the recording interface switched on.
        pub const CAP_ON_LSB: u32 = 2;
        pub const CAP_ON_WIDTH: u32 = 1;
        pub const CAP_ON_MASK: u32 = 0x00000001;
        pub const CAP_ON_RESET: u32 = 0x00000000;
        /// `play_run` (RO) -- 1 = the playback reader is taking samples; 0 = it waits for 96 samples (start, or after an under-run).
        pub const PLAY_RUN_LSB: u32 = 3;
        pub const PLAY_RUN_WIDTH: u32 = 1;
        pub const PLAY_RUN_MASK: u32 = 0x00000001;
        pub const PLAY_RUN_RESET: u32 = 0x00000000;
        /// `play_fill` (RO) -- Samples in the playback buffer between USB and the radio (0 to 256; about 72 to 120 in normal running).
        pub const PLAY_FILL_LSB: u32 = 16;
        pub const PLAY_FILL_WIDTH: u32 = 9;
        pub const PLAY_FILL_MASK: u32 = 0x000001FF;
        pub const PLAY_FILL_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn configured(self) -> bool {
                (self.0 >> CONFIGURED_LSB) & 1 != 0
            }
            pub fn play_on(self) -> bool {
                (self.0 >> PLAY_ON_LSB) & 1 != 0
            }
            pub fn cap_on(self) -> bool {
                (self.0 >> CAP_ON_LSB) & 1 != 0
            }
            pub fn play_run(self) -> bool {
                (self.0 >> PLAY_RUN_LSB) & 1 != 0
            }
            pub fn play_fill(self) -> u32 {
                (self.0 >> PLAY_FILL_LSB) & PLAY_FILL_MASK
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
    }

    /// `fifo_level` -- Stereo samples waiting in the CPU FIFO, 0 to 1,024.
    pub mod fifo_level {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x0000000C;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `fifo_data` -- The oldest sample of the CPU FIFO: left in bits 15:0, right in bits 31:16, signed. Reading takes it out. 0 when the FIFO is empty.
    pub mod fifo_data {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000010;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `fifo_mark` -- High-water mark, 1 to 1,024: interrupt line 12 is high while fifo_level is at or above it (and ctrl.fifo_en is 1). 512 = 10.7 ms.
    pub mod fifo_mark {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000014;
        pub const RESET: u32 = 0x00000200;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
        pub fn write<R: RegisterSpace>(r: &R, value: u32) {
            r.write32(addr(), value)
        }
    }

    /// `play_errors` -- Playback faults. Counters wrap at 65,535. Expected: both stay still while a PC plays.
    pub mod play_errors {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000018;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `underruns` (RO) -- Times the playback buffer ran empty while the PC had playback on (zeros went out, the reader started again).
        pub const UNDERRUNS_LSB: u32 = 0;
        pub const UNDERRUNS_WIDTH: u32 = 16;
        pub const UNDERRUNS_MASK: u32 = 0x0000FFFF;
        pub const UNDERRUNS_RESET: u32 = 0x00000000;
        /// `overruns` (RO) -- Playback samples dropped because the buffer was full (the PC sends faster than the feedback asks).
        pub const OVERRUNS_LSB: u32 = 16;
        pub const OVERRUNS_WIDTH: u32 = 16;
        pub const OVERRUNS_MASK: u32 = 0x0000FFFF;
        pub const OVERRUNS_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn underruns(self) -> u32 {
                (self.0 >> UNDERRUNS_LSB) & UNDERRUNS_MASK
            }
            pub fn overruns(self) -> u32 {
                (self.0 >> OVERRUNS_LSB) & OVERRUNS_MASK
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
    }

    /// `more_errors` -- Further faults. Counters wrap at 65,535.
    pub mod more_errors {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x0000001C;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `cap_overruns` (RO) -- Recording samples dropped because the PC had recording on and did not fetch them.
        pub const CAP_OVERRUNS_LSB: u32 = 0;
        pub const CAP_OVERRUNS_WIDTH: u32 = 16;
        pub const CAP_OVERRUNS_MASK: u32 = 0x0000FFFF;
        pub const CAP_OVERRUNS_RESET: u32 = 0x00000000;
        /// `fifo_overruns` (RO) -- Playback samples dropped at the CPU FIFO because the firmware did not read fast enough.
        pub const FIFO_OVERRUNS_LSB: u32 = 16;
        pub const FIFO_OVERRUNS_WIDTH: u32 = 16;
        pub const FIFO_OVERRUNS_MASK: u32 = 0x0000FFFF;
        pub const FIFO_OVERRUNS_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn cap_overruns(self) -> u32 {
                (self.0 >> CAP_OVERRUNS_LSB) & CAP_OVERRUNS_MASK
            }
            pub fn fifo_overruns(self) -> u32 {
                (self.0 >> FIFO_OVERRUNS_LSB) & FIFO_OVERRUNS_MASK
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
    }

    /// `play_bad` -- Playback packets dropped for a checksum error (16 bits, wraps). A bad cable shows here.
    pub mod play_bad {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000020;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `levels` -- Peak meters: the largest magnitude of either channel since the last read of this register. Reading clears both.
    pub mod levels {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000024;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `play_peak` (RO) -- Playback (PC to radio), 0 to 32,767.
        pub const PLAY_PEAK_LSB: u32 = 0;
        pub const PLAY_PEAK_WIDTH: u32 = 15;
        pub const PLAY_PEAK_MASK: u32 = 0x00007FFF;
        pub const PLAY_PEAK_RESET: u32 = 0x00000000;
        /// `cap_peak` (RO) -- What the PC records (receiver audio, or the playback with ctrl.loopback), 0 to 32,767.
        pub const CAP_PEAK_LSB: u32 = 16;
        pub const CAP_PEAK_WIDTH: u32 = 15;
        pub const CAP_PEAK_MASK: u32 = 0x00007FFF;
        pub const CAP_PEAK_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn play_peak(self) -> u32 {
                (self.0 >> PLAY_PEAK_LSB) & PLAY_PEAK_MASK
            }
            pub fn cap_peak(self) -> u32 {
                (self.0 >> CAP_PEAK_LSB) & CAP_PEAK_MASK
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
    }
}

/// `usbh` register block (base 0xe80f0000).
///
/// USB host on the Pmod board (docs/USB_HOST.md, rtl/usbh/usbh_regs.v): two ports, full and low speed. The
/// logic keeps the frames going and does one transaction at a time for the firmware; the firmware (fw/tr-usbh)
/// does the rest. Registers at 0x100 belong to port 0 (the board's USB1), the same at 0x200 to port 1 (USB2).
/// status: final
pub mod usbh {
    pub const BASE: u32 = 0xE80F0000;
    pub const SIZE: u32 = 0x00010000;

    /// `id` -- Block identifier/version: 'UH' + version 1.
    pub mod id {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000000;
        pub const RESET: u32 = 0x55480001;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `ctrl` -- Switches for both ports.
    pub mod ctrl {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000004;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `swap` (RW) -- 0 = the dock's odd pin row (pins 9, 11) is D-, the even row (10, 12) is D+. 1 = the other way round (the board sits the other way up).
        pub const SWAP_LSB: u32 = 0;
        pub const SWAP_WIDTH: u32 = 1;
        pub const SWAP_MASK: u32 = 0x00000001;
        pub const SWAP_RESET: u32 = 0x00000000;
        /// `irq_rx` (RW) -- 1 = interrupt line 13 is high while a receive FIFO holds something.
        pub const IRQ_RX_LSB: u32 = 8;
        pub const IRQ_RX_WIDTH: u32 = 1;
        pub const IRQ_RX_MASK: u32 = 0x00000001;
        pub const IRQ_RX_RESET: u32 = 0x00000000;
        /// `irq_done` (RW) -- 1 = interrupt line 13 is high while a port's ev_done is set.
        pub const IRQ_DONE_LSB: u32 = 9;
        pub const IRQ_DONE_WIDTH: u32 = 1;
        pub const IRQ_DONE_MASK: u32 = 0x00000001;
        pub const IRQ_DONE_RESET: u32 = 0x00000000;
        /// `irq_line` (RW) -- 1 = interrupt line 13 is high while a port's ev_line is set.
        pub const IRQ_LINE_LSB: u32 = 10;
        pub const IRQ_LINE_WIDTH: u32 = 1;
        pub const IRQ_LINE_MASK: u32 = 0x00000001;
        pub const IRQ_LINE_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn swap(self) -> bool {
                (self.0 >> SWAP_LSB) & 1 != 0
            }
            pub fn with_swap(self, v: bool) -> Self {
                let bit = (v as u32) << SWAP_LSB;
                Value((self.0 & !(SWAP_MASK << SWAP_LSB)) | bit)
            }
            pub fn irq_rx(self) -> bool {
                (self.0 >> IRQ_RX_LSB) & 1 != 0
            }
            pub fn with_irq_rx(self, v: bool) -> Self {
                let bit = (v as u32) << IRQ_RX_LSB;
                Value((self.0 & !(IRQ_RX_MASK << IRQ_RX_LSB)) | bit)
            }
            pub fn irq_done(self) -> bool {
                (self.0 >> IRQ_DONE_LSB) & 1 != 0
            }
            pub fn with_irq_done(self, v: bool) -> Self {
                let bit = (v as u32) << IRQ_DONE_LSB;
                Value((self.0 & !(IRQ_DONE_MASK << IRQ_DONE_LSB)) | bit)
            }
            pub fn irq_line(self) -> bool {
                (self.0 >> IRQ_LINE_LSB) & 1 != 0
            }
            pub fn with_irq_line(self, v: bool) -> Self {
                let bit = (v as u32) << IRQ_LINE_LSB;
                Value((self.0 & !(IRQ_LINE_MASK << IRQ_LINE_LSB)) | bit)
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `spk` -- Speaker stream (isochronous OUT): the radio's 48 kHz stream, one packet per frame.
    pub mod spk {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000010;
        pub const RESET: u32 = 0x00003000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `enable` (RW) -- 1 = send. Write the other fields first.
        pub const ENABLE_LSB: u32 = 0;
        pub const ENABLE_WIDTH: u32 = 1;
        pub const ENABLE_MASK: u32 = 0x00000001;
        pub const ENABLE_RESET: u32 = 0x00000000;
        /// `port` (RW) -- The port the device is on.
        pub const PORT_LSB: u32 = 1;
        pub const PORT_WIDTH: u32 = 1;
        pub const PORT_MASK: u32 = 0x00000001;
        pub const PORT_RESET: u32 = 0x00000000;
        /// `ep` (RW) -- Endpoint number.
        pub const EP_LSB: u32 = 2;
        pub const EP_WIDTH: u32 = 4;
        pub const EP_MASK: u32 = 0x0000000F;
        pub const EP_RESET: u32 = 0x00000000;
        /// `mono` (RW) -- 1 = one channel, (left + right) / 2. 0 = two channels.
        pub const MONO_LSB: u32 = 6;
        pub const MONO_WIDTH: u32 = 1;
        pub const MONO_MASK: u32 = 0x00000001;
        pub const MONO_RESET: u32 = 0x00000000;
        /// `bytes3` (RW) -- 1 = 3-byte samples (the low byte 0). 0 = 2-byte samples.
        pub const BYTES3_LSB: u32 = 7;
        pub const BYTES3_WIDTH: u32 = 1;
        pub const BYTES3_MASK: u32 = 0x00000001;
        pub const BYTES3_RESET: u32 = 0x00000000;
        /// `max_samples` (RW) -- Most samples per frame (the endpoint's packet size / bytes per sample frame, 49 at most).
        pub const MAX_SAMPLES_LSB: u32 = 8;
        pub const MAX_SAMPLES_WIDTH: u32 = 6;
        pub const MAX_SAMPLES_MASK: u32 = 0x0000003F;
        pub const MAX_SAMPLES_RESET: u32 = 0x00000030;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn enable(self) -> bool {
                (self.0 >> ENABLE_LSB) & 1 != 0
            }
            pub fn with_enable(self, v: bool) -> Self {
                let bit = (v as u32) << ENABLE_LSB;
                Value((self.0 & !(ENABLE_MASK << ENABLE_LSB)) | bit)
            }
            pub fn port(self) -> bool {
                (self.0 >> PORT_LSB) & 1 != 0
            }
            pub fn with_port(self, v: bool) -> Self {
                let bit = (v as u32) << PORT_LSB;
                Value((self.0 & !(PORT_MASK << PORT_LSB)) | bit)
            }
            pub fn ep(self) -> u32 {
                (self.0 >> EP_LSB) & EP_MASK
            }
            pub fn with_ep(self, v: u32) -> Self {
                Value((self.0 & !(EP_MASK << EP_LSB)) | ((v & EP_MASK) << EP_LSB))
            }
            pub fn mono(self) -> bool {
                (self.0 >> MONO_LSB) & 1 != 0
            }
            pub fn with_mono(self, v: bool) -> Self {
                let bit = (v as u32) << MONO_LSB;
                Value((self.0 & !(MONO_MASK << MONO_LSB)) | bit)
            }
            pub fn bytes3(self) -> bool {
                (self.0 >> BYTES3_LSB) & 1 != 0
            }
            pub fn with_bytes3(self, v: bool) -> Self {
                let bit = (v as u32) << BYTES3_LSB;
                Value((self.0 & !(BYTES3_MASK << BYTES3_LSB)) | bit)
            }
            pub fn max_samples(self) -> u32 {
                (self.0 >> MAX_SAMPLES_LSB) & MAX_SAMPLES_MASK
            }
            pub fn with_max_samples(self, v: u32) -> Self {
                Value(
                    (self.0 & !(MAX_SAMPLES_MASK << MAX_SAMPLES_LSB))
                        | ((v & MAX_SAMPLES_MASK) << MAX_SAMPLES_LSB),
                )
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `mic` -- Microphone stream (isochronous IN): one IN per frame, the samples go to the speech FIFO of page usb (usb.ctrl.speech_src).
    pub mod mic {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000014;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `enable` (RW) -- 1 = ask for a packet every frame. Write the other fields first.
        pub const ENABLE_LSB: u32 = 0;
        pub const ENABLE_WIDTH: u32 = 1;
        pub const ENABLE_MASK: u32 = 0x00000001;
        pub const ENABLE_RESET: u32 = 0x00000000;
        /// `port` (RW) -- The port the device is on.
        pub const PORT_LSB: u32 = 1;
        pub const PORT_WIDTH: u32 = 1;
        pub const PORT_MASK: u32 = 0x00000001;
        pub const PORT_RESET: u32 = 0x00000000;
        /// `ep` (RW) -- Endpoint number.
        pub const EP_LSB: u32 = 2;
        pub const EP_WIDTH: u32 = 4;
        pub const EP_MASK: u32 = 0x0000000F;
        pub const EP_RESET: u32 = 0x00000000;
        /// `mono` (RW) -- 1 = one channel, copied to left and right. 0 = two channels.
        pub const MONO_LSB: u32 = 6;
        pub const MONO_WIDTH: u32 = 1;
        pub const MONO_MASK: u32 = 0x00000001;
        pub const MONO_RESET: u32 = 0x00000000;
        /// `bytes3` (RW) -- 1 = 3-byte samples, the upper two bytes are used. 0 = 2-byte samples.
        pub const BYTES3_LSB: u32 = 7;
        pub const BYTES3_WIDTH: u32 = 1;
        pub const BYTES3_MASK: u32 = 0x00000001;
        pub const BYTES3_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn enable(self) -> bool {
                (self.0 >> ENABLE_LSB) & 1 != 0
            }
            pub fn with_enable(self, v: bool) -> Self {
                let bit = (v as u32) << ENABLE_LSB;
                Value((self.0 & !(ENABLE_MASK << ENABLE_LSB)) | bit)
            }
            pub fn port(self) -> bool {
                (self.0 >> PORT_LSB) & 1 != 0
            }
            pub fn with_port(self, v: bool) -> Self {
                let bit = (v as u32) << PORT_LSB;
                Value((self.0 & !(PORT_MASK << PORT_LSB)) | bit)
            }
            pub fn ep(self) -> u32 {
                (self.0 >> EP_LSB) & EP_MASK
            }
            pub fn with_ep(self, v: u32) -> Self {
                Value((self.0 & !(EP_MASK << EP_LSB)) | ((v & EP_MASK) << EP_LSB))
            }
            pub fn mono(self) -> bool {
                (self.0 >> MONO_LSB) & 1 != 0
            }
            pub fn with_mono(self, v: bool) -> Self {
                let bit = (v as u32) << MONO_LSB;
                Value((self.0 & !(MONO_MASK << MONO_LSB)) | bit)
            }
            pub fn bytes3(self) -> bool {
                (self.0 >> BYTES3_LSB) & 1 != 0
            }
            pub fn with_bytes3(self, v: bool) -> Self {
                let bit = (v as u32) << BYTES3_LSB;
                Value((self.0 & !(BYTES3_MASK << BYTES3_LSB)) | bit)
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `audio_status` -- Audio counters, wrapping.
    pub mod audio_status {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000018;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `spk_fill` (RO) -- Samples waiting in the speaker buffer (0 to 128; about 48 at the start of a frame).
        pub const SPK_FILL_LSB: u32 = 0;
        pub const SPK_FILL_WIDTH: u32 = 8;
        pub const SPK_FILL_MASK: u32 = 0x000000FF;
        pub const SPK_FILL_RESET: u32 = 0x00000000;
        /// `spk_overruns` (RO) -- Speaker samples dropped because the buffer was full.
        pub const SPK_OVERRUNS_LSB: u32 = 8;
        pub const SPK_OVERRUNS_WIDTH: u32 = 8;
        pub const SPK_OVERRUNS_MASK: u32 = 0x000000FF;
        pub const SPK_OVERRUNS_RESET: u32 = 0x00000000;
        /// `mic_bad_packets` (RO) -- Microphone packets dropped (bad CRC, damaged).
        pub const MIC_BAD_PACKETS_LSB: u32 = 16;
        pub const MIC_BAD_PACKETS_WIDTH: u32 = 16;
        pub const MIC_BAD_PACKETS_MASK: u32 = 0x0000FFFF;
        pub const MIC_BAD_PACKETS_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn spk_fill(self) -> u32 {
                (self.0 >> SPK_FILL_LSB) & SPK_FILL_MASK
            }
            pub fn spk_overruns(self) -> u32 {
                (self.0 >> SPK_OVERRUNS_LSB) & SPK_OVERRUNS_MASK
            }
            pub fn mic_bad_packets(self) -> u32 {
                (self.0 >> MIC_BAD_PACKETS_LSB) & MIC_BAD_PACKETS_MASK
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
    }

    /// `mic_count` -- Microphone samples received since reset (wraps): read twice a known time apart for the device's true rate.
    pub mod mic_count {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x0000001C;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `port_ctrl` -- One port. A write also clears `gone`.
    pub mod port_ctrl {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000100;
        pub const STRIDE: u32 = 0x00000100;
        pub const COUNT: u32 = 2;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "port_ctrl index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `mode` (RW) -- 0 = off (lines released). 1 = reset (both lines driven low). 2 = run (SOF or keep-alive every ms, transactions). 3 = suspend (no SOF). 4 = resume (K driven; go to 2 after 20 ms, the logic adds the low-speed EOP).
        pub const MODE_LSB: u32 = 0;
        pub const MODE_WIDTH: u32 = 3;
        pub const MODE_MASK: u32 = 0x00000007;
        pub const MODE_RESET: u32 = 0x00000000;
        /// `low_speed` (RW) -- 1 = low speed (1.5 Mbit/s): the device pulls D- up. 0 = full speed.
        pub const LOW_SPEED_LSB: u32 = 3;
        pub const LOW_SPEED_WIDTH: u32 = 1;
        pub const LOW_SPEED_MASK: u32 = 0x00000001;
        pub const LOW_SPEED_RESET: u32 = 0x00000000;
        /// `address` (RW) -- The device's address in every token of this port.
        pub const ADDRESS_LSB: u32 = 4;
        pub const ADDRESS_WIDTH: u32 = 7;
        pub const ADDRESS_MASK: u32 = 0x0000007F;
        pub const ADDRESS_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn mode(self) -> u32 {
                (self.0 >> MODE_LSB) & MODE_MASK
            }
            pub fn with_mode(self, v: u32) -> Self {
                Value((self.0 & !(MODE_MASK << MODE_LSB)) | ((v & MODE_MASK) << MODE_LSB))
            }
            pub fn low_speed(self) -> bool {
                (self.0 >> LOW_SPEED_LSB) & 1 != 0
            }
            pub fn with_low_speed(self, v: bool) -> Self {
                let bit = (v as u32) << LOW_SPEED_LSB;
                Value((self.0 & !(LOW_SPEED_MASK << LOW_SPEED_LSB)) | bit)
            }
            pub fn address(self) -> u32 {
                (self.0 >> ADDRESS_LSB) & ADDRESS_MASK
            }
            pub fn with_address(self, v: u32) -> Self {
                Value(
                    (self.0 & !(ADDRESS_MASK << ADDRESS_LSB)) | ((v & ADDRESS_MASK) << ADDRESS_LSB),
                )
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: Value) {
            r.write32(addr(index), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, index: u32, f: impl FnOnce(Value) -> Value) {
            write(r, index, f(read(r, index)))
        }
    }

    /// `port_status` -- State of one port. Reading clears ev_line and ev_done.
    pub mod port_status {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000104;
        pub const STRIDE: u32 = 0x00000100;
        pub const COUNT: u32 = 2;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "port_status index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `dp` (RO) -- D+ as read (after `swap`), steady for 0.5 ms.
        pub const DP_LSB: u32 = 0;
        pub const DP_WIDTH: u32 = 1;
        pub const DP_MASK: u32 = 0x00000001;
        pub const DP_RESET: u32 = 0x00000000;
        /// `dn` (RO) -- D- as read (after `swap`), steady for 0.5 ms.
        pub const DN_LSB: u32 = 1;
        pub const DN_WIDTH: u32 = 1;
        pub const DN_MASK: u32 = 0x00000001;
        pub const DN_RESET: u32 = 0x00000000;
        /// `gone` (RO) -- 1 = both lines were low for 85 us while running: the device is gone, the port has stopped. Cleared by leaving mode 2.
        pub const GONE_LSB: u32 = 2;
        pub const GONE_WIDTH: u32 = 1;
        pub const GONE_MASK: u32 = 0x00000001;
        pub const GONE_RESET: u32 = 0x00000000;
        /// `busy` (RO) -- 1 = the transaction written to `xfer` is not finished.
        pub const BUSY_LSB: u32 = 3;
        pub const BUSY_WIDTH: u32 = 1;
        pub const BUSY_MASK: u32 = 0x00000001;
        pub const BUSY_RESET: u32 = 0x00000000;
        /// `result` (RO) -- Result of the last transaction: 1 done, 2 NAK for nak_limit frames, 3 STALL, 4 no answer three times, 5 damaged three times, 6 the port was not running.
        pub const RESULT_LSB: u32 = 4;
        pub const RESULT_WIDTH: u32 = 3;
        pub const RESULT_MASK: u32 = 0x00000007;
        pub const RESULT_RESET: u32 = 0x00000000;
        /// `rx_any` (RO) -- 1 = the receive FIFO holds something.
        pub const RX_ANY_LSB: u32 = 7;
        pub const RX_ANY_WIDTH: u32 = 1;
        pub const RX_ANY_MASK: u32 = 0x00000001;
        pub const RX_ANY_RESET: u32 = 0x00000000;
        /// `ev_line` (RO) -- 1 = dp, dn or gone changed since the last read.
        pub const EV_LINE_LSB: u32 = 8;
        pub const EV_LINE_WIDTH: u32 = 1;
        pub const EV_LINE_MASK: u32 = 0x00000001;
        pub const EV_LINE_RESET: u32 = 0x00000000;
        /// `ev_done` (RO) -- 1 = a transaction finished since the last read.
        pub const EV_DONE_LSB: u32 = 9;
        pub const EV_DONE_WIDTH: u32 = 1;
        pub const EV_DONE_MASK: u32 = 0x00000001;
        pub const EV_DONE_RESET: u32 = 0x00000000;
        /// `slot_err` (RO) -- Bit n = interrupt slot n has stopped: STALL, or three polls without a proper answer. Cleared by switching the slot off.
        pub const SLOT_ERR_LSB: u32 = 10;
        pub const SLOT_ERR_WIDTH: u32 = 2;
        pub const SLOT_ERR_MASK: u32 = 0x00000003;
        pub const SLOT_ERR_RESET: u32 = 0x00000000;
        /// `frame` (RO) -- Frame number of the last SOF.
        pub const FRAME_LSB: u32 = 16;
        pub const FRAME_WIDTH: u32 = 11;
        pub const FRAME_MASK: u32 = 0x000007FF;
        pub const FRAME_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn dp(self) -> bool {
                (self.0 >> DP_LSB) & 1 != 0
            }
            pub fn dn(self) -> bool {
                (self.0 >> DN_LSB) & 1 != 0
            }
            pub fn gone(self) -> bool {
                (self.0 >> GONE_LSB) & 1 != 0
            }
            pub fn busy(self) -> bool {
                (self.0 >> BUSY_LSB) & 1 != 0
            }
            pub fn result(self) -> u32 {
                (self.0 >> RESULT_LSB) & RESULT_MASK
            }
            pub fn rx_any(self) -> bool {
                (self.0 >> RX_ANY_LSB) & 1 != 0
            }
            pub fn ev_line(self) -> bool {
                (self.0 >> EV_LINE_LSB) & 1 != 0
            }
            pub fn ev_done(self) -> bool {
                (self.0 >> EV_DONE_LSB) & 1 != 0
            }
            pub fn slot_err(self) -> u32 {
                (self.0 >> SLOT_ERR_LSB) & SLOT_ERR_MASK
            }
            pub fn frame(self) -> u32 {
                (self.0 >> FRAME_LSB) & FRAME_MASK
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
    }

    /// `xfer` -- The firmware's transaction. Writing starts it (fill tx first); port_status.busy until it is finished.
    pub mod xfer {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000108;
        pub const STRIDE: u32 = 0x00000100;
        pub const COUNT: u32 = 2;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "xfer index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `kind` (RW) -- 0 = SETUP (8 bytes from tx), 1 = OUT (len bytes from tx), 2 = IN (the data arrives as a record in the receive FIFO).
        pub const KIND_LSB: u32 = 0;
        pub const KIND_WIDTH: u32 = 2;
        pub const KIND_MASK: u32 = 0x00000003;
        pub const KIND_RESET: u32 = 0x00000000;
        /// `ep` (RW) -- Endpoint number.
        pub const EP_LSB: u32 = 2;
        pub const EP_WIDTH: u32 = 4;
        pub const EP_MASK: u32 = 0x0000000F;
        pub const EP_RESET: u32 = 0x00000000;
        /// `toggle` (RW) -- Data toggle: the PID sent (SETUP: 0), or the one expected.
        pub const TOGGLE_LSB: u32 = 6;
        pub const TOGGLE_WIDTH: u32 = 1;
        pub const TOGGLE_MASK: u32 = 0x00000001;
        pub const TOGGLE_RESET: u32 = 0x00000000;
        /// `len` (RW) -- Bytes to send, 0 to 64.
        pub const LEN_LSB: u32 = 7;
        pub const LEN_WIDTH: u32 = 7;
        pub const LEN_MASK: u32 = 0x0000007F;
        pub const LEN_RESET: u32 = 0x00000000;
        /// `nak_limit` (RW) -- Frames to go on trying while the device answers NAK; 0 = for ever (stop by leaving mode 2).
        pub const NAK_LIMIT_LSB: u32 = 16;
        pub const NAK_LIMIT_WIDTH: u32 = 8;
        pub const NAK_LIMIT_MASK: u32 = 0x000000FF;
        pub const NAK_LIMIT_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn kind(self) -> u32 {
                (self.0 >> KIND_LSB) & KIND_MASK
            }
            pub fn with_kind(self, v: u32) -> Self {
                Value((self.0 & !(KIND_MASK << KIND_LSB)) | ((v & KIND_MASK) << KIND_LSB))
            }
            pub fn ep(self) -> u32 {
                (self.0 >> EP_LSB) & EP_MASK
            }
            pub fn with_ep(self, v: u32) -> Self {
                Value((self.0 & !(EP_MASK << EP_LSB)) | ((v & EP_MASK) << EP_LSB))
            }
            pub fn toggle(self) -> bool {
                (self.0 >> TOGGLE_LSB) & 1 != 0
            }
            pub fn with_toggle(self, v: bool) -> Self {
                let bit = (v as u32) << TOGGLE_LSB;
                Value((self.0 & !(TOGGLE_MASK << TOGGLE_LSB)) | bit)
            }
            pub fn len(self) -> u32 {
                (self.0 >> LEN_LSB) & LEN_MASK
            }
            pub fn with_len(self, v: u32) -> Self {
                Value((self.0 & !(LEN_MASK << LEN_LSB)) | ((v & LEN_MASK) << LEN_LSB))
            }
            pub fn nak_limit(self) -> u32 {
                (self.0 >> NAK_LIMIT_LSB) & NAK_LIMIT_MASK
            }
            pub fn with_nak_limit(self, v: u32) -> Self {
                Value(
                    (self.0 & !(NAK_LIMIT_MASK << NAK_LIMIT_LSB))
                        | ((v & NAK_LIMIT_MASK) << NAK_LIMIT_LSB),
                )
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: Value) {
            r.write32(addr(index), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, index: u32, f: impl FnOnce(Value) -> Value) {
            write(r, index, f(read(r, index)))
        }
    }

    /// `rx_pop` -- The oldest word of the receive FIFO; reading takes it out. A record is its data bytes and then one end word.
    pub mod rx_pop {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x0000010C;
        pub const STRIDE: u32 = 0x00000100;
        pub const COUNT: u32 = 2;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "rx_pop index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `data` (RO) -- A data byte; in the end word the source: 0 = the IN transaction of `xfer`, 1 = interrupt slot 0, 2 = slot 1.
        pub const DATA_LSB: u32 = 0;
        pub const DATA_WIDTH: u32 = 8;
        pub const DATA_MASK: u32 = 0x000000FF;
        pub const DATA_RESET: u32 = 0x00000000;
        /// `end` (RO) -- 1 = this is the end word of a record.
        pub const END_LSB: u32 = 8;
        pub const END_WIDTH: u32 = 1;
        pub const END_MASK: u32 = 0x00000001;
        pub const END_RESET: u32 = 0x00000000;
        /// `valid` (RO) -- 0 = the FIFO was empty, nothing was taken.
        pub const VALID_LSB: u32 = 31;
        pub const VALID_WIDTH: u32 = 1;
        pub const VALID_MASK: u32 = 0x00000001;
        pub const VALID_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn data(self) -> u32 {
                (self.0 >> DATA_LSB) & DATA_MASK
            }
            pub fn end(self) -> bool {
                (self.0 >> END_LSB) & 1 != 0
            }
            pub fn valid(self) -> bool {
                (self.0 >> VALID_LSB) & 1 != 0
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
    }

    /// `slot` -- Port 0's two interrupt-IN polls. (Port 1's are `slot1` at 0x210.)
    pub mod slot {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000110;
        pub const STRIDE: u32 = 0x00000004;
        pub const COUNT: u32 = 2;
        pub const RESET: u32 = 0x00000140;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "slot index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `enable` (RW) -- 1 = poll. Switching off clears the slot's toggle and fault.
        pub const ENABLE_LSB: u32 = 0;
        pub const ENABLE_WIDTH: u32 = 1;
        pub const ENABLE_MASK: u32 = 0x00000001;
        pub const ENABLE_RESET: u32 = 0x00000000;
        /// `ep` (RW) -- Endpoint number.
        pub const EP_LSB: u32 = 1;
        pub const EP_WIDTH: u32 = 4;
        pub const EP_MASK: u32 = 0x0000000F;
        pub const EP_RESET: u32 = 0x00000000;
        /// `interval` (RW) -- Frames (ms) between polls, 1 to 255.
        pub const INTERVAL_LSB: u32 = 5;
        pub const INTERVAL_WIDTH: u32 = 8;
        pub const INTERVAL_MASK: u32 = 0x000000FF;
        pub const INTERVAL_RESET: u32 = 0x0000000A;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn enable(self) -> bool {
                (self.0 >> ENABLE_LSB) & 1 != 0
            }
            pub fn with_enable(self, v: bool) -> Self {
                let bit = (v as u32) << ENABLE_LSB;
                Value((self.0 & !(ENABLE_MASK << ENABLE_LSB)) | bit)
            }
            pub fn ep(self) -> u32 {
                (self.0 >> EP_LSB) & EP_MASK
            }
            pub fn with_ep(self, v: u32) -> Self {
                Value((self.0 & !(EP_MASK << EP_LSB)) | ((v & EP_MASK) << EP_LSB))
            }
            pub fn interval(self) -> u32 {
                (self.0 >> INTERVAL_LSB) & INTERVAL_MASK
            }
            pub fn with_interval(self, v: u32) -> Self {
                Value(
                    (self.0 & !(INTERVAL_MASK << INTERVAL_LSB))
                        | ((v & INTERVAL_MASK) << INTERVAL_LSB),
                )
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: Value) {
            r.write32(addr(index), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, index: u32, f: impl FnOnce(Value) -> Value) {
            write(r, index, f(read(r, index)))
        }
    }

    /// `rx_level` -- Words waiting in the receive FIFO, 0 to 1,024.
    pub mod rx_level {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000120;
        pub const STRIDE: u32 = 0x00000100;
        pub const COUNT: u32 = 2;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "rx_level index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> u32 {
            r.read32(addr(index))
        }
    }

    /// `tx` -- Port 0: the 64 bytes to send, byte 0 in bits 7:0 of word 0. Write only (reads 0). Port 1: 0x240.
    pub mod tx {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000140;
        pub const STRIDE: u32 = 0x00000004;
        pub const COUNT: u32 = 16;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "tx index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> u32 {
            r.read32(addr(index))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: u32) {
            r.write32(addr(index), value)
        }
    }

    /// `slot1` -- Port 1's interrupt slots (fields as `slot`).
    pub mod slot1 {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000210;
        pub const STRIDE: u32 = 0x00000004;
        pub const COUNT: u32 = 2;
        pub const RESET: u32 = 0x00000140;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "slot1 index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `enable` (RW) -- 1 = poll.
        pub const ENABLE_LSB: u32 = 0;
        pub const ENABLE_WIDTH: u32 = 1;
        pub const ENABLE_MASK: u32 = 0x00000001;
        pub const ENABLE_RESET: u32 = 0x00000000;
        /// `ep` (RW) -- Endpoint number.
        pub const EP_LSB: u32 = 1;
        pub const EP_WIDTH: u32 = 4;
        pub const EP_MASK: u32 = 0x0000000F;
        pub const EP_RESET: u32 = 0x00000000;
        /// `interval` (RW) -- Frames (ms) between polls, 1 to 255.
        pub const INTERVAL_LSB: u32 = 5;
        pub const INTERVAL_WIDTH: u32 = 8;
        pub const INTERVAL_MASK: u32 = 0x000000FF;
        pub const INTERVAL_RESET: u32 = 0x0000000A;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn enable(self) -> bool {
                (self.0 >> ENABLE_LSB) & 1 != 0
            }
            pub fn with_enable(self, v: bool) -> Self {
                let bit = (v as u32) << ENABLE_LSB;
                Value((self.0 & !(ENABLE_MASK << ENABLE_LSB)) | bit)
            }
            pub fn ep(self) -> u32 {
                (self.0 >> EP_LSB) & EP_MASK
            }
            pub fn with_ep(self, v: u32) -> Self {
                Value((self.0 & !(EP_MASK << EP_LSB)) | ((v & EP_MASK) << EP_LSB))
            }
            pub fn interval(self) -> u32 {
                (self.0 >> INTERVAL_LSB) & INTERVAL_MASK
            }
            pub fn with_interval(self, v: u32) -> Self {
                Value(
                    (self.0 & !(INTERVAL_MASK << INTERVAL_LSB))
                        | ((v & INTERVAL_MASK) << INTERVAL_LSB),
                )
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: Value) {
            r.write32(addr(index), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, index: u32, f: impl FnOnce(Value) -> Value) {
            write(r, index, f(read(r, index)))
        }
    }

    /// `tx1` -- Port 1: the 64 bytes to send. Write only (reads 0).
    pub mod tx1 {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000240;
        pub const STRIDE: u32 = 0x00000004;
        pub const COUNT: u32 = 16;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "tx1 index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> u32 {
            r.read32(addr(index))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: u32) {
            r.write32(addr(index), value)
        }
    }
}

/// `video` register block (base 0xe8070000).
///
/// Video compositor (docs/ARCHITECTURE.md 3.5, docs/V2_COMPOSITOR.md): enable, Slint framebuffer
/// base/stride, up to 4 FPGA windows (spectrum trace or waterfall; waterfall in windows 0 and 1
/// only, each with its own ring and scroll line), the waterfall palettes, colours, grid, 8 receiver passbands, a tuning cursor, and the
/// status and underrun counters.
/// status: final
pub mod video {
    pub const BASE: u32 = 0xE8070000;
    pub const SIZE: u32 = 0x00010000;

    /// `id` -- Block identifier/version: 'VI' + version 2 (version 2: a ring base and a scroll line per waterfall window, the zoom waterfall ring).
    pub mod id {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000000;
        pub const RESET: u32 = 0x56490002;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `ctrl` -- Output enable and refresh-rate select.
    pub mod ctrl {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000004;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `enable` (RW) -- 1 = show the composed picture; 0 = colour bars (the video timing runs either way). Takes effect at the next vertical blank. While 0 the compositor reads no DDR3.
        pub const ENABLE_LSB: u32 = 0;
        pub const ENABLE_WIDTH: u32 = 1;
        pub const ENABLE_MASK: u32 = 0x00000001;
        pub const ENABLE_RESET: u32 = 0x00000000;
        /// `mode_30hz` (RW) -- 0 = 1080p60, 1 = 1080p30 (pixel clock 74.167 MHz, the mode the radio runs because 1080p60 shows no picture on the board's HDMI pins), ARCHITECTURE 3.5. Informational: the mode is chosen at build time.
        pub const MODE_30HZ_LSB: u32 = 1;
        pub const MODE_30HZ_WIDTH: u32 = 1;
        pub const MODE_30HZ_MASK: u32 = 0x00000001;
        pub const MODE_30HZ_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn enable(self) -> bool {
                (self.0 >> ENABLE_LSB) & 1 != 0
            }
            pub fn with_enable(self, v: bool) -> Self {
                let bit = (v as u32) << ENABLE_LSB;
                Value((self.0 & !(ENABLE_MASK << ENABLE_LSB)) | bit)
            }
            pub fn mode_30hz(self) -> bool {
                (self.0 >> MODE_30HZ_LSB) & 1 != 0
            }
            pub fn with_mode_30hz(self, v: bool) -> Self {
                let bit = (v as u32) << MODE_30HZ_LSB;
                Value((self.0 & !(MODE_30HZ_MASK << MODE_30HZ_LSB)) | bit)
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `fb_base` -- Slint framebuffer base address in DDR3, byte address, multiple of 8 (docs/ARCHITECTURE.md 5.4: two 4 MB buffers from 0x1000_0000). Takes effect at the next vertical blank: this is the buffer swap.
    pub mod fb_base {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000008;
        pub const RESET: u32 = 0x10000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
        pub fn write<R: RegisterSpace>(r: &R, value: u32) {
            r.write32(addr(), value)
        }
    }

    /// `fb_stride` -- Framebuffer stride in bytes, multiple of 8. Reset value is 1,920 x 2 B (RGB565, ARCHITECTURE 3.5 item 1).
    pub mod fb_stride {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x0000000C;
        pub const RESET: u32 = 0x00000F00;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
        pub fn write<R: RegisterSpace>(r: &R, value: u32) {
            r.write32(addr(), value)
        }
    }

    /// `win_pos` -- Window top-left corner, one of up to 4 FPGA windows (ARCHITECTURE 3.5 item 2). Windows must not overlap: where they do, the lowest-numbered window wins but its grid lines are not reliable.
    pub mod win_pos {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000020;
        pub const STRIDE: u32 = 0x00000010;
        pub const COUNT: u32 = 4;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "win_pos index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `x` (RW) -- Left edge, pixels.
        pub const X_LSB: u32 = 0;
        pub const X_WIDTH: u32 = 12;
        pub const X_MASK: u32 = 0x00000FFF;
        pub const X_RESET: u32 = 0x00000000;
        /// `y` (RW) -- Top edge, pixels.
        pub const Y_LSB: u32 = 16;
        pub const Y_WIDTH: u32 = 12;
        pub const Y_MASK: u32 = 0x00000FFF;
        pub const Y_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn x(self) -> u32 {
                (self.0 >> X_LSB) & X_MASK
            }
            pub fn with_x(self, v: u32) -> Self {
                Value((self.0 & !(X_MASK << X_LSB)) | ((v & X_MASK) << X_LSB))
            }
            pub fn y(self) -> u32 {
                (self.0 >> Y_LSB) & Y_MASK
            }
            pub fn with_y(self, v: u32) -> Self {
                Value((self.0 & !(Y_MASK << Y_LSB)) | ((v & Y_MASK) << Y_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: Value) {
            r.write32(addr(index), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, index: u32, f: impl FnOnce(Value) -> Value) {
            write(r, index, f(read(r, index)))
        }
    }

    /// `win_size` -- Window width/height, paired with win_pos at the same index.
    pub mod win_size {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000024;
        pub const STRIDE: u32 = 0x00000010;
        pub const COUNT: u32 = 4;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "win_size index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `w` (RW) -- Width, pixels.
        pub const W_LSB: u32 = 0;
        pub const W_WIDTH: u32 = 12;
        pub const W_MASK: u32 = 0x00000FFF;
        pub const W_RESET: u32 = 0x00000000;
        /// `h` (RW) -- Height, pixels.
        pub const H_LSB: u32 = 16;
        pub const H_WIDTH: u32 = 12;
        pub const H_MASK: u32 = 0x00000FFF;
        pub const H_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn w(self) -> u32 {
                (self.0 >> W_LSB) & W_MASK
            }
            pub fn with_w(self, v: u32) -> Self {
                Value((self.0 & !(W_MASK << W_LSB)) | ((v & W_MASK) << W_LSB))
            }
            pub fn h(self) -> u32 {
                (self.0 >> H_LSB) & H_MASK
            }
            pub fn with_h(self, v: u32) -> Self {
                Value((self.0 & !(H_MASK << H_LSB)) | ((v & H_MASK) << H_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: Value) {
            r.write32(addr(index), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, index: u32, f: impl FnOnce(Value) -> Value) {
            write(r, index, f(read(r, index)))
        }
    }

    /// `win_ctrl` -- Window type/source/enable, paired with win_pos/win_size at the same index.
    pub mod win_ctrl {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000028;
        pub const STRIDE: u32 = 0x00000010;
        pub const COUNT: u32 = 4;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "win_ctrl index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `enable` (RW) -- 1 = window drawn.
        pub const ENABLE_LSB: u32 = 0;
        pub const ENABLE_WIDTH: u32 = 1;
        pub const ENABLE_MASK: u32 = 0x00000001;
        pub const ENABLE_RESET: u32 = 0x00000000;
        /// `type_waterfall` (RW) -- 0 = spectrum trace (filled area + line from the line buffer), 1 = waterfall (DDR3 ring + palette), ARCHITECTURE 3.5 item 2. Honoured in windows 0 and 1 only; windows 2 and 3 are always traces.
        pub const TYPE_WATERFALL_LSB: u32 = 1;
        pub const TYPE_WATERFALL_WIDTH: u32 = 1;
        pub const TYPE_WATERFALL_MASK: u32 = 0x00000001;
        pub const TYPE_WATERFALL_RESET: u32 = 0x00000000;
        /// `source_zoom` (RW) -- 0 = full-band spectrum, 1 = zoom spectrum (trace windows; a chip built without the zoom snapshot memory shows the full-band line). A waterfall window selects its source by wf_win_ring and wf_win_ctrl instead.
        pub const SOURCE_ZOOM_LSB: u32 = 2;
        pub const SOURCE_ZOOM_WIDTH: u32 = 1;
        pub const SOURCE_ZOOM_MASK: u32 = 0x00000001;
        pub const SOURCE_ZOOM_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn enable(self) -> bool {
                (self.0 >> ENABLE_LSB) & 1 != 0
            }
            pub fn with_enable(self, v: bool) -> Self {
                let bit = (v as u32) << ENABLE_LSB;
                Value((self.0 & !(ENABLE_MASK << ENABLE_LSB)) | bit)
            }
            pub fn type_waterfall(self) -> bool {
                (self.0 >> TYPE_WATERFALL_LSB) & 1 != 0
            }
            pub fn with_type_waterfall(self, v: bool) -> Self {
                let bit = (v as u32) << TYPE_WATERFALL_LSB;
                Value((self.0 & !(TYPE_WATERFALL_MASK << TYPE_WATERFALL_LSB)) | bit)
            }
            pub fn source_zoom(self) -> bool {
                (self.0 >> SOURCE_ZOOM_LSB) & 1 != 0
            }
            pub fn with_source_zoom(self, v: bool) -> Self {
                let bit = (v as u32) << SOURCE_ZOOM_LSB;
                Value((self.0 & !(SOURCE_ZOOM_MASK << SOURCE_ZOOM_LSB)) | bit)
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: Value) {
            r.write32(addr(index), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, index: u32, f: impl FnOnce(Value) -> Value) {
            write(r, index, f(read(r, index)))
        }
    }

    /// `win_src` -- Source column offset of window i: window column 0 shows source column x0 (spectrum line or waterfall line, 0-1,919).
    pub mod win_src {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x0000002C;
        pub const STRIDE: u32 = 0x00000010;
        pub const COUNT: u32 = 4;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "win_src index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `x0` (RW) -- First source column.
        pub const X0_LSB: u32 = 0;
        pub const X0_WIDTH: u32 = 12;
        pub const X0_MASK: u32 = 0x00000FFF;
        pub const X0_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn x0(self) -> u32 {
                (self.0 >> X0_LSB) & X0_MASK
            }
            pub fn with_x0(self, v: u32) -> Self {
                Value((self.0 & !(X0_MASK << X0_LSB)) | ((v & X0_MASK) << X0_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: Value) {
            r.write32(addr(index), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, index: u32, f: impl FnOnce(Value) -> Value) {
            write(r, index, f(read(r, index)))
        }
    }

    /// `palette_index` -- Index into the waterfall palette; write here, then write palette_data.
    pub mod palette_index {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000060;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `value` (RW) -- Palette entry 0-255.
        pub const VALUE_LSB: u32 = 0;
        pub const VALUE_WIDTH: u32 = 8;
        pub const VALUE_MASK: u32 = 0x000000FF;
        pub const VALUE_RESET: u32 = 0x00000000;
        /// `which` (RW) -- 0 = palette of waterfall window 0, 1 = palette of waterfall window 1.
        pub const WHICH_LSB: u32 = 8;
        pub const WHICH_WIDTH: u32 = 1;
        pub const WHICH_MASK: u32 = 0x00000001;
        pub const WHICH_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn value(self) -> u32 {
                (self.0 >> VALUE_LSB) & VALUE_MASK
            }
            pub fn with_value(self, v: u32) -> Self {
                Value((self.0 & !(VALUE_MASK << VALUE_LSB)) | ((v & VALUE_MASK) << VALUE_LSB))
            }
            pub fn which(self) -> bool {
                (self.0 >> WHICH_LSB) & 1 != 0
            }
            pub fn with_which(self, v: bool) -> Self {
                let bit = (v as u32) << WHICH_LSB;
                Value((self.0 & !(WHICH_MASK << WHICH_LSB)) | bit)
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `palette_data` -- Colour for the palette entry selected by palette_index. Writing this register stores the entry (the palette is BSRAM). Reads return the last value written.
    pub mod palette_data {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000064;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `rgb` (RW) -- Colour, 0xRRGGBB.
        pub const RGB_LSB: u32 = 0;
        pub const RGB_WIDTH: u32 = 24;
        pub const RGB_MASK: u32 = 0x00FFFFFF;
        pub const RGB_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn rgb(self) -> u32 {
                (self.0 >> RGB_LSB) & RGB_MASK
            }
            pub fn with_rgb(self, v: u32) -> Self {
                Value((self.0 & !(RGB_MASK << RGB_LSB)) | ((v & RGB_MASK) << RGB_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `wf_ring_base` -- Full-band waterfall writer: lane-word address of line 0 of the ring it writes. Set it before the full-band spectrum is enabled.
    pub mod wf_ring_base {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000070;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
        pub fn write<R: RegisterSpace>(r: &R, value: u32) {
            r.write32(addr(), value)
        }
    }

    /// `wf_write_line` -- Full-band waterfall writer: index of the last fully written line (0-2,047; 2,047 after reset = none yet).
    pub mod wf_write_line {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000074;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `wf_zoom_ring_base` -- Zoom waterfall writer: lane-word address of line 0 of the ring it writes. Set it before the zoom spectrum is enabled.
    pub mod wf_zoom_ring_base {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x0000007C;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
        pub fn write<R: RegisterSpace>(r: &R, value: u32) {
            r.write32(addr(), value)
        }
    }

    /// `key` -- Key colour: where the Slint framebuffer holds this RGB565 value inside a window, the FPGA layer shows through (ARCHITECTURE 3.5 item 4).
    pub mod key {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000078;
        pub const RESET: u32 = 0x0000F81F;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `rgb565` (RW) -- Key colour, RGB565 (magenta).
        pub const RGB565_LSB: u32 = 0;
        pub const RGB565_WIDTH: u32 = 16;
        pub const RGB565_MASK: u32 = 0x0000FFFF;
        pub const RGB565_RESET: u32 = 0x0000F81F;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn rgb565(self) -> u32 {
                (self.0 >> RGB565_LSB) & RGB565_MASK
            }
            pub fn with_rgb565(self, v: u32) -> Self {
                Value((self.0 & !(RGB565_MASK << RGB565_LSB)) | ((v & RGB565_MASK) << RGB565_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `status` -- Compositor status. Writing 1 to underrun also clears underrun_count.
    pub mod status {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000080;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `underrun` (W1C) -- Sticky: a displayed line was not completely in its line buffer when its scan-out began (the previous contents of the buffer are shown).
        pub const UNDERRUN_LSB: u32 = 0;
        pub const UNDERRUN_WIDTH: u32 = 1;
        pub const UNDERRUN_MASK: u32 = 0x00000001;
        pub const UNDERRUN_RESET: u32 = 0x00000000;
        /// `lane_error` (W1C) -- Sticky: a DDR3 read burst was not granted or not delivered in time and was abandoned.
        pub const LANE_ERROR_LSB: u32 = 1;
        pub const LANE_ERROR_WIDTH: u32 = 1;
        pub const LANE_ERROR_MASK: u32 = 0x00000001;
        pub const LANE_ERROR_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn underrun(self) -> bool {
                (self.0 >> UNDERRUN_LSB) & 1 != 0
            }
            pub fn lane_error(self) -> bool {
                (self.0 >> LANE_ERROR_LSB) & 1 != 0
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        // No modify(): this register has a write-1-to-clear field, and a read-modify-write
        // would clear every other set W1C bit at the same time. Use clear_<field>() instead.
        /// Write-1-to-clear `underrun` only.
        pub fn clear_underrun<R: RegisterSpace>(r: &R) {
            r.write32(addr(), UNDERRUN_MASK << UNDERRUN_LSB);
        }
        /// Write-1-to-clear `lane_error` only.
        pub fn clear_lane_error<R: RegisterSpace>(r: &R) {
            r.write32(addr(), LANE_ERROR_MASK << LANE_ERROR_LSB);
        }
    }

    /// `underrun_count` -- Number of underrun lines since reset or since underrun was cleared. Counts only while ctrl.enable is 1.
    pub mod underrun_count {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000084;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `frame_count` -- Frames shown since reset; increments when the shadow copy is taken (line 1082). A framebuffer swap written before this changes has taken effect once the value has changed twice.
    pub mod frame_count {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000088;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `fb_active` -- Framebuffer base currently in the shadow copy (the frame being scanned out or about to be). The other buffer is free to draw into.
    pub mod fb_active {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x0000008C;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `wf_zoom_write_line` -- Zoom waterfall writer: index of the last fully written line (0-2,047; 2,047 after reset = none yet).
    pub mod wf_zoom_write_line {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000094;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `wf_win_ring` -- Waterfall window i (0, 1): lane-word address of line 0 of the ring the window shows. To show a hardware writer's ring write the same value as that writer's ring base. Taken at the vertical blank.
    pub mod wf_win_ring {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x000000A0;
        pub const STRIDE: u32 = 0x00000010;
        pub const COUNT: u32 = 2;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "wf_win_ring index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> u32 {
            r.read32(addr(index))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: u32) {
            r.write32(addr(index), value)
        }
    }

    /// `wf_win_ctrl` -- Waterfall window i: where its scroll line comes from. The window shows ring line (scroll line - row) mod 2,048 in window row `row`: the newest line at the top.
    pub mod wf_win_ctrl {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x000000A4;
        pub const STRIDE: u32 = 0x00000010;
        pub const COUNT: u32 = 2;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "wf_win_ctrl index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `line_src` (RW) -- 0 = wf_write_line (the full-band hardware writer), 1 = wf_zoom_write_line (the zoom hardware writer), 2 = wf_win_line of this window (written by the CPU: a software waterfall). 3 = as 2.
        pub const LINE_SRC_LSB: u32 = 0;
        pub const LINE_SRC_WIDTH: u32 = 2;
        pub const LINE_SRC_MASK: u32 = 0x00000003;
        pub const LINE_SRC_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn line_src(self) -> u32 {
                (self.0 >> LINE_SRC_LSB) & LINE_SRC_MASK
            }
            pub fn with_line_src(self, v: u32) -> Self {
                Value(
                    (self.0 & !(LINE_SRC_MASK << LINE_SRC_LSB))
                        | ((v & LINE_SRC_MASK) << LINE_SRC_LSB),
                )
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: Value) {
            r.write32(addr(index), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, index: u32, f: impl FnOnce(Value) -> Value) {
            write(r, index, f(read(r, index)))
        }
    }

    /// `wf_win_line` -- Waterfall window i: the scroll line the CPU writes (used when wf_win_ctrl.line_src = 2). Write the new line's bytes to DDR3 first, then this register. Taken at the vertical blank.
    pub mod wf_win_line {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x000000A8;
        pub const STRIDE: u32 = 0x00000010;
        pub const COUNT: u32 = 2;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "wf_win_line index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `line` (RW) -- Ring line shown in the top row, 0-2,047.
        pub const LINE_LSB: u32 = 0;
        pub const LINE_WIDTH: u32 = 11;
        pub const LINE_MASK: u32 = 0x000007FF;
        pub const LINE_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn line(self) -> u32 {
                (self.0 >> LINE_LSB) & LINE_MASK
            }
            pub fn with_line(self, v: u32) -> Self {
                Value((self.0 & !(LINE_MASK << LINE_LSB)) | ((v & LINE_MASK) << LINE_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: Value) {
            r.write32(addr(index), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, index: u32, f: impl FnOnce(Value) -> Value) {
            write(r, index, f(read(r, index)))
        }
    }

    /// `wf_win_top` -- Waterfall window i: ring line shown in its top row in the current frame (the scroll line as latched at the vertical blank).
    pub mod wf_win_top {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x000000AC;
        pub const STRIDE: u32 = 0x00000010;
        pub const COUNT: u32 = 2;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "wf_win_top index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> u32 {
            r.read32(addr(index))
        }
    }

    /// `win_scale` -- Spectrum trace vertical scale of window i: row = (ref - level) x gain, level in 1/64 dB as in the spectrum line buffer.
    pub mod win_scale {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000100;
        pub const STRIDE: u32 = 0x00000020;
        pub const COUNT: u32 = 4;
        pub const RESET: u32 = 0x01000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "win_scale index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `top_level` (RW) -- Level at the top row of the window, signed, 1/64 dB.
        pub const TOP_LEVEL_LSB: u32 = 0;
        pub const TOP_LEVEL_WIDTH: u32 = 16;
        pub const TOP_LEVEL_MASK: u32 = 0x0000FFFF;
        pub const TOP_LEVEL_RESET: u32 = 0x00000000;
        /// `gain` (RW) -- Pixels per dB, Q8.8 (0x0100 = 1 pixel per dB). Levels above ref are drawn in the top row, levels below the window in the bottom row.
        pub const GAIN_LSB: u32 = 16;
        pub const GAIN_WIDTH: u32 = 16;
        pub const GAIN_MASK: u32 = 0x0000FFFF;
        pub const GAIN_RESET: u32 = 0x00000100;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn top_level(self) -> u32 {
                (self.0 >> TOP_LEVEL_LSB) & TOP_LEVEL_MASK
            }
            pub fn with_top_level(self, v: u32) -> Self {
                Value(
                    (self.0 & !(TOP_LEVEL_MASK << TOP_LEVEL_LSB))
                        | ((v & TOP_LEVEL_MASK) << TOP_LEVEL_LSB),
                )
            }
            pub fn gain(self) -> u32 {
                (self.0 >> GAIN_LSB) & GAIN_MASK
            }
            pub fn with_gain(self, v: u32) -> Self {
                Value((self.0 & !(GAIN_MASK << GAIN_LSB)) | ((v & GAIN_MASK) << GAIN_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: Value) {
            r.write32(addr(index), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, index: u32, f: impl FnOnce(Value) -> Value) {
            write(r, index, f(read(r, index)))
        }
    }

    /// `win_gridx` -- Vertical grid lines (frequency) of window i, drawn in col_grid over the window.
    pub mod win_gridx {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000104;
        pub const STRIDE: u32 = 0x00000020;
        pub const COUNT: u32 = 4;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "win_gridx index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `first` (RW) -- Window column of the first line.
        pub const FIRST_LSB: u32 = 0;
        pub const FIRST_WIDTH: u32 = 12;
        pub const FIRST_MASK: u32 = 0x00000FFF;
        pub const FIRST_RESET: u32 = 0x00000000;
        /// `step` (RW) -- Spacing in pixels; 0 = no vertical grid.
        pub const STEP_LSB: u32 = 16;
        pub const STEP_WIDTH: u32 = 12;
        pub const STEP_MASK: u32 = 0x00000FFF;
        pub const STEP_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn first(self) -> u32 {
                (self.0 >> FIRST_LSB) & FIRST_MASK
            }
            pub fn with_first(self, v: u32) -> Self {
                Value((self.0 & !(FIRST_MASK << FIRST_LSB)) | ((v & FIRST_MASK) << FIRST_LSB))
            }
            pub fn step(self) -> u32 {
                (self.0 >> STEP_LSB) & STEP_MASK
            }
            pub fn with_step(self, v: u32) -> Self {
                Value((self.0 & !(STEP_MASK << STEP_LSB)) | ((v & STEP_MASK) << STEP_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: Value) {
            r.write32(addr(index), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, index: u32, f: impl FnOnce(Value) -> Value) {
            write(r, index, f(read(r, index)))
        }
    }

    /// `win_gridy` -- Horizontal grid lines (level) of window i; trace windows only.
    pub mod win_gridy {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000108;
        pub const STRIDE: u32 = 0x00000020;
        pub const COUNT: u32 = 4;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "win_gridy index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `first` (RW) -- Window row of the first line.
        pub const FIRST_LSB: u32 = 0;
        pub const FIRST_WIDTH: u32 = 12;
        pub const FIRST_MASK: u32 = 0x00000FFF;
        pub const FIRST_RESET: u32 = 0x00000000;
        /// `step` (RW) -- Spacing in pixels; 0 = no horizontal grid.
        pub const STEP_LSB: u32 = 16;
        pub const STEP_WIDTH: u32 = 12;
        pub const STEP_MASK: u32 = 0x00000FFF;
        pub const STEP_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn first(self) -> u32 {
                (self.0 >> FIRST_LSB) & FIRST_MASK
            }
            pub fn with_first(self, v: u32) -> Self {
                Value((self.0 & !(FIRST_MASK << FIRST_LSB)) | ((v & FIRST_MASK) << FIRST_LSB))
            }
            pub fn step(self) -> u32 {
                (self.0 >> STEP_LSB) & STEP_MASK
            }
            pub fn with_step(self, v: u32) -> Self {
                Value((self.0 & !(STEP_MASK << STEP_LSB)) | ((v & STEP_MASK) << STEP_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: Value) {
            r.write32(addr(index), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, index: u32, f: impl FnOnce(Value) -> Value) {
            write(r, index, f(read(r, index)))
        }
    }

    /// `col_bg` -- Trace window background colour.
    pub mod col_bg {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000180;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `rgb` (RW) -- 0xRRGGBB.
        pub const RGB_LSB: u32 = 0;
        pub const RGB_WIDTH: u32 = 24;
        pub const RGB_MASK: u32 = 0x00FFFFFF;
        pub const RGB_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn rgb(self) -> u32 {
                (self.0 >> RGB_LSB) & RGB_MASK
            }
            pub fn with_rgb(self, v: u32) -> Self {
                Value((self.0 & !(RGB_MASK << RGB_LSB)) | ((v & RGB_MASK) << RGB_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `col_fill` -- Trace window colour below the trace line.
    pub mod col_fill {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000184;
        pub const RESET: u32 = 0x00003060;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `rgb` (RW) -- 0xRRGGBB.
        pub const RGB_LSB: u32 = 0;
        pub const RGB_WIDTH: u32 = 24;
        pub const RGB_MASK: u32 = 0x00FFFFFF;
        pub const RGB_RESET: u32 = 0x00003060;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn rgb(self) -> u32 {
                (self.0 >> RGB_LSB) & RGB_MASK
            }
            pub fn with_rgb(self, v: u32) -> Self {
                Value((self.0 & !(RGB_MASK << RGB_LSB)) | ((v & RGB_MASK) << RGB_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `col_trace` -- Trace line colour.
    pub mod col_trace {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000188;
        pub const RESET: u32 = 0x00FFFF00;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `rgb` (RW) -- 0xRRGGBB.
        pub const RGB_LSB: u32 = 0;
        pub const RGB_WIDTH: u32 = 24;
        pub const RGB_MASK: u32 = 0x00FFFFFF;
        pub const RGB_RESET: u32 = 0x00FFFF00;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn rgb(self) -> u32 {
                (self.0 >> RGB_LSB) & RGB_MASK
            }
            pub fn with_rgb(self, v: u32) -> Self {
                Value((self.0 & !(RGB_MASK << RGB_LSB)) | ((v & RGB_MASK) << RGB_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `col_grid` -- Grid line colour.
    pub mod col_grid {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x0000018C;
        pub const RESET: u32 = 0x00606060;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `rgb` (RW) -- 0xRRGGBB.
        pub const RGB_LSB: u32 = 0;
        pub const RGB_WIDTH: u32 = 24;
        pub const RGB_MASK: u32 = 0x00FFFFFF;
        pub const RGB_RESET: u32 = 0x00606060;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn rgb(self) -> u32 {
                (self.0 >> RGB_LSB) & RGB_MASK
            }
            pub fn with_rgb(self, v: u32) -> Self {
                Value((self.0 & !(RGB_MASK << RGB_LSB)) | ((v & RGB_MASK) << RGB_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `cursor_ctrl` -- Tuning cursor: a vertical line across the windows selected by window_mask.
    pub mod cursor_ctrl {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000190;
        pub const RESET: u32 = 0x00000100;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `enable` (RW) -- 1 = draw.
        pub const ENABLE_LSB: u32 = 0;
        pub const ENABLE_WIDTH: u32 = 1;
        pub const ENABLE_MASK: u32 = 0x00000001;
        pub const ENABLE_RESET: u32 = 0x00000000;
        /// `window_mask` (RW) -- Bit i set = drawn in window i.
        pub const WINDOW_MASK_LSB: u32 = 1;
        pub const WINDOW_MASK_WIDTH: u32 = 4;
        pub const WINDOW_MASK_MASK: u32 = 0x0000000F;
        pub const WINDOW_MASK_RESET: u32 = 0x00000000;
        /// `width` (RW) -- Width in pixels (0 counts as 1).
        pub const WIDTH_LSB: u32 = 8;
        pub const WIDTH_WIDTH: u32 = 4;
        pub const WIDTH_MASK: u32 = 0x0000000F;
        pub const WIDTH_RESET: u32 = 0x00000001;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn enable(self) -> bool {
                (self.0 >> ENABLE_LSB) & 1 != 0
            }
            pub fn with_enable(self, v: bool) -> Self {
                let bit = (v as u32) << ENABLE_LSB;
                Value((self.0 & !(ENABLE_MASK << ENABLE_LSB)) | bit)
            }
            pub fn window_mask(self) -> u32 {
                (self.0 >> WINDOW_MASK_LSB) & WINDOW_MASK_MASK
            }
            pub fn with_window_mask(self, v: u32) -> Self {
                Value(
                    (self.0 & !(WINDOW_MASK_MASK << WINDOW_MASK_LSB))
                        | ((v & WINDOW_MASK_MASK) << WINDOW_MASK_LSB),
                )
            }
            pub fn width(self) -> u32 {
                (self.0 >> WIDTH_LSB) & WIDTH_MASK
            }
            pub fn with_width(self, v: u32) -> Self {
                Value((self.0 & !(WIDTH_MASK << WIDTH_LSB)) | ((v & WIDTH_MASK) << WIDTH_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `cursor_x` -- Cursor left edge, screen pixels.
    pub mod cursor_x {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000194;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `x` (RW) -- Screen x.
        pub const X_LSB: u32 = 0;
        pub const X_WIDTH: u32 = 12;
        pub const X_MASK: u32 = 0x00000FFF;
        pub const X_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn x(self) -> u32 {
                (self.0 >> X_LSB) & X_MASK
            }
            pub fn with_x(self, v: u32) -> Self {
                Value((self.0 & !(X_MASK << X_LSB)) | ((v & X_MASK) << X_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `cursor_col` -- Cursor colour.
    pub mod cursor_col {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000198;
        pub const RESET: u32 = 0x00FF0000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `rgb` (RW) -- 0xRRGGBB.
        pub const RGB_LSB: u32 = 0;
        pub const RGB_WIDTH: u32 = 24;
        pub const RGB_MASK: u32 = 0x00FFFFFF;
        pub const RGB_RESET: u32 = 0x00FF0000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn rgb(self) -> u32 {
                (self.0 >> RGB_LSB) & RGB_MASK
            }
            pub fn with_rgb(self, v: u32) -> Self {
                Value((self.0 & !(RGB_MASK << RGB_LSB)) | ((v & RGB_MASK) << RGB_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `pb_range` -- Receiver passband k: screen columns x0 <= x < x1.
    pub mod pb_range {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000200;
        pub const STRIDE: u32 = 0x00000010;
        pub const COUNT: u32 = 8;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "pb_range index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `x0` (RW) -- First screen column.
        pub const X0_LSB: u32 = 0;
        pub const X0_WIDTH: u32 = 12;
        pub const X0_MASK: u32 = 0x00000FFF;
        pub const X0_RESET: u32 = 0x00000000;
        /// `x1` (RW) -- One past the last screen column.
        pub const X1_LSB: u32 = 16;
        pub const X1_WIDTH: u32 = 12;
        pub const X1_MASK: u32 = 0x00000FFF;
        pub const X1_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn x0(self) -> u32 {
                (self.0 >> X0_LSB) & X0_MASK
            }
            pub fn with_x0(self, v: u32) -> Self {
                Value((self.0 & !(X0_MASK << X0_LSB)) | ((v & X0_MASK) << X0_LSB))
            }
            pub fn x1(self) -> u32 {
                (self.0 >> X1_LSB) & X1_MASK
            }
            pub fn with_x1(self, v: u32) -> Self {
                Value((self.0 & !(X1_MASK << X1_LSB)) | ((v & X1_MASK) << X1_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: Value) {
            r.write32(addr(index), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, index: u32, f: impl FnOnce(Value) -> Value) {
            write(r, index, f(read(r, index)))
        }
    }

    /// `pb_ctrl` -- Receiver passband k: where the lowest-numbered enabled passband covering a pixel blends its colour over the picture.
    pub mod pb_ctrl {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000204;
        pub const STRIDE: u32 = 0x00000010;
        pub const COUNT: u32 = 8;
        pub const RESET: u32 = 0x00000800;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "pb_ctrl index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `enable` (RW) -- 1 = draw.
        pub const ENABLE_LSB: u32 = 0;
        pub const ENABLE_WIDTH: u32 = 1;
        pub const ENABLE_MASK: u32 = 0x00000001;
        pub const ENABLE_RESET: u32 = 0x00000000;
        /// `window_mask` (RW) -- Bit i set = drawn in window i.
        pub const WINDOW_MASK_LSB: u32 = 1;
        pub const WINDOW_MASK_WIDTH: u32 = 4;
        pub const WINDOW_MASK_MASK: u32 = 0x0000000F;
        pub const WINDOW_MASK_RESET: u32 = 0x00000000;
        /// `alpha` (RW) -- Opacity in sixteenths, 0-16 (larger values count as 16).
        pub const ALPHA_LSB: u32 = 8;
        pub const ALPHA_WIDTH: u32 = 5;
        pub const ALPHA_MASK: u32 = 0x0000001F;
        pub const ALPHA_RESET: u32 = 0x00000008;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn enable(self) -> bool {
                (self.0 >> ENABLE_LSB) & 1 != 0
            }
            pub fn with_enable(self, v: bool) -> Self {
                let bit = (v as u32) << ENABLE_LSB;
                Value((self.0 & !(ENABLE_MASK << ENABLE_LSB)) | bit)
            }
            pub fn window_mask(self) -> u32 {
                (self.0 >> WINDOW_MASK_LSB) & WINDOW_MASK_MASK
            }
            pub fn with_window_mask(self, v: u32) -> Self {
                Value(
                    (self.0 & !(WINDOW_MASK_MASK << WINDOW_MASK_LSB))
                        | ((v & WINDOW_MASK_MASK) << WINDOW_MASK_LSB),
                )
            }
            pub fn alpha(self) -> u32 {
                (self.0 >> ALPHA_LSB) & ALPHA_MASK
            }
            pub fn with_alpha(self, v: u32) -> Self {
                Value((self.0 & !(ALPHA_MASK << ALPHA_LSB)) | ((v & ALPHA_MASK) << ALPHA_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: Value) {
            r.write32(addr(index), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, index: u32, f: impl FnOnce(Value) -> Value) {
            write(r, index, f(read(r, index)))
        }
    }

    /// `pb_col` -- Receiver passband k colour.
    pub mod pb_col {
        use crate::RegisterSpace;

        pub const OFFSET: u32 = 0x00000208;
        pub const STRIDE: u32 = 0x00000010;
        pub const COUNT: u32 = 8;
        pub const RESET: u32 = 0x0000A0FF;

        /// Absolute address of instance `index` (0..COUNT).
        pub fn addr(index: u32) -> u32 {
            assert!(index < COUNT, "pb_col index out of range");
            super::BASE + OFFSET + index * STRIDE
        }

        /// `rgb` (RW) -- 0xRRGGBB.
        pub const RGB_LSB: u32 = 0;
        pub const RGB_WIDTH: u32 = 24;
        pub const RGB_MASK: u32 = 0x00FFFFFF;
        pub const RGB_RESET: u32 = 0x0000A0FF;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn rgb(self) -> u32 {
                (self.0 >> RGB_LSB) & RGB_MASK
            }
            pub fn with_rgb(self, v: u32) -> Self {
                Value((self.0 & !(RGB_MASK << RGB_LSB)) | ((v & RGB_MASK) << RGB_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R, index: u32) -> Value {
            Value(r.read32(addr(index)))
        }
        pub fn write<R: RegisterSpace>(r: &R, index: u32, value: Value) {
            r.write32(addr(index), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, index: u32, f: impl FnOnce(Value) -> Value) {
            write(r, index, f(read(r, index)))
        }
    }
}

/// `zoom` register block (base 0xe8060000).
///
/// Zoom DDC and zoom FFT (docs/ARCHITECTURE.md 3.4, docs/F3_ZOOM.md): tunes a zoom centre and a span
/// (3 kHz to 3.072 MHz, powers of two), decimates, windows, and runs a 4,096-point complex FFT over
/// rtl/zoom/zoom_spectrum.v. Also the zoom backend: column reduction, K-frame averaging, dB
/// conversion and waterfall colour mapping over that FFT's output, sharing its arithmetic (log-domain
/// K-average, docs/ARCHITECTURE.md 3.14 change C6a) with the full-band spectrum's own walk engine.
/// Output (line values, waterfall bytes) is not in this register block; it is a fabric stream/port,
/// consumed the same way full-band spectrum output is (see the spectrum block).
/// status: final
pub mod zoom {
    pub const BASE: u32 = 0xE8060000;
    pub const SIZE: u32 = 0x00010000;

    /// `id` -- Block identifier/version: 'ZM' + version 2 (version 2: narrow_shift, narrow_gain, backend_ft8_columns; one line buffer). Reads 0 in a chip built without the zoom receiver.
    pub mod id {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000000;
        pub const RESET: u32 = 0x5A4D0002;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `phase_inc` -- Zoom-centre NCO phase increment: round(f_Hz / 76.8e6 * 2^32), signed two's complement, relative to the HL2 ADC clock (0.018 Hz steps). Same convention as rx_bank's phase_inc.
    pub mod phase_inc {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000004;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `value` (RW) -- Signed 32-bit phase increment.
        pub const VALUE_LSB: u32 = 0;
        pub const VALUE_WIDTH: u32 = 32;
        pub const VALUE_MASK: u32 = 0xFFFFFFFF;
        pub const VALUE_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn value(self) -> u32 {
                (self.0 >> VALUE_LSB) & VALUE_MASK
            }
            pub fn with_value(self, v: u32) -> Self {
                Value((self.0 & !(VALUE_MASK << VALUE_LSB)) | ((v & VALUE_MASK) << VALUE_LSB))
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `ctrl` -- Zoom DDC/FFT enable and span selection.
    pub mod ctrl {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000008;
        pub const RESET: u32 = 0x0000000C;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `enable` (RW) -- 1 = zoom DDC running and feeding the zoom FFT. 0 holds the DDC in reset: clear it, change span_shift, set it again.
        pub const ENABLE_LSB: u32 = 0;
        pub const ENABLE_WIDTH: u32 = 1;
        pub const ENABLE_MASK: u32 = 0x00000001;
        pub const ENABLE_RESET: u32 = 0x00000000;
        /// `span_shift` (RW) -- Span = 3.072 MHz >> span_shift: 0 = 3.072 MHz, 1 = 1.536 MHz, 2 = 768 kHz, 3 = 384 kHz, 4 = 192 kHz, 5 = 96 kHz, 6 = 48 kHz (reset default). Narrower spans: 6 here and narrow_shift.
        pub const SPAN_SHIFT_LSB: u32 = 1;
        pub const SPAN_SHIFT_WIDTH: u32 = 3;
        pub const SPAN_SHIFT_MASK: u32 = 0x00000007;
        pub const SPAN_SHIFT_RESET: u32 = 0x00000006;
        /// `backend_column_mode` (RW) -- Zoom backend: 0 = max per column (keeps narrow carriers visible), 1 = mean per column (noise floor), same meaning as the full-band spectrum's ctrl.column_mode.
        pub const BACKEND_COLUMN_MODE_LSB: u32 = 4;
        pub const BACKEND_COLUMN_MODE_WIDTH: u32 = 1;
        pub const BACKEND_COLUMN_MODE_MASK: u32 = 0x00000001;
        pub const BACKEND_COLUMN_MODE_RESET: u32 = 0x00000000;
        /// `backend_peak_hold` (RW) -- Zoom backend: 1 = averaging BSRAM holds the peak over K transforms instead of the mean.
        pub const BACKEND_PEAK_HOLD_LSB: u32 = 5;
        pub const BACKEND_PEAK_HOLD_WIDTH: u32 = 1;
        pub const BACKEND_PEAK_HOLD_MASK: u32 = 0x00000001;
        pub const BACKEND_PEAK_HOLD_RESET: u32 = 0x00000000;
        /// `narrow_shift` (RW) -- Narrow spans (rtl/zoom/zoom_cic_narrow.v): with span_shift = 6, span = 48 kHz >> narrow_shift: 1 = 24 kHz, 2 = 12 kHz, 3 = 6 kHz, 4 = 3 kHz (5 to 7: 4). Ignored (0) unless span_shift = 6. Change only with enable = 0.
        pub const NARROW_SHIFT_LSB: u32 = 6;
        pub const NARROW_SHIFT_WIDTH: u32 = 3;
        pub const NARROW_SHIFT_MASK: u32 = 0x00000007;
        pub const NARROW_SHIFT_RESET: u32 = 0x00000000;
        /// `narrow_gain` (RW) -- Gain of the narrow spans' extra decimation stage, 4^narrow_gain: 0 = 0 dB, 1 = 12.04 dB, 2 = 24.08 dB, 3 = 36.12 dB, saturating. Lifts the band noise of a few kHz over the rounding of the 16-bit samples and of the power words behind it. No effect with narrow_shift = 0.
        pub const NARROW_GAIN_LSB: u32 = 9;
        pub const NARROW_GAIN_WIDTH: u32 = 2;
        pub const NARROW_GAIN_MASK: u32 = 0x00000003;
        pub const NARROW_GAIN_RESET: u32 = 0x00000000;
        /// `backend_ft8_columns` (RW) -- Zoom backend column scale: 0 = the 3,277 displayed bins across the 1,920 columns (column = span / 1,920). 1 = 0.71533 columns per bin, starting at the low edge of the span: at the 6 kHz span (narrow_shift = 3) one column is 2.5597 Hz, so 1,172 columns are 3,000 Hz (the FT8 screen's scale); bins beyond column 1,919 are not shown.
        pub const BACKEND_FT8_COLUMNS_LSB: u32 = 11;
        pub const BACKEND_FT8_COLUMNS_WIDTH: u32 = 1;
        pub const BACKEND_FT8_COLUMNS_MASK: u32 = 0x00000001;
        pub const BACKEND_FT8_COLUMNS_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn enable(self) -> bool {
                (self.0 >> ENABLE_LSB) & 1 != 0
            }
            pub fn with_enable(self, v: bool) -> Self {
                let bit = (v as u32) << ENABLE_LSB;
                Value((self.0 & !(ENABLE_MASK << ENABLE_LSB)) | bit)
            }
            pub fn span_shift(self) -> u32 {
                (self.0 >> SPAN_SHIFT_LSB) & SPAN_SHIFT_MASK
            }
            pub fn with_span_shift(self, v: u32) -> Self {
                Value(
                    (self.0 & !(SPAN_SHIFT_MASK << SPAN_SHIFT_LSB))
                        | ((v & SPAN_SHIFT_MASK) << SPAN_SHIFT_LSB),
                )
            }
            pub fn backend_column_mode(self) -> bool {
                (self.0 >> BACKEND_COLUMN_MODE_LSB) & 1 != 0
            }
            pub fn with_backend_column_mode(self, v: bool) -> Self {
                let bit = (v as u32) << BACKEND_COLUMN_MODE_LSB;
                Value((self.0 & !(BACKEND_COLUMN_MODE_MASK << BACKEND_COLUMN_MODE_LSB)) | bit)
            }
            pub fn backend_peak_hold(self) -> bool {
                (self.0 >> BACKEND_PEAK_HOLD_LSB) & 1 != 0
            }
            pub fn with_backend_peak_hold(self, v: bool) -> Self {
                let bit = (v as u32) << BACKEND_PEAK_HOLD_LSB;
                Value((self.0 & !(BACKEND_PEAK_HOLD_MASK << BACKEND_PEAK_HOLD_LSB)) | bit)
            }
            pub fn narrow_shift(self) -> u32 {
                (self.0 >> NARROW_SHIFT_LSB) & NARROW_SHIFT_MASK
            }
            pub fn with_narrow_shift(self, v: u32) -> Self {
                Value(
                    (self.0 & !(NARROW_SHIFT_MASK << NARROW_SHIFT_LSB))
                        | ((v & NARROW_SHIFT_MASK) << NARROW_SHIFT_LSB),
                )
            }
            pub fn narrow_gain(self) -> u32 {
                (self.0 >> NARROW_GAIN_LSB) & NARROW_GAIN_MASK
            }
            pub fn with_narrow_gain(self, v: u32) -> Self {
                Value(
                    (self.0 & !(NARROW_GAIN_MASK << NARROW_GAIN_LSB))
                        | ((v & NARROW_GAIN_MASK) << NARROW_GAIN_LSB),
                )
            }
            pub fn backend_ft8_columns(self) -> bool {
                (self.0 >> BACKEND_FT8_COLUMNS_LSB) & 1 != 0
            }
            pub fn with_backend_ft8_columns(self, v: bool) -> Self {
                let bit = (v as u32) << BACKEND_FT8_COLUMNS_LSB;
                Value((self.0 & !(BACKEND_FT8_COLUMNS_MASK << BACKEND_FT8_COLUMNS_LSB)) | bit)
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `backend_averaging_k` -- Zoom backend: zoom FFT frames averaged per output line. Reset default 32 is a placeholder (the zoom FFT's own frame rate varies with span_shift, unlike the full-band spectrum's fixed 4,687.5 transforms/s); firmware sets this once the target line rate is known.
    pub mod backend_averaging_k {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x0000000C;
        pub const RESET: u32 = 0x00000020;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
        pub fn write<R: RegisterSpace>(r: &R, value: u32) {
            r.write32(addr(), value)
        }
    }

    /// `backend_level` -- Zoom backend: firmware-set offset and gain applied before the 8-bit waterfall colour index, same formula as the full-band spectrum's own level register.
    pub mod backend_level {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000010;
        pub const RESET: u32 = 0x01000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `offset_db64` (RW) -- Signed dB offset, 1/64 dB steps (matches the 16-bit dB line format).
        pub const OFFSET_DB64_LSB: u32 = 0;
        pub const OFFSET_DB64_WIDTH: u32 = 16;
        pub const OFFSET_DB64_MASK: u32 = 0x0000FFFF;
        pub const OFFSET_DB64_RESET: u32 = 0x00000000;
        /// `gain_q8` (RW) -- Unsigned gain, Q8.8 fixed point (0x0100 = 1.0).
        pub const GAIN_Q8_LSB: u32 = 16;
        pub const GAIN_Q8_WIDTH: u32 = 16;
        pub const GAIN_Q8_MASK: u32 = 0x0000FFFF;
        pub const GAIN_Q8_RESET: u32 = 0x00000100;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn offset_db64(self) -> u32 {
                (self.0 >> OFFSET_DB64_LSB) & OFFSET_DB64_MASK
            }
            pub fn with_offset_db64(self, v: u32) -> Self {
                Value(
                    (self.0 & !(OFFSET_DB64_MASK << OFFSET_DB64_LSB))
                        | ((v & OFFSET_DB64_MASK) << OFFSET_DB64_LSB),
                )
            }
            pub fn gain_q8(self) -> u32 {
                (self.0 >> GAIN_Q8_LSB) & GAIN_Q8_MASK
            }
            pub fn with_gain_q8(self, v: u32) -> Self {
                Value(
                    (self.0 & !(GAIN_Q8_MASK << GAIN_Q8_LSB)) | ((v & GAIN_Q8_MASK) << GAIN_Q8_LSB),
                )
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        pub fn write<R: RegisterSpace>(r: &R, value: Value) {
            r.write32(addr(), value.0)
        }
        pub fn modify<R: RegisterSpace>(r: &R, f: impl FnOnce(Value) -> Value) {
            write(r, f(read(r)))
        }
    }

    /// `backend_line_count` -- Zoom backend: free-running count of zoom spectrum lines produced.
    pub mod backend_line_count {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000014;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        pub fn read<R: RegisterSpace>(r: &R) -> u32 {
            r.read32(addr())
        }
    }

    /// `backend_line_status` -- Zoom backend: line status. There is one zoom line buffer since id version 2 (the compositor keeps its own copy of the line).
    pub mod backend_line_status {
        use crate::RegisterSpace;

        pub const ADDR: u32 = 0x00000018;
        pub const RESET: u32 = 0x00000000;

        /// Absolute address.
        pub fn addr() -> u32 {
            super::BASE + ADDR
        }

        /// `ready_buffer` (RO) -- Always 0 (was: index of the buffer to read, when there were two).
        pub const READY_BUFFER_LSB: u32 = 0;
        pub const READY_BUFFER_WIDTH: u32 = 1;
        pub const READY_BUFFER_MASK: u32 = 0x00000001;
        pub const READY_BUFFER_RESET: u32 = 0x00000000;
        /// `line_done` (W1C) -- Set on every completed zoom line; drives its own fabric interrupt line (firmware-side use only).
        pub const LINE_DONE_LSB: u32 = 1;
        pub const LINE_DONE_WIDTH: u32 = 1;
        pub const LINE_DONE_MASK: u32 = 0x00000001;
        pub const LINE_DONE_RESET: u32 = 0x00000000;

        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub struct Value(pub u32);

        impl Value {
            pub fn ready_buffer(self) -> bool {
                (self.0 >> READY_BUFFER_LSB) & 1 != 0
            }
            pub fn line_done(self) -> bool {
                (self.0 >> LINE_DONE_LSB) & 1 != 0
            }
        }

        pub fn read<R: RegisterSpace>(r: &R) -> Value {
            Value(r.read32(addr()))
        }
        // No modify(): this register has a write-1-to-clear field, and a read-modify-write
        // would clear every other set W1C bit at the same time. Use clear_<field>() instead.
        /// Write-1-to-clear `line_done` only.
        pub fn clear_line_done<R: RegisterSpace>(r: &R) {
            r.write32(addr(), LINE_DONE_MASK << LINE_DONE_LSB);
        }
    }
}
