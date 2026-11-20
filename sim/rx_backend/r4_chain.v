// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// End to end testbench of the whole receive path: a 12-bit ADC stream with bursty adc_valid goes through
// the real receiver bank (rtl/rx/rx_bank.v, 8 receivers, two per input rate) and on into the receiver
// back end (rtl/rx_backend/rx_backend.v), and the results are compared with the two bit-exact Rust
// models chained in the same order (tr-rxmodel for the bank, then tr_dsp::backend for the back end).
// The bank mixes each receiver down from the ADC stream with a numerically controlled oscillator and
// decimates it in CIC and FIR stages (see docs/learn/GLOSSARY.md), the back end then filters,
// demodulates and gain controls it, so this bench shows that the two blocks work together on the
// shared stream that connects them, which neither block's own bench can show.
//
// Stimulus: four tones from phase accumulators and the sine table sim/rx_backend/bk_sine.hex plus
// xorshift noise, quantized to the 12-bit range of the ADC, with a new sample only on clocks where
// adc_valid is high (bursts of 1 to 48 valid clocks and gaps of 1 to 46). It is generated exactly as
// fw/tr-dsp/examples/r4_common/chain.rs generates it for the models. The configuration of the banks
// and receivers and the expected results come from chain_scn.vh, written by
// `r4_check chain <cycles> <file>` (see tools/run_r4_full.sh, which passes it in with -I). This is not
// a tb_*.v file on purpose, because it runs for minutes and only belongs in the full run.
//
// Pass: for every receiver the output count and the hash of every output word and stamp offset equal
// the model's, and the final S-meter, squelch state, AGC gain and blanked count read back as the model
// says. Two further counters guard the bank itself and have to stay 0: `repeats` counts bank samples
// that appear again on the very next clock (the bank's arbiter must never send a sample twice), and
// `drain_samples` counts bank samples emitted after adc_valid stopped (the bank decimates by counting
// adc_valid pulses, so nothing may come out once the input stops). PASS is printed when everything
// matches, otherwise FAIL lines.
//
// How to run: bash tools/run_r4_full.sh, which writes chain_scn.vh with a 200,000 clock stream and runs
// `iverilog -g2012 -I <folder with chain_scn.vh> -o tb.vvp sim/rx_backend/r4_chain.v` and `vvp tb.vvp`.

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
`include "rtl/rx_backend/bk_mul.v"
`include "rtl/rx_backend/bk_ram.v"
`include "rtl/rx_backend/bk_rom.v"
`include "rtl/rx_backend/bk_fifo.v"
`include "rtl/rx_backend/bk_front.v"
`include "rtl/rx_backend/bk_decim.v"
`include "rtl/rx_backend/bk_chfilt.v"
`include "rtl/rx_backend/bk_cordic.v"
`include "rtl/rx_backend/bk_post.v"
`include "rtl/rx_backend/bk_ring.v"
`include "rtl/rx_backend/rx_backend.v"

module r4_chain;
    // Tables filled by the scenario file: the 12 coefficient banks of the back end, its per-receiver
    // register values and the results of the models (output count, output hash, final S-meter, AGC
    // gain, squelch state, blanked count).
    integer bk_kind [0:11], bk_ntaps [0:11], bk_exp [0:11], bk_step [0:11], bk_shift [0:11];
    reg [31:0] bk_seed [0:11];
    reg [31:0] cfg_ctrl [0:7], cfg_nb [0:7], cfg_hold [0:7], cfg_att [0:7], cfg_dec [0:7];
    reg [31:0] cfg_hang [0:7], cfg_ref [0:7], cfg_gmax [0:7], cfg_gmin [0:7], cfg_gman [0:7];
    reg [31:0] cfg_loops [0:7], cfg_deemph [0:7], cfg_sq [0:7];
    // Receiver bank side of the scenario: per receiver the NCO phase increment (bank_inc) and the
    // rate code (bank_rate), then the ADC stimulus: four tones (amplitude and phase increment) and the
    // noise shift.
    reg [31:0] bank_inc [0:7];
    integer    bank_rate [0:7];
    integer    tone_amp [0:3];
    reg [31:0] tone_inc [0:3];
    integer    noise_shift;
    integer exp_count [0:7], exp_smeter [0:7], exp_gain [0:7], exp_sq [0:7], exp_blanked [0:7];
    reg [31:0] exp_hash [0:7];
    // Defines scn_load, CHAIN_CYCLES (clocks of ADC stream) and CHAIN_DRAIN (idle clocks afterwards).
    `include "chain_scn.vh"

    reg clk = 1'b0;
    // Half period 3.333 ns makes a 6.666 ns period, the 150 MHz DSP clock of the chip.
    always #3.333 clk = ~clk;
    reg rst = 1'b1;

    // receiver bank: ADC input, its small register port (4-bit address, phase increment of receiver r at
    // 2r and its control word at 2r + 1) and its shared output stream
    reg  [11:0] adc_data = 12'd0;
    reg         adc_valid = 1'b0;
    reg         b_wr = 1'b0;
    reg  [3:0]  b_addr = 4'd0;
    reg  [31:0] b_wdata = 32'd0;
    wire        s_valid;
    wire [2:0]  s_index;
    wire signed [23:0] s_i, s_q;
    rx_bank #(.N(8), .ADC_WIDTH(12), .FIR_COEFF_FILE("rtl/rx/fir_coeffs.hex")) u_bank (
        .clock(clk), .rst(rst), .adc_data(adc_data), .adc_valid(adc_valid),
        .reg_wr(b_wr), .reg_addr(b_addr), .reg_wdata(b_wdata),
        .out_valid(s_valid), .out_index(s_index), .out_i(s_i), .out_q(s_q)
    );

    // back end, fed from the bank stream until the model's last clock (feed goes low), then left to finish
    reg         feed = 1'b1;
    reg  [47:0] hl2_index = 48'h0007_0000_0000;
    reg         reg_wr = 1'b0, reg_rd = 1'b0;
    reg  [15:0] reg_addr = 16'd0;
    reg  [31:0] reg_wdata = 32'd0;
    wire [31:0] reg_rdata;
    wire        out_valid, out_iq, irq;
    wire [2:0]  out_rx;
    wire [15:0] out_s0, out_s1;
    wire [47:0] out_stamp;
    rx_backend dut (
        .clk(clk), .rst(rst),
        .in_valid(s_valid && feed), .in_index(s_index), .in_i(s_i), .in_q(s_q), .hl2_index(hl2_index),
        .reg_wr(reg_wr), .reg_rd(reg_rd), .reg_addr(reg_addr), .reg_wdata(reg_wdata), .reg_rdata(reg_rdata),
        .out_valid(out_valid), .out_rx(out_rx), .out_s0(out_s0), .out_s1(out_s1), .out_iq(out_iq),
        .out_stamp(out_stamp),
        .ring_req(), .ring_addr(), .ring_burstlen(), .ring_wdata(), .ring_wmask(),
        .ring_gnt(1'b0), .ring_done(1'b0), .irq(irq)
    );

    // One full period of a sine in 1,024 entries of 18 bits; the top 10 bits of a phase accumulator
    // index it.
    reg [17:0] sine [0:1023];
    initial $readmemh("sim/rx_backend/bk_sine.hex", sine);
    // One step of the xorshift32 generator, identical to the one in the models.
    function [31:0] xs;
        input [31:0] x;
        reg [31:0] v;
        begin
            v = x ^ (x << 13);
            v = v ^ (v >> 17);
            xs = v ^ (v << 5);
        end
    endfunction

    // Register write of the back end, one clock wide.
    task wr(input [15:0] a, input [31:0] d);
        begin
            @(posedge clk); reg_wr <= 1'b1; reg_addr <= a; reg_wdata <= d;
            @(posedge clk); reg_wr <= 1'b0;
        end
    endtask
    task rd(input [15:0] a, output [31:0] d);
        begin
            @(posedge clk); reg_rd <= 1'b1; reg_addr <= a;
            @(posedge clk); reg_rd <= 1'b0;
            @(posedge clk);
            // Five extra clocks of waiting: the DUT registers the bus once, latches the read address,
            // and its read multiplexer takes two clocks per step (first by receiver, then by field) as
            // two-clock paths (see "register bus" in rx_backend.v), so read data is valid six clocks
            // after reg_rd, not one.
            repeat (3) @(posedge clk);
            @(posedge clk);
            @(posedge clk); d = reg_rdata;
        end
    endtask

    // Output check: every output word and the stamp offset (output stamp minus the stamp stored for the
    // receiver) go into a per-receiver FNV-1a style hash, start value 0x811C9DC5 and prime 0x01000193,
    // the same hash the model computes over its outputs.
    reg [31:0] hash [0:7];
    integer    cnt_out [0:7];
    reg [47:0] soff;
    always @(posedge clk)
        if (out_valid) begin
            soff = out_stamp - dut.m_stamp.mem[out_rx];
            hash[out_rx] = (hash[out_rx] ^ {out_s1, out_s0}) * 32'h0100_0193;
            hash[out_rx] = (hash[out_rx] ^ soff[31:0]) * 32'h0100_0193;
            cnt_out[out_rx] = cnt_out[out_rx] + 1;
        end
    // Counters on the bank's output stream: bank samples seen, samples that repeat the previous clock's
    // sample exactly, and samples that appear after adc_valid has stopped. ccount and vcount count the
    // clocks and the valid clocks of the stream, and +showbank prints every bank sample for debugging.
    integer    repeats = 0, bank_samples = 0, drain_samples = 0;
    reg        drain_phase = 1'b0;
    reg        pv = 1'b0;
    reg [50:0] pd;
    integer stream_t0 = -1, shown = 0, ccount = 0, vcount = 0;
    always @(posedge clk) if (stream_t0 >= 0) begin
        ccount = ccount + 1;
        if (adc_valid) vcount = vcount + 1;
    end
    always @(posedge clk) begin
        if (s_valid && feed) begin
            if ($test$plusargs("showbank")) begin
                $display("B %0d %0d %0d C %0d V %0d", s_index, s_i, s_q, ccount, vcount);
                shown = shown + 1;
            end
            bank_samples = bank_samples + 1;
            if (drain_phase) drain_samples = drain_samples + 1;
            if (pv && pd == {s_index, s_i, s_q}) repeats = repeats + 1;
        end
        pv = s_valid;
        pd = {s_index, s_i, s_q};
    end

    integer r, n, m, errors;
    reg [31:0] v, ci, cq, crng, vrng, rng;
    reg [31:0] ph [0:3];
    reg [9:0]  cidx;
    integer    vleft;
    reg        vstate;
    reg signed [63:0] acc;
    initial begin
        errors = 0;
        scn_load;
        for (r = 0; r < 8; r = r + 1) begin
            hash[r] = 32'h811C_9DC5; cnt_out[r] = 0;
        end
        // reset for 5 clocks, as the model does
        repeat (5) @(posedge clk);
        rst <= 1'b0;
        // back end first while the bank is still disabled: coefficient banks (unit n / 6, bank n % 6,
        // length and exponent, then I and Q of each tap, random or from the sine table as in the
        // back end bench), the receiver settings, and the enable bit
        for (n = 0; n < 12; n = n + 1) begin
            wr(`RX_BACKEND_COEF_SEL_ADDR, ((n % 6) << 1) | (n / 6));
            wr(`RX_BACKEND_BANK_CFG_ADDR(n), bk_ntaps[n] | (bk_exp[n] << 12));
            crng = bk_seed[n] | 1;
            for (m = 0; m < bk_ntaps[n]; m = m + 1) begin
                if (bk_kind[n] == 0) begin
                    crng = xs(crng); ci = $signed(crng) >>> bk_shift[n];
                    crng = xs(crng); cq = $signed(crng) >>> bk_shift[n];
                end else begin
                    cidx = (m * bk_step[n]) & 1023;
                    ci = $signed(sine[(cidx + 10'd256) & 10'd1023]) <<< bk_shift[n];
                    cq = $signed(sine[cidx]) <<< bk_shift[n];
                end
                wr(`RX_BACKEND_COEF_OFFSET + 8 * m, ci);
                wr(`RX_BACKEND_COEF_OFFSET + 8 * m + 4, cq);
            end
        end
        for (r = 0; r < 8; r = r + 1) begin
            wr(`RX_BACKEND_NB_ADDR(r), cfg_nb[r]);
            wr(`RX_BACKEND_NB_HOLD_ADDR(r), cfg_hold[r]);
            wr(`RX_BACKEND_AGC_ATTACK_ADDR(r), cfg_att[r]);
            wr(`RX_BACKEND_AGC_DECAY_ADDR(r), cfg_dec[r]);
            wr(`RX_BACKEND_AGC_HANG_ADDR(r), cfg_hang[r]);
            wr(`RX_BACKEND_AGC_REF_ADDR(r), cfg_ref[r]);
            wr(`RX_BACKEND_AGC_GMAX_ADDR(r), cfg_gmax[r]);
            wr(`RX_BACKEND_AGC_GMIN_ADDR(r), cfg_gmin[r]);
            wr(`RX_BACKEND_AGC_MANUAL_ADDR(r), cfg_gman[r]);
            wr(`RX_BACKEND_LOOPS_ADDR(r), cfg_loops[r]);
            wr(`RX_BACKEND_FM_DEEMPH_ADDR(r), cfg_deemph[r]);
            wr(`RX_BACKEND_SQUELCH_ADDR(r), cfg_sq[r]);
            wr(`RX_BACKEND_CTRL_ADDR(r), cfg_ctrl[r] | 32'd1);
        end
        // bank registers, one per clock while adc_valid is low: phase increment, then the control word
        // that enables the channel and sets its rate
        for (r = 0; r < 8; r = r + 1) begin
            @(posedge clk); b_wr <= 1'b1; b_addr <= r << 1; b_wdata <= bank_inc[r];
            @(posedge clk); b_wr <= 1'b1; b_addr <= (r << 1) | 1; b_wdata <= 4 | bank_rate[r];
        end
        @(posedge clk); b_wr <= 1'b0;
        // ADC stream: CHAIN_CYCLES clocks, a new sample on each valid clock
        vrng = 32'h2545_F491; vleft = 0; vstate = 1'b0; rng = 32'h1234_5679;
        for (m = 0; m < 4; m = m + 1) ph[m] = 0;
        stream_t0 = $time;
        for (n = 0; n < CHAIN_CYCLES; n = n + 1) begin
            if (vleft == 0) begin
                vrng = xs(vrng);
                vstate = !vstate;
                vleft = vstate ? 1 + (vrng % 48) : 1 + (vrng % 46);
            end
            vleft = vleft - 1;
            // Sum of four tones (amplitude * sine / 2^17 gives a peak of the amplitude) and noise
            // shifted down by noise_shift, clipped to the signed 12-bit range of the ADC.
            if (vstate) begin
                acc = 0;
                for (m = 0; m < 4; m = m + 1) begin
                    acc = acc + (($signed(tone_amp[m]) * $signed(sine[ph[m][31:22]])) >>> 17);
                    ph[m] = ph[m] + tone_inc[m];
                end
                rng = xs(rng);
                acc = acc + ($signed(rng) >>> noise_shift);
                if (acc > 2047) acc = 2047;
                if (acc < -2048) acc = -2048;
                adc_data <= acc[11:0];
                adc_valid <= 1'b1;
                hl2_index <= hl2_index + 48'd1;
            end else
                adc_valid <= 1'b0;
            @(posedge clk);
        end
        // Stop the stream and wait CHAIN_DRAIN clocks with no valid input so that anything still in
        // flight comes out; bank samples that appear now are counted as drain_samples.
        adc_valid <= 1'b0;
        drain_phase = 1;
        repeat (CHAIN_DRAIN) @(posedge clk);
        feed <= 1'b0;
        repeat (30000) @(posedge clk);

        // Compare with the models, per receiver: output count and hash, S-meter (bits 15:0 of the
        // status word) with squelch (bit 16), AGC gain and blanked count.
        for (r = 0; r < 8; r = r + 1) begin
            if (cnt_out[r] != exp_count[r] || hash[r] !== exp_hash[r]) begin
                $display("FAIL rx%0d: %0d outputs, hash %08x; models %0d outputs, hash %08x", r, cnt_out[r], hash[r], exp_count[r], exp_hash[r]);
                errors = errors + 1;
            end
            rd(`RX_BACKEND_RX_STATUS_ADDR(r), v);
            if ($signed(v[15:0]) != exp_smeter[r] || v[16] != exp_sq[r]) begin
                $display("FAIL rx%0d: S-meter %0d squelch %0d; models %0d %0d", r, $signed(v[15:0]), v[16], exp_smeter[r], exp_sq[r]);
                errors = errors + 1;
            end
            rd(`RX_BACKEND_AGC_GAIN_ADDR(r), v);
            if ($signed(v) != exp_gain[r]) begin
                $display("FAIL rx%0d: AGC gain %0d; models %0d", r, $signed(v), exp_gain[r]);
                errors = errors + 1;
            end
            rd(`RX_BACKEND_BLANKED_ADDR(r), v);
            if (v != exp_blanked[r]) begin
                $display("FAIL rx%0d: blanked %0d; models %0d", r, v, exp_blanked[r]);
                errors = errors + 1;
            end
        end
        // FIFO overflow flags of the back end must be clear.
        rd(`RX_BACKEND_STATUS_ADDR, v);
        if (v != 0) begin
            $display("FAIL: overflow flags %b", v[3:0]);
            errors = errors + 1;
        end
        $display("r4_chain: %0d stream clocks (%0d ADC samples) + %0d clocks without adc_valid; bank samples %0d, of which %0d repeated on the next clock and %0d emitted after adc_valid stopped",
                 CHAIN_CYCLES, vcount, CHAIN_DRAIN, bank_samples, repeats, drain_samples);
        $display("outputs per receiver: %0d %0d %0d %0d %0d %0d %0d %0d",
                 cnt_out[0], cnt_out[1], cnt_out[2], cnt_out[3], cnt_out[4], cnt_out[5], cnt_out[6], cnt_out[7]);
        // Regression checks for the bank: no sample may repeat on the next clock, and none may be
        // emitted after adc_valid has stopped, because the bank decimates by counting adc_valid pulses
        // and not clocks. Both counters are exactly 0 on a correct bank, and CHAIN_DRAIN is long enough
        // for the back end to finish the last accepted sample.
        if (repeats != 0) begin
            $display("FAIL: %0d bank samples repeated on the next clock (rx_bank arbiter regression -- R4_BACKEND.md section 9 defect 2)", repeats);
            errors = errors + 1;
        end
        if (drain_samples != 0) begin
            $display("FAIL: %0d bank samples emitted after adc_valid stopped (receiver-bank decimate-by-clock regression -- R4_BACKEND.md section 9 defect 1)", drain_samples);
            errors = errors + 1;
        end
        if (errors == 0) $display("PASS"); else $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
