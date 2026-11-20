// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// rx_bank: N independent receivers that listen to the same ADC stream, each tuned to its own
// frequency and its own output rate, with all of their results put onto one shared output stream
// that carries the number of the receiver it belongs to. Any signal in the 0 to 38.4 MHz range
// the Hermes-Lite 2 digitizes can be listened to by any receiver, and the receivers do not
// disturb each other. The terms used here (mixer, CIC, FIR, decimation, round robin) are
// explained in docs/learn/GLOSSARY.md.
//
// Where it sits: its input is the 12-bit sample stream with a valid strobe that the HL2 link
// delivers (gap filling already done, so every valid pulse is a sample of Hermes-Lite 2 time,
// 76.8 million per second on average). Its output goes to the IQ writer, which puts the samples
// in DDR3, and to the receiver back end (rtl/rx_backend), which does the channel filter and the
// demodulation. The firmware tunes each receiver through a small register write port.
//
// The chain of every receiver and the sample rate after each stage:
//   rx_channel.v   NCO mixer (nco_mixer.v): 76.8 Msps in, complex 18-bit out at the same rate
//                  fixed CIC decimate by 10:  76.8 Msps -> 7.68 Msps, 16 bits
//   cic_var_shared.v  variable CIC, 5 stages, decimate by 40, 20, 10 or 5:
//                  7.68 Msps -> 192, 384, 768 or 1,536 ksps, 16 bits
//   fir_decim.v    65-tap FIR, decimate by 4:  -> 48, 96, 192 or 384 ksps, 24 bits
// The three decimation factors multiply to 10 x {40,20,10,5} x 4 = {1600,800,400,200}, which is
// exactly 76.8 MHz divided by the output rate for all four settings, so the output rate is
// locked to the HL2's clock and not to ours.
//
// What is shared between receivers, and why: the mixer and the fixed CIC are per receiver. The
// variable CIC is built as one time-shared arithmetic engine per group of up to 4 receivers
// (I and Q of each, so 8 contexts per engine) instead of one dedicated filter per receiver,
// and the FIR's delay line is a circular buffer in a block RAM that two receivers share. This is
// what lets 8 receivers fit with a single multiplier per FIR and a few block RAMs.
//
// The shared output stream: all receivers' results leave on one bus (out_valid, out_index,
// out_i, out_q) and not on one bus each. Everything behind the bank (the IQ writer, the back end)
// handles one stream anyway, so N parallel buses would only move the serialization downstream.
// A new result of any one receiver is at least 200 clocks after its last (even at 384 ksps),
// and the arbiter needs at most N clocks to empty a collision of all receivers, so one holding
// register per receiver is all the queue that is ever needed.
//
// Register write port (simple synchronous, one write per clock):
//   reg_addr[ADDR_W-1:REG_BITS]   = channel index (0..N-1)
//   reg_addr[REG_BITS-1:0]        = 0 -> phase_inc (32-bit NCO frequency word)
//                                    1 -> control {30'b0, enable, rate_sel[1:0]}
//   reg_wdata[31:0], reg_wr pulses one clock per write.
// phase_inc is round(f_Hz / 76.8e6 x 2^32), signed, relative to the HL2's ADC clock. The control
// word holds enable in bit 2 and rate_sel in bits 1:0 (0 = 48 ksps, 1 = 96, 2 = 192, 3 = 384).
// A disabled receiver is held in reset, so it starts clean when it is enabled again.
//
// Timing structure: the control nets of the bank are registers with few loads, because at the
// DSP clock rate a net with hundreds of loads is too slow.
//   - Register write port: the write is decoded and registered in one clock, and the write
//     enables are three kept copies per register word. The reset is done by writing zero
//     through the same port. A register write takes effect 1 clock after reg_wr.
//   - The output arbiter picks the receiver in round-robin order (the pointer is held as a
//     thermometer mask), ends in a one-hot register and reads the FIR output registers one clock
//     later (they only change once per pass, which is at least 200 clocks). The word leaves 1
//     clock after the decision.
//   - rx_channel's reset output is four kept copies (see there); the reset reaching this module
//     reaches the channels, the registers and the arbiter through rx_fan copies, 2 clocks later.

module rx_bank #(
  parameter N          = 8,                  // number of receivers (4 in the target chip with the zoom, 8 without it)
  parameter ADC_WIDTH  = 12,                 // bits of one ADC sample
  parameter FIR_COEFF_FILE = "rtl/rx/fir_coeffs.hex" // repo-root relative, like nco_mixer; gowin/res.sh runs rx_bank on the default
)(
  input                       clock,        // DSP clock (120 MHz); the ADC samples arrive qualified by adc_valid
  input                       rst,          // synchronous reset

  input      [ADC_WIDTH-1:0]  adc_data,     // ADC sample, two's complement, shared by all receivers
  input                       adc_valid,    // one-clock pulse per sample (average 76.8 M per second, may come in bursts)

  // register write port: reg_addr[0] = 0 -> phase_inc, 1 -> control;
  // reg_addr[IDX_W:1] = channel index
  input                       reg_wr,       // one-clock write strobe
  input      [$clog2(N>1?N:2):0] reg_addr,  // {receiver number, 0 = phase_inc / 1 = control}
  input      [31:0]           reg_wdata,    // value written

  // shared output IQ stream
  output reg                  out_valid,    // one-clock pulse: a new output sample of receiver out_index
  output reg [$clog2(N>1?N:2)-1:0] out_index,   // which receiver the sample belongs to
  output reg signed [23:0]    out_i,        // I, 24 bits wide, on the scale of the CIC output (the FIR has unity DC gain)
  output reg signed [23:0]    out_q         // Q
) /* synthesis syn_maxfan = 10000 syn_srlstyle = "registers" */;

localparam IDX_W = (N <= 1) ? 1 : $clog2(N);   // bits needed to number the receivers

// ---------------------------------------------------------------------
// reset copies: 0..2 the write data, 3 the write enables, 4 the channels, 5 the arbiter and outputs
// ---------------------------------------------------------------------
wire [5:0] rbf;
rx_fan #(.N(6), .PER(10), .INIT(1'b1)) u_rstfan (.clock(clock), .d(rst), .q(rbf));
wire [N-1:0] rchf;   // one reset copy per channel
rx_fan #(.N(N), .PER(10), .INIT(1'b1)) u_rstchan (.clock(clock), .d(rst), .q(rchf));

// ---------------------------------------------------------------------
// per-channel configuration registers. Stage 1 registers the decoded write (and the data, zero
// while reset); stage 2 is the register itself.
// ---------------------------------------------------------------------
reg [31:0]    wd_q;
reg [3*N-1:0] we_p;   // three kept copies of "phase_inc of channel n is written"
reg [3*N-1:0] we_c;   // the same for the control word
initial begin wd_q = 32'd0; we_p = {3*N{1'b1}}; we_c = {3*N{1'b1}}; end

genvar gi;
generate
  for (gi = 0; gi < N; gi = gi + 1) begin : wdec
    wire hit_p = reg_wr & ~reg_addr[0] & (reg_addr[IDX_W:1] == gi);
    wire hit_c = reg_wr &  reg_addr[0] & (reg_addr[IDX_W:1] == gi);
    always @(posedge clock) begin
      we_p[3*gi +: 3] <= {3{hit_p | rbf[3]}};
      we_c[3*gi +: 3] <= {3{hit_c | rbf[3]}};
    end
  end
endgenerate
// The write data is registered in three slices (each with its own reset copy), and zero while
// reset is active, so a reset clears the configuration by writing zero everywhere.
always @(posedge clock) begin
  wd_q[10:0]  <= rbf[0] ? 11'd0 : reg_wdata[10:0];
  wd_q[21:11] <= rbf[1] ? 11'd0 : reg_wdata[21:11];
  wd_q[31:22] <= rbf[2] ? 10'd0 : reg_wdata[31:22];
end

wire [6*N-1:0]     decim_flat;
wire signed [31:0] phase_inc [0:N-1];
wire [1:0]         rate_sel  [0:N-1];
wire               ch_enable [0:N-1];
generate
  for (gi = 0; gi < N; gi = gi + 1) begin : cfg
    reg [31:0] pi_r = 32'd0;   // phase increment of this receiver
    reg [1:0]  rs_r = 2'd0;    // rate select
    reg        en_r = 1'b0;    // enable
    always @(posedge clock) begin
      if (we_p[3*gi])   pi_r[10:0]  <= wd_q[10:0];
      if (we_p[3*gi+1]) pi_r[21:11] <= wd_q[21:11];
      if (we_p[3*gi+2]) pi_r[31:22] <= wd_q[31:22];
      if (we_c[3*gi]) begin
        rs_r <= wd_q[1:0];
        en_r <= wd_q[2];
      end
    end
    assign phase_inc[gi] = pi_r;
    assign rate_sel[gi]  = rs_r;
    assign ch_enable[gi] = en_r;
    // decimation value for the shared variable CIC: the rate select 0..3 (48 to 384 ksps) maps to
    // 40, 20, 10, 5, because the FIR after it always takes a further factor of 4.
    // A continuous assignment: the always @(*) over the rate_sel array this replaces was not
    // re-evaluated when rate_sel stayed 0 (48 ksps), and the decimation stayed X in the whole core.
    assign decim_flat[6*gi +: 6] = (rs_r == 2'd0) ? 6'd40 :   // 48 ksps
                                   (rs_r == 2'd1) ? 6'd20 :   // 96 ksps
                                   (rs_r == 2'd2) ? 6'd10 :   // 192 ksps
                                                    6'd5;     // 384 ksps
  end
endgenerate

// ---------------------------------------------------------------------
// front ends: NCO mixer + fixed CIC, one per receiver. Each one has its own phase increment and
// enable, and all of them read the same adc_data.
// ---------------------------------------------------------------------
wire                  cic1_strobe [0:N-1];
wire signed [15:0]    cic1_i      [0:N-1];
wire signed [15:0]    cic1_q      [0:N-1];
wire [3:0]            chan_rst    [0:N-1];

generate
  for (gi = 0; gi < N; gi = gi + 1) begin : rx
    rx_channel #(
      .ADC_WIDTH(ADC_WIDTH)
    ) u_rx (
      .clock      (clock),
      .rst        (rchf[gi]),
      .adc_data   (adc_data),
      .adc_valid  (adc_valid),
      .phase_inc  (phase_inc[gi]),
      .enable     (ch_enable[gi]),
      .cic1_strobe(cic1_strobe[gi]),
      .cic1_i     (cic1_i[gi]),
      .cic1_q     (cic1_q[gi]),
      .chan_rst   (chan_rst[gi])
    );
  end
endgenerate

// ---------------------------------------------------------------------
// shared variable-CIC engines: one per group of up to 4 receivers (8 contexts: I, Q of each).
// ---------------------------------------------------------------------
wire signed [15:0] cic2_i      [0:N-1];
wire signed [15:0] cic2_q      [0:N-1];
wire               cic2_strobe [0:N-1]; // I and Q strobes are always coincident (shared context group)

localparam CIC_GROUP_MAX = 4;                                       // receivers per engine
localparam NCICGRP = (N + CIC_GROUP_MAX - 1) / CIC_GROUP_MAX;       // number of engines

genvar gg, gr;
generate
  for (gg = 0; gg < NCICGRP; gg = gg + 1) begin : cicgrp
    localparam integer G_START = gg * CIC_GROUP_MAX;
    localparam integer G_SIZE  = ((G_START + CIC_GROUP_MAX) <= N) ? CIC_GROUP_MAX : (N - G_START);
    localparam integer G_NCTX  = 2 * G_SIZE;

    wire [G_NCTX-1:0]          g_rst;
    wire [G_NCTX-1:0]          g_in_strobe;
    wire signed [16*G_NCTX-1:0] g_in_data_flat;
    wire [6*G_NCTX-1:0]         g_decim_flat;
    wire [G_NCTX-1:0]          g_out_strobe;
    wire signed [16*G_NCTX-1:0] g_out_data_flat;

    for (gr = 0; gr < G_SIZE; gr = gr + 1) begin : ctxwire
      // context 2*gr = I of receiver (G_START+gr), 2*gr+1 = Q
      assign g_rst[2*gr]         = chan_rst[G_START+gr][1];
      assign g_rst[2*gr+1]       = chan_rst[G_START+gr][2];
      assign g_in_strobe[2*gr]   = cic1_strobe[G_START+gr];
      assign g_in_strobe[2*gr+1] = cic1_strobe[G_START+gr];
      assign g_in_data_flat[(2*gr)*16 +: 16]   = cic1_i[G_START+gr];
      assign g_in_data_flat[(2*gr+1)*16 +: 16] = cic1_q[G_START+gr];
      assign g_decim_flat[(2*gr)*6 +: 6]       = decim_flat[(G_START+gr)*6 +: 6];
      assign g_decim_flat[(2*gr+1)*6 +: 6]     = decim_flat[(G_START+gr)*6 +: 6];
      assign cic2_i[G_START+gr]      = g_out_data_flat[(2*gr)*16 +: 16];
      assign cic2_q[G_START+gr]      = g_out_data_flat[(2*gr+1)*16 +: 16];
      assign cic2_strobe[G_START+gr] = g_out_strobe[2*gr];
    end

    cic_var_shared #(
      .NCTX(G_NCTX), .STAGES(5), .IN_WIDTH(16), .ACC_WIDTH(43), .OUT_WIDTH(16)
    ) u_cic2 (
      .clock          (clock),
      .rst_all        (rbf[5]),
      .rst            (g_rst),
      .in_strobe      (g_in_strobe),
      .in_data_flat   (g_in_data_flat),
      .decimation_flat(g_decim_flat),
      .out_strobe     (g_out_strobe),
      .out_data_flat  (g_out_data_flat)
    );
  end
endgenerate

// ---------------------------------------------------------------------
// compensating FIR, one per receiver. Its circular-buffer delay line (see fir_decim.v) lives in
// a shared fir_delay_ram2 block, two receivers to a block, instead of a private memory per
// receiver.
// ---------------------------------------------------------------------
localparam FIR_RING_DEPTH = 128;                  // slots per receiver ring, a power of two above the 65 taps
localparam FIR_RAW        = $clog2(FIR_RING_DEPTH);

wire                  ch_valid [0:N-1];
wire signed [23:0]    ch_i     [0:N-1];
wire signed [23:0]    ch_q     [0:N-1];

wire                  fir_ram_wr    [0:N-1];
wire [FIR_RAW-1:0]    fir_ram_waddr [0:N-1];
wire [31:0]           fir_ram_wdata [0:N-1];
wire [FIR_RAW-1:0]    fir_ram_raddr [0:N-1];
wire [31:0]           fir_ram_rdata [0:N-1];

genvar fp;
generate
  for (gi = 0; gi < N; gi = gi + 1) begin : firs
    fir_decim #(
      .TAPS(65), .DECIM(4), .IN_WIDTH(16), .COEFF_WIDTH(20), .OUT_WIDTH(24),
      .COEFF_FILE(FIR_COEFF_FILE), .RING_DEPTH(FIR_RING_DEPTH)
    ) u_fir (
      .clock(clock), .rst(chan_rst[gi][0]),
      .in_strobe(cic2_strobe[gi]),
      .in_i(cic2_i[gi]), .in_q(cic2_q[gi]),
      .out_strobe(ch_valid[gi]),
      .out_i(ch_i[gi]), .out_q(ch_q[gi]),
      .ram_wr(fir_ram_wr[gi]), .ram_waddr(fir_ram_waddr[gi]), .ram_wdata(fir_ram_wdata[gi]),
      .ram_raddr(fir_ram_raddr[gi]), .ram_rdata(fir_ram_rdata[gi])
    );
  end
  // one shared dual-port ring per pair of receivers; an odd leftover receiver (N odd) gets a
  // block to itself with port B unused.
  for (fp = 0; fp < N; fp = fp + 2) begin : firpair
    if (fp + 1 < N) begin : paired
      fir_delay_ram2 #(.RING_DEPTH(FIR_RING_DEPTH), .WORD_W(32)) u_ram (
        .clock(clock),
        .wr_a(fir_ram_wr[fp]), .waddr_a(fir_ram_waddr[fp]), .wdata_a(fir_ram_wdata[fp]),
        .raddr_a(fir_ram_raddr[fp]), .rdata_a(fir_ram_rdata[fp]),
        .wr_b(fir_ram_wr[fp+1]), .waddr_b(fir_ram_waddr[fp+1]), .wdata_b(fir_ram_wdata[fp+1]),
        .raddr_b(fir_ram_raddr[fp+1]), .rdata_b(fir_ram_rdata[fp+1])
      );
    end else begin : lone
      fir_delay_ram2 #(.RING_DEPTH(FIR_RING_DEPTH), .WORD_W(32)) u_ram (
        .clock(clock),
        .wr_a(fir_ram_wr[fp]), .waddr_a(fir_ram_waddr[fp]), .wdata_a(fir_ram_wdata[fp]),
        .raddr_a(fir_ram_raddr[fp]), .rdata_a(fir_ram_rdata[fp]),
        .wr_b(1'b0), .waddr_b({FIR_RAW{1'b0}}), .wdata_b(32'd0),
        .raddr_b({FIR_RAW{1'b0}}), .rdata_b()
      );
    end
  end
endgenerate

// ---------------------------------------------------------------------
// round-robin arbiter onto the shared bus. Stage A decides (pending flags and the thermometer mask
// of "index >= pointer" give the receiver at or after the pointer) and
// ends in a one-hot register; stage B reads the FIR output registers (stable between passes).
// ---------------------------------------------------------------------
// Round robin means that the receiver after the one served last gets the next turn, so that no
// receiver can be starved by a lower numbered one. pend_valid[c] says receiver c has a new
// output word waiting. ge_mask[c] marks the receivers at or after the pointer. Only one receiver
// per clock is granted.
reg  [N-1:0] pend_valid;
reg  [N-1:0] ge_mask;        // ge_mask[c] = (c >= rr_ptr), rr_ptr = last grant + 1 (mod N)
reg  [N-1:0] g_oh;           // stage A result, one-hot
reg  [IDX_W-1:0] g_idx;
reg          g_v;
initial begin pend_valid = {N{1'b0}}; ge_mask = {N{1'b1}}; g_oh = {N{1'b0}}; g_idx = {IDX_W{1'b0}}; g_v = 1'b0; end

wire [N-1:0] chv;
wire [24*N-1:0] chi_f, chq_f;   // the FIR outputs as flat vectors (always @(*) over wire arrays can miss events)
generate
  for (gi = 0; gi < N; gi = gi + 1) begin : chvw
    assign chv[gi] = ch_valid[gi];
    assign chi_f[24*gi +: 24] = ch_i[gi];
    assign chq_f[24*gi +: 24] = ch_q[gi];
  end
endgenerate

// both candidates in parallel (the lowest pending index at or after the pointer, and the lowest
// pending index of all), selected last: the selection no longer sits in front of the prefix OR
wire [N-1:0] hi_req  = pend_valid & ge_mask;
wire         use_hi  = |hi_req;
wire [N-1:0] low_hi, low_lo;   // a lower index is requesting
generate
  for (gi = 0; gi < N; gi = gi + 1) begin : lowa
    if (gi == 0) begin : first
      assign low_hi[gi] = 1'b0;
      assign low_lo[gi] = 1'b0;
    end else begin : more
      assign low_hi[gi] = |hi_req[gi-1:0];
      assign low_lo[gi] = |pend_valid[gi-1:0];
    end
  end
endgenerate
wire [N-1:0] g_hi  = hi_req & ~low_hi;
wire [N-1:0] g_lo  = pend_valid & ~low_lo;
wire [N-1:0] g_n   = use_hi ? g_hi : g_lo;
wire         found = |pend_valid;

reg [IDX_W-1:0] g_idx_n;
integer ei;
always @(*) begin
  g_idx_n = {IDX_W{1'b0}};
  for (ei = 0; ei < N; ei = ei + 1)
    if (g_n[ei]) g_idx_n = g_idx_n | ei[IDX_W-1:0];
end

// the mask after a grant at index k is (c > k), or all ones when k was the last receiver
wire [N-1:0] mask_n;
generate
  for (gi = 0; gi < N; gi = gi + 1) begin : maskn
    if (gi == 0) begin : first
      assign mask_n[gi] = g_n[N-1];
    end else begin : more
      assign mask_n[gi] = (|g_n[gi-1:0]) | g_n[N-1];
    end
  end
endgenerate

// Stage A registers: a grant clears that receiver's pending flag and a new FIR strobe sets it
// (the grant is taken in the same clock, so a flag is cleared the clock it is granted and the
// same word cannot be sent twice).
reg [4:0] g_vk /* synthesis syn_preserve = 1 */;   // copies of g_v for the output enables, <= 10 loads each
initial g_vk = 5'd0;
always @(posedge clock) begin
  if (rbf[5]) begin
    pend_valid <= {N{1'b0}};
    ge_mask    <= {N{1'b1}};
  end else begin
    pend_valid <= (pend_valid & ~g_n) | chv;
    if (found) ge_mask <= mask_n;
  end
  g_oh  <= g_n;
  g_v   <= found;
  g_vk  <= {5{found}};
  g_idx <= g_idx_n;
end

// Stage B: pick the granted receiver's FIR output words (the one-hot select AND-ORs the words).
reg signed [23:0] sel_i, sel_q;
integer ci;
always @(*) begin
  sel_i = 24'sd0;
  sel_q = 24'sd0;
  for (ci = 0; ci < N; ci = ci + 1) begin
    sel_i = sel_i | (chi_f[24*ci +: 24] & {24{g_oh[ci]}});
    sel_q = sel_q | (chq_f[24*ci +: 24] & {24{g_oh[ci]}});
  end
end

// out_valid follows g_v; the word registers only change on a grant
initial begin out_valid = 1'b0; out_index = {IDX_W{1'b0}}; out_i = 24'sd0; out_q = 24'sd0; end
always @(posedge clock) begin
  out_valid <= g_v;
  if (g_vk[0]) out_i[9:0]   <= sel_i[9:0];
  if (g_vk[1]) out_i[19:10] <= sel_i[19:10];
  if (g_vk[2]) begin out_i[23:20] <= sel_i[23:20]; out_q[5:0] <= sel_q[5:0]; end
  if (g_vk[3]) out_q[15:6]  <= sel_q[15:6];
  if (g_vk[4]) begin out_q[23:16] <= sel_q[23:16]; out_index <= g_idx; end
end

endmodule
