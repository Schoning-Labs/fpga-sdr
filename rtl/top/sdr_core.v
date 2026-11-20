// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// sdr_core: the fabric core of the chip, which is the whole radio apart from the pins, the PLLs, the AE350
// CPU, the DDR3 controller and the HDMI serializers (those are in sdr_top.v, the shell around this file).
//
// WHY THE CHIP IS SPLIT IN TWO
// Apart from one vendor primitive (an OTP block that reads the chip's unique ID, rtl/net/chip_dna.v, with a model in
// sim/net/otp_model.v) and with no PLL inside it except the plain Ethernet one, everything here simulates in the open
// tools (iverilog, verilator), and sim/top/tb_sdr_core.v runs the whole of it as a smoke test. The pieces that
// only Gowin's tools understand sit in sdr_top.v.
//
// HOW THE RADIO IS WIRED, FOLLOWING THE SAMPLES
//   1. The Hermes-Lite 2 sends raw 12-bit ADC samples (76.8 Msps) over a gigabit Ethernet link that arrives on the
//      SFP0 cage. sfp_top (rtl/sfp) decodes the line code and hands bytes to the HL2 link receiver (hl2_link_rx_top),
//      which finds the frames, unpacks the 12-bit samples and fills in zeros where frames were lost, so a sample
//      count always equals HL2 time. The result is samp, samp_valid, samp_is_fill and a 48-bit sample index.
//   2. One register (rsamp*) selects either that stream or, on a second board, the board link's stream (blink_top on
//      SFP1), and feeds the three consumers: the receiver bank (rx_bank, a numerically controlled oscillator mixer and
//      decimation filters per receiver), the full-band spectrum (spectrum_pipeline, a 16,384-point FFT) and the zoom
//      receiver (zoom_frontend).
//   3. The receiver bank's output goes to rx_backend, which does the channel filter, demodulation and AGC per
//      receiver and writes IQ blocks into DDR3. Its 12 ksps audio samples also go to the FT8 front end (ft8_frontend).
//   4. The spectrum pipeline gives a spectrum line (for the trace) and waterfall bytes, which waterfall_writer stores
//      as lines in a DDR3 ring. The compositor draws the picture for the monitor: it reads the CPU-drawn GUI frame
//      buffer and the waterfall rings from DDR3 and overlays the spectrum, then hands a pixel (vid_rgb) to the HDMI
//      encoder in the top level.
//   5. The transmit path runs the other way: the CPU writes baseband samples into a DDR3 ring, audio_ring_reader and
//      tx_chain turn them into 12-bit samples at 76.8 Msps (one per received sample, which keeps the rate locked to
//      the HL2), and hl2_link_tx_top frames them for the HL2 on the same SFP0 lane.
//   6. The audio engine turns 48 kHz stereo into the PT8211 headphone DAC stream; audio_out_src makes a never
//      stopping 48 kHz stream out of it for S/PDIF, I2S (audio_digital_out), the HDMI audio packets and the USB cores.
//   7. The CPU controls all of it through registers (next section) and gets 16 interrupt lines.
//
// CLOCK DOMAINS (docs/ARCHITECTURE.md 2; every pair of these is asynchronous to the other, so each crossing is a
// toggle handshake, a Gray-coded FIFO or a synchronizer)
//   clk_dsp  120 MHz  every DSP block, the register blocks, both DDR3 lane arbiters and the lanes themselves (the lane
//                     side of rtl/mem/ddr_mem.v runs on clk_dsp and crosses to the DDR3 controller's own 75 MHz clock
//                     inside that file; in the 256 MB build clk_lane4 and clk_lane5 of the AE350 are driven with
//                     clk_dsp as well)
//   hclk      80 MHz  the AE350's AHB clock (EXTS_HCLK): only ahb_reg_bridge runs on it
//   n1_rxc   125 MHz  transceiver lane 0's recovered clock: the PCS receive side, the HL2 link's frame parser, its
//                     sample FIFO and the CPU receive ring
//   sfp_txc  125 MHz  lane 0's transmit clock: the PCS transmit side, the HL2 transmit framer and the CPU transmit queue
//   clk_eth  100 MHz  the Ethernet PLL's output (eth_clk_pll.v, from clk_50m): the network unit on the RJ45 socket
//                     (rtl/net/net_unit.v)
//   clk_pix           the pixel clock, 74.17 MHz: the compositor's pixel pipeline (rtl/video/compositor_pix.v)
//   clk_usb   48 MHz  the USB device and host cores (clk_48m of the top level)
//   clk_aud  49.152 MHz  the S/PDIF and I2S outputs (inside audio_digital_out)
//
// REGISTER PAGES (docs/ARCHITECTURE.md 4.1; addresses from hw/regmap/*.toml). The CPU sees each block as one 64 KB
// page starting at 0xE800_0000 + page x 0x1_0000.
//   0x00 system          sys_regs                 0x07 video      compositor (rtl/video/compositor.v)
//   0x01 hl2_link        hl2_link_regs            0x08 tx         tx_regs
//   0x02 hl2_pkt (n1_rxc below 0x8000, sfp_txc above) hl2_pkt_port and hl2_txq_port
//   0x03 rx_bank         rx_bank_regs             0x09 audio      audio_regs
//   0x05 spectrum        spectrum_pipeline        0x0C rx_backend rx_backend's own port
//   0x06 zoom            zoom_frontend (DDC) and spectrum_pipeline's zoom back-end fields
//   0x0A sfp             rtl/sfp/sfp_top.v        0x0B blink      rtl/blink/blink_top.v
//   0x0D ft8             ft8_frontend             0x0E usb        usb_audio (rtl/usb, docs/USB_AUDIO.md)
//   0x0F usbh            usbh_top (rtl/usbh, docs/USB_HOST.md)
//   NET_BASE (0x24)      net_unit (rtl/net, the RJ45 network unit; hw/regmap/net.toml is the one place that defines its page)
// Page 0x04 and the pages 0x10 to 0xFF read 0 and ignore writes (apart from NET_BASE).
//
// DDR3 LANES. Write arbiter tiers, highest priority first: the receiver back end's IQ rings, the full-band waterfall
// writer, the capture tier (used by the zoom waterfall writer, because raw capture is not built), and the FT8 front
// end. Read arbiter tiers: video (compositor), audio (audio engine), TX (the TX baseband ring reader) and the rest
// (the FT8 front end). Lane addresses count 64-bit words (docs/F4_DDR.md section 2).
//
// INTERRUPT LINES (docs/ARCHITECTURE.md 4.3), latched in sys_regs:
//   0 packet received   1 HL2 status (safety byte, gap)   2 no source   3 audio low water   4 TX low water
//   5 spectrum line done   6 network unit (RJ45)   7 HL2 lane (SFP0) link change   8 video frame start
//   9 no source   10 receiver back end   11 FT8 front end   12 USB playback samples waiting   13 USB host
//   14 board link (control word, link change)   15 spare

`timescale 1ns / 1ps

`include "hw/regmap/generated/net_regs.vh"     // NET_BASE: the network unit's page (one place) // NET_BASE: the page number of the network unit, from the generated register map (one place)

// SFP_TIMER_X and SFP_TIMER_SGMII: link timers of the PCS in 125 MHz clocks (10 ms and 1.6 ms); the testbenches
// shorten them. ZOOM: 1 builds the zoom receiver (docs/ZOOM_IN_CHIP.md), 0 leaves it out and page 0x06 answers 0.
// NRX: number of receivers built, 1 to 8 (4 in the default build, set with TR_NRX in gowin/p1/build.sh); the register
// layout always keeps the 8-receiver form, and receivers at or above NRX read 0.
module sdr_core #(
    parameter integer SFP_TIMER_X = 1250000,       // network PCS link timers in 125 MHz clocks (10 ms, 1.6 ms)
    parameter integer SFP_TIMER_SGMII = 200000,    // the shortened SGMII timer, for the benches only
`ifdef TR_NO_ZOOM
    parameter integer ZOOM = 0,            // 1: the zoom receiver is built in (docs/ZOOM_IN_CHIP.md); 0: page 0x06 answers 0
`else
    parameter integer ZOOM = 1,            // 1: the zoom receiver is built in (docs/ZOOM_IN_CHIP.md); 0: page 0x06 answers 0
`endif
`ifdef TR_NRX
    parameter integer NRX = `TR_NRX        // receivers built, 1 to 8; gowin/p1/build.sh sets TR_NRX
`else
    parameter integer NRX = 4              // receivers built, 1 to 8 (4 unless TR_NRX says otherwise)
`endif
) (
    // ---- clocks and resets (resets are synchronous, active high, one per clock domain)
    output wire        clk_eth,            // 100 MHz network clock, made by the Ethernet PLL in this file; a port so that the top level carries the net name clk_eth that the constraints use
    input  wire        clk_dsp,  // 120 MHz main clock
    input  wire        rst_dsp,  // reset for clk_dsp
    input  wire        rst_rx,             // reset for n1_rxc (the HL2 link's receive side)
    input  wire        clk_50m,            // 50 MHz board oscillator, the input of the Ethernet PLL
    input  wire        clk_pix,  // 74.17 MHz pixel clock
    // ---- AE350 Extended AHB Slave (the AE350 is the master; see ahb_reg_bridge.v)
    input  wire        hclk,  // AHB clock, 80 MHz
    input  wire        hresetn,  // AHB reset, active low
    input  wire        hsel,  // this slave is selected
    input  wire [31:0] haddr,  // byte address; bits 23:16 are the page
    input  wire [1:0]  htrans,  // transfer type; bit 1 set = a transfer starts
    input  wire        hwrite,  // 1 = write
    input  wire [2:0]  hsize,  // transfer size (always handled as 32 bits)
    input  wire [31:0] hwdata,  // write data
    output wire        hreadyout,  // 0 while an access is in progress
    output wire [31:0] hrdata,  // read data
    output wire        hresp,  // always OKAY (0)
    output wire [15:0] ext_int,  // the 16 interrupt lines to the AE350's PLIC
    // ---- DDR3 lanes, clocked by clk_dsp (signal names from the AE350 manual MUG1031 table 5-1; the handshake is the
    // one described in the header of rtl/mem/ddr_mem.v, docs/MEM_1GB.md section 3; wr_go and rd_go are only used by
    // the 256 MB build)
    output wire [31:0] addr_lane4,  // write lane: word address (64-bit words)
    output wire [7:0]  wr_mask_lane4,      // 1 = byte written (fabric convention)
    output wire [63:0] wr_data_lane4,  // write lane: data word, 64 bits
    output wire        wr_en_lane4,  // write lane: data valid
    output wire        wr_go_lane4,  // write lane: start strobe (256 MB build only)
    output wire [7:0]  burstcount_lane4,  // write lane: burst length in words
    input  wire        wr_wait_lane4,  // write lane: the controller cannot take data this clock
    input  wire        wr_done_lane4,  // write lane: the burst has been written
    output wire [31:0] addr_lane5,  // read lane: word address (64-bit words)
    output wire        rd_en_lane5,  // read lane: request
    output wire        rd_go_lane5,  // read lane: start strobe (256 MB build only)
    output wire [7:0]  burstcount_lane5,  // read lane: burst length in words
    input  wire        rd_valid_lane5,  // read lane: a data word is valid this clock
    input  wire [63:0] rd_data_lane5,  // read lane: data word, 64 bits
    input  wire        rd_rdy_lane5,  // read lane: the controller can take a request
    // ---- RGMII to the RTL8211F on the RJ45 socket: the network unit (rtl/net/net_unit.v, 100 Mbit/s). Every pin is
    // a register of clk_eth or is sampled by it.
    input  wire        rgmii_rxc,  // receive clock from the PHY, sampled as data
    input  wire [3:0]  rgmii_rxd,  // receive data, 4 bits per clock
    input  wire        rgmii_rx_ctl,  // receive data valid
    output wire        rgmii_txc,  // 25 MHz transmit clock (a register of clk_eth)
    output wire [3:0]  rgmii_txd,  // transmit data, 4 bits per clock
    output wire        rgmii_tx_ctl,  // transmit data valid
    output wire        phy_clk,            // 25 MHz reference clock for the PHY
    output wire        phy_rst_n,  // PHY reset, active low
    output wire        phy_mdc,  // management clock (MDIO)
    output wire        phy_mdio_o,  // management data out
    output wire        phy_mdio_oe,  // management data output enable
    input  wire        phy_mdio_i,  // management data in
    // ---- PT8211 audio DAC, a 3-wire serial stereo DAC for the headphones and the speaker amplifier
    output wire        pt8211_bck,  // bit clock
    output wire        pt8211_ws,  // word select (left or right channel)
    output wire        pt8211_din,  // serial data
    // ---- audio outputs begin (docs/AUDIO_OUT.md): S/PDIF and I2S on PMOD2
    input  wire        clk_aud,            // 49.152 MHz = 1,024 x 48 kHz, from the audio PLL
    input  wire        aud_lock,           // the audio PLL's lock
    output wire        spdif_out,          // S/PDIF stream; spdif_out and the four I2S lines below are all clk_aud registers
    output wire        i2s_bck,  // I2S bit clock, 3.072 MHz
    output wire        i2s_ws,  // I2S word clock, 48 kHz
    output wire        i2s_sd,  // I2S data
    output wire        i2s_mclk,  // I2S master clock, 12.288 MHz
    output wire        aud48_valid,        // the 48 kHz stream for the HDMI audio packets (clk_dsp domain):
    output wire [15:0] aud48_l,            // one valid pulse per sample, 16-bit signed left channel
    output wire [15:0] aud48_r,            // 16-bit signed right channel
    // ---- audio outputs end
    // ---- USB audio begin (docs/USB_AUDIO.md): the full-speed device on the "Custom USB" socket
    input  wire        clk_usb,            // 48 MHz, the DSP PLL's second output
    input  wire        usb_dp_i,           // D+ as read from the pad (the pads are in the top level)
    input  wire        usb_dn_i,  // D- as read from the pad
    output wire        usb_dp_o,           // clk_usb registers, all four
    output wire        usb_dn_o,
    output wire        usb_oe,  // 1 = drive D+ and D-; 0 = release them
    output wire        usb_pullup,         // 1 = the 1.5 kohm pull-up on D+ is on
    // ---- USB audio end
    // ---- USB host begin (docs/USB_HOST.md): two ports on the Pmod board, clocked by clk_usb. Per port there is the
    // pin of the dock's odd row (a) and the pin of the even row (b); the pads are in the top level.
    input  wire [1:0]  usbh_a_i,  // as read from the pads
    input  wire [1:0]  usbh_b_i,  // as read from the pads
    output wire [1:0]  usbh_a_o,           // output data, behind a 2:1 switch that swaps D+ and D- (usbh.ctrl.swap), after clk_usb registers
    output wire [1:0]  usbh_b_o,  // output data, same switch
    output wire [1:0]  usbh_oe,            // 1 = drive the port's two pins; clk_usb registers
    // ---- USB host end
    // ---- the two SFP+ cages (docs/SFP_LINKS.md). The transceiver itself (rtl/sfp/sfp_serdes.v) is in
    // sdr_top.v; here are its raw lane words, in line order (bit 0 goes first on the line).
    input  wire        sfp_txc,            // 125 MHz, lane 0 transmit word clock: the HL2 link's transmit side
    input  wire        n1_rxc,             // 125 MHz, lane 0 recovered clock: the HL2 link's receive side
    input  wire        bl_txc,             // 125 MHz, the clock lane 1's transmit buffer is written with
    input  wire        bl_rxc,             // 125 MHz, lane 1 recovered clock: the board link's receive side
    output wire [9:0]  ln0_tx,  // lane 0 transmit word, 10 bits (one 8b/10b code group per clock)
    input  wire [9:0]  ln0_rx,  // lane 0 received word, 10 bits
    input  wire        ln0_rx_vld,  // lane 0 received word is valid
    output wire [19:0] ln1_tx,  // lane 1 transmit word, 20 bits
    input  wire [19:0] ln1_rx,  // lane 1 received word, 20 bits
    input  wire        ln1_rx_vld,  // lane 1 received word is valid
    output wire        serdes_por_n,       // transceiver power-on reset (a clk_dsp register)
    output wire [1:0]  ln_rst_n,  // per-lane reset
    output wire [1:0]  ln_rx_rst,  // per-lane receive reset
    output wire [1:0]  ln_tx_rst,  // per-lane transmit reset
    output wire [3:0]  ln0_fix,  // lane 0 receive alignment and polarity fixes
    output wire [3:0]  ln1_fix,  // lane 1 receive alignment and polarity fixes
    input  wire [3:0]  ln0_stat,           // asynchronous: PLL lock, receive clock lock, signal detect, ready
    input  wire [3:0]  ln1_stat,  // asynchronous, same bits for lane 1
    input  wire [11:0] sfp_diag,           // asynchronous: quad status and lane buffer flags (rtl/sfp/sfp_serdes.v)
    output wire [1:0]  sfp_tx_disable,     // SFP0 and SFP1: 1 = module transmitter off
    input  wire [1:0]  sfp_los,  // SFP0 and SFP1 loss of signal, 1 = no light or no signal
    output wire        twi_scl_o,          // 0 = pull the board's I2C clock line low
    output wire        twi_sda_o,  // 0 = pull the board's I2C data line low
    input  wire        twi_scl_i,  // the I2C clock line as read
    input  wire        twi_sda_i,  // the I2C data line as read
    output wire [2:0]  twi_sel,            // I2C multiplexer channel, 3 bits
    // ---- video position from the HDMI encoder (clk_pix): the pixel the encoder will send next
    input  wire [11:0] vid_cx,  // pixel column, 0 to 2199 for 1080p (2,200 clocks per line)
    input  wire [10:0] vid_cy,  // pixel row, 0 to 1124 (1,125 lines per frame)
    output wire [23:0] vid_rgb,            // 8 bits per color; the compositor's pixel for (vid_cx, vid_cy), in the same clock
    // ---- status
    input  wire [31:0] build_id,  // identifier of the bitstream (read by the CPU in sys_regs)
    input  wire        ddr3_init,          // asynchronous, 1 = the DDR3 controller has calibrated
    input  wire        plls_locked,        // asynchronous, 1 = every fabric PLL has locked
    output wire        led_rx_streaming    // clk_dsp: 1 while raw sample frames are arriving
);

    // =========================================================================== register bus
    // How a CPU access reaches a block: the AE350 puts an AHB access on the Extended AHB Slave port, ahb_reg_bridge
    // turns it into a toggle request for the clock domain that owns the page, regbus_cdc_dst in that domain turns the
    // toggle into a one-clock bus_wr or bus_rd strobe, and (in the clk_dsp domain) one regbus_leg per page passes the
    // strobe to the block. The answers travel back the same way: a leg returns its block's read data only if the last
    // access was to its page, the legs are ORed together, and regbus_cdc_dst holds the result until the bridge reads it.
    // The four channels are clk_dsp (every page except the next two), n1_rxc (the HL2 link receive ring), sfp_txc (the
    // HL2 link transmit queue) and clk_eth (the network unit).
    // the request as seen by the far sides: byte address, write flag, write data, and per-channel toggles and answers
    wire [23:0] req_addr;
    wire        req_wr;
    wire [31:0] req_wdata;
    wire        req_tog0, ack_tog0, req_tog1, ack_tog1, req_tog2, ack_tog2, req_tog3, ack_tog3;
    wire [31:0] rdata0, rdata1, rdata2, rdata3;
    // bridge_timeout pulses when a channel did not answer; rx_dead says the HL2 link has no receive clock
    wire        bridge_timeout, rx_dead;

    // The network unit's page number is bits 23:16 of NET_BASE.
    localparam [31:0] NET_BASE_W = `NET_BASE;
    ahb_reg_bridge #(.NET_PAGE(NET_BASE_W[23:16])) u_bridge (
        .hclk(hclk), .hresetn(hresetn),
        .hsel(hsel), .haddr(haddr), .htrans(htrans), .hwrite(hwrite), .hsize(hsize),
        .hwdata(hwdata), .hreadyout(hreadyout), .hrdata(hrdata), .hresp(hresp),
        .req_addr(req_addr), .req_wr(req_wr), .req_wdata(req_wdata),
        .req_tog0(req_tog0), .ack_tog0(ack_tog0), .rdata0(rdata0),
        .req_tog1(req_tog1), .ack_tog1(ack_tog1), .rdata1(rdata1),
        .req_tog2(req_tog2), .ack_tog2(ack_tog2), .rdata2(rdata2),
        .req_tog3(req_tog3), .ack_tog3(ack_tog3), .rdata3(rdata3),
        .timeout_pulse(bridge_timeout), .rx_dead(rx_dead)
    );

    // A timeout is a one-clock pulse in hclk; it becomes a toggle so sys_regs can pick it up in clk_dsp.
    reg tmo_tog = 1'b0;
    always @(posedge hclk) if (bridge_timeout) tmo_tog <= ~tmo_tog;

    // ---- channel 0: clk_dsp
    wire        d_wr, d_rd;
    wire [23:0] d_addr;
    wire [31:0] d_wdata;
    reg  [31:0] d_rdata;

    // RD_LAT 12: two clocks of the leg, six of rx_backend after its read strobe (see its header), one for the leg's
    // read register and one for the OR of the pages. Read data stands in d_rdata 10 clocks after the strobe, so 12 leaves
    // two clocks of margin; the blocks with a registered address decode (block_regs.v) need 7.
    regbus_cdc_dst #(.RD_LAT(12)) u_dst_dsp (
        .clk(clk_dsp), .rst(rst_dsp),
        .req_tog(req_tog0), .req_addr(req_addr), .req_wr(req_wr), .req_wdata(req_wdata),
        .ack_tog(ack_tog0), .rdata_hold(rdata0),
        .bus_wr(d_wr), .bus_rd(d_rd), .bus_addr(d_addr), .bus_wdata(d_wdata), .bus_rdata(d_rdata)
    );

    // ---- the pages that have a leg of their own (rtl/top/regbus_leg.v), so no bus net is shared between two
    // blocks. lN_wr, lN_rd, lN_a and lN_d go to the block of page N (write and read strobe, 16-bit offset, write
    // data), and lN_q is its read data, which is 0 unless the last access was to that page.
    wire        l0_wr, l0_rd, l1_wr, l1_rd, l3_wr, l3_rd, l5_wr, l5_rd, l6_wr, l6_rd;
    wire        l7_wr, l7_rd, l8_wr, l8_rd, l9_wr, l9_rd, lc_wr, lc_rd, ld_wr, ld_rd;
    wire        la_wr, la_rd, lb_wr, lb_rd;
    wire [15:0] la_a, lb_a;
    wire [31:0] la_d, lb_d, la_q, lb_q, rd_sfp, rd_blink;
    wire [15:0] l0_a, l1_a, l3_a, l5_a, l6_a, l7_a, l8_a, l9_a, lc_a, ld_a;
    wire [31:0] l0_d, l1_d, l3_d, l5_d, l6_d, l7_d, l8_d, l9_d, lc_d, ld_d;
    wire [31:0] l0_q, l1_q, l3_q, l5_q, l6_q, l7_q, l8_q, l9_q, lc_q, ld_q;
    wire [31:0] rd_sys, rd_hl2, rd_rxb, rd_spec, rd_zoom, rd_vid, rd_tx, rd_aud, rd_bk, rd_ft8;
    // One macro instantiates a leg with all its wiring, so the twelve lines below only name the instance, the page, the
    // wire prefix and the block's read-data wire.
`define TR_LEG(NAME, PG, P, RD)     regbus_leg #(.PAGE(PG)) NAME (.clk(clk_dsp), .d_wr(d_wr), .d_rd(d_rd), .d_addr(d_addr),         .d_wdata(d_wdata), .wr(P``_wr), .rd(P``_rd), .addr(P``_a), .wdata(P``_d),         .blk_rdata(RD), .rdata(P``_q));
    `TR_LEG(u_leg_sys,  8'h00, l0, rd_sys)
    `TR_LEG(u_leg_hl2,  8'h01, l1, rd_hl2)
    `TR_LEG(u_leg_rxb,  8'h03, l3, rd_rxb)
    `TR_LEG(u_leg_spec, 8'h05, l5, rd_spec)
    `TR_LEG(u_leg_zoom, 8'h06, l6, rd_zoom)
    `TR_LEG(u_leg_vid,  8'h07, l7, rd_vid)
    `TR_LEG(u_leg_tx,   8'h08, l8, rd_tx)
    `TR_LEG(u_leg_aud,  8'h09, l9, rd_aud)
    `TR_LEG(u_leg_sfp,  8'h0A, la, rd_sfp)
    `TR_LEG(u_leg_blk,  8'h0B, lb, rd_blink)
    `TR_LEG(u_leg_bk,   8'h0C, lc, rd_bk)
    `TR_LEG(u_leg_ft8,  8'h0D, ld, rd_ft8)
`undef TR_LEG
    // ---- USB audio begin: the leg of page 0x0E, written out by hand because the page is optional in the macro list
    wire        le_wr, le_rd;
    wire [15:0] le_a;
    wire [31:0] le_d, le_q, rd_usb;
    regbus_leg #(.PAGE(8'h0E)) u_leg_usb (
        .clk(clk_dsp), .d_wr(d_wr), .d_rd(d_rd), .d_addr(d_addr), .d_wdata(d_wdata),
        .wr(le_wr), .rd(le_rd), .addr(le_a), .wdata(le_d), .blk_rdata(rd_usb), .rdata(le_q)
    );
    // ---- USB audio end
    // ---- USB host begin: the leg of page 0x0F
    wire        lf_wr, lf_rd;
    wire [15:0] lf_a;
    wire [31:0] lf_d, lf_q, rd_usbh;
    regbus_leg #(.PAGE(8'h0F)) u_leg_usbh (
        .clk(clk_dsp), .d_wr(d_wr), .d_rd(d_rd), .d_addr(d_addr), .d_wdata(d_wdata),
        .wr(lf_wr), .rd(lf_rd), .addr(lf_a), .wdata(lf_d), .blk_rdata(rd_usbh), .rdata(lf_q)
    );
    // ---- USB host end

    // The page OR: every leg gives 0 unless it was the one addressed, so ORing them gives the answer of the addressed
    // page, registered once before it goes back to regbus_cdc_dst.
    always @(posedge clk_dsp)
        d_rdata <= l0_q | l1_q | l3_q | l5_q | l6_q | l7_q | l8_q | l9_q | la_q | lb_q | lc_q | ld_q | le_q | lf_q;

    // ---- channel 1: n1_rxc, the HL2 link's receive clock (the receive ring in the HL2 packet memory, page 0x02 below 0x8000)
    wire        x_wr, x_rd;
    wire [23:0] x_addr;
    wire [31:0] x_wdata, x_rdata;
    wire [11:0] ring_rd_addr;
    wire [7:0]  ring_rd_data;

    regbus_cdc_dst #(.RD_LAT(8)) u_dst_rx (
        .clk(n1_rxc), .rst(rst_rx),
        .req_tog(req_tog1), .req_addr(req_addr), .req_wr(req_wr), .req_wdata(req_wdata),
        .ack_tog(ack_tog1), .rdata_hold(rdata1),
        .bus_wr(x_wr), .bus_rd(x_rd), .bus_addr(x_addr), .bus_wdata(x_wdata), .bus_rdata(x_rdata)
    );

    hl2_pkt_port u_pkt (
        .clk(n1_rxc), .bus_rd(x_rd), .bus_addr(x_addr[15:0]), .bus_rdata(x_rdata),
        .ring_rd_addr(ring_rd_addr), .ring_rd_data(ring_rd_data)
    );

    // ---- channel 2: sfp_txc, the HL2 link's transmit clock (the CPU transmit queue, page 0x02 from 0x8000). Its reset is
    // made here from the clk_dsp reset by a 4-flop shift register, asserted at once and released in step with sfp_txc.
    reg  [3:0]  rst_tx_s = 4'hF;
    always @(posedge sfp_txc or posedge rst_dsp)
        if (rst_dsp) rst_tx_s <= 4'hF; else rst_tx_s <= {rst_tx_s[2:0], 1'b0};
    wire        rst_tx = rst_tx_s[3];
    wire        t_wr, t_rd;
    wire [23:0] t_addr;
    wire [31:0] t_wdata, t_rdata;
    wire        cq_wr_en, cq_send_len_wr, cq_busy;
    wire [11:0] cq_wr_addr;
    wire [7:0]  cq_wr_data;
    wire [15:0] cq_wr_len;

    regbus_cdc_dst #(.RD_LAT(4)) u_dst_tx (
        .clk(sfp_txc), .rst(rst_tx),
        .req_tog(req_tog2), .req_addr(req_addr), .req_wr(req_wr), .req_wdata(req_wdata),
        .ack_tog(ack_tog2), .rdata_hold(rdata2),
        .bus_wr(t_wr), .bus_rd(t_rd), .bus_addr(t_addr), .bus_wdata(t_wdata), .bus_rdata(t_rdata)
    );

    hl2_txq_port u_txq (
        .clk(sfp_txc), .bus_wr(t_wr), .bus_rd(t_rd), .bus_addr(t_addr[15:0]), .bus_wdata(t_wdata),
        .bus_rdata(t_rdata),
        .cq_wr_en(cq_wr_en), .cq_wr_addr(cq_wr_addr), .cq_wr_data(cq_wr_data),
        .cq_send_len_wr(cq_send_len_wr), .cq_wr_len(cq_wr_len), .cq_busy(cq_busy)
    );

    // ---- channel 3: clk_eth, the network unit on the RJ45 socket (page NET_BASE). The Ethernet PLL makes its 100 MHz
    // from the 50 MHz oscillator; its reset is made like rst_tx above.
    wire        eth_pll_locked;
    eth_clk_pll u_eth_pll (.clk_in(clk_50m), .clk_100(clk_eth), .clk_25(), .locked(eth_pll_locked));
    reg  [3:0]  rst_eth_s = 4'hF;
    always @(posedge clk_eth or posedge rst_dsp)
        if (rst_dsp) rst_eth_s <= 4'hF; else rst_eth_s <= {rst_eth_s[2:0], 1'b0};
    wire        rst_eth = rst_eth_s[3];
    wire        e_wr, e_rd, net_irq;
    wire [23:0] e_addr;
    wire [31:0] e_wdata, e_rdata;
    regbus_cdc_dst #(.RD_LAT(3)) u_dst_eth (
        .clk(clk_eth), .rst(rst_eth),
        .req_tog(req_tog3), .req_addr(req_addr), .req_wr(req_wr), .req_wdata(req_wdata),
        .ack_tog(ack_tog3), .rdata_hold(rdata3),
        .bus_wr(e_wr), .bus_rd(e_rd), .bus_addr(e_addr), .bus_wdata(e_wdata), .bus_rdata(e_rdata)
    );
    net_unit u_net (
        .clk(clk_eth), .rst(rst_eth),
        .bus_wr(e_wr), .bus_rd(e_rd), .bus_addr(e_addr[15:0]), .bus_wdata(e_wdata), .bus_rdata(e_rdata), .irq(net_irq),
        .rgmii_txc(rgmii_txc), .rgmii_txd(rgmii_txd), .rgmii_tx_ctl(rgmii_tx_ctl),
        .rgmii_rxc(rgmii_rxc), .rgmii_rxd(rgmii_rxd), .rgmii_rx_ctl(rgmii_rx_ctl),
        .phy_clk(phy_clk), .phy_rst_n(phy_rst_n), .mdc(phy_mdc), .mdio_i(phy_mdio_i), .mdio_o(phy_mdio_o),
        .mdio_oe(phy_mdio_oe)
    );
    // The unit's interrupt is a level in clk_eth; three registers move it into clk_dsp.
    (* preserve *) reg [2:0] net_irq_s = 3'b000;
    always @(posedge clk_dsp) net_irq_s <= {net_irq_s[1:0], net_irq};

    // =========================================================================== HL2 link receive
    // The HL2's raw frames arrive on transceiver lane 0 (SFP0) as bytes from sfp_top below, in n1_rxc (docs/HL2_SFP.md).
    // hl2_link_rx_top finds the frames, checks them, unpacks the 12-bit samples, fills gaps with zeros so that the
    // sample count equals HL2 time, crosses into clk_dsp and numbers every sample with a 48-bit index. It also keeps
    // the counters that hl2_link_regs shows to the CPU and fills the CPU's receive ring.
    // samp, samp_valid, samp_is_fill, samp_index: the sample stream in clk_dsp. samp_is_fill marks the zeros that
    // replace lost samples.
    wire [11:0] samp;
    wire        samp_valid, samp_is_fill;
    wire [47:0] samp_index;
    // the safety byte of the HL2 (trip, over-temperature and similar, PROTOCOL 5.4), interrupts and counters
    wire [7:0]  rx_safety_byte;
    wire        rx_irq_safety, rx_irq_pkt, rx_irq_gap;
    wire [31:0] rx_cnt_crc, rx_cnt_raw, rx_cnt_other, cnt_gap_events, cnt_gap_samples, cnt_resync;
    wire [15:0] rx_cnt_ring_frames, rx_cnt_ring_dropped;
    wire [13:0] rx_ring_wr_ptr;
    wire [31:0] rx_cfg_hl2_ip;
    wire [7:0]  rx_raw_version;
    wire [15:0] rx_tx_fifo_fill;
    wire        rx_raw_commit;
    wire [31:0] rx_seq_lost, rx_last_seq;
    wire [15:0] rx_seq_rst, rx_code, rx_len, rx_hmiss, rx_drain, rx_over, rx_idx, rx_hovf;
    wire [7:0]  hl2_g_rx_d, hl2_g_tx_d;
    wire        hl2_g_rx_dv, hl2_g_rx_er, hl2_g_rx_ce, hl2_g_rx_rst, hl2_g_tx_en, hl2_tx_link_up;
    // The receive side is held in reset with the chip and also while the lane's PCS is (sfp.net_ctrl.enable 0).
    wire        rst_hl2rx = rst_rx | hl2_g_rx_rst;

    hl2_link_rx_top #(.RING_AW(14)) u_hl2_rx (
        .clk_rx(n1_rxc), .rst_rx(rst_hl2rx),
        .g_rx_d(hl2_g_rx_d), .g_rx_dv(hl2_g_rx_dv), .g_rx_er(hl2_g_rx_er), .g_rx_ce(hl2_g_rx_ce),
        .clk_dsp(clk_dsp), .rst_dsp(rst_dsp),
        .cfg_hl2_ip(rx_cfg_hl2_ip),
        .samp_out(samp), .samp_out_valid(samp_valid), .samp_out_is_fill(samp_is_fill),
        .samp_index(samp_index),
        .safety_byte(rx_safety_byte), .irq_safety_change(rx_irq_safety),
        .raw_version(rx_raw_version), .raw_tx_fifo_fill(rx_tx_fifo_fill),
        .raw_commit_pulse(rx_raw_commit),
        .irq_pkt_rx(rx_irq_pkt), .irq_gap(rx_irq_gap),
        .cnt_crc_errors(rx_cnt_crc), .cnt_raw_frames(rx_cnt_raw), .cnt_other_frames(rx_cnt_other),
        .cnt_ring_frames(rx_cnt_ring_frames), .cnt_ring_dropped(rx_cnt_ring_dropped),
        .cnt_gap_events(cnt_gap_events), .cnt_gap_samples(cnt_gap_samples),
        .cnt_resync_events(cnt_resync),
        .cnt_seq_lost(rx_seq_lost), .cnt_seq_restarts(rx_seq_rst), .cnt_code_frames(rx_code), .cnt_len_errors(rx_len),
        .cnt_hl2_missing(rx_hmiss), .last_seq(rx_last_seq), .cnt_drain_drops(rx_drain), .cnt_overruns(rx_over),
        .cnt_idx_drops(rx_idx), .hl2_ovf_count(rx_hovf),
        .ring_rd_addr({2'b00, ring_rd_addr}), .ring_rd_data(ring_rd_data), .ring_wr_ptr(rx_ring_wr_ptr)
    );

    // settings and counters passed between the HL2 link blocks and its register block (our and the HL2's MAC address,
    // IP address and port, the transmit trim)
    wire [47:0] our_mac;
    wire [31:0] our_ip, hl2_ip;
    wire [47:0] hl2_mac;
    wire [15:0] our_port;
    wire [31:0] tx_cnt_skip, tx_cnt_insert;
    wire        tx_link_enable;
    wire [7:0]  safety_byte;
    wire [15:0] tx_fifo_fill;
    wire [31:0] tx_trim;
    wire        irq_pkt, irq_hl2_status;

    // The HL2 link's register page 0x01: settings (addresses, transmit enable), counters of every error kind, the
    // safety byte and the interrupts.
    hl2_link_regs u_hl2_regs (
        .clk(clk_dsp), .rst(rst_dsp),
        .bus_wr(l1_wr), .bus_rd(l1_rd), .bus_addr(l1_a), .bus_wdata(l1_d), .bus_rdata(rd_hl2),
        .clk_rx(n1_rxc),
        .rx_cnt_crc_errors(rx_cnt_crc), .rx_cnt_raw_frames(rx_cnt_raw),
        .rx_cnt_other_frames(rx_cnt_other), .rx_cnt_ring_frames(rx_cnt_ring_frames),
        .rx_cnt_ring_dropped(rx_cnt_ring_dropped), .rx_ring_wr_ptr(rx_ring_wr_ptr[11:0]),
        .rx_safety_byte(rx_safety_byte), .rx_cfg_hl2_ip(rx_cfg_hl2_ip),
        .rx_seq_lost(rx_seq_lost), .rx_last_seq(rx_last_seq), .rx_seq_restarts(rx_seq_rst), .rx_code_frames(rx_code),
        .rx_len_errors(rx_len), .rx_hl2_missing(rx_hmiss), .rx_drain_drops(rx_drain), .rx_overruns(rx_over),
        .rx_idx_drops(rx_idx), .rx_hl2_ovf(rx_hovf),
        .cnt_gap_events(cnt_gap_events), .cnt_gap_samples(cnt_gap_samples),
        .cnt_resync_events(cnt_resync), .irq_gap(rx_irq_gap), .sample_index(samp_index),
        .our_mac(our_mac), .our_ip(our_ip), .hl2_ip(hl2_ip), .tx_enable(tx_link_enable),
        .hl2_mac(hl2_mac), .our_port(our_port), .tx_insert(tx_cnt_insert), .tx_skip(tx_cnt_skip),
        .safety_byte(safety_byte), .tx_fifo_fill(tx_fifo_fill), .tx_trim(tx_trim),
        .irq_pkt(irq_pkt), .irq_status(irq_hl2_status)
    );

    // =========================================================================== receiver input select
    // The receiver bank, the zoom receiver, the full-band spectrum and through them FT8 take either the HL2 link's
    // stream or, on a second board, the board link's stream (blink.ctrl.rx_from_link, docs/SFP_LINKS.md 5.4). One
    // register stage follows the selection. The HL2 transmit side and hl2_link's registers always keep the HL2's own.
    wire [11:0] bl_samp;
    wire        bl_valid, bl_is_fill, bl_sel;
    wire [47:0] bl_index;
    reg  [11:0] rsamp = 12'd0;
    reg         rsamp_valid = 1'b0, rsamp_is_fill = 1'b0;
    reg  [47:0] rsamp_index = 48'd0;
    always @(posedge clk_dsp) begin
        rsamp         <= bl_sel ? bl_samp    : samp;
        rsamp_valid   <= bl_sel ? bl_valid   : samp_valid;
        rsamp_is_fill <= bl_sel ? bl_is_fill : samp_is_fill;
        rsamp_index   <= bl_sel ? bl_index   : samp_index;
    end

    // Clocks since the last real sample; bit 18 set means 2^18 clocks (2.2 ms) have passed, which counts as not
    // streaming, and the count stops. Bit 18 is the flag itself because comparing a count against all ones would
    // feed back into the enable of every bit and, through the LED output, into a wide net.
    reg [18:0] stream_age = 19'h40000;
    always @(posedge clk_dsp)
        if (rsamp_valid && !rsamp_is_fill) stream_age <= 19'd0;
        else if (!stream_age[18]) stream_age <= stream_age + 1'b1;
    assign led_rx_streaming = !stream_age[18];

    // =========================================================================== receiver bank
    // rx_bank has NRX receivers. Each one mixes the 12-bit samples down with a numerically controlled oscillator
    // (CORDIC mixer), decimates them with CIC filters and a FIR filter, and gives IQ samples at 48, 96, 192 or 384 ksps
    // on one shared output stream (docs/ARCHITECTURE.md 3.2). Its registers (phase increment and control per
    // receiver) are written through rx_bank_regs on page 0x03.
    wire        rb_wr;
    wire [3:0]  rb_addr;
    wire [31:0] rb_wdata;
    // bank_valid, bank_idx_n, bank_i, bank_q: one IQ sample of receiver bank_idx_n per valid clock
    wire        bank_valid;
    localparam integer RBW = $clog2(NRX > 1 ? NRX : 2);     // RBW = bits needed to number the receivers (at least one, even for a single receiver)
    wire [RBW-1:0] bank_idx_n;
    wire [2:0]  bank_index = bank_idx_n;                     // the back end keeps 3 bits of receiver number, so the upper ones are zero
    wire signed [23:0] bank_i, bank_q;

    rx_bank_regs #(.NRX(NRX)) u_rxb_regs (
        .clk(clk_dsp), .rst(rst_dsp),
        .bus_wr(l3_wr), .bus_rd(l3_rd), .bus_addr(l3_a), .bus_wdata(l3_d), .bus_rdata(rd_rxb),
        .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata)
    );

    rx_bank #(.N(NRX), .ADC_WIDTH(12), .FIR_COEFF_FILE("rtl/rx/fir_coeffs.hex")) u_rx_bank (
        .clock(clk_dsp), .rst(rst_dsp),
        .adc_data(rsamp), .adc_valid(rsamp_valid),
        .reg_wr(rb_wr), .reg_addr(rb_addr[RBW:0]), .reg_wdata(rb_wdata),
        .out_valid(bank_valid), .out_index(bank_idx_n), .out_i(bank_i), .out_q(bank_q)
    );

    // =========================================================================== receiver back end
    // rx_backend does, per receiver, the noise blanker, the channel filter, SSB/CW/AM/SAM/FM demodulation, AGC and
    // S-meter level, and gives 12 ksps audio (docs/ARCHITECTURE.md 3.10). It also writes the IQ blocks of the
    // receivers into DDR3 rings through the write arbiter's top tier (bk_req, bk_gnt, bk_done), stamped with the HL2
    // sample index of the first sample, and its page is 0x0C.
    wire        bk_valid, bk_iq;
    wire [2:0]  bk_rx;
    wire [15:0] bk_s0, bk_s1;
    wire [47:0] bk_stamp;
    wire        bk_req, bk_gnt, bk_done, bk_irq;
    wire [31:0] bk_addr;
    wire [7:0]  bk_burstlen, bk_wmask;
    wire [63:0] bk_wdata;

    rx_backend #(.NRX(NRX)) u_backend (
        .clk(clk_dsp), .rst(rst_dsp),
        .in_valid(bank_valid), .in_index(bank_index), .in_i(bank_i), .in_q(bank_q),
        .hl2_index(rsamp_index),
        .reg_wr(lc_wr), .reg_rd(lc_rd), .reg_addr(lc_a), .reg_wdata(lc_d), .reg_rdata(rd_bk),
        .out_valid(bk_valid), .out_rx(bk_rx), .out_s0(bk_s0), .out_s1(bk_s1), .out_iq(bk_iq),
        .out_stamp(bk_stamp),
        .ring_req(bk_req), .ring_addr(bk_addr), .ring_burstlen(bk_burstlen), .ring_wdata(bk_wdata),
        .ring_wmask(bk_wmask), .ring_gnt(bk_gnt), .ring_done(bk_done),
        .irq(bk_irq)
    );

    // =========================================================================== FT8 front end begin
    // rtl/ft8/ft8_frontend.v works on the back end's audio samples (out_iq = 0 only): it captures a 15 s slot,
    // makes a spectrogram, searches for the synchronization pattern and runs the candidate engine, so that the CPU
    // only has to decode what the chip found (docs/ARCHITECTURE.md 3.12). It has register page 0x0D, the write
    // arbiter's FT8 tier, the read arbiter's "rest" tier and interrupt line 11.
    wire        f8_wreq, f8_wgnt, f8_wdone, f8_rreq, f8_rgnt, f8_rvalid, f8_rdone, f8_irq;
    wire [31:0] f8_waddr, f8_raddr;
    wire [7:0]  f8_wburst, f8_wmask, f8_rburst;
    wire [63:0] f8_wdata, f8_rdata;

    ft8_frontend #(.NRX(NRX)) u_ft8 (
        .clk(clk_dsp), .rst(rst_dsp),
        .audio_valid(bk_valid), .audio_rx(bk_rx), .audio_sample(bk_s0), .audio_iq(bk_iq),
        .bus_wr(ld_wr), .bus_rd(ld_rd), .bus_addr(ld_a), .bus_wdata(ld_d), .bus_rdata(rd_ft8),
        .wr_req(f8_wreq), .wr_addr(f8_waddr), .wr_burstlen(f8_wburst), .wr_wdata(f8_wdata),
        .wr_wmask(f8_wmask), .wr_gnt(f8_wgnt), .wr_done(f8_wdone),
        .rd_req(f8_rreq), .rd_addr(f8_raddr), .rd_burstlen(f8_rburst), .rd_gnt(f8_rgnt),
        .rd_rvalid(f8_rvalid), .rd_rdata(f8_rdata), .rd_done(f8_rdone),
        .irq(f8_irq)
    );
    // =========================================================================== FT8 front end end

    // =========================================================================== zoom begin
    // The zoom receiver (docs/ZOOM_IN_CHIP.md, docs/ZOOM_FIT.md) is a second digital down converter with a window and
    // a frame buffer, fed by the same sample stream as the receiver bank. It has no FFT of its own: the spectrum
    // pipeline plays each frame of 4,096 samples through the last twelve stages of the whole-band FFT (the zfr_*
    // wires) and gives the bins to its zoom context. That context's trace goes to the compositor's zoom snapshot and
    // its waterfall bytes go through a second waterfall writer into the zoom ring (zwf_ring_base and zwf_write_line
    // of the video page) on the write arbiter's capture tier, which has no other user. ZOOM = 0 leaves all of it out.
    wire        zfr_ready, zfr_go, zfr_valid, zfr_last;
    wire signed [15:0] zfr_re, zfr_im;
    wire [31:0] rd_zoom_fe, rd_zoom_be;
    wire        zwf_valid, zwf_sol, zwf_eol;
    wire [7:0]  zwf_data;
    wire [31:0] zwf_ring_base;
    wire [10:0] zwf_write_line;
    wire        zww_req, zww_gnt, zww_done;
    wire [31:0] zww_addr;
    wire [7:0]  zww_burst, zww_wmask;
    wire [63:0] zww_wdata;

    // When ZOOM is 0 the else branch ties every output of the zoom block to 0, so the rest of the core does not change.
    generate
        if (ZOOM != 0) begin : g_zoom
            zoom_frontend u_zoom (
                .clk(clk_dsp), .rst(rst_dsp),
                .adc_data(rsamp), .adc_valid(rsamp_valid),
                .bus_wr(l6_wr), .bus_rd(l6_rd), .bus_addr(l6_a), .bus_wdata(l6_d), .bus_rdata(rd_zoom_fe),
                .fr_ready(zfr_ready), .fr_go(zfr_go), .fr_valid(zfr_valid), .fr_last(zfr_last),
                .fr_re(zfr_re), .fr_im(zfr_im)
            );
            waterfall_writer #(.LINE_BYTES(1920), .RING_LINES(2048)) u_zwf_writer (
                .clk(clk_dsp), .rst(rst_dsp),
                .in_valid(zwf_valid), .in_data(zwf_data), .in_ready(),
                .ring_base(zwf_ring_base), .write_line_ptr(zwf_write_line),
                .req(zww_req), .addr(zww_addr), .burstlen(zww_burst), .wdata(zww_wdata), .wmask(zww_wmask),
                .gnt(zww_gnt), .done(zww_done)
            );
        end else begin : g_nozoom
            assign zfr_ready = 1'b0;
            assign zfr_valid = 1'b0;
            assign zfr_last = 1'b0;
            assign zfr_re = 16'sd0;
            assign zfr_im = 16'sd0;
            assign rd_zoom_fe = 32'd0;
            assign zwf_write_line = 11'd0;
            assign zww_req = 1'b0;
            assign zww_addr = 32'd0;
            assign zww_burst = 8'd0;
            assign zww_wmask = 8'd0;
            assign zww_wdata = 64'd0;
        end
    endgenerate
    // The zoom page 0x06 has two halves of registers, one in the front end and one in the spectrum pipeline's zoom
    // part; each answers 0 when it is not the owner, so ORing gives the page.
    assign rd_zoom = rd_zoom_fe | rd_zoom_be;
    // =========================================================================== zoom end

    // =========================================================================== spectrum
    // spectrum_pipeline takes the same 12-bit stream, windows it, runs the 16,384-point streaming FFT (4.6875 kHz
    // per bin), averages, maps bins to display columns and makes a spectrum line (line_rd_*, read by the compositor
    // for the trace) and waterfall bytes (wf_*, which waterfall_writer stores in DDR3). Page 0x05. The zoom_in_* ports
    // are the older direct zoom path and are tied off; the zfr_* ports are the frame path of the zoom receiver.
    wire        spec_irq, zspec_irq;
    wire [10:0] line_rd_addr, zline_rd_addr;
    wire [15:0] line_rd_data, zline_rd_data;
    wire        wf_valid, wf_sol, wf_eol;
    wire [7:0]  wf_data;

    spectrum_pipeline #(.ZOOM_SHARED((ZOOM != 0) ? 1 : 0)) u_spectrum (
        .clk(clk_dsp), .rst(rst_dsp),
        .adc_data(rsamp), .adc_valid(rsamp_valid),
        .reg_wr(l5_wr), .reg_rd(l5_rd), .reg_addr(l5_a), .reg_wdata(l5_d), .reg_rdata(rd_spec),
        .irq_line_done(spec_irq),
        .line_rd_addr(line_rd_addr), .line_rd_data(line_rd_data),
        .wf_valid(wf_valid), .wf_sol(wf_sol), .wf_eol(wf_eol), .wf_data(wf_data),
        // zoom context: the frames of the zoom receiver (zoom block above) through the shared FFT
        .zoom_in_valid(1'b0), .zoom_in_first(1'b0), .zoom_in_bin(12'd0), .zoom_in_usable(1'b0),
        .zoom_in_re(29'sd0), .zoom_in_im(29'sd0),
        .zfr_ready(zfr_ready), .zfr_go(zfr_go), .zfr_valid(zfr_valid), .zfr_last(zfr_last),
        .zfr_re(zfr_re), .zfr_im(zfr_im),
        .zreg_wr(l6_wr), .zreg_rd(l6_rd), .zreg_addr(l6_a), .zreg_wdata(l6_d), .zreg_rdata(rd_zoom_be),
        .zirq_line_done(zspec_irq),
        .zline_rd_addr(zline_rd_addr), .zline_rd_data(zline_rd_data),
        .zwf_valid(zwf_valid), .zwf_sol(zwf_sol), .zwf_eol(zwf_eol), .zwf_data(zwf_data)
    );

    // =========================================================================== video: compositor begin
    // The compositor owns register page 0x07 (docs/V2_COMPOSITOR.md), reads the GUI framebuffer and the waterfall
    // lines through the read arbiter's video tier, and gives the HDMI encoder its pixel (vid_rgb, for the position
    // vid_cx, vid_cy in the same clock). The waterfall writer stays here. W = 1920, H = 1080 are the visible size,
    // FW x FH = 2200 x 1125 the whole frame with blanking (1080p), and VCAP is the number of lines captured per frame.
    wire [31:0] wf_ring_base;
    wire [10:0] wf_write_line;
    wire        wfw_req, wfw_gnt, wfw_done;
    wire [31:0] wfw_addr;
    wire [7:0]  wfw_burst, wfw_wmask;
    wire [63:0] wfw_wdata;
    wire        vr_req, vr_gnt, vr_rvalid, vr_done, frame_start;
    wire [31:0] vr_addr;
    wire [7:0]  vr_burst;
    wire [63:0] vr_rdata;

    waterfall_writer #(.LINE_BYTES(1920), .RING_LINES(2048)) u_wf_writer (
        .clk(clk_dsp), .rst(rst_dsp),
        .in_valid(wf_valid), .in_data(wf_data), .in_ready(),
        .ring_base(wf_ring_base), .write_line_ptr(wf_write_line),
        .req(wfw_req), .addr(wfw_addr), .burstlen(wfw_burst), .wdata(wfw_wdata), .wmask(wfw_wmask),
        .gnt(wfw_gnt), .done(wfw_done)
    );

    compositor #(.W(1920), .H(1080), .FW(2200), .FH(1125), .VCAP(1082), .ZOOM_SNAP(ZOOM != 0)) u_comp (
        .clk(clk_dsp), .rst(rst_dsp), .clk_pix(clk_pix), .cx(vid_cx), .cy(vid_cy), .rgb(vid_rgb),
        .bus_wr(l7_wr), .bus_rd(l7_rd), .bus_addr(l7_a), .bus_wdata(l7_d), .bus_rdata(rd_vid),
        .rd_req(vr_req), .rd_addr(vr_addr), .rd_burstlen(vr_burst), .rd_gnt(vr_gnt),
        .rd_rvalid(vr_rvalid), .rd_rdata(vr_rdata), .rd_done(vr_done),
        .line_rd_addr(line_rd_addr), .line_rd_data(line_rd_data),
        .zline_rd_addr(zline_rd_addr), .zline_rd_data(zline_rd_data),
        .wf_ring_base(wf_ring_base), .wf_write_line(wf_write_line),
        .zwf_ring_base(zwf_ring_base), .zwf_write_line(zwf_write_line),
        .frame_start(frame_start)
    );
    // =========================================================================== video: compositor end

    // =========================================================================== TX chain
    // The CPU writes baseband samples ({I, Q} 16 bits each, 48 kHz) into a DDR3 ring. audio_ring_reader reads them
    // back through the read arbiter's TX tier, tx_chain interpolates them to 76.8 Msps, mixes them with its own
    // oscillator, applies the gain and the safety trip, and hands 12-bit samples to the HL2 link transmit side, one
    // per received sample. Page 0x08.
    wire        tx_enable;
    wire [4:0]  tx_gain_shift;
    wire [31:0] tx_nco, tx_ring_base, tx_ring_wptr, tx_ring_rptr;
    wire        tx_low_water, tx_irq;

    tx_regs u_tx_regs (
        .clk(clk_dsp), .rst(rst_dsp),
        .bus_wr(l8_wr), .bus_rd(l8_rd), .bus_addr(l8_a), .bus_wdata(l8_d), .bus_rdata(rd_tx),
        .enable(tx_enable), .gain_shift(tx_gain_shift), .nco_freq(tx_nco),
        .ring_base(tx_ring_base), .ring_wptr(tx_ring_wptr), .ring_rptr(tx_ring_rptr),
        .low_water(tx_low_water), .irq(tx_irq)
    );

    // TX baseband ring: one 32-bit word per 48 kHz sample, {I[15:0], Q[15:0]}; the reader restarts at ring word 0
    // whenever TX is disabled. 8,192 words = 171 ms.
    wire        txr_mreq, txr_mvalid;
    wire [31:0] txr_maddr, txr_mdata;
    wire        tx_bb_valid, tx_bb_req;
    wire signed [15:0] tx_bb_i, tx_bb_q;
    wire        txa_req, txa_gnt, txa_rvalid, txa_done;
    wire [31:0] txa_addr;
    wire [7:0]  txa_burst;
    wire [63:0] txa_rdata;

    // "reset or switched off" taken from a register: used as a LUT behind the chip's reset net (thousands of loads) it
    // reached the data registers of the ring reader and the audio engine late.
    reg tx_ring_rst = 1'b1;
    always @(posedge clk_dsp) tx_ring_rst <= rst_dsp || !tx_enable;
    audio_ring_reader #(.RING_SIZE_WORDS(8192), .FIFO_DEPTH(8), .LOW_WATER(2)) u_tx_ring (
        .clk(clk_dsp), .rst(tx_ring_rst),
        .ring_base(tx_ring_base), .wr_ptr(tx_ring_wptr), .rd_ptr(tx_ring_rptr),
        .mem_req(txr_mreq), .mem_addr(txr_maddr), .mem_rvalid(txr_mvalid), .mem_rdata(txr_mdata),
        .smp_valid(tx_bb_valid), .smp_l(tx_bb_i), .smp_r(tx_bb_q), .smp_ready(tx_bb_req),
        .hdmi_valid(), .hdmi_l(), .hdmi_r(), .ring_empty(), .low_water(tx_low_water)
    );

    rd_word_adapter u_tx_adapt (
        .clk(clk_dsp), .rst(rst_dsp),
        .mem_req(txr_mreq), .mem_addr(txr_maddr), .mem_rvalid(txr_mvalid), .mem_rdata(txr_mdata),
        .req(txa_req), .addr(txa_addr), .burstlen(txa_burst), .gnt(txa_gnt),
        .rvalid(txa_rvalid), .rdata(txa_rdata)
    );

    // tx_pace: the HL2 link's pace pulse, one per received sample, trimmed to keep the HL2's FIFO at its target
    wire               tx_pace;
    wire signed [11:0] tx_out;
    wire               tx_out_valid;
    wire               tx_trip = safety_byte[7] | safety_byte[6];   // PROTOCOL 5.4: a safety trip or over-temperature stops the transmitter

    tx_chain u_tx_chain (
        .clock(clk_dsp), .rst(rst_dsp),
        .pace(tx_pace),                   // H2 rate lock: one per received sample, trimmed
        .bb_i(tx_bb_i), .bb_q(tx_bb_q), .bb_valid(tx_bb_valid), .bb_req(tx_bb_req),
        .enable(tx_enable), .trip(tx_trip), .nco_freq(tx_nco), .gain_shift(tx_gain_shift),
        .out_data(tx_out), .out_valid(tx_out_valid)
    );

    // =========================================================================== HL2 link transmit, on lane 0
    // hl2_link_tx_top paces the transmit samples to the HL2's rate (one per received sample, trimmed from the HL2's
    // FIFO fill level, which rx_tx_fill_bridge brings over from n1_rxc), frames them (PROTOCOL 6.2) and sends them in
    // sfp_txc, together with the CPU's own transmit queue.
    wire [15:0] fill_dsp;
    wire        fill_dsp_valid;
    rx_tx_fill_bridge u_fill (
        .clk_rx(n1_rxc), .raw_version(rx_raw_version), .raw_tx_fifo_fill(rx_tx_fifo_fill),
        .raw_commit_pulse(rx_raw_commit),
        .clk_dsp(clk_dsp), .fifo_fill(fill_dsp), .fifo_fill_valid(fill_dsp_valid)
    );
    reg [15:0] fill_hold = 16'd0;
    always @(posedge clk_dsp) if (fill_dsp_valid) fill_hold <= fill_dsp;
    assign tx_fifo_fill = fill_hold;
    assign tx_trim      = tx_cnt_insert - tx_cnt_skip;

    // The settings (MAC and IP addresses, port) change rarely: they are sent across into sfp_txc as one 176-bit word
    // every 64 clk_dsp clocks.
    wire [175:0] txcfg_dsp = {our_mac, our_ip, our_port, hl2_mac, hl2_ip};
    wire [175:0] txcfg;
    reg  [5:0]   txcfg_tick = 6'd0;
    always @(posedge clk_dsp) txcfg_tick <= txcfg_tick + 1'b1;
    cdc_word #(.W(176)) u_txcfg (
        .clk_a(clk_dsp), .d_a(txcfg_dsp), .send_a(txcfg_tick == 6'd0),
        .clk_b(sfp_txc), .q_b(txcfg), .valid_b()
    );

    hl2_link_tx_top u_hl2_tx (
        .clk_dsp(clk_dsp), .rst_dsp(rst_dsp),
        .rx_adc_valid(samp_valid), .fifo_fill(fill_dsp), .fifo_fill_valid(fill_dsp_valid),
        .pace_out(tx_pace), .in_sample(tx_out), .in_valid(tx_out_valid),
        .cfg_tx_enable(tx_link_enable), .cfg_trip(tx_trip),
        .cnt_tx_skip(tx_cnt_skip), .cnt_tx_insert(tx_cnt_insert), .cnt_tx_fill_updates(),
        .clk_tx(sfp_txc), .rst_tx(rst_tx),
        .cfg_my_mac(txcfg[175:128]), .cfg_my_ip(txcfg[127:96]), .cfg_my_port(txcfg[95:80]),
        .cfg_hl2_mac(txcfg[79:32]), .cfg_hl2_ip(txcfg[31:0]),
        .cq_wr_en(cq_wr_en), .cq_wr_addr(cq_wr_addr), .cq_wr_data(cq_wr_data),
        .cq_send_len_wr(cq_send_len_wr), .cq_wr_len_in(cq_wr_len), .cq_busy(cq_busy),
        .cnt_tx_frames(), .cnt_cq_frames(), .cnt_tx_fifo_overrun(),
        .tx_link_up(hl2_tx_link_up), .gmii_txd(hl2_g_tx_d), .gmii_tx_en(hl2_g_tx_en)
    );

    // =========================================================================== audio
    // audio_regs (page 0x09) controls the audio engine. The engine reads a 4,096-word ring (85 ms of 48 kHz stereo)
    // from DDR3 through the read arbiter's audio tier, interpolates it, and sends it to the PT8211 DAC; it also gives
    // the 48 kHz samples as a tap (au_tap_*), which audio_out_src turns into a never-stopping stream for S/PDIF, I2S,
    // HDMI and the USB cores.
    wire        au_enable, au_low_water, au_irq;
    wire [31:0] au_ring_base, au_ring_wptr, au_ring_rptr;
    wire        aur_mreq, aur_mvalid;
    wire [31:0] aur_maddr, aur_mdata;
    wire        aua_req, aua_gnt, aua_rvalid, aua_done;
    wire [31:0] aua_addr;
    wire [7:0]  aua_burst;
    wire [63:0] aua_rdata;

    // ---- audio outputs begin
    wire [2:0]  ao_ctl;
    wire        ao_lock, ao_run, ao_live, ao_ev_slip, ao_ev_err;
    wire        au_tap_v;
    wire signed [15:0] au_tap_l, au_tap_r;
    // ---- audio outputs end

    audio_regs u_au_regs (
        .clk(clk_dsp), .rst(rst_dsp),
        .bus_wr(l9_wr), .bus_rd(l9_rd), .bus_addr(l9_a), .bus_wdata(l9_d), .bus_rdata(rd_aud),
        .enable(au_enable), .ring_base(au_ring_base), .ring_wptr(au_ring_wptr),
        .ring_rptr(au_ring_rptr), .low_water(au_low_water), .irq(au_irq),
        .out_ctl(ao_ctl), .out_lock(ao_lock), .out_run(ao_run), .out_live(ao_live),
        .out_ev_slip(ao_ev_slip), .out_ev_err(ao_ev_err)
    );

    // The clk_dsp frequency (gowin/p1/ip/gowin_pll_dsp.mod: VCO 1,200 MHz divided by 10). The audio engine and the
    // 48 kHz filler of the output stream derive their timing from it: one sample is 2,500 clocks.
    localparam integer CLK_DSP_HZ = 120_000_000;
    reg au_rst = 1'b1;                       // as tx_ring_rst above
    always @(posedge clk_dsp) au_rst <= rst_dsp || !au_enable;
    // 4,096-word ring; it restarts at word 0 whenever audio is disabled
    audio_engine #(.CLK_HZ(CLK_DSP_HZ), .BCK_HZ(12_288_000), .RING_SIZE_WORDS(4096)) u_audio (
        .clk(clk_dsp), .rst(au_rst),
        .ring_base(au_ring_base), .wr_ptr(au_ring_wptr), .rd_ptr(au_ring_rptr),
        .mem_req(aur_mreq), .mem_addr(aur_maddr), .mem_rvalid(aur_mvalid), .mem_rdata(aur_mdata),
        .pt8211_bck(pt8211_bck), .pt8211_ws(pt8211_ws), .pt8211_din(pt8211_din),
        .hdmi_audio_valid(au_tap_v), .hdmi_audio_l(au_tap_l), .hdmi_audio_r(au_tap_r),
        .ring_empty(), .ring_low_water(au_low_water), .interp_underrun()
    );

    // ---- audio outputs begin (docs/AUDIO_OUT.md): one never-stopping 48 kHz stream taken from the engine's tap
    // (zeros while the engine is off, or the 1 kHz test tone), which goes to S/PDIF and I2S on the audio clock and to
    // the HDMI audio packets in the top level
    wire               src48_v, usb_irq, usbh_irq, hmic_v;
    wire signed [15:0] hmic_l, hmic_r;
    wire signed [15:0] src48_l, src48_r;
    audio_out_src #(.PERIOD(CLK_DSP_HZ / 48000)) u_aout_src (
        .clk(clk_dsp), .rst(rst_dsp),
        .in_v(au_tap_v && au_enable), .in_l(au_tap_l), .in_r(au_tap_r), .tone(ao_ctl[2]),
        .s_v(src48_v), .s_l(src48_l), .s_r(src48_r), .live(ao_live)
    );
    // ---- USB audio begin (docs/USB_AUDIO.md). The PC records src48_* (the radio's stream as it leaves the source).
    // aud48_* for the digital outputs is that stream two clocks later, with the PC's playback added while
    // usb.ctrl.monitor is set. The PC's playback also goes to the CPU FIFO of page 0x0E.
    usb_audio u_usb (
        .clk_usb(clk_usb), .clk_dsp(clk_dsp), .rst_dsp(rst_dsp),
        .dp_i(usb_dp_i), .dn_i(usb_dn_i), .dp_o(usb_dp_o), .dn_o(usb_dn_o), .oe(usb_oe),
        .pullup_en(usb_pullup),
        .bus_wr(le_wr), .bus_rd(le_rd), .bus_addr(le_a), .bus_wdata(le_d), .bus_rdata(rd_usb),
        .irq(usb_irq),
        .s_v(src48_v), .s_l(src48_l), .s_r(src48_r),
        .m_v(aud48_valid), .m_l(aud48_l), .m_r(aud48_r),
        .x_v(hmic_v), .x_l(hmic_l), .x_r(hmic_r)
    );
    // ---- USB audio end
    // ---- USB host begin (docs/USB_HOST.md). The headset's speaker gets aud48_* (what S/PDIF, I2S and HDMI get); its
    // microphone goes to the CPU FIFO of page 0x0E (usb.ctrl.speech_src). Interrupt line 13.
    usbh_top u_usbh (
        .clk_usb(clk_usb), .clk_dsp(clk_dsp), .rst_dsp(rst_dsp),
        .a_i(usbh_a_i), .b_i(usbh_b_i), .a_o(usbh_a_o), .b_o(usbh_b_o), .oe(usbh_oe),
        .bus_wr(lf_wr), .bus_rd(lf_rd), .bus_addr(lf_a), .bus_wdata(lf_d), .bus_rdata(rd_usbh),
        .irq(usbh_irq),
        .s_v(aud48_valid), .s_l(aud48_l), .s_r(aud48_r),
        .m_v(hmic_v), .m_l(hmic_l), .m_r(hmic_r)
    );
    // ---- USB host end
    // audio_digital_out makes the S/PDIF and I2S streams from the 48 kHz samples (24-bit words, the 16-bit samples padded with
    // zeros), crossing from clk_dsp to the audio clock; ctl[1:0] select the outputs and the test tone.
    audio_digital_out u_aout (
        .clk(clk_dsp), .rst(rst_dsp),
        .s_v(aud48_valid), .s_l({aud48_l, 8'd0}), .s_r({aud48_r, 8'd0}),
        .ctl({1'b0, ao_ctl[1:0]}), .u_v(), .u_l(), .u_r(),          // the USB tap is not used here
        .clk_aud(clk_aud), .aud_lock(aud_lock),
        .spdif(spdif_out), .i2s_bck(i2s_bck), .i2s_ws(i2s_ws), .i2s_sd(i2s_sd), .i2s_mclk(i2s_mclk),
        .st_lock(ao_lock), .st_run(ao_run), .ev_in(), .ev_frame(), .ev_slip(ao_ev_slip), .ev_err(ao_ev_err)
    );
    // ---- audio outputs end

    // reads the audio ring words through a lane word adapter
    rd_word_adapter u_au_adapt (
        .clk(clk_dsp), .rst(rst_dsp),
        .mem_req(aur_mreq), .mem_addr(aur_maddr), .mem_rvalid(aur_mvalid), .mem_rdata(aur_mdata),
        .req(aua_req), .addr(aua_addr), .burstlen(aua_burst), .gnt(aua_gnt),
        .rvalid(aua_rvalid), .rdata(aua_rdata)
    );

    // =========================================================================== SFP cages (docs/SFP_LINKS.md)
    // Page 0x0A: transceiver control, cage pins, I2C and lane 0's PCS. Lane 0 (SFP0) carries the HL2 link: its bytes go
    // to the HL2 link blocks above (g_rx_*, g_tx_*), and the network packet memory of this block is not built (NET_MAC 0).
    wire sfp_irq_rx, sfp_irq_link, bl_irq, bl_aligned;
    sfp_top #(.TIMER_X(SFP_TIMER_X), .TIMER_SGMII(SFP_TIMER_SGMII), .NET_MAC(0)) u_sfp (
        .clk(clk_dsp), .rst(rst_dsp),
        .bus_wr(la_wr), .bus_rd(la_rd), .bus_addr(la_a), .bus_wdata(la_d), .bus_rdata(rd_sfp),
        .por_n(serdes_por_n), .ln_rst_n(ln_rst_n), .ln_rx_rst(ln_rx_rst), .ln_tx_rst(ln_tx_rst),
        .ln0_fix(ln0_fix), .ln1_fix(ln1_fix), .ln0_stat(ln0_stat), .ln1_stat(ln1_stat), .diag(sfp_diag),
        .ln1_aligned(bl_aligned),
        .sfp_tx_disable(sfp_tx_disable), .sfp_los(sfp_los),
        .twi_scl_o(twi_scl_o), .twi_sda_o(twi_sda_o), .twi_scl_i(twi_scl_i), .twi_sda_i(twi_sda_i),
        .twi_sel(twi_sel),
        .txc(sfp_txc), .tx_word(ln0_tx), .rxc(n1_rxc), .rx_vld(ln0_rx_vld), .rx_word(ln0_rx),
        .irq_rx(sfp_irq_rx), .irq_link(sfp_irq_link),
        .g_rx_rst(hl2_g_rx_rst), .g_rx_d(hl2_g_rx_d), .g_rx_dv(hl2_g_rx_dv), .g_rx_er(hl2_g_rx_er), .g_rx_ce(hl2_g_rx_ce),
        .g_tx_rst(), .g_tx_d(hl2_g_tx_d), .g_tx_en(hl2_g_tx_en), .g_tx_link_up(hl2_tx_link_up)
    );
    // page 0x0B: the board link on SFP1, which sends the HL2 link's own sample stream to a second board and can
    // hand that board's stream back (rx_*, selected by bl_sel)
    blink_top u_blink (
        .clk(clk_dsp), .rst(rst_dsp),
        .bus_wr(lb_wr), .bus_rd(lb_rd), .bus_addr(lb_a), .bus_wdata(lb_d), .bus_rdata(rd_blink),
        .src_samp(samp), .src_valid(samp_valid), .src_is_fill(samp_is_fill), .src_index(samp_index),
        .rx_samp(bl_samp), .rx_valid(bl_valid), .rx_is_fill(bl_is_fill), .rx_index(bl_index),
        .rx_from_link(bl_sel),
        .txc(bl_txc), .tx_word(ln1_tx), .rxc(bl_rxc), .rxw_vld(ln1_rx_vld), .rxw(ln1_rx),
        .aligned(bl_aligned), .irq(bl_irq)
    );

    // =========================================================================== DDR3 lane arbiters
    // The write arbiter picks one of four clients, always the highest-priority one that is waiting, and runs its
    // burst on lane 4; the read arbiter does the same on lane 5 with four read clients. Each client raises req with
    // an address and a burst length, waits for gnt, and finishes when done (writes) or after its data came back
    // (reads). Lane addresses and burst lengths count 64-bit words.
    wire [31:0] wa_addr;
    wire [7:0]  wa_mask, wa_burst;
    wire [63:0] wa_data;
    wire        wa_en, wa_go, wa_wait, wa_done;
    ddr3_write_arbiter u_wr_arb (
        .clk(clk_dsp), .rst(rst_dsp),
        .iq_req(bk_req), .iq_addr(bk_addr), .iq_burstlen(bk_burstlen), .iq_wdata(bk_wdata),
        .iq_wmask(bk_wmask), .iq_gnt(bk_gnt), .iq_done(bk_done),
        .wf_req(wfw_req), .wf_addr(wfw_addr), .wf_burstlen(wfw_burst), .wf_wdata(wfw_wdata),
        .wf_wmask(wfw_wmask), .wf_gnt(wfw_gnt), .wf_done(wfw_done),
        // capture tier: the zoom waterfall writer (raw capture is not built)
        .cap_req(zww_req), .cap_addr(zww_addr), .cap_burstlen(zww_burst), .cap_wdata(zww_wdata),
        .cap_wmask(zww_wmask), .cap_gnt(zww_gnt), .cap_done(zww_done),
        .ft8_req(f8_wreq), .ft8_addr(f8_waddr), .ft8_burstlen(f8_wburst), .ft8_wdata(f8_wdata),
        .ft8_wmask(f8_wmask), .ft8_gnt(f8_wgnt), .ft8_done(f8_wdone),
        .addr_lane4(wa_addr), .wr_mask_lane4(wa_mask), .wr_data_lane4(wa_data),
        .wr_en_lane4(wa_en), .wr_go_lane4(wa_go), .burstcount_lane4(wa_burst),
        .wr_wait_lane4(wa_wait), .wr_done_lane4(wa_done),
        .owner()
    );

    // one register stage between the arbiter and the lane, in both directions (rtl/ddr3/ddr3_wr_relay.v): the lane
    // sits at the DDR3 pins, and the clients are anywhere on the chip
    ddr3_wr_relay u_wr_relay (
        .clk(clk_dsp), .rst(rst_dsp),
        .a_addr(wa_addr), .a_mask(wa_mask), .a_data(wa_data), .a_en(wa_en), .a_go(wa_go),
        .a_burst(wa_burst), .a_wait(wa_wait), .a_done(wa_done),
        .l_addr(addr_lane4), .l_mask(wr_mask_lane4), .l_data(wr_data_lane4), .l_en(wr_en_lane4),
        .l_go(wr_go_lane4), .l_burst(burstcount_lane4), .l_wait(wr_wait_lane4), .l_done(wr_done_lane4)
    );

    wire [31:0] ra_addr;
    wire [7:0]  ra_burst;
    wire        ra_en, ra_rdy;
    ddr3_read_arbiter u_rd_arb (
        .clk(clk_dsp), .rst(rst_dsp),
        .video_req(vr_req), .video_addr(vr_addr), .video_burstlen(vr_burst), .video_gnt(vr_gnt),
        .video_rvalid(vr_rvalid), .video_rdata(vr_rdata), .video_done(vr_done),
        .audio_req(aua_req), .audio_addr(aua_addr), .audio_burstlen(aua_burst), .audio_gnt(aua_gnt),
        .audio_rvalid(aua_rvalid), .audio_rdata(aua_rdata), .audio_done(aua_done),
        .tx_req(txa_req), .tx_addr(txa_addr), .tx_burstlen(txa_burst), .tx_gnt(txa_gnt),
        .tx_rvalid(txa_rvalid), .tx_rdata(txa_rdata), .tx_done(txa_done),
        .rest_req(f8_rreq), .rest_addr(f8_raddr), .rest_burstlen(f8_rburst), .rest_gnt(f8_rgnt),
        .rest_rvalid(f8_rvalid), .rest_rdata(f8_rdata), .rest_done(f8_rdone),
        .addr_lane5(ra_addr), .rd_en_lane5(ra_en), .rd_go_lane5(),
        .burstcount_lane5(ra_burst), .rd_valid_lane5(rd_valid_lane5),
        .rd_data_lane5(rd_data_lane5), .rd_rdy_lane5(ra_rdy),
        .owner()
    );

    // one register stage in front of the read lane (rtl/ddr3/ddr3_rd_relay.v): the arbiter's request, address and
    // length reach the lane's registers without a long path. The data beats (rd_valid, rd_data) do not pass through it.
    ddr3_rd_relay u_rd_relay (
        .clk(clk_dsp), .rst(rst_dsp),
        .a_addr(ra_addr), .a_burst(ra_burst), .a_en(ra_en), .a_rdy(ra_rdy),
        .l_addr(addr_lane5), .l_burst(burstcount_lane5), .l_en(rd_en_lane5), .l_go(rd_go_lane5),
        .l_rdy(rd_rdy_lane5)
    );

    // =========================================================================== system and interrupts
    // The 16 interrupt sources, bit n is line n. sys_regs latches the rising edges, applies the enables and drives ext_int.
    wire [15:0] irq_src = {1'd0,            // 15 spare
                           bl_irq,          // 14 board link: control word waiting, link change
                           usbh_irq,        // 13 USB host: record waiting, transaction done or line change
                           usb_irq,         // 12 USB playback samples waiting (CPU FIFO at its mark)
                           f8_irq,          // 11 FT8 front end
                           bk_irq,          // 10 receiver back end
                           1'b0,            // 9  raw capture (not built)
                           frame_start,     // 8  video frame start
                           sfp_irq_link,    // 7  HL2 lane (SFP0) link change
                           net_irq_s[2],    // 6  network unit on the RJ45 socket (level, its flags and enables)
                           spec_irq,        // 5  spectrum line done
                           tx_irq,          // 4  TX low water
                           au_irq,          // 3  audio low water
                           1'b0,            // 2  IQ block (IQ writer not built)
                           irq_hl2_status,  // 1  HL2 status change
                           irq_pkt};        // 0  packet received

    sys_regs #(.NRX(NRX)) u_sys (
        .clk(clk_dsp), .rst(rst_dsp),
        .bus_wr(l0_wr), .bus_rd(l0_rd), .bus_addr(l0_a), .bus_wdata(l0_d), .bus_rdata(rd_sys),
        .build_id(build_id), .ddr3_init_async(ddr3_init), .plls_locked_async(plls_locked),
        .bus_timeout_tog_async(tmo_tog), .rx_dead_async(rx_dead),
        .irq_src(irq_src), .ext_int(ext_int)
    );

endmodule
