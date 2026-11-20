// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// HL2 link receive: the heart of the receive chain. It takes the byte stream of every Ethernet
// frame from the SFP lane, decides whether the frame is one of the Hermes-Lite 2's raw sample
// frames or something else, parses the raw-frame header, and checks the CRC-32 (docs/ARCHITECTURE.md
// 3.1, steps 1 to 3).
//
// Where it sits: gmii_rx_in.v (which strips the preamble and start-of-frame delimiter) feeds it one
// byte per clock in the clk_rx domain, the 125 MHz clock recovered from the SFP lane. It drives two
// consumers:
//   - raw_*   : the sample bytes of a frame classified as a raw sample frame, going to
//               raw_frame_buffer.v, which unpacks them into 12-bit samples. The bytes are
//               delayed by four clocks, alongside the CRC check (see below), and the FCS is left
//               out, so the buffer only ever sees bytes that belong in it.
//   - other_* : every byte of every frame that is not (so far) classified raw, going to
//               cpu_rx_ring.v for the firmware (discovery replies, register-write replies, ARP,
//               DHCP, ICMP, and the bridge, aux and message traffic of the HL2).
//
// What an Ethernet frame is, for a beginner: a block of bytes sent between two network cards. It
// starts (after a preamble of alternating bits that only serves to let the receiver lock on, and a
// start-of-frame delimiter byte, both removed by gmii_rx_in.v) with the 6-byte destination MAC
// address, the 6-byte source MAC address and a 2-byte EtherType that says what is inside (0x0800
// means an IPv4 packet). The payload follows, and the frame ends with a 4-byte FCS, a CRC-32 over
// everything before it. Inside the IPv4 packet there is a 20-byte IP header (with the sender's
// and receiver's IP addresses and a protocol number, 17 for UDP) and then a UDP datagram, which has
// an 8-byte UDP header (source port, destination port, length, checksum) and then the UDP payload.
// The HL2 sends its raw ADC samples as UDP payloads from port 1024 (docs/rawfront/PROTOCOL.md
// section 5.2 on the Hermes-Lite 2 release branch), one frame of N samples per datagram.
//
// Classification: fixed byte offsets, no VLAN tag and no IP options (the HL2's IP sender always
// emits a 20-byte header with IHL = 5):
//
//   0-5    destination MAC        14-33  IPv4 header (20 B, no options)
//   6-11   source MAC             34-35  UDP source port
//   12-13  EtherType (0x0800)     36-37  UDP destination port
//                                 38-39  UDP length
//                                 40-41  UDP checksum
//                                 42     first UDP payload byte
//
// A frame is "raw" if and only if the EtherType is 0x0800, the IP protocol is 17 (UDP), the IP
// source address is the configured HL2 address, the UDP source port is 1024 and payload byte 0 is
// 0xA5 (the magic number that starts every raw header). All of that is known by the time byte 42
// has arrived, so the routing decision never needs to buffer a byte and replay it later: byte 42
// is fed live to whichever consumer it belongs to. Bytes 0 to 41 are always fed to `other_*`
// speculatively, which is cheap, since cpu_rx_ring.v only commits them at the end of the frame, so
// a frame that turns out to be raw just rolls that ring's write pointer back.
//
// The raw header (PROTOCOL 5.2, starting at UDP payload byte 0), parsed here into registers:
// byte 0 magic 0xA5, byte 1 version (1: 20-byte header, 3: 48 bytes with duplex status), byte 2
// flags, byte 3 transmit-safety byte, bytes 4 to 7 frame sequence number (counts up by one per
// frame, 0 at start), bytes 8 to 13 index of the first sample in the frame (48 bits, counts every
// ADC clock of the HL2 since start), bytes 14 and 15 N (samples in the frame), bytes 16 and 17
// the HL2's FIFO overflow count, bytes 18 and 19 its highest FIFO fill, and in version 3 the
// transmit-side status in bytes 20 to 47. The samples follow the header, packed 12 bits each (two
// samples in three bytes).
//
// CRC-32 check, the four-byte delay line: the frame's own FCS is the last four bytes, but at the
// moment a byte arrives the receiver cannot know whether it is one of the last four. The standard
// solution is to run the CRC over every byte except the last four, which is done by delaying the
// whole byte stream by four clocks (d1 to d4 below): when the delayed byte comes out of the line,
// the four bytes behind it are exactly the FCS if the frame ends now. `crc_en` is high for exactly
// bytes 0 to L-5 of an L-byte frame, without knowing L in advance. At the end of the frame the
// CRC of everything before the FCS is inverted and compared with the four FCS bytes reassembled
// from the line, the last one that arrived being the most significant (crc32_eth.v explains the
// CRC itself). The delayed stream is also what feeds the consumers, which is why they never see
// the FCS.
//
// Byte enable and errors:
//   - `ce` is a byte enable. A clock with `ce` low carries no byte (the lane's receive buffer can
//     deliver clocks without a word), and every register here moves only with `ce`, and every
//     strobe to the two consumers (raw_sof, raw_sample_valid, other_sof, other_valid) is 0 in such
//     a clock, so raw_frame_buffer.v and cpu_rx_ring.v see each byte exactly once. The frame-end
//     pulses come one clock after the end is seen.
//   - `err`: the PCS reported a code error (a 10-bit line symbol that is not valid) inside the
//     frame. The frame is dropped as if its CRC were bad and also counted in cnt_code_frames.
//   - a raw frame is committed only if its sample bytes are exactly 3N/2 for the N in its header,
//     with N even and 1 <= N <= MAX_N (otherwise cnt_len_errors counts it), because the drain of
//     raw_frame_buffer.v takes N samples from its ring whatever arrived.
//
// Loss accounting by the HL2's frame sequence number: at each committed raw frame, a forward jump
// adds the number of frames missing to cnt_seq_lost, and a backward jump, or a frame with flag 4
// ("first frame after start"), starts the count again (cnt_seq_restarts). Every frame that was
// lost before the commit (on the line, in the copper module, by CRC, by code error, by length)
// shows up there. Frames with flag 5 (the HL2 itself lost samples before this frame, because its
// own FIFO overflowed) are counted in cnt_hl2_missing.
//
// A frame with a bad CRC, of either kind, is dropped entirely: neither consumer's write pointer
// moves. For a raw frame this is exactly "a frame with a flipped bit is dropped", and
// gap_filler.v downstream turns the resulting jump of the sample index into zero fill, with no
// special case needed here.

`timescale 1ns / 1ps

module eth_frame_rx #(
    parameter MAX_HDR_BYTES = 48,  // largest raw-frame header (version 3, duplex+echo)
    parameter MAX_N = 5968         // largest N the HL2 sends (PROTOCOL.md 5.1); raw_frame_buffer.v's ring holds 8,192
) (
    input  wire        clk,        // clk_rx, 125 MHz, recovered from the SFP lane
    input  wire        rst,        // synchronous reset, active high

    // from gmii_rx_in.v
    input  wire [ 7:0] data,       // frame byte, destination MAC first, FCS included
    input  wire         active,    // high from the first byte after the SFD to the last FCS byte
    input  wire         ce,              // a byte this clock (data, active, err are new)
    input  wire         err,             // code error in this byte

    // configuration (AHB register domain, synchronised by the caller)
    input  wire [31:0] cfg_hl2_ip, // IPv4 address of the HL2, as set by the firmware (0 until discovery)

    // -------- raw sample path (to raw_frame_buffer.v) --------
    output wire         raw_sof,          // pulse: first byte of a frame now known to be raw
    output wire         raw_sample_valid, // one sample byte (post raw-frame header) this cycle
    output wire [ 7:0]  raw_sample_data,  // that sample byte (packed 12-bit samples, 3 bytes per 2 samples)
    output reg          raw_commit,       // pulse at frame end: CRC good, keep the staged bank
    output reg  [ 7:0]  raw_flags = 8'd0, // header byte 2: flags (PROTOCOL 5.3)
    output reg  [ 7:0]  raw_tx_status = 8'd0, // header byte 3: the HL2's transmit-safety byte (PROTOCOL 5.4)
    output reg  [31:0]  raw_seq = 32'd0,  // header: frame sequence number
    output reg  [47:0]  raw_first_idx = 48'd0, // header: index of the frame's first sample
    output reg  [15:0]  raw_n = 16'd0,    // header: samples in this frame
    output reg  [15:0]  raw_ovf_cnt = 16'd0, // header: HL2 FIFO overflow events since start
    output reg  [15:0]  raw_high_water = 16'd0, // header: HL2 highest raw FIFO fill since start
    // Version 3 header only (PROTOCOL 6.3 bytes 32-33, "TX FIFO fill"): the fill of the HL2's
    // transmit FIFO as it last reported it, which tx_rate_lock.v uses to trim the speed at which
    // samples are sent to the HL2. It is held at its last value, and not cleared, on a version 1
    // (20-byte) header, since those header bytes do not exist there, and `raw_version` tells the
    // caller whether this clock's `raw_commit` carries a fresh value.
    output reg  [ 7:0]  raw_version,      // header byte 1: header version (1 or 3)
    output reg  [15:0]  raw_tx_fifo_fill, // transmit FIFO fill of the HL2, in samples

    // -------- everything else (to cpu_rx_ring.v) --------
    output wire         other_sof,        // pulse: other_data is the first byte of a frame
    output wire         other_valid,      // other_data is a frame byte this clock
    output wire [ 7:0]  other_data,       // frame byte, FCS excluded, four clocks behind the live stream
    output wire          other_eof,        // pulse: this frame (of either kind) has ended
    output reg          other_commit,     // pulse at frame end: CRC good and not raw, so keep it

    // counters (read by the firmware through the register block)
    output reg  [31:0] cnt_crc_errors,    // frames dropped for a bad FCS or a code error
    output reg  [31:0] cnt_raw_frames,    // raw frames committed
    output reg  [31:0] cnt_other_frames,  // other frames committed to the CPU ring
    // loss accounting (docs/HL2_SFP.md section 6; 16-bit counters stop at 0xFFFF)
    output reg  [31:0] cnt_seq_lost = 32'd0,      // raw frames missing by sequence number
    output reg  [15:0] cnt_seq_restarts = 16'd0,  // sequence went back, or flag 4: counting started again
    output reg  [15:0] cnt_code_frames = 16'd0,   // frames dropped for a code error (also in cnt_crc_errors)
    output reg  [15:0] cnt_len_errors = 16'd0,    // raw frames, CRC good, dropped: sample bytes != 3N/2 or N bad
    output reg  [15:0] cnt_hl2_missing = 16'd0,   // committed raw frames with flag 5 (the HL2 lost samples)
    output reg  [31:0] last_seq = 32'd0           // sequence number of the last committed raw frame
) /* synthesis syn_srlstyle = "registers" */;

    // ---------------------------------------------------------------------
    // Byte index of the live byte within its frame, lined up with `data` and `active`. `sof` is
    // the first byte of a frame (active rises), `eof` the clock in which active has just fallen.
    // `sof`, `eof` and every strobe below hold only in a clock with `ce`, and between two bytes
    // the registers keep their values.
    reg        active_d = 1'b0;                       // `active` one byte ago
    wire       sof      = active & ~active_d & ce;
    reg [15:0] byte_cnt = 16'd0;                      // index of the next byte
    wire [15:0] cur_idx = (active & ~active_d) ? 16'd0 : byte_cnt;   // index of the live byte

    always @(posedge clk) if (ce) begin
        active_d <= active;
        if (sof) byte_cnt <= 16'd1;
        else if (active) byte_cnt <= byte_cnt + 16'd1;
    end

    wire eof = active_d & ~active & ce;

    // A code error anywhere in the frame (FCS bytes included), remembered until the frame ends.
    reg any_err = 1'b0;
    always @(posedge clk) if (ce) begin
        if (sof) any_err <= err;
        else if (active && err) any_err <= 1'b1;
    end

    // ---------------------------------------------------------------------
    // Header field capture: the bytes the classifier needs are caught as they go past, when the
    // byte index equals their offset in the table above.
    reg [15:0] et_cap;       // EtherType, bytes 12 and 13
    reg [ 7:0] ipproto_cap;  // IP protocol, byte 23
    reg [31:0] ipsrc_cap;    // IP source address, bytes 26 to 29
    reg [15:0] usport_cap;   // UDP source port, bytes 34 and 35

    always @(posedge clk) if (active && ce) begin
        case (cur_idx)
            16'd12: et_cap[15:8]      <= data;
            16'd13: et_cap[7:0]       <= data;
            16'd23: ipproto_cap       <= data;
            16'd26: ipsrc_cap[31:24]  <= data;
            16'd27: ipsrc_cap[23:16]  <= data;
            16'd28: ipsrc_cap[15:8]   <= data;
            16'd29: ipsrc_cap[7:0]    <= data;
            16'd34: usport_cap[15:8]  <= data;
            16'd35: usport_cap[7:0]   <= data;
            default: ;
        endcase
    end

    // The four header compares are registered: the last of their bytes is byte 35 and the decision
    // is taken at byte 42, so there is time to put a register in between, and the consumers behind
    // the four-byte CRC delay use the held decision. Doing the IP compare, the decision and the
    // byte strobes into the sample buffer and the CPU ring in one clock would be about 12 logic
    // levels, which does not fit in the 8 ns of a 125 MHz clock.
    reg hdr_ok = 1'b0;
    always @(posedge clk)
        hdr_ok <= (et_cap == 16'h0800) && (ipproto_cap == 8'h11) &&
                  (ipsrc_cap == cfg_hl2_ip) && (usport_cap == 16'd1024);
    wire is_raw_now = hdr_ok && (cur_idx == 16'd42) && (data == 8'hA5);   // the verdict, in the clock of byte 42

    // The verdict, held for the rest of the frame (cleared at the start of the next one).
    reg is_raw_hold = 1'b0;
    always @(posedge clk) if (ce) begin
        if (sof) is_raw_hold <= 1'b0;
        else if (active && cur_idx == 16'd42) is_raw_hold <= is_raw_now;
    end
    wire frame_is_raw = (cur_idx == 16'd42) ? is_raw_now : is_raw_hold;

    assign raw_sof   = active && ce && (cur_idx == 16'd42) && is_raw_now;

    // other_sof (unlike raw_sof) has to line up with other_data and other_valid below, which are
    // delayed by the same four clocks that the CRC check delays everything by, so it is defined
    // down there next to that delay line and not here at the live `sof`.

    // other_valid and raw_sample_valid are defined below, after the CRC delay line. Both have to
    // leave out the trailing FCS bytes in the same way the CRC check does, and it is not enough to
    // gate them on `active`, which stays high through the FCS too. The CPU ring would otherwise
    // store the FCS as four more content bytes. The raw path would tolerate extra bytes (because
    // raw_frame_buffer.v only drains the first N samples of a frame), but it is gated the same
    // way so that it does not depend on that.

    // ---------------------------------------------------------------------
    // Raw-frame header parse. The version byte selects the header length. Version 1 (20 bytes,
    // duplex off) and version 3 (48 bytes) are the ones the HL2 sends; any other value is given a
    // 40-byte header length, which makes the length check at the end reject the frame. The fields
    // common to all versions are captured by byte offset from the magic byte, and the transmit
    // FIFO fill of a version 3 header is picked out below.
    wire [15:0] raw_hdr_idx = cur_idx - 16'd42;   // 0 at the magic byte

    reg [15:0] raw_hdr_len;   // header length in bytes, from the version byte

    always @(posedge clk) if (active && ce && frame_is_raw) begin
        case (raw_hdr_idx)
            16'd1: begin
                raw_version <= data;
                raw_hdr_len <= (data == 8'h01) ? 16'd20 : (data == 8'h03) ? 16'd48 : 16'd40;
            end
            16'd2: raw_flags               <= data;
            16'd3: raw_tx_status           <= data;
            16'd4: raw_seq[31:24]          <= data;
            16'd5: raw_seq[23:16]          <= data;
            16'd6: raw_seq[15:8]           <= data;
            16'd7: raw_seq[7:0]            <= data;
            16'd8: raw_first_idx[47:40]    <= data;
            16'd9: raw_first_idx[39:32]    <= data;
            16'd10: raw_first_idx[31:24]   <= data;
            16'd11: raw_first_idx[23:16]   <= data;
            16'd12: raw_first_idx[15:8]    <= data;
            16'd13: raw_first_idx[7:0]     <= data;
            16'd14: raw_n[15:8]            <= data;
            16'd15: raw_n[7:0]             <= data;
            16'd16: raw_ovf_cnt[15:8]      <= data;
            16'd17: raw_ovf_cnt[7:0]       <= data;
            16'd18: raw_high_water[15:8]   <= data;
            16'd19: raw_high_water[7:0]    <= data;
            // Version 3 only (raw_hdr_len 40 or 48). A version 1 frame has raw_hdr_len 20, so its
            // sample bytes begin before raw_hdr_idx reaches 32, and these two bytes are genuinely
            // the transmit-sink status there and never sample data, whatever the version.
            16'd32: raw_tx_fifo_fill[15:8] <= data;
            16'd33: raw_tx_fifo_fill[7:0]  <= data;
            default: ;
        endcase
    end

    // ---------------------------------------------------------------------
    // CRC-32 over the four-byte delay line described in the header. d1 to d4 are the data bytes
    // one to four clocks (with `ce`) ago, a1 to a4 the same for `active`, and idx1 to idx4 for the
    // byte index. `crc_en` is 1 for precisely the bytes 0 to L-5 of an L-byte frame, so the same
    // signal that drives the CRC engine also says "this is a content byte, not the FCS" to the
    // consumers.
    reg [7:0] d1, d2, d3, d4;
    reg       a1, a2, a3, a4;
    reg [15:0] idx1, idx2, idx3, idx4;

    always @(posedge clk) if (ce) begin
        d1 <= data; d2 <= d1; d3 <= d2; d4 <= d3;
        a1 <= active; a2 <= a1; a3 <= a2; a4 <= a3;
        idx1 <= cur_idx; idx2 <= idx1; idx3 <= idx2; idx4 <= idx3;
    end

    wire crc_en = active & a4 & ce;      // (so every strobe below that uses it carries `ce`)
    wire [31:0] crc_run;

    crc32_eth crc_i (
        .clock (clk),
        .clear (sof),
        .enable(crc_en),
        .data  (d4),
        .crc   (crc_run)
    );

    // other_sof marks the clock in which other_data first holds byte 0 (idx4 == 0), four clocks
    // behind the live `sof`. cpu_rx_ring.v relies on `data` already being byte 0 exactly when its
    // `sof` pulses (it reserves the entry's two length bytes and writes the first data byte in the
    // same clock), which only holds if both signals are delayed in the same way.
    assign other_sof   = crc_en && (idx4 == 16'd0);
    // (is_raw_hold and not frame_is_raw: with idx4 >= 42 the live byte is past 42 and the two are equal)
    assign other_valid = crc_en && ((idx4 < 16'd42) || ~is_raw_hold);
    assign other_data  = d4;

    // A raw sample byte is a content byte of a raw frame beyond the raw header. `frame_is_raw`
    // describes the live byte, which has already been decided by the time the delayed index idx4
    // is still short of 42, so the explicit `idx4 >= 16'd42` is needed: it keeps the last two
    // bytes of the IP and UDP header, which the delay line is still passing, out of the sample
    // stream once the live side has decided "raw" a few clocks early. It also matters that
    // raw_hdr_idx_d, as a 16-bit unsigned number, wraps to a huge value for idx4 < 42 and would
    // compare true against any real header length by itself. Without the guard, two extra bytes
    // would appear at the start of every raw frame's samples and shift the phase of the
    // 3-byte-per-2-samples unpacker.
    wire [15:0] raw_hdr_idx_d = idx4 - 16'd42;
    assign raw_sample_valid = crc_en && is_raw_hold && (idx4 >= 16'd42) && (raw_hdr_idx_d >= raw_hdr_len);
    assign raw_sample_data  = d4;

    // The check itself: the inverted CRC of everything but the last four bytes must equal those
    // four bytes read as a number with the newest byte on top.
    wire [31:0] fcs_rx   = {d1, d2, d3, d4};
    wire        crc_good = ((~crc_run) == fcs_rx) && !any_err;

    // Sample bytes counted in this raw frame, for the length check at its end (saturating).
    reg [15:0] n_sbytes = 16'd0;
    always @(posedge clk) begin
        if (sof) n_sbytes <= 16'd0;
        else if (raw_sample_valid && (n_sbytes != 16'hFFFF)) n_sbytes <= n_sbytes + 16'd1;
    end
    // The expected number of sample bytes is 3N/2 (two 12-bit samples in three bytes), and N must
    // be even, non-zero and no larger than MAX_N. Both are registered: raw_n is complete 16 bytes
    // after the magic byte, long before the frame ends.
    reg [15:0] want_bytes = 16'd0;
    reg        n_ok = 1'b0;
    always @(posedge clk) begin
        want_bytes <= raw_n + {1'b0, raw_n[15:1]};
        n_ok       <= (raw_n != 16'd0) && !raw_n[0] && (raw_n <= MAX_N[15:0]);
    end
    wire len_ok = n_ok && (n_sbytes == want_bytes);

    // Sequence accounting (docs/HL2_SFP.md section 6). `seq_exp` is the number that the next frame
    // should carry, and `seq_diff` the number of frames in between, which is only meaningful if
    // the jump is forward (its top bit is the sign).
    reg         seq_valid = 1'b0;                          // a first frame has been seen since reset
    wire [31:0] seq_exp  = last_seq + 32'd1;
    wire [31:0] seq_diff = raw_seq - seq_exp;          // frames missing, if the jump is forward

    // other_eof has to land in the SAME clock as other_commit, because cpu_rx_ring.v looks at
    // them together to decide between "keep this frame" and "roll back its speculative bytes".
    // So it is registered here in exactly the way commit is, and not driven straight from the
    // combinational `eof` one clock earlier: the ring would otherwise see an end without a commit
    // and roll back every frame, discovery replies included.
    reg other_eof_r = 1'b0;
    assign other_eof = other_eof_r;

    // ---------------------------------------------------------------------
    // Frame-end commit or drop: at the end of every frame, exactly one of four things happens.
    //   1. CRC good, raw, length right: committed as a raw frame, with sequence accounting.
    //   2. CRC good, raw, length wrong: dropped and counted in cnt_len_errors.
    //   3. CRC good, not raw: committed to the CPU ring (other_commit).
    //   4. Anything else (bad CRC, or a code error): counted in cnt_crc_errors and dropped.
    // A code error is counted in cnt_code_frames in addition to the case it falls into.
    always @(posedge clk) begin
        raw_commit   <= 1'b0;
        other_commit <= 1'b0;
        other_eof_r  <= 1'b0;
        if (rst) begin
            cnt_crc_errors   <= 32'd0;
            cnt_raw_frames   <= 32'd0;
            cnt_other_frames <= 32'd0;
            cnt_seq_lost     <= 32'd0;
            cnt_seq_restarts <= 16'd0;
            cnt_code_frames  <= 16'd0;
            cnt_len_errors   <= 16'd0;
            cnt_hl2_missing  <= 16'd0;
            seq_valid        <= 1'b0;
        end else if (eof) begin
            other_eof_r <= 1'b1;
            if (any_err && (cnt_code_frames != 16'hFFFF)) cnt_code_frames <= cnt_code_frames + 16'd1;
            if (crc_good && is_raw_hold && len_ok) begin
                raw_commit     <= 1'b1;
                cnt_raw_frames <= cnt_raw_frames + 32'd1;
                last_seq       <= raw_seq;
                seq_valid      <= 1'b1;
                if (raw_flags[5] && (cnt_hl2_missing != 16'hFFFF)) cnt_hl2_missing <= cnt_hl2_missing + 16'd1;
                if (seq_valid && raw_flags[4]) begin
                    if (cnt_seq_restarts != 16'hFFFF) cnt_seq_restarts <= cnt_seq_restarts + 16'd1;
                end else if (seq_valid && (raw_seq != seq_exp)) begin
                    if (!seq_diff[31]) cnt_seq_lost <= cnt_seq_lost + seq_diff;
                    else if (cnt_seq_restarts != 16'hFFFF) cnt_seq_restarts <= cnt_seq_restarts + 16'd1;
                end
            end else if (crc_good && is_raw_hold) begin
                if (cnt_len_errors != 16'hFFFF) cnt_len_errors <= cnt_len_errors + 16'd1;
            end else if (crc_good && ~is_raw_hold) begin
                other_commit     <= 1'b1;
                cnt_other_frames <= cnt_other_frames + 32'd1;
            end else begin
                cnt_crc_errors <= cnt_crc_errors + 32'd1;
            end
        end
    end

endmodule
