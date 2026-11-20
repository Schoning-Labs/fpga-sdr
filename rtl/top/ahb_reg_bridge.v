// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// ahb_reg_bridge: carries the CPU's register reads and writes from the AE350's bus into the clock domain that owns
// the addressed register page.
//
// WHERE IT SITS
// The AE350 hard RISC-V subsystem is the AHB master and sees the whole fabric as one 128 MB window (0xE800_0000 to
// 0xEFFF_FFFF, "Extended AHB Slave" port, MUG1031 table 5-1 signals EXTS_*). AHB is a simple ARM bus in which a master
// first sends an address phase and then, one clock later, the data phase, and the slave stretches the data phase by
// keeping HREADYOUT low until it has the answer. This module is the one slave on that port. Behind it, one
// regbus_cdc_dst per clock domain (rtl/top/regbus_cdc_dst.v) turns the request into a one-clock read or write strobe
// in that domain, and in sdr_core.v a regbus_leg per page hands the strobe to the register block. All the
// register blocks of the radio are reached this way (docs/ARCHITECTURE.md 4.1); bulk data goes through DDR3 and never
// through this port.
//
// WHAT IT DOES, STEP BY STEP
// One access at a time and only 32 bits wide: a byte or half-word write is carried out as a full-word write of HWDATA,
// because every fabric register is a 32-bit word (docs/REGMAP.md). The page is HADDR[23:16], one 64 KB page per block,
// and the far side gets HADDR[23:0]. The access goes to one of four channels, each one a clock domain:
//   channel 0: clk_dsp (120 MHz), every page except the two below
//   channel 1: n1_rxc (125 MHz, the recovered clock of transceiver lane 0), page RX_PAGE (0x02) below offset 0x8000,
//              the HL2 link's CPU receive ring
//   channel 2: sfp_txc (125 MHz, lane 0's transmit clock), page RX_PAGE from offset 0x8000, the HL2 link's CPU
//              transmit queue
//   channel 3: clk_eth (100 MHz), the page NET_PAGE, the network unit on the RJ45 socket (rtl/net/net_unit.v)
//
// WHY A HANDSHAKE AND NOT A SHARED CLOCK
// The AE350's AHB clock (80 MHz) is asynchronous to every fabric clock, so a signal cannot simply be sampled by the
// other side. The request is instead a toggle: the bridge flips req_tog, holds the address and data still, waits until
// the far side flips ack_tog to match, and only then reads the answer, which the far side has also held still. A
// level that changes once per request is safe to pass through a chain of flip-flops (a synchronizer) however the two
// clocks relate, which is why ack_tog goes through three registers here and req_tog through three at the far side.
// An access costs about 12 to 20 AHB clocks this way, which does not matter for control registers.
//
// TIMEOUT
// Two of the channels only have a clock while something outside the chip is running: n1_rxc comes from the SFP
// receiver and does not exist without a link. An access whose domain gives no answer within TIMEOUT AHB clocks
// completes with the read data 0xDEAD_BEEF and pulses timeout_pulse (it ends up in system.status.bus_timeout). The
// channel is then marked dead: later accesses to it return 0xDEAD_BEEF at once, until its acknowledge toggle has
// caught up with the request toggle (the late answer finally arrived), which makes the channel usable again. Without
// the dead flag the late acknowledge would complete the next request with stale data.
//
// HRESP is always OKAY. Errors are reported through the data value and the status bit, so a missing clock can never
// raise a bus exception in the firmware.

`timescale 1ns / 1ps

// TIMEOUT: AHB clocks to wait for an answer (4,096 clocks of 12.5 ns = 51 us). RX_PAGE: the page with the two HL2
// link rings. NET_PAGE: the page of the network unit (sdr_core.v passes the one from the generated register map).
module ahb_reg_bridge #(
    parameter integer TIMEOUT = 4096,
    parameter [7:0]   RX_PAGE = 8'h02,
    parameter [7:0]   NET_PAGE = 8'h11
) (
    input  wire        hclk,
    input  wire        hresetn,
    // AHB-lite slave signals (the AE350's EXTS_* outputs; the AE350 is the master)
    input  wire        hsel,
    input  wire [31:0] haddr,
    input  wire [1:0]  htrans,
    input  wire        hwrite,
    input  wire [2:0]  hsize,
    input  wire [31:0] hwdata,
    output reg         hreadyout,
    output reg  [31:0] hrdata,
    output wire        hresp,
    // The request, held stable from the request toggle until the acknowledge. All four channels share it.
    output reg  [23:0] req_addr,
    output reg         req_wr,
    output reg  [31:0] req_wdata,
    // channel 0, clk_dsp: req_tog flips once per request; ack_tog comes back from the far side, asynchronous to hclk;
    // rdata is stable once ack_tog has toggled
    output reg         req_tog0,
    input  wire        ack_tog0,     // from the far side, asynchronous
    input  wire [31:0] rdata0,       // stable once ack_tog0 has toggled
    // channel 1, n1_rxc (the HL2 link receive ring)
    output reg         req_tog1,
    input  wire        ack_tog1,
    input  wire [31:0] rdata1,
    // channel 2, sfp_txc (the HL2 link transmit queue)
    output reg         req_tog2,
    input  wire        ack_tog2,
    input  wire [31:0] rdata2,
    // channel 3, clk_eth (the network unit)
    output reg         req_tog3,
    input  wire        ack_tog3,
    input  wire [31:0] rdata3,
    // status, in the hclk domain: timeout_pulse is high for one hclk clock when an access timed out; rx_dead is high
    // while channel 1 is marked dead, which firmware reads as "the HL2 link has no receive clock"
    output reg         timeout_pulse,
    output wire        rx_dead
) /* synthesis syn_srlstyle = "registers" */;

    // The bus never signals an error response.
    assign hresp = 1'b0;

    // The four acknowledge toggles come in from other clock domains, so each goes through a 3-flop synchronizer.
    // (* preserve *) keeps the tool from merging or trimming the chain.
    (* preserve *) reg [2:0] ack0_s = 3'b000;
    (* preserve *) reg [2:0] ack1_s = 3'b000;
    (* preserve *) reg [2:0] ack2_s = 3'b000;
    (* preserve *) reg [2:0] ack3_s = 3'b000;
    always @(posedge hclk) begin
        ack3_s <= {ack3_s[1:0], ack_tog3};
        ack0_s <= {ack0_s[1:0], ack_tog0};
        ack1_s <= {ack1_s[1:0], ack_tog1};
        ack2_s <= {ack2_s[1:0], ack_tog2};
    end
    // ack* = the synchronized acknowledge toggle of each channel.
    wire ack0 = ack0_s[2];
    wire ack1 = ack1_s[2];
    wire ack2 = ack2_s[2];
    wire ack3 = ack3_s[2];

    // dead* = the channel has timed out and its answer has not come back yet.
    reg dead0 = 1'b0, dead1 = 1'b0, dead2 = 1'b0, dead3 = 1'b0;
    assign rx_dead = dead1;

    // The state machine: IDLE waits for an address phase, DATA is the first data-phase clock (HWDATA is valid now),
    // WAIT holds HREADYOUT low until the far side has acknowledged or the timeout runs out.
    localparam S_IDLE = 2'd0, S_DATA = 2'd1, S_WAIT = 2'd2;
    // ch = channel of the access in flight (2 bits, 0 to 3), pend_wr / pend_addr = the address phase captured in IDLE,
    // tmo = counts hclk clocks while waiting for an acknowledge.
    reg [1:0]  state = S_IDLE;
    reg [1:0]  ch = 2'd0;
    reg        pend_wr = 1'b0;
    reg [23:0] pend_addr = 24'd0;
    reg [$clog2(TIMEOUT+1)-1:0] tmo = 0;

    // An address phase starts when the AE350 selects this slave, the transfer type is NONSEQ or SEQ (htrans[1]) and
    // the bridge is ready for a new one.
    wire start = hsel && htrans[1] && hreadyout;

    always @(posedge hclk) begin
        timeout_pulse <= 1'b0;
        if (!hresetn) begin
            state     <= S_IDLE;
            hreadyout <= 1'b1;
            hrdata    <= 32'd0;
            req_tog0  <= ack0;
            req_tog1  <= ack1;
            req_tog2  <= ack2;
            req_tog3  <= ack3;
            dead3     <= 1'b0;
            dead0     <= 1'b0;
            dead1     <= 1'b0;
            dead2     <= 1'b0;
        end else begin
            // a dead channel comes back once its late acknowledge has arrived (ack equals req again)
            if (dead0 && (ack0 == req_tog0)) dead0 <= 1'b0;
            if (dead1 && (ack1 == req_tog1)) dead1 <= 1'b0;
            if (dead2 && (ack2 == req_tog2)) dead2 <= 1'b0;
            if (dead3 && (ack3 == req_tog3)) dead3 <= 1'b0;

            case (state)
            S_IDLE: begin
                if (start) begin
                    // address phase: capture, then hold HREADY low through the data phase. The channel is picked
                    // from the page: the network page goes to channel 3, any page other than RX_PAGE to channel 0,
                    // and RX_PAGE goes to channel 2 when address bit 15 is set (upper half) or to channel 1 when not.
                    pend_addr <= haddr[23:0];
                    pend_wr   <= hwrite;
                    ch        <= (haddr[23:16] == NET_PAGE) ? 2'd3 :
                                 (haddr[23:16] != RX_PAGE) ? 2'd0 : (haddr[15] ? 2'd2 : 2'd1);
                    hreadyout <= 1'b0;
                    state     <= S_DATA;
                end
            end
            S_DATA: begin
                    // first data-phase clock: HWDATA is valid now, so the request is complete and can be published
                req_addr  <= pend_addr;
                req_wr    <= pend_wr;
                req_wdata <= hwdata;
                tmo       <= 0;
                    // a dead channel answers at once with the marker value, without a request
                if ((ch == 2'd0 && dead0) || (ch == 2'd1 && dead1) || (ch == 2'd2 && dead2) || (ch == 2'd3 && dead3)) begin
                    hrdata    <= 32'hDEAD_BEEF;
                    hreadyout <= 1'b1;
                    state     <= S_IDLE;
                end else begin
                    if (ch == 2'd0)      req_tog0 <= ~req_tog0;
                    else if (ch == 2'd1) req_tog1 <= ~req_tog1;
                    else if (ch == 2'd2) req_tog2 <= ~req_tog2;
                    else                 req_tog3 <= ~req_tog3;
                    state <= S_WAIT;
                end
            end
                // the answer has arrived when the far side's acknowledge toggle equals the request toggle
            S_WAIT: begin
                tmo <= tmo + 1'b1;
                if (ch == 2'd0 && ack0 == req_tog0) begin
                    hrdata    <= rdata0;
                    hreadyout <= 1'b1;
                    state     <= S_IDLE;
                end else if (ch == 2'd1 && ack1 == req_tog1) begin
                    hrdata    <= rdata1;
                    hreadyout <= 1'b1;
                    state     <= S_IDLE;
                end else if (ch == 2'd2 && ack2 == req_tog2) begin
                    hrdata    <= rdata2;
                    hreadyout <= 1'b1;
                    state     <= S_IDLE;
                end else if (ch == 2'd3 && ack3 == req_tog3) begin
                    hrdata    <= rdata3;
                    hreadyout <= 1'b1;
                    state     <= S_IDLE;
                end else if (tmo == TIMEOUT[$clog2(TIMEOUT+1)-1:0]) begin
                    hrdata        <= 32'hDEAD_BEEF;
                    hreadyout     <= 1'b1;
                    timeout_pulse <= 1'b1;
                    if (ch == 2'd0)      dead0 <= 1'b1;
                    else if (ch == 2'd1) dead1 <= 1'b1;
                    else if (ch == 2'd2) dead2 <= 1'b1;
                    else                 dead3 <= 1'b1;
                    state <= S_IDLE;
                end
            end
            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
