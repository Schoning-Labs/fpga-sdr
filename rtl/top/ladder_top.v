// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// ladder_top: the top level of the bring-up ladder, a small test design for the first power-on of a board.
//
// WHAT IT IS AND WHY IT EXISTS
// The full radio (sdr_top.v) has a great many parts, and when a new board shows nothing at all it is hard to say which
// one is at fault. The ladder is the same board brought up in three small steps, built from this one source three times, so
// that the first step that fails names the faulty part. It is a test design and not part of the radio: it carries no receiver,
// no network and no FFT. What it does carry is exactly the path the radio's firmware depends on, namely the PLLs, the
// AE350 CPU with its DDR3 memory, the register bus between the CPU and the FPGA fabric (rtl/top/ladder_regs.v), the debug
// serial port, the LEDs, and, in the later steps, the HDMI output and the audio DAC. A small program (fw/tr-ladder) runs on the
// CPU, reads the register page, checks the memory and prints a report on the serial port (docs/LADDER.md).
// The build script (gowin/ladder/build.sh) writes a first file that defines LADDER_STEP, and, from step 2 on, LADDER_VIDEO and
// from step 3 on LADDER_AUDIO, which switch the parts below on:
//   1  the four PLLs, the AE350 with the 1 GB DDR3 (rtl/mem/ddr_mem.v and Gowin's DDR3 IP; the AE350 is held in
//      reset until the DDR3 controller reports ready), the debug serial port, the LEDs, a register page
//      (rtl/top/ladder_regs.v) and counters of every clock against the 50 MHz oscillator. No video, no audio.
//   2  step 1 plus HDMI colour bars (rtl/top/ladder_bars.v). The DDR3 tests are the program's (fw/tr-ladder:
//      size probe, address lines, patterns through the processor's data memory bus).
//   3  step 2 plus a 1 kHz tone on the PT8211 DAC (rtl/top/ladder_pt8211.v).
// The structure of the top (the AE350 and DDR3 instances, resets, key debounce, LEDs) follows an earlier design by
// the same author and rtl/top/sdr_top.v (pins, PLLs, the two memory lanes of the
// logic tied off). sdr_top.v and sdr.cst/.sdc are not used here: the pins are in gowin/ladder/ladder.cst and the
// timing constraints in gowin/ladder/ladder.sdc.
//
// LEDS
// They are active low on the board (dock schematic: +3V3, 3.3 kohm, LED, FPGA pin), so the pin is the inverse of the
// logical value below:
//   LED 0 blinks from a plain counter on the 50 MHz oscillator (no PLL, no processor): the board is configured
//   LED 1 DDR3 PLL locked   LED 2 DSP PLL locked   LED 3 video PLL locked
//   LED 4 DDR3 controller ready (initialized and calibrated; the processor starts after this)
//   LED 5 toggled by the program once per printed report ("the processor lives")
// For a beginner: the PLL, AE350, DDR3, AHB and clock domain crossing terms are explained in docs/learn/GLOSSARY.md.

`timescale 1ns / 1ps

module ladder_top (
    input  wire        clk_50m,          // P16, the 50 MHz oscillator on the SOM: the source of every clock
    input  wire        key_rst_n,        // G16, USR_KEY.3: low = reset

    output wire        uart_txd,         // P15 -> BL616 RX, the debug serial port to the PC (UART2 of the AE350)
    input  wire        uart_rxd,         // N16 <- BL616 TX

    // AE350 instruction flash (a SPI NOR chip behind the AE350's own flash controller; the CPU runs the program from it)
    inout  wire        FLASH_SPI_CSN,
    inout  wire        FLASH_SPI_MISO,
    inout  wire        FLASH_SPI_MOSI,
    inout  wire        FLASH_SPI_CLK,
    inout  wire        FLASH_SPI_HOLDN,
    inout  wire        FLASH_SPI_WPN,

    // AE350 JTAG debug port
    input  wire        TCK_IN,
    input  wire        TMS_IN,
    input  wire        TRST_IN,
    input  wire        TDI_IN,
    output wire        TDO_OUT,

    // DDR3 memory: two x16 chips share address and control and give 32 data lines and a 15-bit row address (1 GB)
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
    output wire [14:0] DDR3_ADDR,
    output wire [3:0]  DDR3_DM,
    inout  wire [31:0] DDR3_DQ,
    inout  wire [3:0]  DDR3_DQS,
    inout  wire [3:0]  DDR3_DQS_N,

    // HDMI TMDS pairs: three data lanes and the clock lane, each driven pseudo-differentially (positive and negative pad)
    output wire [2:0]  tmds_p,
    output wire [2:0]  tmds_n,
    output wire        tmds_clk_p,
    output wire        tmds_clk_n,

    output wire        hp_bck,           // E22, PT8211 bit clock
    output wire        hp_ws,            // F24, PT8211 word select (left/right)
    output wire        hp_din,           // G24, PT8211 serial data

    // the six LEDs, active low (see the header)
    output wire [5:0]  led
);
    // the build step, 1 to 3, from the define written by the build script; the program reads it back from the register page
    localparam integer STEP = `LADDER_STEP;

    // =========================================================================== PLLs (gowin/p1/ip/*.mod)
    // Four PLLs make every clock from the 50 MHz oscillator (the same settings as the full radio):
    //   AE350 PLL: VCO 800 MHz, CORE_CLK 800 MHz for the CPU, AHB_CLK and APB_CLK 80 MHz for the buses, DDR_CLK 50 MHz for the
    //   CPU's data-memory bus and RTC_CLK 10 MHz for the real-time counter (the enclk inputs tied to 1 keep every output on)
    //   DDR3 PLL: VCO 1,200 MHz, ddr3_clk_in 50 MHz (initialization logic) and ddr3_memory_clk 300 MHz (the memory clock),
    //   whose enable comes from the DDR3 controller (ddr3_stop)
    //   DSP PLL: VCO 1,200 MHz, clk_dsp 120 MHz
    //   video PLL: VCO 1,112.5 MHz, clk_pix5 370.83 MHz (bit clock of the HDMI serializers) and clk_pix 74.17 MHz (pixel clock)
    wire core_clk, ahb_clk, apb_clk, ddr_clk, rtc_clk;
    Gowin_PLL_AE350 u_pll_ae350 (
        .clkin(clk_50m),
        .clkout0(ddr_clk), .clkout1(core_clk), .clkout2(ahb_clk), .clkout3(apb_clk), .clkout4(rtc_clk),
        .enclk0(1'b1), .enclk1(1'b1), .enclk2(1'b1), .enclk3(1'b1), .enclk4(1'b1)
    );

    wire ddr3_clk_in, ddr3_memory_clk, ddr3_lock, ddr3_stop;
    Gowin_PLL_DDR3 u_pll_ddr3 (
        .clkin(clk_50m), .reset(1'b0), .lock(ddr3_lock),
        .clkout0(ddr3_clk_in), .clkout2(ddr3_memory_clk),
        .enclk0(1'b1), .enclk2(ddr3_stop)
    );

    wire clk_dsp, dsp_lock;
    Gowin_PLL_DSP u_pll_dsp (
        .clkin(clk_50m), .reset(1'b0), .lock(dsp_lock), .clkout0(clk_dsp), .enclk0(1'b1)
    );

    wire clk_pix5, clk_pix, video_lock;
    Gowin_PLL_VIDEO u_pll_video (
        .clkin(clk_50m), .reset(1'b0), .lock(video_lock),
        .clkout0(clk_pix5), .clkout1(clk_pix),
        .enclk0(1'b1), .enclk1(1'b1)
    );

    // The reset is held until all three PLLs that report lock have locked (the AE350 PLL has no lock output).
    wire plls_locked = ddr3_lock & dsp_lock & video_lock;

    // =========================================================================== resets
    // key: three-register synchronizer and a 2^20-clock (21 ms) debounce in the 50 MHz domain (as in sdr_top.v).
    // key_cnt counts while the synchronized key level differs from the accepted one (key_ok) and is cleared when they agree,
    // so key_ok only follows the key after it has stayed changed for 2^20 clocks. After power-up key_ok is 0 (reset on)
    // and becomes 1 when the key has been released and stable for 21 ms.
    reg [2:0]  key_s = 3'b111;
    reg [19:0] key_cnt = 20'd0;
    reg        key_ok = 1'b0;          // 1 = key released and stable
    always @(posedge clk_50m) begin
        key_s <= {key_s[1:0], key_rst_n};
        if (key_s[2] == key_ok) key_cnt <= 20'd0;
        else if (&key_cnt)       key_ok  <= key_s[2];
        else                     key_cnt <= key_cnt + 1'b1;
    end
    // global reset request, active low: key accepted and every PLL locked
    wire sys_rst_n = key_ok & plls_locked;

    // Reset for clk_dsp: asserted at once when sys_rst_n falls, released four clk_dsp clocks after it rises (the usual
    // asynchronous-assert, synchronous-release shift register), so the blocks leave reset together on a clean clock edge.
    reg [3:0] rst_dsp_s = 4'hF;
    always @(posedge clk_dsp or negedge sys_rst_n)
        if (!sys_rst_n) rst_dsp_s <= 4'hF; else rst_dsp_s <= {rst_dsp_s[2:0], 1'b0};
    wire rst_dsp = rst_dsp_s[3];

    // the same reset shift register for clk_pix
    reg [3:0] rst_pix_s = 4'hF;
    always @(posedge clk_pix or negedge sys_rst_n)
        if (!sys_rst_n) rst_pix_s <= 4'hF; else rst_pix_s <= {rst_pix_s[2:0], 1'b0};
    wire rst_pix = rst_pix_s[3];

    // The DDR3 controller starts first and the AE350 is held in reset until it reports initialization and calibration
    // done, so a memory that does not come up shows as a dark LED 4 and a silent serial port, and not as a program
    // that hangs (docs/TANG_LESSONS.md section 9).
    // ddr3_init: from the DDR3 controller, 1 = initialized and calibrated
    wire ddr3_init;
    // the DDR3 controller is released once the key is accepted and the DDR3 PLL is locked
    wire ddr3_rstn = key_ok & ddr3_lock;
    // the AE350 reset release is synchronized into the 50 MHz domain through three registers
    reg [2:0] ae_s = 3'b000;
    always @(posedge clk_50m) ae_s <= {ae_s[1:0], key_ok & plls_locked & ddr3_init};
    wire ae350_rstn = ae_s[2];

    // =========================================================================== AE350 and DDR3
    // The AE350 is the RISC-V CPU subsystem that is built into the chip. It has two ports into the fabric used here: the
    // Extended AHB Slave port (exts_*), through which the CPU reads and writes the register page in ladder_regs.v at
    // 0xE800_0000, and its data-memory bus (dm_*, 64 bits wide), which the DDR3 bridge below connects to the DDR3 memory.
    // the Extended AHB Slave port (CPU to fabric registers); exts_hclk is the 80 MHz AHB clock
    wire        exts_hclk, exts_hrstn, exts_hsel, exts_hwrite, exts_hreadyout, exts_hresp;
    wire [31:0] exts_haddr, exts_hwdata, exts_hrdata;
    wire [1:0]  exts_htrans;
    wire [2:0]  exts_hburst, exts_hsize;
    wire [3:0]  exts_hprot;

    // the CPU's data-memory bus (64 bits), connected to DDR3 through ddr_mem
    wire [63:0] dm_hrdata, dm_hwdata;
    wire [31:0] dm_haddr;
    wire        dm_hready, dm_hresp, dm_hwrite, dm_hrstn;
    wire [2:0]  dm_hburst, dm_hsize;
    wire [3:0]  dm_hprot;
    wire [1:0]  dm_htrans;

    // The CPU subsystem. EXT_INT is tied to 0 because the ladder program polls the register page and takes no fabric interrupts,
    // the modem lines of UART2 are tied to their inactive levels, and POR_RSTN and HW_RSTN both come from ae350_rstn.
    RiscV_AE350_SOC_Top u_ae350 (
        .FLASH_SPI_CSN(FLASH_SPI_CSN), .FLASH_SPI_MISO(FLASH_SPI_MISO),
        .FLASH_SPI_MOSI(FLASH_SPI_MOSI), .FLASH_SPI_CLK(FLASH_SPI_CLK),
        .FLASH_SPI_HOLDN(FLASH_SPI_HOLDN), .FLASH_SPI_WPN(FLASH_SPI_WPN),

        .DDR_HRDATA(dm_hrdata), .DDR_HREADY(dm_hready), .DDR_HRESP(dm_hresp), .DDR_HADDR(dm_haddr),
        .DDR_HBURST(dm_hburst), .DDR_HPROT(dm_hprot), .DDR_HSIZE(dm_hsize), .DDR_HTRANS(dm_htrans),
        .DDR_HWDATA(dm_hwdata), .DDR_HWRITE(dm_hwrite), .DDR_HCLK(), .DDR_HRSTN(dm_hrstn),

        .TCK_IN(TCK_IN), .TMS_IN(TMS_IN), .TRST_IN(TRST_IN), .TDI_IN(TDI_IN),
        .TDO_OUT(TDO_OUT), .TDO_OE(),

        .EXT_INT(16'd0),

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

    // The DDR3 IP and the bridge from the AE350's data-memory bus to it (docs/MEM_1GB.md). The two lanes of the logic (lane 4
    // for writes, lane 5 for reads) are not used in the ladder: no request, their outputs are left open.
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
        .addr_lane4(32'd0), .wr_mask_lane4(8'd0), .wr_data_lane4(64'd0), .wr_en_lane4(1'b0),
        .burstcount_lane4(8'd0), .wr_wait_lane4(), .wr_done_lane4(),
        .addr_lane5(32'd0), .rd_en_lane5(1'b0), .burstcount_lane5(8'd0),
        .rd_valid_lane5(), .rd_data_lane5(), .rd_rdy_lane5()
    );

    // =========================================================================== counters and the register page
    // milliseconds of the oscillator: a time base independent of every PLL
    // ms_div counts 0 to 49,999 (50,000 clocks of 20 ns = 1 ms) and ms_tick is high for one clock after the last count;
    // hb50 is a free-running 26-bit counter whose top bit blinks LED 0 (period 2^26 clocks = 1.34 s).
    reg [15:0] ms_div = 16'd0;
    reg        ms_tick = 1'b0;
    reg [25:0] hb50 = 26'd0;
    always @(posedge clk_50m) begin
        hb50 <= hb50 + 26'd1;
        ms_tick <= (ms_div == 16'd49_999);
        ms_div <= (ms_div == 16'd49_999) ? 16'd0 : ms_div + 16'd1;
    end
    // The counters below let the program measure every clock against the millisecond time base. Each ladder_cnt_x counts
    // pulses in the clock under test and is read in the AHB clock. A pulse comes once per 2^17 clocks (2^12 for the 10 MHz
    // RTC clock), so a 16-bit counter wraps after seconds and the program takes the difference of two reads.
    // aud_cnt counts PT8211 frames (step 3) and vframes counts video frames (steps 2 and 3).
    wire [15:0] ms_cnt, aud_cnt, dsp_cnt, pix_cnt, ahb_cnt, ddr_cnt, rtc_cnt, vframes;
    ladder_cnt_x u_c_ms (.clk_s(clk_50m), .inc(ms_tick), .clk_d(exts_hclk), .q_d(ms_cnt));

    // free-running dividers, one per clock under test; all ones (&div) is high for one clock in every 2^17 (2^12) clocks
    // and counts as one pulse: at 120 MHz that is 915.5 pulses a second for clk_dsp, 565.9 for clk_pix (74.17 MHz), 610.4
    // for the AHB clock (80 MHz), 381.5 for the 50 MHz DDR bus clock and 2,441 for the RTC clock (10 MHz)
    reg [16:0] dsp_div = 17'd0, pix_div = 17'd0, ahb_div = 17'd0, ddr_div = 17'd0;
    reg [11:0] rtc_div = 12'd0;
    always @(posedge clk_dsp) dsp_div <= dsp_div + 17'd1;
    always @(posedge clk_pix) pix_div <= pix_div + 17'd1;
    always @(posedge exts_hclk) ahb_div <= ahb_div + 17'd1;
    always @(posedge ddr_clk) ddr_div <= ddr_div + 17'd1;
    always @(posedge rtc_clk) rtc_div <= rtc_div + 12'd1;
    ladder_cnt_x u_c_dsp (.clk_s(clk_dsp), .inc(&dsp_div), .clk_d(exts_hclk), .q_d(dsp_cnt));
    ladder_cnt_x u_c_pix (.clk_s(clk_pix), .inc(&pix_div), .clk_d(exts_hclk), .q_d(pix_cnt));
    ladder_cnt_x u_c_ahb (.clk_s(exts_hclk), .inc(&ahb_div), .clk_d(exts_hclk), .q_d(ahb_cnt));
    ladder_cnt_x u_c_ddr (.clk_s(ddr_clk), .inc(&ddr_div), .clk_d(exts_hclk), .q_d(ddr_cnt));
    ladder_cnt_x u_c_rtc (.clk_s(rtc_clk), .inc(&rtc_div), .clk_d(exts_hclk), .q_d(rtc_cnt));

    // the build identifier read by the program: the first 8 hex digits of the commit (module written by the build script)
    wire [31:0] build_id;
    tr_build_id u_build (.id(build_id));

    // led_r = the LED word the program writes; the register page itself is described in ladder_regs.v
    wire [5:0] led_r;
    ladder_regs #(.STEP(STEP)) u_regs (
        .hclk(exts_hclk), .hresetn(exts_hrstn), .hsel(exts_hsel), .haddr(exts_haddr), .htrans(exts_htrans),
        .hwrite(exts_hwrite), .hwdata(exts_hwdata), .hreadyout(exts_hreadyout), .hresp(exts_hresp),
        .hrdata(exts_hrdata), .build_id(build_id),
        .ddr3_init(ddr3_init), .dsp_lock(dsp_lock), .vid_lock(video_lock), .ddr3_lock(ddr3_lock),
        .ms_cnt(ms_cnt), .aud_cnt(aud_cnt), .dsp_cnt(dsp_cnt), .pix_cnt(pix_cnt), .ahb_cnt(ahb_cnt),
        .ddr_cnt(ddr_cnt), .rtc_cnt(rtc_cnt), .vframes(vframes), .led_r(led_r));

    // =========================================================================== HDMI colour bars (step 2 and 3)
    wire [2:0] tmds;
    wire       tmds_clock;
    // Step 2 and 3: the colour bar generator and HDMI core. frame is one pulse per picture, counted in vframes.
`ifdef LADDER_VIDEO
    wire frame;
    ladder_bars u_bars (
        .clk_pixel(clk_pix), .clk_pixel_x5(clk_pix5), .reset(rst_pix),
        .tmds(tmds), .tmds_clock(tmds_clock), .frame(frame));
    ladder_cnt_x u_c_vf (.clk_s(clk_pix), .inc(frame), .clk_d(exts_hclk), .q_d(vframes));
    // Step 1: no video, the lanes stay low
`else
    assign tmds = 3'b000;
    assign tmds_clock = 1'b0;
    assign vframes = 16'd0;
`endif
    // ELVDS_OBUF is Gowin's emulated LVDS output buffer: it drives a pad and its inverted twin from one signal, which is how the
    // three data lanes and the clock lane reach the HDMI connector on pins that have no true LVDS driver.
    genvar gt;
    generate for (gt = 0; gt < 3; gt = gt + 1) begin : g_tmds
        ELVDS_OBUF u_obuf (.I(tmds[gt]), .O(tmds_p[gt]), .OB(tmds_n[gt]));
    end endgenerate
    ELVDS_OBUF u_obuf_clk (.I(tmds_clock), .O(tmds_clk_p), .OB(tmds_clk_n));

    // =========================================================================== audio tone (step 3)
    // Step 3: the 1 kHz tone generator on clk_dsp; frame_tick is one pulse per 48 kHz frame, counted in aud_cnt.
`ifdef LADDER_AUDIO
    wire frame_tick;
    ladder_pt8211 u_tone (.clk(clk_dsp), .rst(rst_dsp), .bck(hp_bck), .ws(hp_ws), .din(hp_din),
                          .frame_tick(frame_tick));
    ladder_cnt_x u_c_aud (.clk_s(clk_dsp), .inc(frame_tick), .clk_d(exts_hclk), .q_d(aud_cnt));
    // Steps 1 and 2: the DAC pins stay low
`else
    assign hp_bck = 1'b0;
    assign hp_ws  = 1'b0;
    assign hp_din = 1'b0;
    assign aud_cnt = 16'd0;
`endif

    // =========================================================================== LEDs (active low)
    // lk1 and lk2 pass the status levels into the 50 MHz domain through two registers: bit 3 DDR3 initialized, bit 2 video PLL
    // lock, bit 1 DSP PLL lock, bit 0 DDR3 PLL lock. ledp holds the program's LED word (clocked by the AHB clock) and led5_s1
    // and led5_s2 bring its bit 5 into the 50 MHz domain.
    reg [3:0] lk1 = 4'd0, lk2 = 4'd0;
    always @(posedge clk_50m) begin lk1 <= {ddr3_init, video_lock, dsp_lock, ddr3_lock}; lk2 <= lk1; end
    reg [5:0] ledp = 6'd0;
    always @(posedge exts_hclk) ledp <= led_r;
    reg led5_s1 = 1'b0, led5_s2 = 1'b0;
    always @(posedge clk_50m) begin led5_s1 <= ledp[5]; led5_s2 <= led5_s1; end
    // led[5] = program's toggle, led[4] = DDR3 ready, led[3] = video PLL, led[2] = DSP PLL, led[1] = DDR3 PLL, led[0] = blink,
    // all inverted because the LEDs light when the pin is low
    assign led = ~{led5_s2, lk2[3], lk2[2], lk2[1], lk2[0], hb50[25]};
endmodule
