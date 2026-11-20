// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Smoke test of the chip's fabric core, rtl/top/sdr_core.v, which is everything of the radio that lives in
// FPGA logic around the CPU: the HL2 link, the SFP and RJ45 network ports, the receiver bank and its back end,
// the FT8 front end, the spectrum and zoom paths, the audio and USB blocks, the register bridge for the CPU and
// the DDR3 write and read lanes (docs/ARCHITECTURE.md, docs/P1_TOP.md). The bench drives the core the way the
// chip is driven on the board and shows that the blocks are wired together correctly end to end, which the
// benches of the single blocks cannot show. It is a smoke test: every check looks for a sign of life (a
// register that reads back, a counter that moved, a word that landed in memory) and does not compare sample
// values. The terms are in docs/learn/GLOSSARY.md.
//
// Stimulus and models around the core:
//
//   - The HL2 link comes in over transceiver lane 0. The far end is the HL2's own send side RTL (rawstream.v and
//     the real Ethernet send chain, the same far end as sim/h1_link_rx/tb_h1_link_rx.v, from which the far-end
//     section below is copied) in test-pattern mode, running from a clock that is 50 ppm off the link clock. A
//     model of a copper SFP module (1000BASE-X with auto-negotiation, as in sim/hl2sfp/tb_hl2_sfp.v) puts the
//     HL2's bytes on lane 0's receive words, and the HL2 runs on the module's clock.
//   - The network unit on the RJ45 socket (rtl/net, register page NET_BASE) has its RGMII pins looped back
//     (TXC to RXC, TXD to RXD), so a broadcast frame goes out and comes back in through its registers, and its
//     interrupt arrives on line 6.
//   - A register write and read go through the bus bridge: an AHB-lite master model in the AE350's AHB clock
//     (80 MHz) drives the core's Extended-AHB-slave port, as the CPU does.
//   - Receiver data goes out to the chip's DDR3 memory path: both lanes go through rtl/mem/ddr_mem.v into a
//     behavioural model of Gowin's DDR3 IP (sim/mem/ddr3_ip_model.v), whose ready signals drop at random.
//     Receiver 0 is tuned and its back-end ring enabled through the register bridge, and the ring's payload
//     words must land in the model's memory at the programmed address. The core's ddr3_init input is the
//     memory path's own "calibration done". With -DTB_LANE_MODEL the lanes go to
//     sim/ddr3/ddr3_lane_behav_model.v instead, which assumes the simpler handshake of the 256 MB fall-back
//     in docs/F4_DDR.md.
//
// Checks (each failure prints ERROR, and the run ends with PASS or FAIL):
//   1. system.id and system.build read back, a scratch register writes and reads, an unmapped page reads 0,
//      and the identification and a few registers of the SFP, board link, USB audio and USB host pages answer
//   2. rx_bank phase_inc and ctrl read back from their shadow copies, the receiver count is reported, the
//      FT8 front-end registers of one receiver read back (2b), and receivers that are not built read 0
//   3. raw frames arrive (hl2_link.raw_frame_count > 0 through the bridge) and no CRC errors are counted
//   4. the discovery reply lands in the CPU receive ring and reads back through the clk_rx channel of the
//      bridge (page 0xE802_0000): ring_wptr > 0 and the first word's length field matches the frame's size;
//      4b: the CPU transmit queue page answers through the clk_tx channel (tx_status idle)
//   5. receiver 0's back-end ring: payload words are written at ring_base + 2 onwards, and
//      rx_backend.out_count(0) > 0
//   6. the receive-to-DDR3 interrupt path: system.irq_pending bit 0 (packet received) is set and clears
//   7. (memory path only) every word the write arbiter wrote is in the DDR3 IP model's memory at its address,
//      and the model saw no fault (every write command with its data in the same clock, no bad address)
//   8. the SFP cages: lane 0 negotiated and carries the HL2 link without losses, the network unit loops one
//      frame, and the board link on lane 1 carries a stream, a control word and the receivers' own stream
//
// Run it from the repository root:
//   iverilog -g2012 -I rtl/n1 -o sim/out/tb_sdr_core.vvp sim/top/tb_sdr_core.v && vvp sim/out/tb_sdr_core.vvp
// Options: -DTB_LANE_MODEL, -DTR_NRX=<n> (receivers built), -DTB_DEBUG (first receiver samples) and
// -DTB_VCD (waveform of the top level).

// All RTL the core needs is included here by path relative to the repository root, so the bench compiles on
// its own with the command above.
`include "rtl/hl2link/crc32_eth.v"
`include "rtl/n1/enc_8b10b.v"
`include "rtl/n1/fcs_append.v"
`include "rtl/n1/gmii_mac_tx.v"
`include "rtl/n1/gmii_mac_rx.v"
`include "rtl/sfp/sfp_rx_sym.v"
`include "rtl/sfp/sfp_enc20.v"
`include "rtl/sfp/sfp_xstat.v"
`include "rtl/sfp/sfp_pcs.v"
`include "rtl/sfp/sfp_phy.v"
`include "rtl/sfp/sfp_net.v"
`include "rtl/sfp/sfp_top.v"
`include "rtl/blink/blink_tx.v"
`include "rtl/blink/blink_rx.v"
`include "rtl/blink/blink_rx_buf.v"
`include "rtl/blink/blink_top.v"
`include "sim/sfp/sfp_lane_model.v"
`include "rtl/hl2link/cdc_word.v"
`include "rtl/hl2link/cdc_sample_fifo.v"
`include "rtl/hl2link/gmii_rx_in.v"
`include "rtl/hl2link/eth_frame_rx.v"
`include "rtl/hl2link/raw_frame_buffer.v"
`include "rtl/hl2link/gap_filler.v"
`include "rtl/hl2link/cpu_rx_ring.v"
`include "rtl/hl2link/hl2_link_rx_top.v"
`include "rtl/hl2link/gmii_tx_out.v"
`include "rtl/hl2link/crc32_append.v"
`include "rtl/hl2link/cpu_tx_queue.v"
`include "rtl/hl2link/tx_sample_framer.v"
`include "rtl/hl2link/tx_rate_lock.v"
`include "rtl/hl2link/rx_tx_fill_bridge.v"
`include "rtl/hl2link/hl2_link_tx_top.v"
`include "rtl/hl2link/eth_clk_pll.v"
`include "sim/net/otp_model.v"          // Gowin OTP primitive (the chip ID reader in the network unit)
`include "rtl/net/chip_dna.v"
`include "rtl/net/eth_top.v"
`include "rtl/net/net_unit.v"
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
`include "rtl/spectrum/spectrum_pipeline.v"
`include "rtl/zoom/cic_var_pow2.v"
`include "rtl/zoom/zoom_fir_half.v"
`include "rtl/zoom/zoom_cic_comp.v"
`include "rtl/zoom/zoom_ddc.v"
`include "rtl/zoom/zoom_window.v"
`include "rtl/zoom/zoom_spectrum.v"
`include "rtl/zoom/zoom_frontend.v"
`include "rtl/video/waterfall_writer.v"
`include "rtl/video/compositor_util.v"
`include "rtl/video/compositor_fetch.v"
`include "rtl/video/compositor_pix.v"
`include "rtl/video/compositor.v"
`include "rtl/tx/tx_fir_interp4.v"
`include "rtl/tx/CicInterpM5.v"
`include "rtl/tx/tx_chain.v"
`include "rtl/audio/audio_ring_reader.v"
`include "rtl/audio/audio_interp_x8.v"
`include "rtl/audio/audio_nco_tick.v"
`include "rtl/audio/audio_pt8211_tx.v"
`include "rtl/audio/audio_engine.v"
`include "rtl/audio/audio_out_src.v"
`include "rtl/audio/audio_spdif_tx.v"
`include "rtl/audio/audio_digital_out.v"
`include "rtl/ddr3/ddr3_write_arbiter.v"
`include "rtl/ddr3/ddr3_wr_relay.v"
`include "rtl/ddr3/ddr3_rd_relay.v"
`include "rtl/ddr3/ddr3_read_arbiter.v"
`define TR_FFT_INCLUDED          // rtl/spectrum/spectrum_pipeline.v above already includes the FFT, so ft8_frontend must not include it again
`include "rtl/ft8/ft8_frontend.v"
`include "rtl/top/ahb_reg_bridge.v"
`include "rtl/top/regbus_cdc_dst.v"
`include "rtl/top/regbus_leg.v"
`include "rtl/top/sys_regs.v"
`include "rtl/top/hl2_link_regs.v"
`include "rtl/top/hl2_pkt_port.v"
`include "rtl/top/block_regs.v"
`include "rtl/top/rd_word_adapter.v"
`include "rtl/top/p1_stubs.v"
`include "rtl/usb/usb_fs_phy.v"
`include "rtl/usb/usb_fs_core.v"
`include "rtl/usb/usb_afifo.v"
`include "rtl/usb/usb_ep0.v"
`include "rtl/usb/usb_ep_cap.v"
`include "rtl/usb/usb_ep_play.v"
`include "rtl/usb/usb_play.v"
`include "rtl/usb/usb_regs.v"
`include "rtl/usb/usb_audio.v"
`include "rtl/usbh/usbh_phy.v"
`include "rtl/usbh/usbh_port.v"
`include "rtl/usbh/usbh_iso_out.v"
`include "rtl/usbh/usbh_iso_in.v"
`include "rtl/usbh/usbh_regs.v"
`include "rtl/usbh/usbh_top.v"
`include "rtl/top/sdr_core.v"
`include "sim/ddr3/ddr3_lane_behav_model.v"
`include "rtl/mem/ddr_mem.v"
`include "sim/mem/ddr3_ip_model.v"

// The HL2's own send side, used as the far end of the link, taken from the h1_link_rx bench.
`include "sim/h1_link_rx/dcfifo_sim_stub.v"
`include "sim/h1_link_rx/hl2/rawstream.v"
`include "sim/h1_link_rx/hl2/udp_send.v"
`include "sim/h1_link_rx/hl2/ip_send.v"
`include "sim/h1_link_rx/hl2/mac_send.v"
`include "sim/h1_link_rx/hl2/crc32.v"
`include "sim/h1_link_rx/hl2/rgmii_send.v"

// Generated register definitions (address and field macros) for the pages that this bench uses.
`include "hw/regmap/generated/system_regs.vh"
`include "hw/regmap/generated/hl2_link_regs.vh"
`include "hw/regmap/generated/hl2_pkt_regs.vh"
`include "hw/regmap/generated/rx_bank_regs.vh"
`include "hw/regmap/generated/rx_backend_regs.vh"
`include "hw/regmap/generated/net_regs.vh"

// The timescale comes after the includes (the reason is given in sim/h1_link_rx/tb_h1_link_rx.v); all delays
// below are in picoseconds with 1 fs of resolution, which is fine enough to write the 50 ppm clock offset.
`timescale 1ps / 1fs

module tb_sdr_core;

    // Addresses of the HL2 (the far end) and of the chip side (MY_*), and the UDP port the HL2 sends to. BUILD
    // is a value that system.build must read back, and RING0 is the lane-word address of receiver 0's ring.
    localparam [47:0] HL2_MAC = 48'h02_00_00_00_00_02;
    localparam [31:0] HL2_IP  = 32'h0a63_0002;   // 10.99.0.2
    localparam [47:0] MY_MAC  = 48'h02_00_00_00_00_01;
    localparam [31:0] MY_IP   = 32'h0a63_0001;   // 10.99.0.1
    localparam [15:0] MY_PORT = 16'd51000;
    localparam [31:0] BUILD   = 32'h1234_5678;
    localparam [31:0] RING0   = 32'd4096;        // receiver 0 back-end ring, lane words

    // ------------------------------------------------------------------ clocks
    logic clk = 1'b0;                              // 125 MHz RGMII (far end TX = our RX clock)
    always #4000 clk = ~clk;
    // Half period 6,510.0912 ps makes a 13,020.18 ps period, which is 50 ppm faster than the nominal 76.8 MHz
    // (13,020.83 ps), so the HL2's ADC clock is not locked to the 125 MHz link clock, as on the real line. The
    // other clocks also start at different offsets, so that no two edges line up.
    logic clk_ad = 1'b0;                           // HL2 ADC clock, 76.8 MHz + 50 ppm
    initial begin #1733; forever #6510.0912 clk_ad = ~clk_ad; end
    logic clk_dsp = 1'b0;                          // 120 MHz
    initial begin #907; forever #4166.667 clk_dsp = ~clk_dsp; end
    logic hclk = 1'b0;                             // AE350 AHB, 80 MHz
    initial begin #211; forever #6250 hclk = ~hclk; end
    // The bridge's request toggles have no initial value in the RTL, while the flip-flops of the chip start
    // at 0. In simulation they start as X, and with both sides in reset copying each other's toggle (the bridge
    // sets request from acknowledge, the far side acknowledge from request) an X that gets into that loop
    // before the first AHB edge never leaves it, depending on the phase between the two clocks. Setting them
    // to 0 here is what the chip does by itself.
    initial begin dut.u_bridge.req_tog0 = 1'b0; dut.u_bridge.req_tog1 = 1'b0; dut.u_bridge.req_tog2 = 1'b0;
                  dut.u_bridge.req_tog3 = 1'b0; end
    logic clk_50m = 1'b0;                          // board oscillator, 50 MHz (input of the Ethernet PLL model)
    initial begin #1300; forever #10000 clk_50m = ~clk_50m; end
    logic clk_mem = 1'b0;                          // DDR3 memory clock, 400 MHz
    initial begin #333; forever #1250 clk_mem = ~clk_mem; end
    // About 74 MHz (13,468 ps period) is the video pixel clock; the exact rate does not matter here.
    logic clk_pix = 1'b0;                          // pixel clock (any rate will do here)
    initial begin #500; forever #6734 clk_pix = ~clk_pix; end

    // The far end drives the HL2's raw sender: run starts the stream, cmd_* is its command port (used below to
    // select the test pattern and the frame size), discover_rqst asks for one discovery reply, and adc is a
    // counting stand-in for the HL2's ADC data.
    // ------------------------------------------------------------------ far end (HL2 RTL)
    logic        run = 1'b0;
    logic [ 5:0] cmd_addr = 6'h0;
    logic [31:0] cmd_data = 32'h0;
    logic        cmd_rqst = 1'b0;
    logic        discover_rqst = 1'b0;
    logic [ 7:0] tx_status = 8'h01;
    logic [11:0] adc = 12'h0;
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
        .clk_ad(clk_ad), .adc_data(adc), .clk(clk), .run(run),
        .cmd_addr(cmd_addr), .cmd_data(cmd_data), .cmd_rqst(cmd_rqst), .raw_mode(raw_mode),
        .pkt_tx_request(pkt_req), .pkt_tx_length({5'h0, pkt_len}), .pkt_tx_data(pkt_data),
        .pkt_tx_enable(pkt_en),
        .udp_tx_request(udp_tx_request), .udp_tx_length(udp_tx_length), .udp_tx_data(udp_tx_data),
        .udp_tx_enable(udp_tx_enable), .udp0_tx_enable(udp0_tx_enable), .udp_tx_busy(udp_tx_busy),
        .dup_on(1'b0), .dup_status(160'd0), .tx_status(tx_status)
    );

    // Discovery reply packer, copied from sim/h1_link_rx/tb_h1_link_rx.v. On discover_rqst it hands the HL2's UDP
    // sender a 60 byte (0x3c) discovery reply: 0xEF 0xFE, a status byte (3 while run is set, else 2), the MAC
    // address 00:1c:c0:a2:13:dd and filler, so that the chip's CPU receive ring has a frame to catch.
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

    // Stand-in for the HL2's transmit arbiter: when the UDP sender asks to send (udp_tx_request = 2'b10) the
    // request is granted after one clock (tx_ready, then tx_start), and udp_tx_busy stays high until the RGMII
    // sender has finished the frame.
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

    // The HL2's own send chain, UDP into IP into MAC into RGMII, with the HL2's addresses and the chip as the
    // destination.
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
    // The send modules have no reset in the simulation, so their byte counters and sending flags start at 0.
    initial begin
        udp_send_inst.byte_no = 16'd0; udp_send_inst.sending = 1'b0;
        ip_send_inst.byte_no = 5'd0;   ip_send_inst.sending = 1'b0;
    end

    // Wire-level tap of the far end's RGMII sender (as in tb_h1_link_rx.v, without error injection): every
    // clock the byte on the wire and a flag that it belongs to a frame go into the queue mq, which the copper
    // module model below reads and turns into 1000BASE-X symbols.
    wire       far_sending = rgmii_send_inst.sending;
    wire [7:0] far_byte    = rgmii_send_inst.shift_reg[63:56];
    reg [8:0]  mq [0:1023];
    integer    mw = 0, mr = 0;
    always @(posedge clk) begin mq[mw % 1024] = {far_sending, far_byte}; mw = mw + 1; end

    // The core's resets: rst_dsp and rst_rx are released together with hresetn, the AHB reset, at the start of
    // the sequence below.
    // ------------------------------------------------------------------ DUT
    logic rst_dsp = 1'b1, rst_rx = 1'b1, hresetn = 1'b0;

    // AHB-lite master signals, driven by ahb_write and ahb_read below; the core is the slave.
    logic        hsel = 1'b0, hwrite = 1'b0;
    logic [31:0] haddr = 32'd0, hwdata = 32'd0;
    logic [1:0]  htrans = 2'b00;
    wire         hreadyout, hresp;
    wire  [31:0] hrdata;
    wire  [15:0] ext_int;

    // Write lane 4 and read lane 5 of the DDR3 fabric, as the core presents them to the memory path.
    wire [31:0] addr_lane4, addr_lane5;
    wire [7:0]  wr_mask_lane4, burstcount_lane4, burstcount_lane5;
    wire [63:0] wr_data_lane4, rd_data_lane5;
    wire        wr_en_lane4, wr_go_lane4, wr_wait_lane4, wr_done_lane4;
    wire        rd_en_lane5, rd_go_lane5, rd_valid_lane5, rd_rdy_lane5;
    wire        ddr3_init;

    // Raster position (a 200 by 100 pixel frame) for the compositor, which only needs a running position here.
    logic [11:0] vid_cx = 12'd0;
    logic [10:0] vid_cy = 11'd0;
    always @(posedge clk_pix) begin
        vid_cx <= (vid_cx == 12'd199) ? 12'd0 : vid_cx + 12'd1;
        if (vid_cx == 12'd199) vid_cy <= (vid_cy == 11'd99) ? 11'd0 : vid_cy + 11'd1;
    end

    // Receivers built: the core's own default of 4, or -DTR_NRX=<n>. TRX is the receiver whose FT8 front-end
    // registers are tested (3, or 5 when more than 5 receivers are built).
`ifdef TR_NRX
    localparam integer NRX = `TR_NRX;
`else
    localparam integer NRX = 4;           // = the core's default
`endif
    localparam integer TRX = (NRX > 5) ? 5 : 3;
    wire usb_pullup;
    // SFP cages: each lane's transmit words come back as its receive words through the lane model, which is a
    // cable from the cage to itself, at a bit position that the aligners in the receive path have to find.
    reg         sfp_txc = 1'b0;
    always #4000 sfp_txc = ~sfp_txc;
    wire [9:0]  ln0_tx, ln0_rx;
    wire [19:0] ln1_tx, ln1_rx;
    wire        n1_rxc, bl_rxc;
    wire        led_stream;
    // lane 0: the HL2 through the copper module (its 1000BASE-X words on the far end's clock `clk`)
    wire [9:0]  p_tx;
    sfp_lane_model #(.W(10), .OFFSET(6)) u_lane0 (.tx_clk(clk), .tx_word(p_tx), .rx_clk(n1_rxc),
                                                  .rx_word(ln0_rx), .err(10'd0), .cut(1'b0));
    sfp_lane_model #(.W(20), .OFFSET(11), .DELAY(3.1)) u_lane1 (.tx_clk(sfp_txc), .tx_word(ln1_tx), .rx_clk(bl_rxc),
                                                  .rx_word(ln1_rx), .err(20'd0), .cut(1'b0));
    // the RJ45 PHY: its pins looped back (the network unit hears itself)
    wire        e_txc, e_txctl;
    wire [3:0]  e_txd;
    // The two timer parameters of the SFP block are set to short values so that link negotiation finishes
    // within the short simulated time.
    sdr_core #(.SFP_TIMER_X(3000), .SFP_TIMER_SGMII(800)) dut (
        .clk_dsp(clk_dsp), .rst_dsp(rst_dsp), .rst_rx(rst_rx),
        .clk_50m(clk_50m), .clk_pix(clk_pix),
        .hclk(hclk), .hresetn(hresetn), .hsel(hsel), .haddr(haddr), .htrans(htrans),
        .hwrite(hwrite), .hsize(3'b010), .hwdata(hwdata),
        .hreadyout(hreadyout), .hrdata(hrdata), .hresp(hresp), .ext_int(ext_int),
        .addr_lane4(addr_lane4), .wr_mask_lane4(wr_mask_lane4), .wr_data_lane4(wr_data_lane4),
        .wr_en_lane4(wr_en_lane4), .wr_go_lane4(wr_go_lane4), .burstcount_lane4(burstcount_lane4),
        .wr_wait_lane4(wr_wait_lane4), .wr_done_lane4(wr_done_lane4),
        .addr_lane5(addr_lane5), .rd_en_lane5(rd_en_lane5), .rd_go_lane5(rd_go_lane5),
        .burstcount_lane5(burstcount_lane5), .rd_valid_lane5(rd_valid_lane5),
        .rd_data_lane5(rd_data_lane5), .rd_rdy_lane5(rd_rdy_lane5),
        .rgmii_rxc(e_txc), .rgmii_rxd(e_txd), .rgmii_rx_ctl(e_txctl),
        .rgmii_txc(e_txc), .rgmii_txd(e_txd), .rgmii_tx_ctl(e_txctl), .phy_clk(), .phy_rst_n(), .phy_mdc(), .phy_mdio_o(), .phy_mdio_oe(),
        .phy_mdio_i(1'b1),
        .sfp_txc(sfp_txc), .n1_rxc(n1_rxc), .bl_txc(sfp_txc), .bl_rxc(bl_rxc),
        .ln0_tx(ln0_tx), .ln0_rx(ln0_rx), .ln0_rx_vld(1'b1), .ln1_tx(ln1_tx), .ln1_rx(ln1_rx), .ln1_rx_vld(1'b1),
        .serdes_por_n(), .ln_rst_n(), .ln_rx_rst(), .ln_tx_rst(), .ln0_fix(), .ln1_fix(),
        .ln0_stat(4'hF), .ln1_stat(4'hF), .sfp_diag(12'h0A5), .sfp_tx_disable(), .sfp_los(2'b00),
        .twi_scl_o(), .twi_sda_o(), .twi_scl_i(1'b1), .twi_sda_i(1'b1), .twi_sel(),
        .pt8211_bck(), .pt8211_ws(), .pt8211_din(),
        // audio outputs: the board oscillator stands in for the 49.152 MHz audio clock here
        .clk_aud(clk_50m), .aud_lock(1'b1), .spdif_out(), .i2s_bck(), .i2s_ws(), .i2s_sd(), .i2s_mclk(),
        .aud48_valid(), .aud48_l(), .aud48_r(),
        // USB audio: no host on the lines (D+ pulled up, D- low: the idle state); the board oscillator stands
        // in for the 48 MHz clock. The USB side has its own bench, sim/usb/tb_usb_audio.v.
        .clk_usb(clk_50m), .usb_dp_i(1'b1), .usb_dn_i(1'b0), .usb_dp_o(), .usb_dn_o(), .usb_oe(),
        .usb_pullup(usb_pullup),
        // USB host: empty sockets (the unit has its own bench, sim/usbh/tb_usbh.v)
        .usbh_a_i(2'b00), .usbh_b_i(2'b00), .usbh_a_o(), .usbh_b_o(), .usbh_oe(),
        .vid_cx(vid_cx), .vid_cy(vid_cy),
        .build_id(BUILD), .ddr3_init(ddr3_init), .plls_locked(1'b1), .led_rx_streaming(led_stream)
    );

    // ------------------------------------------------------------------ the copper module
    // A model of an SFP module with a 1000BASE-T copper side, as in sim/hl2sfp/tb_hl2_sfp.v, with the HL2 behind
    // it. On lane 0's receive words it sends 1000BASE-X symbols, 10 bits per clock at 125 MHz (the 1.25 Gbaud
    // line rate), coded in 8b10b (docs/learn/GLOSSARY.md). First comes the auto-negotiation: configuration
    // ordered sets (the comma K28.5 followed by D21.5 or D2.2 in turn, then a 16-bit word in two bytes), where
    // the word 0x0020 advertises full duplex and 0x4020 adds the acknowledge bit. After the chip has
    // acknowledged and the HL2 is between two frames, the model switches to data mode (p_mode) and sends the
    // frames from the queue mq as 1000BASE-X frames: a start of packet symbol (K27.7), the bytes, an end of
    // packet (K29.7 and K23.7), and idle ordered sets (K28.5 with D5.6 or D16.2, chosen by the running
    // disparity) in between.
    // The 8b10b encode and decode functions (enc8b10b_d, enc8b10b_k, dec8b10b), found through -I rtl/n1.
`include "tab_8b10b.vh"
    // p_rd is the running disparity of the encoder, p_mode 0 while negotiating and 1 in data mode, c2 picks
    // C1 or C2 in turn, cpos counts the four symbols of a configuration word (comma, C1 or C2, low byte, high
    // byte), p_code is the symbol on the wire, ms the data mode state and p_word the configuration word sent.
    reg        p_rd = 0, p_mode = 0, pos = 0, c2 = 0;
    reg [9:0]  p_code = 0;
    reg [2:0]  ms = 0;
    reg [1:0]  cpos = 0;
    reg [15:0] p_word = 16'h0020;
    // The transmitted bits are in the opposite order on the lane, so the code is reversed.
    assign p_tx = {p_code[0], p_code[1], p_code[2], p_code[3], p_code[4], p_code[5], p_code[6], p_code[7], p_code[8], p_code[9]};
    // Encode one data or control symbol with the current running disparity into p_code and update the
    // disparity (bit 0 of the encoder's result).
    task psym(input [7:0] d, input k);
        reg [10:0] e;
        begin e = k ? enc8b10b_k(d, p_rd) : enc8b10b_d(d, p_rd); p_code <= e[10:1]; p_rd = e[0]; end
    endtask
    // The oldest queue entries, {sending flag, byte}; lvl is the queue fill (write pointer minus read pointer).
    wire [8:0] head = mq[mr % 1024], next = mq[(mr + 1) % 1024];
    integer lvl;
    // One symbol per clock. In negotiation mode the queue's read pointer only moves when the queue grows too
    // full, since nothing is sent. In data mode the state ms picks the next symbol from the queue head: a start
    // of frame and the bytes of a frame, then the end of packet symbols, and idles in between, where entries
    // that are not part of a frame are skipped as needed to keep the queue short.
    always @(posedge clk) begin
        #1;
        lvl = mw - mr;
        if (!p_mode) begin
            case (cpos)
                2'd0: psym(8'hBC, 1);
                2'd1: psym(c2 ? 8'h42 : 8'hB5, 0);
                2'd2: psym(p_word[7:0], 0);
                default: begin psym(p_word[15:8], 0); c2 = ~c2; end
            endcase
            cpos = cpos + 2'd1;
            if (lvl > 6) mr = mr + 1;
            pos = 0; ms = 0;
        end else begin
            case (ms)
                3'd0: if (lvl > 0 && head[8]) begin psym(8'hFB, 1); mr = mr + 1; ms = 2; end
                      else begin psym(8'hBC, 1); if (lvl > 0) mr = mr + 1; if (lvl > 8 && !next[8]) mr = mr + 1; ms = 1; end
                3'd1: begin psym(!p_rd ? 8'hC5 : 8'h50, 0); if (lvl > 0 && !head[8]) mr = mr + 1; ms = 0; end
                3'd2: if (lvl > 0 && head[8]) begin psym(head[7:0], 0); mr = mr + 1; end
                      else begin psym(8'hFD, 1); if (lvl > 0) mr = mr + 1; ms = 3; end
                default: begin psym(8'hF7, 1); if (lvl > 0 && !head[8]) mr = mr + 1; ms = pos ? 3'd0 : 3'd3; end
            endcase
            pos = ~pos;
        end
    end
    // The chip's own configuration words as the module reads them (lane 0's transmitter, aligned): after a
    // comma followed by C1 or C2, the next two data bytes make a word, and d_cfg_n counts how often the same
    // word came in a row.
    wire [9:0] rcode = {ln0_tx[0], ln0_tx[1], ln0_tx[2], ln0_tx[3], ln0_tx[4], ln0_tx[5], ln0_tx[6], ln0_tx[7], ln0_tx[8], ln0_tx[9]};
    wire [9:0] rdec = dec8b10b(rcode);
    reg [7:0]  prev_d = 0; reg prev_k = 0; reg [1:0] rpos = 0; reg [7:0] clo = 0;
    reg [15:0] d_cfg = 0; integer d_cfg_n = 0, acks = 0;
    always @(posedge sfp_txc) begin
        if (rpos == 1) begin clo = rdec[7:0]; rpos = 2; end
        else if (rpos == 2) begin
            rpos = 0;
            if ({rdec[7:0], clo} == d_cfg) d_cfg_n = d_cfg_n + 1; else d_cfg_n = 1;
            d_cfg = {rdec[7:0], clo};
        end else if (prev_k && prev_d == 8'hBC && !rdec[8] && (rdec[7:0] == 8'hB5 || rdec[7:0] == 8'h42)) rpos = 1;
        prev_d = rdec[7:0]; prev_k = rdec[8];
    end
    // Negotiation: once the chip's word has come three times in a row the module acknowledges it (bit 14), and
    // when the chip acknowledges in turn the module counts it; after 1,000 such words, and only between two of
    // the HL2's frames (a frame cut off at its start would have a bad FCS), it goes to data mode.
    always @(posedge clk) if (!p_mode) begin
        if (d_cfg_n >= 3 && (d_cfg & 16'hBFFF) == 16'h0020) p_word <= 16'h4020; else p_word <= 16'h0020;
        if (d_cfg_n >= 3 && d_cfg == 16'h4020 && cpos == 2'd0) acks = acks + 1;
        if (acks > 1000 && !far_sending && !head[8]) p_mode <= 1'b1;
    end

    // ---- DDR3 begin
    // Two alternatives for the memory the lanes write into. The default is the chip's real memory path
    // (rtl/mem/ddr_mem.v) with a model of Gowin's DDR3 IP behind it.
`ifdef TB_LANE_MODEL
    // Behavioural lane model with 65,536 words, in which 3 % of the idle clocks start a stall of up to
    // 16 clocks; the memory is ready from the start, so ddr3_init is tied high.
    assign ddr3_init = 1'b1;

    ddr3_lane_behav_model #(.MEM_WORDS(65536), .STALL_NUM(30), .STALL_DEN(1000),
                            .STALL_MAX_CYCLES(16), .SEED(32'h0B1C_0DE5)) u_ddr (
        .clk(clk_dsp), .rst(rst_dsp),
        .addr_lane4(addr_lane4), .wr_mask_lane4(wr_mask_lane4), .wr_data_lane4(wr_data_lane4),
        .wr_en_lane4(wr_en_lane4), .wr_go_lane4(wr_go_lane4), .burstcount_lane4(burstcount_lane4),
        .wr_wait_lane4(wr_wait_lane4), .wr_done_lane4(wr_done_lane4),
        .addr_lane5(addr_lane5), .rd_en_lane5(rd_en_lane5), .rd_go_lane5(rd_go_lane5),
        .burstcount_lane5(burstcount_lane5), .rd_valid_lane5(rd_valid_lane5),
        .rd_data_lane5(rd_data_lane5), .rd_rdy_lane5(rd_rdy_lane5), .phys_busy()
    );

    // Word w of the lane model's memory.
    function [63:0] ddr_word(input [31:0] w); ddr_word = u_ddr.mem[w]; endfunction
    // The lane model has no start content to compare with and no fault counter, so these are X and 0.
    wire [63:0] ddr_fresh = 64'bx;                 // a word nothing has written
    function [63:0] ddr_start(input [31:0] w); ddr_start = 64'bx; endfunction
    wire [31:0] ddr_faults = 32'd0;
`else
    // The chip's memory path: the bridge and Gowin's DDR3 IP (a model). The processor's data memory bus is at
    // rest here, since the core has no part in it; sim/mem/tb_ddr_mem.v drives all three sides.
    ddr_mem u_mem (
        .ddr3_clk_in(clk_50m), .ddr3_mem_clk(clk_mem), .ddr3_lock(1'b1), .ddr3_stop(),
        .rstn(~rst_dsp), .init(ddr3_init),
        .DDR3_BANK(), .DDR3_CS_N(), .DDR3_RAS_N(), .DDR3_CAS_N(), .DDR3_WE_N(), .DDR3_CK(), .DDR3_CK_N(),
        .DDR3_CKE(), .DDR3_RESET_N(), .DDR3_ODT(), .DDR3_ADDR(), .DDR3_DM(), .DDR3_DQ(), .DDR3_DQS(),
        .DDR3_DQS_N(),
        .hclk(clk_50m), .hrstn(1'b1), .haddr(32'd0), .hsize(3'd0), .htrans(2'b00), .hwrite(1'b0),
        .hwdata(64'd0), .hready(), .hresp(), .hrdata(),
        .lane_clk(clk_dsp), .lane_rst(rst_dsp),
        .addr_lane4(addr_lane4), .wr_mask_lane4(wr_mask_lane4), .wr_data_lane4(wr_data_lane4),
        .wr_en_lane4(wr_en_lane4), .burstcount_lane4(burstcount_lane4),
        .wr_wait_lane4(wr_wait_lane4), .wr_done_lane4(wr_done_lane4),
        .addr_lane5(addr_lane5), .rd_en_lane5(rd_en_lane5), .burstcount_lane5(burstcount_lane5),
        .rd_valid_lane5(rd_valid_lane5), .rd_data_lane5(rd_data_lane5), .rd_rdy_lane5(rd_rdy_lane5)
    );
    // a 64-bit lane word in the model's memory: line = word / 4 (32 bytes a line)
    function [63:0] ddr_word(input [31:0] w); ddr_word = u_mem.u_ddr3.mem[w[13:2]][64 * w[1:0] +: 64]; endfunction
    // the model's start content of receiver 0's ring (line i = eight words 0xDEAD0000 + i)
    function [63:0] ddr_start(input [31:0] w); reg [31:0] v; begin v = 32'hDEAD_0000 + (w >> 2); ddr_start = {v, v}; end endfunction
    wire [63:0] ddr_fresh = ddr_start(RING0 + 2);
    wire [31:0] ddr_faults = u_mem.u_ddr3.errors;
    // A shadow memory of what the write arbiter means, word by word (the lane's contract in
    // sim/ddr3/ddr3_lane_behav_model.v: every beat in a clock with wr_en and without wr_wait goes to
    // addr_lane4 plus the number of beats of this burst so far, selected by the byte mask, and the burst ends
    // with wr_done). sh_v marks the words that were written and sh_last is the newest one. Check 7 compares the
    // IP model's memory with this.
    reg [63:0]  sh_mem [0:16383];
    reg         sh_v   [0:16383];
    reg [7:0]   sh_idx = 8'd0;
    reg [31:0]  sh_last = 32'hFFFF_FFFF;
    integer     sh_i, sh_beats = 0;
    wire [31:0] sh_a = addr_lane4 + sh_idx;
    initial for (sh_i = 0; sh_i < 16384; sh_i = sh_i + 1) begin
        sh_v[sh_i] = 1'b0; sh_mem[sh_i] = ddr_start(sh_i);
    end
    always @(posedge clk_dsp) begin
        if (wr_en_lane4 && !wr_wait_lane4) begin
            sh_beats = sh_beats + 1;
            sh_idx <= sh_idx + 8'd1;
            if (sh_a < 32'd16384) begin
                for (sh_i = 0; sh_i < 8; sh_i = sh_i + 1)
                    if (wr_mask_lane4[sh_i]) sh_mem[sh_a[13:0]][8*sh_i +: 8] = wr_data_lane4[8*sh_i +: 8];
                sh_v[sh_a[13:0]] = 1'b1;
            end
            sh_last = sh_a;
        end
        if (wr_done_lane4) sh_idx <= 8'd0;
    end
`endif
    // ---- DDR3 end

    // Count the write beats on lane 4 whose address lies inside receiver 0's ring (4 slots of 66 lane words,
    // which is the size of an IQ slot, from RING0 on), which shows that the receiver's data really leave
    // the back end through the write arbiter.
    integer ring_beats = 0;
    always @(posedge clk_dsp)
        if (wr_en_lane4 && !wr_wait_lane4 && addr_lane4 >= RING0 && addr_lane4 < RING0 + 32'd66 * 4)
            ring_beats = ring_beats + 1;

    // Debug prints (-DTB_DEBUG): the first bank samples of receiver 0 and the first back-end outputs.
`ifdef TB_DEBUG
    integer dbg_b = 0, dbg_k = 0;
    always @(posedge clk_dsp) begin
        if (dut.bank_valid && dut.bank_index == 3'd0 && dbg_b < 40) begin
            dbg_b = dbg_b + 1;
            if (dbg_b % 4 == 0) $display("t=%0t bank rx0 i=%0d q=%0d", $time, dut.bank_i, dut.bank_q);
        end
        if (dut.bk_valid && dbg_k < 20) begin
            dbg_k = dbg_k + 1;
            $display("t=%0t backend rx%0d s0=%h s1=%h iq=%b", $time, dut.bk_rx, dut.bk_s0, dut.bk_s1, dut.bk_iq);
        end
    end
`endif

    // ------------------------------------------------------------------ AHB-lite master model
    integer errors = 0;
    // CHECK counts an error and prints its message unless the condition is exactly true, so an X counts as a
    // failure.
    `define CHECK(cond, msg) if ((cond) !== 1'b1) begin errors = errors + 1; $display("ERROR t=%0t: %s", $time, msg); end

    // AHB-lite write: the address phase with a non-sequential transfer, then the data phase, then wait until
    // hreadyout is high (the bridge stretches the access while it crosses clock domains). The signals change
    // 1 ns after the clock edge.
    task ahb_write(input [31:0] a, input [31:0] d);
        begin
            @(posedge hclk); #1;
            hsel = 1'b1; htrans = 2'b10; hwrite = 1'b1; haddr = a;
            @(posedge hclk); #1;                   // address phase accepted (HREADY was high)
            hsel = 1'b0; htrans = 2'b00; hwrite = 1'b0; hwdata = d;
            while (hreadyout !== 1'b1) begin @(posedge hclk); #1; end
        end
    endtask

    // AHB-lite read: the same, and the data is taken when hreadyout is high.
    task ahb_read(input [31:0] a, output [31:0] d);
        begin
            @(posedge hclk); #1;
            hsel = 1'b1; htrans = 2'b10; hwrite = 1'b0; haddr = a;
            @(posedge hclk); #1;
            hsel = 1'b0; htrans = 2'b00;
            while (hreadyout !== 1'b1) begin @(posedge hclk); #1; end
            d = hrdata;
        end
    endtask

    // ------------------------------------------------------------------ sequence
    logic [31:0] v;
    integer      t0, len, k, nonzero;
    initial begin
        // -DTB_VCD dumps the signals of this top level only (depth 1) into a waveform file.
`ifdef TB_VCD
        $dumpfile("build/tb_sdr_core.vcd");
        $dumpvars(1, tb_sdr_core);
`endif
        // Reset for 100 ns, release the three resets, and wait 20 ns before the first access.
        #100037;
        rst_dsp = 1'b0; rst_rx = 1'b0; hresetn = 1'b1;
        #20000;

        // 1. bridge: identification, scratch, unmapped page
        ahb_read(`SYSTEM_ID_ABS_ADDR, v);
        `CHECK(v == `SYSTEM_ID_RESET, $sformatf("system.id %08x", v))
        ahb_read(`SYSTEM_BUILD_ABS_ADDR, v);
        `CHECK(v == BUILD, $sformatf("system.build %08x", v))
        ahb_write(`SYSTEM_SCRATCH_ABS_ADDR, 32'hA5C3_0F96);
        ahb_read(`SYSTEM_SCRATCH_ABS_ADDR, v);
        `CHECK(v == 32'hA5C3_0F96, $sformatf("system.scratch %08x", v))
        ahb_read(32'hE810_0000, v);
        `CHECK(v == 32'd0, $sformatf("unmapped page 0x10 reads %08x", v))
        // SFP pages: identification, then both links switched on so that they come up during the tests below
        ahb_read(32'hE80A_0000, v);
        `CHECK(v == 32'h5346_0001, $sformatf("sfp.id %08x", v))
        ahb_read(32'hE80B_0000, v);
        `CHECK(v == 32'h424C_0001, $sformatf("blink.id %08x", v))
        ahb_write(32'hE80A_0004, 32'h0000_0007);       // transceiver out of reset
        ahb_write(32'hE80A_0020, 32'h0000_0005);       // lane 0 (HL2): PCS on, 1000BASE-X with negotiation
        ahb_write(32'hE80B_0004, 32'h0000_0003);       // board link: enable, send the HL2 stream
        ahb_read(`HL2_LINK_ID_ABS_ADDR, v);
        `CHECK(v == `HL2_LINK_ID_RESET, $sformatf("hl2_link.id %08x", v))
        // USB audio page 0x0E: id, the pull-up on after reset, the CPU FIFO empty, no PC
        ahb_read(`USB_ID_ABS_ADDR, v);
        `CHECK(v == `USB_ID_RESET, $sformatf("usb.id %08x", v))
        ahb_read(`USB_CTRL_ABS_ADDR, v);
        `CHECK(v == 32'd1 && usb_pullup === 1'b1, $sformatf("usb.ctrl %08x pull-up %b", v, usb_pullup))
        // USB host page 0x0F: id, the speaker register's reset value, a slot written and read back, empty sockets
        ahb_read(`USBH_ID_ABS_ADDR, v);
        `CHECK(v == `USBH_ID_RESET, $sformatf("usbh.id %08x", v))
        ahb_read(`USBH_SPK_ABS_ADDR, v);
        `CHECK(v == 32'h0000_3000, $sformatf("usbh.spk %08x", v))
        ahb_write(`USBH_SLOT1_ABS_ADDR(1), 32'h0000_0083);
        ahb_read(`USBH_SLOT1_ABS_ADDR(1), v);
        `CHECK(v == 32'h0000_0083, $sformatf("usbh.slot1[1] %08x", v))
        ahb_read(`USBH_PORT_STATUS_ABS_ADDR(0), v);
        `CHECK(v[3:0] == 4'd0, $sformatf("usbh.port_status[0] %08x", v))
        ahb_write(`USB_FIFO_MARK_ABS_ADDR, 32'd300);
        ahb_read(`USB_FIFO_MARK_ABS_ADDR, v);
        `CHECK(v == 32'd300, $sformatf("usb.fifo_mark %08x", v))
        ahb_read(`USB_STATUS_ABS_ADDR, v);
        `CHECK(v == 32'd0, $sformatf("usb.status %08x", v))
        ahb_read(`USB_FIFO_DATA_ABS_ADDR, v);
        `CHECK(v == 32'd0, $sformatf("usb.fifo_data %08x", v))
        $display("t=%0t: bridge register write/read OK", $time);

        // HL2 addressing for the raw-frame classifier; interrupts on
        ahb_write(`HL2_LINK_HL2_IP_ABS_ADDR, HL2_IP);
        ahb_write(`SYSTEM_IRQ_ENABLE_ABS_ADDR, 32'h0000_FFFF);

        // 2. receiver 0: 303 kHz, 48 ksps out of the bank, enabled (phase_inc = 2^32 * 303 kHz / 76.8 MHz =
        // 16,944,989). The far end's test pattern is a sawtooth (sample = index mod 4096) with harmonics every
        // 18.75 kHz (76.8 MHz / 4096); the 16th, at 300 kHz, has an amplitude of 2 / (pi * 16) of the peak,
        // which is -28 dBFS, so receiver 0 sees a 3 kHz tone.
        ahb_write(`RX_BANK_PHASE_INC_ABS_ADDR(0), 32'd16_944_989);
        ahb_write(`RX_BANK_CTRL_ABS_ADDR(0), (32'd0 << `RX_BANK_CTRL_RATE_SEL_LSB) | 32'd1);
        ahb_read(`RX_BANK_PHASE_INC_ABS_ADDR(0), v);
        `CHECK(v == 32'd16_944_989, $sformatf("rx_bank.phase_inc(0) %08x", v))
        ahb_read(`RX_BANK_CTRL_ABS_ADDR(0), v);
        `CHECK(v == 32'd1, $sformatf("rx_bank.ctrl(0) %08x", v))

        // the chip reports its receiver count
        ahb_read(`SYSTEM_STATUS_ABS_ADDR, v);
        `CHECK(v[`SYSTEM_STATUS_NUM_RX_MSB:`SYSTEM_STATUS_NUM_RX_LSB] == NRX, $sformatf("system.status.num_rx %0d, built %0d", v[`SYSTEM_STATUS_NUM_RX_MSB:`SYSTEM_STATUS_NUM_RX_LSB], NRX))

        // 2b. FT8 front end (page 0x0D): the id, and receiver TRX's registers read back
        ahb_read(`FT8_ID_ABS_ADDR, v);
        `CHECK(v == `FT8_ID_RESET, $sformatf("ft8.id %08x", v))
        ahb_read(`FT8_BAND_ABS_ADDR(TRX), v);
        `CHECK(v == `FT8_BAND_RESET, $sformatf("ft8.band(%0d) reset %08x", TRX, v))
        ahb_write(`FT8_SPEC_BASE_ABS_ADDR(TRX), 32'h0123_4567);
        ahb_write(`FT8_TRIG_ABS_ADDR(TRX), (32'd337 << `FT8_TRIG_TRIG2_LSB) | 32'd295);
        ahb_write(`FT8_CAND_BB_BASE_ABS_ADDR(1), 32'h0055_AA00);
        ahb_read(`FT8_SPEC_BASE_ABS_ADDR(TRX), v);
        `CHECK(v == 32'h0123_4567, $sformatf("ft8.spec_base(%0d) %08x", TRX, v))
        ahb_read(`FT8_TRIG_ABS_ADDR(TRX), v);
        `CHECK(v == ((32'd337 << 16) | 32'd295), $sformatf("ft8.trig(%0d) %08x", TRX, v))
        ahb_read(`FT8_CAND_BB_BASE_ABS_ADDR(1), v);
        `CHECK(v == 32'h0055_AA00, $sformatf("ft8.cand_bb_base(1) %08x", v))
        ahb_read(`FT8_SPEC_BASE_ABS_ADDR(TRX - 1), v);
        `CHECK(v !== 32'h0123_4567, $sformatf("ft8.spec_base(%0d) took receiver %0d's write: %08x", TRX - 1, TRX, v))
        // a receiver that is not built (NRX < 8) reads 0 in every block and ignores the writes
        if (NRX < 8) begin
            ahb_write(`RX_BANK_PHASE_INC_ABS_ADDR(7), 32'd12345);
            ahb_read(`RX_BANK_PHASE_INC_ABS_ADDR(7), v);
            `CHECK(v == 32'd0, $sformatf("rx_bank.phase_inc(7) not built, reads %08x", v))
            ahb_write(`RX_BACKEND_CTRL_ABS_ADDR(7), 32'h0000_0001);
            ahb_read(`RX_BACKEND_CTRL_ABS_ADDR(7), v);
            `CHECK(v == 32'd0, $sformatf("rx_backend.ctrl(7) not built, reads %08x", v))
            ahb_write(`FT8_SPEC_BASE_ABS_ADDR(7), 32'h0123_4567);
            ahb_read(`FT8_SPEC_BASE_ABS_ADDR(7), v);
            `CHECK(v == 32'd0, $sformatf("ft8.spec_base(7) not built, reads %08x", v))
            ahb_read(`FT8_BAND_ABS_ADDR(7), v);
            `CHECK(v == 32'd0, $sformatf("ft8.band(7) not built, reads %08x", v))
        end
        ahb_read(`FT8_STATUS_ABS_ADDR, v);
        `CHECK(v == 32'd0, $sformatf("ft8.status %08x", v))

        // Back end receiver 0: an identity filter of one tap, an input shift of 6, a fixed gain of +24 dB (the
        // manual gain 16384 is 4.0 in log2 with 12 fractional bits, which is a factor of 16), IQ output at
        // 24 ksps, and a ring at RING0 with 4 slots (log2 = 2).
        ahb_write(`RX_BACKEND_COEF_SEL_ABS_ADDR, 32'd0);
        ahb_write(`RX_BACKEND_BANK_CFG_ABS_ADDR(0), 32'd1);
        ahb_write(`RX_BACKEND_BASE + `RX_BACKEND_COEF_OFFSET, 32'h4000_0000);
        ahb_write(`RX_BACKEND_BASE + `RX_BACKEND_COEF_OFFSET + 4, 32'd0);
        ahb_write(`RX_BACKEND_AGC_MANUAL_ABS_ADDR(0), 32'd16384);
        ahb_write(`RX_BACKEND_RING_BASE_ABS_ADDR(0), RING0);
        ahb_write(`RX_BACKEND_RING_SLOTS_ABS_ADDR(0), 32'd2);
        ahb_write(`RX_BACKEND_RING_CTRL_ABS_ADDR(0), 32'd1);
        ahb_write(`RX_BACKEND_CTRL_ABS_ADDR(0),
                  (32'd4 << `RX_BACKEND_CTRL_MODE_LSB) | (32'd1 << `RX_BACKEND_CTRL_OUT24_LSB) |
                  (32'd6 << `RX_BACKEND_CTRL_IN_SHIFT_LSB) | 32'd1);

        // far end: N = 968, test pattern, raw mode on, then one discovery reply
        @(posedge clk); #37;
        cmd_addr <= 6'h30; cmd_data <= {16'd968, 13'd0, 1'b0, 1'b1, 1'b1}; cmd_rqst <= 1'b1;
        @(posedge clk); cmd_rqst <= 1'b0;
        #(20 * 8000);
        run <= 1'b1;

        // 3. raw frames through the whole receive path
        // Poll every 20 us for up to 400 us until at least 3 raw frames have arrived.
        t0 = $time;
        do begin
            #(20_000_000);
            ahb_read(`HL2_LINK_RAW_FRAME_COUNT_ABS_ADDR, v);
        end while (v < 32'd3 && $time - t0 < 400_000_000);
        `CHECK(v >= 32'd3, $sformatf("hl2_link.raw_frame_count %0d after %0d us", v, ($time - t0) / 1_000_000))
        ahb_read(`HL2_LINK_CRC_ERROR_COUNT_ABS_ADDR, v);
        `CHECK(v == 32'd0, $sformatf("hl2_link.crc_error_count %0d", v))
        $display("t=%0t: raw frames arriving", $time);
        // one discovery reply, now that lane 0's link is up (a frame sent before the module model has negotiated is
        // not carried, as on the real line)
        @(posedge clk) discover_rqst <= 1'b1;
        @(posedge clk) discover_rqst <= 1'b0;
        // Wait 50 us for the reply to go through the link and into the CPU ring.
        #(50_000_000);

        // 4. discovery reply in the CPU ring, read through the clk_rx channel
        ahb_read(`HL2_LINK_RING_WPTR_ABS_ADDR, v);
        `CHECK(v != 32'd0, "hl2_link.ring_wptr still 0: discovery reply not in the ring")
        ahb_read(`HL2_PKT_RX_RING_ABS_ADDR(0), v);
        len = {v[7:0], v[15:8]};                    // 2-byte big-endian length first
        `CHECK(len > 60 && len < 200, $sformatf("ring word 0 = %08x: frame length %0d", v, len))
        // 4b. H2's CPU transmit queue through the clk_tx channel: write one word, read the status
        ahb_write(`HL2_PKT_TX_QUEUE_ABS_ADDR(0), 32'h0403_0201);
        ahb_read(`HL2_PKT_TX_STATUS_ABS_ADDR, v);
        `CHECK(v == 32'd0, $sformatf("hl2_pkt.tx_status %08x (expected idle)", v))
        ahb_read(`SYSTEM_STATUS_ABS_ADDR, v);
        `CHECK(v[`SYSTEM_STATUS_BUS_TIMEOUT_LSB] == 1'b0, "bus timeout flagged")
        $display("t=%0t: CPU ring frame of %0d bytes read over the bridge", $time, len);

        // 5. receiver data in the DDR3 model
        t0 = $time;
        // Wait up to 600 us for the first receiver 0 data to reach the lane.
        while (ring_beats < 6 && $time - t0 < 600_000_000) #(10_000_000);
        `CHECK(ring_beats >= 6, $sformatf("only %0d lane beats into receiver 0's ring after %0d us",
                                          ring_beats, ($time - t0) / 1_000_000))
        ahb_read(`RX_BACKEND_OUT_COUNT_ABS_ADDR(0), v);
        `CHECK(v > 32'd0, $sformatf("rx_backend.out_count(0) %0d", v))
        // The first payload word must have been written (it no longer holds the model's start content), and
        // at least one of the first six words must be neither X nor 0 nor the start content.
        `CHECK(ddr_word(RING0 + 2) !== ddr_fresh, "ring payload word 0 never written")
        nonzero = 0;
        for (k = 2; k < 2 + 6; k = k + 1)
            if (ddr_word(RING0 + k) !== 64'bx && ddr_word(RING0 + k) != 64'd0 &&
                ddr_word(RING0 + k) !== ddr_start(RING0 + k)) nonzero = nonzero + 1;
        `CHECK(nonzero > 0, "receiver 0's first ring payload words are all zero")
        $display("t=%0t: %0d beats in receiver 0's ring; out_count %0d; payload words 0-5:",
                 $time, ring_beats, v);
        for (k = 2; k < 2 + 6; k = k + 1) $display("  %016x", ddr_word(RING0 + k));

        // 6. interrupt latched for the received packet
        ahb_read(`SYSTEM_IRQ_PENDING_ABS_ADDR, v);
        `CHECK(v[0] == 1'b1, $sformatf("system.irq_pending %04x: line 0 not set", v))
        `CHECK(ext_int[0] == 1'b1, "EXT_INT[0] low")
        ahb_write(`SYSTEM_IRQ_PENDING_ABS_ADDR, 32'h0000_0001);
        ahb_read(`SYSTEM_IRQ_PENDING_ABS_ADDR, v);
        `CHECK(v[0] == 1'b0, "irq_pending bit 0 did not clear")

`ifndef TB_LANE_MODEL
        // 7. every word the arbiter wrote is in the model's memory at its address (but the newest,
        // which may still be on its way)
        nonzero = 0;
        for (k = 0; k < 16384; k = k + 1)
            if (sh_v[k] && k != sh_last) begin
                nonzero = nonzero + 1;
                if (ddr_word(k) !== sh_mem[k]) begin
                    errors = errors + 1;
                    if (errors < 12) $display("ERROR: DDR3 word %0d holds %016x, the arbiter wrote %016x", k, ddr_word(k), sh_mem[k]);
                end
            end
        `CHECK(nonzero >= 4, $sformatf("only %0d words to compare", nonzero))
        $display("t=%0t: %0d lane beats, %0d different words compared with the DDR3 model's memory", $time, sh_beats, nonzero);
`endif
        // 8. SFP cages (docs/SFP_LINKS.md, docs/HL2_SFP.md): lane 0 carries the HL2 link (negotiated with the module
        //  model above), lane 1 the board link looped back to itself
        ahb_read(32'hE80A_0008, v);
        `CHECK(v[27:16] == 12'h0A5 && v[3:0] == 4'hF && v[11:8] == 4'hF, $sformatf("sfp.serdes_status %08x (diag 0A5, both lanes F)", v))
        ahb_read(32'hE80A_0024, v);
        `CHECK(v[3:0] == 4'hF, $sformatf("sfp.net_status %08x: link not up", v))
        `CHECK(v[31:16] == 16'h4020, $sformatf("sfp.net_status partner word %04x", v[31:16]))
        ahb_read(32'hE80A_0044, v);
        `CHECK(v == 32'd0, $sformatf("sfp.code_errors %0d", v))
        // the HL2 link's loss counters (docs/HL2_SFP.md section 6): nothing lost, the sequence followed
        ahb_read(`HL2_LINK_SEQ_LOST_ABS_ADDR, v);
        `CHECK(v == 32'd0, $sformatf("hl2_link.seq_lost %0d", v))
        ahb_read(`HL2_LINK_LOSS_C_ABS_ADDR, v);
        `CHECK(v == 32'd0, $sformatf("hl2_link.loss_c %08x", v))
        ahb_read(`HL2_LINK_RX_SEQ_ABS_ADDR, len);
        ahb_read(`HL2_LINK_RAW_FRAME_COUNT_ABS_ADDR, v);
        `CHECK(len != 32'd0 && len + 32'd1 >= v, $sformatf("hl2_link.rx_seq %0d with %0d frames", len, v))
        //  network unit on the RJ45 socket (pins looped): identification, a 64-byte broadcast frame out and back in
        ahb_read(`NET_ID_ABS_ADDR, v);
        `CHECK(v == 32'h4554_0001, $sformatf("net.id %08x", v))
        // chip ID (docs/NET_ID.md): the OTP read is done long before the first register access; model's DNA 0123456789abcdef
        ahb_read(`NET_DNA_STATUS_ABS_ADDR, v);
        `CHECK(v == 32'h0000_4001, $sformatf("net.dna_status %08x", v))
        ahb_read(`NET_DNA_ID_LO_ABS_ADDR, v);
        `CHECK(v == 32'h89AB_CDEF, $sformatf("net.dna_id_lo %08x", v))
        ahb_read(`NET_DNA_ID_HI_ABS_ADDR, v);
        `CHECK(v == 32'h0123_4567, $sformatf("net.dna_id_hi %08x", v))
        ahb_read(`NET_BASE + 32'h84, v);
        `CHECK(v == 32'h89AB_CDEF, $sformatf("net.dna_raw1 %08x", v))
        ahb_write(`NET_CTRL_ABS_ADDR, 32'h0000_0013);   // receiver, transmitter, broadcast; PHY out of reset
        ahb_write(`NET_IRQ_ENABLE_ABS_ADDR, 32'h0000_0001);
        ahb_write(`NET_TX_PTR_ABS_ADDR, 32'd0);
        for (k = 0; k < 16; k = k + 1)
            ahb_write(`NET_TX_DATA_ABS_ADDR, (k < 2) ? 32'hFFFF_FFFF : (k == 2) ? 32'h5402_FFFF : 32'h0403_0201 + k * 32'h0404_0404);
        ahb_write(`NET_TX_LEN_ABS_ADDR, 32'd64);
        t0 = $time;
        do begin #(2_000_000); ahb_read(`NET_RX_LEN_ABS_ADDR, v); end while (v == 32'd0 && $time - t0 < 100_000_000);
        `CHECK(v == 32'd64, $sformatf("net.rx_len %0d after one frame of 64 bytes", v))
        ahb_read(`NET_RX_DATA_ABS_ADDR, v);
        `CHECK(v == 32'hFFFF_FFFF, $sformatf("net.rx_data word 0 %08x", v))
        ahb_read(`SYSTEM_IRQ_PENDING_ABS_ADDR, v);
        `CHECK(v[6] == 1'b1, $sformatf("system.irq_pending %04x: line 6 (network unit) not set", v))
        ahb_write(`NET_RX_DONE_ABS_ADDR, 32'd0);
        ahb_read(`NET_RX_COUNT_ABS_ADDR, v);
        `CHECK(v == 32'd1, $sformatf("net.rx_count %0d", v))
        $display("t=%0t: network unit: a frame out and back over its RJ45 pins", $time);
        //  board link: up, the HL2 stream sent and received back; a control word; then the receivers on it
        ahb_read(32'hE80B_0008, v);
        `CHECK(v[3:0] == 4'hF, $sformatf("blink.status %08x: link not up both ways with samples", v))
        ahb_read(32'hE80B_0038, v);
        `CHECK(v > 32'd1000, $sformatf("blink.rx_samples %0d", v))
        ahb_read(32'hE80B_0024, v);
        `CHECK(v == 32'd0, $sformatf("blink.rx_bad %0d", v))
        ahb_write(32'hE80B_0010, 32'hCAFE_F00D);
        repeat (30) ahb_read(32'hE80B_0008, v);
        `CHECK(v[6] == 1'b1, "blink.status.ctl_rx_avail low")
        ahb_read(32'hE80B_0014, v);
        `CHECK(v == 32'hCAFE_F00D, $sformatf("blink.ctl_rx %08x", v))
        ahb_read(`SYSTEM_IRQ_PENDING_ABS_ADDR, v);
        `CHECK(v[7] && v[14], $sformatf("system.irq_pending %04x: lines 7, 14", v))
        ahb_write(32'hE80B_0004, 32'h0000_0007);       // receivers take the link's stream (here: their own, looped)
        // Let the stream run for 300 us before comparing the link's sample index with the HL2 link's.
        #300_000_000;
        ahb_read(32'hE80B_0060, v);
        ahb_read(`HL2_LINK_SAMPLE_INDEX_LO_ABS_ADDR, len);
        `CHECK((len - v) < 32'd60000, $sformatf("link stream index %08x, HL2 link's %08x", v, len))
        `CHECK(led_stream == 1'b1, "receivers see no stream from the link")
        ahb_read(32'hE80B_0058, v);
        `CHECK(v == 32'd0, $sformatf("blink.tx_overflows %0d", v))
        ahb_read(32'hE80B_005C, v);
        `CHECK(v == 32'd0, $sformatf("blink.rx_overruns %0d", v))
        ahb_write(32'hE80B_0004, 32'h0000_0003);

        // 7. the DDR3 IP model's own checks
        `CHECK(ddr_faults == 32'd0, $sformatf("the DDR3 IP model saw %0d faults", ddr_faults))
        `CHECK(ddr3_init == 1'b1, "DDR3 not initialised")

        if (errors == 0) $display("PASS");
        else             $display("FAIL (%0d errors)", errors);
        $finish;
    end

    // Watchdog: 2 ms of simulated time.
    initial begin
        #2_000_000_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
