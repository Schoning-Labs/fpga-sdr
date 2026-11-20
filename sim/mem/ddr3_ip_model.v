// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Behavioral stand-in for Gowin's DDR3 Memory Interface IP, for the benches only. The model comes from an
// earlier design by the same author and is used here unchanged. Its module name and
// ports are those of the IP, so the memory wrapper rtl/mem/ddr_mem.v instantiates it exactly as it instantiates
// the real thing (docs/MEM_1GB.md). The user interface follows Gowin's IPUG281 (sections 4.4.5 to 4.4.8) with
// a 1:4 clock ratio between the memory clock and the user clock, bursts of 8, and 32 data lines, which makes
// 256-bit data, a 32-bit byte mask and a 29-bit address.
//
// What it models: commands taken on clocks with cmd_en and cmd_ready; write data taken on clocks with
// wr_data_en and wr_data_rdy (the model counts an error if a write command and its data do not arrive in the
// same clock, because the bridge in front of it is written for that case only); a mask bit of 1 meaning the
// byte is not written; read data returned in the order of the read commands after LAT clocks; ready signals
// that drop at random; and a start-up time before init_calib_complete. The memory is MEM_LINES lines of 32 bytes,
// and the line number is taken modulo MEM_LINES, so a bench has to keep its addresses apart. It does not
// model the DDR3 pins, the calibration or the refresh. The counter errors collects every protocol violation
// (bad address, write without data, data without a command, unknown command) and the benches require it to
// stay 0.
`timescale 1ns / 1ps

// The module has the name that Gowin's generated IP has.
module DDR3_Memory_Interface_Top #(
`ifdef DDR_512MB
    parameter integer MEM_LINES = 8192,     // the same 131,072 bytes in lines of 16 (-DDDR_512MB)
`else
    parameter integer MEM_LINES = 4096,
`endif
    parameter integer LAT = 9,
    parameter integer STALL = 1             // 1: cmd_ready and wr_data_rdy drop at random
`ifdef DDR_512MB
    , parameter integer DQW = 16            // 16 data lines (-DDDR_512MB): 128-bit data, 16-bit mask, lines of 16 bytes
`else
    , parameter integer DQW = 32
`endif
) (
    input  wire         clk,
    output wire         pll_stop,
    input  wire         memory_clk,
    input  wire         pll_lock,
    input  wire         rst_n,
    output reg          clk_out = 1'b0,
    output wire         ddr_rst,
    output reg          init_calib_complete = 1'b0,
    output reg          cmd_ready = 1'b0,
    input  wire [2:0]   cmd,
    input  wire         cmd_en,
    input  wire [28:0]  addr,
    output reg          wr_data_rdy = 1'b0,
    input  wire [8*DQW-1:0] wr_data,
    input  wire         wr_data_en,
    input  wire         wr_data_end,
    input  wire [DQW-1:0]  wr_data_mask,
    output reg  [8*DQW-1:0] rd_data,
    output reg          rd_data_valid = 1'b0,
    output reg          rd_data_end = 1'b0,
    input  wire         sr_req,
    input  wire         ref_req,
    output wire         sr_ack,
    output wire         ref_ack,
    input  wire         burst,
    output wire [14:0]  O_ddr_addr,
    output wire [2:0]   O_ddr_ba,
    output wire         O_ddr_cs_n,
    output wire         O_ddr_ras_n,
    output wire         O_ddr_cas_n,
    output wire         O_ddr_we_n,
    output wire         O_ddr_clk,
    output wire         O_ddr_clk_n,
    output wire         O_ddr_cke,
    output wire         O_ddr_odt,
    output wire         O_ddr_reset_n,
    output wire [DQW/8-1:0] O_ddr_dqm,
    inout  wire [DQW-1:0]  IO_ddr_dq,
    inout  wire [DQW/8-1:0] IO_ddr_dqs,
    inout  wire [DQW/8-1:0] IO_ddr_dqs_n
);
    // The pins of the DDR3 devices are not modeled and keep fixed idle values, and there is no self-refresh or
    // refresh acknowledge.
    assign pll_stop = 1'b1;
    assign {sr_ack, ref_ack} = 2'b00;
    assign O_ddr_addr = 15'd0; assign O_ddr_ba = 3'd0; assign O_ddr_dqm = 0;
    assign {O_ddr_cs_n, O_ddr_ras_n, O_ddr_cas_n, O_ddr_we_n, O_ddr_clk, O_ddr_clk_n, O_ddr_cke, O_ddr_odt,
            O_ddr_reset_n} = 9'b011110101;
    // clk_out is the user clock, the memory clock divided by 4 (it toggles on every second memory clock).
    reg [1:0] dv = 2'd0;
    always @(posedge memory_clk) begin dv <= dv + 2'd1; if (dv[0]) clk_out <= ~clk_out; end
    assign ddr_rst = !(rst_n && pll_lock);

    // mem is the memory array; q_d and q_t are the queue of pending reads, the data and the time (in clk_out
    // clocks) at which each result is released, LAT clocks after its command.
    reg [8*DQW-1:0] mem [0:MEM_LINES-1];
    reg [8*DQW-1:0] q_d [0:63];
    reg [31:0]  q_t [0:63];
    integer     q_w = 0, q_r = 0, now = 0, up = 0, i, errors = 0, n_wr = 0, n_rd = 0;
    reg [31:0]  seed = 32'h1234_5678;
    reg [8*DQW-1:0] w;
    // Start content of every line is the line number in the low half of 0xDEAD0000, repeated across the line, so
    // a bench can tell a word that was never written.
    initial for (i = 0; i < MEM_LINES; i = i + 1) mem[i] = {(DQW / 4){32'hDEAD_0000 + i[15:0]}};
    // Everything happens on the user clock.
    always @(posedge clk_out) begin
        now <= now + 1;
        rd_data_valid <= 1'b0; rd_data_end <= 1'b0;
    // In reset the model is not ready; after reset it needs 40 clocks of start-up before it reports that the
    // calibration is complete.
        if (ddr_rst) begin up <= 0; init_calib_complete <= 1'b0; cmd_ready <= 1'b0; wr_data_rdy <= 1'b0; end
        else begin
            up <= up + 1;
            if (up == 40) init_calib_complete <= 1'b1;
    // A linear congruential generator (multiplier 1664525, increment 1013904223) decides on each clock whether
    // cmd_ready and wr_data_rdy are high: each is low on one clock in four, at random.
            seed = seed * 32'd1664525 + 32'd1013904223;
            cmd_ready   <= init_calib_complete && (STALL == 0 || seed[20:19] != 2'd0);
            wr_data_rdy <= init_calib_complete && (STALL == 0 || seed[25:24] != 2'd0);
        end
        // A command is accepted when cmd_en and cmd_ready are both high. The address must be aligned to the
        // burst of 8 (low 3 bits zero) and below 2^28; the line is addr[27:3]. Command 000 is a write and 001 a
        // read.
        if (cmd_en && cmd_ready) begin
            if (addr[2:0] != 3'd0 || addr[28]) begin errors = errors + 1; $display("model: bad address %h", addr); end
            if (cmd == 3'b000) begin
                n_wr = n_wr + 1;
                if (!(wr_data_en && wr_data_rdy && wr_data_end)) begin
                    errors = errors + 1; $display("model: write command without its data in the same clock");
                end
                // Merge the written bytes into the line: a mask bit of 1 keeps the old byte.
                w = mem[addr[27:3] % MEM_LINES];
                for (i = 0; i < DQW; i = i + 1) if (!wr_data_mask[i]) w[8*i +: 8] = wr_data[8*i +: 8];
                mem[addr[27:3] % MEM_LINES] = w;
            end else if (cmd == 3'b001) begin
                n_rd = n_rd + 1;
                // A read puts the line into the queue with its release time LAT clocks from now.
                q_d[q_w % 64] = mem[addr[27:3] % MEM_LINES]; q_t[q_w % 64] = now + LAT; q_w = q_w + 1;
            end else begin errors = errors + 1; $display("model: unknown command"); end
        // Write data without a command in the same clock is a protocol violation.
        end else if (wr_data_en && wr_data_rdy) begin
            errors = errors + 1; $display("model: write data without a command");
        end
        // Release the oldest queued read when its time has come, as one beat of valid data.
        if (q_r != q_w && q_t[q_r % 64] <= now) begin
            rd_data <= q_d[q_r % 64]; rd_data_valid <= 1'b1; rd_data_end <= 1'b1; q_r = q_r + 1;
        end
    end
endmodule
