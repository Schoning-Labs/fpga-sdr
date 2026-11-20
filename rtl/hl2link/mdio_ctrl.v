// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// MDIO master: the two-wire management interface with which a MAC reads and writes the registers
// of an Ethernet PHY chip. Not used in the current design, where the HL2 link arrives over the
// SFP lane and the RJ45 socket belongs to the network unit (docs/HL2_SFP.md section 9), and kept
// together with the other pieces for an RGMII PHY on the HL2 link.
//
// What MDIO is, for a beginner: a PHY (the chip that turns Ethernet's analog signals into digital
// bits) has a few dozen 16-bit registers for its status (is a cable plugged in, which speed was
// negotiated) and settings (restart auto-negotiation, power down). They are reached over MDIO, a
// slow serial bus of one clock wire (MDC) and one bidirectional data wire (MDIO), defined in IEEE
// 802.3 clause 22. This is a plain bit-banged master (no hard MDIO controller exists on this FPGA
// family), which divides the input clock down to MDC, drives MDIO as an open-drain style output
// (the PHY side has a pull-up, so this module drives the wire or lets go of it), and runs the
// standard 32-bit frame:
//
//   32 x preamble '1' | ST 01 | OP (10 read, 01 write) | PHYAD[4:0] | REGAD[4:0] | TA | DATA[15:0]
//
// For a read, TA (turnaround) is "Z0": the master releases the bus after ST, OP, PHYAD and REGAD,
// and the PHY drives a 0 turnaround bit, then 16 data bits. For a write, the master drives TA "10"
// and then the 16 data bits. The PHY address of the RTL8211F on this board is 1 (set by strap
// pins on the chip), and docs/H3_PHY.md explains why no RGMII delay register has to be written
// (both delays are already enabled by strap).
//
// Usage: set `phy_addr`, `reg_addr`, `rd_wrn` (and `wr_data` for a write), pulse `start` for one
// clock while `busy` is low, then wait for `done` (a one-clock pulse). A read result is in
// `rd_data` from then on. A transaction takes about 64 MDC periods, i.e. 51 us at 1.25 MHz.

`timescale 1ns / 1ps

module mdio_ctrl #(
    parameter MDC_DIV = 50   // mdc_clk = clk / (2*MDC_DIV); 125 MHz / 100 = 1.25 MHz (<= the
                             // clause 22 2.5 MHz ceiling with margin)
) (
    input  wire        clk,         // system clock, 125 MHz
    input  wire        rst,         // synchronous reset, active high

    input  wire        start,       // pulse: begin a transaction (ignored while busy)
    input  wire        rd_wrn,      // 1 = read, 0 = write
    input  wire [4:0]  phy_addr,    // which PHY on the bus (strapped to 1 on this board)
    input  wire [4:0]  reg_addr,    // which of its 32 registers
    input  wire [15:0] wr_data,     // value to write

    output reg  [15:0] rd_data,     // value read, valid after `done` of a read
    output reg          busy,       // a transaction is running
    output reg          done,        // one-cycle pulse when a transaction completes
    output reg          no_response, // read only: the PHY never drove TA low (open bus, no ACK)

    output wire        mdc,         // management clock to the PHY
    output wire        mdio_out,    // data to drive, valid while mdio_oe is 1
    output wire        mdio_oe,     // 1: this master drives `mdio_out`; 0: release (PHY drives)
    input  wire        mdio_in      // data from the pin
);

    // ---- MDC generator: toggles every MDC_DIV input clocks. It runs freely, and the gating below
    // only decides whether the shift state machine advances on a given MDC edge, so the clock the
    // PHY sees stays regular even between transactions. ----
    reg [15:0] div_cnt = 16'd0;
    reg        mdc_r   = 1'b0;
    wire       mdc_fall = mdc_r && (div_cnt == MDC_DIV[15:0] - 16'd1);
    wire       mdc_rise = !mdc_r && (div_cnt == MDC_DIV[15:0] - 16'd1);

    always @(posedge clk) begin
        if (rst) begin
            div_cnt <= 16'd0;
            mdc_r   <= 1'b0;
        end else if (div_cnt == MDC_DIV[15:0] - 16'd1) begin
            div_cnt <= 16'd0;
            mdc_r   <= ~mdc_r;
        end else begin
            div_cnt <= div_cnt + 16'd1;
        end
    end

    assign mdc = mdc_r;

    // ---- Frame shift register: 32 preamble '1's, then ST/OP/PHYAD/REGAD/TA/DATA (32 bits),
    // driven MSB first, sampled on MDC's rising edge (by the PHY) and changed on MDC's falling edge
    // (by this side), which is the standard clause 22 timing: the data is stable well before the
    // PHY's own sample point on the rising edge.
    localparam ST_IDLE = 2'd0, ST_PREAMBLE = 2'd1, ST_FRAME = 2'd2, ST_DONE = 2'd3;
    reg [1:0]  state     = ST_IDLE;
    reg [5:0]  bit_cnt    = 6'd0;    // counts down within PREAMBLE (32) or FRAME (32)
    reg [31:0] shift_out = 32'd0;    // the frame being sent, next bit on top
    reg [15:0] shift_in  = 16'd0;    // the data bits being received
    reg        cur_rd_wrn = 1'b1;    // the running transaction is a read

    wire [31:0] frame_write = {2'b01, 2'b01, phy_addr, reg_addr, 2'b10, wr_data};
    wire [31:0] frame_read  = {2'b01, 2'b10, phy_addr, reg_addr, 2'b00, 16'h0000}; // TA/DATA bits
                                                                                    // unused while
                                                                                    // driving (see
                                                                                    // mdio_oe below)

    // Drive MDIO only during the preamble, ST, OP, PHYAD and REGAD, and (for a write only) TA and
    // DATA. For a read, release starting at the 2-bit TA field so that the PHY can drive it (its
    // second bit, 0, is the turnaround acknowledgement) and the 16 data bits that follow.
    // `bit_cnt` counts down from 32 (about to send frame bit 0, the first ST bit) to 1 (about to
    // send frame bit 31, the last data bit), and the 14 address-phase bits (ST 2, OP 2, PHYAD 5,
    // REGAD 5) are bit_cnt 32 to 19.
    wire in_preamble    = (state == ST_PREAMBLE);
    wire in_frame       = (state == ST_FRAME);
    wire addr_phase     = (bit_cnt >= 6'd19);   // ST/OP/PHYAD/REGAD: bit_cnt 32 downto 19 (14 bits)
    assign mdio_oe  = in_preamble || (in_frame && (cur_rd_wrn ? addr_phase : 1'b1));
    assign mdio_out = in_preamble ? 1'b1 : shift_out[31];

    always @(posedge clk) begin
        done         <= 1'b0;
        if (rst) begin
            state       <= ST_IDLE;
            busy        <= 1'b0;
            no_response <= 1'b0;
        end else begin
            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy       <= 1'b1;
                        cur_rd_wrn <= rd_wrn;
                        shift_out  <= rd_wrn ? frame_read : frame_write;
                        bit_cnt    <= 6'd32;
                        state      <= ST_PREAMBLE;
                    end
                end

                ST_PREAMBLE: begin
                    if (mdc_fall) begin
                        if (bit_cnt == 6'd1) begin
                            bit_cnt <= 6'd32;
                            state   <= ST_FRAME;
                        end else begin
                            bit_cnt <= bit_cnt - 6'd1;
                        end
                    end
                end

                ST_FRAME: begin
                    // Shift the outgoing register on the falling edge (which changes MDIO_OUT
                    // while this side still drives it), and capture MDIO_IN on the rising edge,
                    // once the PHY has had a falling-to-rising half period to present its own bit
                    // (the turnaround and every read data bit).
                    if (mdc_fall) begin
                        shift_out <= {shift_out[30:0], 1'b0};
                        if (bit_cnt == 6'd1) begin
                            state <= ST_DONE;
                        end else begin
                            bit_cnt <= bit_cnt - 6'd1;
                        end
                    end
                    if (mdc_rise && cur_rd_wrn) begin
                        // Bit 14 of the frame is the turnaround (a PHY-driven '0' is expected),
                        // then bits 15 to 30 are the 16 data bits. bit_cnt counts down from 32, so
                        // TA is sampled when bit_cnt is 18, data bit 0 (the MSB) when it is 17,
                        // down to bit_cnt 2 for the LSB.
                        if (bit_cnt == 6'd18 && mdio_in) no_response <= 1'b1;
                        if (bit_cnt <= 6'd17 && bit_cnt >= 6'd2)
                            shift_in <= {shift_in[14:0], mdio_in};
                    end
                end

                ST_DONE: begin
                    if (cur_rd_wrn) rd_data <= shift_in;
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase

            if (start && state == ST_IDLE) no_response <= 1'b0;
        end
    end

endmodule
