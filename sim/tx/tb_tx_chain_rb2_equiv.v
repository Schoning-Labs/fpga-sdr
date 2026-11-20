// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Equivalence test of the transmit chain's FIR stage. rtl/tx/tx_fir_interp4.v computes its 4-phase
// polyphase interpolation with one shared multiplier that is used over many clocks, and the version it
// replaced (kept in sim/tx/ref/) did all multiply-adds of a phase in parallel in one clock. This bench shows
// that the two designs are bit exact the same, by running both complete transmit chains (the real
// rtl/tx/tx_chain.v and the reference sim/tx/ref/tx_chain_ref.v, see sim/tx/tb_tx_chain.v for what the chain
// does and docs/learn/GLOSSARY.md for the terms) side by side from the same reset with the same stimulus and
// comparing out_data on every clock. The current chain's output comes LAT clocks later than the reference's,
// which is handled by delaying the reference (see out_data_ref_d below). The bench is self-contained: it
// includes its DUTs and every module they need, by paths relative to the repository root.
//
// Stimulus, in one continuous run of about 86,000 clocks (the same two-tone baseband that
// sim/tx/tb_tx_chain.v uses, which the chains see all the time):
//
// 1. 20,000 clocks with the chain disabled, which covers the start-up of both pipelines.
// 2. 40,000 clocks enabled, in steady state, long enough to cover many full FIR phase cycles (4 calc
//    pulses are one new baseband sample) well past the FIR and CIC start-up transient.
// 3. Disable, re-enable and trip, toggled the same way as in sim/tx/tb_tx_chain.v, 2,000 clocks each,
//    followed by 20,000 clocks of normal operation.
//
// The spectral purity check of sim/tx/tb_tx_chain.v is not repeated here, and no long settling window is
// needed: with identical stimulus from an identical reset both chains are deterministic, so any divergence
// shows up at once, at whatever clock it first occurs. The run is kept short so that it is quick when
// tools/check.sh runs everything under sim/.
//
// Pass: out_data and out_valid of the current chain equal the delayed reference on every compared clock. The
// bench prints the number of clocks compared and of mismatches, the first mismatch if any, and PASS or FAIL.
//
// The reference chain is sim/tx/ref/tx_chain_ref.v with sim/tx/ref/tx_fir_interp4_ref.v, copies of the
// earlier rtl/tx/tx_chain.v and rtl/tx/tx_fir_interp4.v that differ only in their names, so that both can be
// compiled into one simulation next to the current modules.
//
// How to run: from the repository root, `iverilog -g2012 -o tb.vvp sim/tx/tb_tx_chain_rb2_equiv.v && vvp tb.vvp`,
// or `bash tools/check.sh`.

`timescale 1ns / 1ps

`include "rtl/tx/CicInterpM5.v"
`include "rtl/rx/nco_mixer.v"
`include "rtl/tx/tx_fir_interp4.v"
`include "rtl/tx/tx_chain.v"
`include "sim/tx/ref/tx_fir_interp4_ref.v"
`include "sim/tx/ref/tx_chain_ref.v"

module tb_tx_chain_rb2_equiv;

    // The same constants as in sim/tx/tb_tx_chain.v: an NCO at bin 12032 of a 65,536-point FFT of the 76.8 Msps
    // output (14.1 MHz) and two baseband tones at +6 and -7 bins, 9,000 of 32,767 full scale each.
    // ---- shared stimulus (same two-tone design as sim/tx/tb_tx_chain.v) ----------------
    localparam real FS_OUT = 76_800_000.0;
    localparam LOGN = 16;
    localparam NFFT = 65536;                    // bin spacing = 76.8 MHz / 65536 = 1171.875 Hz
    localparam integer LO_BIN   = 12032;
    localparam integer NCO_FREQ = LO_BIN * (32'd1 << (32 - LOGN));
    localparam integer F1_BIN = 6;
    localparam integer F2_BIN = -7;
    localparam real A1 = 9000.0;
    localparam real A2 = 9000.0;
    localparam real PI = 3.14159265358979323846;

    // One clock and one set of control inputs for both chains; enable and trip reach the current chain
    // through a delay (enable_d, trip_d, below).
    reg clock = 0;
    reg rst   = 1;
    reg enable = 0;
    reg trip   = 0;
    reg [4:0] gain_shift = 5'd0;

    always #5 clock = ~clock;

    // ---- baseband sources, one independent generator per chain --------------------------
    // Each DUT gets its own bb_i, bb_q and bb_req loop, as sim/tx/tb_tx_chain.v drives its single DUT: a chain
    // only ever sees a new sample in response to its own bb_req. The two FIRs raise bb_req a different number
    // of clocks after calc (about 22 clocks in the shared-multiplier FIR against 1 in the reference, see
    // rtl/tx/tx_fir_interp4.v), so the chains do not pull a given baseband sample on the same absolute clock
    // and do not need to. Both generators enumerate the identical two-tone waveform by sample index, and as
    // long as each chain's own request arrives before its next use of that sample (always true here, since the
    // next use is 1,600 clocks later, docs/ARCHITECTURE.md section 3.6) both chains consume the same sample
    // values in the same order, which is what makes their out_data streams comparable at all.
    wire signed [15:0] bb_i_new, bb_q_new, bb_i_ref, bb_q_ref;
    wire bb_req_new, bb_req_ref;
    wire signed [11:0] out_data_new, out_data_ref;
    wire out_valid_new, out_valid_ref;

    integer n_new, n_ref;
    reg signed [15:0] bb_i_new_r, bb_q_new_r, bb_i_ref_r, bb_q_ref_r;
    assign bb_i_new = bb_i_new_r;
    assign bb_q_new = bb_q_new_r;
    assign bb_i_ref = bb_i_ref_r;
    assign bb_q_ref = bb_q_ref_r;

    // Two-tone baseband sample number idx of the I and Q streams (cosine and sine of the same two
    // frequencies, 7,031.25 Hz and -8,203.125 Hz, at 48 kHz).
    function real bb_sample_i(input integer idx);
        real f1, f2;
        begin
            f1 = FS_OUT / NFFT * F1_BIN;
            f2 = FS_OUT / NFFT * F2_BIN;
            bb_sample_i = A1*$cos(2.0*PI*f1*idx/48000.0) + A2*$cos(2.0*PI*f2*idx/48000.0);
        end
    endfunction

    function real bb_sample_q(input integer idx);
        real f1, f2;
        begin
            f1 = FS_OUT / NFFT * F1_BIN;
            f2 = FS_OUT / NFFT * F2_BIN;
            bb_sample_q = A1*$sin(2.0*PI*f1*idx/48000.0) + A2*$sin(2.0*PI*f2*idx/48000.0);
        end
    endfunction

    // Generator of the current chain.
    always @(posedge clock) begin
        if (rst) begin
            n_new <= 0;
            bb_i_new_r <= $rtoi(bb_sample_i(0));
            bb_q_new_r <= $rtoi(bb_sample_q(0));
        end else if (bb_req_new) begin
            n_new <= n_new + 1;
            bb_i_new_r <= $rtoi(bb_sample_i(n_new + 1));
            bb_q_new_r <= $rtoi(bb_sample_q(n_new + 1));
        end
    end

    // Generator of the reference chain.
    always @(posedge clock) begin
        if (rst) begin
            n_ref <= 0;
            bb_i_ref_r <= $rtoi(bb_sample_i(0));
            bb_q_ref_r <= $rtoi(bb_sample_q(0));
        end else if (bb_req_ref) begin
            n_ref <= n_ref + 1;
            bb_i_ref_r <= $rtoi(bb_sample_i(n_ref + 1));
            bb_q_ref_r <= $rtoi(bb_sample_q(n_ref + 1));
        end
    end

    // The output stage of rtl/tx/tx_chain.v has LAT more pipeline registers than the reference's, but the
    // enable and trip gating is not delayed with them: the current chain's samples come out LAT clocks later
    // than the reference's, gated by the enable and trip of the clock they come out on. So the reference is
    // compared through a LAT clock delay, and the current chain gets enable and trip LAT clocks late (enable_d
    // and trip_d), so that both gate the same sample with the same values. Both chains use the same NCO mixer,
    // so its own latency does not count. LAT = 3 output stage registers plus 1 for the registered pace
    // (everything behind pace in rtl/tx/tx_chain.v is one clock later).
    localparam integer LAT = 4;
    reg signed [11:0] ref_data_dl [0:LAT-1];
    reg               ref_valid_dl [0:LAT-1];
    reg               enable_dl [0:LAT-1];
    reg               trip_dl [0:LAT-1];
    integer dl;
    initial for (dl = 0; dl < LAT; dl = dl + 1) begin
        enable_dl[dl] = 1'b0;
        trip_dl[dl]   = 1'b0;
    end
    // Shift registers that delay the reference's output and the enable and trip inputs by LAT clocks.
    always @(posedge clock) begin
        ref_data_dl[0]  <= out_data_ref;
        ref_valid_dl[0] <= out_valid_ref;
        enable_dl[0]    <= enable;
        trip_dl[0]      <= trip;
        for (dl = 1; dl < LAT; dl = dl + 1) begin
            ref_data_dl[dl]  <= ref_data_dl[dl-1];
            ref_valid_dl[dl] <= ref_valid_dl[dl-1];
            enable_dl[dl]    <= enable_dl[dl-1];
            trip_dl[dl]      <= trip_dl[dl-1];
        end
    end
    wire signed [11:0] out_data_ref_d  = ref_data_dl[LAT-1];
    wire               out_valid_ref_d = ref_valid_dl[LAT-1];
    wire               enable_d        = enable_dl[LAT-1];
    wire               trip_d          = trip_dl[LAT-1];

    // ---- DUTs: current (one shared multiplier) and reference (parallel multipliers) -----
    tx_chain #(
        .OUTPUT_SHIFT(15)
    ) dut_new (
        .clock     (clock),
        .rst       (rst),
        .pace      (1'b1),
        .bb_i      (bb_i_new),
        .bb_q      (bb_q_new),
        .bb_valid  (1'b1),
        .bb_req    (bb_req_new),
        .enable    (enable_d),
        .trip      (trip_d),
        .nco_freq  (NCO_FREQ),
        .gain_shift(gain_shift),
        .out_data  (out_data_new),
        .out_valid (out_valid_new)
    );

    tx_chain_ref #(
        .OUTPUT_SHIFT(15)
    ) dut_ref (
        .clock     (clock),
        .rst       (rst),
        .pace      (1'b1),
        .bb_i      (bb_i_ref),
        .bb_q      (bb_q_ref),
        .bb_valid  (1'b1),
        .bb_req    (bb_req_ref),
        .enable    (enable),
        .trip      (trip),
        .nco_freq  (NCO_FREQ),
        .gain_shift(gain_shift),
        .out_data  (out_data_ref),
        .out_valid (out_valid_ref)
    );

    // ---- clock by clock comparison --------------------------------------------------------
    // Each compared clock waits 1 ns after the clock edge, so that the registered outputs of both chains have
    // settled, and counts a mismatch of out_data or of out_valid.
    integer errors;
    integer cyc;
    integer first_mismatch_cyc;

    initial begin
        errors = 0;
        cyc = 0;
        first_mismatch_cyc = -1;

        repeat (4) @(posedge clock);
        rst = 1'b0;

        // ---- case 1: two-tone baseband, disabled at first (as in tb_tx_chain.v, enable stays low through
        // start-up) --------------------------------------------------------------------------
        repeat (20_000) begin
            @(posedge clock);
            #1; // let both DUTs' registered outputs settle before sampling
            if (out_data_new !== out_data_ref_d) begin
                errors = errors + 1;
                if (first_mismatch_cyc == -1) first_mismatch_cyc = cyc;
            end
            if (out_valid_new !== out_valid_ref_d) errors = errors + 1;
            cyc = cyc + 1;
        end

        // ---- case 2: enable, run the two-tone steady state ------------------------------------
        enable = 1'b1;
        repeat (40_000) begin
            @(posedge clock);
            #1;
            if (out_data_new !== out_data_ref_d) begin
                errors = errors + 1;
                if (first_mismatch_cyc == -1) first_mismatch_cyc = cyc;
            end
            if (out_valid_new !== out_valid_ref_d) errors = errors + 1;
            cyc = cyc + 1;
        end

        // ---- case 3: disable, re-enable and trip, 2,000 clocks each, same order as tb_tx_chain.v ----
        enable = 1'b0;
        repeat (2000) begin
            @(posedge clock);
            #1;
            if (out_data_new !== out_data_ref_d) begin
                errors = errors + 1;
                if (first_mismatch_cyc == -1) first_mismatch_cyc = cyc;
            end
            cyc = cyc + 1;
        end

        enable = 1'b1;
        repeat (2000) begin
            @(posedge clock);
            #1;
            if (out_data_new !== out_data_ref_d) begin
                errors = errors + 1;
                if (first_mismatch_cyc == -1) first_mismatch_cyc = cyc;
            end
            cyc = cyc + 1;
        end

        trip = 1'b1;
        repeat (2000) begin
            @(posedge clock);
            #1;
            if (out_data_new !== out_data_ref_d) begin
                errors = errors + 1;
                if (first_mismatch_cyc == -1) first_mismatch_cyc = cyc;
            end
            cyc = cyc + 1;
        end
        trip = 1'b0;

        repeat (20_000) begin
            @(posedge clock);
            #1;
            if (out_data_new !== out_data_ref_d) begin
                errors = errors + 1;
                if (first_mismatch_cyc == -1) first_mismatch_cyc = cyc;
            end
            cyc = cyc + 1;
        end

        $display("Compared %0d cycles; out_data/out_valid mismatches: %0d; samples pulled new=%0d ref=%0d",
                  cyc, errors, n_new, n_ref);
        if (first_mismatch_cyc != -1)
            $display("First out_data mismatch at compared cycle %0d", first_mismatch_cyc);

        if (errors == 0)
            $display("PASS");
        else
            $display("FAIL: %0d out_data/out_valid mismatch(es)", errors);

        $finish;
    end

endmodule
