// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// sdr_top: the chip top level of the fpga-sdr FPGA, written for the Sipeed Tang Mega 138K Pro dock
// (Gowin GW5AST-LV138FPG676AC1/I0, device version B, see docs/BOARD.md).
//
// WHAT IT IS AND WHERE IT SITS
// Everything in the radio that can be simulated with the open tools lives in rtl/top/sdr_core.v, and this file
// is the thin shell around it that holds what only Gowin's own tools understand: the pins, the five PLLs (the blocks
// that make new clock frequencies from the 50 MHz oscillator), the AE350 hard RISC-V subsystem (the 800 MHz CPU that
// runs the Rust firmware), the DDR3 memory path, the HDMI serializers with their pseudo-differential pads, the SFP+
// transceiver and the reset sequencing. The smoke test sim/top/tb_sdr_core.v runs the core whole, which is why
// the line between the two files is drawn where it is.
//
// HOW THE RADIO IS WIRED TOGETHER (a beginner's map)
//   - The Hermes-Lite 2 (HL2), the radio front end, sends raw 12-bit ADC samples over Ethernet. They arrive on the
//     SFP0 cage through a transceiver (rtl/sfp), cross into the core, and are mixed down by the receivers, turned
//     into spectra and into audio.
//   - The CPU never sees the samples one by one. It talks to the core through the Extended AHB Slave port (the
//     exts_* wires below), a 32-bit bus that the core turns into registers, one 64 KB page per block
//     (docs/ARCHITECTURE.md 4.1). The core raises 16 interrupt lines (ext_int) back to the CPU.
//   - Bulk data (IQ blocks, waterfall lines, the screen's frame buffer) goes through DDR3, the 1 GB of memory on the
//     board that the CPU uses as its main memory too. The core has two lanes into it (a write lane 4 and a read lane
//     5, both clocked by clk_dsp), and the CPU has its own data bus (the dm_* wires); rtl/mem/ddr_mem.v puts both in
//     front of Gowin's DDR3 controller.
//   - The picture goes out through rtl/video/sdr_hdmi_video.v (TMDS encoding) and the three ELVDS_OBUF pads at
//     the bottom of this file. The sound goes to the PT8211 headphone DAC, to S/PDIF, to I2S and into the HDMI stream.
//
// CLOCK DOMAINS (docs/ARCHITECTURE.md 2; the PLL settings are in gowin/p1/ip/*.mod, the timing constraints in
// gowin/p1/sdr.sdc). Every PLL takes the 50 MHz oscillator (or, for the audio PLL, a 48 MHz output of another
// PLL) and multiplies it up to a VCO frequency (the PLL's internal oscillator, which must stay inside a window) and
// then divides that down once per output.
//   pll_ae350  50 MHz in, VCO 800 MHz: CORE_CLK 800 MHz (the CPU), AHB_CLK 80 MHz and APB_CLK 80 MHz (the two buses
//              the CPU uses to reach peripherals), DDR_CLK 50 MHz (the CPU's data-memory bus) and RTC_CLK 10 MHz (the
//              real-time counter). The core clock is clkout1.
//   pll_ddr3   50 MHz in, VCO 1,200 MHz: DDR3_CLK_IN 50 MHz (clkout0, the reference of the DDR3 controller's reset and
//              initialization logic) and DDR3_MEMORY_CLK 300 MHz (clkout2, placed at PLL_L[0]). The DDR3 IP divides the
//              memory clock by 4 to get its own 75 MHz user clock, called ddr3_sys in the constraints. 300 MHz is
//              deliberately below the 400 MHz the memory chips are rated for, because reads that overlap were lost
//              or corrupted at 400 MHz whenever a lot of logic on the chip switched at once.
//   pll_dsp    50 MHz in, VCO 1,200 MHz: clk_dsp 120 MHz (divide by 10, almost every block of the radio) and clk_48m
//              48 MHz (divide by 25, used by the USB full-speed device and host and as the reference of pll_aud).
//              120 MHz makes a microsecond exactly 120 clocks and one 48 kHz audio sample exactly 2,500 clocks.
//   pll_aud    48 MHz in (clk_48m): clk_aud 49.152 MHz = 1,024 x 48 kHz, the clock of the S/PDIF and I2S outputs
//              (48 MHz x 128 / 125, docs/AUDIO_OUT.md section 3).
//   pll_eth    50 MHz in: clk_eth 100 MHz for the network unit on the RJ45 socket (it sits inside the core, in
//              rtl/hl2link/eth_clk_pll.v, as Gowin_PLL_ETH).
//   pll_video  50 MHz in, VCO 1,112.5 MHz: clk_pix5 370.83 MHz (the TMDS bit clock, five times the pixel clock) and
//              clk_pix 74.17 MHz (the pixel clock of 1080p30, CEA-861 mode 34, 0.11 % below the nominal 74.25 MHz,
//              which the standard allows up to 0.5 %). The pixel clock cannot be exactly 74.25 MHz because the PLL's
//              phase detector needs at least 19 MHz after the input divider, so the nearest reachable value is used.
//              1080p60 needs a pixel clock of about 148.5 MHz; that was tried on these pins and gave a black picture,
//              while 1080p30 and 720p60 work.
//   n1_rxc, sfp_txc  125 MHz, the SerDes lane 0 clocks of the SFP0 cage, which carries the HL2 through a 1000BASE-T
//              copper module (docs/HL2_SFP.md). The RJ45 PHY's RXC pin (C23) is sampled as ordinary data by the
//              network unit and is no clock of the design.
// The domains are unrelated to each other (the constraint file says so with asynchronous clock groups), so every
// signal that crosses from one to another goes through a synchronizer, a Gray-coded FIFO or a handshake.
//
// DDR3 AND THE AE350
// With the default build the DDR3 is Gowin's DDR3 IP in rtl/mem/ddr_mem.v, using both x16 chips (1 GB); the AE350 is
// held in reset until that controller reports that it has calibrated, so a memory that does not come up shows as a
// dark LED 0 and a silent UART rather than as a program that hangs. With `TR_DDR_256 defined the AE350's own shared
// DDR3 controller is used instead, with one chip and 256 MB.

`timescale 1ns / 1ps

// Ports are grouped by what they connect to. Pin names after the // are the ball names on the dock; the pin
// assignments and I/O standards are in gowin/p1/sdr.cst.
module sdr_top (
    input  wire        clk_50m,          // P16, the 50 MHz oscillator on the SOM: the source of every clock
    input  wire        key_rst_n,        // G16, USR_KEY.3: low = reset

    // AE350 debug UART (UART2), carried to the PC by the BL616 USB bridge chip on the dock
    output wire        uart_txd,         // P15 -> BL616 RX
    input  wire        uart_rxd,         // N16 <- BL616 TX

    // AE350 instruction flash (a SPI NOR chip behind the AE350's own flash controller; the CPU executes from it)
    inout  wire        FLASH_SPI_CSN,
    inout  wire        FLASH_SPI_MISO,
    inout  wire        FLASH_SPI_MOSI,
    inout  wire        FLASH_SPI_CLK,
    inout  wire        FLASH_SPI_HOLDN,
    inout  wire        FLASH_SPI_WPN,

    // AE350 JTAG debug port, for a hardware debugger
    input  wire        TCK_IN,
    input  wire        TMS_IN,
    input  wire        TRST_IN,
    input  wire        TDI_IN,
    output wire        TDO_OUT,

    // ---- DDR3 begin
    // The DDR3 memory: two x16 chips share the address and control lines and give 32 data lines and a 15-bit row
    // address (1 GB). With `TR_DDR_256 (gowin/p1/build.sh, TR_DDR=256) only the AE350's embedded controller is
    // used, on one chip (byte lanes 0 and 1) with a 14-bit row address.
    output wire [2:0]  DDR3_BANK,
    output wire        DDR3_CS_N,
    output wire        DDR3_RAS_N,
    output wire        DDR3_CAS_N,
    output wire        DDR3_WE_N,
    output wire        DDR3_CK,
    output wire        DDR3_CK_N,
    output wire        DDR3_CKE,
    output wire        DDR3_RESET_N,
    output wire        DDR3_ODT,
`ifdef TR_DDR_256
    output wire [13:0] DDR3_ADDR,
    output wire        DDR3_A14,         // row address bit 14 of the 4 Gbit chip: held low
    output wire [1:0]  DDR3_DM,
    inout  wire [15:0] DDR3_DQ,
    inout  wire [1:0]  DDR3_DQS,
    inout  wire [1:0]  DDR3_DQS_N,
`else
    output wire [14:0] DDR3_ADDR,
    output wire [3:0]  DDR3_DM,
    inout  wire [31:0] DDR3_DQ,
    inout  wire [3:0]  DDR3_DQS,
    inout  wire [3:0]  DDR3_DQS_N,
`endif
    // ---- DDR3 end

    // RTL8211F RGMII PHY on the RJ45 socket: it carries the network unit (rtl/net/net_unit.v, 100 Mbit/s)
    input  wire        rgmii_rxc,        // C23 (sampled as data)
    input  wire [3:0]  rgmii_rxd,
    input  wire        rgmii_rx_ctl,
    output wire        rgmii_txc,        // H24, 25 MHz TXC (a register of clk_eth)
    output wire [3:0]  rgmii_txd,
    output wire        rgmii_tx_ctl,
    output wire        phy_clk,          // E18, the PHY's 25 MHz reference
    output wire        phy_rst_n,        // E17
    output wire        phy_mdc,          // K23
    inout  wire        phy_mdio,         // K22

    // HDMI TX port 0: each TMDS lane is a pseudo-differential pair made by an ELVDS_OBUF on two LVCMOS33D pins
    output wire [2:0]  tmds_p,
    output wire [2:0]  tmds_n,
    output wire        tmds_clk_p,
    output wire        tmds_clk_n,

    // PT8211 stereo DAC (headphones and the speaker amplifier), a three-wire serial DAC
    output wire        hp_bck,
    output wire        hp_ws,
    output wire        hp_din,

    // ---- audio outputs begin: PMOD2 = J26 (S/PDIF for a TOSLINK transmitter module, I2S for an external DAC)
    output wire        spdif_out,        // B21, J26 pin 12: S/PDIF for a TOSLINK transmitter module
    output wire        i2s_bck,          // B20, J26 pin 9:  I2S bit clock 3.072 MHz
    output wire        i2s_ws,           // A20, J26 pin 10: I2S word clock 48 kHz
    output wire        i2s_sd,           // B19, J26 pin 7:  I2S data
    output wire        i2s_mclk,         // A19, J26 pin 8:  I2S master clock 12.288 MHz
    // ---- audio outputs end

    // ---- USB audio begin: the "Custom USB" socket J5, full speed (12 Mbit/s). D+ and D- are driven from the FPGA
    // pins directly, and usb_pullup switches the 1.5 kohm resistor that tells the PC "a full-speed device is here"
    // (docs/USB_AUDIO.md section 9).
    inout  wire        usb_dp,           // T19, 0 ohm to D+
    inout  wire        usb_dn,           // U19, 0 ohm to D-
    output wire        usb_pullup,       // M19, 1.5 kohm to D+
    input  wire [5:0]  usb_hs_unused,    // M21, M22, U21, V21, T20, U20: the high-speed circuit's pins, inputs
    // ---- USB audio end
    // ---- USB host begin: the Pmod USB host board (docs/USB_HOST.md section 4) with two ports; per port the D-/D+
    // pair sits on one pin of the dock's odd row (a: pins 9 and 11) and one of the even row (b: pins 10 and 12).
    // The pins' own pull-downs are the host's 15 kohm pull-downs, so no external part is needed.
    inout  wire [1:0]  usbh_a,
    inout  wire [1:0]  usbh_b,
    // ---- USB host end

    // SFP+ cages (docs/SFP_LINKS.md section 7): SFP0 carries the Hermes-Lite 2, SFP1 is the link to a second
    // board. The serial pairs of transceiver quad 1, lanes 0 and 1, and the 125 MHz reference (quad 1 reference 1,
    // AA13/AB13) are dedicated pins bound by the transceiver block, so the .cst does not list them.
    output wire [1:0]  sfp_tx_disable,   // R18 (SFP0), M20 (SFP1): 1 = module transmitter off
    input  wire [1:0]  sfp_los,          // V18, W18
    inout  wire        twi_scl,          // K25: the board's system I2C (clock chips, module memories)
    inout  wire        twi_sda,          // K26
    output wire [2:0]  twi_sel,          // N19 (bit 2), P19, P26 (bit 0): I2C multiplexer channel

    // LEDs (active low on the dock): see the assignment at the end of the file
    output wire [1:0]  led
);

    // =========================================================================== PLLs
    // Each instance below is a Gowin_PLL_* module generated from the .mod file of the same name (the generated
    // Verilog is not kept in the repository, only the settings). enclk* inputs gate an output; tying one to 1'b1
    // leaves it running.
    wire core_clk, ahb_clk, apb_clk, ddr_clk, rtc_clk;
    Gowin_PLL_AE350 u_pll_ae350 (
        .clkin(clk_50m),
        .clkout0(ddr_clk), .clkout1(core_clk), .clkout2(ahb_clk), .clkout3(apb_clk),
        .clkout4(rtc_clk),
        .enclk0(1'b1), .enclk1(1'b1), .enclk2(1'b1), .enclk3(1'b1), .enclk4(1'b1)
    );

    wire ddr3_clk_in, ddr3_memory_clk, ddr3_lock, ddr3_stop;
    // The DDR3 IP wants a low-speed continuous reference clock (IPUG281 4.4.2, recommended 50 MHz). It is taken from
    // the DDR3 PLL's own 50 MHz output 0, the way that is known to calibrate
    // on the board. ddr3_stop is the enable of the 300 MHz memory clock output (enclk2) and is driven by
    // the DDR3 IP, so the IP can switch that clock off.
    wire ddr3_clk_pll;
    assign ddr3_clk_in = ddr3_clk_pll;
    Gowin_PLL_DDR3 u_pll_ddr3 (
        .clkin(clk_50m), .reset(1'b0), .lock(ddr3_lock),
        .clkout0(ddr3_clk_pll), .clkout2(ddr3_memory_clk),
        .enclk0(1'b1), .enclk2(ddr3_stop)
    );

    wire clk_dsp, dsp_lock;
    // The DSP PLL feeds almost the whole radio at 120 MHz and, on its second output, a 48 MHz clock for USB and for
    // the audio PLL. Its reset input is tied to 1'b0, which lets it run freely from power-up.
    // ---- audio outputs begin
    wire clk_48m;
    Gowin_PLL_DSP u_pll_dsp (
        .clkin(clk_50m), .reset(1'b0), .lock(dsp_lock), .clkout0(clk_dsp), .enclk0(1'b1),
        .clkout1(clk_48m), .enclk1(1'b1)
    );
    // The audio PLL makes 49.152 MHz = 48 MHz x 128 / 125. Its lock is only a status bit (audio.out_status): the
    // chip does not wait for it, and S/PDIF and I2S stay silent while it is low.
    wire clk_aud, aud_lock;
    Gowin_PLL_AUD u_pll_aud (.clkin(clk_48m), .clkout0(clk_aud), .lock(aud_lock));
    // ---- audio outputs end

    wire clk_pix5, clk_pix, video_lock;
    // The video PLL: clk_pix5 is the 5x bit clock for the OSER10 serializers (each pixel clock they send ten bits,
    // two per clk_pix5 edge, which is why the DDR-style serializer only needs 5x), clk_pix is the pixel clock.
    Gowin_PLL_VIDEO u_pll_video (
        .clkin(clk_50m), .reset(1'b0), .lock(video_lock),
        .clkout0(clk_pix5), .clkout1(clk_pix),
        .enclk0(1'b1), .enclk1(1'b1)
    );

    // The chip is held in reset until the three PLLs that gate the fabric have locked (the DDR3 PLL also gates the
    // memory clock, but the AE350 PLL runs on its own).
    wire plls_locked = ddr3_lock & dsp_lock & video_lock;

    // =========================================================================== resets
    // The reset key is asynchronous and bounces, so it goes through a 3-flop synchronizer in the 50 MHz domain and
    // then a debounce: key_ok only follows the synchronized level after it has been stable for 2^20 clocks (21 ms at
    // 50 MHz). key_s starts at all ones so the chip comes out of power-up with the key "released".
    (* preserve *) reg [2:0] key_s = 3'b111;
    reg [19:0] key_cnt = 20'd0;
    // key_cnt counts how long key_s[2] has differed from key_ok; key_ok flips when the count saturates.
    reg        key_ok = 1'b0;          // 1 = key released and stable
    always @(posedge clk_50m) begin
        key_s <= {key_s[1:0], key_rst_n};
        if (key_s[2] == key_ok) key_cnt <= 20'd0;
        else if (&key_cnt)       key_ok  <= key_s[2];
        else                     key_cnt <= key_cnt + 1'b1;
    end
    // sys_rst_n is the master reset, active low: the key must be released and all fabric PLLs locked.
    wire sys_rst_n = key_ok & plls_locked;

    // One synchronous active-high reset per fabric domain. Each is a 4-flop shift register that is forced to ones
    // while sys_rst_n is low (asynchronous assertion) and shifts in zeros after sys_rst_n returns, so it is released
    // a few clocks later and in step with its own clock (reset removal must be synchronous to avoid metastability).
    (* preserve *) reg [3:0] rst_dsp_s = 4'hF;
    always @(posedge clk_dsp or negedge sys_rst_n)
        if (!sys_rst_n) rst_dsp_s <= 4'hF; else rst_dsp_s <= {rst_dsp_s[2:0], 1'b0};
    wire rst_dsp = rst_dsp_s[3];

    // The HL2 link's receive side runs on the transceiver lane 0's recovered clock, n1_rxc, so it has its own reset.
    wire n1_rxc;
    (* preserve *) reg [3:0] rst_rx_s = 4'hF;
    always @(posedge n1_rxc or negedge sys_rst_n)
        if (!sys_rst_n) rst_rx_s <= 4'hF; else rst_rx_s <= {rst_rx_s[2:0], 1'b0};
    wire rst_rx = rst_rx_s[3];

    // The pixel clock domain (compositor and HDMI encoder) has its own reset as well.
    (* preserve *) reg [3:0] rst_pix_s = 4'hF;
    always @(posedge clk_pix or negedge sys_rst_n)
        if (!sys_rst_n) rst_pix_s <= 4'hF; else rst_pix_s <= {rst_pix_s[2:0], 1'b0};
    wire rst_pix = rst_pix_s[3];

    // ---- DDR3 begin: resets of the AE350 and of the DDR3 controller. The controller only needs the key and its
    // own PLL to have locked.
    wire ddr3_init;
    wire ddr3_rstn  = key_ok & ddr3_lock;
`ifdef TR_DDR_256
    // The AE350 comes out of power-on and hardware reset together with the key and the PLLs, and its DDR3 controller
    // (inside the same IP) comes from the key and the DDR3 PLL. The CPU cannot wait for DDR3_INIT here, because
    // holding the core would not hold the controller, so the boot code polls system.status.ddr3_init instead.
    wire ae350_rstn = key_ok & plls_locked;
`else
    // The DDR3 controller in rtl/mem/ddr_mem.v starts first, and the AE350 is held in reset until the controller
    // reports that initialization and calibration are done. A memory that does not come up then shows as a dark LED 0
    // and a silent UART instead of as a program that hangs (the same order as Sipeed's ae350_customized_demo).
    // ae_s is a 3-flop synchronizer into the 50 MHz domain.
    reg [2:0] ae_s = 3'b000;
    always @(posedge clk_50m) ae_s <= {ae_s[1:0], key_ok & plls_locked & ddr3_init};
    wire ae350_rstn = ae_s[2];
`endif
    // ---- DDR3 end

    // =========================================================================== AE350
    // The AE350 is Gowin's hard RISC-V subsystem. Its Extended AHB Slave port (the exts_* wires) is how the CPU
    // reaches the fabric registers, at 0xE800_0000 and up (128 MB window, one 64 KB page per register block).
    wire        exts_hclk, exts_hrstn, exts_hsel, exts_hwrite, exts_hreadyout, exts_hresp;
    wire [31:0] exts_haddr, exts_hwdata, exts_hrdata;
    wire [1:0]  exts_htrans;
    wire [2:0]  exts_hburst, exts_hsize;
    wire [3:0]  exts_hprot;
    wire [15:0] ext_int;
    // SFP+ transceiver <-> core. The two lane clocks are one net in the default build: the macro keeps the single
    // net name `sfp_txc` that the constraints use. With TR_SFP_TXC_OWN the net ln1_txc needs its own create_clock
    // and CLOCK_LOC line.
    wire ln1_txc;
`ifdef TR_SFP_TXC_OWN
`define TR_BL_TXC ln1_txc
`else
`define TR_BL_TXC sfp_txc
`endif
    wire        sfp_txc, bl_rxc, ln0_rx_vld, ln1_rx_vld, serdes_por_n, twi_scl_o, twi_sda_o;
    wire [9:0]  ln0_tx, ln0_rx;
    wire [19:0] ln1_tx, ln1_rx;
    wire [1:0]  ln_rst_n, ln_rx_rst, ln_tx_rst;
    wire [3:0]  ln0_fix, ln1_fix, ln0_stat, ln1_stat;
    wire [11:0] sfp_diag;

    // The two DDR3 lane ports of the core (write lane 4 and read lane 5, 64 bits wide). Burst counts are in 64-bit
    // words; wr_go and rd_go are the "start" strobes of the 256 MB build's controller.
    wire [31:0] addr_lane4, addr_lane5;
    wire [7:0]  wr_mask8_lane4, burstcount_lane4, burstcount_lane5;
    wire [63:0] wr_data_lane4, rd_data_lane5;
    wire        wr_en_lane4, wr_go_lane4, wr_wait_lane4, wr_done_lane4;
    wire        rd_en_lane5, rd_go_lane5, rd_valid_lane5, rd_rdy_lane5;

    // ---- DDR3 begin
`ifdef TR_DDR_256
    // MUG1031 shows a 4-bit wr_mask_lane4 for the 64-bit lane, without saying which polarity. It is taken here as one
    // bit per 16 bits with the DDR3 data-mask polarity (1 = do not write), which is Gowin's convention for its DDR3
    // memory interface; the core's clients all write whole words, so a wrong guess would show up as lost data.
    wire [3:0] wr_mask_lane4;
    genvar gm;
    generate for (gm = 0; gm < 4; gm = gm + 1) begin : g_mask
        assign wr_mask_lane4[gm] = ~(wr_mask8_lane4[2*gm] & wr_mask8_lane4[2*gm+1]);
    end endgenerate
`else
    // The AE350's data memory bus ("Customized Data Memory", MUG1031 8.2.3), carried to rtl/mem/ddr_mem.v. It is
    // 64 bits wide and runs on ddr_clk, the 50 MHz DDR-bus clock.
    wire [63:0] dm_hrdata, dm_hwdata;
    wire [31:0] dm_haddr;
    wire        dm_hready, dm_hresp, dm_hwrite, dm_hrstn;
    wire [2:0]  dm_hburst, dm_hsize;
    wire [3:0]  dm_hprot;
    wire [1:0]  dm_htrans;
`endif
    // ---- DDR3 end

    RiscV_AE350_SOC_Top u_ae350 (
        .FLASH_SPI_CSN(FLASH_SPI_CSN), .FLASH_SPI_MISO(FLASH_SPI_MISO),
        .FLASH_SPI_MOSI(FLASH_SPI_MOSI), .FLASH_SPI_CLK(FLASH_SPI_CLK),
        .FLASH_SPI_HOLDN(FLASH_SPI_HOLDN), .FLASH_SPI_WPN(FLASH_SPI_WPN),

        // ---- DDR3 begin
`ifdef TR_DDR_256
        .DDR3_MEMORY_CLK(ddr3_memory_clk), .DDR3_CLK_IN(ddr3_clk_in), .DDR3_RSTN(ddr3_rstn),
        .DDR3_LOCK(ddr3_lock), .DDR3_STOP(ddr3_stop), .DDR3_INIT(ddr3_init),
        .DDR3_BANK(DDR3_BANK), .DDR3_CS_N(DDR3_CS_N), .DDR3_RAS_N(DDR3_RAS_N),
        .DDR3_CAS_N(DDR3_CAS_N), .DDR3_WE_N(DDR3_WE_N), .DDR3_CK(DDR3_CK), .DDR3_CK_N(DDR3_CK_N),
        .DDR3_CKE(DDR3_CKE), .DDR3_RESET_N(DDR3_RESET_N), .DDR3_ODT(DDR3_ODT),
        .DDR3_ADDR(DDR3_ADDR), .DDR3_DM(DDR3_DM), .DDR3_DQ(DDR3_DQ), .DDR3_DQS(DDR3_DQS),
        .DDR3_DQS_N(DDR3_DQS_N),

        .clk_lane4(clk_dsp), .addr_lane4(addr_lane4), .wr_mask_lane4(wr_mask_lane4),
        .wr_data_lane4(wr_data_lane4), .wr_en_lane4(wr_en_lane4), .wr_go_lane4(wr_go_lane4),
        .burstcount_lane4(burstcount_lane4), .wr_wait_lane4(wr_wait_lane4),
        .wr_done_lane4(wr_done_lane4),
        .clk_lane5(clk_dsp), .addr_lane5(addr_lane5), .rd_en_lane5(rd_en_lane5),
        .rd_go_lane5(rd_go_lane5), .burstcount_lane5(burstcount_lane5),
        .rd_valid_lane5(rd_valid_lane5), .rd_data_lane5(rd_data_lane5), .rd_rdy_lane5(rd_rdy_lane5),
`else
        .DDR_HRDATA(dm_hrdata), .DDR_HREADY(dm_hready), .DDR_HRESP(dm_hresp), .DDR_HADDR(dm_haddr),
        .DDR_HBURST(dm_hburst), .DDR_HPROT(dm_hprot), .DDR_HSIZE(dm_hsize), .DDR_HTRANS(dm_htrans),
        .DDR_HWDATA(dm_hwdata), .DDR_HWRITE(dm_hwrite), .DDR_HCLK(), .DDR_HRSTN(dm_hrstn),
`endif
        // ---- DDR3 end

        .TCK_IN(TCK_IN), .TMS_IN(TMS_IN), .TRST_IN(TRST_IN), .TDI_IN(TDI_IN),
        .TDO_OUT(TDO_OUT), .TDO_OE(),

        .EXT_INT(ext_int),

        .EXTS_HRDATA(exts_hrdata), .EXTS_HREADYIN(exts_hreadyout), .EXTS_HRESP(exts_hresp),
        .EXTS_HADDR(exts_haddr), .EXTS_HBURST(exts_hburst), .EXTS_HPROT(exts_hprot),
        .EXTS_HSEL(exts_hsel), .EXTS_HSIZE(exts_hsize), .EXTS_HTRANS(exts_htrans),
        .EXTS_HWDATA(exts_hwdata), .EXTS_HWRITE(exts_hwrite), .EXTS_HCLK(exts_hclk),
        .EXTS_HRSTN(exts_hrstn),

        .UART2_TXD(uart_txd), .UART2_RTSN(), .UART2_RXD(uart_rxd), .UART2_CTSN(1'b0),
        .UART2_DCDN(1'b1), .UART2_DSRN(1'b1), .UART2_RIN(1'b1), .UART2_DTRN(),
        .UART2_OUT1N(), .UART2_OUT2N(),

        .CORE_CLK(core_clk), .DDR_CLK(ddr_clk), .AHB_CLK(ahb_clk), .APB_CLK(apb_clk),
        .RTC_CLK(rtc_clk),
        .POR_RSTN(ae350_rstn), .HW_RSTN(ae350_rstn)
    );

    // =========================================================================== DDR3
    // ---- DDR3 begin
`ifndef TR_DDR_256
    // Gowin's DDR3 IP with 32 data lines for the board's whole 1 GB, plus the bridge from the AE350's data memory bus
    // and from the core's two lanes (docs/MEM_1GB.md). The bus side runs on the PLL's DDR-bus clock net (the one
    // the AE350's DDR_CLK input has) and the lanes run on clk_dsp, so ddr_mem is where three clock domains meet
    // (bus, lanes and the controller's 75 MHz ddr3_sys). The write mask goes through as the core gives it, one bit
    // per byte with 1 = written.
    ddr_mem u_mem (
        .ddr3_clk_in(ddr3_clk_in), .ddr3_mem_clk(ddr3_memory_clk), .ddr3_lock(ddr3_lock),
        .ddr3_stop(ddr3_stop), .rstn(ddr3_rstn), .init(ddr3_init),
        .DDR3_BANK(DDR3_BANK), .DDR3_CS_N(DDR3_CS_N), .DDR3_RAS_N(DDR3_RAS_N), .DDR3_CAS_N(DDR3_CAS_N),
        .DDR3_WE_N(DDR3_WE_N), .DDR3_CK(DDR3_CK), .DDR3_CK_N(DDR3_CK_N), .DDR3_CKE(DDR3_CKE),
        .DDR3_RESET_N(DDR3_RESET_N), .DDR3_ODT(DDR3_ODT), .DDR3_ADDR(DDR3_ADDR), .DDR3_DM(DDR3_DM),
        .DDR3_DQ(DDR3_DQ), .DDR3_DQS(DDR3_DQS), .DDR3_DQS_N(DDR3_DQS_N),
        .hclk(ddr_clk), .hrstn(dm_hrstn), .haddr(dm_haddr), .hsize(dm_hsize), .htrans(dm_htrans),
        .hwrite(dm_hwrite), .hwdata(dm_hwdata), .hready(dm_hready), .hresp(dm_hresp), .hrdata(dm_hrdata),
        .lane_clk(clk_dsp), .lane_rst(rst_dsp),
        .addr_lane4(addr_lane4), .wr_mask_lane4(wr_mask8_lane4), .wr_data_lane4(wr_data_lane4),
        .wr_en_lane4(wr_en_lane4), .burstcount_lane4(burstcount_lane4),
        .wr_wait_lane4(wr_wait_lane4), .wr_done_lane4(wr_done_lane4),
        .addr_lane5(addr_lane5), .rd_en_lane5(rd_en_lane5), .burstcount_lane5(burstcount_lane5),
        .rd_valid_lane5(rd_valid_lane5), .rd_data_lane5(rd_data_lane5), .rd_rdy_lane5(rd_rdy_lane5)
    );
`endif
    // ---- DDR3 end

    // =========================================================================== HDMI
    // The pixel for position (vid_cx, vid_cy) comes from the compositor inside the core (vid_rgb); this block turns
    // it into TMDS. 1920 x 1080 at 30 Hz is video mode 34 of CEA-861, with a pixel clock of 74.25 MHz nominal.
    wire [2:0]  tmds;
    wire        tmds_clock;
    wire [23:0] vid_rgb;   // V2 compositor pixel for (vid_cx, vid_cy)
    wire [11:0] vid_cx;
    wire [10:0] vid_cy;

    // ---- audio outputs begin: the core's 48 kHz stream (clk_dsp domain) for the HDMI audio packets
    wire        aud48_valid;
    wire [15:0] aud48_l, aud48_r;
    // ---- audio outputs end

    // Video mode 34 is 1920 x 1080 at 30 Hz (CEA-861). EXT_RGB = 1 makes the encoder take its pixel from rgb_ext
    // instead of generating the built-in colour-bar test pattern.
    sdr_hdmi_video #(
        .VIDEO_ID_CODE(34), .SCREEN_WIDTH(1920), .SCREEN_HEIGHT(1080), .VIDEO_REFRESH_RATE(30.0),
        .EXT_RGB(1)   // the pixel comes from the V2 compositor in the core
    ) u_hdmi (
        .clk_pixel(clk_pix), .clk_pixel_x5(clk_pix5), .reset(rst_pix),
        .clk_aud_src(clk_dsp), .aud_valid(aud48_valid), .aud_l(aud48_l), .aud_r(aud48_r),
        .tmds(tmds), .tmds_clock(tmds_clock), .cx(vid_cx), .cy(vid_cy), .rgb_ext(vid_rgb)
    );

    // The three TMDS data lanes and the TMDS clock lane each leave through an emulated-LVDS output buffer: the
    // ELVDS_OBUF drives a true and a complement pad (tmds_p and tmds_n) from one single-ended serial stream.
    genvar gt;
    generate for (gt = 0; gt < 3; gt = gt + 1) begin : g_tmds
        ELVDS_OBUF u_obuf (.I(tmds[gt]), .O(tmds_p[gt]), .OB(tmds_n[gt]));
    end endgenerate
    ELVDS_OBUF u_obuf_clk (.I(tmds_clock), .O(tmds_clk_p), .OB(tmds_clk_n));

    // =========================================================================== fabric core
    // The whole radio apart from this shell. Its ports are the clocks and resets, the AHB slave and interrupts,
    // the two DDR3 lanes, the pins of the network, audio and USB blocks, the SFP transceiver and the video position.
    wire phy_mdio_o, phy_mdio_oe, led_stream;
    // phy_mdio is a bidirectional (open-drain style) pin: the core gives the value and an output enable, and a high
    // impedance level lets the PHY pull it up or drive it.
    assign phy_mdio   = phy_mdio_oe ? phy_mdio_o : 1'bz;
    // TXC is a register of the network unit's clock (rtl/net/eth_top.v), so no ODDR is needed here.

    wire [31:0] build_id;
    tr_build_id u_build (.id(build_id));

    // ---- USB audio begin: the two bidirectional pads. dp_o, dn_o and oe are registers of the 48 MHz clock, so the
    // tristate control comes straight from flip-flops.
    wire usb_dp_o, usb_dn_o, usb_oe;
    assign usb_dp = usb_oe ? usb_dp_o : 1'bz;
    assign usb_dn = usb_oe ? usb_dn_o : 1'bz;
    // ---- USB audio end
    // ---- USB host begin: four bidirectional pads, driven the same way
    wire [1:0] usbh_a_o, usbh_b_o, usbh_oe;
    assign usbh_a[0] = usbh_oe[0] ? usbh_a_o[0] : 1'bz;
    assign usbh_b[0] = usbh_oe[0] ? usbh_b_o[0] : 1'bz;
    assign usbh_a[1] = usbh_oe[1] ? usbh_a_o[1] : 1'bz;
    assign usbh_b[1] = usbh_oe[1] ? usbh_b_o[1] : 1'bz;
    // ---- USB host end

    wire clk_eth;                            // from the core's Ethernet PLL; the name is the one sdr.cst puts on a clock line
    sdr_core u_core (
        .clk_eth(clk_eth), .clk_dsp(clk_dsp), .rst_dsp(rst_dsp), .rst_rx(rst_rx),
        .clk_50m(clk_50m), .clk_pix(clk_pix),
        .hclk(exts_hclk), .hresetn(exts_hrstn), .hsel(exts_hsel), .haddr(exts_haddr),
        .htrans(exts_htrans), .hwrite(exts_hwrite), .hsize(exts_hsize), .hwdata(exts_hwdata),
        .hreadyout(exts_hreadyout), .hrdata(exts_hrdata), .hresp(exts_hresp), .ext_int(ext_int),
        .addr_lane4(addr_lane4), .wr_mask_lane4(wr_mask8_lane4), .wr_data_lane4(wr_data_lane4),
        .wr_en_lane4(wr_en_lane4), .wr_go_lane4(wr_go_lane4), .burstcount_lane4(burstcount_lane4),
        .wr_wait_lane4(wr_wait_lane4), .wr_done_lane4(wr_done_lane4),
        .addr_lane5(addr_lane5), .rd_en_lane5(rd_en_lane5), .rd_go_lane5(rd_go_lane5),
        .burstcount_lane5(burstcount_lane5), .rd_valid_lane5(rd_valid_lane5),
        .rd_data_lane5(rd_data_lane5), .rd_rdy_lane5(rd_rdy_lane5),
        .rgmii_rxc(rgmii_rxc), .rgmii_rxd(rgmii_rxd), .rgmii_rx_ctl(rgmii_rx_ctl),
        .rgmii_txc(rgmii_txc), .rgmii_txd(rgmii_txd), .rgmii_tx_ctl(rgmii_tx_ctl), .phy_clk(phy_clk),
        .phy_rst_n(phy_rst_n), .phy_mdc(phy_mdc), .phy_mdio_o(phy_mdio_o),
        .phy_mdio_oe(phy_mdio_oe), .phy_mdio_i(phy_mdio),
        .pt8211_bck(hp_bck), .pt8211_ws(hp_ws), .pt8211_din(hp_din),
        // ---- audio outputs begin
        .clk_aud(clk_aud), .aud_lock(aud_lock),
        .spdif_out(spdif_out), .i2s_bck(i2s_bck), .i2s_ws(i2s_ws), .i2s_sd(i2s_sd), .i2s_mclk(i2s_mclk),
        .aud48_valid(aud48_valid), .aud48_l(aud48_l), .aud48_r(aud48_r),
        // ---- audio outputs end
        // ---- USB audio begin
        .clk_usb(clk_48m), .usb_dp_i(usb_dp), .usb_dn_i(usb_dn),
        .usb_dp_o(usb_dp_o), .usb_dn_o(usb_dn_o), .usb_oe(usb_oe), .usb_pullup(usb_pullup),
        // ---- USB audio end
        // ---- USB host begin
        .usbh_a_i(usbh_a), .usbh_b_i(usbh_b), .usbh_a_o(usbh_a_o), .usbh_b_o(usbh_b_o), .usbh_oe(usbh_oe),
        // ---- USB host end
        .sfp_txc(sfp_txc), .n1_rxc(n1_rxc), .bl_txc(`TR_BL_TXC), .bl_rxc(bl_rxc),
        .ln0_tx(ln0_tx), .ln0_rx(ln0_rx), .ln0_rx_vld(ln0_rx_vld),
        .ln1_tx(ln1_tx), .ln1_rx(ln1_rx), .ln1_rx_vld(ln1_rx_vld),
        .serdes_por_n(serdes_por_n), .ln_rst_n(ln_rst_n), .ln_rx_rst(ln_rx_rst), .ln_tx_rst(ln_tx_rst),
        .ln0_fix(ln0_fix), .ln1_fix(ln1_fix), .ln0_stat(ln0_stat), .ln1_stat(ln1_stat), .sfp_diag(sfp_diag),
        .sfp_tx_disable(sfp_tx_disable), .sfp_los(sfp_los),
        .twi_scl_o(twi_scl_o), .twi_sda_o(twi_sda_o), .twi_scl_i(twi_scl), .twi_sda_i(twi_sda),
        .twi_sel(twi_sel),
        .vid_cx(vid_cx), .vid_cy(vid_cy), .vid_rgb(vid_rgb),
        .build_id(build_id), .ddr3_init(ddr3_init), .plls_locked(plls_locked),
        .led_rx_streaming(led_stream)
    );

    // =========================================================================== SFP+ transceiver
    // (docs/SFP_LINKS.md section 2; rtl/sfp/sfp_serdes.v.) Lane clocks, all 125 MHz: sfp_txc (transmit, both lanes),
    // n1_rxc and bl_rxc (recovered from the received data of lane 0 and lane 1). bl_txc is sfp_txc unless
    // TR_SFP_TXC_OWN is defined. The module's two-wire I2C pins are open drain: the core gives only "release"
    // (1) or "pull low" (0), so a 1 turns into high impedance and a 0 into a hard low.
    assign twi_scl = twi_scl_o ? 1'bz : 1'b0;
    assign twi_sda = twi_sda_o ? 1'bz : 1'b0;
    sfp_serdes u_serdes (
        .por_n(serdes_por_n), .ln_rst_n(ln_rst_n), .ln_rx_rst(ln_rx_rst), .ln_tx_rst(ln_tx_rst),
        .ln0_fix(ln0_fix), .ln1_fix(ln1_fix),
        .sfp_txc(sfp_txc), .n1_rxc(n1_rxc), .bl_txc(`TR_BL_TXC), .ln1_txc(ln1_txc), .bl_rxc(bl_rxc),
        .ln0_tx(ln0_tx), .ln0_rx(ln0_rx), .ln0_rx_vld(ln0_rx_vld),
        .ln1_tx(ln1_tx), .ln1_rx(ln1_rx), .ln1_rx_vld(ln1_rx_vld),
        .ln0_stat(ln0_stat), .ln1_stat(ln1_stat), .diag(sfp_diag)
    );

    // LEDs (active low on the dock): LED 0 = DDR3 initialized, LED 1 = HL2 samples arriving
    assign led = ~{led_stream, ddr3_init};
    // ---- DDR3 begin: the 256 MB build ties the unused 15th row address line low
`ifdef TR_DDR_256
    assign DDR3_A14 = 1'b0;
`endif
    // ---- DDR3 end

endmodule
