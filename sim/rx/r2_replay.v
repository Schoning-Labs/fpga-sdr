// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Replay harness for the receiver bank rtl/rx/rx_bank.v with eight receivers (see docs/RX_DSP.md and
// docs/R2_RXMODEL.md). The bank takes one stream of 12 bit ADC samples, runs each of its
// receivers through a mixer, a CIC filter and a compensating FIR (the terms are explained in
// docs/learn/GLOSSARY.md), and delivers all of their output samples on one stream tagged with
// the receiver number. This file has no stimulus of its own. It plays back a stimulus file and
// prints what the bank produces, so that a Rust model of the same bank can be run over exactly the
// same stimulus and the two outputs compared word for word.
//
// Input: sim/rx/out/r2_stimulus.txt, one line per ADC clock cycle, either "0 <valid> <data>" to
// present one adc_valid / adc_data cycle (the valid flag lets the file leave gaps in the sample
// stream, as the real ADC pacing does), or "1 <addr> <wdata>" to pulse one register write to the
// bank (the tuning word or the control word of a receiver). The whole schedule, including
// when each register write lands relative to the ADC stream, lives in this one file, which
// fw/tr-rxmodel/src/bin/r2_check.rs writes.
//
// Output: one line "O <index> <i> <q>" for every out_valid pulse, in time order, then
// "DONE <lines> <outputs>" and "PASS". The PASS only means that the replay ran to the end. The
// verdict is r2_check.rs, which runs the identical stimulus through the Rust model and diffs the
// two output streams word for word.
//
// The file is not named tb_*.v on purpose. The generic loop of tools/check.sh would try to run it
// standalone before the stimulus file exists and fail. r2_check.rs compiles it with iverilog and
// runs it with vvp itself (`cargo run -p tr-rxmodel --release --bin r2_check` in fw/, which
// tools/check.sh does in its receiver bank section).
//
// Output sampling: out_valid, out_index, out_i and out_q are registers inside rx_bank, updated by
// nonblocking assignment on the same rising edge that the stimulus loop below also runs on, so
// reading them in that loop right after `@(posedge clock)` would race the update. The capture
// therefore runs in a separate block on the falling edge, half a period later, when all updates
// of the rising edge have settled, which is the usual way around this race.

`timescale 1ns / 1ps

`include "rtl/rx/nco_mixer.v"
`include "rtl/rx/cic_integrator.v"
`include "rtl/rx/cic_comb.v"
`include "rtl/rx/cic_fixed.v"
`include "rtl/rx/cic_var_shared.v"
`include "rtl/rx/fir_decim.v"
`include "rtl/rx/fir_delay_ram2.v"
`include "rtl/rx/rx_channel.v"
`include "rtl/rx/rx_bank.v"

module r2_replay;

    // Eight receivers, the stimulus file's path, the reset length in clocks, and how many clocks
    // to keep running after the last stimulus line so that the pipeline can drain.
    localparam N = 8;
    localparam STIM_PATH = "sim/rx/out/r2_stimulus.txt";
    localparam RESET_CYCLES = 5;
    localparam DRAIN_CYCLES = 32;

    // The time scale is arbitrary (2 ns per period), the bank only counts clock edges.
    reg clock = 1'b0;
    always #1 clock = ~clock;

    // The bank's inputs: ADC data and valid, and the register write port (a 4 bit address that
    // holds the receiver number and the register, and a 32 bit word).
    reg         rst = 1'b1;
    reg  [11:0] adc_data = 12'sd0;
    reg         adc_valid = 1'b0;
    reg         reg_wr = 1'b0;
    reg  [3:0]  reg_addr = 4'd0;
    reg  [31:0] reg_wdata = 32'd0;

    // The bank's output stream: one sample per out_valid, tagged with its receiver in out_index.
    wire        out_valid;
    wire [2:0]  out_index;
    wire signed [23:0] out_i, out_q;

    // 12 bit ADC samples, the coefficients of the compensating FIR read from rtl/rx/fir_coeffs.hex.
    rx_bank #(
        .N(N), .ADC_WIDTH(12), .FIR_COEFF_FILE("rtl/rx/fir_coeffs.hex")
    ) dut (
        .clock(clock), .rst(rst),
        .adc_data(adc_data), .adc_valid(adc_valid),
        .reg_wr(reg_wr), .reg_addr(reg_addr), .reg_wdata(reg_wdata),
        .out_valid(out_valid), .out_index(out_index), .out_i(out_i), .out_q(out_q)
    );

    // Number of outputs seen.
    integer out_count;

    // Output capture on the falling edge, clear of the update at the rising edge it is reading
    // (see the header). It runs for the whole simulation and the main block below ends it with
    // $finish after the last stimulus line and the drain clocks.
    always @(negedge clock) begin
        if (out_valid) begin
            $display("O %0d %0d %0d", out_index, $signed(out_i), $signed(out_q));
            out_count = out_count + 1;
        end
    end

    // fh is the stimulus file, code is 0 for an ADC cycle and 1 for a register write, f1 and f2
    // are its two fields, got is the number of fields read by $fscanf.
    integer fh;
    integer code, f1, f2, got;
    integer line_count;

    initial begin
        out_count = 0;
        line_count = 0;

        // Reset for RESET_CYCLES clocks, then open the stimulus file.
        repeat (RESET_CYCLES) @(posedge clock);
        rst = 1'b0;

        fh = $fopen(STIM_PATH, "r");
        if (fh == 0) begin
            $display("FAIL: cannot open %s", STIM_PATH);
            $finish;
        end

        // Play the file back one line per clock: an ADC cycle (valid flag and data, no register
        // write) or a register write (address and data, no ADC sample).
        got = $fscanf(fh, "%d %d %d", code, f1, f2);
        while (got == 3) begin
            line_count = line_count + 1;
            if (code == 0) begin
                adc_valid <= f1[0];
                adc_data  <= f2[11:0];
                reg_wr    <= 1'b0;
            end else begin
                adc_valid <= 1'b0;
                reg_wr    <= 1'b1;
                reg_addr  <= f1[3:0];
                reg_wdata <= f2;
            end
            @(posedge clock);
            got = $fscanf(fh, "%d %d %d", code, f1, f2);
        end
        $fclose(fh);

        // Stop driving, run the pipeline empty and report.
        adc_valid <= 1'b0;
        reg_wr    <= 1'b0;
        repeat (DRAIN_CYCLES) @(posedge clock);

        // One more falling edge, so that an out_valid in the last drain clock is captured before
        // out_count is read.
        @(negedge clock);

        $display("DONE %0d %0d", line_count, out_count);
        $display("PASS");
        $finish;
    end

endmodule
