// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Carries the fill level of the Hermes-Lite 2's transmit FIFO from the receive side of the HL2
// link to the transmit side's rate control.
//
// Why it exists: the HL2 plays one transmit sample per tick of its own ADC clock, out of a FIFO
// that we fill with the frames we send (docs/rawfront/PROTOCOL.md section 6). To keep that FIFO
// from running empty or overflowing, tx_rate_lock.v needs to know how full it is, and the HL2
// reports that in the header of every raw frame it sends us (version 3 header, bytes 32 and 33,
// "TX FIFO fill", PROTOCOL.md 6.3). eth_frame_rx.v picks the value out of the header in the clk_rx
// domain, but the rate control lives in clk_dsp, so the value has to change clock domains.
//
// How it works: a version 3 raw frame updates the value at most once per frame, which at gigabit
// rate is once every 12.6 us to 78 us, far slower than either clock, so the toggle handshake of
// cdc_word.v (which explains how it works) is the right tool. The value is sent when a raw frame
// has just been committed (a frame with a bad CRC never updates it) and only if its header
// version is not 1, because a version 1 header (20 bytes) has no such field.
//
// Where it sits: the chip's top level instantiates it between hl2_link_rx_top.v and
// hl2_link_tx_top.v, connecting `raw_version`, `raw_tx_fifo_fill` and `raw_commit_pulse` of the
// first to its inputs and `fifo_fill` and `fifo_fill_valid` to the second. Latency: three to four
// clk_dsp clocks after the commit pulse.

`timescale 1ns / 1ps

module rx_tx_fill_bridge (
    input  wire        clk_rx,
    input  wire [ 7:0] raw_version,        // hl2_link_rx_top.v raw_version
    input  wire [15:0] raw_tx_fifo_fill,   // hl2_link_rx_top.v raw_tx_fifo_fill
    input  wire        raw_commit_pulse,   // hl2_link_rx_top.v raw_commit_pulse

    input  wire        clk_dsp,
    output wire [15:0] fifo_fill,          // the HL2's transmit FIFO fill in samples, in clk_dsp
    output wire         fifo_fill_valid    // one-clock pulse in clk_dsp: fifo_fill has just been updated
) /* synthesis syn_srlstyle = "registers" */;

    // Send only for a committed raw frame whose header has the field (not version 1).
    wire has_fill = raw_commit_pulse && (raw_version != 8'h01);

    cdc_word #(.W(16)) cdc_i (
        .clk_a(clk_rx), .d_a(raw_tx_fifo_fill), .send_a(has_fill),
        .clk_b(clk_dsp), .q_b(fifo_fill), .valid_b(fifo_fill_valid)
    );

endmodule
