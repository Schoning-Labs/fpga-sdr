// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Gap filler: turns the sample stream of the Hermes-Lite 2, in which whole frames can be missing,
// into a continuous stream in which every sample sits at its exact place in time. A frame can go
// missing because it was lost on the line, because the copper module in the SFP cage dropped it,
// or because eth_frame_rx.v threw it away for a bad CRC.
//
// Why it matters: the receivers behind this block (the numerically controlled oscillators that
// shift each station down to baseband, the filters, the FFT) all assume one sample per tick of the
// HL2's 76.8 MHz ADC clock. If 968 samples are missing and nothing replaces them, the phase of
// every oscillator jumps and every filter sees a click. Zeros are not the true signal, but they
// keep the timing exact, so the damage is limited to the missing stretch (at most one frame, about
// 12.6 us at 968 samples and 78 us at 5,968 samples) and everything behind it carries on cleanly.
//
// Where it sits (docs/ARCHITECTURE.md 3.1 step 4): it runs on clk_dsp (120 MHz) and is fed by
// raw_frame_buffer.v through cdc_sample_fifo.v. It pops samples, and for the first sample of each
// committed frame (the FIFO word tagged `sof`) it also pops the frame's 48-bit first-sample index
// from the matching index FIFO. The HL2 counts every ADC clock since the stream started, so
// consecutive frames carry indices that differ by exactly N. This module keeps `expected_idx`, the
// index that the next sample should have, and compares:
//   - the same as expected: the frame follows its predecessor, nothing to do;
//   - ahead by k, with k up to RESYNC_THRESHOLD (65,536): k samples are missing, and k zero
//     samples are inserted before the real one, each marked with `out_is_fill`. This is a gap
//     event, counted in cnt_gap_events and cnt_gap_samples;
//   - ahead by more than that, or behind: the index is trusted to have restarted (for example the
//     HL2 was restarted). No fill is inserted, because filling tens of thousands of clocks would
//     stall everything else, `expected_idx` simply jumps, and it is counted as a resync.
// In both cases `irq_gap` pulses once (interrupt line 1 of the CPU's interrupt controller). The
// very first frame after reset only sets the baseline.
//
// Throughput: one sample per clk_dsp clock (120 M/s), comfortably above the 76.8 Msps at which
// the samples arrive, so the sample FIFO only backs up during a zero fill and then drains again
// (the fill itself is also 120 M samples/s, so it catches up faster than real time). The sample
// FIFO's read port has one clock of latency (`samp_valid` follows `samp_pop`), so pops are issued
// ahead into a 4-word input queue, on credit: a pop goes out only if the queue has room for it
// even if nothing more is taken out. That keeps a pop going out in every clock while samples flow
// and stops them cleanly when the state machine stalls (waiting for an index, filling). Popping a
// sample, waiting for it and only then popping the next would need three clocks per sample, or
// 40 M/s, which is below the stream rate.
//
// Timing: the check of a frame's index against the expected index is spread over four clocks of
// registers, because doing it in one (a 48-bit subtract, a 48-bit compare against the threshold
// and the selection into expected_idx) is 16 logic levels, which does not fit in a clk_dsp
// period. S_WAIT_IDX latches the index, S_DIFF subtracts, S_FLAG turns the difference into three
// flags, and S_DECIDE acts on them. The input queue holds the samples meanwhile, and since the
// stream runs at 64 % of the clock rate, the queue drains again within the frame. The fill counter
// is only as wide as the threshold needs (17 bits), not 48.

`timescale 1ns / 1ps

module gap_filler #(
    parameter RESYNC_THRESHOLD = 48'd65536   // largest jump that is filled with zeros, in samples
) (
    input  wire        clk,        // clk_dsp, 120 MHz
    input  wire        rst,        // synchronous reset, active high

    // raw_frame_buffer.v pop interface (the sample FIFO and the index FIFO behind it)
    output reg          samp_pop,    // request one sample from the sample FIFO
    input  wire          samp_sof,   // the popped sample is the first one of a committed frame
    input  wire [11:0]   samp_data,  // 12-bit two's complement ADC sample
    input  wire           samp_valid, // samp_data holds the sample requested by samp_pop a clock earlier

    output reg          idx_pop,     // request the frame's index from the index FIFO
    input  wire [47:0]   idx_data,   // first-sample index of the frame
    input  wire           idx_valid, // idx_data is valid

    // continuous output stream (to the receiver bank, spectrum and FT8 front end)
    output reg  [11:0] out_sample,   // 12-bit sample, zero for fill
    output reg          out_valid,   // one-clock pulse per sample (up to one per clock)
    output reg          out_is_fill,    // this cycle's sample is zero-fill, not a real ADC sample

    output reg  [47:0] expected_idx,     // index the next sample should have
    output reg  [31:0] cnt_gap_events,   // frames that were filled
    output reg  [31:0] cnt_gap_samples,  // zero samples inserted
    output reg  [31:0] cnt_resync_events, // jumps too large (or backward) to fill
    output reg          irq_gap           // one-cycle pulse per gap or resync event (PLIC line 1)
);

    // Control states:
    //   S_RUN       samples go through, the first sample of a frame sends us on to fetch its index
    //   S_WAIT_IDX  waiting for the index FIFO to deliver the frame's index
    //   S_DIFF      subtract the expected index from the frame's index
    //   S_FLAG      turn the difference into flags (zero, fillable)
    //   S_DECIDE    act: baseline, in sequence, fill, or resync
    //   S_FILLING   emit zeros, one per clock, until the gap is closed
    //   S_EMIT_REAL emit the held first sample of the frame after the fill
    localparam S_RUN       = 3'd0,
               S_DIFF      = 3'd1,
               S_WAIT_IDX  = 3'd2,
               S_FILLING   = 3'd3,
               S_EMIT_REAL = 3'd4,
               S_FLAG      = 3'd5,
               S_DECIDE    = 3'd6;
    localparam GW = $clog2(RESYNC_THRESHOLD + 1);   // bits of the largest gap that is filled

    reg [2:0]  state = S_RUN;
    reg [11:0] held_sample = 12'd0;  // first sample of the frame, held while its index is checked
    reg [GW-1:0] gap_remaining = {GW{1'b0}};   // zero samples still to insert
    reg [47:0] idx_r = 48'd0;        // the frame's index, latched
    reg [48:0] diff = 49'd0;         // idx_r - expected_idx, one bit wider: bit 48 = index went back
    reg        f_zero = 1'b0, f_fill = 1'b0;   // flags: in sequence; a forward jump small enough to fill
    reg        started = 1'b0;   // true once the first real sample has been seen (there is no gap
                                  // check before that, since there is no "expected index" yet)

    // ---- input queue: 4 words of {sof, sample} ----
    reg [12:0] q_mem [0:3];
    reg [1:0]  q_wp = 2'd0, q_rp = 2'd0;   // write and read pointers
    reg [2:0]  q_cnt = 3'd0;               // words held
    wire        q_head_sof  = q_mem[q_rp][12];
    wire [11:0] q_head_data = q_mem[q_rp][11:0];
    wire        q_nonempty  = (q_cnt != 3'd0);

    // The state machine takes the head word in this clock (every case below that uses it).
    wire deq = q_nonempty && (state == S_RUN);
    wire [2:0] q_cnt_next = q_cnt + {2'd0, samp_valid} - {2'd0, deq};
    // Credit check: the words queued after this clock edge, plus the pop the FIFO is serving now,
    // plus this new one, must fit in the four places of the queue.
    wire pop_ok = ({1'b0, q_cnt_next} + {3'd0, samp_pop} + 4'd1) <= 4'd4;

    always @(posedge clk) begin
        if (rst) begin
            q_wp <= 2'd0; q_rp <= 2'd0; q_cnt <= 3'd0;
            samp_pop <= 1'b0;
        end else begin
            if (samp_valid) begin
                q_mem[q_wp] <= {samp_sof, samp_data};
                q_wp <= q_wp + 2'd1;
            end
            if (deq) q_rp <= q_rp + 2'd1;
            q_cnt    <= q_cnt_next;
            samp_pop <= pop_ok;
        end
    end

    // The state machine and the output stream. The pulses default to 0 in every clock.
    always @(posedge clk) begin
        idx_pop       <= 1'b0;
        out_valid     <= 1'b0;
        out_is_fill   <= 1'b0;
        irq_gap       <= 1'b0;

        if (rst) begin
            state        <= S_RUN;
            started      <= 1'b0;
            expected_idx <= 48'd0;
            cnt_gap_events    <= 32'd0;
            cnt_gap_samples   <= 32'd0;
            cnt_resync_events <= 32'd0;
        end else begin
            case (state)
                S_RUN: begin
                    if (deq) begin
                        if (q_head_sof) begin
                            // First sample of a committed frame: fetch its index before letting it
                            // out. The very first frame ever is included, since it becomes the
                            // baseline.
                            held_sample <= q_head_data;
                            idx_pop     <= 1'b1;
                            state       <= S_WAIT_IDX;
                        end else begin
                            out_sample   <= q_head_data;
                            out_valid    <= 1'b1;
                            expected_idx <= expected_idx + 48'd1;
                        end
                    end
                end

                S_WAIT_IDX: begin
                    if (idx_valid) begin
                        idx_r <= idx_data;
                        state <= S_DIFF;
                    end
                    // The index FIFO was empty when popped (it is written in the same clk_rx
                    // clock as the sof sample, but crosses on its own synchronizer): pop again.
                    else if (!idx_pop) idx_pop <= 1'b1;
                end

                S_DIFF: begin
                    diff  <= {1'b0, idx_r} - {1'b0, expected_idx};
                    state <= S_FLAG;
                end

                S_FLAG: begin
                    f_zero <= (diff == 49'd0);
                    f_fill <= !diff[48] && (diff[47:0] <= RESYNC_THRESHOLD);   // forward, small enough
                    state  <= S_DECIDE;
                end

                S_DECIDE: begin
                    if (!started) begin
                        // The first frame after reset: its index is the baseline.
                        started      <= 1'b1;
                        expected_idx <= idx_r + 48'd1;
                        out_sample   <= held_sample;
                        out_valid    <= 1'b1;
                        state        <= S_RUN;
                    end else if (f_zero) begin
                        // In sequence: the first sample goes straight out.
                        out_sample   <= held_sample;
                        out_valid    <= 1'b1;
                        expected_idx <= expected_idx + 48'd1;
                        state        <= S_RUN;
                    end else if (f_fill) begin
                        // A fillable gap: count it, then insert zeros (diff counts them exactly).
                        gap_remaining     <= diff[GW-1:0];
                        cnt_gap_events    <= cnt_gap_events + 32'd1;
                        irq_gap           <= 1'b1;
                        state             <= S_FILLING;
                    end else begin
                        // Resync: too large a jump, or the index went backwards, which is also
                        // treated as a resync rather than trusted blindly.
                        expected_idx      <= idx_r + 48'd1;
                        cnt_resync_events <= cnt_resync_events + 32'd1;
                        irq_gap           <= 1'b1;
                        out_sample        <= held_sample;
                        out_valid         <= 1'b1;
                        state             <= S_RUN;
                    end
                end

                S_FILLING: begin
                    // One zero sample per clock, each flagged as fill, until the gap is closed.
                    out_sample      <= 12'd0;
                    out_valid       <= 1'b1;
                    out_is_fill     <= 1'b1;
                    expected_idx    <= expected_idx + 48'd1;
                    cnt_gap_samples <= cnt_gap_samples + 32'd1;
                    if (gap_remaining == {{(GW-1){1'b0}}, 1'b1}) begin
                        state <= S_EMIT_REAL;
                    end else begin
                        gap_remaining <= gap_remaining - 1'b1;
                    end
                end

                S_EMIT_REAL: begin
                    // The real first sample of the frame, now at its right place in time.
                    out_sample   <= held_sample;
                    out_valid    <= 1'b1;
                    expected_idx <= expected_idx + 48'd1;
                    state        <= S_RUN;
                end

                default: state <= S_RUN;
            endcase
        end
    end

endmodule
