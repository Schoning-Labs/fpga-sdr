// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// ladder_regs: the register page of the bring-up ladder (rtl/top/ladder_top.v, docs/LADDER.md), the small page that lets
// the test program on the AE350 CPU check that the CPU can talk to the FPGA fabric at all.
//
// WHERE IT SITS
// The CPU reaches the fabric through the AE350's Extended AHB Slave port, a window of 128 MB at 0xE800_0000 on the CPU's
// address map. AHB is the bus protocol of the AE350: every transfer has an address phase (the CPU puts out the address and
// the control signals) followed by a data phase (the write data is sent, or the read data is returned). This module is the
// whole slave behind that window. Everything runs in the AHB clock (80 MHz); the counters and flags that live in other
// clock domains arrive through ladder_cnt_x or through two registers, so none of them is read mid-change.
//
// THE ACCESS PROTOCOL
// The slave has zero wait states (hreadyout stays 1) and never reports an error (hresp stays 0). Read data is prepared in the
// address phase, from haddr, and held for the data phase, so the CPU gets it without delay. A write is taken in the data
// phase that follows its address phase: the address phase only remembers that a write to this page was addressed
// and which register, and the next clock stores hwdata. Only the first 256 bytes of the window are decoded (haddr[27:8] = 0);
// any other address in the window reads 0 and ignores writes, and so does a clock without a valid transfer. Registers are
// word registers: the two lowest address bits are ignored. The protocol comes from an earlier design by the same
// author; the register map below is fpga-sdr's own.
//
// REGISTER MAP (offsets from 0xE800_0000, 32 bits each; rw = read-write, the rest read-only)
//   0x00 ID          'LADR' = 0x4C41_4452
//   0x04 STEP        the build step, 1 to 3 (see ladder_top.v)
//   0x08 BUILD       the first 8 hex digits of the commit the bitstream was built from
//   0x0C LED word    rw, bits 5:0 = the LED register; bit 5 is LED 5, which the program toggles once per report
//   0x10 STATUS      bit 0 = DDR3 initialized and calibrated, bit 1 = DSP PLL locked, bit 2 = video PLL locked,
//                    bit 3 = DDR3 PLL locked
//   0x14 SCRATCH     rw, 32 bits with no effect, to test that a written word reads back
//   0x40 ms          milliseconds of the 50 MHz oscillator, 16 bits (wraps after 65.5 s): the time base
//   0x44 PT8211      number of 48 kHz audio frames sent to the DAC, 16 bits (step 3, else 0)
//   0x48 DSP clock   clk_dsp (120 MHz) divided by 2^17, counted, 16 bits
//   0x4C pixel clock clk_pix (74.17 MHz) divided by 2^17, counted, 16 bits
//   0x50 AHB clock   the AHB clock (80 MHz) divided by 2^17, counted, 16 bits
//   0x54 DDR clock   the CPU's data-memory bus clock (50 MHz) divided by 2^17, counted, 16 bits
//   0x58 RTC clock   the real-time counter clock (10 MHz) divided by 2^12, counted, 16 bits
//   0x5C video       number of video frames sent (steps 2 and 3, else 0), 16 bits
// To measure a clock the program reads the ms counter and the clock's counter twice, some time apart, and divides the
// difference of the clock counter times 2^17 (2^12 for the RTC) by the difference in milliseconds.
`timescale 1ns / 1ps
module ladder_regs #(
    parameter integer STEP = 1
) (
    input  wire        hclk,  // AHB clock, 80 MHz
    input  wire        hresetn,  // AHB reset, active low
    input  wire        hsel,  // slave select: the transfer is addressed to this slave (the whole window)
    input  wire [31:0] haddr,  // address of the transfer, byte address inside the 128 MB window
    input  wire [1:0]  htrans,  // transfer type: bit 1 set = a real transfer (NONSEQ or SEQ), bit 1 clear = idle or busy
    input  wire        hwrite,  // 1 = write, 0 = read
    input  wire [31:0] hwdata,  // write data, valid in the data phase of a write
    output wire        hreadyout,  // always 1: this slave never inserts a wait state
    output wire        hresp,  // always 0: OKAY, no error response
    output reg  [31:0] hrdata,  // read data for the transfer that is in its address phase, held through its data phase
    input  wire [31:0] build_id,  // build identifier (first 8 hex digits of the commit)
    input  wire        ddr3_init,  // DDR3 controller initialized and calibrated (from another clock domain)
    input  wire        dsp_lock,  // DSP PLL locked (from another clock domain)
    input  wire        vid_lock,  // video PLL locked (from another clock domain)
    input  wire        ddr3_lock,  // DDR3 PLL locked (from another clock domain)
    input  wire [15:0] ms_cnt,  // milliseconds of the 50 MHz oscillator, from ladder_cnt_x
    input  wire [15:0] aud_cnt,  // PT8211 frames sent, from ladder_cnt_x
    input  wire [15:0] dsp_cnt,  // clk_dsp divided by 2^17, counted
    input  wire [15:0] pix_cnt,  // clk_pix divided by 2^17, counted
    input  wire [15:0] ahb_cnt,  // AHB clock divided by 2^17, counted
    input  wire [15:0] ddr_cnt,  // DDR bus clock divided by 2^17, counted
    input  wire [15:0] rtc_cnt,  // RTC clock divided by 2^12, counted
    input  wire [15:0] vframes,  // video frames sent
    output reg  [5:0]  led_r  // LED word to ladder_top.v, bits 5:0 (the program writes it)
) /* synthesis syn_maxfan = 10000 */;
    // no wait states and no errors
    assign hreadyout = 1'b1;
    assign hresp = 1'b0;
    // wr_p = the last address phase was a write to this slave, a_p = its register offset (word aligned), pg_p = it was inside the decoded page
    reg        wr_p = 1'b0;
    reg [7:0]  a_p = 8'd0;
    reg        pg_p = 1'b0;
    // scratch = the SCRATCH register
    reg [31:0] scratch = 32'd0;
    // status inputs seen through two registers (they come from other clock domains)
    reg [3:0] st1 = 4'd0, st2 = 4'd0;
    // st2 is the stable copy that the STATUS register shows
    always @(posedge hclk) begin st1 <= {ddr3_lock, vid_lock, dsp_lock, ddr3_init}; st2 <= st1; end
    always @(posedge hclk) begin
        if (!hresetn) begin
            wr_p <= 1'b0; a_p <= 8'd0; pg_p <= 1'b0; led_r <= 6'd0; scratch <= 32'd0;
        end else begin
            // data phase of a write that was addressed in the clock before: store hwdata into the register that was addressed
            if (wr_p && pg_p) begin
                case (a_p)
                    8'h0C: led_r   <= hwdata[5:0];
                    8'h14: scratch <= hwdata;
                    default: ;
                endcase
            end
            // address phase: remember whether it is a write to this page and which register, for the next clock
            wr_p <= hsel & htrans[1] & hwrite;
            a_p  <= haddr[7:0] & 8'hFC;
            pg_p <= (haddr[27:8] == 20'd0);
            // read data for the transfer in its address phase, held for its data phase: the register at the word address,
            // 0 for an unknown register
            case (haddr[7:0] & 8'hFC)
                8'h00: hrdata <= 32'h4C41_4452;
                8'h04: hrdata <= STEP;
                8'h08: hrdata <= build_id;
                8'h0C: hrdata <= {26'd0, led_r};
                8'h10: hrdata <= {28'd0, st2};
                8'h14: hrdata <= scratch;
                8'h40: hrdata <= {16'd0, ms_cnt};
                8'h44: hrdata <= {16'd0, aud_cnt};
                8'h48: hrdata <= {16'd0, dsp_cnt};
                8'h4C: hrdata <= {16'd0, pix_cnt};
                8'h50: hrdata <= {16'd0, ahb_cnt};
                8'h54: hrdata <= {16'd0, ddr_cnt};
                8'h58: hrdata <= {16'd0, rtc_cnt};
                8'h5C: hrdata <= {16'd0, vframes};
                default: hrdata <= 32'd0;
            endcase
            // an idle clock, or an address outside the first 256 bytes of the window, reads 0
            if (!(hsel && htrans[1]) || (haddr[27:8] != 20'd0)) hrdata <= 32'd0;
        end
    end
endmodule
