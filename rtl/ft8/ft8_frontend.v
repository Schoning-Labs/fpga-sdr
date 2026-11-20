// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// ft8_frontend: the FT8/FT4 decoder front end, the hardware half of an FT8 decoder, with its registers and its
// share of the two DDR3 lanes.
//
// What FT8 is
//   FT8 is a weak-signal digital mode for HF amateur radio.  Time is cut into fixed 15-second slots that start at
//   :00, :15, :30 and :45 of every minute (UTC), and a station transmits one short message per slot, starting 0.5 s
//   after the slot begins.  The message (77 bits, plus a 14-bit CRC and error-correction parity, 174 bits in all)
//   is sent as 79 symbols of 160 ms each, which is 12.64 s on the air.  Each symbol is one of 8 tones (8-FSK, frequency
//   shift keying with eight frequencies), the tones are 6.25 Hz apart (1 / 160 ms, which is also the symbol rate of
//   6.25 baud), so a whole signal is only 50 Hz wide and a 3 kHz audio channel holds some 60 of them at once.
//   Three of the 79 symbols are not data: the blocks of 7 symbols at positions 0-6, 36-42 and 72-78 are always the
//   same tone pattern 3 1 4 0 6 5 2, the Costas array.  Its tone changes are chosen so that it can be recognized at
//   any time and frequency offset, because the pattern correlates with itself at one position only.  A receiver does
//   not know when a station started (the clocks differ by a fraction of a second) or on which audio frequency it is,
//   so it first searches for the Costas pattern in time and frequency (the "sync search"), then cuts out each candidate
//   and measures the energy of the 8 tones in each of its 79 symbols ("soft symbols"), and finally corrects the bits
//   with an LDPC code (low-density parity-check, an error-correcting code).  The glossary entries "FT8", "Costas
//   array", "Slot", "Spectrogram", "Soft symbol" and "LDPC" in docs/learn/GLOSSARY.md say more.  FT4 is the faster
//   sibling (4 tones, 576 samples per symbol at 12 ksps, 7.5 s slots), which the same blocks serve through parameters.
//
// Why the hardware does the front end
//   Measured on the CPU, a lean decode of one 15-second slot costs about 900 million instructions, and 83 % of
//   that is regular per-sample arithmetic: 372 FFTs of 3,840 points per slot for the spectrogram, a sum over
//   all frequencies and time offsets for the sync search, and 79 x 8 correlations of 1,920 samples per candidate
//   (docs/CPU_BUDGET.md, docs/FT8_OFFLOAD.md).  An FPGA does that kind of work in parallel at one sample per clock,
//   while the irregular rest (picking candidates, belief propagation, the LDPC decoder, unpacking the message)
//   stays in the firmware, which also can be changed without a new bitstream.  With 8 receivers all decoding FT8,
//   the CPU could not do the front end for all of them.
//
// What is in here (three engines, see their own files)
//   ft8_spectrogram.v  stores each decoder receiver's 12 ksps audio of the running slot in DDR3 and, every 40 ms,
//                      makes one line of the spectrogram of it (docs/F5_FT8SPEC.md).
//   ft8_sync.v         at the end of the slot, searches the spectrogram for the Costas pattern at every frequency and
//                      time offset and writes one record per frequency to DDR3 (docs/F6_SYNC.md).
//   ft8_cand.v         the candidate engine: for a candidate the CPU chose, mixes it down to a narrow baseband (pass 1),
//                      and later cuts that baseband into the 79 x 8 soft symbols (pass 2) (docs/F7_CAND.md).
//   The sample flow is audio -> DDR3 slot buffer -> spectrogram -> sync records -> (CPU picks candidates) -> baseband
//   -> soft symbols -> (CPU decodes).  The sample rate is 12 ksps throughout, and a symbol is 1,920 samples long.
//
// Second decode pass (docs/FT8_PASS2.md)
//   After the first pass the CPU subtracts the decoded signals from the slot's audio and writes the residual back to
//   DDR3, so that weaker signals hidden under strong ones can be found.  `p2_cmd` makes the spectrogram engine replay
//   that residual into a spectrogram of its own (between the live frames), then the sync engine searches it, and
//   `irq_status.p2_done` says the records are in DDR3.  The candidate engine takes the residual like any other audio ring
//   (`cap_ring_base`).
//
// Registers
//   Register page 0xE80D_0000, layout in hw/regmap/ft8.toml (the generated include below, and docs/REGMAP.md).
//   A write takes effect two clocks after `bus_wr`; read data is valid four clocks after `bus_rd` and holds (the top
//   level waits twelve).  `bus_addr` and `bus_wdata` are taken in the clock of the strobe.  Writing a receiver's
//   slot_boundary starts its new slot (frame counter to 0, sync triggers armed); writing sync_cmd or cand_cmd starts
//   that command.
//
// DDR3
//   The engines write and read DDR3 themselves and the CPU reads their results from its own view of the same memory
//   (the CPU has to invalidate the data-cache lines first, docs/ARCHITECTURE.md).  This module is one write client (the
//   write arbiter's FT8 tier): slot capture first, then the spectrogram ring, the sync records and the candidate
//   engine's words.  It is also one read client (the read arbiter's lowest tier): the spectrogram's window reader first,
//   then the sync search, then the candidate engine.  Both shares are one level (rtl/ft8/ft8_ddr3_mux.v).  The
//   front end's average traffic is small (docs/ARCHITECTURE.md section 3.9), so it comes last and does not disturb the video, IQ or waterfall traffic.
//
// Interrupt (fabric line 11): a level, the OR of irq_status & irq_enable.

`timescale 1ns / 1ps
`include "hw/regmap/generated/ft8_regs.vh"
`include "rtl/ft8/ft8_dly.v"
`include "rtl/ft8/ft8_spectrogram.v"
`include "rtl/ft8/ft8_ddr3_mux.v"
`include "rtl/ft8/ft8_sync.v"
`include "rtl/ft8/ft8_cand.v"

module ft8_frontend #(
    // ADDR_WIDTH is the width of the DDR3 word address on the outer ports (the engines inside use 27 bits).
    parameter integer ADDR_WIDTH = 32,
    // CAND_LANES: number of candidate lanes built in ft8_cand.v.  With 1 the one lane is run twice for a two-lane
    // command, which takes twice the clocks (449,603 against 229,729 for a pass 1 with its pass 2, which is 3.75 ms
    // against 1.9 ms at 120 MHz); the registers and the results are the same as with 2.
    parameter integer CAND_LANES = 1,
    // NRX is the number of decoder receivers built, 1 to 8 (the receivers of the back end).  The register page keeps
    // its 8-receiver layout; receivers at or above NRX read 0 and ignore writes.
    parameter integer NRX = 8
) (
    // Clock (clk_dsp, 120 MHz) and synchronous reset (active high).
    input  wire        clk,
    input  wire        rst,
    // Receiver back-end output stream: one sample per audio_valid pulse for receiver audio_rx (0..7), signed 16 bit
    // at 12 ksps, and audio_iq = 1 marks I/Q words that this block ignores.
    input  wire        audio_valid,
    input  wire [2:0]  audio_rx,
    input  wire [15:0] audio_sample,
    input  wire        audio_iq,
    // Register bus (page 0xE80D_0000): bus_wr and bus_rd are strobes, bus_addr is the byte offset inside the page,
    // bus_wdata the write data and bus_rdata the read data.
    input  wire        bus_wr,
    input  wire        bus_rd,
    input  wire [15:0] bus_addr,
    input  wire [31:0] bus_wdata,
    output reg  [31:0] bus_rdata,
    // DDR3 write client (write arbiter convention): wr_req with address, burst length and data, wr_gnt when the
    // arbiter takes it, wr_done when the burst has been written.  Words are 64 bit, wr_wmask masks bytes.
    output wire        wr_req,
    output wire [ADDR_WIDTH-1:0] wr_addr,
    output wire [7:0]  wr_burstlen,
    output wire [63:0] wr_wdata,
    output wire [7:0]  wr_wmask,
    input  wire        wr_gnt,
    input  wire        wr_done,
    // DDR3 read client (read arbiter convention): rd_req with address and burst length, rd_gnt when granted,
    // rd_rvalid with rd_rdata for each 64-bit word that comes back, and rd_done after the last one.
    output wire        rd_req,
    output wire [ADDR_WIDTH-1:0] rd_addr,
    output wire [7:0]  rd_burstlen,
    input  wire        rd_gnt,
    input  wire        rd_rvalid,
    input  wire [63:0] rd_rdata,
    input  wire        rd_done,
    // Interrupt line to the CPU interrupt controller (a level).
    output reg         irq
);

    localparam integer NUM_RX = NRX;
    // Addresses inside are 27 bits wide: the DDR3 is 1 GB, which is 2^27 lane words of 8 bytes (docs/MEM_1GB.md), and
    // every address register, adder and select in the three engines is that much narrower.  The upper address bits
    // are not stored and read as 0.
    localparam integer AW = 27;
    wire [AW-1:0] wr_addr_i, rd_addr_i;
    assign wr_addr = {{(ADDR_WIDTH-AW){1'b0}}, wr_addr_i};
    assign rd_addr = {{(ADDR_WIDTH-AW){1'b0}}, rd_addr_i};

    // ================================================================ register write side
    // Stage 1: the bus as it arrives, registered.  Stage 2: one write enable per register (one flip-flop
    // each, so that no enable net carries decode logic) and the data d2, which is copied by the tool where it fans out.
    reg        w1;
    reg [15:0] a1 /* synthesis syn_maxfan = 10000 */;
    reg [31:0] d1;
    reg [31:0] d2 /* synthesis syn_maxfan = 10000 */;
    always @(posedge clk) begin
        w1 <= bus_wr && !rst;
        a1 <= bus_addr;
        d1 <= bus_wdata;
        d2 <= d1;
    end

    // Address decode.  The page has two areas: per-receiver registers at 0x200 .. 0x3FF (receiver number in address
    // bits 8:6, register number in bits 5:2, so 64 bytes per receiver) and global registers below 0x100 (register number
    // in bits 7:2), of which the candidate lane registers sit at 0x040 .. 0x05F.
    wire        a_rx   = (a1[15:10] == 6'd0) && a1[9];              // 0x200 .. 0x3FF
    wire [2:0]  a_rxi  = a1[8:6];
    wire [3:0]  a_rxr  = a1[5:2];
    wire        a_glob = (a1[15:8] == 8'h00);
    wire        a_lane = a_glob && (a1[7:5] == 3'b010);            // 0x040 .. 0x05F
    wire        a_ln   = a1[4];

    // Write enables, one flip-flop each.  Per receiver the registers are 0 ctrl, 1 cap_base, 2 spec_base,
    // 3 slot_boundary, 4 rec_base, 5 band, 6 trig.
    reg [7*NUM_RX-1:0] we_rx;
    reg                we_irq_clr, we_irq_en, we_sync_cmd, we_cand_cmd, we_cand_cap, we_cand_first;
    reg                we_p2_cmd, we_p2_base;
    reg [7:0]          we_lane;       // {lane, register}: inc, i0, bb_base, sym_base
    reg [2:0]          we_base;       // a ring base is written: 0 cap_base, 1 spec_base, 2 rec_base
    reg [2:0]          wa_base;       // ... of this receiver
    integer wi;
    // Decode the bus write into the one-clock enables above, one clock after the registered strobe.
    always @(posedge clk) begin
        for (wi = 0; wi < 7 * NUM_RX; wi = wi + 1)
            we_rx[wi] <= w1 && a_rx && (a_rxi == wi / 7) && (a_rxr == wi % 7);
        for (wi = 0; wi < 8; wi = wi + 1)
            we_lane[wi] <= w1 && a_lane && (a_ln == wi / 4) && (a1[3:2] == wi % 4);
        we_base[0]    <= w1 && a_rx && (a_rxr == 4'd1);
        we_base[1]    <= w1 && a_rx && (a_rxr == 4'd2);
        we_base[2]    <= w1 && a_rx && (a_rxr == 4'd4);
        wa_base       <= a_rxi;
        we_irq_clr    <= w1 && a_glob && (a1[7:2] == 6'h01);
        we_irq_en     <= w1 && a_glob && (a1[7:2] == 6'h02);
        we_sync_cmd   <= w1 && a_glob && (a1[7:2] == 6'h05);
        we_cand_cmd   <= w1 && a_glob && (a1[7:2] == 6'h08);
        we_cand_cap   <= w1 && a_glob && (a1[7:2] == 6'h09);
        we_cand_first <= w1 && a_glob && (a1[7:2] == 6'h0A);
        we_p2_cmd     <= w1 && a_glob && (a1[7:2] == 6'h0C);
        we_p2_base    <= w1 && a_glob && (a1[7:2] == 6'h0D);
    end

    // ---- per-receiver settings (packed, one slice per receiver):
    // r_enable switches the receiver's front end on, r_sh is the power shift of the spectrogram, r_ia and r_ib the
    // lowest and highest carrier bin of the sync search, r_trig1 and r_trig2 the two frame numbers at which the sync
    // search starts by itself (so an early decode can run before the slot ends), r_boundary the HL2 sample index
    // where the slot begins, slot_start a one-clock pulse when the slot boundary is written.
    reg [NUM_RX-1:0]    r_enable;
    reg [NUM_RX*5-1:0]  r_sh;
    // The three ring base addresses per receiver (slot audio, spectrogram, sync records) live in small LUT RAM
    // blocks (ft8_cfg8 in ft8_dly.v) instead of 8 x 27 flip-flops each: every engine reads the base of the receiver
    // it is working on, at its own receiver number, and the bus reads the one of the receiver addressed.  They are
    // not reset, because nothing runs before the firmware enables the front end.
    wire [2:0]      spec_cfg_rx, cap_cfg_rx, sync_cfg_rx;
    wire [AW-1:0]   capb_spec, capb_cap, capb_bus;
    wire [AW-1:0]   specb_spec, specb_sync, specb_bus;
    wire [AW-1:0]   recb_sync, recb_bus;
    ft8_cfg8 #(.W(AW), .NR(3)) m_capb (.clk(clk), .we(we_base[0]), .wa(wa_base), .wd(d2[AW-1:0]),
        .ra({a_rxi, cap_cfg_rx, spec_cfg_rx}), .rd({capb_bus, capb_cap, capb_spec}));
    ft8_cfg8 #(.W(AW), .NR(3)) m_specb (.clk(clk), .we(we_base[1]), .wa(wa_base), .wd(d2[AW-1:0]),
        .ra({a_rxi, sync_cfg_rx, spec_cfg_rx}), .rd({specb_bus, specb_sync, specb_spec}));
    ft8_cfg8 #(.W(AW), .NR(2)) m_recb (.clk(clk), .we(we_base[2]), .wa(wa_base), .wd(d2[AW-1:0]),
        .ra({a_rxi, sync_cfg_rx}), .rd({recb_bus, recb_sync}));
    reg [NUM_RX*32-1:0] r_boundary;
    reg [NUM_RX*10-1:0] r_ia, r_ib;
    reg [NUM_RX*9-1:0]  r_trig1, r_trig2;
    reg [NUM_RX-1:0]    slot_start;
    genvar g;
    // Per-receiver registers: writes of control, band and trigger words, and the slot boundary.  Reset values:
    // power shift 16, band bins 32 to 960 (100 Hz to 3 kHz in 3.125 Hz steps).
    generate
        for (g = 0; g < NUM_RX; g = g + 1) begin : g_rx
            always @(posedge clk) begin
                slot_start[g] <= we_rx[7*g+3] && !rst;
                if (rst) begin
                    r_enable[g]       <= 1'b0;
                    r_sh[5*g +: 5]    <= 5'd16;
                    r_ia[10*g +: 10]  <= 10'd32;
                    r_ib[10*g +: 10]  <= 10'd960;
                    r_trig1[9*g +: 9] <= 9'd0;
                    r_trig2[9*g +: 9] <= 9'd0;
                end else begin
                    if (we_rx[7*g+0]) begin
                        r_enable[g]    <= d2[`FT8_CTRL_ENABLE_LSB];
                        r_sh[5*g +: 5] <= d2[`FT8_CTRL_PWR_SHIFT_LSB +: 5];
                    end
                    if (we_rx[7*g+5]) begin
                        r_ia[10*g +: 10] <= d2[`FT8_BAND_IA_LSB +: 10];
                        r_ib[10*g +: 10] <= d2[`FT8_BAND_IB_LSB +: 10];
                    end
                    if (we_rx[7*g+6]) begin
                        r_trig1[9*g +: 9] <= d2[`FT8_TRIG_TRIG1_LSB +: 9];
                        r_trig2[9*g +: 9] <= d2[`FT8_TRIG_TRIG2_LSB +: 9];
                    end
                end
                // The boundary is an address, so it needs no reset (nothing runs before the firmware enables it).
                if (we_rx[7*g+3]) r_boundary[32*g +: 32]  <= d2;
            end
        end
    endgenerate

    // ---- commands and the candidate engine's settings:
    // r_sync_rx and r_sync_rows are the sync command's receiver and number of rows, and sync_go the one-clock start
    // pulse.  r_cand_* are the candidate command's settings (pass 1 or 2, number of lanes), the slot's audio ring base
    // and its first sample number.  r_inc, r_i0, r_bb and r_sym hold one value per candidate lane: NCO phase increment,
    // first sample index, baseband buffer base and soft-symbol buffer base.
    reg [2:0]      r_sync_rx;
    reg [8:0]      r_sync_rows;
    reg            sync_go;
    reg            r_cand_pass2;
    reg [1:0]      r_cand_lanes;
    reg            cand_go;
    reg [AW-1:0]   r_cand_cap;
    reg [31:0]     r_cand_first;
    reg [2*32-1:0] r_inc;
    reg [2*16-1:0] r_i0;
    reg [2*AW-1:0] r_bb, r_sym;
    generate
        for (g = 0; g < 2; g = g + 1) begin : g_lane
            always @(posedge clk) begin
                if (we_lane[4*g+0]) r_inc[32*g +: 32] <= d2;
                if (we_lane[4*g+1]) r_i0[16*g +: 16]  <= d2[15:0];
                if (we_lane[4*g+2]) r_bb[AW*g +: AW]  <= d2[AW-1:0];
                if (we_lane[4*g+3]) r_sym[AW*g +: AW] <= d2[AW-1:0];
            end
        end
    endgenerate
    // A command write latches its parameters and, one clock later, pulses the start (sync_go, cand_go).
    always @(posedge clk) begin
        sync_go <= we_sync_cmd && !rst;
        cand_go <= we_cand_cmd && !rst;
        if (we_sync_cmd) begin
            r_sync_rx   <= d2[`FT8_SYNC_CMD_RX_LSB +: 3];
            r_sync_rows <= d2[`FT8_SYNC_CMD_ROWS_LSB +: 9];
        end
        if (we_cand_cmd) begin
            r_cand_pass2 <= d2[`FT8_CAND_CMD_PASS2_LSB];
            r_cand_lanes <= d2[`FT8_CAND_CMD_LANES_LSB +: 2];
        end
        if (we_cand_cap)   r_cand_cap   <= d2[AW-1:0];
        if (we_cand_first) r_cand_first <= d2;
        if (rst) begin
            r_sync_rx <= 3'd0; r_sync_rows <= 9'd0; r_cand_pass2 <= 1'b0; r_cand_lanes <= 2'd0;
        end
    end

    // ---- second pass (docs/FT8_PASS2.md): replay of residual audio, then its sync search.
    // p2_cmd starts the spectrogram engine's replay channel, the replay's last frame starts the sync engine's
    // residual search, and the end of that search is the p2_done event.  A p2_cmd while one is running is ignored.
    reg [2:0]    r_p2_rx;
    // One base for the three buffers of the second pass (registers are the chip's scarce resource): the area is
    // aligned to 2^19 lane words, so only the upper bits are kept and the three addresses are those bits over a
    // constant: audio + 0, spectrogram + 0x1_0000, records + 0x4_0000.
    reg  [AW-1:19] r_p2_hi;
    wire [AW-1:0]  p2_audio = {r_p2_hi, 19'h0_0000};
    wire [AW-1:0]  p2_spec  = {r_p2_hi, 19'h1_0000};
    wire [AW-1:0]  p2_rec   = {r_p2_hi, 19'h4_0000};
    reg [4:0]    r_p2_sh;
    reg          p2_go, p2_busy;
    wire         rp_done_w, rp_busy_w;
    wire [8:0]   rp_frame_w;
    wire         p2_sync_done;
    always @(posedge clk) begin
        p2_go <= we_p2_cmd && !p2_busy && !rst;
        if (we_p2_cmd && !p2_busy) r_p2_rx <= d2[`FT8_P2_CMD_RX_LSB +: 3];
        if (we_p2_base) r_p2_hi <= d2[AW-1:19];
        // the receiver's power shift, picked one clock after the command (nothing reads it sooner)
        r_p2_sh <= r_sh[5*r_p2_rx +: 5];
        if (rst) begin
            p2_busy <= 1'b0;
            r_p2_rx <= 3'd0;
        end else if (we_p2_cmd) p2_busy <= 1'b1;
        else if (p2_sync_done) p2_busy <= 1'b0;
    end

    // ================================================================ engines
    // Slot capture and spectrogram engine: the slot capture and spectrogram ring write clients, the replay
    // read client, and its status outputs (capture write pointers per receiver, frame pointers, interrupt).
    // ---- slot capture and spectrogram engine (ft8_spectrogram.v)
    wire [NUM_RX*32-1:0] cap_wr_ptr;
    wire [NUM_RX*9-1:0]  frame_ptr;
    wire                 cap_overflow, spec_busy;
    wire                 s_wreq, s_wgnt, s_wdone;        // slot capture
    wire [AW-1:0]        s_waddr;
    wire [7:0]           s_wburst, s_wmask;
    wire [63:0]          s_wdata;
    wire                 g_wreq, g_wgnt, g_wdone;        // spectrogram ring
    wire [AW-1:0]        g_waddr;
    wire [7:0]           g_wburst, g_wmask;
    wire [63:0]          g_wdata;
    wire                 s_rreq, s_rgnt, s_rvalid, s_rdone;
    wire [AW-1:0]        s_raddr;
    wire [7:0]           s_rburst;
    wire [63:0]          s_rdata;
    wire                 spec_irq;
    wire [2:0]           spec_irq_rx;
    wire [8:0]           spec_irq_frame;

    // Audio input registered, with the I/Q words dropped: only receiver audio goes into the front end.
    reg        au_v;
    reg [2:0]  au_rx;
    reg [15:0] au_s;
    always @(posedge clk) begin
        au_v  <= audio_valid && !audio_iq && !rst;
        au_rx <= audio_rx;
        au_s  <= audio_sample;
    end

    ft8_spectrogram #(.NUM_RX(NUM_RX), .ADDR_WIDTH(AW), .CFG_EXT(1)) u_spec (
        .clk(clk), .rst(rst),
        .audio_valid(au_v), .audio_rx(au_rx), .audio_sample(au_s),
        .enable(r_enable), .pwr_shift(r_sh), .cap_ring_base({(NUM_RX*AW){1'b0}}),
        .spec_ring_base({(NUM_RX*AW){1'b0}}), .slot_boundary_ptr(r_boundary), .slot_start(slot_start),
        .cfg_rx(spec_cfg_rx), .cfg_bases({capb_spec, specb_spec}),
        .cap_cfg_rx(cap_cfg_rx), .cap_cfg_base(capb_cap),
        .cap_wr_ptr(cap_wr_ptr), .frame_ptr(frame_ptr), .cap_overflow(cap_overflow),
        .engine_busy(spec_busy),
        .rp_start(p2_go), .rp_cap_base(p2_audio), .rp_spec_base(p2_spec), .rp_sh(r_p2_sh),
        .rp_frame(rp_frame_w), .rp_busy(rp_busy_w), .rp_done(rp_done_w),
        .capw_req(s_wreq), .capw_addr(s_waddr), .capw_burstlen(s_wburst), .capw_wdata(s_wdata),
        .capw_wmask(s_wmask), .capw_gnt(s_wgnt), .capw_done(s_wdone),
        .ringw_req(g_wreq), .ringw_addr(g_waddr), .ringw_burstlen(g_wburst), .ringw_wdata(g_wdata),
        .ringw_wmask(g_wmask), .ringw_gnt(g_wgnt), .ringw_done(g_wdone),
        .rd_req(s_rreq), .rd_addr_o(s_raddr), .rd_burstlen(s_rburst), .rd_gnt(s_rgnt),
        .rd_rvalid(s_rvalid), .rd_rdata(s_rdata), .rd_rdone(s_rdone),
        .irq(spec_irq), .irq_rx(spec_irq_rx), .irq_frame(spec_irq_frame)
    );

    // ---- sync search (ft8_sync.v): reads spectrogram windows, writes records.
    // ---- sync search engine (ft8_sync.v)
    wire          sync_busy, sync_irq;
    wire [2:0]    sync_irq_rx;
    wire [8:0]    sync_irq_rows;
    wire          sync_irq_alt;
    assign p2_sync_done = sync_irq && sync_irq_alt;
    wire [31:0]   sync_clocks;
    wire          y_wreq, y_wgnt, y_wdone;
    wire [AW-1:0] y_waddr;
    wire [7:0]    y_wburst, y_wmask;
    wire [63:0]   y_wdata;
    wire          y_rreq, y_rgnt, y_rvalid, y_rdone;
    wire [AW-1:0] y_raddr;
    wire [7:0]    y_rburst;
    wire [63:0]   y_rdata;

    ft8_sync #(.NUM_RX(NUM_RX), .ADDR_WIDTH(AW), .CFG_EXT(1)) u_sync (
        .clk(clk), .rst(rst),
        .spec_ring_base({(NUM_RX*AW){1'b0}}), .rec_base({(NUM_RX*AW){1'b0}}),
        .cfg_rx(sync_cfg_rx), .cfg_bases({specb_sync, recb_sync}), .band_ia(r_ia), .band_ib(r_ib),
        .trig1(r_trig1), .trig2(r_trig2), .frame_ptr(frame_ptr), .slot_start(slot_start),
        .cmd_start(sync_go), .cmd_rx(r_sync_rx), .cmd_rows(r_sync_rows),
        .alt_start(rp_done_w), .alt_rx(r_p2_rx), .alt_spec_base(p2_spec), .alt_rec_base(p2_rec),
        .busy(sync_busy), .irq(sync_irq), .irq_rx(sync_irq_rx), .irq_rows(sync_irq_rows),
        .irq_alt(sync_irq_alt),
        .run_clocks(sync_clocks),
        .rd_req(y_rreq), .rd_addr(y_raddr), .rd_burstlen(y_rburst), .rd_gnt(y_rgnt),
        .rd_rvalid(y_rvalid), .rd_rdata(y_rdata), .rd_done(y_rdone),
        .wr_req(y_wreq), .wr_addr(y_waddr), .wr_burstlen(y_wburst), .wr_wdata(y_wdata),
        .wr_wmask(y_wmask), .wr_gnt(y_wgnt), .wr_done(y_wdone)
    );

    // ---- candidate engine (ft8_cand.v): reads the slot audio and its own baseband, writes basebands and soft symbols.
    // ---- candidate engine (ft8_cand.v)
    wire          cand_busy, cand_irq;
    wire [31:0]   cand_clocks;
    wire          c_wreq, c_wgnt, c_wdone;
    wire [AW-1:0] c_waddr;
    wire [7:0]    c_wburst, c_wmask;
    wire [63:0]   c_wdata;
    wire          c_rreq, c_rgnt, c_rvalid, c_rdone;
    wire [AW-1:0] c_raddr;
    wire [7:0]    c_rburst;
    wire [63:0]   c_rdata;

    ft8_cand #(.ADDR_WIDTH(AW), .LANES(CAND_LANES)) u_cand (
        .clk(clk), .rst(rst),
        .cmd_start(cand_go), .cmd_pass2(r_cand_pass2), .cmd_lanes(r_cand_lanes),
        .cap_ring_base(r_cand_cap), .slot_first_sample(r_cand_first),
        .lane_inc(r_inc), .lane_i0(r_i0), .lane_bb_base(r_bb), .lane_sym_base(r_sym),
        .busy(cand_busy), .irq(cand_irq), .run_clocks(cand_clocks),
        .rd_req(c_rreq), .rd_addr(c_raddr), .rd_burstlen(c_rburst), .rd_gnt(c_rgnt),
        .rd_rvalid(c_rvalid), .rd_rdata(c_rdata), .rd_done(c_rdone),
        .wr_req(c_wreq), .wr_addr(c_waddr), .wr_burstlen(c_wburst), .wr_wdata(c_wdata),
        .wr_wmask(c_wmask), .wr_gnt(c_wgnt), .wr_done(c_wdone)
    );

    // ================================================================ DDR3 lane shares
    // read lane share: spectrogram reader first, then the sync search, then the candidate engine (a fixed priority
    // chosen so that the engine that needs data in real time comes first).  The three clients share one data bus,
    // so each only sees its own rvalid and done.
    assign s_rdata = rd_rdata;
    assign y_rdata = rd_rdata;
    assign c_rdata = rd_rdata;
    ft8_ddr3_rmux3 #(.ADDR_WIDTH(AW)) u_rmux (
        .clk(clk), .rst(rst),
        .c_req({c_rreq, y_rreq, s_rreq}), .c_addr({c_raddr, y_raddr, s_raddr}),
        .c_burstlen({c_rburst, y_rburst, s_rburst}),
        .c_gnt({c_rgnt, y_rgnt, s_rgnt}), .c_rvalid({c_rvalid, y_rvalid, s_rvalid}),
        .c_done({c_rdone, y_rdone, s_rdone}),
        .req(rd_req), .addr(rd_addr_i), .burstlen(rd_burstlen), .gnt(rd_gnt), .rvalid(rd_rvalid),
        .done(rd_done)
    );

    // write lane share: slot capture (the audio must never be lost), then the spectrogram ring, the sync records and the
    // candidate engine, in that order of priority.
    wire          wm_req, wm_gnt, wm_done;
    wire [AW-1:0] wm_addr;
    wire [7:0]    wm_burstlen, wm_wmask;
    wire [63:0]   wm_wdata;
    ft8_ddr3_wmux4 #(.ADDR_WIDTH(AW)) u_wmux (
        .clk(clk), .rst(rst),
        .c_req({c_wreq, y_wreq, g_wreq, s_wreq}), .c_addr({c_waddr, y_waddr, g_waddr, s_waddr}),
        .c_burstlen({c_wburst, y_wburst, g_wburst, s_wburst}),
        .c_wdata({c_wdata, y_wdata, g_wdata, s_wdata}), .c_wmask({c_wmask, y_wmask, g_wmask, s_wmask}),
        .c_gnt({c_wgnt, y_wgnt, g_wgnt, s_wgnt}), .c_done({c_wdone, y_wdone, g_wdone, s_wdone}),
        .req(wm_req), .addr(wm_addr), .burstlen(wm_burstlen), .wdata(wm_wdata), .wmask(wm_wmask),
        .gnt(wm_gnt), .done(wm_done)
    );
    // A register stage between the mux and the chip's write arbiter (docs/ROUTE_CAUSE.md section 6, row 1), so that the
    // arbiter's grant comes from registers next to the mux and not from the DDR3 lane's wait.
    ft8_wr_stage #(.ADDR_WIDTH(AW)) u_wstage (
        .clk(clk), .rst(rst),
        .m_req(wm_req), .m_addr(wm_addr), .m_burstlen(wm_burstlen), .m_wdata(wm_wdata), .m_wmask(wm_wmask),
        .m_gnt(wm_gnt), .m_done(wm_done),
        .req(wr_req), .addr(wr_addr_i), .burstlen(wr_burstlen), .wdata(wr_wdata), .wmask(wr_wmask),
        .gnt(wr_gnt), .done(wr_done)
    );

    // ================================================================ events and interrupt
    // Status bits of irq_status: 7:0 sync_done per receiver, 8 cand_done, 9 frame (a new spectrogram line is in
    // DDR3), 10 p2_done.  `ev` is the one-clock event each source raises, st_irq the sticky status, en_irq the enable.
    reg [10:0]         st_irq, en_irq;      // {p2_done, frame, cand_done, sync_done[7:0]}
    reg [NUM_RX*9-1:0] sync_rows;
    reg [10:0]         ev;
    integer e;
    always @(posedge clk) begin
        // The residual's search is not the receiver's own: it sets p2_done and not sync_done.
        for (e = 0; e < NUM_RX; e = e + 1) begin
            ev[e] <= sync_irq && !sync_irq_alt && (sync_irq_rx == e);
            if (sync_irq && !sync_irq_alt && (sync_irq_rx == e)) sync_rows[9*e +: 9] <= sync_irq_rows;
        end
        for (e = NUM_RX; e < 8; e = e + 1)      // sync_done of the receivers that are not built
            ev[e] <= 1'b0;
        ev[8]  <= cand_irq;
        ev[9]  <= spec_irq;
        ev[10] <= p2_sync_done;
        if (rst) begin
            st_irq <= 11'd0;
            en_irq <= 11'd0;
            irq    <= 1'b0;
        end else begin
            // an event in the clock of a clear stays set, so none is lost
            st_irq <= (st_irq & ~(we_irq_clr ? d2[10:0] : 11'd0)) | ev;
            if (we_irq_en) en_irq <= d2[10:0];
            irq <= |(st_irq & en_irq);
        end
    end

    // ================================================================ register read side
    // a1 holds the address (the bus holds it through the read).  Stage A: each receiver's word and the word of the
    // global page; stage B: the receiver; stage C: bus_rdata.  Reads have no side effects.

    reg [31:0]  rxw [0:7];
    reg [31:0]  glob;
    reg [31:0]  rx_sel;
    reg [31:0]  glob_b;
    reg         is_rx_a, is_rx_b, is_glob_a, is_glob_b;
    reg [2:0]   rxi_a;
    generate
        for (g = NUM_RX; g < 8; g = g + 1) begin : g_rd_off      // receivers that are not built read 0
            always @(posedge clk) rxw[g] <= 32'd0;
        end
        for (g = 0; g < NUM_RX; g = g + 1) begin : g_rd
            always @(posedge clk) begin
                case (a_rxr)
                    4'd0: rxw[g] <= {19'd0, r_sh[5*g +: 5], 7'd0, r_enable[g]};
                    // the bases: the addressed receiver's (the only word of these that is then picked)
                    4'd1: rxw[g] <= capb_bus;
                    4'd2: rxw[g] <= specb_bus;
                    4'd3: rxw[g] <= r_boundary[32*g +: 32];
                    4'd4: rxw[g] <= recb_bus;
                    4'd5: rxw[g] <= {6'd0, r_ib[10*g +: 10], 6'd0, r_ia[10*g +: 10]};
                    4'd6: rxw[g] <= {7'd0, r_trig2[9*g +: 9], 7'd0, r_trig1[9*g +: 9]};
                    4'd7: rxw[g] <= cap_wr_ptr[32*g +: 32];
                    4'd8: rxw[g] <= {23'd0, frame_ptr[9*g +: 9]};
                    4'd9: rxw[g] <= {23'd0, sync_rows[9*g +: 9]};
                    default: rxw[g] <= 32'd0;
                endcase
            end
        end
    endgenerate
    always @(posedge clk) begin
        case (a1[7:2])
            6'h00: glob <= `FT8_ID_RESET;
            6'h01: glob <= {21'd0, st_irq};
            6'h02: glob <= {21'd0, en_irq};
            6'h03: glob <= {27'd0, p2_busy, cap_overflow, cand_busy, sync_busy, spec_busy};
            6'h04: glob <= {15'd0, spec_irq_frame, 5'd0, spec_irq_rx};
            6'h05: glob <= {15'd0, r_sync_rows, 5'd0, r_sync_rx};
            6'h06: glob <= sync_clocks;
            6'h07: glob <= {23'd0, rp_frame_w};
            6'h0C: glob <= {29'd0, r_p2_rx};
            6'h0D: glob <= p2_audio;
            6'h08: glob <= {29'd0, r_cand_lanes, r_cand_pass2};
            6'h09: glob <= r_cand_cap;
            6'h0A: glob <= r_cand_first;
            6'h0B: glob <= cand_clocks;
            6'h10: glob <= r_inc[31:0];
            6'h11: glob <= {16'd0, r_i0[15:0]};
            6'h12: glob <= r_bb[AW-1:0];
            6'h13: glob <= r_sym[AW-1:0];
            6'h14: glob <= r_inc[63:32];
            6'h15: glob <= {16'd0, r_i0[31:16]};
            6'h16: glob <= r_bb[2*AW-1:AW];
            6'h17: glob <= r_sym[2*AW-1:AW];
            default: glob <= 32'd0;
        endcase
        is_rx_a   <= a_rx;
        is_glob_a <= a_glob;
        rxi_a     <= a_rxi;
        rx_sel    <= rxw[rxi_a];
        glob_b    <= glob;
        is_rx_b   <= is_rx_a;
        is_glob_b <= is_glob_a;
        bus_rdata <= is_rx_b ? rx_sel : is_glob_b ? glob_b : 32'd0;
    end

    // bus_rd is not needed: no register has a read side effect
    wire unused = bus_rd | rp_busy_w;

endmodule
