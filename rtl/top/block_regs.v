// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// block_regs: the register pages of four blocks of the radio that have no register port of their own (the receiver
// bank, the transmit chain, the audio engine and the video block), written as four small modules in one file.
//
// WHAT THEY ARE AND WHERE THEY SIT
// The AE350 CPU reaches every block of the FPGA through a bus of 32-bit registers, one 64 KB page per block
// (docs/ARCHITECTURE.md 4.1, the bus itself in ahb_reg_bridge.v and regbus_cdc_dst.v). In front of each page sits a
// regbus_leg.v, which hands the page a one-clock write strobe (bus_wr), a one-clock read strobe (bus_rd), the offset of
// the register inside the page (bus_addr, 16 bits, always a multiple of 4 because registers are 32 bits wide) and the
// write data (bus_wdata). The leg keeps bus_addr and bus_wdata unchanged from the strobe until the next access to the
// same page. Every module here answers on bus_rdata, which the leg passes on to the page OR in sdr_core.v, so
// a module must drive bus_rdata to zero whenever the current address is not one of its registers.
// The register layouts (offsets, field positions, reset values) are written once in hw/regmap/*.toml and turned into the
// `define constants of the generated include files below, so the offsets named in this file always match the firmware.
// All four modules run in clk_dsp (120 MHz).
//
// WHY THE DECODE IS REGISTERED
// An address compare, the read selection and the load enables of a row of 32-bit registers used to happen in the same
// clock, which made seven levels of logic and, because the decode was shared between blocks, a single net with 133 loads
// that was hard to route at 120 MHz. Now each module compares the address in the clock after the strobe and keeps the
// result in a register with one flag per register: `we` (a one-clock write flag, only set when the strobe was a write)
// and `rs` (the read selection, stays while the address stays). The registers load from `we` one clock later, and the
// read data is a registered AND-OR of the registers selected by `rs`. The price is latency: a write lands, and read data
// is valid, two clocks after the strobe (three for the sticky flags that a write clears in sys_regs.v). The
// regbus_cdc_dst read latency (RD_LAT, 12 clocks on the clk_dsp bus) is longer than that, so nothing waits for these blocks.
// For a beginner: a "sticky" flag is a bit that the hardware sets when something happens and that stays set until the
// CPU clears it, and "W1C" means write-1-to-clear, so writing a 1 into that bit clears it and writing a 0 leaves it.
//
// THE FOUR MODULES
//   rx_bank_regs  page 0xE803_0000  the receiver bank (rtl/rx/rx_bank.v). That block has a write-only port, so this module
//                                   keeps a shadow copy of every word written so that the CPU can read it back, and it
//                                   translates the control word between the layout of the register map and the layout the
//                                   bank expects (the translation is explained at the write below).
//   tx_regs       page 0xE808_0000  the transmit chain and its baseband ring in DDR3
//   audio_regs    page 0xE809_0000  the audio engine ring, volume and the digital audio outputs
//   video_regs    page 0xE807_0000  the frame buffer and waterfall fields of the video block. This module is not
//                                   instantiated in the chip, because rtl/video/compositor.v serves that page with its
//                                   own, larger register set (windows, palette, overlays); the module is kept as the small
//                                   version of the page, with its offsets taken from the same generated include file.
//
// A note on the interrupt outputs of tx_regs and audio_regs: each one is a level (a held 1) that rises when the ring
// reader reports "low water", meaning that the ring in DDR3 is running empty and the CPU should write more samples. The
// level stays until the CPU writes 1 to the low-water bit of the block's status register. sys_regs.v turns that level
// into the pending bit of the interrupt line (docs/ARCHITECTURE.md 4.3: line 3 audio, line 4 transmit).
// Terms such as ring, NCO, phase increment and DDR3 are explained in docs/learn/GLOSSARY.md.

`timescale 1ns / 1ps

`include "hw/regmap/generated/rx_bank_regs.vh"
`include "hw/regmap/generated/tx_regs.vh"
`include "hw/regmap/generated/audio_regs.vh"
`include "hw/regmap/generated/video_regs.vh"

// ================================================================================ rx_bank_regs
// rx_bank_regs: the page of the receiver bank, with one 32-bit phase increment word and one 32-bit control word for
// each of up to eight receivers.
//   offset 0x00  ID           read-only, 0x5258_0001 (the ASCII letters "RX" and a version number 1)
//   offset 0x04 + 8 i  PHASE_INC of receiver i, read-write, 32 bits: the frequency word of the receiver's numerically
//                      controlled oscillator (NCO), which is the digital signal that mixes the wanted station down to
//                      zero frequency. It is round(f_Hz / 76.8e6 x 2^32), a signed number, relative to the HL2's ADC clock.
//   offset 0x08 + 8 i  CTRL of receiver i, read-write: bit 0 = enable (the receiver runs and feeds the shared IQ stream),
//                      bits 2:1 = rate_sel, the output sample rate (0 = 48 kHz, 1 = 96 kHz, 2 = 192 kHz, 3 = 384 kHz).
// Receivers at or above NRX read as 0 and ignore writes.
module rx_bank_regs #(
    parameter integer NRX = 8              // number of receivers built (1 to 8); this many pairs of registers answer
) (
    input  wire        clk,  // clock of the register bus, clk_dsp (120 MHz)
    input  wire        rst,  // synchronous reset, high = reset; stops writes in progress (the shadow copies are not cleared by it)
    input  wire        bus_wr,  // write strobe from regbus_leg, high for one clock per CPU write
    input  wire        bus_rd,  // read strobe from regbus_leg, high for one clock per CPU read; unused here because the read data is selected by the address alone
    input  wire [15:0] bus_addr,  // offset of the register inside the 64 KB page (a multiple of 4)
    input  wire [31:0] bus_wdata,  // data of the CPU write, held until the next access to this page
    output reg  [31:0] bus_rdata,  // read data back to the leg: the selected register, or 0 for an address that is not a register of this page
    // Write port of rtl/rx/rx_bank.v, which takes one write per clock: rb_wr is a one-clock write strobe, rb_addr is
    // {receiver number[2:0], sel} with sel 0 = phase increment and sel 1 = control, rb_wdata is the 32-bit word
    // (for a control word it is already in the layout the bank expects, see below).
    output reg         rb_wr,
    output reg  [3:0]  rb_addr,
    output reg  [31:0] rb_wdata
) /* synthesis syn_maxfan = 10000 */;
    // One 32-bit shadow word per register (two per receiver, indexed like rb_addr), so that the CPU can read back what it wrote,
    // because rx_bank.v has no read port. They start at zero when the chip is configured and are not touched by rst.
    reg [31:0] shadow [0:2*NRX-1];
    integer i;
    // Clears the shadow words at configuration time (an initial statement sets the power-up value of a register in the FPGA).
    initial for (i = 0; i < 2*NRX; i = i + 1) shadow[i] = 32'd0;

    // The registers sit at offsets 0x004 to 0x043 for eight receivers: receiver i has its phase increment at 0x004 + 8i
    // and its control word at 0x008 + 8i. rel is the distance from the first register in bytes, so rel[5:2] is the
    // register number 0..15 (receiver = rel[5:3], sel = rel[2]).
    wire [15:0] rel    = bus_addr - `RX_BANK_PHASE_INC_OFFSET;
    // in_arr: the address lies inside the array of registers of the receivers that exist and is word aligned
    wire        in_arr = (bus_addr >= `RX_BANK_PHASE_INC_OFFSET) &&
                         (bus_addr <  `RX_BANK_PHASE_INC_OFFSET + 16'd8 * NRX) && (bus_addr[1:0] == 2'b00);

    // Registered decode flags: we_arr = write to a register of the array (one clock), rs_arr = read selection of the
    // array and rs_id = read selection of the ID register (both stay while the address stays), idx = register number.
    reg        we_arr = 1'b0, rs_arr = 1'b0, rs_id = 1'b0;
    reg [3:0]  idx = 4'd0;

    // Power-up values of the outputs (no write, read data 0).
    initial begin rb_wr = 1'b0; rb_addr = 4'd0; rb_wdata = 32'd0; bus_rdata = 32'd0; end

    // One always block does both steps: the decode flags are registered in the first clock after the strobe, and
    // the shadow word, the write to the bank and the read data follow in the second.
    always @(posedge clk) begin
        // clock 1 after the strobe: compare the address (gated by reset for writes) and register the flags
        we_arr <= bus_wr && in_arr && !rst;
        rs_arr <= in_arr;
        rs_id  <= (bus_addr == `RX_BANK_ID_ADDR);
        idx    <= rel[5:2];

        // rb_wr is a one-clock pulse, so it is cleared here every clock and set again below only in a clock that writes
        rb_wr <= 1'b0;
        // clock 2: the write lands in the shadow word and goes on to the receiver bank
        if (we_arr) begin
            shadow[idx] <= bus_wdata;
            rb_wr       <= 1'b1;
            rb_addr     <= idx;
            // The register map puts enable in bit 0 and rate_sel in bits 2:1 of the control word, while rx_bank.v wants
            // {enable, rate_sel[1:0]} in bits 2:0, so odd registers (idx[0] = 1, the control words) are repacked
            // and even registers (the phase increments) go through unchanged.
            rb_wdata    <= idx[0] ? {29'd0, bus_wdata[`RX_BANK_CTRL_ENABLE_LSB],
                                     bus_wdata[`RX_BANK_CTRL_RATE_SEL_LSB +: 2]}
                                  : bus_wdata;
        end
        // read data, registered: the ID constant, a shadow word, or zero for any other address
        if (rs_id)       bus_rdata <= `RX_BANK_ID_RESET;
        else if (rs_arr) bus_rdata <= shadow[idx];
        else             bus_rdata <= 32'd0;
    end
endmodule

// ================================================================================ tx_regs
// tx_regs: the page of the transmit chain. The CPU writes baseband samples into a ring in DDR3 and moves the write pointer;
// the TX ring reader takes them out at the rate of the transmit chain and reports its read pointer back here.
//   offset 0x00  ID           read-only, 0x5458_0001 ("TX", version 1)
//   offset 0x04  CTRL         read-write, bit 0 = enable of the transmit chain (cleared by reset)
//   offset 0x08  GAIN         read-write, bits 15:0 = gain value (read back as written); bits 4:0 of the same word also
//                             go out as gain_shift, the shift the transmit chain applies to the baseband sample
//   offset 0x0C  NCO_PHASE_INC  read-write, 32 bits, frequency word of the transmit NCO
//   offset 0x10  RING_BASE    read-write, byte address of the ring in DDR3
//   offset 0x14  RING_SIZE    read-write, ring size in sample frames, a power of two
//   offset 0x18  RING_WPTR    read-write, write pointer: where the CPU has written up to
//   offset 0x1C  RING_RPTR    read-only, read pointer from the ring reader
//   offset 0x20  STATUS       bit 0 = low water, a sticky flag set when the ring reader's low_water level rises, cleared by
//                             writing 1 to bit 0 (W1C). Bit 1 of the register map ("trimming up") is not built and reads 0.
// All writable registers are zero after reset.
module tx_regs (
    input  wire        clk,  // clock of the register bus, clk_dsp (120 MHz)
    input  wire        rst,  // synchronous reset, high = reset
    input  wire        bus_wr,  // write strobe from regbus_leg, one clock
    input  wire        bus_rd,  // read strobe from regbus_leg, one clock; unused, the read data follows the address
    input  wire [15:0] bus_addr,  // offset inside the page, a multiple of 4
    input  wire [31:0] bus_wdata,  // CPU write data
    output reg  [31:0] bus_rdata,  // read data back to the leg, 0 for an address that is not one of ours
    output reg         enable,  // 1 = transmit chain enabled
    output reg  [4:0]  gain_shift,  // gain shift, 0 to 31 bits, from bits 4:0 of the GAIN register
    output reg  [31:0] nco_freq,  // transmit NCO phase increment word
    output reg  [31:0] ring_base,  // ring base address in DDR3
    output reg  [31:0] ring_wptr,  // ring write pointer, the CPU's
    input  wire [31:0] ring_rptr,  // ring read pointer, from the ring reader
    input  wire        low_water,     // level from the ring reader: 1 = the ring is running low on samples
    output wire        irq            // interrupt line 4: the sticky low-water flag, held until the CPU clears it
) /* synthesis syn_maxfan = 10000 */;
    // ring_size has no output port, it is a register the CPU can write and read back; gain is the full 16-bit gain word
    reg [31:0] ring_size = 32'd0;
    reg [15:0] gain = 16'd0;
    // lw_flag = the sticky flag, lw_d = low_water one clock ago, used to find its rising edge
    reg        lw_flag = 1'b0, lw_d = 1'b0;
    assign irq = lw_flag;

    // one decode flag per register, in the order of the read selection below: bit 0 ID, 1 CTRL, 2 GAIN, 3 NCO phase
    // increment, 4 ring base, 5 ring size, 6 write pointer, 7 read pointer, 8 status
    wire [8:0] hit = {bus_addr == `TX_STATUS_ADDR, bus_addr == `TX_RING_RPTR_ADDR,
                      bus_addr == `TX_RING_WPTR_ADDR, bus_addr == `TX_RING_SIZE_ADDR,
                      bus_addr == `TX_RING_BASE_ADDR, bus_addr == `TX_NCO_PHASE_INC_ADDR,
                      bus_addr == `TX_GAIN_ADDR, bus_addr == `TX_CTRL_ADDR, bus_addr == `TX_ID_ADDR};
    // we = write flag per register (one clock), rs = read selection per register, both registered one clock after the strobe
    reg [8:0] we = 9'd0, rs = 9'd0;

    // one clock for the decode, one more for loading the registers and the read data
    always @(posedge clk) begin
        we   <= bus_wr ? hit : 9'd0;
        rs   <= hit;
        lw_d <= low_water;
        // reset puts every writable register back to zero (rs is not reset, it only follows the address)
        if (rst) begin
            enable <= 1'b0; gain <= 16'd0; gain_shift <= 5'd0; nco_freq <= 32'd0;
            ring_base <= 32'd0; ring_size <= 32'd0; ring_wptr <= 32'd0; lw_flag <= 1'b0;
        end else begin
            // a rising edge of low_water sets the flag; a write of 1 to the status bit below clears it
            if (low_water && !lw_d) lw_flag <= 1'b1;
            // a write to a register loads it in the clock after the decode (we[n] is the flag of register n above)
            if (we[1]) enable <= bus_wdata[`TX_CTRL_ENABLE_LSB];
            // the gain is kept whole for read-back and its low 5 bits are the shift the chain uses
            if (we[2]) begin gain <= bus_wdata[15:0]; gain_shift <= bus_wdata[4:0]; end
            if (we[3]) nco_freq  <= bus_wdata;
            if (we[4]) ring_base <= bus_wdata;
            if (we[5]) ring_size <= bus_wdata;
            if (we[6]) ring_wptr <= bus_wdata;
            // W1C: writing a 1 into bit 0 of the status register clears the flag
            if (we[8] && bus_wdata[`TX_STATUS_LOW_WATER_LSB]) lw_flag <= 1'b0;
        end
        // read data: every register is ANDed with its selection bit and the results are ORed, so only the addressed
        // register shows and every other address reads 0. The 32-bit constant is the ID, and bits above a short register read 0.
        bus_rdata <= ({32{rs[0]}} & `TX_ID_RESET)       |
                     ({32{rs[1]}} & {31'd0, enable})    |
                     ({32{rs[2]}} & {16'd0, gain})      |
                     ({32{rs[3]}} & nco_freq)           |
                     ({32{rs[4]}} & ring_base)          |
                     ({32{rs[5]}} & ring_size)          |
                     ({32{rs[6]}} & ring_wptr)          |
                     ({32{rs[7]}} & ring_rptr)          |
                     ({32{rs[8]}} & {31'd0, lw_flag});
    end
endmodule

// ================================================================================ audio_regs
// audio_regs: the page of the audio engine. The CPU writes finished stereo samples into a ring in DDR3, the audio ring
// reader plays them out through the engine, and the registers below start and stop it and set the digital outputs.
//   offset 0x00  ID           read-only, 0x4155_0001 ("AU", version 1)
//   offset 0x04  CTRL         read-write, bit 0 = enable of the audio engine
//   offset 0x08  RING_BASE    read-write, byte address of the ring in DDR3
//   offset 0x0C  RING_SIZE    read-write, ring size in stereo sample frames, a power of two
//   offset 0x10  RING_WPTR    read-write, write pointer set by the CPU
//   offset 0x14  RING_RPTR    read-only, read pointer from the ring reader
//   offset 0x18  VOLUME       read-write, 0 to 255 linear (the headphone DAC has no volume control of its own); 0 after reset
//   offset 0x1C  STATUS       bit 0 = low water, sticky, cleared by writing 1 (W1C), drives interrupt line 3
//   offset 0x20  OUT_CTRL     read-write, bit 0 = S/PDIF output on, bit 1 = I2S output on, bit 2 = test tone;
//                             3 after reset (S/PDIF and I2S on, no tone)
//   offset 0x24  OUT_STATUS   read-only: bit 0 = audio PLL (49.152 MHz) locked, bit 1 = S/PDIF and I2S are sending samples,
//                             bit 2 = the stream comes from the engine, bits 15:8 = slips (a count that wraps at 255), bits 23:16
//                             = errors, buffer overruns and underruns (wraps at 255). A slip is one sample taken out or put in
//                             to make up the small difference between the stream's 48 kHz and the audio PLL's. Both counters clear on reset.
// The digital outputs themselves are described in docs/AUDIO_OUT.md.
module audio_regs (
    input  wire        clk,  // clock of the register bus, clk_dsp (120 MHz)
    input  wire        rst,  // synchronous reset, high = reset
    input  wire        bus_wr,  // write strobe from regbus_leg, one clock
    input  wire        bus_rd,  // read strobe from regbus_leg, one clock; unused
    input  wire [15:0] bus_addr,  // offset inside the page, a multiple of 4
    input  wire [31:0] bus_wdata,  // CPU write data
    output reg  [31:0] bus_rdata,  // read data back to the leg, 0 for an address that is not one of ours
    output reg         enable,  // 1 = audio engine enabled
    output reg  [31:0] ring_base,  // ring base address in DDR3
    output reg  [31:0] ring_wptr,  // ring write pointer, the CPU's
    input  wire [31:0] ring_rptr,  // ring read pointer, from the ring reader
    input  wire        low_water,  // level from the ring reader: 1 = the ring is running low on samples
    output wire        irq,           // interrupt line 3: the sticky low-water flag, held until the CPU clears it
    // ---- audio outputs begin (docs/AUDIO_OUT.md): S/PDIF, I2S, HDMI audio, test tone
    output reg  [2:0]  out_ctl,       // output switches: bit 0 S/PDIF on, bit 1 I2S on, bit 2 test tone on
    input  wire        out_lock,      // 1 = the audio PLL is locked (already synchronized to clk)
    input  wire        out_run,       // 1 = S/PDIF and I2S are sending samples
    input  wire        out_live,      // 1 = the stream comes from the engine, 0 = it is the test tone or silence
    input  wire        out_ev_slip,   // one-clock pulse for every slip (one sample taken out or put in)
    input  wire        out_ev_err     // one-clock pulse for every buffer overrun or underrun
    // ---- audio outputs end
) /* synthesis syn_maxfan = 10000 */;
    // slips and errors counted since reset, 8 bits each, wrapping from 255 to 0
    reg [7:0]  out_slips = 8'd0, out_errs = 8'd0;
    // out_ctl has its reset value from the very start, so the outputs are on before the first reset reaches the block
    initial out_ctl = `AUDIO_OUT_CTRL_RESET;
    // event counters
    always @(posedge clk) begin
        if (rst) begin out_slips <= 8'd0; out_errs <= 8'd0; end
        else begin
            if (out_ev_slip) out_slips <= out_slips + 8'd1;
            if (out_ev_err)  out_errs  <= out_errs + 8'd1;
        end
    end
    // ring size (frames) and volume (0 to 255) are read-write registers with no outputs of their own here
    reg [31:0] ring_size = 32'd0, volume = 32'd0;
    // lw_flag = sticky low-water flag, lw_d = low_water one clock ago, used to find its rising edge
    reg        lw_flag = 1'b0, lw_d = 1'b0;
    assign irq = lw_flag;

    // one decode flag per register, in the order of the read selection below: bit 0 ID, 1 CTRL, 2 ring base, 3 ring size,
    // 4 write pointer, 5 read pointer, 6 volume, 7 status, 8 output control, 9 output status
    wire [9:0] hit = {bus_addr == `AUDIO_OUT_STATUS_ADDR, bus_addr == `AUDIO_OUT_CTRL_ADDR,
                      bus_addr == `AUDIO_STATUS_ADDR, bus_addr == `AUDIO_VOLUME_ADDR,
                      bus_addr == `AUDIO_RING_RPTR_ADDR, bus_addr == `AUDIO_RING_WPTR_ADDR,
                      bus_addr == `AUDIO_RING_SIZE_ADDR, bus_addr == `AUDIO_RING_BASE_ADDR,
                      bus_addr == `AUDIO_CTRL_ADDR, bus_addr == `AUDIO_ID_ADDR};
    // we = write flag per register (one clock), rs = read selection per register, both registered one clock after the strobe
    reg [9:0] we = 10'd0, rs = 10'd0;

    // one clock for the decode, one more for loading the registers and the read data
    always @(posedge clk) begin
        we   <= bus_wr ? hit : 10'd0;
        rs   <= hit;
        lw_d <= low_water;
        // reset puts every writable register back to zero, except the output switches, which go back to their reset value (3)
        if (rst) begin
            enable <= 1'b0; ring_base <= 32'd0; ring_size <= 32'd0; ring_wptr <= 32'd0;
            volume <= 32'd0; lw_flag <= 1'b0; out_ctl <= `AUDIO_OUT_CTRL_RESET;
        end else begin
            // a rising edge of low_water sets the flag; a write of 1 to the status bit below clears it
            if (low_water && !lw_d) lw_flag <= 1'b1;
            // a write to a register loads it in the clock after the decode (we[n] is the flag of register n above)
            if (we[1]) enable    <= bus_wdata[`AUDIO_CTRL_ENABLE_LSB];
            if (we[2]) ring_base <= bus_wdata;
            if (we[3]) ring_size <= bus_wdata;
            if (we[4]) ring_wptr <= bus_wdata;
            if (we[6]) volume    <= bus_wdata;
            if (we[8]) out_ctl   <= bus_wdata[2:0];
            // W1C: writing a 1 into bit 0 of the status register clears the flag
            if (we[7] && bus_wdata[`AUDIO_STATUS_LOW_WATER_LSB]) lw_flag <= 1'b0;
        end
        // read data: each register ANDed with its selection bit and all ORed together, so only the addressed register shows
        // and every other address reads 0; the last line packs OUT_STATUS as {0, errors, slips, 0, live, run, lock}
        bus_rdata <= ({32{rs[0]}} & `AUDIO_ID_RESET)     |
                     ({32{rs[1]}} & {31'd0, enable})     |
                     ({32{rs[2]}} & ring_base)           |
                     ({32{rs[3]}} & ring_size)           |
                     ({32{rs[4]}} & ring_wptr)           |
                     ({32{rs[5]}} & ring_rptr)           |
                     ({32{rs[6]}} & volume)              |
                     ({32{rs[7]}} & {31'd0, lw_flag})    |
                     ({32{rs[8]}} & {29'd0, out_ctl})    |
                     ({32{rs[9]}} & {8'd0, out_errs, out_slips, 5'd0, out_live, out_run, out_lock});
    end
endmodule

// ================================================================================ video_regs
// video_regs: the small version of the video page (see the header: the chip uses the compositor's page instead).
//   offset 0x00  ID           read-only, 0x5649_0002 ("VI", version 2)
//   offset 0x04  CTRL         read-write, bit 0 = enable, bit 1 = mode_30hz (1 = 30 Hz picture)
//   offset 0x08  FB_BASE      read-write, address of the frame buffer in DDR3
//   offset 0x0C  FB_STRIDE    read-write, distance in bytes from one line of the frame buffer to the next
//   offset 0x70  WF_RING_BASE read-write, address of line 0 of the full-band waterfall ring
//   offset 0x74  WF_WRITE_LINE read-only, 11 bits: the index of the last waterfall line the writer has finished (0 to 2,047)
module video_regs (
    input  wire        clk,  // clock of the register bus, clk_dsp (120 MHz)
    input  wire        rst,  // synchronous reset, high = reset
    input  wire        bus_wr,  // write strobe from regbus_leg, one clock
    input  wire        bus_rd,  // read strobe from regbus_leg, one clock; unused
    input  wire [15:0] bus_addr,  // offset inside the page, a multiple of 4
    input  wire [31:0] bus_wdata,  // CPU write data
    output reg  [31:0] bus_rdata,  // read data back to the leg, 0 for an address that is not one of ours
    output reg         enable,  // 1 = video output enabled
    output reg         mode_30hz,  // 1 = 30 Hz picture
    output reg  [31:0] fb_base,  // frame buffer base address in DDR3
    output reg  [31:0] fb_stride,  // frame buffer line distance in bytes
    output reg  [31:0] wf_ring_base,  // base address of the waterfall ring
    input  wire [10:0] wf_write_line  // from the waterfall writer: index of the last finished line
) /* synthesis syn_maxfan = 10000 */;
    // one decode flag per register, in the order of the read selection below: bit 0 id, 1 ctrl, 2 frame buffer base,
    // 3 stride, 4 waterfall ring base, 5 waterfall write line
    wire [5:0] hit = {bus_addr == `VIDEO_WF_WRITE_LINE_ADDR, bus_addr == `VIDEO_WF_RING_BASE_ADDR,
                      bus_addr == `VIDEO_FB_STRIDE_ADDR, bus_addr == `VIDEO_FB_BASE_ADDR,
                      bus_addr == `VIDEO_CTRL_ADDR, bus_addr == `VIDEO_ID_ADDR};
    // we = write flag per register (one clock), rs = read selection per register, both registered one clock after the strobe
    reg [5:0] we = 6'd0, rs = 6'd0;

    // one clock for the decode, one more for loading the registers and the read data
    always @(posedge clk) begin
        we <= bus_wr ? hit : 6'd0;
        rs <= hit;
        // reset puts every writable register back to zero
        if (rst) begin
            enable <= 1'b0; mode_30hz <= 1'b0; fb_base <= 32'd0; fb_stride <= 32'd0;
            wf_ring_base <= 32'd0;
        end else begin
            // CTRL carries two separate bits
            if (we[1]) begin
                enable    <= bus_wdata[`VIDEO_CTRL_ENABLE_LSB];
                mode_30hz <= bus_wdata[`VIDEO_CTRL_MODE_30HZ_LSB];
            end
            if (we[2]) fb_base      <= bus_wdata;
            if (we[3]) fb_stride    <= bus_wdata;
            if (we[4]) wf_ring_base <= bus_wdata;
        end
        // read data: each register ANDed with its selection bit and all ORed together, so only the addressed register shows
        bus_rdata <= ({32{rs[0]}} & `VIDEO_ID_RESET)             |
                     ({32{rs[1]}} & {30'd0, mode_30hz, enable})  |
                     ({32{rs[2]}} & fb_base)                     |
                     ({32{rs[3]}} & fb_stride)                   |
                     ({32{rs[4]}} & wf_ring_base)                |
                     ({32{rs[5]}} & {21'd0, wf_write_line});
    end
endmodule
