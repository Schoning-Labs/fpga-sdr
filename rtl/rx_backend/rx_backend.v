// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// rx_backend: the receiver back end, top level. It takes the receiver bank's shared I/Q stream
// (NRX receivers, 1 to 8: 8 here by default and 4 in the chip with the zoom receiver; 48 to
// 384 ksps each) and turns every receiver into 12 or 24 ksps audio (or I/Q) in clk_dsp, with
// no CPU work per sample: noise blanker, decimation to 24 ksps, a complex channel filter of up
// to 1,024 taps, the demodulator, the AGC, the S-meter and the squelch. The specification is
// docs/R4_BACKEND.md and the architecture overview is section 3.10 of docs/ARCHITECTURE.md.
// The terms used here are explained in docs/learn/GLOSSARY.md.
//
//   bank stream -> bk_front (scale, noise blanker) -> FIFO -> bk_decim (half-bands to 24 ksps)
//     -> FIFO per unit -> bk_chfilt x 2 (1,024-tap complex filter, receivers 0-3 / 4-7)
//     -> FIFO per unit -> bk_post (CORDIC, demodulator, AGC, S-meter, squelch, HB5) -> output
//
// Every stage is one engine that serves all receivers in turn, which is why one receiver
// costs so little logic: the engines do their arithmetic as a short chain of states, one job
// per sample, and the FIFOs between them absorb the bursts (receivers that are enabled together
// deliver their samples in the same few clocks). The data between the stages carries the
// receiver number, an epoch bit (which flips every time a receiver is enabled, so that samples
// of an old run are dropped when it is switched off and on again) and a flag for the first
// sample after enable (which makes every stage start that receiver from a clean state).
//
// Registers: hw/regmap/rx_backend.toml via the generated hw/regmap/generated/rx_backend_regs.vh;
// a plain synchronous register port in this clock domain (the AHB bridge and its clock
// crossing sit outside). The register read and write paths are two-clock (multicycle) paths,
// constrained by rtl/rx_backend/rx_backend.sdc; see "register bus" below for what the RTL does
// to make that constraint true, and for the bus contract it needs (at least two clocks between
// two writes, and between two reads). Read data is valid six clocks after reg_rd; a write lands
// five clocks after reg_wr is sampled. Per receiver the register page has a 128-byte slot
// (control word, noise blanker, AGC, loops, squelch, status, stamp base and ring setup), then
// a few global registers (status, interrupt, coefficient window selection) and the bank table.
// The channel filter coefficients are written through a window of 1,024 taps x {re, im}.
//
// Output: one sample per out_valid with its receiver, 16-bit audio (or I and Q) and the HL2
// sample index of the bank sample that completed it (docs/R4_BACKEND.md section 3.8), for the
// audio mixer; the same samples go to each receiver's DDR3 ring (bk_ring.v) through the ring_*
// write-lane client port, and an interrupt is raised for each finished block of a ring that the
// firmware has subscribed to.
//
// Stamps: a receiver's samples are time stamped in HL2 time. When the receiver's first bank
// sample arrives the module captures the HL2 index of that moment, and from then on every
// output sample gets the previous stamp plus one output period (6,400 ADC samples at 12 ksps,
// 3,200 at 24 ksps), so differences between stamps are exact.

`timescale 1ns / 1ps
`include "hw/regmap/generated/rx_backend_regs.vh"

module rx_backend #(
    parameter HB_FILE   = "rtl/rx_backend/bk_hb.hex",
    parameter LOG2_FILE = "rtl/rx_backend/bk_log2.hex",
    parameter EXP2_FILE = "rtl/rx_backend/bk_exp2.hex",
    // Receivers built, 1 to 8. The register map keeps the 8-receiver layout:
    // receivers at or above NRX read 0 and ignore writes. Everything that grows with the receiver count
    // (settings, stamps, rings, the decimator's and the post engine's delay lines, the channel-filter
    // units: 4 receivers each, so a second unit only for NRX > 4) is sized by it.
    parameter integer NRX = 8
) (
    input  wire         clk,        // clk_dsp
    input  wire         rst,        // synchronous reset

    // receiver bank output stream (rtl/rx/rx_bank.v)
    input  wire         in_valid,   // one-clock pulse: a new sample of receiver in_index
    input  wire [2:0]   in_index,   // receiver number
    input  wire [23:0]  in_i,       // I, two's complement
    input  wire [23:0]  in_q,       // Q

    // HL2 index of the most recent ADC sample (HL2 link, ARCHITECTURE 3.1)
    input  wire [47:0]  hl2_index,  // count of ADC samples since the HL2 stream began, the HL2's own time

    // register port (byte address within the 64 KB page)
    input  wire         reg_wr,     // write strobe (at least two clocks between two writes)
    input  wire         reg_rd,     // read strobe (at least two clocks between two reads)
    input  wire [15:0]  reg_addr,   // byte address
    input  wire [31:0]  reg_wdata,  // write data
    output reg  [31:0]  reg_rdata,  // read data, valid five clocks after reg_rd is sampled

    // output stream
    output reg          out_valid,  // one-clock pulse: a finished output sample
    output reg  [2:0]   out_rx,     // its receiver
    output reg  [15:0]  out_s0,     // audio, or I in IQ mode
    output reg  [15:0]  out_s1,     // Q in IQ mode, otherwise 0
    output reg          out_iq,     // the receiver is in IQ mode
    output reg  [47:0]  out_stamp,  // HL2 sample index of the bank sample that completed this sample

    // output rings: DDR3 write-lane client (rtl/ddr3/ddr3_write_arbiter.v convention)
    output wire         ring_req,   // request a write
    output wire [31:0]  ring_addr,  // lane word address
    output wire [7:0]   ring_burstlen,   // words in the burst
    output wire [63:0]  ring_wdata,
    output wire [7:0]   ring_wmask,
    input  wire         ring_gnt,
    input  wire         ring_done,  // the write is done

    // interrupt line 10: a subscribed receiver's ring received a block
    output wire         irq
);
    integer r3;
    localparam integer NU = (NRX + 3) / 4;       // channel-filter units

    // ================================================================ register bus
    // CPU register accesses are rare, so the register read and write paths are timed as two-clock
    // (multicycle) paths by rtl/rx_backend/rx_backend.sdc instead of being cut into more
    // pipeline stages:
    //     set_multicycle_path -from [get_regs {*rbmc_*}] -setup -end 2   (hold -start 1)
    // i.e. every path that starts at a register named rbmc_* may take two clocks. The RTL below
    // makes that true; keep these rules when changing anything here:
    //   1. A register named rbmc_* only loads on an access (the latched write address and data,
    //      the latched read address, the read fields), so it then holds its value until the next
    //      access of the same kind, at least two clocks later (bus contract below).
    //   2. Every register an rbmc_* path ends on only loads when a plain flag is high (w_go2 for
    //      the write decode, wr_en2 and w_go for the commit, r_go2 and r_go4 for the reads), and
    //      that flag is timed as a normal one-clock path. The flag is high only on clocks two or
    //      more clocks after the rbmc_* registers it goes with were loaded, and low in between,
    //      so a value still settling is never captured.
    //   3. Values that change on their own (the engines' S-meter, gain, blanked count, ring
    //      pointers and bank in use; the settings the CPU writes; the stamps and counters) are
    //      only read through a one-clock path into the rbmc_f_* read fields; the two-clock paths
    //      are only the ones that start at rbmc_* (the receiver select into rbmc_f_*, and
    //      rbmc_f_* into reg_rdata).
    // Bus contract: at least two clocks between two reg_wr strobes, and at least two clocks
    // between two reg_rd strobes (the AHB bridge's clock crossing gives more; a write and a read
    // may be as close as the same clock). A simulation check at the end of this file reports a
    // violation. A write lands five clocks after reg_wr is sampled; read data is valid in
    // reg_rdata five clocks after reg_rd is sampled: the testbenches' rd() tasks wait six clocks
    // after raising reg_rd.
    reg         reg_wr_r, reg_rd_r;
    reg  [15:0] reg_addr_r;
    reg  [31:0] reg_wdata_r;
    always @(posedge clk) begin
        if (rst) begin
            reg_wr_r <= 1'b0;
            reg_rd_r <= 1'b0;
        end else begin
            reg_wr_r <= reg_wr;
            reg_rd_r <= reg_rd;
        end
        reg_addr_r  <= reg_addr;
        reg_wdata_r <= reg_wdata;
    end

    // write: address and data latched on the access (rule 1), committed two clocks later by
    // w_go (rule 2), in copies: 0-7 the receivers' settings, 8 the global registers, 9 the
    // bank table, 10-11 the two channel-filter units' coefficient memories
    // Decoding: decoded from rbmc_wa in one clock, one decode net had a
    // fan-out of 1,268 and missed even two clocks; decoded from reg_addr_r as it is latched, the
    // 134 flags missed one clock by 2.3 ns. So the decode is a two-clock path of its own: w_go2,
    // two clocks after rbmc_wa/rbmc_wd were loaded, loads the decode into wr_en1 (one flag per
    // register) and copies the address and data into rbmc_wa2/rbmc_wd2, which hold them for the
    // commit; wr_en2 = wr_en1 if w_go3, else 0 (a one-clock path), and each register loads from
    // rbmc_wd2 on its own wr_en2 flag the clock after that (a one-clock path from a register
    // straight to its load enable; rbmc_wd2 to the register is two clocks). wr_en1/wr_en2:
    // [16 r + j] for receiver r and its j-th writable register (slots 0-12, 20, 21, 22 of the
    // register map, in that order); [128 + g] the global registers (status, irq_status,
    // irq_enable, coef_sel); [132] "a bank_cfg register"; [133] "the coefficient window".
    (* syn_preserve = 1 *) reg [15:0] rbmc_wa, rbmc_wa2;
    (* syn_preserve = 1 *) reg [31:0] rbmc_wd, rbmc_wd2;
    reg [133:0]                       wr_en1, wr_en2;
    // The settings that are memories (slots 1-13 below) are written through one flag per slot
    // for all receivers, in a copy for the engines' memories and one for the read-back memories, and the
    // bank table through bk_we (a copy per memory); the receiver is the memory's write address (cw_a)
    reg [15:0]                        ws_en1;
    reg [15:0] ws_en2  /* synthesis syn_preserve = 1 */;
    reg [15:0] ws_en2c /* synthesis syn_preserve = 1 */;
    reg [2:0]  bk_we   /* synthesis syn_preserve = 1 */;
    wire [3:0] cw_a = {1'b0, rbmc_wa2[9:7] - 3'd2};
    // While the reset is held every word is written with its reset value, one word in four clocks through
    // the same latched address and data (rbmc_wa2, rbmc_wd2: loaded in phase 0, the flag in phase 3, so the
    // two-clock rule holds): 128 words of settings, then 16 of the bank table, 576 clocks. The memories
    // also start with these values, so a reset shorter than that changes nothing at power-up.
    reg  [9:0]  sw_n = 10'd0;
    wire        sw_done = (sw_n[9:6] == 4'b1001);
    wire        sw_bank = sw_n[9];
    always @(posedge clk)
        if (!rst)          sw_n <= 10'd0;
        else if (!sw_done) sw_n <= sw_n + 10'd1;
    function [31:0] rstval;
        input [3:0] j;
        case (j)
            4'd1:    rstval = `RX_BACKEND_NB_RESET;
            4'd2:    rstval = `RX_BACKEND_NB_HOLD_RESET;
            4'd3:    rstval = `RX_BACKEND_AGC_ATTACK_RESET;
            4'd4:    rstval = `RX_BACKEND_AGC_DECAY_RESET;
            4'd5:    rstval = `RX_BACKEND_AGC_HANG_RESET;
            4'd6:    rstval = `RX_BACKEND_AGC_REF_RESET;
            4'd7:    rstval = `RX_BACKEND_AGC_GMAX_RESET;
            4'd8:    rstval = `RX_BACKEND_AGC_GMIN_RESET;
            4'd9:    rstval = `RX_BACKEND_AGC_MANUAL_RESET;
            4'd10:   rstval = `RX_BACKEND_LOOPS_RESET;
            4'd11:   rstval = `RX_BACKEND_FM_DEEMPH_RESET;
            4'd12:   rstval = `RX_BACKEND_SQUELCH_RESET;
            4'd13:   rstval = `RX_BACKEND_RING_BASE_RESET;
            default: rstval = 32'd0;
        endcase
    endfunction
    wire [15:0] sw_wa = sw_bank ? {10'd0, sw_n[5:2], 2'd0} : {5'd0, {1'b0, sw_n[4:2]} + 4'd2, 7'd0};
    wire [31:0] sw_wd = sw_bank ? `RX_BACKEND_BANK_CFG_RESET : rstval(sw_n[8:5]);
    wire        sw_fire = (sw_n[1:0] == 2'd2) && !sw_done;
    reg  [15:0] sw_oh;
    integer     sw_j;
    always @(*)
        for (sw_j = 0; sw_j < 16; sw_j = sw_j + 1)
            sw_oh[sw_j] = sw_fire && !sw_bank && (sw_n[8:5] == sw_j);
    reg                               w_go1, w_go2, w_go3;
    (* syn_preserve = 1 *) reg [1:0]  w_go;          // the coefficient window, per unit
    wire [3:0]  wr_blk  = rbmc_wa[10:7];
    wire [2:0]  wr_rx   = wr_blk[2:0] - 3'd2;          // blocks 2..9 -> receivers 0..7
    wire        wr_word = (rbmc_wa[1:0] == 2'd0);
    wire        wr_isrx = wr_word && (rbmc_wa[15:11] == 5'd0) && (wr_blk >= 4'd2) && (wr_blk <= NRX + 1);
    wire        wr_isgl = wr_word && (rbmc_wa[15:8] == 8'd0);
    integer     wr_r, wr_j;
    function [4:0] wslot;             // the register slot of writable slot j
        input integer j;
        wslot = (j <= 12) ? j : j + 7;
    endfunction
    always @(posedge clk) begin
        if (reg_wr_r) begin
            rbmc_wa <= reg_addr_r;
            rbmc_wd <= reg_wdata_r;
        end
        if (w_go2) begin
            rbmc_wa2 <= rbmc_wa;
            rbmc_wd2 <= rbmc_wd;
            for (wr_r = 0; wr_r < 8; wr_r = wr_r + 1)
                for (wr_j = 0; wr_j < 16; wr_j = wr_j + 1)
                    wr_en1[wr_r*16 + wr_j] <= (wr_r < NRX) && wr_isrx && wr_rx == wr_r && rbmc_wa[6:2] == wslot(wr_j);
            wr_en1[131:128] <= {rbmc_wa == `RX_BACKEND_COEF_SEL_ADDR, rbmc_wa == `RX_BACKEND_IRQ_ENABLE_ADDR,
                                rbmc_wa == `RX_BACKEND_IRQ_STATUS_ADDR, rbmc_wa == `RX_BACKEND_STATUS_ADDR};
            wr_en1[132] <= wr_isgl && rbmc_wa[7:6] == 2'b01 && rbmc_wa[5:2] < 6 * NU;
            for (wr_j = 0; wr_j < 16; wr_j = wr_j + 1)
                ws_en1[wr_j] <= wr_isrx && rbmc_wa[6:2] == wslot(wr_j);
            wr_en1[133] <= (rbmc_wa >= `RX_BACKEND_COEF_OFFSET) &&
                           (rbmc_wa < `RX_BACKEND_COEF_OFFSET + `RX_BACKEND_COEF_COUNT * `RX_BACKEND_COEF_STRIDE);
        end
        if (rst && sw_n[1:0] == 2'd0 && !sw_done) begin     // the reset's own writes (w_go2 is low)
            rbmc_wa2 <= sw_wa;
            rbmc_wd2 <= sw_wd;
        end
        if (rst) begin
            w_go1  <= 1'b0;
            w_go2  <= 1'b0;
            w_go3  <= 1'b0;
            w_go   <= 2'd0;
            wr_en2 <= 134'd0;
            ws_en2  <= sw_oh;
            ws_en2c <= sw_oh;
            bk_we   <= {3{sw_fire && sw_bank}};
        end else begin
            w_go1  <= reg_wr_r;
            w_go2  <= w_go1;
            w_go3  <= w_go2;
            w_go   <= {2{w_go3 && wr_en1[133]}};
            wr_en2 <= w_go3 ? wr_en1 : 134'd0;
            ws_en2  <= w_go3 ? ws_en1 : 16'd0;
            ws_en2c <= w_go3 ? ws_en1 : 16'd0;
            bk_we   <= {3{w_go3 && wr_en1[132]}};
        end
    end

    // read: address fields latched on the access (rule 1); r_go1..r_go4 follow the access, the
    // read fields load on r_go2 and reg_rdata on r_go4 (rule 2)
    wire [3:0]  rd_blk  = reg_addr_r[10:7];
    wire        rd_word = (reg_addr_r[1:0] == 2'd0);
    // receiver, in eight copies (as one register its fan-out would be 1,344): copy i is
    // rbmc_rrx[3i +: 3]
    (* syn_preserve = 1 *) reg [23:0] rbmc_rrx;
    (* syn_preserve = 1 *) reg [4:0]  rbmc_rk;        // per-receiver register slot
    (* syn_preserve = 1 *) reg [5:0]  rbmc_rgl;       // reg_addr[7:2], for the global registers
    (* syn_preserve = 1 *) reg        rbmc_risrx, rbmc_risgl;
    reg                               r_go1, r_go3, r_go4;
    (* syn_preserve = 1 *) reg [3:0]  r_go2;          // copies, a quarter of the read fields each
    always @(posedge clk) begin
        if (reg_rd_r) begin
            rbmc_rrx   <= {8{rd_blk[2:0] - 3'd2}};
            rbmc_rk    <= reg_addr_r[6:2];
            rbmc_rgl   <= reg_addr_r[7:2];
            rbmc_risrx <= rd_word && (reg_addr_r[15:11] == 5'd0) && (rd_blk >= 4'd2) && (rd_blk <= NRX + 1);
            rbmc_risgl <= rd_word && (reg_addr_r[15:8] == 8'd0);
        end
        if (rst) begin
            r_go1 <= 1'b0;
            r_go2 <= 4'd0;
            r_go3 <= 1'b0;
            r_go4 <= 1'b0;
        end else begin
            r_go1 <= reg_rd_r;
            r_go2 <= {4{r_go1}};
            r_go3 <= r_go2[0];
            r_go4 <= r_go3;
        end
    end

    // ================================================================ registers
    // Only the control word, the ring size and the ring enable of each receiver are flip-flops
    // (the engines read them all at once). Every other setting is one word per receiver in LUT
    // RAM (bk_cfgram): an engine works on one receiver at a time and reads that receiver's word at the
    // receiver number it gives; the register read-back has a second memory with the same contents.
    // (As flip-flops with 8-way selects, the settings took 2,700 flip-flops and most of this
    // module's 10,500 LUTs.)
    (* syn_ramstyle = "registers" *) reg  [15:0] r_ctrl   [0:NRX-1];
    (* syn_ramstyle = "registers" *) reg  [3:0]  r_rlog2  [0:NRX-1];
    (* syn_ramstyle = "registers" *) reg         r_ren    [0:NRX-1];
    reg  [3:0]  r_coefsel;
    reg  [3:0]  r_status;
    reg  [7:0]  r_irq_st, r_irq_en;

    // flattened views for the engines: always 8 wide, the receivers that are not built are 0. Continuous
    // assignments: an always @(*) over an array that never changes stays X in iverilog.
    wire [7:0]   en, nb_en, agc_en, sq_en, out24;
    wire [23:0]  in_shift, mode, bank_sel;
    wire [15:0]  in_rate;
    wire [31:0]  ring_log2_f;
    wire [7:0]   ring_en_f;
    genvar gf;
    generate
        for (gf = 0; gf < 8; gf = gf + 1) begin : flat
            if (gf < NRX) begin : used
                assign en[gf]              = r_ctrl[gf][`RX_BACKEND_CTRL_ENABLE_LSB];
                assign mode[gf*3 +: 3]     = r_ctrl[gf][`RX_BACKEND_CTRL_MODE_MSB:`RX_BACKEND_CTRL_MODE_LSB];
                assign out24[gf]           = r_ctrl[gf][`RX_BACKEND_CTRL_OUT24_LSB];
                assign in_rate[gf*2 +: 2]  = r_ctrl[gf][`RX_BACKEND_CTRL_IN_RATE_MSB:`RX_BACKEND_CTRL_IN_RATE_LSB];
                assign in_shift[gf*3 +: 3] = r_ctrl[gf][`RX_BACKEND_CTRL_IN_SHIFT_MSB:`RX_BACKEND_CTRL_IN_SHIFT_LSB];
                assign nb_en[gf]           = r_ctrl[gf][`RX_BACKEND_CTRL_NB_EN_LSB];
                assign agc_en[gf]          = r_ctrl[gf][`RX_BACKEND_CTRL_AGC_EN_LSB];
                assign sq_en[gf]           = r_ctrl[gf][`RX_BACKEND_CTRL_SQ_EN_LSB];
                assign bank_sel[gf*3 +: 3] = r_ctrl[gf][`RX_BACKEND_CTRL_BANK_SEL_MSB:`RX_BACKEND_CTRL_BANK_SEL_LSB];
                assign ring_log2_f[gf*4 +: 4] = r_rlog2[gf];
                assign ring_en_f[gf]       = r_ren[gf];
            end else begin : unused
                assign en[gf]              = 1'b0;
                assign mode[gf*3 +: 3]     = 3'd0;
                assign out24[gf]           = 1'b0;
                assign in_rate[gf*2 +: 2]  = 2'd0;
                assign in_shift[gf*3 +: 3] = 3'd0;
                assign nb_en[gf]           = 1'b0;
                assign agc_en[gf]          = 1'b0;
                assign sq_en[gf]           = 1'b0;
                assign bank_sel[gf*3 +: 3] = 3'd0;
                assign ring_log2_f[gf*4 +: 4] = 4'd0;
                assign ring_en_f[gf]       = 1'b0;
            end
        end
    endgenerate

    // ---- the settings memories. e_*: the engines' copies; c_*: the read-back copies. The macro
    // below makes one memory of a setting: its slot in the register map, its width and lowest bit,
    // its reset value, the write enable flag, the read address and the output.
    wire [35:0] p_crx;                       // bk_post: the job's receiver, twelve copies
    wire [2:0]  f_r2c, f_r3, f_r4;           // bk_front: the receiver at three of its stages
    wire [2:0]  g_rx;                        // bk_ring: the receiver of the word being addressed
    wire [7:0]  e_nbt;   wire [12:0] e_nbk;  wire [15:0] e_hold;
    wire [23:0] e_att, e_dec;
    wire [15:0] e_hang;  wire [16:0] e_ref, e_deemph;
    wire [19:0] e_gmax, e_gmin, e_gman;
    wire [20:0] e_loops; wire [31:0] e_sq, e_rbase;
    wire [20:0] c_nb;    wire [15:0] c_hold, c_hang;
    wire [23:0] c_att, c_dec;
    wire [16:0] c_ref, c_deemph;
    wire [19:0] c_gmax, c_gmin, c_gman;
    wire [20:0] c_loops; wire [31:0] c_sq, c_rbase;
`define BK_CFG(NAME, SLOT, WIDTH, LOBIT, RSTVAL, WE, RA, RD) \
    bk_cfgram #(.W(WIDTH), .RSTV(RSTVAL), .LO(LOBIT)) NAME ( \
        .clk(clk), .we(WE[SLOT]), .wa(cw_a), .wd(rbmc_wd2[LOBIT +: WIDTH]), .ra({1'b0, RA}), .rd(RD))
    `BK_CFG(m_nbt,    1,  8,  0, `RX_BACKEND_NB_RESET,          ws_en2, f_r3,           e_nbt);
    `BK_CFG(m_nbk,    1, 13,  8, `RX_BACKEND_NB_RESET,          ws_en2, f_r2c,          e_nbk);
    `BK_CFG(m_hold,   2, 16,  0, `RX_BACKEND_NB_HOLD_RESET,     ws_en2, f_r4,           e_hold);
    `BK_CFG(m_att,    3, 24,  0, `RX_BACKEND_AGC_ATTACK_RESET,  ws_en2, p_crx[2*3 +: 3],  e_att);
    `BK_CFG(m_dec,    4, 24,  0, `RX_BACKEND_AGC_DECAY_RESET,   ws_en2, p_crx[10*3 +: 3], e_dec);
    `BK_CFG(m_hang,   5, 16,  0, `RX_BACKEND_AGC_HANG_RESET,    ws_en2, p_crx[3*3 +: 3],  e_hang);
    `BK_CFG(m_ref,    6, 17,  0, `RX_BACKEND_AGC_REF_RESET,     ws_en2, p_crx[3*3 +: 3],  e_ref);
    `BK_CFG(m_gmax,   7, 20,  0, `RX_BACKEND_AGC_GMAX_RESET,    ws_en2, p_crx[4*3 +: 3],  e_gmax);
    `BK_CFG(m_gmin,   8, 20,  0, `RX_BACKEND_AGC_GMIN_RESET,    ws_en2, p_crx[4*3 +: 3],  e_gmin);
    `BK_CFG(m_gman,   9, 20,  0, `RX_BACKEND_AGC_MANUAL_RESET,  ws_en2, p_crx[9*3 +: 3],  e_gman);
    `BK_CFG(m_loops, 10, 21,  0, `RX_BACKEND_LOOPS_RESET,       ws_en2, p_crx[1*3 +: 3],  e_loops);
    `BK_CFG(m_deemph,11, 17,  0, `RX_BACKEND_FM_DEEMPH_RESET,   ws_en2, p_crx[11*3 +: 3], e_deemph);
    `BK_CFG(m_sq,    12, 32,  0, `RX_BACKEND_SQUELCH_RESET,     ws_en2, p_crx[8*3 +: 3],  e_sq);
    `BK_CFG(m_rbase, 13, 32,  0, `RX_BACKEND_RING_BASE_RESET,   ws_en2, g_rx,           e_rbase);
    // read-back copies, at the latched read address (rbmc_rrx, the copies it had)
    `BK_CFG(mc_nb,    1, 21,  0, `RX_BACKEND_NB_RESET,          ws_en2c, rbmc_rrx[2:0],   c_nb);
    `BK_CFG(mc_hold,  2, 16,  0, `RX_BACKEND_NB_HOLD_RESET,     ws_en2c, rbmc_rrx[2:0],   c_hold);
    `BK_CFG(mc_att,   3, 24,  0, `RX_BACKEND_AGC_ATTACK_RESET,  ws_en2c, rbmc_rrx[2:0],   c_att);
    `BK_CFG(mc_dec,   4, 24,  0, `RX_BACKEND_AGC_DECAY_RESET,   ws_en2c, rbmc_rrx[5:3],   c_dec);
    `BK_CFG(mc_hang,  5, 16,  0, `RX_BACKEND_AGC_HANG_RESET,    ws_en2c, rbmc_rrx[5:3],   c_hang);
    `BK_CFG(mc_ref,   6, 17,  0, `RX_BACKEND_AGC_REF_RESET,     ws_en2c, rbmc_rrx[5:3],   c_ref);
    `BK_CFG(mc_gmax,  7, 20,  0, `RX_BACKEND_AGC_GMAX_RESET,    ws_en2c, rbmc_rrx[8:6],   c_gmax);
    `BK_CFG(mc_gmin,  8, 20,  0, `RX_BACKEND_AGC_GMIN_RESET,    ws_en2c, rbmc_rrx[8:6],   c_gmin);
    `BK_CFG(mc_gman,  9, 20,  0, `RX_BACKEND_AGC_MANUAL_RESET,  ws_en2c, rbmc_rrx[8:6],   c_gman);
    `BK_CFG(mc_loops,10, 21,  0, `RX_BACKEND_LOOPS_RESET,       ws_en2c, rbmc_rrx[11:9],  c_loops);
    `BK_CFG(mc_deemph,11,17,  0, `RX_BACKEND_FM_DEEMPH_RESET,   ws_en2c, rbmc_rrx[11:9],  c_deemph);
    `BK_CFG(mc_sq,   12, 32,  0, `RX_BACKEND_SQUELCH_RESET,     ws_en2c, rbmc_rrx[11:9],  c_sq);
    `BK_CFG(mc_rbase,13, 32,  0, `RX_BACKEND_RING_BASE_RESET,   ws_en2c, rbmc_rrx[23:21], c_rbase);
`undef BK_CFG
    // the bank table: 12 words (6 per channel-filter unit); a memory per unit and one for the read-back
    wire [5:0]  u_cbank;                     // each unit's bank, 3 bits
    wire [31:0] e_bank;                      // each unit's bank word, 16 bits
    wire [15:0] c_bank;
    bk_cfgram #(.W(16), .RSTV(`RX_BACKEND_BANK_CFG_RESET)) m_bank0 (
        .clk(clk), .we(bk_we[0]), .wa(rbmc_wa2[5:2]), .wd(rbmc_wd2[15:0]),
        .ra({1'b0, u_cbank[2:0]}), .rd(e_bank[15:0]));
    generate
        if (NU > 1) begin : bank1
            bk_cfgram #(.W(16), .RSTV(`RX_BACKEND_BANK_CFG_RESET)) m_bank1 (
                .clk(clk), .we(bk_we[1]), .wa(rbmc_wa2[5:2]), .wd(rbmc_wd2[15:0]),
                .ra({1'b0, u_cbank[5:3]} + 4'd6), .rd(e_bank[31:16]));
        end else begin : nobank1
            assign e_bank[31:16] = 16'd0;
        end
    endgenerate
    bk_cfgram #(.W(16), .RSTV(`RX_BACKEND_BANK_CFG_RESET)) mc_bank (
        .clk(clk), .we(bk_we[2]), .wa(rbmc_wa2[5:2]), .wd(rbmc_wd2[15:0]),
        .ra(rbmc_rgl[3:0]), .rd(c_bank));

    assign irq = |(r_irq_st & r_irq_en);

    // ================================================================ epochs
    // The epoch bit of a receiver flips on every rising edge of its enable. It travels with every
    // sample, and an engine drops samples whose epoch is not the current one, so a disable and
    // enable pair can come at any time without stale samples reaching the output.
    reg [7:0] en_d, epoch;
    always @(posedge clk) begin
        if (rst) begin
            en_d  <= 8'd0;
            epoch <= 8'd0;
        end else begin
            en_d  <= en;
            epoch <= epoch ^ (en & ~en_d);
        end
    end

    // ================================================================ engines
    // The chain of the engines with the FIFOs between them (see the header). The FIFO after the
    // noise blanker has 64 entries, the others 8.
    wire         first_ev;
    wire [2:0]   first_rx;
    wire         a_push;
    wire [52:0]  a_din, a_dout;
    wire         a_empty, a_full, a_ovf;
    wire         a_pop;
    wire [255:0] blanked;

    bk_front #(.NRX(NRX)) u_front (
        .clk(clk), .rst(rst),
        .in_valid(in_valid), .in_rx(in_index), .in_i(in_i), .in_q(in_q),
        .en(en), .epoch(epoch), .in_shift(in_shift), .nb_en(nb_en),
        .cfg_r2c(f_r2c), .cfg_r3(f_r3), .cfg_r4(f_r4), .nb_thr(e_nbt),
        .nb_kdown(e_nbk[`RX_BACKEND_NB_K_DOWN_MSB-8:`RX_BACKEND_NB_K_DOWN_LSB-8]),
        .nb_kup(e_nbk[`RX_BACKEND_NB_K_UP_MSB-8:`RX_BACKEND_NB_K_UP_LSB-8]), .nb_hold(e_hold),
        .first_ev(first_ev), .first_rx(first_rx),
        .out_push(a_push), .out_data(a_din), .blanked(blanked)
    );
    bk_fifo #(.DW(53), .LOG2(6)) u_fa (
        .clk(clk), .rst(rst), .push(a_push), .din(a_din), .pop(a_pop), .dout(a_dout),
        .empty(a_empty), .full(a_full), .overflow(a_ovf)
    );

    wire         d_push;
    wire [52:0]  d_data;
    bk_decim #(.HB_FILE(HB_FILE), .NRX(NRX)) u_decim (
        .clk(clk), .rst(rst),
        .in_empty(a_empty), .in_data(a_dout), .in_pop(a_pop),
        .en(en), .epoch(epoch), .in_rate(in_rate),
        .out_push(d_push), .out_data(d_data)
    );

    // coefficient window: written straight into bk_chfilt's coefficient memories from the
    // latched write (rbmc_wa2, rbmc_wd2: two-clock paths; the enable is w_go[unit], set with
    // wr_en2 for a write in the window)
    wire [2:0] coef_bank = r_coefsel[`RX_BACKEND_COEF_SEL_BANK_MSB:`RX_BACKEND_COEF_SEL_BANK_LSB];
    wire       coef_unit = r_coefsel[`RX_BACKEND_COEF_SEL_UNIT_LSB];

    wire [1:0]   b_empty, b_ovf, c_empty, c_ovf, b_pop, c_pop, cf_push;
    wire [105:0] b_dout, c_din, c_dout;
    wire [23:0]  bank_cur;
    genvar gu;
    generate
        // the second channel-filter unit (receivers 4-7) only exists for NRX > 4; without it its FIFO side
        // reads empty and the post engine never looks at it
        if (NU < 2) begin : nounit1
            assign b_empty[1] = 1'b1;
            assign c_empty[1] = 1'b1;
            assign b_ovf[1]   = 1'b0;
            assign c_ovf[1]   = 1'b0;
            assign b_pop[1]   = 1'b0;
            assign cf_push[1] = 1'b0;
            assign b_dout[105:53] = 53'd0;
            assign c_din[105:53]  = 53'd0;
            assign c_dout[105:53] = 53'd0;
            assign bank_cur[23:12] = 12'd0;
            assign u_cbank[5:3]    = 3'd0;
        end
        for (gu = 0; gu < NU; gu = gu + 1) begin : unit
            wire b_full, c_full;
            bk_fifo #(.DW(53), .LOG2(3)) u_fb (
                .clk(clk), .rst(rst), .push(d_push && d_data[51] == gu), .din(d_data),
                .pop(b_pop[gu]), .dout(b_dout[gu*53 +: 53]), .empty(b_empty[gu]), .full(b_full),
                .overflow(b_ovf[gu])
            );
            bk_chfilt #(.NRU((NRX - gu * 4) > 4 ? 4 : (NRX - gu * 4))) u_cf (
                .clk(clk), .rst(rst),
                .in_empty(b_empty[gu]), .in_data(b_dout[gu*53 +: 53]), .in_pop(b_pop[gu]),
                .en(en[gu*4 +: 4]), .epoch(epoch[gu*4 +: 4]), .bank_sel(bank_sel[gu*12 +: 12]),
                .cfg_bank(u_cbank[gu*3 +: 3]),
                .bank_ntaps(e_bank[gu*16 + `RX_BACKEND_BANK_CFG_NTAPS_LSB +: 11]),
                .bank_exp(e_bank[gu*16 + `RX_BACKEND_BANK_CFG_EXP_LSB +: 4]),
                .coef_we(w_go[gu] && coef_unit == gu), .coef_bank(coef_bank),
                .coef_tap(rbmc_wa2[12:3]), .coef_im(rbmc_wa2[2]), .coef_data(rbmc_wd2),
                .out_push(cf_push[gu]), .out_data(c_din[gu*53 +: 53]), .bank_cur(bank_cur[gu*12 +: 12])
            );
            bk_fifo #(.DW(53), .LOG2(3)) u_fc (
                .clk(clk), .rst(rst), .push(cf_push[gu]), .din(c_din[gu*53 +: 53]),
                .pop(c_pop[gu]), .dout(c_dout[gu*53 +: 53]), .empty(c_empty[gu]), .full(c_full),
                .overflow(c_ovf[gu])
            );
        end
    endgenerate

    wire         p_valid;
    wire [2:0]   p_rx;
    wire [15:0]  p_s0, p_s1;
    wire [127:0] st_smeter;
    wire [7:0]   st_sq_open;
    wire [143:0] st_gain;
    bk_post #(.HB_FILE(HB_FILE), .LOG2_FILE(LOG2_FILE), .EXP2_FILE(EXP2_FILE), .NRX(NRX)) u_post (
        .clk(clk), .rst(rst),
        .in0_empty(c_empty[0]), .in0_data(c_dout[52:0]), .in0_pop(c_pop[0]),
        .in1_empty(c_empty[1]), .in1_data(c_dout[105:53]), .in1_pop(c_pop[1]),
        .en(en), .epoch(epoch), .mode(mode), .out24(out24), .agc_en(agc_en), .sq_en(sq_en),
        .cfg_rx(p_crx),
        .k_sm(e_loops[`RX_BACKEND_LOOPS_K_SM_MSB:`RX_BACKEND_LOOPS_K_SM_LSB]),
        .k_dc(e_loops[`RX_BACKEND_LOOPS_K_DC_MSB:`RX_BACKEND_LOOPS_K_DC_LSB]),
        .sam_kp(e_loops[`RX_BACKEND_LOOPS_SAM_KP_MSB:`RX_BACKEND_LOOPS_SAM_KP_LSB]),
        .sam_ki(e_loops[`RX_BACKEND_LOOPS_SAM_KI_MSB:`RX_BACKEND_LOOPS_SAM_KI_LSB]), .deemph(e_deemph),
        .att_a(e_att[`RX_BACKEND_AGC_ATTACK_A_MSB:`RX_BACKEND_AGC_ATTACK_A_LSB]),
        .att_s(e_att[`RX_BACKEND_AGC_ATTACK_S_MSB:`RX_BACKEND_AGC_ATTACK_S_LSB]),
        .dec_a(e_dec[`RX_BACKEND_AGC_DECAY_A_MSB:`RX_BACKEND_AGC_DECAY_A_LSB]),
        .dec_s(e_dec[`RX_BACKEND_AGC_DECAY_S_MSB:`RX_BACKEND_AGC_DECAY_S_LSB]), .hang_n(e_hang),
        .agc_ref(e_ref), .gmax(e_gmax), .gmin(e_gmin), .gman(e_gman),
        .sq_open_l(e_sq[`RX_BACKEND_SQUELCH_OPEN_MSB:`RX_BACKEND_SQUELCH_OPEN_LSB]),
        .sq_close_l(e_sq[`RX_BACKEND_SQUELCH_CLOSE_MSB:`RX_BACKEND_SQUELCH_CLOSE_LSB]),
        .out_valid(p_valid), .out_rx(p_rx), .out_s0(p_s0), .out_s1(p_s1),
        .st_smeter(st_smeter), .st_sq_open(st_sq_open), .st_gain(st_gain)
    );

    // ================================================================ stamps and output
    // stamp_base (the HL2 index of a receiver's first sample) is only written on that first
    // sample and only read by the register port: one word per receiver in LUT RAM (m_stamp
    // below), read at the latched read address. stamp_next is the stamp of the next output
    // sample of each receiver and out_count the number of output samples since enable.
    wire [47:0] c_stamp;
    (* syn_ramstyle = "registers" *) reg [47:0] stamp_next [0:NRX-1];
    (* syn_ramstyle = "registers" *) reg [31:0] out_count  [0:NRX-1];
    function [47:0] per_out;  input o24; per_out = o24 ? 48'd3200 : 48'd6400; endfunction
    function [47:0] per_in;   input [1:0] rs; per_in = 48'd1600 >> rs; endfunction
    integer r4;

    // A receiver's first sample (first_ev) must not go through an 8-way select into a 48-bit add
    // in one clock. So hl2_index and the receiver's out24 and in_rate are captured on first_ev,
    // the stamp offset (per_out - per_in) is worked out a clock later, added the clock after,
    // and written the clock after that, which is early enough since the first output of that
    // receiver comes hundreds of clocks later. The first output's stamp is the capture plus
    // (output period - input period), which is the HL2 index at which that output was completed.
    // Each receiver has its own adder for stamp_next and out_count.
    reg        fe_v1;
    // (bk_front registers its input once more, so first_ev is a clock later: the HL2 index is
    // taken a clock later to match)
    reg [47:0] hl2_index_d;
    always @(posedge clk) begin
        fe_v1 <= first_ev && !rst;
        hl2_index_d <= hl2_index;
    end
    reg [2:0]  fe_rx1;
    reg        fe_o24;                        // the receiver's out24 and in_rate, at first_ev
    reg [1:0]  fe_rs;
    reg [7:0]  fe_sel2, fe_sel3;              // one-hot receiver, 0 when no first sample
    reg [2:0]  fe_rx2, fe_rx3;                // the same receiver as a number, for stamp_base's memory
    reg        fe_v3;
    reg [47:0] fe_idx1, fe_idx2, fe_idx3, fe_next3;
    reg [12:0] fe_off2;                       // per_out - per_in: at most 6400 - 200
    always @(posedge clk) begin
        if (first_ev) begin
            fe_rx1  <= first_rx;
            fe_idx1 <= hl2_index_d;
            fe_o24  <= out24[first_rx];
            fe_rs   <= in_rate[first_rx*2 +: 2];
        end
        if (rst) begin
            fe_sel2 <= 8'd0;
            fe_sel3 <= 8'd0;
            fe_v3   <= 1'b0;
        end else begin
            fe_sel2 <= fe_v1 ? 8'd1 << fe_rx1 : 8'd0;
            fe_sel3 <= fe_sel2;
            fe_v3   <= |fe_sel2;
        end
        fe_rx2   <= fe_rx1;
        fe_rx3   <= fe_rx2;
        fe_idx2  <= fe_idx1;
        fe_off2  <= per_out(fe_o24) - per_in(fe_rs);
        fe_idx3  <= fe_idx2;
        fe_next3 <= fe_idx2 + {35'd0, fe_off2};
    end

    // mode == IQ per receiver, from a register (out_iq from p_rx through the 8-way mode select
    // would be too slow); a mode change reaches out_iq one clock later
    reg [7:0] is_iq;
    always @(posedge clk)
        for (r4 = 0; r4 < 8; r4 = r4 + 1)
            is_iq[r4] <= (r4 < NRX) && mode[r4*3 +: 3] == 3'd4;

    // bk_post's output sample registered once more here, with its receiver as a one-hot flag
    // (bk_post's out_valid, as the load enable of every receiver's stamp_next and out_count
    // through the p_rx decode, would be too slow)
    reg        pq_v;
    reg [2:0]  pq_rx;
    reg [15:0] pq_s0, pq_s1;
    reg [7:0]  pq_sel;
    // each receiver's stamp_next and out_count load on one flag of their own, registered with
    // pq_sel and fe_sel3 (either of them; the output sample wins): sn_ce for stamp_next, oc_ce
    // for out_count (a load enable through a LUT, fed by a one-hot flag with a fan-out of 80,
    // would be too slow)
    reg [7:0]  sn_ce, oc_ce;
    // out_count + 1 written as {a, 1} + {0, 1}: Gowin builds the plain "+ 1" from LUTs, ten
    // levels deep, while this form goes onto the carry chain
    // (docs/TANG_LESSONS.md section 6)
    function [31:0] inc32(input [31:0] a);
        reg [32:0] t;
        begin
            t = {a, 1'b1} + {32'd0, 1'b1};
            inc32 = t[32:1];
        end
    endfunction
    always @(posedge clk) begin
        pq_v   <= p_valid && !rst;
        pq_sel <= (p_valid && !rst) ? 8'd1 << p_rx : 8'd0;
        pq_rx  <= p_rx;
        pq_s0  <= p_s0;
        pq_s1  <= p_s1;
        sn_ce  <= ((p_valid && !rst) ? 8'd1 << p_rx : 8'd0) | fe_sel2;
        oc_ce  <= ((p_valid && !rst) ? 8'd1 << p_rx : 8'd0) | fe_sel2;
    end
    always @(posedge clk)
        for (r4 = 0; r4 < NRX; r4 = r4 + 1) begin
            if (sn_ce[r4])
                stamp_next[r4] <= pq_sel[r4] ? stamp_next[r4] + per_out(out24[r4]) : fe_next3;
            if (oc_ce[r4])
                out_count[r4]  <= pq_sel[r4] ? inc32(out_count[r4]) : 32'd0;
        end

    bk_cfgram #(.W(48)) m_stamp (
        .clk(clk), .we(fe_v3), .wa({1'b0, fe_rx3}), .wd(fe_idx3), .ra({1'b0, rbmc_rrx[20:18]}), .rd(c_stamp));

    always @(posedge clk) begin
        out_valid <= 1'b0;
        if (pq_v) begin
            out_valid <= 1'b1;
            out_rx    <= pq_rx;
            out_s0    <= pq_s0;
            out_s1    <= pq_s1;
            out_iq    <= is_iq[pq_rx];
            out_stamp <= stamp_next[pq_rx];
        end
    end

    // ================================================================ output rings
    wire [255:0] ring_wptr_i;
    wire [7:0]   ring_block_i;
    wire         ring_ovf;
    bk_ring #(.NRX(NRX)) u_ring (
        .clk(clk), .rst(rst),
        .in_valid(out_valid), .in_rx(out_rx), .in_s0(out_s0), .in_s1(out_s1), .in_iq(out_iq),
        .in_stamp(out_stamp), .smeter(st_smeter),
        .cfg_rx(g_rx), .ring_base(e_rbase), .ring_log2(ring_log2_f), .ring_en(ring_en_f),
        .ring_wptr(ring_wptr_i), .block_done(ring_block_i), .overflow(ring_ovf),
        .req(ring_req), .addr(ring_addr), .burstlen(ring_burstlen), .wdata(ring_wdata),
        .wmask(ring_wmask), .gnt(ring_gnt), .done(ring_done)
    );

    // ================================================================ register port
    // Writes: from the latched address and data (rbmc_wa, rbmc_wd2; two-clock paths), each
    // register enabled by its own wr_en2 flag (a one-clock path). Same addresses and values as
    // the register map.
    always @(posedge clk) begin
        if (rst) begin
            for (r3 = 0; r3 < NRX; r3 = r3 + 1) begin
                r_ctrl[r3]   <= `RX_BACKEND_CTRL_RESET;
                r_rlog2[r3]  <= `RX_BACKEND_RING_SLOTS_RESET;
                r_ren[r3]    <= 1'b0;
            end
            r_coefsel <= 4'd0;
            r_status  <= 4'd0;
            r_irq_st  <= 8'd0;
            r_irq_en  <= 8'd0;
        end else begin
            r_status <= r_status | {ring_ovf, c_ovf[0] | c_ovf[1], b_ovf[0] | b_ovf[1], a_ovf};
            r_irq_st <= r_irq_st | ring_block_i;
            begin
                if (wr_en2[128]) r_status  <= (r_status | {ring_ovf, c_ovf[0] | c_ovf[1], b_ovf[0] | b_ovf[1], a_ovf}) & ~rbmc_wd2[3:0];
                if (wr_en2[129]) r_irq_st  <= (r_irq_st | ring_block_i) & ~rbmc_wd2[7:0];
                if (wr_en2[130]) r_irq_en  <= rbmc_wd2[7:0];
                if (wr_en2[131]) r_coefsel <= rbmc_wd2[3:0];
            end
            // bank settings and per-receiver settings: decoded from the address fields, as the
            // reads below are (same addresses as the register map, checked there)
            for (r3 = 0; r3 < NRX; r3 = r3 + 1)
                begin
                    if (wr_en2[r3*16 + 0])  r_ctrl[r3]   <= rbmc_wd2[15:0];
                    if (wr_en2[r3*16 + 14]) r_rlog2[r3]  <= rbmc_wd2[3:0];
                    if (wr_en2[r3*16 + 15]) r_ren[r3]    <= rbmc_wd2[0];
                end
        end
    end

    // Register reads. An indexed two-level mux over the address fields (per-receiver registers
    // sit at 0x100 + 0x80 r + 4 k: the receiver r = reg_addr[10:7] - 2 selects among 8 in each of
    // the 24 register slots k = reg_addr[6:2], and k selects among the slots); the value returned
    // for an unmapped address is 0.
    //
    // First step, on r_go2: every field selected by receiver (rbmc_rrx, a two-clock path) into
    // its own read field rbmc_f_*, in parallel; the value itself arrives through a one-clock
    // path (rule 3). Second step, on r_go4: the field selected by slot (rbmc_rk2) into reg_rdata,
    // a two-clock path from the read fields. (Doing the same two steps on every clock, each as
    // a one-clock path, fails because of the per-receiver select's fan-out and the long routes
    // from the engines' status registers to the central mux.)
    reg  [31:0] rbmc_f_ctrl, rbmc_f_nb, rbmc_f_hold, rbmc_f_att, rbmc_f_dec, rbmc_f_hang,
                rbmc_f_ref, rbmc_f_gmax, rbmc_f_gmin, rbmc_f_gman, rbmc_f_loops, rbmc_f_deemph,
                rbmc_f_sq, rbmc_f_status, rbmc_f_gain, rbmc_f_blanked, rbmc_f_stamp_lo,
                rbmc_f_stamp_hi, rbmc_f_outcnt, rbmc_f_rbase, rbmc_f_rlog2, rbmc_f_ren,
                rbmc_f_ringwptr, rbmc_f_glv;
    (* syn_preserve = 1 *) reg [4:0] rbmc_rk2;
    (* syn_preserve = 1 *) reg       rbmc_risrx2, rbmc_risgl2;
    // the engines' per-receiver status outputs as arrays, selected by index (as indexed
    // part-selects of the flat buses, st_gain[rrx*18 +: 18] and the like, Gowin built the index
    // product in a DSP block)
    wire [15:0] smeter_a  [0:7];
    wire [17:0] gain_a    [0:7];
    wire [31:0] blanked_a [0:7];
    wire [31:0] wptr_a    [0:7];
    wire [2:0]  bank_a    [0:7];
    genvar ga;
    generate
        for (ga = 0; ga < 8; ga = ga + 1) begin : stat_a
            assign smeter_a[ga]  = st_smeter[ga*16 +: 16];
            assign gain_a[ga]    = st_gain[ga*18 +: 18];
            assign blanked_a[ga] = blanked[ga*32 +: 32];
            assign wptr_a[ga]    = ring_wptr_i[ga*32 +: 32];
            assign bank_a[ga]    = bank_cur[ga*3 +: 3];
        end
    endgenerate
    always @(posedge clk) begin
        if (r_go2[0]) begin
            rbmc_f_ctrl     <= {16'd0, r_ctrl[rbmc_rrx[2:0]]};
            rbmc_f_nb       <= {11'd0, c_nb};
            rbmc_f_hold     <= {16'd0, c_hold};
            rbmc_f_att      <= {8'd0, c_att};
            rbmc_f_dec      <= {8'd0, c_dec};
            rbmc_f_hang     <= {16'd0, c_hang};
            rbmc_f_ref      <= {15'd0, c_ref};
        end
        if (r_go2[1]) begin
            rbmc_f_gmax     <= {12'd0, c_gmax};
            rbmc_f_gmin     <= {12'd0, c_gmin};
            rbmc_f_gman     <= {12'd0, c_gman};
            rbmc_f_loops    <= {11'd0, c_loops};
            rbmc_f_deemph   <= {15'd0, c_deemph};
            rbmc_f_sq       <= c_sq;
        end
        if (r_go2[2]) begin
            rbmc_f_status   <= {12'd0, bank_a[rbmc_rrx[14:12]], st_sq_open[rbmc_rrx[14:12]], smeter_a[rbmc_rrx[14:12]]};
            rbmc_f_gain     <= {{14{gain_a[rbmc_rrx[14:12]][17]}}, gain_a[rbmc_rrx[14:12]]};
            rbmc_f_blanked  <= blanked_a[rbmc_rrx[17:15]];
            rbmc_f_stamp_lo <= c_stamp[31:0];
            rbmc_f_stamp_hi <= {16'd0, c_stamp[47:32]};
            rbmc_f_outcnt   <= out_count[rbmc_rrx[17:15]];
        end
        if (r_go2[3]) begin
            rbmc_f_rbase    <= c_rbase;
            rbmc_f_rlog2    <= {28'd0, r_rlog2[rbmc_rrx[23:21]]};
            rbmc_f_ren      <= {31'd0, r_ren[rbmc_rrx[23:21]]};
            rbmc_f_ringwptr <= wptr_a[rbmc_rrx[23:21]];

            if (rbmc_rgl[5:4] == 2'b01 && rbmc_rgl[3:0] < 6 * NU)
                rbmc_f_glv <= {16'd0, c_bank};
            else if (rbmc_rgl[5:3] == 3'b000)
                case (rbmc_rgl[2:0])
                    3'd0: rbmc_f_glv <= `RX_BACKEND_ID_RESET;
                    3'd1: rbmc_f_glv <= {28'd0, r_status};
                    3'd2: rbmc_f_glv <= {24'd0, r_irq_st};
                    3'd3: rbmc_f_glv <= {24'd0, r_irq_en};
                    3'd4: rbmc_f_glv <= {28'd0, r_coefsel};
                    default: rbmc_f_glv <= 32'd0;
                endcase
            else
                rbmc_f_glv <= 32'd0;

            rbmc_rk2    <= rbmc_rk;
            rbmc_risrx2 <= rbmc_risrx;
            rbmc_risgl2 <= rbmc_risgl;
        end
    end

    reg [31:0] rd_rxv;
    always @(*) begin
        case (rbmc_rk2)
            5'd0:  rd_rxv = rbmc_f_ctrl;
            5'd1:  rd_rxv = rbmc_f_nb;
            5'd2:  rd_rxv = rbmc_f_hold;
            5'd3:  rd_rxv = rbmc_f_att;
            5'd4:  rd_rxv = rbmc_f_dec;
            5'd5:  rd_rxv = rbmc_f_hang;
            5'd6:  rd_rxv = rbmc_f_ref;
            5'd7:  rd_rxv = rbmc_f_gmax;
            5'd8:  rd_rxv = rbmc_f_gmin;
            5'd9:  rd_rxv = rbmc_f_gman;
            5'd10: rd_rxv = rbmc_f_loops;
            5'd11: rd_rxv = rbmc_f_deemph;
            5'd12: rd_rxv = rbmc_f_sq;
            5'd13: rd_rxv = rbmc_f_status;
            5'd14: rd_rxv = rbmc_f_gain;
            5'd15: rd_rxv = rbmc_f_blanked;
            5'd16: rd_rxv = rbmc_f_stamp_lo;
            5'd17: rd_rxv = rbmc_f_stamp_hi;
            5'd18: rd_rxv = rbmc_f_outcnt;
            5'd20: rd_rxv = rbmc_f_rbase;
            5'd21: rd_rxv = rbmc_f_rlog2;
            5'd22: rd_rxv = rbmc_f_ren;
            5'd23: rd_rxv = rbmc_f_ringwptr;
            default: rd_rxv = 32'd0;
        endcase
    end

    always @(posedge clk) begin
        if (r_go4)
            reg_rdata <= rbmc_risrx2 ? rd_rxv : rbmc_risgl2 ? rbmc_f_glv : 32'd0;
    end

    // The bus contract the two-clock paths rely on (simulation only): two writes, or two reads,
    // at least two clocks apart.
    // synthesis translate_off
    reg chk_wr_d = 1'b0, chk_rd_d = 1'b0;
    always @(posedge clk) begin
        chk_wr_d <= reg_wr_r;
        chk_rd_d <= reg_rd_r;
        if (!rst && reg_wr_r && chk_wr_d)
            $display("rx_backend: ERROR register writes on consecutive clocks (rx_backend.sdc needs two clocks between them) at %0t", $time);
        if (!rst && reg_rd_r && chk_rd_d)
            $display("rx_backend: ERROR register reads on consecutive clocks (rx_backend.sdc needs two clocks between them) at %0t", $time);
    end
    // synthesis translate_on

    // Consistency of the fixed offsets above with the generated register map (simulation only).
    // synthesis translate_off
    initial begin
        if (`RX_BACKEND_CTRL_ADDR(0) != 32'h100 || `RX_BACKEND_CTRL_ADDR(1) != 32'h180 ||
            `RX_BACKEND_NB_ADDR(0) != 32'h104 || `RX_BACKEND_OUT_COUNT_ADDR(0) != 32'h148 ||
            `RX_BACKEND_RING_BASE_ADDR(0) != 32'h150 || `RX_BACKEND_RING_WPTR_ADDR(0) != 32'h15C ||
            `RX_BACKEND_BANK_CFG_ADDR(0) != 32'h40 || `RX_BACKEND_COEF_SEL_ADDR != 32'h10)
            $display("rx_backend: ERROR register map offsets changed; update the read mux");
    end
    // synthesis translate_on
endmodule
