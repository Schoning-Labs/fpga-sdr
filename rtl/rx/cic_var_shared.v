// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// cic_var_shared: the second filter of the receiver chain, a five-stage CIC decimator whose
// decimation factor can be switched between 5, 10, 20 and 40, built so that several receivers
// share one set of arithmetic instead of each having its own.
//
// Where it sits: rx_bank.v puts one of these behind every group of up to four receivers. Its
// input is the 16-bit complex stream that rx_channel.v produces at 7.68 Msps (a context is one
// real stream, so a receiver uses two contexts, I and Q, and a group of four receivers has eight).
// Its output goes to the compensating FIR in fir_decim.v. Terms such as CIC, decimation and
// bit growth are explained in docs/learn/GLOSSARY.md.
//
// What a CIC filter does: a CIC (cascaded integrator-comb) decimator is a cheap low-pass filter
// that also lowers the sample rate. It has no multipliers. A chain of integrators (running sums)
// works at the input rate, only every D-th result is kept, and a chain of combs (each one
// subtracts its previous reading) works at the output rate. With five stages the filter is five
// boxcar averages of D samples in a row, so it rejects the frequencies that would fold onto the
// wanted band after the rate drops by D, and it droops a little inside the passband (which the
// FIR after it is designed to put up with). The integrators are allowed to overflow, because
// only the difference between two readings reaches the output and two's complement wraps
// consistently, but the registers must be wide enough for the true result.
//
// Sample rates and the numbers: the input is 7.68 Msps. D = 40, 20, 10 and 5 give 192, 384, 768
// and 1,536 ksps, which is four times the final receiver rate of 48, 96, 192 and 384 ksps (the
// FIR after this block takes the last factor of 4). The sums grow by ceil(5 x log2(D)) bits:
// 12 for D = 5, 17 for D = 10, 22 for D = 20 and 27 for D = 40, so the accumulators are
// 16 + 27 = 43 bits wide. At the output a 16-bit field is selected out of the 43 bits and
// rounded, and the field moves with D so that the DC gain is the same for all four settings:
// D^5 / 2^growth equals 3,125 / 4,096 = 0.763 in each case (5^5 = 3,125 and the other factors of
// two cancel against the growth). That is the reason one set of FIR coefficients can serve
// every receiver rate.
//
// How the sharing works: the integrators and combs for all contexts are computed by one
// arithmetic engine, which handles one context per clock. A context wants service only once per
// input sample of its own, and those arrive at most every 10 clocks (the fixed CIC in front
// decimates by 10 and a valid sample comes at most once per clock), while the engine needs at
// most NCTX clocks to serve everybody (8, in the usual case), so every context is served
// before its next sample is due and a single pending flag per context is all the queue needed.
// The state of each context (five integrators, five comb outputs and the five comb inputs of
// the previous decimation event, 43 bits each) lives in three small LUT RAMs with one word per
// context, read and written by the context that was granted.
//
// The control part of every context (the decimation counter, the output strobe and the rounded
// output register) is not shared. It runs every clock for each context, so out_strobe and
// out_data have the same timing that a separate filter per context would give. The shared engine
// can be several clocks late with its arithmetic without anybody noticing, because the output
// register only looks at the result of the previous decimation event when a new one starts
// (the top comb value changes once per decimation period, at least 5 samples apart).
//
// Pipeline after a grant, in clocks:
//   E0  the grant is registered (one-hot and as a number); the context's integrators are read
//   E1  the integrators add the new input sample; the context's comb words are read
//   E2  the new integrators are written back; the combs subtract; the new comb inputs are written
//   E3  the new comb outputs are written; the top one is also copied into that context's own
//       register, which the output rounding reads every clock
// A context is granted at most once in 10 clocks, so none of its words is ever in the pipeline
// twice. The state of a context is therefore updated 5 clocks after its grant, and the grant
// itself waits for at most NCTX clocks.
//
// Reset: a reset of a context writes nothing into the RAMs. It sets two flags for that context,
// "integrators are zero" and "comb words are zero", and the next grant (the next grant that
// ends a decimation period, for the comb words) uses zeros in place of what it read and clears
// the flag. The output and the control registers are reset directly. A reset reaches the state
// registers 2 clocks after it reaches the module because of rx_fan.
//
// Fan-out: every control net is a kept copy with at most 11 loads (rx_fan and rx_vreg below),
// because a net driving hundreds of registers was the slowest path of the whole receiver bank.
//
// Gowin specific: the three state RAMs are LUT RAM (RAM16SDP4 cells), so this block uses no
// block RAM and no DSP block; the adds are 43-bit carry chains.

// ---------------------------------------------------------------------------------------------
// rx_fan: N copies of one control bit, for fan-out. A first rank of kept registers (the roots)
// each drives PER leaf registers, and each leaf drives the real loads, so no register has more
// than PER loads. The copies are made for resets and clock enables, which the usual fan-out
// attribute does not duplicate. Latency from d to q is 2 clocks.
// ---------------------------------------------------------------------------------------------
module rx_fan #(
  parameter N    = 4,                 // number of copies wanted
  parameter PER  = 10,                // loads per register (and leaves per root)
  parameter INIT = 1'b0   // power-up value: 1 for a reset (the design starts in reset)
)(
  input          clock,
  input          d,                   // the control bit to copy
  output [N-1:0] q                    // the copies, 2 clocks behind d
) /* synthesis syn_maxfan = 10000 syn_srlstyle = "registers" */;
localparam R = (N + PER - 1) / PER;
`ifdef GOWIN_DSP
// A kept register that powers up high is built twice by the Gowin tool (a set-type flip-flop
// that drives the loads and a reset-type twin with no load that syn_preserve keeps: 21
// flip-flops for 10, measured). Flip-flop primitives that are instantiated by hand are built
// exactly once and are not merged, so this build uses those.
wire [R-1:0] root;
wire [N-1:0] leaf;
genvar gf;
generate
  for (gf = 0; gf < R; gf = gf + 1) begin : rt
    if (INIT) begin : hi
      DFFSE #(.INIT(1'b1)) f (.Q(root[gf]), .D(d), .CLK(clock), .SET(1'b0), .CE(1'b1)) /* synthesis syn_preserve = 1 */;
    end else begin : lo
      DFFRE #(.INIT(1'b0)) f (.Q(root[gf]), .D(d), .CLK(clock), .RESET(1'b0), .CE(1'b1)) /* synthesis syn_preserve = 1 */;
    end
  end
  for (gf = 0; gf < N; gf = gf + 1) begin : lf
    if (INIT) begin : hi
      DFFSE #(.INIT(1'b1)) f (.Q(leaf[gf]), .D(root[gf / PER]), .CLK(clock), .SET(1'b0), .CE(1'b1)) /* synthesis syn_preserve = 1 */;
    end else begin : lo
      DFFRE #(.INIT(1'b0)) f (.Q(leaf[gf]), .D(root[gf / PER]), .CLK(clock), .RESET(1'b0), .CE(1'b1)) /* synthesis syn_preserve = 1 */;
    end
  end
endgenerate
`else
// Simulation version: the same two ranks as plain registers, powered up at INIT.
reg [R-1:0] root /* synthesis syn_preserve = 1 */;
reg [N-1:0] leaf /* synthesis syn_preserve = 1 */;
integer i;
initial begin root = {R{INIT}}; leaf = {N{INIT}}; end
always @(posedge clock) begin
  root <= {R{d}};
  for (i = 0; i < N; i = i + 1)
    leaf[i] <= root[i / PER];
end
`endif
assign q = leaf;
endmodule

// rx_vreg: a register vector of W bits whose synchronous reset and clock enable are given per
// group of G bits, one kept copy of each control per group (the copies come from rx_fan). Reset
// wins over enable. Used for the CIC accumulators, which are wide and need their controls split.
module rx_vreg #(
  parameter W  = 43,                  // width of the register vector
  parameter G  = 11,                  // bits per group (loads per control copy)
  parameter NG = (W + G - 1) / G      // number of groups
)(
  input               clock,
  input  [NG-1:0]     rst,            // one reset per group
  input  [NG-1:0]     en,             // one clock enable per group
  input  [W-1:0]      d,              // next value
  output reg [W-1:0]  q               // stored value
) /* synthesis syn_maxfan = 10000 syn_srlstyle = "registers" */;
initial q = {W{1'b0}};
genvar g;
generate
  for (g = 0; g < NG; g = g + 1) begin : grp
    localparam LO = g * G;                                   // first bit of this group
    localparam GW = (LO + G <= W) ? G : (W - LO);            // width of this group (the last one may be short)
    always @(posedge clock)
      if (rst[g]) q[LO +: GW] <= {GW{1'b0}};
      else if (en[g]) q[LO +: GW] <= d[LO +: GW];
  end
endgenerate
endmodule

// ---------------------------------------------------------------------------------------------
// rx_ctxram: up to 16 words of W bits in LUT RAM (RAM16SDP4 cells, 4 bits each), written with the
// clock and read without one (the read data follows the read address within the same clock). The
// write enable is not covered by the fan-out attribute, so there is one kept copy of it per CPS
// cells, loaded one clock ahead from we_pre. The address registers outside this module are
// ordinary data nets, which the fan-out attribute duplicates by itself.
// ---------------------------------------------------------------------------------------------
module rx_ctxram #(
  parameter W   = 215,               // bits per word
  parameter CPS = 10                 // cells (of 4 bits) per write-enable copy
)(
  input           clock,
  input           we_pre,            // write enable, one clock before the write
  input  [3:0]    wa,                // write address (a context number)
  input  [W-1:0]  wd,                // write data
  input  [3:0]    ra,                // read address (a context number)
  output [W-1:0]  rd                 // read data, no clock needed
) /* synthesis syn_maxfan = 10000 */;
localparam SW = 4 * CPS;             // bits served by one write-enable copy
localparam NS = (W + SW - 1) / SW;   // number of slices
reg [NS-1:0] wek /* synthesis syn_preserve = 1 */;
initial wek = {NS{1'b0}};
always @(posedge clock) wek <= {NS{we_pre}};
genvar g;
generate
  for (g = 0; g < NS; g = g + 1) begin : sl
    localparam LO = g * SW;
    localparam GW = (LO + SW <= W) ? SW : (W - LO);
    reg [GW-1:0] mem [0:15] /* synthesis syn_ramstyle = "distributed_ram" */;
    // synthesis translate_off
    integer k;
    initial for (k = 0; k < 16; k = k + 1) mem[k] = {GW{1'b0}};
    // synthesis translate_on
    always @(posedge clock)
      if (wek[g]) mem[wa] <= wd[LO +: GW];
    assign rd[LO +: GW] = mem[ra];
  end
endgenerate
endmodule

module cic_var_shared #(
  parameter NCTX      = 8,           // at most 16: one LUT RAM word per context
  parameter STAGES    = 5,           // integrator and comb stages
  parameter IN_WIDTH   = 16,         // bits of one input sample
  parameter ACC_WIDTH  = 43,         // IN_WIDTH + 27, the growth for decimation 40 with 5 stages
  parameter OUT_WIDTH  = 16          // bits of one rounded output sample
)(
  input                              clock,     // DSP clock
  input                              rst_all, // not used any more (the grant has no pointer to reset)
  input      [NCTX-1:0]              rst,     // per-context (that receiver's own chan_rst)

  input      [NCTX-1:0]              in_strobe, // per context: one-clock pulse for an input sample that is valid
  // Flat (packed) buses instead of unpacked-array ports: plain Verilog-2001 (no SystemVerilog)
  // for synthesis-tool compatibility (yosys's synth_gowin flow, tools/yosys_res.sh). Context c's
  // slice is bits [c*WIDTH +: WIDTH].
  input  signed [NCTX*IN_WIDTH-1:0]  in_data_flat,    // input samples, two's complement
  input      [NCTX*6-1:0]            decimation_flat, // one of 5, 10, 20, 40 per context

  output     [NCTX-1:0]                  out_strobe,    // per context: one-clock pulse for each output sample
  output signed [NCTX*OUT_WIDTH-1:0]     out_data_flat  // rounded output samples, valid from out_strobe on
) /* synthesis syn_maxfan = 10000 syn_srlstyle = "registers" */;

localparam G    = 11;                        // bits per kept reset copy
localparam SW   = STAGES * ACC_WIDTH;        // one context's integrators (or comb outputs, or comb inputs)
localparam CW   = (STAGES - 1) * ACC_WIDTH;  // the comb outputs that feed a next stage
localparam NGS  = (SW + G - 1) / G;
localparam NGC  = (CW + G - 1) / G;
localparam NGD  = (IN_WIDTH + G - 1) / G;
localparam TLO  = IN_WIDTH + 12 - OUT_WIDTH - 1;   // lowest bit of the top comb word the rounding reads
localparam TW   = ACC_WIDTH - TLO;

// pending work per context and the grant ------------------------------------------------------
// Every context that has a sample waiting raises its pending flag. A fixed priority picks the
// lowest numbered one. Priority is good enough because a context becomes pending at most once
// in 10 clocks and the engine drains all of them in at most NCTX clocks, in any order.
wire [NCTX-1:0]            pend_v;           // a sample waits
wire [NCTX-1:0]            bnd_v;            // the waiting sample ends a decimation period
wire [NCTX-1:0]            zi_v;             // this context's integrators count as zero (reset since their last write)
wire [NCTX-1:0]            zc_v;             // the same for its comb words
wire [NCTX*IN_WIDTH-1:0]   pend_data_v;

wire [NCTX-1:0] lower_any;                   // lower_any[c] = some context below c is pending
genvar gc;
generate
  for (gc = 0; gc < NCTX; gc = gc + 1) begin : lowany
    if (gc == 0) begin : first
      assign lower_any[gc] = 1'b0;
    end else begin : more
      assign lower_any[gc] = |pend_v[gc-1:0];
    end
  end
endgenerate
wire [NCTX-1:0] gnt_n = pend_v & ~lower_any; // one-hot: the lowest pending context

// The same decision as a binary number, made by OR-ing in the index of the one granted context.
reg [3:0] ga_n;                              // its number
integer ek;
always @(*) begin
  ga_n = 4'd0;
  for (ek = 0; ek < NCTX; ek = ek + 1)
    if (gnt_n[ek]) ga_n = ga_n | ek[3:0];
end

// stage E0: the grant ---------------------------------------------------------------------------
// The grant is registered (gnt_r), and its number and one-hot copy are then carried down a delay
// line (a0..a3 and oh1, oh2) so that every later stage finds the address it needs, together with
// flags that say whether this sample ended a decimation period (b1, b2) and whether the RAM
// write enables should fire (v0, v1).
reg [NCTX-1:0] gnt_r /* synthesis syn_preserve = 1 */; // the grant, one clock after the decision
reg [NCTX-1:0] oh1 = {NCTX{1'b0}}, oh2 = {NCTX{1'b0}};
reg [3:0]      a0 = 4'd0, a1 = 4'd0, a2 = 4'd0, a3 = 4'd0;
reg            v0 = 1'b0, v1 = 1'b0;
reg            b1 = 1'b0, b2 = 1'b0;         // the comb phase follows (the sample ended a decimation period)
wire           b0w = |(gnt_r & bnd_v);       // E0, as cb_src was
wire           ziw = |(gnt_r & zi_v);        // E0: the granted context's integrators count as zero
wire           zcw = |(gnt_r & zc_v);        // E0: its comb words count as zero
initial gnt_r = {NCTX{1'b0}};
always @(posedge clock) begin
  gnt_r <= gnt_n;  oh1 <= gnt_r;  oh2 <= oh1;
  a0 <= ga_n;      a1 <= a0;      a2 <= a1;   a3 <= a2;
  v0 <= |pend_v;   v1 <= v0;
  b1 <= b0w;       b2 <= b1;
end

// kept copies of the two "counts as zero" flags, for E1: zk gates the integrators that were read
// (inside the adders' own LUTs), ck1 is the synchronous reset of the comb words' read registers
reg [NGS-1:0]     zk  /* synthesis syn_preserve = 1 */;
reg [NGC+NGS-1:0] ck1 /* synthesis syn_preserve = 1 */;
initial begin zk = {NGS{1'b0}}; ck1 = {(NGC+NGS){1'b0}}; end
always @(posedge clock) begin
  zk  <= {NGS{ziw}};
  ck1 <= {(NGC+NGS){zcw}};
end

// the state: three LUT RAMs, one word per context -------------------------------------------------
// m_int holds the integrators, m_prev the comb inputs of the previous decimation event (the
// values each comb subtracts), and m_out the comb outputs (which feed the next comb stage the
// next time round).
wire [SW-1:0] irm, com, cpm;                 // read: integrators, comb outputs, comb inputs of last time
reg  [SW-1:0] iw  = {SW{1'b0}};              // new integrators
reg  [SW-1:0] cw  = {SW{1'b0}};              // new comb outputs
wire [SW-1:0] cin;                           // new "comb inputs of last time"
rx_ctxram #(.W(SW)) m_int  (.clock(clock), .we_pre(v1), .wa(a2), .wd(iw),  .ra(a0), .rd(irm));
rx_ctxram #(.W(SW)) m_prev (.clock(clock), .we_pre(b1), .wa(a2), .wd(cin), .ra(a1), .rd(cpm));
rx_ctxram #(.W(SW)) m_out  (.clock(clock), .we_pre(b2), .wa(a3), .wd(cw),  .ra(a1), .rd(com));

// the granted word, selected once (E0) and registered (E1)
reg [IN_WIDTH-1:0] sd_c;
integer sk;
always @(*) begin
  sd_c = {IN_WIDTH{1'b0}};
  for (sk = 0; sk < NCTX; sk = sk + 1)
    sd_c = sd_c | (pend_data_v[sk*IN_WIDTH +: IN_WIDTH] & {IN_WIDTH{gnt_r[sk]}});
end

// registers of E1: the context's integrators and the word; of E2: its comb words
reg [IN_WIDTH-1:0] svc_data = {IN_WIDTH{1'b0}};
reg [SW-1:0]       ir  = {SW{1'b0}};
reg [CW-1:0]       cor = {CW{1'b0}};
reg [SW-1:0]       cpr = {SW{1'b0}};
wire [SW-1:0]      irz;                      // ir, or zero
always @(posedge clock) begin
  svc_data <= sd_c;
  ir       <= irm;
end
genvar gk;
generate
  for (gk = 0; gk < NGS; gk = gk + 1) begin : rk_s
    localparam LO = gk * G;
    localparam GW = (LO + G <= SW) ? G : (SW - LO);
    assign irz[LO +: GW] = ir[LO +: GW] & {GW{~zk[gk]}};
    always @(posedge clock)
      if (ck1[gk]) cpr[LO +: GW] <= {GW{1'b0}};
      else         cpr[LO +: GW] <= cpm[LO +: GW];
  end
  for (gk = 0; gk < NGC; gk = gk + 1) begin : rk_c
    localparam LO = gk * G;
    localparam GW = (LO + G <= CW) ? G : (CW - LO);
    always @(posedge clock)
      if (ck1[NGS+gk]) cor[LO +: GW] <= {GW{1'b0}};
      else             cor[LO +: GW] <= com[LO +: GW];
  end
endgenerate

// E1: integrators (stage 0 fed by the granted word, stage i by stage i-1's old value);
// E2: combs (stage 0 fed by the top integrator's fresh value, stage i by stage i-1's old output)
// The comb chain runs one clock behind the integrator chain and reads the top integrator's
// freshly registered value, so no two 43-bit adders are ever chained inside one clock.
wire [ACC_WIDTH-1:0] svc_ext = {{(ACC_WIDTH-IN_WIDTH){svc_data[IN_WIDTH-1]}}, svc_data};
genvar gs;
generate
  for (gs = 0; gs < STAGES; gs = gs + 1) begin : stg
    wire [ACC_WIDTH-1:0] i_in;
    wire [ACC_WIDTH-1:0] c_in;
    if (gs == 0) begin : s_first
      assign i_in = svc_ext;
      assign c_in = iw[(STAGES-1)*ACC_WIDTH +: ACC_WIDTH];
    end else begin : s_next
      assign i_in = irz[(gs-1)*ACC_WIDTH +: ACC_WIDTH];
      assign c_in = cor[(gs-1)*ACC_WIDTH +: ACC_WIDTH];
    end
    assign cin[gs*ACC_WIDTH +: ACC_WIDTH] = c_in;
    always @(posedge clock) begin
      iw[gs*ACC_WIDTH +: ACC_WIDTH] <= irz[gs*ACC_WIDTH +: ACC_WIDTH] + i_in;
      cw[gs*ACC_WIDTH +: ACC_WIDTH] <= c_in - cpr[gs*ACC_WIDTH +: ACC_WIDTH];
    end
  end
endgenerate
wire [TW-1:0] cw_top = cw[SW-1 -: TW];       // the top comb output, the bits the rounding reads

// Everything below is per context and not shared: decimation setting, counter, pending flag,
// the copy of the top comb word and the rounding of the output.
generate
  for (gc = 0; gc < NCTX; gc = gc + 1) begin : ctx
    // The decimation value is converted to a one-hot select (dsel) and to "count minus one"
    // (dm1_q) in registers, so the counter compare and the output field select start from
    // flip-flops. Any value other than 5, 10 and 20 is treated as 40.
    wire [5:0] dec_in = decimation_flat[gc*6 +: 6];
    reg  [3:0] dsel   = 4'b1000;            // one-hot: decimation 5, 10, 20, 40 (anything else: 40)
    reg  [5:0] dm1_q  = 6'd39;
    always @(posedge clock) begin
      dsel[0] <= (dec_in == 6'd5);
      dsel[1] <= (dec_in == 6'd10);
      dsel[2] <= (dec_in == 6'd20);
      dsel[3] <= ~((dec_in == 6'd5) | (dec_in == 6'd10) | (dec_in == 6'd20));
      dm1_q <= dec_in - 6'd1;
    end

    // per-context control: sample_no / out_strobe (the decimation counter)
    // sample_no counts accepted input samples; on the one that ends a period (the count reaches
    // decimation - 1) it restarts and ostb is raised for one clock.
    reg [5:0] sample_no  = 6'd0;
    reg       ostb       = 1'b0;
    wire      last_samp  = (sample_no == dm1_q);
    always @(posedge clock) begin
      if (rst[gc]) begin
        sample_no <= 6'd0;
        ostb      <= 1'b0;
      end else begin
        if (in_strobe[gc]) begin
          if (last_samp) begin
            sample_no <= 6'd0;
            ostb      <= 1'b1;
          end else begin
            sample_no <= sample_no + 6'd1;
            ostb      <= 1'b0;
          end
        end else begin
          ostb <= 1'b0;
        end
      end
    end
    assign out_strobe[gc] = ostb;

    // pending work: latched when in_strobe arrives, cleared when the grant is decided
    // pdata and pbound keep the sample and the "ends a period" flag until the engine takes them.
    reg                 pending = 1'b0;
    reg [IN_WIDTH-1:0]  pdata   = {IN_WIDTH{1'b0}};
    reg                 pbound  = 1'b0;
    // "counts as zero" flags: set by the reset, cleared by the grant that writes the words again
    reg                 zi = 1'b1;
    reg                 zc = 1'b1;
    always @(posedge clock) begin
      if (rst[gc]) begin
        pending <= 1'b0;
      end else if (in_strobe[gc]) begin
        pending <= 1'b1;
      end else if (gnt_n[gc]) begin
        pending <= 1'b0;
      end
      if (in_strobe[gc]) begin
        pdata  <= in_data_flat[gc*IN_WIDTH +: IN_WIDTH];
        pbound <= last_samp;
      end
      if (rst[gc])                    zi <= 1'b1;
      else if (gnt_r[gc])             zi <= 1'b0;
      if (rst[gc])                    zc <= 1'b1;
      else if (gnt_r[gc] & pbound)    zc <= 1'b0;
    end
    assign pend_v[gc]                           = pending;
    assign zi_v[gc]                             = zi;
    assign zc_v[gc]                             = zc;
    assign bnd_v[gc]                            = pbound;
    assign pend_data_v[gc*IN_WIDTH +: IN_WIDTH] = pdata;

    // this context's top comb output, a register copy (the rounding below reads it every clock);
    // loaded in the clock the comb outputs are written (E3)
    // The copy is split in three slices (bits 10:0, 21:11 and the rest) with their own kept
    // enable (tek) and reset (trk), so that none of them has many loads.
    reg [2:0] tek /* synthesis syn_preserve = 1 */;
    reg [2:0] trk /* synthesis syn_preserve = 1 */;
    initial begin tek = 3'd0; trk = 3'd0; end
    always @(posedge clock) begin
      tek <= {3{oh2[gc] & b2}};
      trk <= {3{rst[gc]}};
    end
    reg [TW-1:0] top_r = {TW{1'b0}};
    always @(posedge clock) begin
      if (trk[0])      top_r[10:0]    <= 11'd0;
      else if (tek[0]) top_r[10:0]    <= cw_top[10:0];
      if (trk[1])      top_r[21:11]   <= 11'd0;
      else if (tek[1]) top_r[21:11]   <= cw_top[21:11];
      if (trk[2])      top_r[TW-1:22] <= {(TW-22){1'b0}};
      else if (tek[2]) top_r[TW-1:22] <= cw_top[TW-1:22];
    end
    wire [ACC_WIDTH-1:0] top = {top_r, {TLO{1'b0}}};

    // rounded output: select the field, then add the rounding bit; refreshed every clock
    // The 16-bit field that is taken depends on the decimation: its top bit is 16 + growth - 1
    // (bit 27 for D = 5, 32 for D = 10, 37 for D = 20 and 42 for D = 40), and the bit just under
    // the field is added to round half up.
    reg [OUT_WIDTH-1:0]  lo_f = {OUT_WIDTH{1'b0}}, hi_f = {OUT_WIDTH{1'b0}};
    reg                  lo_r = 1'b0, hi_r = 1'b0, sa_q = 1'b0;
    reg [OUT_WIDTH-1:0]  od_f = {OUT_WIDTH{1'b0}};
    reg                  od_r = 1'b0;
    reg [OUT_WIDTH-1:0]  od_q = {OUT_WIDTH{1'b0}};
    always @(posedge clock) begin
      // two ranks of 2:1 selection (decimation 5/10, then 20/40, then which pair)
      lo_f <= dsel[0] ? top[IN_WIDTH + 12 - 1 -: OUT_WIDTH] : top[IN_WIDTH + 17 - 1 -: OUT_WIDTH];
      lo_r <= dsel[0] ? top[IN_WIDTH + 12 - OUT_WIDTH - 1]  : top[IN_WIDTH + 17 - OUT_WIDTH - 1];
      hi_f <= dsel[2] ? top[IN_WIDTH + 22 - 1 -: OUT_WIDTH] : top[IN_WIDTH + 27 - 1 -: OUT_WIDTH];
      hi_r <= dsel[2] ? top[IN_WIDTH + 22 - OUT_WIDTH - 1]  : top[IN_WIDTH + 27 - OUT_WIDTH - 1];
      sa_q <= dsel[0] | dsel[1];
      od_f <= sa_q ? lo_f : hi_f;
      od_r <= sa_q ? lo_r : hi_r;
      if (rst[gc]) od_q <= {OUT_WIDTH{1'b0}};
      else         od_q <= od_f + od_r;
    end
    assign out_data_flat[gc*OUT_WIDTH +: OUT_WIDTH] = od_q;
  end
endgenerate

endmodule
