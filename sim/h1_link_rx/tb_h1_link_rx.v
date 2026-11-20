// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Testbench for the HL2 link receive path, rtl/hl2link/hl2_link_rx_top.v.
//
// Some background first, for a reader new to this part of the radio. The Hermes-Lite 2 (HL2) is the small
// transceiver that digitizes the antenna signal with a 12 bit ADC at 76.8 Msps. In its "raw stream" mode it does no
// filtering at all, it just packs the samples two to every three bytes (N samples take 3N/2 bytes), puts a short header
// in front (a 0xA5 marker byte, the sample count N, a frame sequence number, the index of the first sample, a safety
// status byte and some flags), and sends the result as UDP packets over gigabit Ethernet, which at N = 968 fills about
// 98 % of the line (980 Mbit/s). fpga-sdr takes that stream in on an SFP cage and has to turn it back into one
// continuous sample stream at a clock of its own, which is the job of the DUT. The terms used below (UDP, FCS, CRC,
// CDC, ring buffer) are explained in docs/learn/GLOSSARY.md.
//
// What the DUT does, in the order a byte travels through it:
//   gmii_rx_in.v        takes the bytes of the transceiver's receive path (data, data valid, byte enable) on the
//                       recovered 125 MHz receive clock,
//   eth_frame_rx.v      checks the Ethernet CRC-32 of every frame, decides whether it is a raw sample frame
//                       (UDP from the HL2's address, source port 1024, first payload byte 0xA5) and parses its header,
//   raw_frame_buffer.v  stages the sample bytes, drops them again if the CRC turns out bad, and carries the samples over
//                       to the DSP clock through a FIFO,
//   gap_filler.v        compares each frame's first sample index with the index it expects and inserts zero samples
//                       for every sample that went missing, so the stream stays continuous in time,
//   cpu_rx_ring.v       keeps every frame that is not a raw frame (discovery replies and the like) for the firmware.
//
// The far end in this bench is the HL2's own sending code (sim/h1_link_rx/hl2/), driven in test pattern mode: the
// sample with index k then has the value k mod 4096, so every output sample can be checked against a counter. The
// bench also adds a clock offset of 50 ppm between the HL2's sample clock and the DUT's clocks, flips one bit in
// one raw frame on the wire (the DUT must drop that frame and fill exactly N zero samples in its place), sends
// discovery requests so that other traffic reaches the CPU ring, and finally changes the safety status byte to see
// the interrupt fire. With -DGAPS the DUT's receive clock is 2.5 % faster than the far end's and takes the bytes
// through a queue, so some of its clocks carry no byte (byte enable 0), as when the transceiver's receive buffer is
// read while it is nearly empty.
//
// Pass: after a settling time the bench checks that every output sample matches the pattern, that exactly one CRC error,
// one gap event and one lost sequence number were seen, that exactly 968 zero samples were inserted, that
// no real sample was lost or duplicated, that the far end never overflowed, and that a discovery reply stored in the
// CPU ring has the right length and destination MAC. It prints "PASS", or "FAIL: n errors" after the individual
// ERROR lines, and ends with $finish.
//
// Run, from the repo root (the include paths are relative to it):
//   iverilog -g2012 -o build/tb_h1_link_rx.vvp sim/h1_link_rx/tb_h1_link_rx.v && vvp build/tb_h1_link_rx.vvp
// -DSIM_US=n sets how many microseconds of link time are streamed and checked (default 3, run_long.sh uses 20000),
// -DGAPS selects the byte enable variant, and -DTB_DEBUG or -DTB_HEARTBEAT add progress printouts.

`include "rtl/hl2link/crc32_eth.v"
`include "rtl/hl2link/cdc_word.v"
`include "rtl/hl2link/cdc_sample_fifo.v"
`include "rtl/hl2link/gmii_rx_in.v"
`include "rtl/hl2link/eth_frame_rx.v"
`include "rtl/hl2link/raw_frame_buffer.v"
`include "rtl/hl2link/gap_filler.v"
`include "rtl/hl2link/cpu_rx_ring.v"
`include "rtl/hl2link/hl2_link_rx_top.v"

// The far end: the HL2's own sending code, copied into sim/h1_link_rx/hl2/ so that this bench does not depend on
// a second checkout. The path is relative to the repo root because the build command above takes no include path.
`include "sim/h1_link_rx/dcfifo_sim_stub.v"
`include "sim/h1_link_rx/hl2/rawstream.v"
`include "sim/h1_link_rx/hl2/udp_send.v"
`include "sim/h1_link_rx/hl2/ip_send.v"
`include "sim/h1_link_rx/hl2/mac_send.v"
`include "sim/h1_link_rx/hl2/crc32.v"
`include "sim/h1_link_rx/hl2/rgmii_send.v"

// The timescale comes after the includes on purpose. Every included file sets its own `timescale, and a directive
// stays in force until the next one, so a directive placed at the top of this file would be replaced by the one in the
// last included file before this module is reached. All delays below are written in picoseconds (8000 = one 125 MHz
// period).
`timescale 1ps / 1fs

module tb_h1_link_rx;

    // ------------------------------------------------------------------
    // Addresses of the two ends of the link (arbitrary, it is a point-to-point cable, and the RJ45 is used only by the HL2).
    // Addresses (arbitrary, point-to-point link -- DECISIONS.md: the RJ45 is used only by the HL2)
    localparam [47:0] HL2_MAC = 48'h02_00_00_00_00_02;
    localparam [31:0] HL2_IP  = 32'h0a63_0002;   // 10.99.0.2
    localparam [47:0] MY_MAC  = 48'h02_00_00_00_00_01;
    localparam [31:0] MY_IP   = 32'h0a63_0001;   // 10.99.0.1
    localparam [15:0] MY_PORT = 16'd51000;

    // ------------------------------------------------------------------
    // Clocks
    //   clk     125 MHz: the clock of the far end's transmitter and, without GAPS, of the DUT's receive side too
    //           (a gigabit link is 8 bits per 8 ns clock, and the receiver clock is recovered from the same
    //           transmitter, so both sides see the same frequency).
    //   clk_ad  76.8 MHz plus 50 ppm: the HL2's own ADC and sample clock, free running and unrelated to `clk`. It differs
    //           from ours by a few ppm in the real radio (ARCHITECTURE.md section 2), which is what makes the asynchronous
    //           FIFOs in raw_frame_buffer.v and cdc_sample_fifo.v necessary.
    //   clk_dsp 150 MHz: the DUT's own independent local clock, also unrelated to `clk` and `clk_ad`.
    logic clk = 1'b0;
    always #4000 clk = ~clk;                  // 125 MHz (8000 ps period)

    logic clk_ad = 1'b0;
    initial begin
        // Offset of 1733 ps so that no edge of this clock lands on an edge of another one.
        #1733;
        // 76.8 MHz is a period of 13020.8333 ps, half of that is 6510.41667 ps, and dividing by 1.00005 gives the 50 ppm
        // faster half period of 6510.0912 ps.
        // 76.8 MHz + 50 ppm: nominal half period 6510.41667 ps, /1.00005 = 6510.0912 ps
        forever #6510.0912 clk_ad = ~clk_ad;
    end

    logic clk_dsp = 1'b0;
    initial begin
        #907;
        forever #3333.333 clk_dsp = ~clk_dsp;   // 150 MHz
    end

    // The DUT's receive clock: the far end's own (without GAPS), or 2.5 % faster with a byte queue in between (see the header).
    // The half period of 3902 ps gives a period of 7804 ps against 8000 ps, which is 1.0251 times the frequency.
    // the DUT's receive clock: the far end's (without GAPS), or 2.5 % faster with a byte queue (see the header)
`ifdef GAPS
    logic dclk = 1'b0;
    initial begin #1100; forever #3902 dclk = ~dclk; end
`else
    wire dclk = clk;
`endif

    // ------------------------------------------------------------------
    // Far end: rawstream.v from the HL2 plus the real send chain. This section mirrors the HL2's own testbench for it.
    // Far end: rawstream.v + real send chain (mirrors gateware/sim/rawstream/tb_rawstream.sv)
    logic        run = 1'b0;
    logic [ 5:0] cmd_addr = 6'h0;
    logic [31:0] cmd_data = 32'h0;
    logic        cmd_rqst = 1'b0;
    logic        discover_rqst = 1'b0;
    logic [ 7:0] tx_status = 8'h01;             // PROTOCOL.md 5.4 idle value

    logic [11:0] adc = 12'h0;   // unused (test-pattern mode only), free-running so it is not X
    always @(posedge clk_ad) adc <= adc + 12'd1;

    logic [ 1:0] udp_tx_request;
    logic [15:0] udp_tx_length;
    logic [ 7:0] udp_tx_data;
    wire         udp_tx_enable, udp0_tx_enable, udp_tx_busy;
    wire  [ 1:0] pkt_req;
    wire  [ 7:0] pkt_data;
    wire  [10:0] pkt_len;
    logic        pkt_en;
    logic        raw_mode;

    rawstream #(.FIFO_AW(14)) far_i (
        .clk_ad        (clk_ad),
        .adc_data      (adc),
        .clk           (clk),
        .run           (run),
        .cmd_addr      (cmd_addr),
        .cmd_data      (cmd_data),
        .cmd_rqst      (cmd_rqst),
        .raw_mode      (raw_mode),
        .pkt_tx_request(pkt_req),
        .pkt_tx_length ({5'h0, pkt_len}),
        .pkt_tx_data   (pkt_data),
        .pkt_tx_enable (pkt_en),
        .udp_tx_request(udp_tx_request),
        .udp_tx_length (udp_tx_length),
        .udp_tx_data   (udp_tx_data),
        .udp_tx_enable (udp_tx_enable),
        .udp0_tx_enable(udp0_tx_enable),
        .udp_tx_busy   (udp_tx_busy),
        .dup_on        (1'b0),
        .dup_status    (160'd0),
        .tx_status     (tx_status)
    );

    // Packer model for discovery replies, in the role of the HL2's usopenhpsdr1.v and network.v (which this simulator
    // cannot read). When a discovery request is pending it asks the send chain for a 60 byte packet starting with
    // 0xEF 0xFE, a status byte that says whether `run` is set, and filler bytes, so that the receiver sees
    // ordinary non-raw traffic going through the same mac_send/ip_send/udp_send/crc32 chain as the raw stream.
    // Discovery-reply packer model (copied from tb_rawstream.sv; see the file header comment)
    localparam P_IDLE = 2'd0, P_REQ = 2'd1, P_SEND = 2'd2;
    logic [1:0] p_state = P_IDLE;
    logic [7:0] p_byte  = 8'h0;
    logic [5:0] p_cnt   = 6'h0;
    logic       p_pending = 1'b0;
    logic [10:0] p_len  = 11'd0;
    always @(posedge clk) begin
        if (discover_rqst) p_pending <= 1'b1;
        case (p_state)
            P_IDLE: if (p_pending) begin p_len <= 11'h3c; p_state <= P_REQ; end
            P_REQ: begin
                p_byte <= 8'hef;
                if (pkt_en) begin p_state <= P_SEND; p_cnt <= 6'h3a; p_pending <= 1'b0; end
            end
            P_SEND: begin
                p_cnt <= p_cnt - 6'd1;
                case (p_cnt)
                    6'h3a: p_byte <= 8'hfe;
                    6'h39: p_byte <= run ? 8'h03 : 8'h02;
                    6'h38: p_byte <= 8'h00;
                    6'h37: p_byte <= 8'h1c;
                    6'h36: p_byte <= 8'hc0;
                    6'h35: p_byte <= 8'ha2;
                    6'h34: p_byte <= 8'h13;
                    6'h33: p_byte <= 8'hdd;
                    6'h00: begin p_byte <= 8'h00; p_state <= P_IDLE; end
                    default: p_byte <= p_cnt[5:0] ^ 8'h55;
                endcase
            end
        endcase
    end
    assign pkt_req  = (p_state == P_REQ) ? 2'b10 : 2'b00;
    assign pkt_data = p_byte;
    assign pkt_len  = p_len;

    // Send arbitration of the HL2's network.v: a UDP transmit request from rawstream.v (or the packer above) is granted
    // when the transmitter is idle, and the data then flows through udp_send, ip_send and mac_send, which wrap it in UDP,
    // IP and Ethernet headers and append the CRC.
    // network.v send arbitration (copied from tb_rawstream.sv)
    logic tx_ready = 1'b0, tx_start = 1'b0;
    logic [2:0] tx_protocol = 3'd0;
    localparam PT_UDP0 = 3'd4;
    wire rgmii_tx_active;
    assign udp_tx_enable  = tx_start && (tx_protocol == PT_UDP0);
    assign udp0_tx_enable = tx_start && (tx_protocol == PT_UDP0);
    assign udp_tx_busy    = tx_ready | tx_start | rgmii_tx_active;
    always @(posedge clk)
        if (rgmii_tx_active) begin tx_ready <= 1'b0; tx_start <= 1'b0; end
        else if (tx_ready) tx_start <= 1'b1;
        else if (udp_tx_request == 2'b10) begin tx_protocol <= PT_UDP0; tx_ready <= 1'b1; end

    wire        udp_tx_active;
    wire [ 7:0] udp_data;
    wire [15:0] udp_length;
    wire [ 7:0] ip_tx_data;
    wire        ip_tx_active;
    wire [ 7:0] mac_tx_data;
    wire        mac_tx_active;
    logic [7:0] rgmii_tx_data_in_pipe;
    logic       rgmii_tx_enable_pipe = 1'b0;

    udp_send udp_send_inst (.reset(1'b0), .clock(clk), .tx_enable(udp_tx_enable), .data_in(udp_tx_data),
        .length_in(udp_tx_length), .local_port(16'd1024), .destination_port(MY_PORT),
        .active(udp_tx_active), .data_out(udp_data), .length_out(udp_length), .port_ID(8'h00));
    ip_send ip_send_inst (.data_in(udp_data), .tx_enable(udp_tx_active), .is_icmp(1'b0), .length(udp_length),
        .destination_ip(MY_IP), .data_out(ip_tx_data), .active(ip_tx_active), .clock(clk), .reset(1'b0),
        .local_ip(HL2_IP));
    mac_send mac_send_inst (.data_in(ip_tx_data), .tx_enable(ip_tx_active), .destination_mac(MY_MAC),
        .data_out(mac_tx_data), .active(mac_tx_active), .clock(clk), .local_mac(HL2_MAC), .reset(1'b0));
    always @(posedge clk) begin
        rgmii_tx_data_in_pipe <= mac_tx_data;
        rgmii_tx_enable_pipe  <= mac_tx_active;
    end
    rgmii_send #(.SIM(1)) rgmii_send_inst (.data(rgmii_tx_data_in_pipe), .tx_enable(rgmii_tx_enable_pipe),
        .active(rgmii_tx_active), .clock(clk), .PHY_TX(), .PHY_TX_EN());

    initial begin
        udp_send_inst.byte_no = 16'd0; udp_send_inst.sending = 1'b0;
        ip_send_inst.byte_no = 5'd0;   ip_send_inst.sending = 1'b0;
    end

    // ------------------------------------------------------------------
    // Wire-level tap and bit error injection. The shift register of rgmii_send is the complete wire byte stream
    // (preamble, start frame delimiter, content, FCS) and `sending` is high for as long as it holds a frame. Only
    // the output pins are switched off in this simulation, the framing logic is unchanged.
    wire       far_sending = rgmii_send_inst.sending;
    wire [7:0] far_byte    = rgmii_send_inst.shift_reg[63:56];

    // The injected error: a bit is flipped once, at byte 300 of a frame counted from the start of its preamble. A
    // discovery reply is only 114 bytes on the wire, so this offset can only fall inside a raw frame (about 1,500
    // bytes at N = 968), and the flipped bit (mask 0x20) is somewhere in its sample data. The FCS then no longer matches.
    logic        inject_armed = 1'b0;   // testbench arms this once, at a chosen point in the run
    logic        inject_done  = 1'b0;
    integer      inject_byte_offset = 300;   // only ever reached inside a raw frame, see header
    integer      frame_byte_cnt = 0;
    logic        far_sending_pd = 1'b0;   // far_sending sampled at posedge, for edge detect below
    logic [7:0]  wire_byte;
    logic        wire_dv;

    // The wire tap registers the far end's byte and its valid flag once per clock, and the injection above replaces
    // the byte by a corrupted copy at the chosen offset. The byte stream below the DUT's pins then runs through the
    // same kind of register once more (g_d, g_dv, g_ce) so that everything the DUT sees is registered.
    always @(posedge clk) begin
        wire_byte <= far_byte;
        wire_dv   <= far_sending;
        if (inject_armed && !inject_done && far_sending && (frame_byte_cnt == inject_byte_offset)) begin
            wire_byte   <= far_byte ^ 8'h20;   // flip one bit
            inject_done <= 1'b1;
            $display("t=%0t: injecting a bit error at frame byte offset %0d", $time, inject_byte_offset);
        end
    end

    // frame_byte_cnt restarts at every rising edge of `far_sending`, so it always means "bytes since the start of
    // this frame". The previous value of far_sending is registered on the same clock edge as everything else here,
    // which is the only way the edge is seen once per frame.
    always @(posedge clk) begin
        far_sending_pd <= far_sending;
        if (far_sending && !far_sending_pd) frame_byte_cnt <= 0;
        else if (far_sending) frame_byte_cnt <= frame_byte_cnt + 1;
    end

    // ------------------------------------------------------------------
    // The bytes into the DUT, as the transceiver's receive path presents them: byte, data valid and byte enable.
    // The bytes into the DUT, as the lane's PCS gives them (dv, data, ce)
    logic [7:0] g_d = 8'd0;
    logic       g_dv = 1'b0, g_ce = 1'b0;
`ifdef GAPS
    // GAPS variant: a 256 entry queue written at 125 MHz and read at the DUT's 2.5 % faster clock. The reader keeps two
    // entries of margin and, whenever the queue has run dry, gives a clock without a byte (ce = 0). `gaps` counts those clocks.
    reg [8:0] gq [0:255];
    integer   gw = 0, gr = 0, gaps = 0;
    always @(posedge clk) begin gq[gw % 256] = {wire_dv, wire_byte}; gw = gw + 1; end
    always @(posedge dclk) begin
        if (gr < gw - 2) begin {g_dv, g_d} <= gq[gr % 256]; g_ce <= 1'b1; gr = gr + 1; end
        else begin g_ce <= 1'b0; gaps = gaps + 1; end
    end
`else
    always @(posedge clk) begin g_d <= wire_byte; g_dv <= wire_dv; g_ce <= 1'b1; end
`endif

    // ------------------------------------------------------------------
    // Device under test. The reset is held until the first part of the test sequence below has run.
    // DUT
    logic        rst_rx = 1'b1, rst_dsp = 1'b1;
    logic [31:0] cfg_hl2_ip = HL2_IP;

    wire [11:0] samp_out;
    wire        samp_out_valid, samp_out_is_fill;
    wire [7:0]  safety_byte;
    wire        irq_safety_change, irq_pkt_rx, irq_gap;
    wire [31:0] cnt_crc_errors, cnt_raw_frames, cnt_other_frames;
    wire [15:0] cnt_ring_frames, cnt_ring_dropped;
    wire [31:0] cnt_gap_events, cnt_gap_samples, cnt_resync_events, cnt_seq_lost;
    wire [15:0] cnt_len_errors, cnt_drain_drops, cnt_overruns;
    logic [13:0] ring_rd_addr = 14'd0;
    wire [7:0]   ring_rd_data;
    wire [13:0]  ring_wr_ptr;

`ifdef TB_SAMP_AW
    // tb_h1_link_rx_backpressure.v makes the sample FIFO smaller, so that the zero fill backs the drain up into a
    // full FIFO and the backpressure path is exercised.
    defparam dut.buf_i.SAMP_AW = `TB_SAMP_AW;
`endif
    hl2_link_rx_top #(.RING_AW(14)) dut (
        .clk_rx      (dclk),
        .rst_rx      (rst_rx),
        .g_rx_d(g_d), .g_rx_dv(g_dv), .g_rx_er(1'b0), .g_rx_ce(g_ce),
        .clk_dsp     (clk_dsp),
        .rst_dsp     (rst_dsp),
        .cfg_hl2_ip  (cfg_hl2_ip),
        .samp_out         (samp_out),
        .samp_out_valid   (samp_out_valid),
        .samp_out_is_fill (samp_out_is_fill),
        .safety_byte      (safety_byte),
        .irq_safety_change(irq_safety_change),
        .irq_pkt_rx  (irq_pkt_rx),
        .irq_gap     (irq_gap),
        .cnt_crc_errors  (cnt_crc_errors),
        .cnt_raw_frames  (cnt_raw_frames),
        .cnt_other_frames(cnt_other_frames),
        .cnt_ring_frames (cnt_ring_frames),
        .cnt_ring_dropped(cnt_ring_dropped),
        .cnt_gap_events   (cnt_gap_events),
        .cnt_gap_samples  (cnt_gap_samples),
        .cnt_resync_events(cnt_resync_events),
        .cnt_seq_lost(cnt_seq_lost), .cnt_seq_restarts(), .cnt_code_frames(), .cnt_len_errors(cnt_len_errors),
        .cnt_hl2_missing(), .last_seq(), .cnt_drain_drops(cnt_drain_drops), .cnt_overruns(cnt_overruns),
        .cnt_idx_drops(), .hl2_ovf_count(),
        .ring_rd_addr(ring_rd_addr),
        .ring_rd_data(ring_rd_data),
        .ring_wr_ptr (ring_wr_ptr)
    );

    // Debug printouts, switched on with -DTB_DEBUG: the first frames and samples, far end state and wire activity.
`ifdef TB_DEBUG
    integer dbg_rs_n = 0;
    always @(posedge clk) begin
        if (dut.frame_rx_i.raw_sample_valid && dbg_rs_n < 20) begin
            $display("t=%0t raw_sample_data=%h idx4=%0d hdr_idx_d=%0d",
                $time, dut.frame_rx_i.raw_sample_data, dut.frame_rx_i.idx4, dut.frame_rx_i.raw_hdr_idx_d);
            dbg_rs_n = dbg_rs_n + 1;
        end
    end
    integer dbg_bp_n = 0;
    always @(posedge clk) begin
        if (dut.buf_i.wr_en_bank && dbg_bp_n < 12) begin
            $display("t=%0t bankwrite wp=%0d data=%h", $time, dut.buf_i.wp, dut.buf_i.wr_data_bank);
            dbg_bp_n = dbg_bp_n + 1;
        end
    end
    logic far_sending_prev_dbg = 1'b0;
    always @(posedge clk) begin
        far_sending_prev_dbg <= far_sending;
        if (far_sending != far_sending_prev_dbg)
            $display("t=%0t far_sending edge: %b -> %b  frame_byte_cnt(after)=%0d far_sending_pd=%b",
                     $time, far_sending_prev_dbg, far_sending, frame_byte_cnt, far_sending_pd);
    end
    always @(posedge clk) begin
        if (cmd_rqst || far_i.cfg_mode)
            $display("t=%0t cmd_rqst=%b cmd_addr=%h cmd_data=%h CMD_ADDR=%h cfg_mode=%b cfg_n=%0d",
                $time, cmd_rqst, cmd_addr, cmd_data, far_i.CMD_ADDR, far_i.cfg_mode, far_i.cfg_n);
    end
    initial begin
        #300000;
        forever begin
            $display("t=%0t run=%b raw_mode=%b raw_active=%b state=%0d rd_used=%0d fill_ge_n=%b cfg_n=%0d",
                $time, run, raw_mode, far_i.raw_active, far_i.state, far_i.rd_used, far_i.fill_ge_n, far_i.cfg_n);
            #2000000;
        end
    end
    integer dbg_trace_n = 0;
    always @(posedge clk) begin
        if (dbg_trace_n < 130 && (dut.gmii_i.active || dut.gmii_i.dv)) begin
            $display("t=%0t phy: dv=%b payload=%b active=%b data=%h  | far_sending=%b far_byte=%h",
                $time, dut.gmii_i.dv, dut.gmii_i.payload, dut.gmii_i.active, dut.gmii_i.data,
                far_sending, far_byte);
            dbg_trace_n = dbg_trace_n + 1;
        end
    end
    always @(posedge clk) begin
        if (dut.frame_rx_i.eof)
            $display("t=%0t eof crc_good=%b is_raw_hold=%b byte_cnt=%0d crc_run=%h ~crc_run=%h fcs=%h d1=%h d2=%h d3=%h d4=%h",
                $time, dut.frame_rx_i.crc_good, dut.frame_rx_i.is_raw_hold, dut.frame_rx_i.byte_cnt,
                dut.frame_rx_i.crc_run, ~dut.frame_rx_i.crc_run, dut.frame_rx_i.fcs_rx,
                dut.frame_rx_i.d1, dut.frame_rx_i.d2, dut.frame_rx_i.d3, dut.frame_rx_i.d4);
    end
    always @(posedge clk_dsp) begin
        if (samp_out_valid)
            $display("t=%0t samp_out=%h fill=%b", $time, samp_out, samp_out_is_fill);
    end
`endif

    // ------------------------------------------------------------------
    // Checkers
    integer errors = 0;
    // The comparison is `!== 1'b1` so that a condition that evaluates to X (a memory word that was never written, for
    // example) counts as a failure, which `!(cond)` would let through silently.
    `define CHECK(cond, msg) if ((cond) !== 1'b1) begin errors = errors + 1; $display("ERROR t=%0t: %s", $time, msg); end

    // Test pattern check. In test pattern mode sample k of a frame whose first index is I has the value (I + k) mod 4096.
    // This counter is kept independent of the DUT's own expected index in gap_filler.v, so the check is a real one. It
    // starts from the first real sample's own value (the bench does not know which index the far end was at when raw mode
    // went on) and from then on has to advance by exactly 1 per output sample, whether the sample is real or a fill.
    logic [11:0] tb_expected = 12'h0;
    logic        tb_started  = 1'b0;
    integer      samples_checked = 0;
    integer      fill_samples_seen = 0;
    integer      pattern_errors = 0;

    // Progress line every microsecond (or -DTB_HEARTBEAT_PS picoseconds), switched on with -DTB_HEARTBEAT.
`ifdef TB_HEARTBEAT
    initial begin
        forever begin
`ifdef TB_HEARTBEAT_PS
            #(`TB_HEARTBEAT_PS);
`else
            #(1_000_000);
`endif
            $display("HEARTBEAT t=%0t raw_frames=%0d other_frames=%0d samples=%0d gap_ev=%0d rd_used=%0d state=%0d draining=%b fifo_wr_full=%b samp_pop_state=%0d",
                $time, cnt_raw_frames, cnt_other_frames, samples_checked, cnt_gap_events,
                far_i.rd_used, far_i.state, dut.buf_i.draining, dut.buf_i.fifo_wr_full, dut.gap_i.state);
            $fflush;
        end
    end
`endif

    // Output checker, on the DSP clock, for every sample that leaves the DUT: the first one must be real, a fill sample
    // must be zero, and every real sample must equal the running expected value.
    always @(posedge clk_dsp) begin
        if (samp_out_valid) begin
            if (!tb_started) begin
                tb_started <= 1'b1;
                tb_expected <= samp_out + 12'd1;
                `CHECK(!samp_out_is_fill, "stream started with a fill sample")
            end else begin
                if (samp_out_is_fill) begin
                    `CHECK(samp_out == 12'h000, "fill sample was not zero")
                    fill_samples_seen <= fill_samples_seen + 1;
                end else begin
                    if (samp_out !== tb_expected) begin
                        pattern_errors <= pattern_errors + 1;
                        if (pattern_errors < 20)
                            $display("ERROR t=%0t: pattern sample %0d: got %h expected %h",
                                     $time, samples_checked, samp_out, tb_expected);
                    end
                end
                tb_expected <= tb_expected + 12'd1;
            end
            samples_checked <= samples_checked + 1;
        end
    end

    // ------------------------------------------------------------------
    // Helper that reads back the CPU ring through its read port: the 2 byte length of the entry that starts at
    // `start_addr` and then its first 8 bytes, packed into one 64 bit word (Icarus does not accept an array as a task
    // port). The read data of the ring arrives a clock after the address, so each read waits two clocks.
    reg [15:0] rr_len;
    reg [63:0] rr_bytes;

    task automatic read_ring_frame(input [13:0] start_addr);
        integer i;
        reg [7:0] b;
        begin
            ring_rd_addr = start_addr; @(posedge dclk); @(posedge dclk);
            rr_len[15:8] = ring_rd_data;
            ring_rd_addr = start_addr + 14'd1; @(posedge dclk); @(posedge dclk);
            rr_len[7:0] = ring_rd_data;
            for (i = 0; i < 8; i = i + 1) begin
                ring_rd_addr = start_addr + 14'd2 + i[13:0];
                @(posedge dclk); @(posedge dclk);
                rr_bytes[63 - 8*i -: 8] = ring_rd_data;
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Discovery requests, every 200 us and independent of the raw stream, as background traffic for the CPU ring. The
    // gap is long because at N = 968 the raw stream alone takes 98 % of the gigabit line, so every other frame has to
    // fit into the remaining 2 %. A much higher request rate would make the far end's sample FIFO grow until it overflowed,
    // which is correct behavior for an over-full link, and is not what this test is about. The final checks confirm
    // that the far end never overflowed.
    integer disc_sent = 0;
    logic   disc_enable = 1'b0;
    always begin
        #(200_000_000);
        if (disc_enable) begin
            @(posedge clk) discover_rqst <= 1'b1;
            @(posedge clk) discover_rqst <= 1'b0;
            disc_sent = disc_sent + 1;
        end
    end

    // ------------------------------------------------------------------
    // Test sequence
    integer sim_us;
    reg [13:0] ring_wr_ptr_before, ring_wr_ptr_after, ring_span;
    // The CPU ring in hl2_link_rx_top.v is a fixed 4 KB whatever RING_AW says, and ring_wr_ptr wraps at that size.
    localparam [13:0] CPU_RING_BYTES = 14'd4096;

    initial begin
        // SIM_US is the amount of link time that is streamed and checked, 3 us by default for a quick check and
        // 20000 us (20 ms) in run_long.sh. The short default is enough because the setup already reaches the first
        // good raw frame, the corrupted frame and a discovery reply on its own, and because the settling time at the
        // end lets the fill and the last frames finish, so every check below is exact at any SIM_US.
`ifdef SIM_US
        sim_us = `SIM_US;
`else
        sim_us = 3;
`endif

        // Reset phase. Reset is held for several periods of both the receive clock (8000 ps) and the DSP clock (6667 ps),
        // because a pulse shorter than one period of the destination clock is never sampled. The extra 37 ps keeps
        // every later stimulus change off the 8000 ps grid of `clk`: a write that lands in the same instant as a clock
        // edge is a race against that edge's own always blocks.
        #50037;
        rst_rx = 1'b0; rst_dsp = 1'b0;
        #10000;

        // Configure the far end through its command port: register 0x30 with N = 968 in the top 16 bits (the default
        // size of the real stream), bit 1 = test pattern and bit 0 = raw mode, then start the stream with `run`.
        cmd_addr <= 6'h30; cmd_data <= {16'd968, 13'd0, 1'b0, 1'b1, 1'b1}; cmd_rqst <= 1'b1;
        @(posedge clk); cmd_rqst <= 1'b0;
        #(20 * 8000);
        run <= 1'b1;
        disc_enable <= 1'b1;

        // Wait for one whole good raw frame before the bit error is armed. gap_filler.v has no expected index until it
        // has seen a first real frame, so corrupting the very first frame would only become that baseline, no gap would be
        // counted, and the test would silently check nothing. The 300 us pause lets a few frames through as well.
        wait (cnt_raw_frames >= 32'd1);
        #(300000);
        inject_armed <= 1'b1;

        #(300000);
        // Find one committed CPU ring entry by its start and end pointers instead of assuming an entry size. The write
        // pointer is read before a new request goes out, and the interrupt irq_pkt_rx (one pulse per committed
        // entry) marks the moment the pointer is valid for whichever entry commits next. It need not be this explicit
        // request, since the periodic requests keep running, but every non-raw frame in this bench is a discovery reply,
        // so any entry bounds a valid one just as well.
        @(posedge dclk); ring_wr_ptr_before = ring_wr_ptr;
        discover_rqst <= 1'b1;
        @(posedge clk) discover_rqst <= 1'b0;
        @(posedge irq_pkt_rx);
        ring_wr_ptr_after = ring_wr_ptr;

        // Read the entry back now, while it is certain to still be there. The ring is 4 KB and nothing in this bench
        // plays the part of the CPU consuming it, so over a long run later replies wrap around and overwrite it.
        ring_span = (ring_wr_ptr_after - ring_wr_ptr_before) & (CPU_RING_BYTES - 1);
        `CHECK(ring_span != 0, "irq_pkt_rx fired but wr_ptr did not move")
        read_ring_frame(ring_wr_ptr_before);
        `CHECK(rr_len == ring_span - 2,
               $sformatf("CPU ring entry length %0d does not match its own span (wr_ptr %0d -> %0d)",
                         rr_len, ring_wr_ptr_before, ring_wr_ptr_after))
        `CHECK(rr_len == 16'd102, $sformatf("CPU ring entry length %0d, expected 102", rr_len))
        // The ring stores the whole frame from the destination MAC on, not just the UDP payload, so the first six bytes
        // are this bench's own MAC and the next two are the start of the HL2's MAC. The discovery reply's 0xEF 0xFE
        // sits 42 bytes further in, past the Ethernet, IP and UDP headers, beyond the 8 byte read window. Matching
        // the address is just as strong a proof that a real, intact frame landed there.
        `CHECK(rr_bytes[63:16] == MY_MAC,
               $sformatf("CPU ring frame did not start with the destination MAC: got %h, expected %h",
                         rr_bytes[63:16], MY_MAC))
        $display("discovery reply in CPU ring: length=%0d first bytes=%h %h %h %h",
                  rr_len, rr_bytes[63:56], rr_bytes[55:48], rr_bytes[47:40], rr_bytes[39:32]);

        // Stream and check for SIM_US more. The time is counted from here, not from the start, because the setup above
        // takes a variable time until the first frame arrives, and a fixed total would either race the setup at a short
        // SIM_US or waste time at a long one. The constant is 64 bit because sim_us * 1_000_000 in 32 bit arithmetic
        // overflows at 2,147 us and went negative at the 20 ms figure.
        #(64'd1_000_000 * sim_us);

        // Safety byte and interrupt. The status byte is copied into the header of every frame as the HL2 builds it, so
        // the change has to be made, and its result checked, while the stream is still running: once `run` drops, no
        // more raw frames arrive and safety_byte only ever updates from one. The wait must span a whole frame period
        // (about 12.6 us at N = 968, the time 968 samples take at 76.8 Msps), so the timeout is 30 us.
        tx_status <= 8'h81;   // trip bit set (PROTOCOL.md 5.4 bit 7)
        fork
            begin : wait_irq
                @(posedge irq_safety_change);
                $display("t=%0t: irq_safety_change fired, safety_byte=%h", $time, safety_byte);
            end
            begin : timeout_irq
                #(30_000_000);   // 30 us: comfortably more than one N=968 frame period
                `CHECK(0, "irq_safety_change did not fire within one frame period of the change")
            end
        join_any
        disable timeout_irq;
        `CHECK(safety_byte == 8'h81, $sformatf("safety_byte register = %h, expected 81", safety_byte))

        run <= 1'b0;
        disc_enable <= 1'b0;
        // Let everything already on the wire land and drain out of the DUT before counting: the far end finishes the
        // frame it is sending (up to one frame period), and then that frame drains through the ring and the sample FIFO.
        // 40 us is well above that, and it is what makes the checks below exact at any SIM_US.
        #(40_000_000);

        // Final checks.
        `CHECK(samples_checked > 0, "no samples ever came out of the DUT")
        `CHECK(pattern_errors == 0, $sformatf("%0d test-pattern mismatches", pattern_errors))
        // Exactly one frame is corrupted (inject_done latches after the first hit) and nothing else in this bench
        // can lose a frame, so the counts below are exact values and not lower bounds.
        `CHECK(cnt_crc_errors == 32'd1, $sformatf("%0d CRC failures, expected exactly 1 (the injected one)", cnt_crc_errors))
        `CHECK(cnt_gap_events == 32'd1, $sformatf("%0d gap events, expected exactly 1", cnt_gap_events))
        `CHECK(cnt_resync_events == 32'd0, $sformatf("%0d resync events, expected 0", cnt_resync_events))
        // A frame with a flipped bit is dropped and replaced by exactly N zero samples, counted both by the DUT and,
        // independently, by this bench's own output checker.
        `CHECK(cnt_gap_samples == 32'd968,
               $sformatf("gap fill produced %0d zero samples, expected exactly 968 (N)", cnt_gap_samples))
        `CHECK(fill_samples_seen == 968,
               $sformatf("%0d fill samples seen at the output, expected exactly 968 (N)", fill_samples_seen))
        // No sample lost or duplicated anywhere: every good raw frame's 968 samples came out. The pattern check alone
        // would not catch a whole frame going missing between two frames whose indices happen to line up with a fill.
        `CHECK(samples_checked - fill_samples_seen == cnt_raw_frames * 968,
               $sformatf("%0d real samples out, expected %0d (%0d good frames x 968)",
                         samples_checked - fill_samples_seen, cnt_raw_frames * 968, cnt_raw_frames))
        // A handful of good frames shows that the stream runs continuously and not just once, and the 20 ms run reaches
        // over a thousand.
        `CHECK(cnt_raw_frames >= 2, $sformatf("only %0d good raw frames", cnt_raw_frames))
        `CHECK(cnt_ring_frames > 0, "no non-raw frame ever landed in the CPU ring")
        // The only gap may be the injected one, so the far end itself must never have overflowed, which would
        // be a second, legitimate gap in the sample index.
        `CHECK(far_i.ovf_cnt == 16'd0, $sformatf("the far end overflowed %0d times", far_i.ovf_cnt))
        // Loss accounting: the one corrupted frame is the one frame missing by sequence number, and nothing was dropped
        // behind the commit point.
        `CHECK(cnt_seq_lost == 32'd1, $sformatf("%0d frames missing by sequence number, expected 1", cnt_seq_lost))
        `CHECK(cnt_len_errors == 16'd0 && cnt_drain_drops == 16'd0 && cnt_overruns == 16'd0,
               $sformatf("length errors %0d, drain drops %0d, overruns %0d", cnt_len_errors, cnt_drain_drops, cnt_overruns))
`ifdef GAPS
        $display("receive clocks without a byte: %0d", gaps);
        `CHECK(gaps > 100, "the GAPS run had no gaps")
`endif

        $display("samples_checked=%0d fill_samples=%0d raw_frames=%0d other_frames=%0d crc_errors=%0d",
                  samples_checked, fill_samples_seen, cnt_raw_frames, cnt_other_frames, cnt_crc_errors);
        $display("gap_events=%0d gap_samples=%0d resync_events=%0d ring_frames=%0d ring_dropped=%0d",
                  cnt_gap_events, cnt_gap_samples, cnt_resync_events, cnt_ring_frames, cnt_ring_dropped);

        if (errors == 0) $display("PASS");
        else $display("FAIL: %0d errors", errors);
        $finish;
    end

endmodule
