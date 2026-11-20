// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// usb_regs: the register page 0x0E `usb` (hw/regmap/usb.toml, docs/USB_AUDIO.md) of the USB audio device, in clk_dsp, behind a
// regbus_leg (rtl/top/regbus_leg.v): strobes bus_wr / bus_rd for one clock, address and write data held until the
// next access to this page; the decode is registered (as rtl/top/block_regs.v), so a write lands one clock after
// its strobe and read data stands two clocks after it.
//
// It is the window through which the firmware controls the USB sound card and watches it: ten registers (id, ctrl, status,
// fifo_level, fifo_data, fifo_mark, play_errors, more_errors, play_bad, levels, in the order of the list in the bus
// section below; their addresses and bit fields come from the generated header hw/regmap/generated/usb_regs.vh). The controls
// (connect, fifo_en, monitor, loopback, speech_src) go to usb_audio.v and usb_play.v, and the status and the counters
// come from usb_play.v, usb_ep_play.v and usb_ep_cap.v. In the processor's address map the page is
// behind the register bus described in docs/REGMAP.md; terms are in docs/learn/GLOSSARY.md.
//
// Two registers have a side effect on a read, so their value is copied at the read strobe and the copy is what
// the bus gets (the leg samples the answer many clocks later, when the live value has moved on):
//   fifo_data   the oldest word of the CPU FIFO; the read takes it out (f_pop)
//   levels      the two peak meters; the read clears them
//
// Status from the USB clock (configured, the two interfaces' alternate settings) comes in through two
// registers per bit; the two event toggles of rtl/usb/usb_ep_play.v through three. The five fault counters
// are here, 16 bits each, wrapping: playback under-runs, playback over-runs, capture over-runs, CPU FIFO over-runs and bad playback packets, each
// counting events as one-clock pulses, so nothing is missed and a wrap only happens after 65,536 events. The USB clock (48 MHz)
// and the register clock (120 MHz) are unrelated, so a level crossing between them goes through two flip-flops
// (so that a changing level is read as the old or the new value, never as garbage) and an event crosses as a toggle (a bit that
// flips once per event) through three flip-flops, whose last two are compared to give a one-clock pulse.
//
// Latency: a register write takes effect 1 clock after the strobe, a read answer is in bus_rdata 2 clocks after the strobe, and a
// status bit from the USB side is seen 2 clocks (levels) or 3 clocks (events) after it changed, plus up to a clock for the unrelated clock edges.
//
// Gowin specifics: nothing special (about 160 LUTs and no RAM); syn_preserve on the synchronizer registers keeps the tool from
// merging them with equal registers elsewhere or moving them.

`timescale 1ns / 1ps
`include "hw/regmap/generated/usb_regs.vh"

module usb_regs (
    input  wire        clk,  // register clock, 120 MHz
    input  wire        rst,  // synchronous reset
    // register bus from the regbus_leg of this page: write and read strobes (one clock), the 16-bit offset inside the page, the write data
    input  wire        bus_wr,
    input  wire        bus_rd,
    input  wire [15:0] bus_addr,
    input  wire [31:0] bus_wdata,
    output reg  [31:0] bus_rdata = 32'd0,  // the register value being read, valid 2 clocks after the strobe
    output reg         irq = 1'b0,            // 1 while the CPU FIFO holds at least `mark` words (the firmware's interrupt line 12)
    // controls (usb.ctrl and usb.fifo_mark), outputs to the unit
    // controls
    output reg         connect = 1'b1,  // 1 = the pull-up of D+ is on, the device is visible to the PC (1 after reset, so the board enumerates at once)
    output reg         fifo_en = 1'b0,  // 1 = the CPU FIFO is filled with speech samples
    output reg         monitor = 1'b0,  // 1 = the PC's playback is added to the stream of the digital outputs
    output reg         loopback = 1'b0,  // 1 = the PC's recording carries the PC's own playback
    output reg         speech_src = 1'b0,     // 1 = the CPU FIFO takes the USB host's microphone instead of the PC's playback
    output wire        play_on,               // 1 = the PC has the playback interface on (synchronized to this clock)
    // status from the USB clock domain (asynchronous to this clock, synchronized below)
    input  wire        configured_u,  // the PC has configured the device
    input  wire        play_on_u,  // playback interface on (alternate setting 1)
    input  wire        cap_on_u,  // capture interface on
    input  wire        ev_over_t_u,  // toggle: flips when a playback sample was dropped because the FIFO was full
    input  wire        ev_bad_t_u,  // toggle: flips when a bad playback packet was dropped
    // from usb_play.v and usb_ep_cap.v (this clock): status, fill level and event pulses
    input  wire        play_run,  // 1 while the playback reader is running
    input  wire [8:0]  play_fill,  // samples in the playback FIFO, 0 to 256
    input  wire        ev_under,  // one-clock pulse: playback under-run
    input  wire        ev_cap_over,  // one-clock pulse: capture sample dropped
    input  wire        ev_fover,  // one-clock pulse: CPU FIFO sample dropped
    input  wire [31:0] f_word,  // oldest word of the CPU FIFO, {R, L}
    input  wire [10:0] f_level,  // words in the CPU FIFO, 0 to 1,024
    output reg         f_pop = 1'b0,  // one-clock pulse: take the oldest word out of the CPU FIFO
    input  wire [14:0] pk_play,  // peak of the playback samples, 15 bits
    input  wire [14:0] pk_cap,  // peak of the stream to the PC, 15 bits
    output reg         pk_clr = 1'b0  // one-clock pulse: clear both peak meters
) /* synthesis syn_maxfan = 10000 syn_srlstyle = "registers" */;

    // st_a, st_b: two-stage synchronizers for the three status levels (bit 0 configured, bit 1 playback on, bit 2 capture on).
    // ov_s, bd_s: three-stage shift registers for the two event toggles.
    // ---------------------------------------------------------------- crossings from the USB clock
    reg [2:0] st_a = 3'd0 /* synthesis syn_preserve = 1 */;
    reg [2:0] st_b = 3'd0 /* synthesis syn_preserve = 1 */;
    reg [2:0] ov_s = 3'd0 /* synthesis syn_preserve = 1 */;
    reg [2:0] bd_s = 3'd0 /* synthesis syn_preserve = 1 */;
    always @(posedge clk) begin
        st_a <= {cap_on_u, play_on_u, configured_u};
        st_b <= st_a;
        ov_s <= {ov_s[1:0], ev_over_t_u};
        bd_s <= {bd_s[1:0], ev_bad_t_u};
    end
    // The synchronized playback switch, and the two events: a pulse in the clock in which the two last stages differ.
    assign play_on = st_b[1];
    wire ev_over = ov_s[2] ^ ov_s[1];
    wire ev_bad  = bd_s[2] ^ bd_s[1];

    // Fault counters, 16 bits, each counts its events and wraps.
    // ---------------------------------------------------------------- counters
    reg [15:0] n_under = 16'd0, n_over = 16'd0, n_cap = 16'd0, n_fifo = 16'd0, n_bad = 16'd0;
    always @(posedge clk) begin
        if (rst) begin
            n_under <= 16'd0; n_over <= 16'd0; n_cap <= 16'd0; n_fifo <= 16'd0; n_bad <= 16'd0;
        end else begin
            if (ev_under)    n_under <= n_under + 16'd1;
            if (ev_over)     n_over  <= n_over + 16'd1;
            if (ev_cap_over) n_cap   <= n_cap + 16'd1;
            if (ev_fover)    n_fifo  <= n_fifo + 16'd1;
            if (ev_bad)      n_bad   <= n_bad + 16'd1;
        end
    end

    // ---------------------------------------------------------------- bus
    // one flag per register: 0 id, 1 ctrl, 2 status, 3 fifo_level, 4 fifo_data, 5 fifo_mark, 6 play_errors,
    // 7 more_errors, 8 play_bad, 9 levels (the address match of each, in this order)
    wire [9:0] hit = {bus_addr == `USB_LEVELS_ADDR, bus_addr == `USB_PLAY_BAD_ADDR,
                      bus_addr == `USB_MORE_ERRORS_ADDR, bus_addr == `USB_PLAY_ERRORS_ADDR,
                      bus_addr == `USB_FIFO_MARK_ADDR, bus_addr == `USB_FIFO_DATA_ADDR,
                      bus_addr == `USB_FIFO_LEVEL_ADDR, bus_addr == `USB_STATUS_ADDR,
                      bus_addr == `USB_CTRL_ADDR, bus_addr == `USB_ID_ADDR};
    // we: write strobe per register; rs: read select per register (held while the address stays). rd_d: the read strobe, one clock late.
    // mark: the CPU FIFO level at which irq rises. pop_word, pk_copy: the values copied at a read of the two registers with side effects.
    reg [9:0]  we = 10'd0, rs = 10'd0;
    reg        rd_d = 1'b0;
    reg [10:0] mark = `USB_FIFO_MARK_RESET;
    reg [31:0] pop_word = 32'd0;
    reg [29:0] pk_copy = 30'd0;

    // Registered decode, the writes, and the two reads with side effects, then the read data multiplexer.
    always @(posedge clk) begin
        we     <= bus_wr ? hit : 10'd0;
        rs     <= hit;
        rd_d   <= bus_rd;
        f_pop  <= 1'b0;
        pk_clr <= 1'b0;
        irq    <= fifo_en && (f_level >= mark);
        if (rst) begin
            connect <= 1'b1; fifo_en <= 1'b0; monitor <= 1'b0; loopback <= 1'b0; speech_src <= 1'b0;
            mark <= `USB_FIFO_MARK_RESET;
        end else begin
            if (we[1]) begin
                connect  <= bus_wdata[`USB_CTRL_CONNECT_LSB];
                fifo_en  <= bus_wdata[`USB_CTRL_FIFO_EN_LSB];
                monitor  <= bus_wdata[`USB_CTRL_MONITOR_LSB];
                loopback <= bus_wdata[`USB_CTRL_LOOPBACK_LSB];
                speech_src <= bus_wdata[`USB_CTRL_SPEECH_SRC_LSB];
            end
            if (we[5]) mark <= bus_wdata[10:0];
            // the clock after a read strobe: rs holds the register's flag; copy the value and only then take the word out or clear the meters
            if (rd_d && rs[4]) begin
                pop_word <= (f_level != 11'd0) ? f_word : 32'd0;
                f_pop    <= (f_level != 11'd0);
            end
            if (rd_d && rs[9]) begin
                pk_copy <= {pk_cap, pk_play};
                pk_clr  <= 1'b1;
            end
        end
        // Read data: each register's value ANDed with its select and all ORed together; status holds {fill, run, configured/play/capture}.
        bus_rdata <= ({32{rs[0]}} & `USB_ID_RESET)                                       |
                     ({32{rs[1]}} & {27'd0, speech_src, loopback, monitor, fifo_en, connect}) |
                     ({32{rs[2]}} & {7'd0, play_fill, 12'd0, play_run, st_b})            |
                     ({32{rs[3]}} & {21'd0, f_level})                                    |
                     ({32{rs[4]}} & pop_word)                                            |
                     ({32{rs[5]}} & {21'd0, mark})                                       |
                     ({32{rs[6]}} & {n_over, n_under})                                   |
                     ({32{rs[7]}} & {n_fifo, n_cap})                                     |
                     ({32{rs[8]}} & {16'd0, n_bad})                                      |
                     ({32{rs[9]}} & {1'b0, pk_copy[29:15], 1'b0, pk_copy[14:0]});
    end

endmodule
