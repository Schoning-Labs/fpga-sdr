// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// bk_post: everything the receiver back end does after the channel filter, for all receivers.
// For every 24 ksps complex sample it finds the length and the angle of the sample (a CORDIC),
// updates the S-meter and the squelch, demodulates (SSB/CW/data, AM, synchronous AM, FM or plain
// I/Q), applies an automatic gain control (AGC) that works in the log domain, optionally brings
// the rate down to 12 ksps with a half-band filter (HB5), and delivers a 16-bit audio sample (or
// a 16-bit I/Q pair). Model: fw/tr-dsp/src/backend/post.rs; specification: docs/R4_BACKEND.md
// sections 3.4 to 3.7. The terms are explained in docs/learn/GLOSSARY.md.
//
// How it is organized: one sequential engine serves all receivers, one job per 24 ksps sample,
// and one multiplier (27 x 36, one DSP block) is shared by every multiplication of a job. A job
// is a chain of small states, each of which does one short step of arithmetic (so the engine runs
// at the DSP clock rate), and a multiply is issued by a state, waits a few clocks, and returns to
// the state that issued it. The state of every receiver (S-meter average, DC tracker, carrier
// tracking loop, AGC gain and so on) is kept in small LUT RAMs and loaded when its job is taken
// and written back when it ends. Cost per job: about 60 clocks (SSB) to 85 (SAM), plus 36 (real)
// or 72 (IQ) for HB5 on every second job; 8 receivers take under 20 M of the 120 M clocks per second.
//
// What each part does:
//   CORDIC vectoring (bk_cordic.v): M = |y| (24-bit scale) and phi = angle(y) in 1/2^24 turn. The
//     CORDIC gain K = 1.6468 is removed by multiplying with BK_KINV = round(2^17 / K) = 79,594.
//   Level and S-meter: L = log2(M) in U5.12, from the position of the leading one plus a
//     1,024-entry table of round(4096 log2(1 + m/1024)) indexed by the next 10 bits (worst
//     error 0.0014 octave = 0.009 dB). The S-meter is a one-pole average of L, sm += ((L << 8) - sm)
//     >> k_sm, converted to 1/64 dB relative to an envelope of 2^23: smeter = (((sm >> 8) -
//     23 x 4096) x 6165) >> 16, where 6165 = 2^16 x 20 log10(2) x 64 / 4096. The average is taken
//     of the log, which for noise reads 2.5 dB below the power average; steady carriers read
//     exactly. The firmware adds its own calibration.
//   Squelch: opens when the S-meter exceeds sq_open, closes when it falls below sq_close (the
//     hysteresis is the difference of the two levels); closed means the audio is zero.
//   Demodulators, a = audio on the 24-bit scale:
//     SSB, CW, data: a = Re(y). The channel filter has already removed the other sideband, so
//        the real part is the audio. The CW pitch comes from tuning the receiver `pitch` Hz off
//        the carrier and centering the filter there.
//     AM: a = M - dc, where dc is a slow average of M (dc += ((M << 16) - dc) >> k_dc) that removes
//        the carrier's DC component.
//     SAM (synchronous AM): a phase-locked loop follows the carrier. The sample is rotated back by
//        the loop angle theta, C = Re(y e^(-j theta)) (a CORDIC rotation), e = phi - theta is the
//        phase error, and a proportional-integral loop updates the frequency
//        (freq += (e << 8) >> ki, clamped to +/-2^27, which is +/-750 Hz) and the angle
//        (theta += freq + ((e << 8) >> kp)). The audio is C minus the same DC tracker as AM.
//     FM: a = phi - phi_previous, the change of angle from sample to sample, which is the
//        instantaneous frequency (24-bit wrap-around: +/-2^23 is +/-12 kHz at 24 ksps), with an
//        optional one-pole de-emphasis, de += ((d - de) x alpha + 2^16) >> 17.
//     IQ: the filtered I and Q pass through unchanged (two outputs).
//   AGC in the log domain: the gain G is kept as log2 of a multiplier (S.24 fraction, clamped to
//     [gmin, gmax]) and the target is Gt = clamp((R - L) << 12), so no divider is needed and an
//     attack moves the gain by equal steps in dB. If L + G is above the reference R (the output
//     is too loud) the gain follows the target with the attack coefficient and the hang counter
//     is reloaded; otherwise while the hang counter runs it counts down and the gain holds;
//     otherwise the gain follows the target with the decay coefficient. A coefficient is
//     alpha = a x 2^-(17 + s) (a has 17 bits, s is 0 to 15, so time constants from 0.04 ms to over
//     10 s keep four digits). FM and AGC off use a fixed gain `manual` instead. The gain is
//     applied through a 1,024-entry 2^x table and one multiply: out = sat24(round(a x m x
//     2^((ga >> 10) - 16))).
//   HB5 (half-band to 12 ksps): the same 63-tap filter as the last decimation stage (pass band
//     4.8 kHz, stop band from 7.2 kHz at 24 ksps, 104 dB), real in audio modes and complex in IQ
//     mode. With out24 set it is skipped and the audio stays at 24 ksps (up to 9.6 kHz).
//   Output: s = sat16((v + 128) >> 8).
//
// The AGC runs before HB5 so that its detector sees every 24 ksps sample and HB5 smooths the
// gain changes. A receiver's first sample after enable starts every state from its reset value
// (the AGC starts at maximum gain gmax).

`timescale 1ns / 1ps

module bk_post #(
    parameter HB_FILE   = "rtl/rx_backend/bk_hb.hex",       // half-band coefficients (the HB4 entries are used for HB5)
    parameter LOG2_FILE = "rtl/rx_backend/bk_log2.hex",     // log2 table of the AGC level
    parameter EXP2_FILE = "rtl/rx_backend/bk_exp2.hex",     // 2^x table of the AGC gain
    parameter integer NRX = 8       // receivers built (rx_backend.v): per-receiver state and the HB5 delay line are sized by it
) (
    input  wire         clk,        // DSP clock
    input  wire         rst,        // synchronous reset

    // two input FIFOs (channel-filter units 0 and 1), show-ahead
    input  wire         in0_empty,  // FIFO of channel-filter unit 0 (receivers 0-3) is empty
    input  wire [52:0]  in0_data,   // {epoch, rx[2:0], first, re[23:0], im[23:0]}
    output reg          in0_pop,    // one-clock pulse: take that entry
    input  wire         in1_empty,  // the same for unit 1 (receivers 4-7)
    input  wire [52:0]  in1_data,
    output reg          in1_pop,

    input  wire [7:0]   en,         // per receiver: enabled
    input  wire [7:0]   epoch,      // per receiver: current epoch bit (a job of another epoch is dropped)
    // per-receiver configuration (flattened, receiver r at [r*W +: W])
    input  wire [23:0]  mode,       // 3 bits: 0 SSB/CW/data, 1 AM, 2 SAM, 3 FM, 4 IQ
    input  wire [7:0]   out24,      // 1: stay at 24 ksps (no HB5), 0: half-band to 12 ksps
    input  wire [7:0]   agc_en,     // 1: AGC on, 0: fixed gain `manual`
    input  wire [7:0]   sq_en,      // 1: squelch on
    // The settings of the job's receiver are read from rx_backend's settings memories at cfg_rx
    // (the job's receiver number, in twelve copies, to keep the fan-out low).
    output wire [35:0]  cfg_rx,
    input  wire [3:0]   k_sm,       // S-meter time constant, 2^k samples
    input  wire [3:0]   k_dc,       // DC tracker time constant (AM and SAM), 2^k samples
    input  wire [4:0]   sam_kp,     // SAM loop proportional gain shift
    input  wire [4:0]   sam_ki,     // SAM loop integral gain shift
    input  wire [16:0]  deemph,     // FM de-emphasis coefficient alpha, U0.17 (0 = off)
    input  wire [16:0]  att_a,      // AGC attack coefficient a (alpha = a x 2^-(17+s))
    input  wire [3:0]   att_s,      // AGC attack shift s
    input  wire [16:0]  dec_a,      // AGC decay coefficient a
    input  wire [3:0]   dec_s,      // AGC decay shift s
    input  wire [15:0]  hang_n,     // AGC hang time, in 24 ksps samples
    input  wire [16:0]  agc_ref,    // U5.12
    input  wire [19:0]  gmax,       // S7.12
    input  wire [19:0]  gmin,
    input  wire [19:0]  gman,       // manual gain (AGC off and FM)
    input  wire [15:0]  sq_open_l,  // signed 1/64 dB
    input  wire [15:0]  sq_close_l,

    output reg          out_valid,  // one-clock pulse: a finished output sample
    output reg  [2:0]   out_rx,     // its receiver
    output reg  [15:0]  out_s0,     // audio (or I in IQ mode), 16 bits, two's complement
    output reg  [15:0]  out_s1,     // Q in IQ mode, otherwise 0

    output wire [127:0] st_smeter,  // 16 per receiver: S-meter, signed, 1/64 dB relative to an envelope of 2^23
    output wire [7:0]   st_sq_open, // per receiver: squelch open
    output wire [143:0] st_gain     // 18 per receiver: AGC gain applied, S.10 (octaves)
);
    `include "rtl/rx_backend/bk_consts.vh"

    localparam [2:0] M_SSB = 3'd0, M_AM = 3'd1, M_SAM = 3'd2, M_FM = 3'd3, M_IQ = 3'd4;

    // ---------------------------------------------------------------- tables
    // hb: the half-band coefficients (read for HB5); u_log and u_exp: the log2 table of the level
    // and the 2^x table of the gain, both read with the clock.
    (* syn_romstyle = "distributed_rom" *) reg [31:0] hb [0:BK_HB_ENTRIES-1];
    initial $readmemh(HB_FILE, hb);
    reg  [9:0]  log_addr, exp_addr;
    wire [11:0] log_q;
    wire [16:0] exp_q;
    bk_rom #(.DW(12), .AW(10), .FILE(LOG2_FILE)) u_log (.clk(clk), .addr(log_addr), .data(log_q));
    bk_rom #(.DW(17), .AW(10), .FILE(EXP2_FILE)) u_exp (.clk(clk), .addr(exp_addr), .data(exp_q));

    // ---------------------------------------------------------------- CORDIC
    // c_start pulses to begin a vectoring (c_rot = 0) or a rotation (c_rot = 1) of (c_x, c_y) by c_z.
    reg               c_start, c_rot;
    reg  signed [23:0] c_x, c_y, c_z;
    wire              c_done;
    wire signed [29:0] c_xo;
    wire signed [23:0] c_zo;
    bk_cordic u_cordic (
        .clk(clk), .rst(rst), .start(c_start), .rot(c_rot), .x_in(c_x), .y_in(c_y), .z_in(c_z),
        .done(c_done), .x_out(c_xo), .z_out(c_zo)
    );

    // ---------------------------------------------------------------- shared multiplier
    // Every multiplication of a job goes through one multiplier. The operand pair is picked by
    // msel, a one-hot register set by the state that issues the multiply, from seven registers
    // that are each loaded in one place (oa_x, oa_sm, oa_fm, gd8, aa, ab for a; constants and job
    // settings for b). The seven uses are: MS_X the CORDIC magnitude times 1/K, MS_SM the S-meter
    // level times the dB constant, MS_FM the FM de-emphasis difference times its coefficient,
    // MS_ATT and MS_DEC the AGC step times its attack or decay coefficient, and MS_GA and MS_GB
    // the I (or only) and Q samples times the gain multiplier from the 2^x table. The HB5 filter
    // also uses the multiplier (mac_mode), with the data from its delay line and the coefficient.
    localparam integer MS_X = 0, MS_SM = 1, MS_FM = 2, MS_ATT = 3, MS_DEC = 4, MS_GA = 5,
                       MS_GB = 6;
    reg               mac_mode;          // 1: operands come from the HB5 MAC pipeline
    // one-hot operand select, in copies: three for a (9 bits each), four for b (9 bits each);
    // as one register per operand its fan-out alone would take 4 ns of routing
    (* syn_preserve = 1 *) reg [20:0] msel_a;
    (* syn_preserve = 1 *) reg [27:0] msel_b;
    // msel_n: the select as the issuing state sets it; msel_a/msel_b copy it on the next clock,
    // so the load logic of the copies is not in front of the seven issuing states
    // (every product is therefore one clock later, state S_W5)
    reg        [6:0]  msel_n;
    reg  signed [26:0] oa_x;              // CORDIC magnitude, (x + 4) >>> 3, times 1/K
    reg  signed [26:0] oa_sm;             // S-meter level, times the dB constant
    reg  signed [26:0] oa_fm;             // FM de-emphasis difference, times its coefficient
    reg               iss1_v, iss2_v, iss1_ok, iss2_ok;
    reg  signed [25:0] iss1_c, iss2_c;
    reg               iss1_q, iss2_q;    // which half of the RAM word (0 = I, 1 = Q)
    wire [47:0]       hb_rdata;
    wire signed [23:0] mac_d = !iss2_ok ? 24'sd0 : (iss2_q ? hb_rdata[23:0] : hb_rdata[47:24]);
    reg  signed [26:0] gd8;               // AGC step input (declared here for the operand mux)
    reg  signed [25:0] aa, ab;            // audio / I, Q before the gain (SAM: up to +/-2 x 2^23.5)
    reg  [16:0] c_de, c_atta, c_deca;
    reg         c_dez;                // c_de == 0, worked out in S_MAG (S_FM1's branch)
    wire signed [26:0] kinv = BK_KINV;
    wire signed [26:0] op_a_x  = oa_x;
    wire signed [26:0] op_a_ga = {aa[25], aa};
    wire signed [26:0] op_a_gb = {ab[25], ab};
    wire signed [35:0] op_b_x  = {{9{kinv[26]}}, kinv};
    wire signed [35:0] op_b_sm = 36'sd6165;
    wire        [35:0] op_b_fm = {19'd0, c_de};
    wire        [35:0] op_b_at = {19'd0, c_atta};
    wire        [35:0] op_b_dc = {19'd0, c_deca};
    wire        [35:0] op_b_ex = {19'd0, exp_q};
    wire signed [26:0] op_a;
    wire signed [35:0] op_b;
    genvar gs;
    generate
        for (gs = 0; gs < 3; gs = gs + 1) begin : opa
            wire [6:0] m = msel_a[gs*7 +: 7];
            assign op_a[gs*9 +: 9] = ({9{m[MS_X]}}   & op_a_x[gs*9 +: 9])
                                   | ({9{m[MS_SM]}}  & oa_sm[gs*9 +: 9])
                                   | ({9{m[MS_FM]}}  & oa_fm[gs*9 +: 9])
                                   | ({9{m[MS_ATT] | m[MS_DEC]}} & gd8[gs*9 +: 9])
                                   | ({9{m[MS_GA]}}  & op_a_ga[gs*9 +: 9])
                                   | ({9{m[MS_GB]}}  & op_a_gb[gs*9 +: 9]);
        end
        for (gs = 0; gs < 4; gs = gs + 1) begin : opb
            wire [6:0] m = msel_b[gs*7 +: 7];
            assign op_b[gs*9 +: 9] = ({9{m[MS_X]}}   & op_b_x[gs*9 +: 9])
                                   | ({9{m[MS_SM]}}  & op_b_sm[gs*9 +: 9])
                                   | ({9{m[MS_FM]}}  & op_b_fm[gs*9 +: 9])
                                   | ({9{m[MS_ATT]}} & op_b_at[gs*9 +: 9])
                                   | ({9{m[MS_DEC]}} & op_b_dc[gs*9 +: 9])
                                   | ({9{m[MS_GA] | m[MS_GB]}} & op_b_ex[gs*9 +: 9]);
        end
    endgenerate
    // the selected operands are registered here, in the fabric, before the multiplier's own
    // input register, so that the select is not in front of the DSP block's input pins (one more
    // MAC pipeline stage in vpipe, state S_W3)
    reg  signed [26:0] mul_a;
    reg  signed [35:0] mul_b;
    always @(posedge clk) begin
        msel_a <= {3{msel_n}};
        msel_b <= {4{msel_n}};
        mul_a <= mac_mode ? {{3{mac_d[23]}}, mac_d} : op_a;
        mul_b <= mac_mode ? {{10{iss2_c[25]}}, iss2_c} : op_b;
    end
    wire signed [62:0] mul_pd;
    bk_mul #(.AW(27), .BW(36)) u_mul (.clk(clk), .a(mul_a), .b(mul_b), .p(mul_pd));
    // and the product registered once more in the fabric, so that the DSP block's output does not
    // go straight into the rounding adders (state S_W4, vpipe[3])
    // (syn_preserve: otherwise Gowin moves it into the DSP block's output register, and the
    // rounding behind it starts at the DSP output again)
    (* syn_preserve = 1 *) reg signed [62:0] mul_p;
    always @(posedge clk)
        mul_p <= mul_pd;
    reg [3:0]  vpipe;                   // marks the HB5 products as they come out of the multiplier
    reg signed [51:0] acc;              // HB5 accumulator
    reg        acc_clr;

    // ---------------------------------------------------------------- HB5 delay lines
    // 64 words of {I, Q} per receiver, a circular buffer written with every filtered sample
    // bits of a receiver number in the delay line's address: 1 for NRX <= 2, 2 for <= 4, 3 above (the rest of
    // the module keeps 3-bit receiver numbers; the top bits are 0 for the receivers that are built)
    localparam integer RW = (NRX > 4) ? 3 : (NRX > 2) ? 2 : 1;
    reg         hb_we;
    reg  [RW+5:0] hb_waddr, hb_raddr;
    reg  [47:0] hb_wdata;
    bk_ram #(.DW(48), .AW(RW+6), .SLICE(18)) u_hb5 (
        .clk(clk), .we(hb_we), .waddr(hb_waddr), .wdata(hb_wdata), .raddr(hb_raddr), .rdata(hb_rdata)
    );

    // ---------------------------------------------------------------- per-receiver state
    // The state of each receiver, read when its job is taken and written back when it ends:
    // r_sm the S-meter average (U5.20), r_sqo the squelch state, r_dc the AM DC tracker (24.16),
    // r_th and r_fr the SAM carrier angle and frequency, r_ph the previous angle (FM, and the
    // first sample of SAM), r_de the FM de-emphasis state, r_g the AGC gain (S.24), r_hang the
    // hang counter, and r_wp, r_fill, r_phs the HB5 write pointer, fill and pair phase. s_db and
    // s_gain are the status values that the register block reads.
    (* syn_ramstyle = "distributed_ram" *)
    reg signed [26:0] r_sm   [0:NRX-1];   // U5.20
    (* syn_ramstyle = "distributed_ram" *)
    reg               r_sqo  [0:NRX-1];
    (* syn_ramstyle = "distributed_ram" *)
    reg signed [43:0] r_dc   [0:NRX-1];   // 24.16
    (* syn_ramstyle = "distributed_ram" *)
    reg        [31:0] r_th   [0:NRX-1];
    (* syn_ramstyle = "distributed_ram" *)
    reg signed [28:0] r_fr   [0:NRX-1];
    (* syn_ramstyle = "distributed_ram" *)
    reg signed [23:0] r_ph   [0:NRX-1];
    (* syn_ramstyle = "distributed_ram" *)
    reg signed [24:0] r_de   [0:NRX-1];
    (* syn_ramstyle = "distributed_ram" *)
    reg signed [33:0] r_g    [0:NRX-1];   // S.24
    (* syn_ramstyle = "distributed_ram" *)
    reg        [15:0] r_hang [0:NRX-1];
    (* syn_ramstyle = "distributed_ram" *)
    reg        [5:0]  r_wp   [0:NRX-1];
    (* syn_ramstyle = "distributed_ram" *)
    reg        [6:0]  r_fill [0:NRX-1];
    (* syn_ramstyle = "distributed_ram" *)
    reg               r_phs  [0:NRX-1];
    reg signed [15:0] s_db   [0:NRX-1];
    reg signed [17:0] s_gain [0:NRX-1];

    genvar gi;
    generate
        for (gi = 0; gi < 8; gi = gi + 1) begin : stat
            if (gi < NRX) begin : used
                assign st_smeter[gi*16 +: 16]  = s_db[gi];
                assign st_sq_open[gi]          = r_sqo[gi];
                assign st_gain[gi*18 +: 18]    = s_gain[gi];
            end else begin : unused
                assign st_smeter[gi*16 +: 16]  = 16'd0;
                assign st_sq_open[gi]          = 1'b0;
                assign st_gain[gi*18 +: 18]    = 18'd0;
            end
        end
    endgenerate

    // ---------------------------------------------------------------- job registers
    // The job in progress: its receiver, flags, the filtered sample (yr, yi) and the copies of the
    // receiver's settings and state, which the states below work on (w_*) before they are written
    // back. syn_maxfan on rx: as one register its 91 loads (the address pins of the settings
    // memories) took 8.6 ns of routing, so the tool is told to make copies.
    reg  [2:0]  rx /* synthesis syn_maxfan = 10000 */;
    reg         first, ep;
    reg         first_ph;             // a copy of first, for w_ph (S_MAG)
    reg  signed [23:0] yr, yi;
    reg  [2:0]  cm;          // mode
    // the mode as flags, and copies of `first`, loaded with the job (decoded from cm, or as one
    // net, they would fan out to the load enables of whole groups of registers)
    reg         mo_am, mo_sam, mo_fm, mo_iq;          // SSB (and codes 5..7): none of them
    reg         mo_ssb;                               // none of them
    (* syn_preserve = 1 *) reg [4:0] first_c;
    reg         c_out24, c_agc, c_sq;
    reg  [3:0]  c_ksm, c_kdc;
    reg  [4:0]  c_kp, c_ki;
    reg  [16:0] c_ref;
    reg  [3:0]  c_atts, c_decs;
    reg  [15:0] c_hang;
    reg  signed [33:0] c_gmax, c_gmin, c_gman;   // already << 12
    reg  signed [15:0] c_sqo, c_sqc;

    reg  signed [26:0] w_sm;
    reg                w_sqo;
    reg  signed [43:0] w_dc;
    reg                w_dc_ce;
    reg                cxy_ce;
    reg         [31:0] w_th;
    reg  signed [28:0] w_fr;
    reg  signed [23:0] w_ph;
    reg  signed [24:0] w_de;
    reg  signed [33:0] w_g;
    reg         [15:0] w_hang;
    reg         [5:0]  w_wp;
    reg         [6:0]  w_fill;
    reg                w_phs;

    // the quantities of the job: the CORDIC's raw magnitude and angle, the magnitude M, the
    // log level L, the SAM or AM carrier, the gained I and Q, the gain applied, the HB5
    // output and the HB5 tap counters
    reg  signed [29:0] xv;       // CORDIC raw magnitude
    reg  signed [23:0] phi;
    reg  signed [24:0] mag;      // M
    reg         [16:0] lvl;      // L, U5.12
    reg  signed [24:0] ca;       // c for AM / SAM
    reg                ca_rb;    // rounding bit of ca (SAM carrier), added in S_ROT2_B
    reg  signed [23:0] ga_i, ga_q;
    reg  signed [17:0] ga;       // gain applied, S.10
    reg  signed [23:0] th24;
    reg  signed [23:0] vi, vq;   // HB5 output (or the gained sample at 24 ksps)
    reg  [5:0]  idx;
    reg  [6:0]  t;
    reg  [3:0]  drain;
    reg         mac_q;           // HB5 MAC on the Q half
    reg         pick1;           // round-robin between the two inputs

    // ---------------------------------------------------------------- helpers
    // sat24 limits a wide value to the 24-bit range, msb25 gives the position of the leading one
    // of M, and (below) midx is M shifted so that its top 10 bits after the leading one become the
    // index of the log table.
    function signed [23:0] sat24;
        input signed [70:0] v;
        begin
            if (v > 71'sd8388607)       sat24 = 24'sd8388607;
            else if (v < -71'sd8388608) sat24 = -24'sd8388608;
            else                        sat24 = v[23:0];
        end
    endfunction
    // leading-one position of M (M < 2^25) and the log-table index
    function [4:0] msb25;
        input [24:0] v;
        integer b;
        begin
            msb25 = 5'd0;
            for (b = 0; b < 25; b = b + 1)
                if (v[b]) msb25 = b[4:0];
        end
    endfunction
    reg  [4:0]  mpos;                 // msb25(mag), registered in S_MAG2
    wire [34:0] mwide = {10'd0, mag[24:0]};
    reg         m_right;              // S_MAG2B: mpos >= 10
    reg  [4:0]  m_amt;                // S_MAG2B: |mpos - 10|
    wire [9:0]  midx = m_right ? (mwide >> m_amt) : (mwide << m_amt);

    // ---------------------------------------------------------------- FSM
    // Every state does one short step of arithmetic that fits in one clock, and a step that does
    // not fit is split into several (the split-off states are the ones named ..._B, ..._C, ...
    // below, plus S_TAKE, S_MAG3, S_FM1, S_AGP1-3, S_MEND0 and S_OUT0). A job takes a few
    // hundred clocks at most, well under the about 780 available per job at 8 receivers x 24 ksps.
    // The path of a job: S_IDLE, S_TK0, S_TAKE (take a job), S_VEC (CORDIC), S_MAG (|y|),
    // S_MAG2..S_LOG2 (level), S_SM.. (S-meter and squelch), S_DEM (demodulator, with S_ROT.. for
    // SAM, S_FM.. for FM and S_DC.. for the DC tracker of AM and SAM), S_AGP.. and S_AGC.. (AGC),
    // S_GAIN.. (gain), S_HB, S_MAC, S_MWAIT, S_MEND (HB5), S_OUT0, S_OUT and S_WB (output and
    // write back). S_W1..S_W5 are the wait for a multiply.
    localparam
        S_IDLE = 6'd0,  S_VEC = 6'd1,  S_MAG = 6'd2,  S_LOG = 6'd3,  S_LOG2 = 6'd4,
        S_SM = 6'd5,    S_SM2 = 6'd6,  S_DEM = 6'd7,  S_ROT = 6'd8,  S_ROT2 = 6'd9,
        S_FM2 = 6'd10,  S_DC = 6'd11,  S_AGC = 6'd12, S_AGC2 = 6'd13, S_GAIN = 6'd14,
        S_GAIN2 = 6'd15, S_GAIN3 = 6'd16, S_HB = 6'd17, S_MAC = 6'd18, S_MWAIT = 6'd19,
        S_MEND = 6'd20, S_OUT = 6'd21, S_WB = 6'd22, S_W1 = 6'd23, S_W2 = 6'd24, S_MAG2 = 6'd25,
        S_GAIN1 = 6'd26,
        S_TAKE = 6'd27, S_MAG3 = 6'd28, S_SM_B = 6'd29, S_SM_C = 6'd30, S_FM1 = 6'd31,
        S_ROT2_B = 6'd32, S_ROT2_C = 6'd33, S_ROT2_D = 6'd34, S_ROT2_E = 6'd35,
        S_FM2_B = 6'd36, S_DC_B = 6'd37, S_DC_C = 6'd38,
        S_AGP1 = 6'd39, S_AGP2 = 6'd40, S_AGP3 = 6'd41,
        S_AGC2_B = 6'd42, S_AGC2_C = 6'd43, S_AGC2_D = 6'd44,
        S_GAIN3_B = 6'd45, S_GAIN3_C = 6'd46, S_GAIN3_D = 6'd47,
        S_MEND0 = 6'd48, S_OUT0 = 6'd49, S_AGC2_E = 6'd50,
        S_SM_B2 = 6'd51, S_DC_B2 = 6'd52, S_ROT2_B2 = 6'd53, S_SM3 = 6'd54,
        S_W3 = 6'd55, S_AGP2_B = 6'd56, S_GAIN3_C2 = 6'd57, S_GAIN3_S = 6'd58,
        S_SM_BH = 6'd59, S_DC_BH = 6'd60, S_ROT2_BH = 6'd61, S_W4 = 6'd62, S_ROT2_CF = 6'd63,
        S_W5 = 7'd64, S_TK0 = 7'd65, S_AGC2_BH = 7'd66, S_SM4 = 7'd67, S_MAG2B = 7'd68;
    // The state is 69 separate flags, s[S_x]: one flip-flop per state, each state's work written
    // as its own `if (s[S_x])` block rather than as a branch of one case statement, and every
    // clock s is cleared and the block of the active state sets its successor's flag. So a flag's
    // next value is an OR over the few states that lead to it, and a register's load enable
    // depends only on the states that load it. A binary state register with a one-hot encoding
    // attribute, or a case statement over the flags, makes the Gowin tool build logic in which
    // every state flip-flop depends on the whole state vector, which is much slower. The state
    // numbers above are the flag indices; `st`, the binary state, exists in simulation only
    // (testbenches use it). syn_preserve keeps synthesis from re-extracting a state machine.
    (* syn_preserve = 1 *) reg [68:0] s;
    // the state a multiply's four wait states return to, one-hot:
    // S_MAG, S_SM2, S_FM2, S_ROT2, S_AGC2, S_GAIN3
    reg [5:0] retq;
    // synthesis translate_off
    reg [6:0] st;
    integer si;
    always @(*) begin
        st = 7'd0;
        for (si = 0; si < 69; si = si + 1)
            if (s[si]) st = si;
    end
    // synthesis translate_on
    reg       att;               // AGC update uses the attack coefficient

    // current job's tap: read from the table into iss0_w (its own clock), used a clock later
    reg  [6:0]  ta;                       // BK_HB4_START + t, the HB5 table address
    wire [31:0] tap_w   = hb[ta];
    reg         iss0_v, iss0_q;
    reg  [31:0] iss0_w;
    wire [5:0]  tap_off = iss0_w[31:26];

    // AGC target and step, worked out over S_AGP1-3 from registered values (lvl, c_ref, c_gmax,
    // c_gmin, w_g and w_hang do not change between S_AGP1 and S_AGC)
    reg  signed [34:0] gt_raw, gt;
    reg                above;
    reg                wg_hi, wg_lo;      // S_AGP1: w_g > c_gmax, w_g < c_gmin
    reg                gt_hi, gt_lo;      // S_AGP2: gt_raw > c_gmax, gt_raw < c_gmin
    wire               agc_act = c_agc && !mo_fm;
    // S_AGC's four-way decision (attack, hold, decay or manual gain), made in S_AGP2/S_AGP3 into
    // registers, because made in S_AGC itself from cm, c_agc, above and w_hang != 0 it would sit
    // in front of the loads of the multiplier operands, w_g and w_hang
    reg                ag_act, ag_hnz;    // S_AGP2: agc_act, w_hang != 0
    reg         [15:0] hang_m1;           // S_AGP2: w_hang - 1
    reg                p_att, p_hang, p_dec;   // S_AGP3: attack, hold, decay (else manual gain)
    // The gain after this job's AGC update. w_g keeps the gain the job started with (from the
    // receiver's state, or c_gmax on its first sample), read by S_AGP1-S_AGC2_C; g_new is
    // loaded in S_AGC or S_AGC2_E, read from S_GAIN on and written back. (Before, w_g itself was
    // loaded from five places.) Every job that is written back passes S_AGC.
    reg  signed [33:0] g_new;

    // registers of the split states
    reg  [52:0]        jr;                // S_IDLE -> S_TAKE: the job taken
    reg                take_ok;           // S_IDLE -> S_TAKE: the job's receiver is enabled
    // (twelve copies: groups 1-4 have two each, 8-11 the second)
    (* syn_preserve = 1 *) reg [11:0] take_c;   // S_TAKE, in twelve copies
    (* syn_preserve = 1 *) reg [35:0] jrx_c;    // jr[51:49], in twelve copies
    assign cfg_rx = jrx_c;
    reg  signed [26:0] d_sm, sms_r;       // S_SM
    // the variable right shifts by a job setting, in two clocks each (by 4 x amt[4:2], then by
    // amt[1:0]): S_SM_BH, S_DC_BH, S_ROT2_BH hold the first half
    reg  signed [26:0] sms_h;
    reg  signed [43:0] dcs_h;
    reg  signed [31:0] kis_h, pterm_h;
    reg                mzero;             // S_MAG2: mag == 0
    reg  signed [43:0] dcs_r;             // S_DC_B
    reg  signed [31:0] kis_r;             // S_ROT2_B
    reg  signed [62:0] agc_bias;          // S_AGC: 2^(8 + sh) for S_AGC2
    reg  signed [23:0] fm_d;              // S_DEM (FM)
    reg  signed [31:0] e32_r, pterm_r;    // S_ROT2
    reg  signed [33:0] fn_raw, fn_r;
    reg                fn_hi, fn_lo;      // S_ROT2_CF
    reg         [31:0] th_t;
    reg         [24:0] fm_t;              // S_FM2
    reg  signed [43:0] dcd_r;             // S_DC
    reg  signed [62:0] agc_sum;           // S_AGC2
    reg         [3:0]  agc_sh;
    reg  signed [62:0] stp_h;             // S_AGC2_BH
    reg         [34:0] stp35;
    reg  signed [34:0] ng_r;
    reg                ng_over, ng_under;
    reg  signed [33:0] wg_clamped;        // S_AGP2: w_g clamped to [gmin, gmax], for S_AGC's hang
    reg  signed [15:0] db_r;              // S_SM2 -> S_SM3
    reg                sq_gt, sq_lt;      // S_SM3 -> S_SM4: db_r above the open level, below the close level
    reg  signed [9:0]  tt_r;              // S_GAIN1: apply_gain's shift, clamped to [-48, 24]
    reg                g_left;            // S_GAIN2: tt_r >= 0
    reg  signed [70:0] g_bias;            // S_GAIN2: 2^(-tt_r - 1) when tt_r < 0, else 0
    reg         [2:0]  g_coarse, g_fine;  // S_GAIN2: |tt_r| = 8 x g_coarse + g_fine
    reg  signed [70:0] gw1, gw2, gw3, gw4;  // S_GAIN3 .. S_GAIN3_C2
    reg                gs_hi, gs_lo;      // S_GAIN3_S: gw4 above / below the 24-bit range
    reg  signed [23:0] gs_v;              // S_GAIN3_S: gw4[23:0]
    reg  signed [51:0] mend_r;            // S_MEND0
    reg  signed [24:0] or_i, or_q;        // S_OUT0
    function signed [15:0] sat16;
        input signed [24:0] r;
        begin
            if (r > 25'sd32767)       sat16 = 16'sd32767;
            else if (r < -25'sd32768) sat16 = -16'sd32768;
            else                      sat16 = r[15:0];
        end
    endfunction

    integer k;
    always @(posedge clk) begin
        in0_pop   <= 1'b0;
        in1_pop   <= 1'b0;
        take_c    <= 12'h000;
        out_valid <= 1'b0;
        c_start   <= 1'b0;
        hb_we     <= 1'b0;
        iss0_v    <= 1'b0;
        iss1_v    <= iss0_v;
        if (iss0_v) begin
            iss1_c   <= iss0_w[25:0];
            iss1_q   <= iss0_q;
            iss1_ok  <= {1'b0, tap_off} < w_fill;
            hb_raddr <= {rx[RW-1:0], idx - tap_off};
        end
        iss2_v    <= iss1_v;
        iss2_ok   <= iss1_ok;
        iss2_c    <= iss1_c;
        iss2_q    <= iss1_q;
        vpipe     <= {vpipe[2:0], iss2_v};
        if (vpipe[3])
            acc <= acc + mul_p[51:0];
        // cleared the clock after a MAC pass is started (S_HB, S_MEND set acc_clr), from a
        // register and not from those states' own decisions, which would be a long path into the
        // accumulator's 52 bits. The pass's first product lands several clocks later.
        acc_clr <= 1'b0;
        if (acc_clr)
            acc <= 52'sd0;
        if (rst) begin
            s <= 69'd1 << S_IDLE;
            vpipe <= 4'd0;
            iss0_v <= 1'b0;
            iss1_v <= 1'b0;
            iss2_v <= 1'b0;
            mac_mode <= 1'b0;
            mac_q <= 1'b0;
            pick1 <= 1'b0;
            for (k = 0; k < NRX; k = k + 1) begin
                r_sqo[k] <= 1'b0;
                s_db[k] <= 16'sd0;
                s_gain[k] <= 18'sd0;
            end
        end else begin
            // S_TAKE's loads of the job's settings and its receiver's state, in eight groups, each
            // enabled by its own copy of the "job taken" flag and indexed by its own copy of the
            // receiver number (take_c, jrx_c): as one enable and one select for all of them,
            // those two nets would have a fan-out of several hundred and be too slow.
            if (take_c[0]) begin
                rx      <= jrx_c[0*3 +: 3];
                ep      <= jr[52];
                first   <= jr[48];
                first_ph <= jr[48];
                yr      <= jr[47:24];
                yi      <= jr[23:0];
                cm      <= mode[jrx_c[0*3 +: 3]*3 +: 3];
                mo_am   <= mode[jrx_c[0*3 +: 3]*3 +: 3] == M_AM;
                mo_sam  <= mode[jrx_c[0*3 +: 3]*3 +: 3] == M_SAM;
                mo_fm   <= mode[jrx_c[0*3 +: 3]*3 +: 3] == M_FM;
                mo_iq   <= mode[jrx_c[0*3 +: 3]*3 +: 3] == M_IQ;
                mo_ssb  <= mode[jrx_c[0*3 +: 3]*3 +: 3] != M_AM && mode[jrx_c[0*3 +: 3]*3 +: 3] != M_SAM &&
                           mode[jrx_c[0*3 +: 3]*3 +: 3] != M_FM && mode[jrx_c[0*3 +: 3]*3 +: 3] != M_IQ;
                c_out24 <= out24[jrx_c[0*3 +: 3]];
                c_agc   <= agc_en[jrx_c[0*3 +: 3]];
                c_sq    <= sq_en[jrx_c[0*3 +: 3]];
            end
            if (take_c[1]) begin
                c_ksm   <= k_sm;
                c_kdc   <= k_dc;
                c_kp    <= sam_kp;
                c_ki    <= sam_ki;
            end
            if (take_c[11])
                c_de    <= deemph;
            if (take_c[2]) begin
                c_atta  <= att_a;
                c_atts  <= att_s;
            end
            if (take_c[10]) begin
                c_deca  <= dec_a;
                c_decs  <= dec_s;
            end
            if (take_c[3]) begin
                c_hang  <= hang_n;
                c_ref   <= agc_ref;
            end
            if (take_c[8]) begin
                c_sqo   <= sq_open_l;
                c_sqc   <= sq_close_l;
            end
            if (take_c[4]) begin
                c_gmax  <= $signed(gmax) <<< 12;
                c_gmin  <= $signed(gmin) <<< 12;
            end
            if (take_c[9])
                c_gman  <= $signed(gman) <<< 12;
            // A receiver's first sample (`first`) starts from the reset state instead of the stored
            // one: loaded that way here, with the job, except w_ph, whose starting value is the
            // sample's own angle (S_VEC), and
            // w_g, which starts at c_gmax (S_LOG; nothing reads w_g before S_AGP1).
            if (take_c[5]) begin
                w_sm    <= r_sm[jrx_c[5*3 +: 3]];
                w_sqo   <= first_c[0] ? 1'b0 : r_sqo[jrx_c[5*3 +: 3]];
            end
            if (take_c[6]) begin
                w_th    <= first_c[1] ? 32'd0  : r_th[jrx_c[6*3 +: 3]];
                w_fr    <= first_c[1] ? 29'sd0 : r_fr[jrx_c[6*3 +: 3]];
                w_ph    <= r_ph[jrx_c[6*3 +: 3]];
                w_de    <= first_c[1] ? 25'sd0 : r_de[jrx_c[6*3 +: 3]];
            end
            if (take_c[7]) begin
                w_g     <= r_g[jrx_c[7*3 +: 3]];   // first sample: c_gmax, in S_LOG
                w_hang  <= first_c[3] ? 16'd0 : r_hang[jrx_c[7*3 +: 3]];
                w_wp    <= first_c[3] ? 6'd0  : r_wp[jrx_c[7*3 +: 3]];
                w_fill  <= first_c[4] ? 7'd0  : r_fill[jrx_c[7*3 +: 3]];
                w_phs   <= first_c[4] ? 1'b0  : r_phs[jrx_c[7*3 +: 3]];
            end
            // w_dc loads in two places, at the take (take_c[5]) and in S_DC_B2, on one registered
            // flag of its own, w_dc_ce, set the clock before either (its load enable as a LUT
            // behind the state flags would be too slow)
            w_dc_ce <= s[S_TK0] || s[S_DC_BH];
            if (w_dc_ce)
                w_dc <= !s[S_DC_B2] ? r_dc[jrx_c[5*3 +: 3]]
                      : first ? ($signed({ca[24], ca}) <<< 16) : w_dc + dcs_r;
            // the CORDIC's magnitude as a multiplier operand; c_done pulses only in S_VEC and S_ROT
            if (c_done)
                oa_x <= (c_xo + 30'sd4) >>> 3;
            s <= 69'd0;                        // every state below names its successor
            // ------------------------------------------------------------ take a job
            // jr is loaded in every S_IDLE clock (not enabled by the take condition, whose fan-out
            // would be too slow); it is only used from S_TK0 on, and S_TK0 follows only a take.
            // The job word is taken in S_IDLE, and its receiver number, first flag and enable test
            // are worked out from the registered word in S_TK0, a clock later, because going from
            // the FIFO pick into the eight copies of the receiver number in one clock is too slow.
            // The two FIFOs are served in turn (pick1) so neither can starve the other.
            if (s[S_IDLE]) begin : take
                reg use1;
                use1 = in0_empty || (!in1_empty && pick1);
                jr    <= use1 ? in1_data : in0_data;
                if (!in0_pop && !in1_pop && (!in0_empty || !in1_empty)) begin
                    if (use1) in1_pop <= 1'b1; else in0_pop <= 1'b1;
                    pick1 <= !use1;
                    s[S_TK0] <= 1'b1;
                end
            end
            if (s[S_TK0]) begin
                take_ok <= en[jr[51:49]] && epoch[jr[51:49]] == jr[52];
                jrx_c   <= {12{jr[51:49]}};
                first_c <= {5{jr[48]}};
                take_c  <= 12'hFFF;
                s[S_TAKE] <= 1'b1;
            end
            // c_x, c_y and c_rot load in S_TAKE (the vectoring's input) and S_SM3 (the SAM
            // rotation's), on one registered flag of their own set the clock before either
            // (as a LUT behind the two state flags it would be too slow)
            cxy_ce <= s[S_TK0] || s[S_SM2];
            if (cxy_ce) begin
                c_rot <= s[S_SM3];
                c_x   <= s[S_SM3] ? yr : jr[47:24];
                c_y   <= s[S_SM3] ? yi : jr[23:0];
            end
            if (s[S_TAKE]) begin
                if (take_ok) begin
                    c_start <= 1'b1;
                    s[S_VEC] <= 1'b1;
                end else
                    s[S_IDLE] <= 1'b1;
            end
            // ------------------------------------------------------------ |y|, angle(y)
            // The CORDIC returns K|y| in c_xo (not yet divided by the gain K) and the angle in c_zo.
            // The multiply of K|y| by 1/K is issued as the CORDIC finishes and comes back to S_MAG.
            if (s[S_VEC]) if (c_done) begin
                xv  <= c_xo;
                phi <= c_zo;
                s[S_W1] <= 1'b1;
            end
            if (s[S_W1]) s[S_W2] <= 1'b1;
            if (s[S_W2]) s[S_W3] <= 1'b1;
            if (s[S_W3]) s[S_W4] <= 1'b1;
            if (s[S_W4]) s[S_W5] <= 1'b1;
            if (s[S_W5]) begin                // back to the state that issued the multiply
                if (retq[0]) s[S_MAG] <= 1'b1;
                if (retq[1]) s[S_SM2] <= 1'b1;
                if (retq[2]) s[S_FM2] <= 1'b1;
                if (retq[3]) s[S_ROT2] <= 1'b1;
                if (retq[4]) s[S_AGC2] <= 1'b1;
                if (retq[5]) s[S_GAIN3] <= 1'b1;
            end
            if (s[S_MAG]) begin
                // a receiver's first sample: w_ph starts at the sample's own angle (phi, from
                // S_VEC; nothing reads w_ph before S_DEM). Here rather than in S_VEC, from its own
                // copy of `first`, which keeps the path short.
                if (first_ph)
                    w_ph <= phi;
                // (mul_p + 2^17) >>> 18 in 25 bits, as mul_p[42:18] + mul_p[17]: the same bits,
                // a 25-bit increment instead of a 63-bit add
                mag <= $signed(mul_p[42:18]) + $signed({24'd0, mul_p[17]});
                c_dez <= c_de == 17'd0;
                s[S_MAG2] <= 1'b1;
            end
            if (s[S_MAG2]) begin
                mpos <= msb25(mag[24:0]);
                mzero <= mag == 25'sd0;
                s[S_MAG2B] <= 1'b1;
            end
            // the log-table index's shift direction and amount a clock ahead of the shift
            // (worked out from mpos in one clock it would be too slow)
            if (s[S_MAG2B]) begin
                m_right <= mpos >= 5'd10;
                m_amt   <= (mpos >= 5'd10) ? mpos - 5'd10 : 5'd10 - mpos;
                s[S_MAG3] <= 1'b1;
            end
            if (s[S_MAG3]) begin
                log_addr <= midx;
                s[S_LOG] <= 1'b1;
            end
            if (s[S_LOG]) begin                       // table read
                if (first_c[2])
                    w_g <= c_gmax;             // a receiver's first sample: the AGC starts at gmax
                s[S_LOG2] <= 1'b1;
            end
            // The level L = log2(M) in U5.12: the leading-one position is the integer part (5 bits)
            // and the table output the fraction (12 bits); a zero magnitude has level 0.
            if (s[S_LOG2]) begin
                lvl <= mzero ? 17'd0 : {mpos, log_q};
                s[S_SM] <= 1'b1;
            end
            // ------------------------------------------------------------ S-meter, squelch
            // sm moves toward L with the time constant 2^k_sm (a two-step shift); the first sample of a
            // receiver sets it to L. Then the level is converted to 1/64 dB (the multiply by 6165,
            // with 23 x 4096 = 94,208 taken off to make it relative to an envelope of 2^23).
            if (s[S_SM]) begin
                d_sm <= $signed({2'b0, lvl, 8'd0}) - w_sm;
                s[S_SM_B] <= 1'b1;
            end
            if (s[S_SM_B]) begin
                sms_h <= d_sm >>> {c_ksm[3:2], 2'b00};
                s[S_SM_BH] <= 1'b1;
            end
            if (s[S_SM_BH]) begin
                sms_r <= sms_h >>> c_ksm[1:0];
                s[S_SM_B2] <= 1'b1;
            end
            if (s[S_SM_B2]) begin
                w_sm <= first ? $signed({2'b0, lvl, 8'd0}) : w_sm + sms_r;
                s[S_SM_C] <= 1'b1;
            end
            if (s[S_SM_C]) begin
                oa_sm <= (w_sm >>> 8) - 27'sd94208;
                s[S_W1] <= 1'b1;
            end
            if (s[S_SM2]) begin : sm2
                reg signed [15:0] db;
                db = mul_p >>> 16;
                s_db[rx] <= db;
                db_r <= db;
                s[S_SM3] <= 1'b1;
            end
            // squelch decision, a clock after the S-meter: the compares in S_SM3, the update in
            // S_SM4 (in one clock it would be too slow)
            // The squelch has two thresholds, so it opens above sq_open and only closes again below
            // sq_close, which stops it from chattering at the edge.
            if (s[S_SM3]) begin
                sq_gt <= db_r > c_sqo;
                sq_lt <= db_r < c_sqc;
                // the SAM rotation's CORDIC inputs, for every mode (only SAM starts it, in
                // S_DEM; the vectoring started at the take has long taken its inputs). Here
                // rather than in S_DEM behind the mode test, which would be too slow.
                c_z <= -$signed(w_th[31:8]);
                s[S_SM4] <= 1'b1;
            end
            if (s[S_SM4]) begin
                if (sq_gt)      w_sqo <= 1'b1;
                else if (sq_lt) w_sqo <= 1'b0;
                s[S_DEM] <= 1'b1;
            end
            // ------------------------------------------------------------ demodulator
            // (the mode flags are mutually exclusive: one if-block each rather than a priority
            // case)
            if (s[S_DEM] && mo_am) begin
                ca <= mag;
                s[S_DC] <= 1'b1;
            end
            // SAM: start the CORDIC rotation by -theta (the angle is the top 24 bits of the 32-bit w_th).
            if (s[S_DEM] && mo_sam) begin
                th24 <= w_th[31:8];
                c_start <= 1'b1;
                s[S_ROT] <= 1'b1;
            end
            // FM: the angle step since the last sample, in 1/2^24 turn; the old angle is kept.
            if (s[S_DEM] && mo_fm) begin
                fm_d <= phi - w_ph;
                w_ph <= phi;
                s[S_FM1] <= 1'b1;
            end
            if (s[S_DEM] && mo_iq) begin
                aa <= yr;
                ab <= yi;
                s[S_AGP1] <= 1'b1;
            end
            // SSB, CW and data: the real part is the audio.
            if (s[S_DEM] && mo_ssb) begin
                aa <= yr;
                ab <= 26'sd0;
                s[S_AGP1] <= 1'b1;
            end
            if (s[S_FM1]) begin
                if (c_dez) begin
                    aa <= fm_d;
                    ab <= 26'sd0;
                    s[S_AGP1] <= 1'b1;
                end else begin
                    aa <= fm_d;    // kept for S_FM2
                    oa_fm <= $signed({{3{fm_d[23]}}, fm_d}) - $signed({{2{w_de[24]}}, w_de});
                    ab <= 26'sd0;
                    s[S_W1] <= 1'b1;
                end
            end
            if (s[S_ROT]) if (c_done) begin
                s[S_W1] <= 1'b1;
            end
            // The rotation is done: ca = C, the carrier-aligned amplitude. The phase error e is the angle
            // of the sample minus theta, and the loop is a proportional-integral controller: the
            // frequency w_fr integrates e (ki), and the angle w_th advances by the frequency plus a
            // proportional part (kp). The frequency is clamped to +/-2^27 of the 32-bit angle units.
            if (s[S_ROT2]) begin : rot2
                reg signed [23:0] e24;
                e24 = phi - th24;
                e32_r <= {e24, 8'd0};
                // (mul_p + 2^17) >>> 18, in two clocks, because the 25-bit increment behind the mul_p
                // register and the state select is too many logic levels for one clock: the cut
                // here, the rounding bit added in the next state; ca is not read before S_DC
                ca <= $signed(mul_p[42:18]);
                ca_rb <= mul_p[17];
                s[S_ROT2_B] <= 1'b1;
            end
            if (s[S_ROT2_B]) begin
                ca <= ca + $signed({24'd0, ca_rb});
                kis_h   <= e32_r >>> {c_ki[4:2], 2'b00};
                pterm_h <= e32_r >>> {c_kp[4:2], 2'b00};
                s[S_ROT2_BH] <= 1'b1;
            end
            if (s[S_ROT2_BH]) begin
                kis_r   <= kis_h >>> c_ki[1:0];
                pterm_r <= pterm_h >>> c_kp[1:0];  // kept signed (a part-select would make it logical)
                s[S_ROT2_B2] <= 1'b1;
            end
            if (s[S_ROT2_B2]) begin
                fn_raw  <= w_fr + kis_r;
                s[S_ROT2_CF] <= 1'b1;
            end
            if (s[S_ROT2_CF]) begin                   // the clamp's compares, a clock before its select
                fn_hi <= fn_raw > 34'sd134217728;
                fn_lo <= fn_raw < -34'sd134217728;
                s[S_ROT2_C] <= 1'b1;
            end
            if (s[S_ROT2_C]) begin : rot2c
                reg signed [33:0] fn;
                fn = fn_hi ? 34'sd134217728 : fn_lo ? -34'sd134217728 : fn_raw;
                w_fr <= fn[28:0];
                fn_r <= fn;
                s[S_ROT2_D] <= 1'b1;
            end
            if (s[S_ROT2_D]) begin
                th_t <= w_th + fn_r[31:0];
                s[S_ROT2_E] <= 1'b1;
            end
            if (s[S_ROT2_E]) begin
                w_th <= th_t + pterm_r;
                s[S_DC] <= 1'b1;
            end
            if (s[S_FM2]) begin : fm2
                reg signed [62:0] t;
                t = (mul_p + 63'sd65536) >>> 17;
                fm_t <= t[24:0];
                s[S_FM2_B] <= 1'b1;
            end
            if (s[S_FM2_B]) begin : fm2b
                reg signed [24:0] nde;
                nde = w_de + fm_t;
                w_de <= nde;
                aa <= nde;
                s[S_AGP1] <= 1'b1;
            end
            if (s[S_DC]) begin
                dcd_r <= ($signed({ca[24], ca}) <<< 16) - w_dc;
                s[S_DC_B] <= 1'b1;
            end
            if (s[S_DC_B]) begin
                dcs_h <= dcd_r >>> {c_kdc[3:2], 2'b00};
                s[S_DC_BH] <= 1'b1;
            end
            if (s[S_DC_BH]) begin
                dcs_r <= dcs_h >>> c_kdc[1:0];
                s[S_DC_B2] <= 1'b1;
            end
            if (s[S_DC_B2]) begin
                s[S_DC_C] <= 1'b1;
            end
            if (s[S_DC_C]) begin
                aa <= ca - (w_dc >>> 16);
                ab <= 26'sd0;
                s[S_AGP1] <= 1'b1;
            end
            // ------------------------------------------------------------ AGC
            // AGC. gt_raw = R - L is the target gain, `above` says that the output level L + G is over
            // the reference, and wg_hi and wg_lo find out if the stored gain is outside its limits.
            if (s[S_AGP1]) begin
                gt_raw <= $signed({1'b0, c_ref, 12'd0}) - $signed({1'b0, lvl, 12'd0});
                above  <= ($signed({1'b0, lvl}) + (w_g >>> 12)) > $signed({1'b0, c_ref});
                wg_hi  <= w_g > c_gmax;
                wg_lo  <= w_g < c_gmin;
                s[S_AGP2] <= 1'b1;
            end
            // (the clamps: compare in one clock, select in the next)
            if (s[S_AGP2]) begin
                gt_hi <= gt_raw > c_gmax;
                gt_lo <= gt_raw < c_gmin;
                wg_clamped <= wg_hi ? c_gmax : wg_lo ? c_gmin : w_g;
                ag_act  <= agc_act;
                ag_hnz  <= w_hang != 16'd0;
                hang_m1 <= w_hang - 16'd1;
                s[S_AGP2_B] <= 1'b1;
            end
            if (s[S_AGP2_B]) begin
                gt <= gt_hi ? c_gmax : gt_lo ? c_gmin : gt_raw;
                s[S_AGP3] <= 1'b1;
            end
            if (s[S_AGP3]) begin : agp3
                reg signed [34:0] gdiff;
                gdiff = gt - w_g;
                gd8 <= gdiff >>> 8;
                p_att  <= ag_act && above;
                p_hang <= ag_act && !above && ag_hnz;
                p_dec  <= ag_act && !above && !ag_hnz;
                att    <= above;
                agc_bias <= above ? (63'sd1 <<< (8 + c_atts)) : (63'sd1 <<< (8 + c_decs));
                s[S_AGC] <= 1'b1;
            end
            // attack and decay move the gain by a fraction of (target - gain): the product (gain error
            // >> 8) x a is formed by the multiplier and shifted by 9 + s. The hang state keeps the
            // clamped gain; with the AGC off or in FM the manual gain is used.
            if (s[S_AGC]) begin
                // att and agc_bias were set in S_AGP3 (used only on the attack and decay paths)
                if (p_att || p_dec) begin
                    s[S_W1] <= 1'b1;
                end else begin
                    s[S_GAIN] <= 1'b1;
                end
                if (p_att)
                    w_hang <= c_hang;
                else if (p_hang)
                    w_hang <= hang_m1;
                g_new <= p_hang ? wg_clamped : c_gman;   // the attack and decay paths load it in S_AGC2_E
            end
            if (s[S_AGC2]) begin
                agc_sum <= mul_p + agc_bias;
                agc_sh  <= att ? c_atts : c_decs;
                s[S_AGC2_BH] <= 1'b1;
            end
            // agc_sum >>> (9 + agc_sh) over two clocks, by 9 + 4 x agc_sh[3:2] in S_AGC2_BH and
            // by agc_sh[1:0] here (in one clock it would be too slow)
            if (s[S_AGC2_BH]) begin
                stp_h <= agc_sum >>> (9 + {agc_sh[3:2], 2'b00});
                s[S_AGC2_B] <= 1'b1;
            end
            if (s[S_AGC2_B]) begin : agc2b
                reg signed [62:0] stp;
                stp = stp_h >>> agc_sh[1:0];
                stp35 <= stp[34:0];
                s[S_AGC2_C] <= 1'b1;
            end
            if (s[S_AGC2_C]) begin
                ng_r <= w_g + stp35;
                s[S_AGC2_D] <= 1'b1;
            end
            if (s[S_AGC2_D]) begin
                ng_over  <= ng_r > c_gmax;
                ng_under <= ng_r < c_gmin;
                s[S_AGC2_E] <= 1'b1;
            end
            if (s[S_AGC2_E]) begin
                g_new <= ng_over ? c_gmax : ng_under ? c_gmin : ng_r[33:0];
                s[S_GAIN] <= 1'b1;
            end
            // ------------------------------------------------------------ gain
            // The gain g_new (S.24 octaves) is split: the top part ga (S.10) gives the integer shift of
            // the output and the 10 bits below the integer part address the 2^x table, which
            // gives the multiplier for the fraction. The result is shifted by (ga >> 10) - 16.
            if (s[S_GAIN]) begin
                ga <= g_new >>> 14;
                exp_addr <= g_new[23:14];
                s[S_GAIN1] <= 1'b1;
            end
            if (s[S_GAIN1]) begin : gain1             // table read; the gain's shift from ga
                reg signed [9:0] tt;
                tt = (ga >>> 10) - 10'sd16;
                if (tt > 10'sd24) tt = 10'sd24;
                if (tt < -10'sd48) tt = -10'sd48;
                tt_r <= tt;
                s[S_GAIN2] <= 1'b1;
            end
            if (s[S_GAIN2]) begin : gain2             // a * m; the gain's shift split up
                reg [5:0] n;
                n = (tt_r >= 0) ? tt_r[5:0] : -tt_r;
                g_left   <= tt_r >= 0;
                g_bias   <= (tt_r >= 0) ? 71'sd0 : (71'sd1 <<< (-tt_r - 1));
                g_coarse <= n[5:3];
                g_fine   <= n[2:0];
                s[S_W1] <= 1'b1;
            end
            // apply_gain(p, ga) = sat24(round(p * 2^tt)): S_GAIN3 the rounding bias, S_GAIN3_B the
            // shift by a multiple of 8, S_GAIN3_C the rest of the shift, S_GAIN3_D saturation
            if (s[S_GAIN3]) begin
                gw1 <= $signed({{8{mul_p[62]}}, mul_p}) + g_bias;
                s[S_GAIN3_B] <= 1'b1;
            end
            if (s[S_GAIN3_B]) begin
                if (g_left)
                    gw2 <= gw1 <<< {g_coarse, 3'd0};
                else
                    gw2 <= gw1 >>> {g_coarse, 3'd0};
                s[S_GAIN3_C] <= 1'b1;
            end
            if (s[S_GAIN3_C]) begin                   // the rest of the shift: 4 x g_fine[2], then g_fine[1:0]
                if (g_left)
                    gw3 <= gw2 <<< {g_fine[2], 2'b00};
                else
                    gw3 <= gw2 >>> {g_fine[2], 2'b00};
                s[S_GAIN3_C2] <= 1'b1;
            end
            if (s[S_GAIN3_C2]) begin
                if (g_left)
                    gw4 <= gw3 <<< g_fine[1:0];
                else
                    gw4 <= gw3 >>> g_fine[1:0];
                s[S_GAIN3_S] <= 1'b1;
            end
            if (s[S_GAIN3_S]) begin                   // sat24's compares
                gs_hi <= gw4 > 71'sd8388607;
                gs_lo <= gw4 < -71'sd8388608;
                gs_v  <= gw4[23:0];
                s[S_GAIN3_D] <= 1'b1;
            end
            if (s[S_GAIN3_D]) begin : gain3d
                reg signed [23:0] gsat;
                gsat = gs_hi ? 24'sd8388607 : gs_lo ? -24'sd8388608 : gs_v;
                if (!mac_q) begin
                    ga_i <= gsat;
                    if (mo_iq) begin
                        mac_q <= 1'b1;         // second pass: Q
                        s[S_W1] <= 1'b1;
                    end else begin
                        ga_q <= 24'sd0;
                        s_gain[rx] <= ga;
                        s[S_HB] <= 1'b1;
                    end
                end else begin
                    ga_q <= gsat;
                    mac_q <= 1'b0;
                    s_gain[rx] <= ga;
                    s[S_HB] <= 1'b1;
                end
            end
            // ------------------------------------------------------------ squelch, HB5
            // The squelch zeroes the audio when it is closed. With out24 the sample goes out as it is;
            // otherwise it is written into the HB5 delay line, and on every second sample (the
            // phase bit w_phs) the 33 non-zero taps of the half-band are run through the multiplier.
            if (s[S_HB]) begin : hb5
                reg signed [23:0] oi, oq;
                oi = (c_sq && !w_sqo) ? 24'sd0 : ga_i;
                oq = (c_sq && !w_sqo) ? 24'sd0 : ga_q;
                if (c_out24) begin
                    vi <= oi;
                    vq <= oq;
                    s[S_OUT0] <= 1'b1;
                end else begin
                    hb_we    <= 1'b1;
                    hb_waddr <= {rx[RW-1:0], w_wp};
                    hb_wdata <= {oi, oq};
                    idx      <= w_wp;
                    w_wp     <= w_wp + 6'd1;
                    if (w_fill != 7'd64) w_fill <= w_fill + 7'd1;
                    w_phs    <= !w_phs;
                    if (!w_phs) begin
                        s[S_WB] <= 1'b1;            // first of a pair
                    end else begin
                        t <= 7'd0;
                        ta <= BK_HB4_START;
                        mac_q <= 1'b0;
                        acc_clr <= 1'b1;
                        mac_mode <= 1'b1;
                        s[S_MAC] <= 1'b1;
                    end
                end
            end
            if (s[S_MAC]) begin
                iss0_v   <= 1'b1;
                iss0_w   <= tap_w;
                iss0_q   <= mac_q;
                if (t == BK_HB4_COUNT - 1) begin
                    drain <= 4'd7;
                    s[S_MWAIT] <= 1'b1;
                end
                t <= t + 7'd1;
                ta <= ta + 7'd1;
            end
            if (s[S_MWAIT]) begin
                if (drain == 4'd0)
                    s[S_MEND0] <= 1'b1;
                drain <= drain - 4'd1;
            end
            if (s[S_MEND0]) begin
                mend_r <= (acc + 52'sd16777216) >>> 25;
                s[S_MEND] <= 1'b1;
            end
            if (s[S_MEND]) begin : mend
                reg signed [23:0] y;
                y = (mend_r > 52'sd8388607) ? 24'sd8388607 : (mend_r < -52'sd8388608) ? -24'sd8388608 : mend_r[23:0];
                if (!mac_q) begin
                    vi <= y;
                    if (mo_iq) begin
                        mac_q <= 1'b1;
                        t <= 7'd0;
                        ta <= BK_HB4_START;
                        acc_clr <= 1'b1;
                        s[S_MAC] <= 1'b1;
                    end else begin
                        vq <= 24'sd0;
                        mac_mode <= 1'b0;
                        s[S_OUT0] <= 1'b1;
                    end
                end else begin
                    vq <= y;
                    mac_q <= 1'b0;
                    mac_mode <= 1'b0;
                    s[S_OUT0] <= 1'b1;
                end
            end
            // ------------------------------------------------------------ output, write back
            if (s[S_OUT0]) begin
                or_i <= ($signed({vi[23], vi}) + 25'sd128) >>> 8;
                or_q <= ($signed({vq[23], vq}) + 25'sd128) >>> 8;
                s[S_OUT] <= 1'b1;
            end
            if (s[S_OUT]) begin
                out_valid <= 1'b1;
                out_rx    <= rx;
                out_s0    <= sat16(or_i);
                out_s1    <= mo_iq ? sat16(or_q) : 16'd0;
                s[S_WB] <= 1'b1;
            end
            if (s[S_WB]) begin
                r_sm[rx]   <= w_sm;
                r_sqo[rx]  <= w_sqo;
                r_dc[rx]   <= w_dc;
                r_th[rx]   <= w_th;
                r_fr[rx]   <= w_fr;
                r_ph[rx]   <= w_ph;
                r_de[rx]   <= w_de;
                r_g[rx]    <= g_new;
                r_hang[rx] <= w_hang;
                r_wp[rx]   <= w_wp;
                r_fill[rx] <= w_fill;
                r_phs[rx]  <= w_phs;
                s[S_IDLE] <= 1'b1;
            end
            // the states that wait: stay until their condition (the if-blocks above only name
            // the next state)
            if (s[S_IDLE] && !(!in0_pop && !in1_pop && (!in0_empty || !in1_empty))) s[S_IDLE] <= 1'b1;
            if (s[S_VEC] && !c_done) s[S_VEC] <= 1'b1;
            if (s[S_ROT] && !c_done) s[S_ROT] <= 1'b1;
            if (s[S_MAC] && t != BK_HB4_COUNT - 1) s[S_MAC] <= 1'b1;
            if (s[S_MWAIT] && drain != 4'd0) s[S_MWAIT] <= 1'b1;
            // A multiply is issued by one of seven states (each also goes to S_W1): the
            // operand select (msel_n, one-hot MS_*) and the state S_W5 returns to (retq, one-hot
            // S_MAG, S_SM2, S_FM2, S_ROT2, S_AGC2, S_GAIN3), written here as one AND-OR of the
            // issuing conditions rather than in each state's block.
            begin : issue
                reg i_vec, i_sm, i_fm, i_rot, i_agc, i_ga, i_gb;
                i_vec = s[S_VEC] && c_done;
                i_sm  = s[S_SM_C];
                i_fm  = s[S_FM1] && !c_dez;
                i_rot = s[S_ROT] && c_done;
                i_agc = s[S_AGC] && (p_att || p_dec);
                i_ga  = s[S_GAIN2];
                i_gb  = s[S_GAIN3_D] && !mac_q && mo_iq;
                if (i_vec || i_sm || i_fm || i_rot || i_agc || i_ga || i_gb) begin
                    retq   <= {i_ga || i_gb, i_agc, i_rot, i_fm, i_sm, i_vec};
                    msel_n <= {i_gb, i_ga, i_agc && !p_att, i_agc && p_att, i_fm, i_sm, i_vec || i_rot};
                end
            end
        end
    end
endmodule
