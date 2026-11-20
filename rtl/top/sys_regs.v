// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// sys_regs: the system register page 0xE800_0000, which holds the chip's identity, the interrupt controller of the fabric
// and a few health bits (hw/regmap/system.toml, docs/ARCHITECTURE.md 4.1 and 4.3). It runs in clk_dsp (120 MHz).
//
// REGISTER MAP (offsets inside the page, 32 bits each; RO = read-only, RW = read-write, W1C = write 1 to clear)
//   0x00 ID           RO   0x5452_0001 (the letters "TR" and version 1)
//   0x04 BUILD        RO   an identifier of the bitstream, taken from the build_id input
//   0x08 SCRATCH      RW   32 bits with no effect on the hardware, for the firmware to test the bus
//   0x10 IRQ_PENDING  W1C  bits 15:0, one per interrupt line: set when the line's source rises, cleared by writing 1 to the bit
//   0x14 IRQ_ENABLE   RW   bits 15:0, one per line: a pending line reaches the CPU only when its enable bit is set
//   0x18 IRQ_RAW      RO   bits 15:0, the level of each line's source right now (before the edge latch and the enable)
//   0x1C STATUS       RO   bit 0 = DDR3 initialized and calibrated, bit 1 = every PLL reports lock, bit 8 = bus timeout (sticky,
//                          cleared by writing 1 to bit 8: an AHB access to a register page got no answer), bit 9 = the receive
//                          clock domain gave no answer to the last access to page 0xE802_0000, bits 19:16 = number of receivers built
//   0x20 DSP_CYCLES   RO   free-running 32-bit count of clk_dsp clocks, 8.33 ns each, wrapping about every 35.8 seconds (2^32 / 120 MHz);
//                          the firmware subtracts two reads to measure a time
//
// INTERRUPTS
// `irq_src[n]` is the level of the source of fabric line GPn (the sources are listed in docs/ARCHITECTURE.md 4.3), already in
// clk_dsp. A rising edge sets the line's bit in IRQ_PENDING (writing 1 clears it), and `ext_int[n]` = pending AND enable, registered,
// goes to the AE350's EXT_INT[n] input (PLIC sources 4 and 11 to 25, MUG1029 table 4-2). The edge latch gives every line the same
// contract for the firmware whether its source is a one-clock pulse (a packet was received) or a level that stays until the block's own
// W1C status is cleared (the receiver back end): clear the block first, then clear the pending bit, otherwise the line would
// be set again at once. A pending line stays set until the CPU clears it, which is why the CPU can read IRQ_PENDING to see
// which source woke it.
//
// The status inputs come from other clock domains (the PLL lock and DDR3 flags from the 50 MHz and DDR3 clocks, the bus timeout
// from the 80 MHz bus clock, the receive-domain flag from the clk_rx side), so each one passes through a three-register
// synchronizer before it is used (see docs/learn/GLOSSARY.md, clock domain crossing).

`timescale 1ns / 1ps

`include "hw/regmap/generated/system_regs.vh"

module sys_regs #(
    parameter integer NRX = 8              // receivers built (system.status.num_rx)
) (
    input  wire        clk,  // clock of the register bus, clk_dsp (120 MHz)
    input  wire        rst,  // synchronous reset, high = reset
    // register bus (page-local offset, one-clock strobes; read data comes two clocks after the strobe)
    input  wire        bus_wr,  // write strobe from regbus_leg, one clock per CPU write
    input  wire        bus_rd,  // read strobe, one clock per CPU read; unused, the read data follows the address
    input  wire [15:0] bus_addr,  // offset inside the page in bytes (a multiple of 4)
    input  wire [31:0] bus_wdata,  // data of the CPU write
    output reg  [31:0] bus_rdata,  // read data back to the leg: the addressed register, 0 for any other address
    // status inputs, each from another clock domain (hence the _async in the name)
    input  wire [31:0] build_id,  // build identifier, constant after configuration
    input  wire        ddr3_init_async,  // 1 = the DDR3 controller finished initialization and calibration
    input  wire        plls_locked_async,  // 1 = every PLL reports lock
    input  wire        bus_timeout_tog_async,   // toggles once per bridge timeout (clock of the AHB bus, 80 MHz)
    input  wire        rx_dead_async,  // 1 = the receive clock domain did not answer the last access to its page
    // interrupts
    input  wire [15:0] irq_src,  // levels of the sources of the 16 fabric interrupt lines, already in clk_dsp
    output reg  [15:0] ext_int  // to the AE350's EXT_INT inputs: pending AND enable, registered
) /* synthesis syn_maxfan = 10000 syn_srlstyle = "registers" */;

    // NRX as a 4-bit number for the status register (up to 8 fits)
    localparam [3:0] NRX4 = NRX;
    // Three-register synchronizers for the four status inputs. The third register of each is the one used, so a changing
    // input has two clocks to settle; (* preserve *) keeps the tool from merging or trimming the chain.
    (* preserve *) reg [2:0] s_ddr = 0, s_pll = 0, s_tmo = 0, s_dead = 0;
    always @(posedge clk) begin
        s_ddr  <= {s_ddr[1:0],  ddr3_init_async};
        s_pll  <= {s_pll[1:0],  plls_locked_async};
        s_tmo  <= {s_tmo[1:0],  bus_timeout_tog_async};
        s_dead <= {s_dead[1:0], rx_dead_async};
    end

    // scratch = SCRATCH, pending and enable = IRQ_PENDING and IRQ_ENABLE, src_d = irq_src one clock ago (for the edge)
    reg [31:0] scratch = 32'd0;
    reg [15:0] pending = 16'd0, enable = 16'd0, src_d = 16'd0;
    // bus_timeout = the sticky bit 8 of STATUS
    reg        bus_timeout = 1'b0;
    // cycles = the free-running clock counter behind DSP_CYCLES
    reg [31:0] cycles = 32'd0;

    // rise = a source went from 0 to 1 in this clock
    wire [15:0] rise = irq_src & ~src_d;

    // Registered decode (the scheme is described in block_regs.v): hit has one bit per register, the address compare of
    // this clock, in the order 0 ID, 1 BUILD, 2 SCRATCH, 3 IRQ_PENDING, 4 IRQ_ENABLE, 5 IRQ_RAW, 6 STATUS, 7 DSP_CYCLES.
    // A write lands and the read data is valid two clocks after the strobe (the pending bits that a write clears: three).
    wire [7:0] hit = {bus_addr == `SYSTEM_DSP_CYCLES_ADDR, bus_addr == `SYSTEM_STATUS_ADDR,
                      bus_addr == `SYSTEM_IRQ_RAW_ADDR, bus_addr == `SYSTEM_IRQ_ENABLE_ADDR,
                      bus_addr == `SYSTEM_IRQ_PENDING_ADDR, bus_addr == `SYSTEM_SCRATCH_ADDR,
                      bus_addr == `SYSTEM_BUILD_ADDR, bus_addr == `SYSTEM_ID_ADDR};
    // we = write flag per register (one clock), rs = read selection per register, both registered one clock after the strobe
    reg [7:0]  we = 8'd0, rs = 8'd0;
    // w1c = the pending bits that a write to IRQ_PENDING clears, valid for one clock
    reg [15:0] w1c = 16'd0;          // pending bits a write clears, one clock

    // decode, edge detection, interrupt pending bits and the writable registers
    always @(posedge clk) begin
        we     <= bus_wr ? hit : 8'd0;
        rs     <= hit;
        w1c    <= we[3] ? bus_wdata[15:0] : 16'd0;
        // remember the sources for the edge detection of the next clock
        src_d  <= irq_src;
        // 8.33 ns per count; it wraps without any special handling
        cycles <= cycles + 1'b1;
        // reset clears the writable registers, the pending bits and the outputs
        if (rst) begin
            scratch     <= 32'd0;
            pending     <= 16'd0;
            enable      <= 16'd0;
            bus_timeout <= 1'b0;
            ext_int     <= 16'd0;
        end else begin
            // a new rising edge sets the pending bit and a W1C write clears it; if both happen in one clock the clear wins
            pending <= (pending | rise) & ~w1c;
            // any change of the toggle from the bus bridge marks a timeout; writing 1 to bit 8 of STATUS clears the mark
            if (s_tmo[2] ^ s_tmo[1])
                bus_timeout <= 1'b1;
            else if (we[6] && bus_wdata[`SYSTEM_STATUS_BUS_TIMEOUT_LSB])
                bus_timeout <= 1'b0;
            // CPU writes: we[n] is the write flag of register n (see the list above)
            if (we[2]) scratch <= bus_wdata;
            if (we[4]) enable  <= bus_wdata[15:0];
            // the interrupt output, registered one clock after pending and enable
            ext_int <= pending & enable;
        end
    end

    // read data: each register ANDed with its selection bit and all ORed together, so only the addressed register shows.
    // STATUS is packed as {12 zeros, receivers built, 6 zeros, receive domain dead, bus timeout, 6 zeros, PLLs locked, DDR3 init}.
    always @(posedge clk) begin
        bus_rdata <= ({32{rs[0]}} & `SYSTEM_ID_RESET)    |
                     ({32{rs[1]}} & build_id)            |
                     ({32{rs[2]}} & scratch)             |
                     ({32{rs[3]}} & {16'd0, pending})    |
                     ({32{rs[4]}} & {16'd0, enable})     |
                     ({32{rs[5]}} & {16'd0, irq_src})    |
                     ({32{rs[6]}} & {12'd0, NRX4, 6'd0, s_dead[2], bus_timeout, 6'd0, s_pll[2], s_ddr[2]}) |
                     ({32{rs[7]}} & cycles);
    end

endmodule
