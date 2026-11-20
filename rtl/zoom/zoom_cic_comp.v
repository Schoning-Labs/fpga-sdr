// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// zoom_cic_comp: the last stage of the zoom DDC (docs/F3_ZOOM.md section 4). A CIC filter has a passband that
// is not flat but droops towards the edges, and the displayed 80 percent of the zoom spectrum would show
// that as a tilt. This 15-tap FIR, with no decimation, is the inverse of that droop, so the displayed
// part is flat within 0.01 dB. The droop depends on how much the CIC decimates, so there are eleven
// coefficient sets, one per span (rtl/zoom/zoom_cic_comp_coeffs.hex, span 0 first; spans 7 to 10 are the
// narrow spans, where the droop is that of rtl/zoom/zoom_cic_narrow.v). It works on I and Q with one
// multiplier per channel. The terms are explained in docs/learn/GLOSSARY.md.
//
// The output values are those of the parallel reference sim/zoom/ref/zoom_cic_comp_parallel_ref.v (word
// for word in sim/zoom/zoom_rb1_compare_sim.v). The filter does one tap per clock, one short step per
// clock:
//   clock 0  tap counter gp0, job pointer jp0
//   clock 1  read address and coefficient address (set base + tap), registered
//   clock 2  delay line read (LUT RAM), coefficient ROM read
//   clock 3  one more register (as zoom_fir_half.v, so both have the same clock table)
//   clock 4  operands of the multiply-accumulate
//   clock 5-7  rx_mac (rtl/rx/fir_decim.v), starting from the rounding constant at a job's first tap
//   clock 8  the output is a bit slice of the block's result
// A job takes 15 clocks. Its input, zoom_fir_half.v's output, comes at most every 32 clocks, so this
// filter never queues more than one sample and its delay line is DEPTH = 32 samples of LUT RAM.
// REQUIRES in_strobe pulses at least 16 clocks apart.
//
// Output k is the filter over the inputs before input k (one sample of delay) and the first output after
// power-up is 0. The coefficient set follows span_shift at once; the DDC is held in reset while the span
// changes. Coefficients are Q16 (COEFF_WIDTH - 2 fraction bits, so a gain a little above 1 at the edge
// of the band fits); the output is the sum shifted down by that, rounded half up.

module zoom_cic_comp #(
    parameter TAPS         = 15,
    parameter IN_WIDTH     = 16,   // up to 27
    parameter COEFF_WIDTH  = 18,   // up to 18
    parameter OUT_WIDTH    = 16,
    parameter N_SPANS      = 11,   // number of coefficient sets
    parameter COEFF_FILE   = "rtl/zoom/zoom_cic_comp_coeffs.hex",
    parameter DEPTH        = 32    // delay line length in samples (a power of two)
)(
    input                         clock,
    input                         rst,
    input      [3:0]              span_shift, // 0..N_SPANS-1: selects the coefficient set
    input                         in_strobe,  // one-clock pulse per input sample (at least 16 clocks apart)
    input      signed [IN_WIDTH-1:0] in_i,    // input I
    input      signed [IN_WIDTH-1:0] in_q,    // input Q
    output reg                    out_strobe, // one-clock pulse per output sample
    output reg signed [OUT_WIDTH-1:0] out_i,  // output I
    output reg signed [OUT_WIDTH-1:0] out_q   // output Q
) /* synthesis syn_maxfan = 10000 syn_srlstyle = "registers" */;

localparam integer SHIFT = COEFF_WIDTH - 2;            // coefficients are Q(COEFF_WIDTH-2)
localparam integer AW    = $clog2(DEPTH);
localparam integer GPW   = $clog2(TAPS);
localparam integer CAW   = $clog2(N_SPANS * TAPS);
localparam [47:0]  ROUND = 48'd1 << (SHIFT - 1);

reg signed [COEFF_WIDTH-1:0] coeff [0:(N_SPANS*TAPS)-1] /* synthesis syn_romstyle = "distributed_rom" */;
initial $readmemh(COEFF_FILE, coeff);

// the first coefficient of the set for this span, registered from span_shift
reg [CAW-1:0] span_base = {CAW{1'b0}};                 // span_shift * TAPS
always @(posedge clock)
    case (span_shift)
        4'd0:    span_base <= 0 * TAPS;
        4'd1:    span_base <= 1 * TAPS;
        4'd2:    span_base <= 2 * TAPS;
        4'd3:    span_base <= 3 * TAPS;
        4'd4:    span_base <= 4 * TAPS;
        4'd5:    span_base <= 5 * TAPS;
        4'd6:    span_base <= 6 * TAPS;
        4'd7:    span_base <= 7 * TAPS;
        4'd8:    span_base <= 8 * TAPS;
        4'd9:    span_base <= 9 * TAPS;
        default: span_base <= 10 * TAPS;
    endcase

// delay line, I and Q in one word
reg [2*IN_WIDTH-1:0] dly [0:DEPTH-1] /* synthesis syn_ramstyle = "distributed_ram" */;
integer init_k;
initial for (init_k = 0; init_k < DEPTH; init_k = init_k + 1) dly[init_k] = {2*IN_WIDTH{1'b0}};

reg [AW-1:0] wr_ptr = {AW{1'b0}};                      // next write index
reg [AW-1:0] wr_seen1 = {AW{1'b0}}, wr_seen2 = {AW{1'b0}};   // the same, 1 and 2 clocks later
reg [AW-1:0] np = {AW{1'b0}};                          // job pointer of the next job: samples np-1 .. np-TAPS

always @(posedge clock)
    if (in_strobe & ~rst) dly[wr_ptr] <= {in_i, in_q};

// ---------------------------------------------------------------------------------- clock 0: issue
reg            v0 = 1'b0;
reg [GPW-1:0]  gp0 = {GPW{1'b0}};
reg [AW-1:0]   jp0 = {AW{1'b0}};
wire           last0 = (gp0 == TAPS - 1);
wire           start = (wr_seen2 != np) & (~v0 | last0);

always @(posedge clock) begin
    if (rst) begin
        wr_ptr   <= {AW{1'b0}};
        wr_seen1 <= {AW{1'b0}};
        wr_seen2 <= {AW{1'b0}};
        np       <= {AW{1'b0}};
        v0       <= 1'b0;
        gp0      <= {GPW{1'b0}};
    end else begin
        if (in_strobe) wr_ptr <= wr_ptr + 1'b1;
        wr_seen1 <= wr_ptr;
        wr_seen2 <= wr_seen1;
        if (start) begin
            v0  <= 1'b1;
            gp0 <= {GPW{1'b0}};
            jp0 <= np;
            np  <= np + 1'b1;
        end else if (v0 && !last0) begin
            gp0 <= gp0 + 1'b1;
        end else begin
            v0 <= 1'b0;
        end
    end
end

// ---------------------------------------------------------------------------------- clocks 1 to 4
reg [AW-1:0]  ra = {AW{1'b0}};
reg [CAW-1:0] ca1 = {CAW{1'b0}};
reg           v1 = 1'b0, f1 = 1'b0, l1 = 1'b0;
reg [2*IN_WIDTH-1:0] m2 = {2*IN_WIDTH{1'b0}};
reg signed [COEFF_WIDTH-1:0] c2 = {COEFF_WIDTH{1'b0}};
reg           v2 = 1'b0, f2 = 1'b0, l2 = 1'b0;
reg [2*IN_WIDTH-1:0] o3 = {2*IN_WIDTH{1'b0}};
reg signed [COEFF_WIDTH-1:0] c3 = {COEFF_WIDTH{1'b0}};
reg           v3 = 1'b0, f3 = 1'b0, l3 = 1'b0;
reg signed [IN_WIDTH-1:0]    xi4 = {IN_WIDTH{1'b0}}, xq4 = {IN_WIDTH{1'b0}};
reg signed [COEFF_WIDTH-1:0] c4 = {COEFF_WIDTH{1'b0}};
reg           acc4 = 1'b1;
reg [3:0]     ld = 4'd0;                               // last tap, clocks 4 to 7

always @(posedge clock) begin
    // clock 1
    ra   <= jp0 - {{(AW-GPW){1'b0}}, gp0} - 1'b1;
    ca1  <= span_base + {{(CAW-GPW){1'b0}}, gp0};
    v1   <= v0 & ~rst;
    f1   <= (gp0 == {GPW{1'b0}});
    l1   <= last0;
    // clock 2
    m2   <= dly[ra];
    c2   <= coeff[ca1];
    v2   <= v1 & ~rst;  f2 <= f1;  l2 <= l1;
    // clock 3
    o3   <= m2;
    c3   <= c2;
    v3   <= v2 & ~rst;  f3 <= f2;  l3 <= l2;
    // clock 4: operands of the multiply-accumulate; a clock without a tap adds 0
    if (v3) begin
        xi4 <= o3[2*IN_WIDTH-1:IN_WIDTH];
        xq4 <= o3[IN_WIDTH-1:0];
        c4  <= c3;
    end else begin
        xi4 <= {IN_WIDTH{1'b0}};
        xq4 <= {IN_WIDTH{1'b0}};
        c4  <= {COEFF_WIDTH{1'b0}};
    end
    acc4 <= ~(v3 & f3);
    ld   <= {ld[2:0], v3 & l3 & ~rst};
end

// ---------------------------------------------------------------------------------- clocks 5 to 8
wire signed [47:0] p_i, p_q;
wire signed [17:0] mc  = c4;                           // sign-extended to the block's ports
wire signed [26:0] mxi = xi4, mxq = xq4;
rx_mac #(.PRELOAD(ROUND)) u_mac_i (.clock(clock), .a(mxi), .b(mc), .acc(acc4), .p(p_i));
rx_mac #(.PRELOAD(ROUND)) u_mac_q (.clock(clock), .a(mxq), .b(mc), .acc(acc4), .p(p_q));

always @(posedge clock) begin
    if (rst) begin
        out_strobe <= 1'b0;
        out_i      <= {OUT_WIDTH{1'b0}};
        out_q      <= {OUT_WIDTH{1'b0}};
    end else begin
        out_strobe <= ld[3];
        if (ld[3]) begin
            out_i <= p_i[SHIFT +: OUT_WIDTH];
            out_q <= p_q[SHIFT +: OUT_WIDTH];
        end
    end
end

endmodule
