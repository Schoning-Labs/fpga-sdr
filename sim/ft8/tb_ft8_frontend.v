// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Register and reset test of the whole FT8 front end as the chip instantiates it,
// rtl/ft8/ft8_frontend.v. That block holds the three FT8 engines (the spectrogram, the sync
// search and the candidate engine), the register page that the firmware uses to control them
// and the shares of the two DDR3 lanes. The engines' own bit-exact tests are tb_ft8_spectrogram.v,
// tb_ft8_sync.v and tb_ft8_cand.v, so this bench looks only at the glue around them: the
// register map (generated from hw/regmap/ft8.toml), the reset state, the interrupt and the
// control of the second decode pass (docs/FT8_PASS2.md).
//
// The bench drives the register bus the way rtl/top/sdr_core.v does and holds every DDR3
// request without a grant, so no engine ever moves data here. It runs four groups of checks:
//   1. After reset no output is unknown, which matters because the DDR3 arbiters further up
//      would pass an unknown value on to the memory controller.
//   2. The id and the reset values are right, every kind of register (per receiver and per lane)
//      reads back what was written, a write to one receiver does not reach another, and an
//      unmapped offset reads zero.
//   3. Writing slot_boundary restarts that receiver's slot only (its sync triggers are armed and
//      the others are not), the interrupt follows irq_status & irq_enable (the candidate
//      engine's done pulse is forced), and a status bit clears when 1 is written to it.
//   4. For the second pass the p2_* registers read back, p2_cmd sets status.p2_busy and makes the
//      replay ask DDR3 for its first window, a second p2_cmd while busy changes nothing, and the
//      end of the residual search (forced) sets irq_status.p2_done, not a receiver's sync_done,
//      and clears p2_busy. Running the whole chain on a recording is tools/check_ft8_pass2.sh.
//
// Pass criterion: no CHECK fails. The bench prints one ERROR line per failed check and finishes
// with "PASS: tb_ft8_frontend" or "FAIL: tb_ft8_frontend, <n> errors".
//
// Run from the repository root:
//   iverilog -g2012 -o build/tb_ft8_frontend.vvp sim/ft8/tb_ft8_frontend.v && vvp build/tb_ft8_frontend.vvp

`timescale 1ns / 1ps
`include "rtl/ft8/ft8_frontend.v"

// Number of receivers built, -DTB_NRX=<n> (default 8). Receivers at or above n must read 0 and ignore writes.
`ifndef TB_NRX
`define TB_NRX 8
`endif

module tb_ft8_frontend;
    localparam integer NRX = `TB_NRX;
    localparam integer PRX = (NRX > 5) ? 5 : 3;        // the receiver of the second-pass test
    // Expected register value: x for a receiver that is built, 0 for one beyond NRX.
    `define EXPV(r, x) (((r) < NRX) ? (x) : 32'd0)
    reg clk = 1'b0;
    always #3.333 clk = ~clk;
    reg rst = 1'b1;

    reg         bus_wr = 1'b0, bus_rd = 1'b0;
    reg  [15:0] bus_addr = 16'd0;
    reg  [31:0] bus_wdata = 32'd0;
    wire [31:0] bus_rdata;
    wire        wr_req, rd_req, irq;
    wire [31:0] wr_addr, rd_addr;
    wire [7:0]  wr_burstlen, wr_wmask, rd_burstlen;
    wire [63:0] wr_wdata;

    ft8_frontend #(.NRX(NRX)) dut (
        .clk(clk), .rst(rst),
        .audio_valid(1'b0), .audio_rx(3'd0), .audio_sample(16'd0), .audio_iq(1'b0),
        .bus_wr(bus_wr), .bus_rd(bus_rd), .bus_addr(bus_addr), .bus_wdata(bus_wdata),
        .bus_rdata(bus_rdata),
        .wr_req(wr_req), .wr_addr(wr_addr), .wr_burstlen(wr_burstlen), .wr_wdata(wr_wdata),
        .wr_wmask(wr_wmask), .wr_gnt(1'b0), .wr_done(1'b0),
        .rd_req(rd_req), .rd_addr(rd_addr), .rd_burstlen(rd_burstlen), .rd_gnt(1'b0),
        .rd_rvalid(1'b0), .rd_rdata(64'd0), .rd_done(1'b0),
        .irq(irq)
    );

    // Error counter, and a CHECK macro that counts a failure and prints its message. Comparing
    // with !== 1 makes an unknown (x) result fail as well.
    integer errors = 0;
    `define CHECK(cond, msg) if ((cond) !== 1'b1) begin errors = errors + 1; $display("ERROR t=%0t: %s", $time, msg); end

    // The bus as rtl/top/sdr_core.v drives it: address and data held, one clock strobes,
    // then four idle clocks (writes act two clocks after the strobe, read data is valid four
    // clocks after it).
    task wr(input [31:0] a, input [31:0] d);
        begin
            @(posedge clk); bus_addr <= a[15:0]; bus_wdata <= d; bus_wr <= 1'b1;
            @(posedge clk); bus_wr <= 1'b0;
            repeat (4) @(posedge clk);
        end
    endtask
    task rd(input [31:0] a, output [31:0] d);
        begin
            @(posedge clk); bus_addr <= a[15:0]; bus_rd <= 1'b1;
            @(posedge clk); bus_rd <= 1'b0;
            repeat (4) @(posedge clk);
            #1 d = bus_rdata;
        end
    endtask

    // v receives read data, r is the receiver or lane number of the loops below.
    reg [31:0] v;
    integer r;
    initial begin
        // Reset for 20 clocks, then 40 clocks of settling.
        repeat (20) @(posedge clk);
        rst <= 1'b0;
        repeat (40) @(posedge clk);
        // Group 1: outputs after reset.
        `CHECK(wr_req === 1'b0, $sformatf("wr_req %b after reset", wr_req))
        `CHECK(rd_req === 1'b0, $sformatf("rd_req %b after reset", rd_req))
        `CHECK(irq === 1'b0, $sformatf("irq %b after reset", irq))
        // Group 2: id, reset values, then write and read back with a distinct value per receiver
        // (the receiver number is added to each value, so that a write that lands on the wrong
        // receiver shows up).
        rd(`FT8_ID_ADDR, v);
        `CHECK(v == `FT8_ID_RESET, $sformatf("id %08x", v))
        rd(`FT8_STATUS_ADDR, v);
        `CHECK(v == 32'd0, $sformatf("status %08x", v))
        for (r = 0; r < 8; r = r + 1) begin
            rd(`FT8_CTRL_ADDR(r), v);
            `CHECK(v == `EXPV(r, `FT8_CTRL_RESET), $sformatf("ctrl(%0d) reset %08x", r, v))
            rd(`FT8_BAND_ADDR(r), v);
            `CHECK(v == `EXPV(r, `FT8_BAND_RESET), $sformatf("band(%0d) reset %08x", r, v))
            rd(`FT8_FRAME_PTR_ADDR(r), v);
            `CHECK(v == 32'd0, $sformatf("frame_ptr(%0d) %08x", r, v))
            rd(`FT8_CAP_WR_PTR_ADDR(r), v);
            `CHECK(v == 32'd0, $sformatf("cap_wr_ptr(%0d) %08x", r, v))
        end
        for (r = 0; r < 8; r = r + 1) begin
            wr(`FT8_CAP_BASE_ADDR(r),  32'h0100_0000 + r);
            wr(`FT8_SPEC_BASE_ADDR(r), 32'h0200_0000 + r);
            wr(`FT8_REC_BASE_ADDR(r),  32'h0300_0000 + r);
            wr(`FT8_BAND_ADDR(r), ((32'd900 + r) << `FT8_BAND_IB_LSB) | (32'd40 + r));
            wr(`FT8_TRIG_ADDR(r), ((32'd337 + r) << `FT8_TRIG_TRIG2_LSB) | (32'd295 + r));
            wr(`FT8_CTRL_ADDR(r), ((32'd10 + r) << `FT8_CTRL_PWR_SHIFT_LSB));
        end
        for (r = 0; r < 2; r = r + 1) begin
            wr(`FT8_CAND_INC_ADDR(r),      32'hC0DE_0000 + r);
            wr(`FT8_CAND_I0_ADDR(r),       32'h0000_FF00 + r);
            wr(`FT8_CAND_BB_BASE_ADDR(r),  32'h0400_0000 + r);
            wr(`FT8_CAND_SYM_BASE_ADDR(r), 32'h0500_0000 + r);
        end
        wr(`FT8_CAND_CAP_BASE_ADDR, 32'h0600_0000);
        wr(`FT8_CAND_FIRST_SAMPLE_ADDR, 32'h0000_1234);
        for (r = 0; r < 8; r = r + 1) begin
            rd(`FT8_CAP_BASE_ADDR(r), v);  `CHECK(v == `EXPV(r, 32'h0100_0000 + r), $sformatf("cap_base(%0d) %08x", r, v))
            rd(`FT8_SPEC_BASE_ADDR(r), v); `CHECK(v == `EXPV(r, 32'h0200_0000 + r), $sformatf("spec_base(%0d) %08x", r, v))
            rd(`FT8_REC_BASE_ADDR(r), v);  `CHECK(v == `EXPV(r, 32'h0300_0000 + r), $sformatf("rec_base(%0d) %08x", r, v))
            rd(`FT8_BAND_ADDR(r), v);
            `CHECK(v == `EXPV(r, (((32'd900 + r) << 16) | (32'd40 + r))), $sformatf("band(%0d) %08x", r, v))
            rd(`FT8_TRIG_ADDR(r), v);
            `CHECK(v == `EXPV(r, (((32'd337 + r) << 16) | (32'd295 + r))), $sformatf("trig(%0d) %08x", r, v))
            rd(`FT8_CTRL_ADDR(r), v);
            `CHECK(v == `EXPV(r, ((32'd10 + r) << 8)), $sformatf("ctrl(%0d) %08x", r, v))
        end
        for (r = 0; r < 2; r = r + 1) begin
            rd(`FT8_CAND_INC_ADDR(r), v);      `CHECK(v == 32'hC0DE_0000 + r, $sformatf("cand_inc(%0d) %08x", r, v))
            rd(`FT8_CAND_I0_ADDR(r), v);       `CHECK(v == 32'h0000_FF00 + r, $sformatf("cand_i0(%0d) %08x", r, v))
            rd(`FT8_CAND_BB_BASE_ADDR(r), v);  `CHECK(v == 32'h0400_0000 + r, $sformatf("cand_bb_base(%0d) %08x", r, v))
            rd(`FT8_CAND_SYM_BASE_ADDR(r), v); `CHECK(v == 32'h0500_0000 + r, $sformatf("cand_sym_base(%0d) %08x", r, v))
        end
        rd(`FT8_CAND_CAP_BASE_ADDR, v);     `CHECK(v == 32'h0600_0000, $sformatf("cand_cap_base %08x", v))
        rd(`FT8_CAND_FIRST_SAMPLE_ADDR, v); `CHECK(v == 32'h0000_1234, $sformatf("cand_first_sample %08x", v))
        rd(16'h0F00, v);                    `CHECK(v == 32'd0, $sformatf("unmapped offset reads %08x", v))
        // Group 3: slot boundary and interrupt.
        wr(`FT8_SLOT_BOUNDARY_ADDR(3), 32'h0000_4000);
        rd(`FT8_SLOT_BOUNDARY_ADDR(3), v);  `CHECK(v == 32'h0000_4000, $sformatf("slot_boundary(3) %08x", v))
        `CHECK(dut.u_sync.armed[3*3 +: 3] === 3'b111, "receiver 3's sync triggers not armed by slot_boundary")
        `CHECK(dut.u_sync.armed[2*3 +: 3] === 3'b000, "receiver 2's sync triggers armed by receiver 3's slot_boundary")
        wr(`FT8_IRQ_ENABLE_ADDR, 32'h0000_0100);
        rd(`FT8_IRQ_STATUS_ADDR, v);        `CHECK(v == 32'd0, $sformatf("irq_status %08x", v))
        `CHECK(irq === 1'b0, "irq without an event")
        // The candidate engine's done pulse, forced (the engine's own test covers the real one).
        @(posedge clk); force dut.cand_irq = 1'b1;
        @(posedge clk); release dut.cand_irq;
        repeat (4) @(posedge clk);
        rd(`FT8_IRQ_STATUS_ADDR, v);        `CHECK(v == 32'h0000_0100, $sformatf("irq_status after the event %08x", v))
        `CHECK(irq === 1'b1, "irq not raised")
        wr(`FT8_IRQ_STATUS_ADDR, 32'h0000_0100);
        rd(`FT8_IRQ_STATUS_ADDR, v);        `CHECK(v == 32'd0, $sformatf("irq_status after clear %08x", v))
        `CHECK(irq === 1'b0, "irq not lowered")
        `CHECK(wr_req === 1'b0 && rd_req === 1'b0, "a DDR3 request without work")
        // Group 4: second pass.
        wr(`FT8_P2_BASE_ADDR, 32'h0708_1234);     // the low 19 bits are not stored
        rd(`FT8_P2_BASE_ADDR, v);       `CHECK(v == 32'h0708_0000, $sformatf("p2_base %08x", v))
        `CHECK(dut.p2_spec === 27'h709_0000 && dut.p2_rec === 27'h70C_0000, "the spectrogram and record parts of the area")
        rd(`FT8_P2_FRAME_ADDR, v);      `CHECK(v == 32'd0, $sformatf("p2_frame %08x", v))
        wr(`FT8_IRQ_ENABLE_ADDR, 32'h0000_0400);
        wr(`FT8_P2_CMD_ADDR, PRX);
        rd(`FT8_P2_CMD_ADDR, v);        `CHECK(v == PRX, $sformatf("p2_cmd %08x", v))
        rd(`FT8_STATUS_ADDR, v);
        `CHECK(v[`FT8_STATUS_P2_BUSY_LSB] === 1'b1, $sformatf("status after p2_cmd %08x", v))
        repeat (40) @(posedge clk);
        `CHECK(rd_req === 1'b1, "the replay did not ask for its first window")
        `CHECK(rd_addr === 32'h0708_0000, $sformatf("the replay reads %08x", rd_addr))
        `CHECK(dut.u_spec.pw_sh === 5'd10 + PRX, $sformatf("the replay's power shift %0d, receiver %0d has %0d", dut.u_spec.pw_sh, PRX, 10 + PRX))
        wr(`FT8_P2_CMD_ADDR, 32'd2);    // ignored while busy
        rd(`FT8_P2_CMD_ADDR, v);        `CHECK(v == PRX, $sformatf("p2_cmd changed while busy: %08x", v))
        // The end of the residual's search, forced (tb_ft8_sync.v covers the real one).
        @(posedge clk); force dut.sync_irq = 1'b1; force dut.sync_irq_alt = 1'b1; force dut.sync_irq_rx = PRX;
        @(posedge clk); release dut.sync_irq; release dut.sync_irq_alt; release dut.sync_irq_rx;
        repeat (4) @(posedge clk);
        rd(`FT8_IRQ_STATUS_ADDR, v);    `CHECK(v == 32'h0000_0400, $sformatf("irq_status after the residual search %08x", v))
        `CHECK(irq === 1'b1, "irq not raised by p2_done")
        rd(`FT8_STATUS_ADDR, v);
        `CHECK(v[`FT8_STATUS_P2_BUSY_LSB] === 1'b0, $sformatf("p2_busy after p2_done: status %08x", v))
        wr(`FT8_IRQ_STATUS_ADDR, 32'h0000_0400);
        rd(`FT8_IRQ_STATUS_ADDR, v);    `CHECK(v == 32'd0, $sformatf("irq_status after clear %08x", v))

        if (errors == 0) $display("PASS: tb_ft8_frontend");
        else $display("FAIL: tb_ft8_frontend, %0d errors", errors);
        $finish;
    end
endmodule
