// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// HL2 link receive path, top level (docs/ARCHITECTURE.md 3.1): everything between the bytes that
// the SFP lane's PCS delivers and the continuous 12-bit sample stream that the receivers use.
//
// The Hermes-Lite 2 (HL2) is the radio front end. It digitizes the antenna signal at 76.8 Msps
// and sends every 12-bit sample to this board in UDP datagrams over Ethernet, which is about 933
// Mbit/s on the wire, with no loss allowed. The HL2 is plugged into SFP cage 0 through a
// 1000BASE-T copper module, so the Ethernet bytes arrive through transceiver lane 0 and its PCS
// (rtl/sfp/sfp_phy.v), and `clk_rx` is the 125 MHz clock that the lane recovers from the line
// (docs/HL2_SFP.md).
//
// The chain, in the order the data travels:
//   gmii_rx_in.v       the PCS's bytes to a byte stream with a byte enable (clk_rx): preamble and
//                      start-of-frame delimiter removed.
//   eth_frame_rx.v     CRC-32 check, classifier (raw sample frame or something else) and
//                      raw-frame header parse (clk_rx).
//   raw_frame_buffer.v the sample bytes of good raw frames are staged in a ring, unpacked to
//                      12-bit samples, and moved from clk_rx to clk_dsp.
//   gap_filler.v       a continuous sample stream on clk_dsp, with zeros in place of lost frames.
//   cpu_rx_ring.v      every frame that is not a raw sample frame, for the firmware (clk_rx).
// plus the transmit-safety-byte register and its change interrupt (docs/ARCHITECTURE.md 3.1
// step 5): every raw frame carries a byte that reports the HL2's transmit interlock (whether the
// transmitter is on, tripped or too hot), so the radio sees a change within one frame without any
// CPU involvement.
//
// The register interface here is a flat list of fields and not a bus slave. The register block
// generated from hw/regmap/ wraps it in the addressed register page the firmware reads
// (docs/ARCHITECTURE.md 4.1).
//
// `RING_AW` sizes only the port (how wide the address and write pointer bus of the caller is),
// kept at 14 bits so that nothing upstream of this module has to change width. The CPU ring
// itself is fixed at `CPU_RING_AW` = 12 (4 KB) regardless of `RING_AW`: a caller presenting a
// wider address simply addresses the same 4 KB repeatedly (top bits ignored), and `ring_wr_ptr`
// is zero-extended up to `RING_AW` bits.
//
// Clock domains: clk_rx for everything up to the sample FIFO inside raw_frame_buffer.v, clk_dsp
// (120 MHz) from there on. The only crossings are inside raw_frame_buffer.v (a Gray-coded FIFO
// and a held-word handshake, see cdc_sample_fifo.v and cdc_word.v).

`timescale 1ns / 1ps

module hl2_link_rx_top #(
    parameter RING_AW = 14
) (
    // clk_rx: transceiver lane 0's recovered word clock, 125 MHz (n1_rxc)
    input  wire        clk_rx,
    input  wire        rst_rx,       // synchronous reset for the clk_rx domain, active high

    // lane 0's PCS (rtl/sfp/sfp_phy.v), clk_rx: a byte is new in a clock with g_rx_ce
    input  wire [7:0]  g_rx_d,       // byte from the PCS
    input  wire        g_rx_dv,      // data valid (preamble through the last FCS byte)
    input  wire        g_rx_er,      // error in this byte
    input  wire        g_rx_ce,      // a new byte in this clock

    // clk_dsp: 120 MHz
    input  wire        clk_dsp,
    input  wire        rst_dsp,      // synchronous reset for the clk_dsp domain, active high

    // configuration (clk_rx domain; the caller is responsible for synchronizing a write from the
    // bus clock)
    input  wire [31:0] cfg_hl2_ip,   // IPv4 address of the HL2 (frames from other addresses are not raw)

    // continuous sample stream, clk_dsp (the receivers consume this)
    output wire [11:0] samp_out,         // 12-bit two's complement sample
    output wire         samp_out_valid,  // a sample is on samp_out in this clock
    output wire          samp_out_is_fill, // the sample is zero fill for a lost frame, not a real sample
    // HL2 sample index of the next expected sample (gap_filler expected_idx): the index of the
    // sample just output plus one. The receiver back end uses it for time stamps.
    output wire [47:0]  samp_index,

    // safety byte (clk_rx; PROTOCOL.md 5.4)
    output reg  [ 7:0] safety_byte,        // the HL2's transmit-safety byte from the newest good raw frame
    output reg          irq_safety_change, // one-clock pulse when the byte changed

    // Rate lock input: the duplex TX sink's reported FIFO fill (PROTOCOL.md 6.3 bytes 32-33),
    // valid together with raw_commit whenever raw_version is 3 (clk_rx; see eth_frame_rx.v)
    output wire [ 7:0] raw_version,        // header version of the newest raw frame
    output wire [15:0] raw_tx_fifo_fill,   // HL2 transmit FIFO fill, in samples
    output wire         raw_commit_pulse,  // one-clock pulse per committed raw frame

    // interrupts (clk_rx except irq_gap which is clk_dsp)
    output wire         irq_pkt_rx,     // PLIC line 0: a frame is waiting in the CPU ring
    output wire          irq_gap,        // PLIC line 1 (also covers resync)

    // counters, read by the firmware (docs/HL2_SFP.md section 6)
    output wire [31:0] cnt_crc_errors,      // frames dropped for a bad FCS or a code error
    output wire [31:0] cnt_raw_frames,      // raw frames committed
    output wire [31:0] cnt_other_frames,    // other frames committed to the CPU ring
    output wire [15:0] cnt_ring_frames,     // frames stored in the CPU ring
    output wire [15:0] cnt_ring_dropped,    // frames that did not fit in the CPU ring
    output wire [31:0] cnt_gap_events,      // lost frames that were filled
    output wire [31:0] cnt_gap_samples,     // zero samples inserted
    output wire [31:0] cnt_resync_events,   // index jumps too large to fill
    // loss accounting, clk_rx (docs/HL2_SFP.md section 6)
    output wire [31:0] cnt_seq_lost,        // raw frames missing by sequence number
    output wire [15:0] cnt_seq_restarts,    // sequence restarts
    output wire [15:0] cnt_code_frames,     // frames dropped for a code error
    output wire [15:0] cnt_len_errors,      // raw frames dropped for a wrong length
    output wire [15:0] cnt_hl2_missing,     // raw frames flagged by the HL2 as missing samples before them
    output wire [31:0] last_seq,            // sequence number of the newest committed raw frame
    output wire [15:0] cnt_drain_drops,     // committed frames not drained (previous one still draining)
    output wire [15:0] cnt_overruns,        // samples overwritten before they were drained
    output wire [15:0] cnt_idx_drops,       // frame indices lost (index FIFO full)
    output wire [15:0] hl2_ovf_count,       // the HL2's own FIFO overflow count from the last raw header

    // CPU receive ring read port (clk_rx)
    input  wire [RING_AW-1:0] ring_rd_addr,  // byte address to read
    output wire [7:0]          ring_rd_data, // that byte, one clock later
    output wire [RING_AW-1:0]  ring_wr_ptr   // byte address one past the newest committed frame
);

    // ---------------------------------------------------------------------
    // From the PCS's bytes to a frame byte stream.
    wire [7:0] phy_data;
    wire        phy_active, phy_ce, phy_err;

    gmii_rx_in gmii_i (
        .clk(clk_rx), .rst(rst_rx),
        .rx_d(g_rx_d), .rx_dv(g_rx_dv), .rx_er(g_rx_er), .rx_ce(g_rx_ce),
        .data(phy_data), .active(phy_active), .ce_o(phy_ce), .err(phy_err)
    );

    // Frame check, classifier and raw header parser. Its outputs go to the sample buffer (raw_*)
    // and to the CPU ring (other_*).
    wire        raw_sof, raw_sample_valid, other_sof, other_valid, other_eof;
    wire [7:0]  raw_sample_data, other_data;
    wire        raw_commit, other_commit;
    wire [7:0]  raw_flags, raw_tx_status;
    wire [31:0] raw_seq;
    wire [47:0] raw_first_idx;
    wire [15:0] raw_n, raw_ovf_cnt, raw_high_water;

    assign raw_commit_pulse = raw_commit;

    eth_frame_rx frame_rx_i (
        .clk       (clk_rx),
        .rst       (rst_rx),
        .data      (phy_data),
        .active    (phy_active),
        .ce        (phy_ce),
        .err       (phy_err),
        .cfg_hl2_ip(cfg_hl2_ip),

        .raw_sof         (raw_sof),
        .raw_sample_valid(raw_sample_valid),
        .raw_sample_data (raw_sample_data),
        .raw_commit      (raw_commit),
        .raw_flags       (raw_flags),
        .raw_tx_status   (raw_tx_status),
        .raw_seq         (raw_seq),
        .raw_first_idx   (raw_first_idx),
        .raw_n           (raw_n),
        .raw_ovf_cnt     (raw_ovf_cnt),
        .raw_high_water  (raw_high_water),
        .raw_version         (raw_version),
        .raw_tx_fifo_fill    (raw_tx_fifo_fill),

        .other_sof   (other_sof),
        .other_valid (other_valid),
        .other_data  (other_data),
        .other_eof   (other_eof),
        .other_commit(other_commit),

        .cnt_crc_errors  (cnt_crc_errors),
        .cnt_raw_frames  (cnt_raw_frames),
        .cnt_other_frames(cnt_other_frames),
        .cnt_seq_lost    (cnt_seq_lost),
        .cnt_seq_restarts(cnt_seq_restarts),
        .cnt_code_frames (cnt_code_frames),
        .cnt_len_errors  (cnt_len_errors),
        .cnt_hl2_missing (cnt_hl2_missing),
        .last_seq        (last_seq)
    );
    assign hl2_ovf_count = raw_ovf_cnt;

    // Safety byte: latched from every CRC-good raw frame (PROTOCOL.md 5.4). A bad frame never
    // reaches raw_commit, so a torn or garbage byte is never latched. The idle value after reset
    // is 0x01 ("transmit off"), and a change raises a one-clock interrupt pulse.
    always @(posedge clk_rx) begin
        irq_safety_change <= 1'b0;
        if (rst_rx) begin
            safety_byte <= 8'h01;   // PROTOCOL.md 5.4 idle value
        end else if (raw_commit) begin
            safety_byte <= raw_tx_status;
            if (raw_tx_status != safety_byte) irq_safety_change <= 1'b1;
        end
    end

    // ---------------------------------------------------------------------
    // Sample staging and the clock crossing to clk_dsp, then the gap filler.
    wire        samp_pop, samp_sof, samp_valid;
    wire [11:0] samp_data;
    wire        idx_pop, idx_valid;
    wire [47:0] idx_data;

    raw_frame_buffer buf_i (
        .clk_rx           (clk_rx),
        .rst_rx           (rst_rx),
        .raw_sof          (raw_sof),
        .sample_valid     (raw_sample_valid),
        .sample_data      (raw_sample_data),
        .commit           (raw_commit),
        .commit_first_idx (raw_first_idx),
        .commit_n         (raw_n),
        .cnt_committed_samples(),
        .cnt_drain_drops(cnt_drain_drops),
        .cnt_overruns   (cnt_overruns),
        .cnt_idx_drops  (cnt_idx_drops),

        .clk_dsp  (clk_dsp),
        .rst_dsp  (rst_dsp),
        .samp_pop (samp_pop),
        .samp_sof (samp_sof),
        .samp_data(samp_data),
        .samp_valid(samp_valid),
        .idx_pop  (idx_pop),
        .idx_data (idx_data),
        .idx_valid(idx_valid)
    );

    gap_filler gap_i (
        .clk (clk_dsp),
        .rst (rst_dsp),
        .samp_pop  (samp_pop),
        .samp_sof  (samp_sof),
        .samp_data (samp_data),
        .samp_valid(samp_valid),
        .idx_pop   (idx_pop),
        .idx_data  (idx_data),
        .idx_valid (idx_valid),

        .out_sample (samp_out),
        .out_valid  (samp_out_valid),
        .out_is_fill(samp_out_is_fill),
        .expected_idx(samp_index),
        .cnt_gap_events   (cnt_gap_events),
        .cnt_gap_samples  (cnt_gap_samples),
        .cnt_resync_events(cnt_resync_events),
        .irq_gap          (irq_gap)
    );

    // ---------------------------------------------------------------------
    // The CPU receive ring, fixed at 4 KB (see the header on why this is not simply `RING_AW`).
    localparam CPU_RING_AW = 12;

    wire [CPU_RING_AW-1:0] cpu_ring_wr_ptr;

    cpu_rx_ring #(.AW(CPU_RING_AW), .RING_BYTES(1 << CPU_RING_AW)) ring_i (
        .clk   (clk_rx),
        .rst   (rst_rx),
        .sof   (other_sof),
        .valid (other_valid),
        .data  (other_data),
        .eof   (other_eof),
        .commit(other_commit),
        .cnt_frames (cnt_ring_frames),
        .cnt_dropped(cnt_ring_dropped),
        .irq_pkt_rx (irq_pkt_rx),
        .rd_addr(ring_rd_addr[CPU_RING_AW-1:0]),
        .rd_data(ring_rd_data),
        .wr_ptr (cpu_ring_wr_ptr)
    );

    assign ring_wr_ptr = {{(RING_AW-CPU_RING_AW){1'b0}}, cpu_ring_wr_ptr};

endmodule
