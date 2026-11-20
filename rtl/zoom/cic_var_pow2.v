// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// cic_var_pow2: a variable-decimation CIC (Hogenauer) filter whose decimation is a power of two (1, 2,
// 4, ..., 2^MAX_SHIFT), selected by `shift`. The DC gain is the same at every setting: the output is
// the slice of the accumulator above STAGES x shift bits of growth, rounded. It is the zoom DDC's
// second stage (docs/F3_ZOOM.md section 2): the fixed CIC in front of it gives 7.68 Msps and this one
// gives 7.68 Msps / 2^span_shift. The terms (CIC, integrator, comb, bit growth) are explained in
// docs/learn/GLOSSARY.md, and rtl/rx/cic_var_shared.v describes the basic CIC filter.
//
// The output words and the out_strobe timing are those of the plain textbook form, kept as
// sim/zoom/ref/cic_var_pow2_ref.v and compared word for word by sim/zoom/tb_cic_var_pow2.v. The way
// they are worked out here is different (docs/ZOOM_FIT.md section 3), because the textbook form
// with STAGES = 11 needs integrators and combs of ACC_WIDTH = 82 bits, which as flip-flops that all
// step at the input rate would be 4,100 registers and 3,000 adder cells per channel. In this form
// nothing wide runs at the input rate:
//
//   1. A CIC that decimates by R = 2^shift is a CIC that decimates by 2 followed by one that decimates by
//      R / 2: (1 - z^-R) / (1 - z^-1) = (1 + z^-1) * (1 - z^-R) / (1 - z^-2). And STAGES stages that
//      decimate by 2 are one filter with the STAGES + 1 binomial coefficients, (1 + z^-1)^STAGES. That
//      filter is worked out once for every second input sample: the last 16 samples in LUT RAM, one
//      multiplier, a sum of IN_WIDTH + STAGES bits (`fir`, 12 products in 12 clocks).
//   2. Its output words are 16 clocks apart or more. The remaining CIC (decimation R / 2) is serial:
//      one adder walks the STAGES integrators, one a clock, a second one the STAGES combs when an output
//      is due; the state is in LUT RAM (16 words x ACC_WIDTH each). Every add is done in two halves on two
//      clocks, the halves of consecutive stages overlapping, so a stage still takes one clock.
//   3. shift = 0 passes the samples on; shift = 1 takes the filter's output.
//   4. The result is cut and rounded as in the textbook form and waits in a 32-word LUT RAM: the integrators
//      and combs of the textbook form each delay by one sample, this form does not, so the output is read
//      dly_of(shift) output words late (and is zero until then, as there). The filter is worked out at
//      the samples, and the combs at the filter outputs, that make the phase the same.
//
// Every sum is exact (ACC_WIDTH bits, wrapping), the one rounding is the last, so the words are the same.
//
// REQUIRES in_strobe pulses at least 8 clocks apart (the fixed CIC in front decimates by 10), a consumer
// that samples out_data at out_strobe only, `shift` changed only while rst_all is high (held 4 clocks or
// more), MAX_SHIFT <= 6 (larger `shift` values select the MAX_SHIFT slice) and STAGES <= 13.
//
// Clocks, F0 = the edge that sees in_strobe: out_strobe is high in the third clock after it. The filter
// is done 15 clocks after its sample, the integrators 15 clocks after that, the combs 15 more.

module cic_var_pow2 #(
    parameter STAGES    = 5,     // integrator and comb stages
    parameter IN_WIDTH   = 16,   // bits of one input sample
    parameter MAX_SHIFT  = 6,    // decimation up to 2^MAX_SHIFT
    parameter OUT_WIDTH  = 16,   // bits of one output sample
    parameter PARTS      = 4     // not used
)(
    input                          rst_all,   // synchronous reset, held while the zoom is disabled
    input      [2:0]               shift,     // decimation = 1 << shift, 0..MAX_SHIFT
    input                          clock,
    input                          in_strobe, // one-clock pulse per input sample (at least 8 clocks apart)
    output                         out_strobe,// one-clock pulse per output sample
    input      signed [IN_WIDTH-1:0] in_data, // input sample, held around in_strobe
    output     signed [OUT_WIDTH-1:0] out_data// rounded output, valid at out_strobe
) /* synthesis syn_maxfan = 10000 syn_srlstyle = "registers" */;

localparam integer ACC_WIDTH = IN_WIDTH + STAGES * MAX_SHIFT;
localparam integer LW  = ACC_WIDTH / 2;
localparam integer HW  = ACC_WIDTH - LW;
localparam integer FW  = IN_WIDTH + STAGES;                 // the filter's sum
localparam integer KW  = STAGES;                            // a binomial coefficient (below 2^STAGES)
localparam integer NT  = STAGES + 1;                        // filter taps
localparam integer CW  = OUT_WIDTH + 1;                     // {slice, rounding bit}
localparam integer PH  = STAGES % 2;                        // the filter is worked out at samples of this parity
localparam integer HQ  = (STAGES + PH) / 2;                 // the combs at filter outputs -HQ (mod R / 2)

function integer binom(input integer n, input integer k);
    integer i, r;
    begin
        r = 1;
        for (i = 1; i <= k; i = i + 1) r = (r * (n - k + i)) / i;
        binom = r;
    end
endfunction
// output words of delay at shift s: the textbook form's STAGES - 1 input and STAGES output samples
function integer dly_of(input integer s);
    integer r, q;
    begin
        r = 1 << s;
        q = (s >= 2) ? ((r / 2) - (HQ % (r / 2))) % (r / 2) : 0;
        dly_of = (s == 0) ? (2 * STAGES - 1) : (STAGES - 1) + (STAGES + 2 * q + PH) / r;
    end
endfunction

// ---------------------------------------------------------------------------------------- settings
// The registered settings that follow from `shift`: the decimation mask, the comb phase and the number
// of output words to skip at the start.
reg [2:0] sh_q  = 3'd0;                                // shift, limited to MAX_SHIFT
reg [5:0] mask  = 6'd0;                                // decimation - 1
reg [4:0] bmask = 5'd0;                                // R / 2 - 1
reg [4:0] bq    = 5'd0;                                // -HQ mod R / 2
reg       s_is0 = 1'b1, s_is1 = 1'b0;
wire [4:0] dly_w [0:7];
genvar gd;
generate
    for (gd = 0; gd < 8; gd = gd + 1) begin : g_dly
        localparam integer DS = dly_of((gd > MAX_SHIFT) ? MAX_SHIFT : gd);
        assign dly_w[gd] = DS[4:0];
    end
endgenerate
wire [4:0] nhq = 5'd0 - HQ[4:0];
always @(posedge clock) begin
    sh_q  <= (shift > MAX_SHIFT) ? MAX_SHIFT[2:0] : shift;
    s_is0 <= (sh_q == 3'd0);
    s_is1 <= (sh_q == 3'd1);
    case (sh_q)
        3'd0:    begin mask <= 6'b000000; bmask <= 5'b00000; end
        3'd1:    begin mask <= 6'b000001; bmask <= 5'b00000; end
        3'd2:    begin mask <= 6'b000011; bmask <= 5'b00001; end
        3'd3:    begin mask <= 6'b000111; bmask <= 5'b00011; end
        3'd4:    begin mask <= 6'b001111; bmask <= 5'b00111; end
        3'd5:    begin mask <= 6'b011111; bmask <= 5'b01111; end
        default: begin mask <= 6'b111111; bmask <= 5'b11111; end
    endcase
    bq <= nhq & bmask;
end

// ---------------------------------------------------------------------------------------- strobes
// The decimation counter counts the input strobes and raises ob on every (decimation)-th one;
// out_strobe is ob two clocks later.
reg [5:0] sample_no = 6'd0;
reg       ob = 1'b0;
reg [1:0] ob_dly = 2'b00;
always @(posedge clock) begin
    if (rst_all) begin
        sample_no <= 6'd0;
        ob        <= 1'b0;
    end else if (in_strobe) begin
        if ((sample_no & mask) == mask) begin
            sample_no <= 6'd0;
            ob        <= 1'b1;
        end else begin
            sample_no <= sample_no + 6'd1;
            ob        <= 1'b0;
        end
    end else
        ob <= 1'b0;
    ob_dly <= {ob_dly[0], ob};
end
assign out_strobe = ob_dly[1];

// ---------------------------------------------------------------------------------------- 1. the filter
reg  [IN_WIDTH-1:0] xr [0:15] /* synthesis syn_ramstyle = "distributed_ram" */;
integer ix;
initial for (ix = 0; ix < 16; ix = ix + 1) xr[ix] = {IN_WIDTH{1'b0}};
reg  [3:0] xwp  = 4'd0;                                // where the next sample goes
reg  [3:0] xcnt = 4'd0;                                // samples since reset, stops at 15
reg        xpar = 1'b0;                                // parity of the next sample's number
always @(posedge clock) begin
    if (in_strobe && !rst_all) xr[xwp] <= in_data;
    if (rst_all) begin
        xwp <= 4'd0; xcnt <= 4'd0; xpar <= 1'b0;
    end else if (in_strobe) begin
        xwp  <= xwp + 4'd1;
        xpar <= ~xpar;
        if (xcnt != 4'd15) xcnt <= xcnt + 4'd1;
    end
end

wire [KW-1:0] coef_w [0:15];
genvar gc;
generate
    for (gc = 0; gc < 16; gc = gc + 1) begin : g_coef
        localparam integer CB = (gc <= STAGES) ? binom(STAGES, gc) : 0;
        assign coef_w[gc] = CB[KW-1:0];
    end
endgenerate

reg        f_run = 1'b0;
reg  [3:0] f_k = 4'd0, f_base = 4'd0, f_cnt = 4'd0;
reg  [2:0] f_v = 3'd0, f_first = 3'd0, f_last = 3'd0;  // a tap on its way: read, product, sum
reg  signed [IN_WIDTH-1:0] f_x = {IN_WIDTH{1'b0}};
reg  signed [KW:0]         f_c = {(KW+1){1'b0}};
reg  signed [IN_WIDTH+KW:0] f_p = {(IN_WIDTH+KW+1){1'b0}};
reg  signed [FW-1:0]       fir = {FW{1'b0}};
reg        fir_v = 1'b0;                               // fir is a new word (one clock)
wire [3:0] f_a = f_base - f_k;
wire       f_start = in_strobe && !rst_all && (xpar == PH[0]);
always @(posedge clock) begin
    f_x <= (f_k < f_cnt) ? xr[f_a] : {IN_WIDTH{1'b0}};     // samples from before the reset count as zero
    f_c <= {1'b0, coef_w[f_k]};
    f_p <= f_x * f_c;
    if (f_v[1]) fir <= f_first[1] ? f_p[FW-1:0] : fir + f_p[FW-1:0];
    if (rst_all) begin
        f_run <= 1'b0; f_v <= 3'd0; fir_v <= 1'b0;
    end else begin
        if (f_start) begin
            f_run  <= 1'b1;
            f_k    <= 4'd0;
            f_base <= xwp;                                 // the place of this sample
            f_cnt  <= (xcnt == 4'd15) ? 4'd15 : xcnt + 4'd1;
        end else if (f_run) begin
            f_k <= f_k + 4'd1;
            if (f_k == NT - 1) f_run <= 1'b0;
        end
        f_v     <= {f_v[1:0], f_run};
        f_first <= {f_first[1:0], f_run && (f_k == 4'd0)};
        f_last  <= {f_last[1:0], f_run && (f_k == NT - 1)};
        fir_v   <= f_v[1] && f_last[1];
    end
end

// ---------------------------------------------------------------------------------------- 2. the serial CIC
// One pass of an engine, clocks 0 to 14 (clock 0 = the clock its start strobe is high):
//   edge 0       the word to add is the input of the pass; the sum is cleared
//   edge c       c = 1 .. 11: the word to add is the state word of stage c - 1 (read from LUT RAM)
//   edge c       c = 1 .. 12: low half of the sum (stage c - 2; c = 1: the input)
//   edge c       c = 2 .. 13: high half of the sum (stage c - 3), with the carry of the low half
//   integrators  the sum is written back: low half at edge c = 3 .. 13 (stage c - 3), high at c = 4 .. 14
//   combs        the word before the subtraction is written: low half at the edge of the low subtraction,
//                high half at the edge of the high one
// So stage s is read at edge s + 1 and written at edges s + 2 to s + 4, and the next pass is 16 clocks
// later at the earliest.
reg  [4:0] wcnt = 5'd0;                                // filter outputs since reset
wire       i_start = fir_v && !s_is0 && !s_is1;
wire       i_dec   = ((wcnt & bmask) == bq);           // this filter output is one the combs work on

reg  [LW-1:0] mi_l [0:15] /* synthesis syn_ramstyle = "distributed_ram" */;
reg  [HW-1:0] mi_h [0:15] /* synthesis syn_ramstyle = "distributed_ram" */;
reg  [LW-1:0] mc_l [0:15] /* synthesis syn_ramstyle = "distributed_ram" */;
reg  [HW-1:0] mc_h [0:15] /* synthesis syn_ramstyle = "distributed_ram" */;
integer im;
initial for (im = 0; im < 16; im = im + 1) begin
    mi_l[im] = {LW{1'b0}}; mi_h[im] = {HW{1'b0}}; mc_l[im] = {LW{1'b0}}; mc_h[im] = {HW{1'b0}};
end

wire [ACC_WIDTH-1:0] fir_x = {{(ACC_WIDTH-FW){fir[FW-1]}}, fir};

// ---- integrators
reg        i_run = 1'b0, i_fresh = 1'b1, i_dec_q = 1'b0;
reg  [3:0] i_c = 4'd0;                                 // the clock of the pass, 1 .. 14 while i_run
reg  [LW-1:0] i_ml = {LW{1'b0}};
reg  [HW-1:0] i_mh0 = {HW{1'b0}}, i_mh = {HW{1'b0}};
reg  [LW-1:0] i_sl = {LW{1'b0}};
reg  [HW-1:0] i_sh = {HW{1'b0}};
reg           i_cy = 1'b0;
wire [3:0]    i_ra = i_c - 4'd1;                       // the stage read at the edge of this clock
wire [3:0]    i_wl = i_c - 4'd3;
wire [3:0]    i_wh = i_c - 4'd4;
wire [LW:0]   i_lw = {1'b0, i_sl} + {1'b0, i_ml};
wire [HW+1:0] i_hw = {1'b0, i_sh, 1'b1} + {1'b0, i_mh, i_cy};
wire          i_end = i_run && (i_c == 4'd14);
always @(posedge clock) begin
    // the word to add
    if (i_start) begin
        i_ml  <= fir_x[LW-1:0];
        i_mh0 <= fir_x[ACC_WIDTH-1:LW];
    end else begin
        i_ml  <= i_fresh ? {LW{1'b0}} : mi_l[i_ra];
        i_mh0 <= i_fresh ? {HW{1'b0}} : mi_h[i_ra];
    end
    i_mh <= i_mh0;
    // the sum
    if (i_start)                                      begin i_sl <= {LW{1'b0}}; i_cy <= 1'b0; end
    else if (i_run && i_c >= 4'd1 && i_c <= 4'd12)    {i_cy, i_sl} <= i_lw;
    if (i_run && i_c == 4'd1)                         i_sh <= {HW{1'b0}};
    else if (i_run && i_c >= 4'd2 && i_c <= 4'd13)    i_sh <= i_hw[HW:1];
    // back into the memory
    if (i_run && i_c >= 4'd3 && i_c <= 4'd13) mi_l[i_wl] <= i_sl;
    if (i_run && i_c >= 4'd4 && i_c <= 4'd14) mi_h[i_wh] <= i_sh;
    if (rst_all) begin
        i_run <= 1'b0; i_fresh <= 1'b1; i_c <= 4'd0; wcnt <= 5'd0;
    end else begin
        if (i_start) begin
            i_run   <= 1'b1;
            i_c     <= 4'd1;
            i_dec_q <= i_dec;
            wcnt    <= wcnt + 5'd1;
        end else if (i_run) begin
            i_c <= i_c + 4'd1;
            if (i_c == 4'd14) begin
                i_run   <= 1'b0;
                i_fresh <= 1'b0;                       // every stage has been written once
            end
        end
    end
end

// ---- combs
wire       c_start = i_end && i_dec_q;                 // i_sl and i_sh are the new word of the last integrator
reg        c_run = 1'b0, c_fresh = 1'b1;
reg  [3:0] c_c = 4'd0;
reg  [LW-1:0] c_ml = {LW{1'b0}};
reg  [HW-1:0] c_mh0 = {HW{1'b0}}, c_mh = {HW{1'b0}};
reg  [LW-1:0] c_sl = {LW{1'b0}};
reg  [HW-1:0] c_sh = {HW{1'b0}};
reg           c_cy = 1'b0, c_ci = 1'b0;                // carry into the high half; into the low half (1: subtract)
wire [3:0]    c_ra = c_c - 4'd1;
wire [3:0]    c_wl = c_c - 4'd2;
wire [3:0]    c_wh = c_c - 4'd3;
wire [LW+1:0] c_lw = {1'b0, c_sl, 1'b1} + {1'b0, c_ml, c_ci};
wire [HW+1:0] c_hw = {1'b0, c_sh, 1'b1} + {1'b0, c_mh, c_cy};
wire          c_end = c_run && (c_c == 4'd14);
always @(posedge clock) begin
    // the word to add: the input, then minus the state words (inverted, carry 1)
    if (c_start) begin
        c_ml  <= i_sl;
        c_mh0 <= i_sh;
    end else begin
        c_ml  <= c_fresh ? {LW{1'b1}} : ~mc_l[c_ra];
        c_mh0 <= c_fresh ? {HW{1'b1}} : ~mc_h[c_ra];
    end
    c_mh <= c_mh0;
    c_ci <= c_run && (c_c >= 4'd1);                    // clocks 2 .. 12: a subtraction
    if (c_start)                                      begin c_sl <= {LW{1'b0}}; c_cy <= 1'b0; end
    else if (c_run && c_c >= 4'd1 && c_c <= 4'd12)    {c_cy, c_sl} <= c_lw[LW+1:1];
    if (c_run && c_c == 4'd1)                         c_sh <= {HW{1'b0}};
    else if (c_run && c_c >= 4'd2 && c_c <= 4'd13)    c_sh <= c_hw[HW:1];
    // the word before the subtraction is the new state of the stage
    if (c_run && c_c >= 4'd2 && c_c <= 4'd12) mc_l[c_wl] <= c_sl;
    if (c_run && c_c >= 4'd3 && c_c <= 4'd13) mc_h[c_wh] <= c_sh;
    if (rst_all) begin
        c_run <= 1'b0; c_fresh <= 1'b1; c_c <= 4'd0;
    end else begin
        if (c_start) begin
            c_run <= 1'b1;
            c_c   <= 4'd1;
        end else if (c_run) begin
            c_c <= c_c + 4'd1;
            if (c_c == 4'd14) begin
                c_run   <= 1'b0;
                c_fresh <= 1'b0;
            end
        end
    end
end
wire [ACC_WIDTH-1:0] ctop = {c_sh, c_sl};              // the output of the last comb, from clock 14 of the pass on

// ---------------------------------------------------------------------------------------- 3. cut and round
// growth(shift) = STAGES * shift: the slice is [IN_WIDTH + growth - 1 -: OUT_WIDTH], rounded by the bit
// below it (shift 0 with OUT_WIDTH = IN_WIDTH has no bit below: exact). cand[k] = {slice, rounding bit}.
wire [8*CW-1:0] cand;
genvar gk;
generate
    for (gk = 0; gk < 8; gk = gk + 1) begin : g_cand
        localparam integer KS  = (gk > MAX_SHIFT) ? MAX_SHIFT : gk;
        localparam integer TOP = IN_WIDTH + KS * STAGES;          // one above the top bit of the slice
        if (gk == 0) begin : g_0
            if (IN_WIDTH > OUT_WIDTH) begin : g_r
                assign cand[gk*CW +: CW] = in_data[IN_WIDTH-OUT_WIDTH-1 +: CW];
            end else begin : g_x
                assign cand[gk*CW +: CW] = {in_data[IN_WIDTH-OUT_WIDTH +: OUT_WIDTH], 1'b0};
            end
        end else if (gk == 1) begin : g_1
            assign cand[gk*CW +: CW] = fir[TOP-OUT_WIDTH-1 +: CW];
        end else begin : g_n
            assign cand[gk*CW +: CW] = ctop[TOP-OUT_WIDTH-1 +: CW];
        end
    end
endgenerate

reg  [CW-1:0]        sel = {CW{1'b0}};
reg                  sel_v = 1'b0, rnd_v = 1'b0;
reg  [OUT_WIDTH-1:0] rnd = {OUT_WIDTH{1'b0}};
wire take_v = s_is0 ? in_strobe : s_is1 ? fir_v : c_end;
always @(posedge clock) begin
    if (take_v) sel <= cand[sh_q*CW +: CW];
    sel_v <= take_v && !rst_all;
    rnd   <= sel[CW-1:1] + {{(OUT_WIDTH-1){1'b0}}, sel[0]};
    rnd_v <= sel_v && !rst_all;
end

// ---------------------------------------------------------------------------------------- 4. the output delay
reg  [OUT_WIDTH-1:0] ring [0:31] /* synthesis syn_ramstyle = "distributed_ram" */;
integer ir;
initial for (ir = 0; ir < 32; ir = ir + 1) ring[ir] = {OUT_WIDTH{1'b0}};
reg  [4:0] wp = 5'd0, rp = 5'd0, skip = 5'd0;
reg  [OUT_WIDTH-1:0] od = {OUT_WIDTH{1'b0}};
always @(posedge clock) begin
    if (rnd_v) ring[wp] <= rnd;
    if (rst_all) begin
        wp   <= 5'd0;
        rp   <= 5'd0;
        skip <= dly_w[sh_q];
        od   <= {OUT_WIDTH{1'b0}};
    end else begin
        if (rnd_v) wp <= wp + 5'd1;
        if (ob) begin
            if (skip != 5'd0) begin
                skip <= skip - 5'd1;
                od   <= {OUT_WIDTH{1'b0}};
            end else begin
                od <= ring[rp];
                rp <= rp + 5'd1;
            end
        end
    end
end
assign out_data = od;

endmodule
