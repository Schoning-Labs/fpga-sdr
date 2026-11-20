// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Transmit rate lock: decides, sample by sample, when the transmit chain may produce its next
// sample, so that the Hermes-Lite 2's transmit FIFO neither runs empty nor overflows
// (docs/ARCHITECTURE.md 3.6 point 3).
//
// The problem: the HL2 plays one transmit sample per tick of its own 76.8 MHz ADC clock, taken
// from a FIFO that we fill with frames (tx_sample_framer.v). Our clocks come from a different
// crystal, so a rate generated from them would drift against the HL2's, and the FIFO would slowly
// fill up or run dry. The HL2's own ADC clock is the one reference both directions share, since
// the samples that we receive come in at that rate.
//
// How it works, in two parts:
//   1. The rate lock proper. `pace` follows `rx_adc_valid`, the strobe of the received sample
//      stream (hl2_link_rx_top.v's `samp_out_valid`, which averages 76.8 Msps although it is
//      bursty within clk_dsp). The transmit chain (tx_chain.v) produces one output sample per
//      `pace` pulse, and tx_sample_framer.v takes it as its `in_valid`, so both directions run on
//      one sample clock by construction, one hop apart (received samples for RX, played-back
//      samples for TX, over the same physical link). Over the long run this alone matches the far
//      end's DAC rate.
//   2. The fill trim. In addition, the HL2 reports the fill of its transmit FIFO in every raw
//      frame header (PROTOCOL.md 6.3 bytes 32 and 33, carried to clk_dsp by rx_tx_fill_bridge.v
//      as `fifo_fill`), and the trim nudges the rate so that the fill settles around
//      TARGET_FILL (12,000 samples, the target the PC tool of the HL2 project also uses). It is
//      needed for the start-up (PROTOCOL.md 6.4), when the FIFO has to grow from 0 to the target,
//      and for the occasional disturbance.
//
// Trim mechanism: a proportional controller, re-evaluated (not accumulated) on every received fill
// update, about every 12.6 to 78 us: `pending <= clamp(-error >>> GAIN_SHIFT)`. `pending` is a
// signed count of samples still owed (positive: send extra samples ahead of real time, negative:
// hold some back), and it is drained at most one per `COOLDOWN` clk_dsp clocks. A positive
// `pending` steals an idle clock (one where `rx_adc_valid` is already 0) to insert one extra
// `pace` pulse, and a negative one swallows one `rx_adc_valid` pulse to skip one. The parameter
// FILL_BAND (and the wire `band_s` made from it) is a place for a deadband around the target, but the
// control law as built corrects in proportion to the whole error and does not use it.
//
// Why the corrections are rate limited: how fast the trim may close a deficit is set by the
// wire and not by the clk_dsp clock. The link carries about 930 Mbit/s against the 921.6 Mbit/s
// that the sample rate itself needs (docs/rawfront/PROTOCOL.md 5.7), which leaves only about 0.9 %
// of spare capacity, roughly 700 ksps. Inserting extra samples faster than that does not make the
// frames reach the HL2 any sooner, since the send time of a frame is fixed by the bit rate of the
// wire. It only piles more samples into tx_sample_framer.v's FIFO than the sender drains, and the
// overflow is silently dropped. Spacing the corrections `COOLDOWN` clocks apart keeps the
// average extra rate within the real margin of the link however large the outstanding correction
// is: at 256 clocks that is 120e6 / 256 = 469 ksps, inside the 700 ksps with some margin, and a
// full 12,000-sample start-up deficit closes in about 12,000 x 256 / 120e6 = 26 ms.
//
// Why `pending` is replaced and not added to: each fill update would otherwise add a full step on
// top of the corrections that are still queued, because the fill measurement has not yet seen the
// effect of what was queued before (COOLDOWN lets only a handful of samples drain per update
// period, far fewer than a large error asks for). That is integrator windup, and it saturates
// `pending` at `PENDING_MAX` and overshoots the target when the backlog finally drains. A fresh,
// error-proportional value in every update is always bounded by the current error alone, so it
// settles cleanly, and convergence speed is unchanged, because it is set by the drain rate of
// COOLDOWN and not by the gain.
//
// Counters for the firmware: `cnt_fill_updates` (fill reports received), `cnt_insert` (extra
// samples sent) and `cnt_skip` (samples held back).

`timescale 1ns / 1ps

module tx_rate_lock #(
    parameter [15:0] TARGET_FILL  = 16'd12000,  // PROTOCOL.md 6.4: the target fill of the HL2's TX FIFO, in samples
    parameter [15:0] FILL_BAND    = 16'd1000,   // deadband either side of TARGET_FILL (not used by the control law, see header)
    parameter        GAIN_SHIFT   = 0,          // proportional gain = 1/2**GAIN_SHIFT (see header:
                                                 // COOLDOWN, not this gain, sets convergence speed)
    parameter        PENDING_MAX  = 17'sd16000, // clamp on the outstanding correction
    parameter        COOLDOWN     = 256         // clk_dsp cycles between corrections (see header:
                                                 // ~120e6/256 = 469 ksps, inside the link's ~700
                                                 // ksps of real spare capacity with some margin)
) (
    input  wire        clk_dsp,           // 120 MHz
    input  wire        rst_dsp,           // synchronous reset, active high

    input  wire        rx_adc_valid,      // hl2_link_rx_top.v samp_out_valid
    input  wire [15:0] fifo_fill,         // hl2_link_rx_top.v raw_tx_fifo_fill (clk_dsp already)
    input  wire        fifo_fill_valid,   // one clk_dsp pulse per new fill value

    output wire        pace,              // to tx_chain.v `pace` and tx_sample_framer.v `in_valid`

    output reg  [31:0] cnt_fill_updates,  // fill reports received
    output reg  [31:0] cnt_skip,          // samples held back
    output reg  [31:0] cnt_insert         // extra samples sent
) /* synthesis syn_srlstyle = "registers" */;

    reg signed [16:0] pending = 17'sd0;   // samples still owed: >0 send extra, <0 hold back

    // The error is the reported fill minus the target, as signed 17-bit numbers (one bit wider
    // than the 16-bit fill, so the subtraction cannot overflow).
    wire signed [16:0] fill_s   = {1'b0, fifo_fill};
    wire signed [16:0] target_s = {1'b0, TARGET_FILL};
    wire signed [16:0] band_s   = {1'b0, FILL_BAND};
    wire signed [16:0] err      = fill_s - target_s;   // >0: fill too high, send less; <0: send more

    // Directly proportional to the current error and not accumulated (see header): a high fill
    // (err>0) gives a negative target (hold back), a low fill (err<0) a positive one (send extra).
    wire signed [16:0] pending_target = (-err) >>> GAIN_SHIFT;   // arithmetic shift: rounds toward -inf
    wire signed [16:0] pending_clamped =
        (pending_target >  PENDING_MAX) ?  PENDING_MAX :
        (pending_target < -PENDING_MAX) ? -PENDING_MAX :
        pending_target;

    // The cooldown counter: counts down to 0 after every correction, and a new correction may only
    // be made when it is 0.
    reg [15:0] cooldown_cnt = 16'd0;
    wire       cooldown_done = (cooldown_cnt == 16'd0);

    // "Cooldown over and something owed" is decided one clock ahead, in two flags (ins_armed and
    // skip_armed), and the new target is registered (target_r, with its strobe target_v) before it
    // is loaded. Doing the 16-bit cooldown compare, the sign test of `pending`, the decision and
    // the 17-bit add back into `pending` in one clock would be 12 logic levels, which does not fit
    // in a clk_dsp period, and the result also feeds tx_chain's pace. So an insert or skip comes at
    // the earliest two clocks after the cooldown ends or a new fill value arrives instead of at
    // once, and since the cooldown is hundreds of clocks, the rate does not change.
    reg ins_armed = 1'b0, skip_armed = 1'b0;
    reg signed [16:0] target_r = 17'sd0;
    reg               target_v = 1'b0;
    wire do_insert = ins_armed  && !rx_adc_valid;
    wire do_skip   = skip_armed &&  rx_adc_valid;
    always @(posedge clk_dsp) begin
        target_r <= pending_clamped;
        target_v <= fifo_fill_valid && !rst_dsp;
        if (rst_dsp || target_v || do_insert || do_skip) begin
            ins_armed  <= 1'b0;
            skip_armed <= 1'b0;
        end else begin
            ins_armed  <= cooldown_done && (pending > 17'sd0);
            skip_armed <= cooldown_done && (pending < 17'sd0);
        end
    end

    always @(posedge clk_dsp) begin
        if (rst_dsp) begin
            pending          <= 17'sd0;
            cooldown_cnt     <= 16'd0;
            cnt_fill_updates <= 32'd0;
            cnt_skip         <= 32'd0;
            cnt_insert       <= 32'd0;
        end else begin
            if (cooldown_cnt != 16'd0) cooldown_cnt <= cooldown_cnt - 16'd1;

            // A new fill value (`target_v`) takes priority over draining `pending` by one in the
            // same clock, because both want the last say over the same register. The send
            // decision of that clock is not affected either way, since `do_insert` and `do_skip`
            // are already combinationally in `pace` from before the new value is folded in. The
            // choice only decides whether `pending` also drains in this one clock (deferred by
            // one clock when they collide) or takes the new value at once. Fill updates arrive
            // thousands of clocks apart, so giving them priority costs at most one clock of drain
            // progress, which cannot be observed.
            if (target_v) begin
                pending          <= target_r;
                cnt_fill_updates <= cnt_fill_updates + 32'd1;
            end else if (do_insert) begin
                pending      <= pending - 17'sd1;
                cooldown_cnt <= COOLDOWN[15:0] - 16'd1;
                cnt_insert   <= cnt_insert + 32'd1;
            end else if (do_skip) begin
                pending      <= pending + 17'sd1;
                cooldown_cnt <= COOLDOWN[15:0] - 16'd1;
                cnt_skip     <= cnt_skip + 32'd1;
            end
        end
    end

    // The pace: the received sample strobe, plus one pulse when inserting, minus one when skipping.
    assign pace = do_insert ? 1'b1 : do_skip ? 1'b0 : rx_adc_valid;

endmodule
