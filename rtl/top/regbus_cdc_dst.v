// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// regbus_cdc_dst: the far side of the register-bus handshake that ahb_reg_bridge.v starts.
//
// There is one instance per destination clock (clk_dsp, n1_rxc, sfp_txc and clk_eth in sdr_core.v). It runs in
// that clock and does the following. When the request toggle (req_tog) differs from the acknowledge toggle (ack_tog),
// a request is open: the module copies the address, write flag and data to its own registers and issues one access on
// the local register bus, bus_wr or bus_rd high for exactly one clock together with bus_addr and bus_wdata. It then
// waits RD_LAT clocks, which is the time the register blocks behind it need to answer, captures bus_rdata (also after
// a write, which does no harm) into rdata_hold and flips ack_tog. The bridge reads rdata_hold only after it has seen
// that toggle, and rdata_hold does not change again until the next request, so the data needs no resynchronizing.
// RD_LAT is set per instance to the read latency of the blocks on that bus (12 for clk_dsp, see sdr_core.v).
//
// The address, write flag and data are held stable by the bridge from before the request toggle until the
// acknowledge, so they can be sampled here safely as soon as the toggle has passed the three flip-flops of req_s.

`timescale 1ns / 1ps

module regbus_cdc_dst #(
    // RD_LAT: clocks between the access strobe and capturing the read data. The blocks behind this bus must have
    // their answer ready by then.
    parameter integer RD_LAT = 6
) (
    input  wire        clk,  // the destination domain's clock
    input  wire        rst,  // synchronous reset, active high, in the domain of clk
    input  wire        req_tog,       // request toggle from the bridge, asynchronous to clk
    input  wire [23:0] req_addr,      // HADDR[23:0] of the access, asynchronous, stable while a request is open
    input  wire        req_wr,  // 1 = write, 0 = read
    input  wire [31:0] req_wdata,  // write data
    // answer to the bridge
    output reg         ack_tog = 1'b0,  // acknowledge toggle: equals req_tog when idle, flips when an access is finished
    output reg  [31:0] rdata_hold = 32'd0,  // the read data of the finished access, held until the next one
    // the local register bus: bus_wr and bus_rd are one-clock strobes, bus_addr and bus_wdata stay until the next access
    output reg         bus_wr = 1'b0,
    output reg         bus_rd = 1'b0,
    output reg  [23:0] bus_addr = 24'd0,
    output reg  [31:0] bus_wdata = 32'd0,
    input  wire [31:0] bus_rdata  // read data coming back from the blocks, expected RD_LAT clocks after the strobe
) /* synthesis syn_srlstyle = "registers" */;

    // req_s: synchronizer chain for the request toggle (it arrives from another clock domain)
    (* preserve *) reg [2:0] req_s = 3'b000;
    // busy: an access is in progress, waiting for the read data. cnt counts the wait.
    reg        busy = 1'b0;
    reg [$clog2(RD_LAT+1)-1:0] cnt = 0;

    // The reset goes through a register of this block. The chip's reset net has thousands of loads, and used directly
    // as a load enable of bus_addr and bus_wdata it took 6 ns of routing; one local copy keeps the path short.
    reg rst_q = 1'b1 /* synthesis syn_preserve = 1 */;
    always @(posedge clk) rst_q <= rst;

    always @(posedge clk) begin
        // shift the request toggle in; its third stage is the one safe to compare
        req_s  <= {req_s[1:0], req_tog};
        // the strobes are one-clock pulses, so they default to 0 every clock and are set only on the clock that
        // starts an access
        bus_wr <= 1'b0;
        bus_rd <= 1'b0;
        if (rst_q) begin
            busy    <= 1'b0;
            ack_tog <= req_s[2];     // idle: acknowledge equals request
        end else if (!busy) begin
            // a request is open when the synchronized request toggle differs from the acknowledge toggle
            if (req_s[2] != ack_tog) begin
                bus_addr  <= req_addr;
                bus_wdata <= req_wdata;
                bus_wr    <= req_wr;
                bus_rd    <= !req_wr;
                busy      <= 1'b1;
                cnt       <= 0;
            end
        end else begin
            // wait for the blocks to answer, then capture the data and acknowledge
            cnt <= cnt + 1'b1;
            if (cnt == RD_LAT[$clog2(RD_LAT+1)-1:0]) begin
                rdata_hold <= bus_rdata;
                ack_tog    <= ~ack_tog;
                busy       <= 1'b0;
            end
        end
    end

endmodule
