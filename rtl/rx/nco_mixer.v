// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// nco_mixer: a numerically controlled oscillator (NCO) together with a mixer. It multiplies a
// signal by a sine and a cosine of a frequency that the firmware chooses, which moves the part
// of the spectrum around that frequency down to 0 Hz (or the other way round, for transmit).
// This is the first stage of every receiver and the stage that makes tuning possible. The terms
// used here (NCO, phase accumulator, mixer, Taylor series) are explained in
// docs/learn/GLOSSARY.md.
//
// One design is used in three places, in two modes:
//   MODE 0 (receive): a real input in_i (the ADC sample) gives a complex output
//          out_i/out_q = G * in_i * (cos t, sin t). Used by the receiver bank (rx_channel.v, one
//          per receiver) and by the zoom receiver (rtl/zoom/zoom_ddc.v).
//   MODE 1 (transmit): a complex input gives a real output out_i = G * (in_i cos t - in_q sin t),
//          which is Re{(in_i + j in_q) e^(jt)}; out_q is 0. Used by the transmit chain
//          (rtl/tx/tx_chain.v).
// Here t is the NCO phase. It is a 32-bit register in which one full turn is 2^32, and it
// advances by the 32-bit increment `frequency` for every accepted sample, so the oscillator runs
// at f = frequency / 2^32 x (sample rate). With a sample rate of 76.8 MHz the step is
// 76.8e6 / 2^32 = 0.0179 Hz, and the firmware computes frequency = round(f_Hz / 76.8e6 x 2^32).
// While the increment is 0 the phase is held at 0. The gain is G = 107,922 / 2,048 = 52.6963,
// the same as the mixer of the Hermes-Lite 2 receiver, and the sign convention (x times
// e^(+jt)) and the zero phase offset are that mixer's too, so all levels further down the
// chain are the same as in that radio.
//
// How the sine and cosine are made: a table with one entry per phase step would be far too
// big (the top 12 bits of the phase alone would need 4,096 entries per turn, and cutting the
// phase to 12 bits leaves spurious tones only about 72 dB below the signal, 6 dB per bit).
// Instead the design uses a quarter-wave table plus a first-order correction for the part of the
// phase that the table does not resolve:
//   1. Table: 1,024 entries of 18 bits for a quarter wave, T[k] = sin((k + 0.5) pi / 2048)
//      scaled by 107,922. Because of the half-step offset, T[1023 - k] is the cosine of the
//      angle of T[k], so one read of two table positions gives both sine and cosine of the
//      same angle in one clock.
//   2. Quadrant: odd quadrants take the mirrored angle (the 30 phase bits inside the quadrant
//      inverted, which mirrors both the table address and the residual d), and the quadrant
//      then only decides the signs: sin t = +-bs and cos t = +-bc, with the sign of the sine
//      from phase[31] and the sign of the cosine from phase[31] ^ phase[30]. In receive mode
//      the signs are applied to the 12-bit sample, which is cheaper than applying them to a
//      22-bit sine; in transmit mode they are applied to the 18-bit sine and cosine.
//   3. Residual: d = phase[19:10], the ten bits just below the table address, centered on the
//      table sample by appending a 1 bit (dc = {phase[19] ^ 1, phase[18:10], 1}), so that
//      |d| <= pi / 4096 radians. d in radians is dc x 2 pi x 2^-23.
//   4. Correction (two multiplies): with a the table angle,
//          sin(a + d) = sin a + d cos a,    cos(a + d) = cos a - d sin a
//      The first-order term is enough because the neglected term d^2/2 is below 3e-7 of full
//      scale (-130 dB). The factor 2 pi is made as dc x 201 / 32 = dc x 6.28125 using two small
//      adds (3 dc and 9 dc, then (3 dc << 6) + 9 dc), which has a relative error of 3e-4 on a
//      correction that is itself at most 83 table steps, so at most 0.03 of a step.
//   5. Mix (two more multiplies): the sample times the corrected cosine and sine. That is 4 DSP
//      multipliers in total.
//
// Widths: the correction is truncated (floor) to E extra fraction bits of the table value and
// added, so the corrected sine and cosine (bs and bc) are 18 + E bits. E is 4 in receive mode,
// which puts them on the DSP's 27-bit port against the 13-bit signed sample, and 0 in transmit
// mode, where the 24-bit samples need the 27-bit port and the sine the 18-bit one. The receive
// output is rounded to nearest (half up) to 18 bits, the transmit output is the floor, 31 bits
// wide (the transmit chain rounds after its own shift).
//
// Error budget (docs/RX_DSP.md section 10 has the measurements): the table rounding is 0.5 step of
// 107,922 (-106.7 dB at worst, noise-like), the rounding of the output is the same at 18 bits,
// the Taylor remainder is -130 dB, the truncation of the residual is 0.04 step and the 201/32
// error 0.03 step. Over 1,000 random tuning words the worst spur of the mixer itself was
// 117.3 dBc.
//
// Pipeline: every register advances only on in_strobe (the receive side's adc_valid), so the mixer
// behaves the same whether valid samples come every clock or in bursts; out_strobe is a
// registered one-clock pulse per accepted input once the pipeline holds valid data (see the
// note on valid tracking below). Latency is LAT accepted samples: 7 in MODE 0 and 8 in MODE 1.
// Stages (MODE 0):
//   A  phase accumulator; table read (address register inside the block RAM); d, quadrant, x
//   B  sin, cos from the two table ports; 3 dc, 9 dc
//   C  ds = (3 dc << 6) + 9 dc
//   D  d x cos, d x sin (DSP)
//   E  bs = sin<<E + floor(d cos), bc = cos<<E - floor(d sin); signed samples
//   F  x cos, x sin (DSP)
//   G  round to OUT_WIDTH
// MODE 1 inserts a stage between E and F that applies the signs to bs and bc, and its last
// stage is the difference of the two floor(product / 2^11).
//
// rst clears only the valid tracking: the phase and the data registers have no reset and keep
// their power-up value of 0. fw/tr-rxmodel/src/nco.rs is a bit-exact software model of MODE 0
// (docs/R2_RXMODEL.md).
//
// Gowin specific: 4 DSP blocks (2 for the correction, 2 for the mix) and one block RAM for the
// table, read on both of its ports in the same clock (see nco_sin_dp below).

// The sine table, 1,024 x 18, two read ports: one block RAM in the Gowin builds (generated), the same
// values from the hex file in simulation. A registered read on both ports, held while ce is low.
// The Gowin builds instantiate the DPX9B primitive with the table generated into
// rtl/rx/nco_sin_dp.vh by tools/gen_nco_table.py. The same script writes the hex file that
// the simulation reads. The file keeps the table as 512 words of 36 bits, word j = {T[j],
// T[1023 - j]}, and the second half of the table is found by mirroring the address (a table
// written as one single-port 512 x 36 ROM, or as a 1,024 x 18 ROM with two read ports, is
// counted as two block RAMs by the Gowin tools, while the dual-port block used here is one).
`ifdef GOWIN_DSP
`include "rtl/rx/nco_sin_dp.vh"
`else
module nco_sin_dp #(parameter TABLE_FILE = "") (
  input         clock, ce,           // clock and read enable (the outputs hold while ce is low)
  input  [9:0]  aa, ab,              // read addresses of the two ports, 0..1023
  output [17:0] qa, qb               // T[aa] and T[ab], one clock later
);
  reg [35:0] rom [0:511];                       // word j = {T[j], T[1023 - j]}
  initial $readmemh(TABLE_FILE, rom);
  reg [17:0] qa_r = 18'd0, qb_r = 18'd0;
  always @(posedge clock)
    if (ce) begin
      qa_r <= aa[9] ? rom[~aa[8:0]][17:0] : rom[aa[8:0]][35:18];   // T[aa]
      qb_r <= ab[9] ? rom[~ab[8:0]][17:0] : rom[ab[8:0]][35:18];   // T[ab]
    end
  assign qa = qa_r;
  assign qb = qb_r;
endmodule
`endif

// Table file path, relative to the directory the simulator or synthesis runs in (the repo root
// everywhere except sim/run_sim.sh, which runs from sim/ and passes -DNCO_TABLE_FILE).
`ifndef NCO_TABLE_FILE
`define NCO_TABLE_FILE "rtl/rx/nco_sin_table.hex"
`endif

module nco_mixer #(
  parameter MODE       = 0,   // 0: receive (real in, complex out); 1: transmit (complex in, real out)
  parameter IN_WIDTH   = 12,  // 12 (receive, ADC) or 24 (transmit, CIC output)
  parameter OUT_WIDTH  = 18,  // 18 (receive) or 31 (transmit)
  parameter TABLE_FILE = `NCO_TABLE_FILE   // hex file with the sine table, used in simulation only
)(
  input                         clock,       // DSP clock
  input                         rst,         // synchronous reset of the valid tracking
  input                         in_strobe,   // one-clock pulse per valid input sample
  input  signed [31:0]          frequency,   // phase increment per accepted sample, one turn = 2^32
  input  signed [IN_WIDTH-1:0]  in_i,        // input, real part (the ADC sample in receive mode)
  input  signed [IN_WIDTH-1:0]  in_q,       // MODE 1 only
  output                        out_strobe,  // one-clock pulse per output sample
  output signed [OUT_WIDTH-1:0] out_i,       // output, real part
  output signed [OUT_WIDTH-1:0] out_q       // MODE 0 only (0 in MODE 1)
) /* synthesis syn_maxfan = 10000 syn_srlstyle = "registers" */;

localparam E   = (MODE == 0) ? 4 : 0;   // extra fraction bits of the corrected sine/cosine
localparam SCW = 18 + E;                // corrected sine/cosine width
localparam SH  = 28 - E;                // (dc * 201) * table >> SH = correction in 2^-E steps
localparam LAT = (MODE == 0) ? 7 : 8;   // register levels from input to output

//------------------------------------------------------------------------------
// valid tracking (same scheme as the CORDIC mixer it replaces)
//------------------------------------------------------------------------------
// The datapath only advances on in_strobe, so a strobe-gated shift register tracks validity in
// lockstep. valid_sr[i] = 1 once at least i+1 samples have been accepted. out_strobe is a
// register loaded every clock with in_strobe & valid_sr[LAT-2] (the pre-edge value: the sample
// reaching the output register at this edge is valid): a genuine one-clock pulse per accepted
// input, dropping to 0 the clock after in_strobe stops (docs/RX_DSP.md section 1). rst clears it
// immediately, so a disabled channel can never be left with a stuck out_strobe.
reg [LAT-2:0] valid_sr = {(LAT-1){1'b0}};
reg           out_strobe_r = 1'b0;
always @(posedge clock)
  if (rst) begin
    valid_sr     <= {(LAT-1){1'b0}};
    out_strobe_r <= 1'b0;
  end else begin
    if (in_strobe)
      valid_sr <= {valid_sr[LAT-3:0], 1'b1};
    out_strobe_r <= in_strobe & valid_sr[LAT-2];
  end
assign out_strobe = out_strobe_r;

//------------------------------------------------------------------------------
// stage A: phase accumulator, table read
//------------------------------------------------------------------------------
// phase advances by `frequency` on every accepted sample (and is forced to 0 while the
// increment is 0). Its top two bits are the quadrant. The next 20 bits are the position inside
// the quadrant: for odd quadrants they are inverted (um), which mirrors the angle. The upper 10
// of them (addr_s) address the table and the lower 10 are the residual d. The second table port
// reads the complementary address ~addr_s = 1023 - addr_s, which holds the cosine.
reg [31:0] phase = 32'd0;
wire        q0   = phase[30];
wire [19:0] um   = phase[29:10] ^ {20{q0}};   // [19:10] table address, [9:0] residual d
wire [9:0]  addr_s = um[19:10];

wire [17:0] rd_s, rd_c;                              // T[k], T[1023 - k]: the registered table read
nco_sin_dp #(.TABLE_FILE(TABLE_FILE)) u_tab (
  .clock(clock), .ce(in_strobe), .aa(addr_s), .ab(~addr_s), .qa(rd_s), .qb(rd_c));

// The residual is made signed by inverting its top bit (so it is centered on the table
// sample), and the quadrant is carried down the pipeline until the signs are needed.
reg signed [9:0] d_a  = 10'sd0;
reg [1:0]        q_a  = 2'd0;

always @(posedge clock)
  if (in_strobe) begin
    phase <= (frequency == 32'sd0) ? 32'd0 : phase + frequency;
    d_a   <= {~um[9], um[8:0]};
    q_a   <= phase[31:30];
  end

//------------------------------------------------------------------------------
// stages B, C: sin/cos from the table read; ds = dc * 201 (= dc * 2 pi * 32)
//------------------------------------------------------------------------------
// dc is the residual with a 1 appended, an 11-bit odd number, which puts d exactly in the middle
// of the step the table entry stands for. The multiplication by 201 is done with shifts and two
// adds: 3 dc, 9 dc and then (3 dc << 6) + 9 dc = 201 dc.
wire signed [10:0] dc = {d_a, 1'b1};

reg [16:0]        s_b = 17'd0, c_b = 17'd0;      // table values are positive, below 2^17
reg signed [12:0] d3_b = 13'sd0;                 // 3 dc
reg signed [14:0] d9_b = 15'sd0;                 // 9 dc
reg [1:0]         q_b = 2'd0;
reg [16:0]        s_c = 17'd0, c_c = 17'd0;
reg signed [18:0] ds_c = 19'sd0;                 // |dc * 201| <= 1023 * 201 < 2^18
reg [1:0]         q_c = 2'd0;

always @(posedge clock)
  if (in_strobe) begin
    s_b  <= rd_s[16:0];
    c_b  <= rd_c[16:0];
    d3_b <= (dc <<< 1) + dc;
    d9_b <= (dc <<< 3) + dc;
    q_b  <= q_a;
    s_c  <= s_b;
    c_c  <= c_b;
    ds_c <= (d3_b <<< 6) + d9_b;
    q_c  <= q_b;
  end

//------------------------------------------------------------------------------
// stages D, E: Taylor correction
//------------------------------------------------------------------------------
// Stage D multiplies the scaled residual with the table cosine and sine (pc_d is d cos a and
// ps_d is d sin a, still scaled up by 2^SH). Stage E shifts those down by SH, which turns them
// into a correction in units of 2^-E table steps (floor), and adds it to the table value that
// was shifted up by E: bs_e = sin a + d cos a and bc_e = cos a - d sin a.
reg signed [36:0]    pc_d = 37'sd0, ps_d = 37'sd0;   // ds * cos, ds * sin
reg [16:0]           s_d = 17'd0, c_d = 17'd0;
reg [1:0]            q_d = 2'd0;
reg signed [SCW-1:0] bs_e = {SCW{1'b0}}, bc_e = {SCW{1'b0}};
reg [1:0]            q_e = 2'd0;

wire signed [SCW-1:0] s_d_sh = $signed({1'b0, s_d}) <<< E;
wire signed [SCW-1:0] c_d_sh = $signed({1'b0, c_d}) <<< E;
wire signed [36-SH:0] corr_s = pc_d >>> SH;   // d cos a, added to sin a
wire signed [36-SH:0] corr_c = ps_d >>> SH;   // d sin a, subtracted from cos a

always @(posedge clock)
  if (in_strobe) begin
    pc_d <= ds_c * $signed({1'b0, c_c});
    ps_d <= ds_c * $signed({1'b0, s_c});
    s_d  <= s_c;
    c_d  <= c_c;
    q_d  <= q_c;
    bs_e <= s_d_sh + corr_s;
    bc_e <= c_d_sh - corr_c;
    q_e  <= q_d;
  end

//------------------------------------------------------------------------------
// input delay to stage E / F, mix, output
//------------------------------------------------------------------------------
generate
  if (MODE == 0) begin : rx
    // Receive. The sample is delayed (x_a to x_d) until it meets bs and bc, and in the stage
    // before the multiplies its sign is set from the quadrant: xs_e is x for the sine
    // (negated when the sine is negative) and xc_e the same for the cosine. The negated sample
    // is made one stage early (nx_d) so that the sign stage has no negation in it. The
    // two products mi_f = x cos and mq_f = x sin are then rounded to OUT_WIDTH.
    reg signed [IN_WIDTH-1:0] x_a = 0, x_b = 0, x_c = 0, x_d = 0;
    reg signed [IN_WIDTH:0]    xs_e = 0, xc_e = 0;     // one bit wider: -(-2^(IN_WIDTH-1))
    reg signed [IN_WIDTH:0]    nx_d = 0;               // -x_d, formed one stage early, so the sign stage has no negate
    wire signed [IN_WIDTH:0]   x_c_ext = x_c;
    reg signed [IN_WIDTH+SCW:0] mi_f = 0, mq_f = 0;
    reg signed [OUT_WIDTH-1:0] oi_g = 0, oq_g = 0;

    wire signed [IN_WIDTH:0] x_d_ext = x_d;
    // round half up to OUT_WIDTH: floor(m / 2^(11+E)) + bit (10+E) of m
    // (the shift of 11 + E removes the 2^11 inside the gain 107,922 / 2,048 and the E fraction bits)
    wire signed [OUT_WIDTH-1:0] ri = mi_f[11+E+OUT_WIDTH-1:11+E] + mi_f[10+E];
    wire signed [OUT_WIDTH-1:0] rq = mq_f[11+E+OUT_WIDTH-1:11+E] + mq_f[10+E];

    always @(posedge clock)
      if (in_strobe) begin
        x_a  <= in_i;
        x_b  <= x_a;
        x_c  <= x_b;
        x_d  <= x_c;
        nx_d <= -x_c_ext;
        xs_e <= q_d[1]          ? nx_d : x_d_ext;       // sign of sin t
        xc_e <= (q_d[1] ^ q_d[0]) ? nx_d : x_d_ext;     // sign of cos t
        mi_f <= xc_e * bc_e;
        mq_f <= xs_e * bs_e;
        oi_g <= ri;
        oq_g <= rq;
      end
    assign out_i = oi_g;
    assign out_q = oq_g;
  end else begin : tx
    // Transmit. The two input samples are delayed (i_a.. and q_a_..) to meet the sine and
    // cosine, the signs are applied to those (bss_f and bcs_f), the products pi_g = i cos and
    // pq_g = q sin are formed, and the output is the difference of the two products with 11
    // bits dropped from each (floor), giving Re{(i + jq) e^(jt)}.
    reg signed [IN_WIDTH-1:0] i_a = 0, i_b = 0, i_c = 0, i_d = 0, i_e = 0, i_f = 0;
    reg signed [IN_WIDTH-1:0] q_a_ = 0, q_b_ = 0, q_c_ = 0, q_d_ = 0, q_e_ = 0, q_f_ = 0;
    reg signed [SCW-1:0]          bss_f = 0, bcs_f = 0;
    reg signed [IN_WIDTH+SCW-1:0] pi_g = 0, pq_g = 0;
    reg signed [OUT_WIDTH-1:0]    o_h = 0;

    wire signed [IN_WIDTH+SCW-12:0] pi_t = pi_g >>> 11;
    wire signed [IN_WIDTH+SCW-12:0] pq_t = pq_g >>> 11;
    wire signed [IN_WIDTH+SCW-11:0] diff = pi_t - pq_t;

    always @(posedge clock)
      if (in_strobe) begin
        i_a <= in_i;  i_b <= i_a;  i_c <= i_b;  i_d <= i_c;  i_e <= i_d;  i_f <= i_e;
        q_a_ <= in_q; q_b_ <= q_a_; q_c_ <= q_b_; q_d_ <= q_c_; q_e_ <= q_d_; q_f_ <= q_e_;
        bss_f <= q_e[1]          ? -bs_e : bs_e;
        bcs_f <= (q_e[1] ^ q_e[0]) ? -bc_e : bc_e;
        pi_g  <= i_f * bcs_f;
        pq_g  <= q_f_ * bss_f;
        o_h   <= diff[OUT_WIDTH-1:0];
      end
    assign out_i = o_h;
    assign out_q = {OUT_WIDTH{1'b0}};
  end
endgenerate

endmodule
