// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// End-to-end testbench for rtl/audio/audio_engine.v, which wires the DDR3 ring reader, the x8 polyphase
// interpolator and the PT8211 serializer together (docs/ARCHITECTURE.md section 3.7). A process in the
// testbench plays the firmware and writes a sequence of constant (DC) plateaus into a ring held in
// sim/audio/ddr3_behav_model.v, and a decoder of the three PT8211 pins (the same technique as
// tb_audio_pt8211_tx.v) turns the engine's bck, ws and din back into 16-bit samples, which are then compared
// with what the filter has to produce.
//
// Why DC plateaus, and what the known gain is: a constant input is the one signal a direct-form FIR
// interpolator does not reproduce exactly. The 8 polyphase phases do not have exactly equal tap sums, because
// rtl/audio/audio_interp_coeffs.hex was designed as a low-pass filter and not as a Nyquist interpolator with a
// unity centre tap (docs/A1_AUDIO.md). Once a plateau has been held long enough to fill the 18-tap delay
// line (18 input samples, and this test holds each plateau for 48), the output cycles through exactly 8 known
// values, one per phase. They are computed here from the 8 per-phase coefficient sums (PHASE_SUM below) with
// the same round-half-up and saturate rule as `round_sat` in audio_interp_x8.v. The gain is therefore not
// exactly one, but it is exactly computable, and the decoded pins are compared with it for equality and not
// within a tolerance.
//
// Stimulus: four plateaus of 12,000, -9,000, 32,000 and -32,000, each 48 input samples long, in both
// channels. The ring is 64 words deep and the producer only writes while a slot is free.
//
// The fixed group delay of the filter (about 71.5 samples at 384 kHz according to docs/A1_AUDIO.md, plus a
// few clocks of ring and serializer pipeline) is not assumed anywhere: the checks begin only once each
// plateau has clearly settled, see MARGIN_IN, and wait on the real count of decoded samples.
//
// Passing: for every plateau the 16 decoded left samples from deep in steady state match some rotation of the
// 8 expected per-phase values. The last line is "PASS", otherwise a "FAIL: plateau ..." line with the decoded
// values, and "FAIL: <n> mismatch(es)", or "FAIL: timeout" after 5 ms of simulated time (the 192 input samples
// take 4 ms at 48 kHz). Run it from the repository root, the include paths are relative to it:
//   iverilog -g2012 -o sim/out/tb_audio_engine.vvp sim/audio/tb_audio_engine.v && vvp -n sim/out/tb_audio_engine.vvp
// or all testbenches together with tools/check.sh.

`timescale 1ns / 1ps
`include "rtl/audio/audio_ring_reader.v"
`include "rtl/audio/audio_interp_x8.v"
`include "rtl/audio/audio_nco_tick.v"
`include "rtl/audio/audio_pt8211_tx.v"
`include "rtl/audio/audio_engine.v"
`include "sim/audio/ddr3_behav_model.v"

module tb_audio_engine;

    // 120 MHz DSP clock (docs/ARCHITECTURE.md section 2).
    localparam integer CLK_HZ = 120_000_000;
    localparam real    CLK_PERIOD_NS = 1.0e9 / CLK_HZ;

    reg clk = 0;
    always #(CLK_PERIOD_NS / 2.0) clk = ~clk;
    reg rst = 1;

    // A small ring (64 words) and FIFO (8) so the ring wraps and the producer has to wait for free slots.
    localparam integer ADDR_WIDTH      = 32;
    localparam integer RING_SIZE_WORDS = 64;
    localparam integer FIFO_DEPTH      = 8;
    localparam [ADDR_WIDTH-1:0] RING_BASE = 32'h1000;

    reg  [ADDR_WIDTH-1:0] wr_ptr;
    wire [ADDR_WIDTH-1:0] rd_ptr;
    wire                  mem_req;
    wire [ADDR_WIDTH-1:0] mem_addr;
    wire                  mem_rvalid;
    wire [31:0]           mem_rdata;
    wire                  pt8211_bck, pt8211_ws, pt8211_din;
    wire                  hdmi_audio_valid;
    wire signed [15:0]    hdmi_audio_l, hdmi_audio_r;
    wire                  ring_empty, ring_low_water, interp_underrun;

    audio_engine #(
        .ADDR_WIDTH     (ADDR_WIDTH),
        .RING_SIZE_WORDS(RING_SIZE_WORDS),
        .FIFO_DEPTH     (FIFO_DEPTH)
    ) dut (
        .clk             (clk),
        .rst             (rst),
        .ring_base       (RING_BASE),
        .wr_ptr          (wr_ptr),
        .rd_ptr          (rd_ptr),
        .mem_req         (mem_req),
        .mem_addr        (mem_addr),
        .mem_rvalid      (mem_rvalid),
        .mem_rdata       (mem_rdata),
        .pt8211_bck      (pt8211_bck),
        .pt8211_ws       (pt8211_ws),
        .pt8211_din      (pt8211_din),
        .hdmi_audio_valid(hdmi_audio_valid),
        .hdmi_audio_l    (hdmi_audio_l),
        .hdmi_audio_r    (hdmi_audio_r),
        .ring_empty      (ring_empty),
        .ring_low_water  (ring_low_water),
        .interp_underrun (interp_underrun)
    );

    // The memory model answers a read 3 clocks after the request.
    ddr3_behav_model #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .MEM_WORDS (4096),
        .LATENCY   (3)
    ) mem_model (
        .clk       (clk),
        .rst       (rst),
        .mem_req   (mem_req),
        .mem_addr  (mem_addr),
        .mem_rvalid(mem_rvalid),
        .mem_rdata (mem_rdata)
    );

    // ---------------------------------------------------------------- per-phase expected DC gain
    // Per-phase sums of the 18 coefficients of that phase in audio_interp_coeffs.hex (the integer sums of
    // the Q17 values), listed in the order of `phase_reg` 0 to 7 in rtl/audio/audio_interp_x8.v. Phases 0 and 7
    // are equal and so are 1 and 6, the filter is symmetric. A phase sum divided by 2^14 is the DC gain of
    // that phase, which is close to 1 (16376 / 16384) but not equal.
    function integer phase_sum(input integer p);
        begin
            case (p)
                0: phase_sum = 16386;
                1: phase_sum = 16368;
                2: phase_sum = 16376;
                3: phase_sum = 16376;
                4: phase_sum = 16376;
                5: phase_sum = 16376;
                6: phase_sum = 16368;
                7: phase_sum = 16386;
                default: phase_sum = 0;
            endcase
        end
    endfunction

    // Expected output for a DC input `x` in phase `p`: the same round-half-up then saturate rule as
    // `round_sat` in audio_interp_x8.v, with a shift of 14 bits (the coefficients are Q17 and the
    // interpolation gain of 8 takes off 3 bits).
    // Same round-half-up-then-saturate rule as audio_interp_x8.v's round_sat (SHIFT=14).
    function integer expected_dc(input integer x, input integer p);
        integer acc, shifted;
        begin
            acc     = x * phase_sum(p);
            shifted = (acc + (1 <<< 13)) >>> 14;
            if (shifted > 32767) expected_dc = 32767;
            else if (shifted < -32768) expected_dc = -32768;
            else expected_dc = shifted;
        end
    endfunction

    // ---------------------------------------------------------------- stimulus: DC plateaus
    localparam integer NPLATEAU   = 4;
    localparam integer N_IN_HOLD  = 48; // comfortably more than the settling time below
    // The output of the interpolator needs about 28 input samples to settle after a step from one DC value to
    // another, longer than the 18 samples of the delay line alone because of the deferred shift pipeline in
    // audio_interp_x8.v. MARGIN_IN is well above that.
    localparam integer MARGIN_IN  = 34; // input samples to skip before trusting steady state
    localparam integer CHECK_OUT  = 16; // decoded samples checked per plateau (2 full 8-phase cycles)

    integer plateau_val [0:NPLATEAU-1];
    initial begin
        plateau_val[0] = 12000;
        plateau_val[1] = -9000;
        plateau_val[2] = 32000;
        plateau_val[3] = -32000;
    end

    // The simulated firmware: while the current plateau has samples left and the ring has a free slot, write
    // the same value into both channels of the next ring word (a `poke`, standing for the CPU's write-back)
    // and move `wr_ptr` on, then go to the next plateau after N_IN_HOLD words.
    reg  [ADDR_WIDTH-1:0] words_written;
    integer                cur_plateau;
    integer                cur_in_count;
    reg signed [15:0]      cur_val;

    always @(posedge clk) begin
        if (rst) begin
            wr_ptr        <= {ADDR_WIDTH{1'b0}};
            words_written <= {ADDR_WIDTH{1'b0}};
            cur_plateau   <= 0;
            cur_in_count  <= 0;
        end else if (cur_plateau < NPLATEAU &&
                      (wr_ptr - rd_ptr) < RING_SIZE_WORDS[ADDR_WIDTH-1:0]) begin
            cur_val = plateau_val[cur_plateau][15:0];
            mem_model.poke(RING_BASE + (wr_ptr & (RING_SIZE_WORDS - 1)), {cur_val, cur_val});
            wr_ptr        <= wr_ptr + 1'b1;
            words_written <= words_written + 1'b1;
            if (cur_in_count == N_IN_HOLD - 1) begin
                cur_in_count <= 0;
                cur_plateau  <= cur_plateau + 1;
            end else begin
                cur_in_count <= cur_in_count + 1;
            end
        end
    end

    // ---------------------------------------------------------------- PT8211 pin decoder
    reg [4:0]  idx;
    reg [15:0] shreg;
    reg        bck_d;
    wire       bck_rise = pt8211_bck && !bck_d;
    always @(posedge clk) bck_d <= pt8211_bck;

    // Room for every decoded sample of all plateaus, plus some for the pipeline delay.
    localparam integer MAX_DECODED = NPLATEAU * N_IN_HOLD * 8 + 64; // + margin for pipeline latency
    reg signed [15:0] dec_l [0:MAX_DECODED-1];
    integer            dec_count;

    // Decoder: shift DIN in on every BCK rising edge and keep the left channel word (the second half of the
    // 32-bit frame) when it is complete.
    always @(posedge clk) begin
        if (rst) begin
            idx       <= 5'd0;
            shreg     <= 16'd0;
            dec_count <= 0;
        end else if (bck_rise) begin
            shreg <= {shreg[14:0], pt8211_din};
            if (idx[3:0] == 4'hF && idx[4] == 1'b1 && dec_count < MAX_DECODED) begin
                // 16th bit of the LEFT channel just arrived; record the completed left word (L
                // and R carry the same value here, see the producer above).
                dec_l[dec_count] <= {shreg[14:0], pt8211_din};
                dec_count        <= dec_count + 1;
            end
            idx <= (idx == 5'd31) ? 5'd0 : (idx + 5'd1);
        end
    end

    // Each plateau must show CHECK_OUT consecutive decoded samples, taken from near the end of its dwell,
    // that match one fixed rotation of the 8 expected per-phase values. The rotation is not assumed, it is
    // searched, and it then has to hold for every sample of the window.
    //
    // The window is placed by waiting for `dec_count` to reach a value and not by computing an index from the
    // input sample count, because the ring reader, interpolator and serializer add a fixed pipeline delay
    // (a handful of decoded samples) between a write and its appearance on the pins, and waiting on the real
    // count makes the test independent of it. The window ends MARGIN_IN input samples after the start of the
    // plateau, so it sits deep in steady state as long as the delay is well under the 48 samples of a plateau.
    integer errors;
    integer p, dec_needed, base, rot, k, want, got, found, all_match;

    initial begin
        errors = 0;
        #(20 * CLK_PERIOD_NS);
        rst = 0;

        // For each plateau: wait for the decoded samples up to the window's end, then try the 8 rotations.
        for (p = 0; p < NPLATEAU; p = p + 1) begin
            dec_needed = (p * N_IN_HOLD + MARGIN_IN) * 8;
            wait (dec_count >= dec_needed);
            base = dec_needed - CHECK_OUT;

            // The search needs a rotation that matches the whole window, not only its first sample: two
            // pairs of the 8 expected values coincide (phase 0 equals phase 7 and phase 1 equals phase 6, a
            // symmetry of this filter), so matching one sample could lock onto the wrong rotation.
            found = 0;
            for (rot = 0; rot < 8; rot = rot + 1) begin
                if (!found) begin
                    all_match = 1;
                    for (k = 0; k < CHECK_OUT; k = k + 1) begin
                        want = expected_dc(plateau_val[p], (rot + k) % 8);
                        got  = $signed(dec_l[base + k]);
                        if (got !== want) all_match = 0;
                    end
                    if (all_match) found = 1;
                end
            end
            if (!found) begin
                $display("FAIL: plateau %0d (value=%0d): no rotation of the expected per-phase values matches decoded samples %0d..%0d",
                          p, plateau_val[p], base, base + CHECK_OUT - 1);
                for (k = 0; k < CHECK_OUT; k = k + 1)
                    $display("  decoded[%0d] = %0d", k, $signed(dec_l[base + k]));
                errors = errors + 1;
            end
        end

        if (errors == 0)
            $display("PASS");
        else
            $display("FAIL: %0d mismatch(es)", errors);
        $finish;
    end

    // Safety net: 5 ms of simulated time.
    initial begin
        #(5_000_000);
        $display("FAIL: timeout, dec_count=%0d wr_ptr=%0d", dec_count, wr_ptr);
        $finish;
    end

endmodule
