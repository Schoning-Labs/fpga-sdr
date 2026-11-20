// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// zoom_fir_half: stage 4 of the zoom DDC (docs/F3_ZOOM.md sections 3 and 8.1), a 63-tap linear-phase
// low-pass filter that also decimates by 2, on I and Q. It is the real anti-alias filter of the zoom: it
// protects the central 80 percent of the final spectrum against signals from outside the view by at
// least 80 dB, which the CIC stages in front of it cannot do alone. The terms (FIR, tap, linear phase,
// decimation, folded taps) are explained in docs/learn/GLOSSARY.md.
//
// Linear phase means that the coefficients are symmetric, so the two samples that meet the same
// coefficient can be added before the multiply ("folding"): 63 taps need only 32 multiplies. This
// filter has TWO multipliers per channel (two folded taps per clock), because with one the 32 folded taps
// take 32 clocks per output, and at the widest span 3.84 million outputs per second would then need a
// clock of 123 MHz (docs/CLOCK_STUDY.md); the chip runs at 120 MHz. The tap delay line is a circular buffer
// of DEPTH samples that is also the queue for the HL2's sample bursts (a whole 5,968-sample frame arrives
// on consecutive clocks, then nothing for as long again; the fixed CIC in front makes that one input here
// every 10 clocks).
//
// The output values are those of the parallel reference sim/zoom/ref/zoom_fir_half_parallel_ref.v (word for
// word). Two folded taps per clock, lane 1 the folded taps 0 to 15 and lane 2 the folded taps 16 to 31
// (tap 31 is the middle tap, alone), one short step per clock:
//   clock 0  tap counter gp0 (0 to 15), job pointer jp0
//   clock 1  the four read addresses (two per lane), registered
//   clock 2  the addresses sorted into the two banks of the delay line, registered
//   clock 3  block RAM read (four reads per clock: see below), coefficient ROM read
//   clock 4  block RAM output register
//   clock 5  pair sums x[n-k] + x[n-(TAPS-1-k)] of both lanes (the middle tap alone), registered
//   clock 6-8  two rx_mac per channel (rtl/rx/fir_decim.v: the instantiated MULTALU27X18 with input, product
//            and output register and the sum inside the block). Lane 1 starts from the rounding constant
//            at a job's first tap, lane 2 from 0
//   clock 9  the two results added (the sum of the lanes is the sum of the one-multiplier form: the same
//            integers, the order of the additions does not matter), registered
//   clock 10 the output is a bit slice of that sum
// A job takes 16 clocks plus one per sample that arrives during it (the write steals a clock): 18 at
// most in an HL2 burst, where an output is due every 20; 7.5 M outputs per second (120 MHz / 16 clocks)
// against 3.84 M needed at the widest span, so the filter keeps up at any clock above about 62 MHz and its
// backlog stays small.
//
// Which samples are kept: the reference keeps the outputs computed when its phase bit, toggled by every
// input, was 1 before the input: the job that ends before write index n for n = 1, 3, 5, ... (it uses
// samples n-1 down to n-63). That holds for inputs at least 3 clocks apart, which the fixed CIC in front
// (decimation 10) guarantees; with inputs on consecutive clocks the reference keeps the other phase, and
// this module does not follow it there. REQUIRES in_strobe pulses at least 3 clocks apart.
//
// Delay line (docs/ZOOM_IN_CHIP.md section 11): four reads a clock (the two samples of each of the two folded
// taps) from ONE copy of the samples, in two banks by bit 4 of the address, each bank a pair of
// true-dual-port block RAMs (I and Q, 16 bits each, DEPTH / 2 words): 4 block RAMs in all. The lane-1 and
// lane-2 addresses of one side differ by exactly 16, so they are always in different banks, and every bank
// gets one read of each side: port A reads the "x[n-k]" side, port B the "x[n-(TAPS-1-k)]" side or, in the
// clock after an input sample, writes it (into the bank of its address). In that clock the tap counter
// waits and the pipeline carries an empty step (which adds 0).
// REQUIRES TAPS = 63 (32 folded taps, 16 a lane).

module zoom_fir_half #(
    parameter TAPS         = 63,   // filter length (the only supported value)
    parameter IN_WIDTH     = 16,   // bits of one input sample
    parameter COEFF_WIDTH  = 18,   // up to 27
    parameter OUT_WIDTH    = 16,   // bits of one output sample
    parameter COEFF_FILE   = "rtl/zoom/zoom_fir_half_coeffs.hex",   // 32 coefficients, one per line, hexadecimal
    parameter DEPTH        = 512   // circular buffer: TAPS + the burst backlog, see above
)(
    input                         clock,
    input                         rst,           // synchronous reset
    input                         in_strobe,     // one-clock pulse per input sample (at least 3 clocks apart)
    input      signed [IN_WIDTH-1:0] in_i,       // input I
    input      signed [IN_WIDTH-1:0] in_q,       // input Q
    output reg                    out_strobe,    // one-clock pulse per output sample (every second input)
    output reg signed [OUT_WIDTH-1:0] out_i,     // output I
    output reg signed [OUT_WIDTH-1:0] out_q      // output Q
) /* synthesis syn_maxfan = 10000 syn_srlstyle = "registers" */;

localparam integer UNIQUE_TAPS = (TAPS + 1) / 2;          // 32 for TAPS=63
localparam integer HALF        = UNIQUE_TAPS / 2;         // 16: folded taps a lane, and the distance between the lanes' addresses
localparam integer PAIR_WIDTH  = IN_WIDTH + 1;
localparam integer SHIFT       = COEFF_WIDTH - 1;
localparam integer AW          = $clog2(DEPTH);
localparam integer GPW         = $clog2(HALF);            // 4: the bank is bit GPW of the address
localparam integer BAW         = AW - 1;                  // a bank's address: the address without bit GPW
localparam integer SUMW        = SHIFT + OUT_WIDTH;       // the bits of the lanes' sum that are kept
localparam [47:0]  ROUND       = 48'd1 << (SHIFT - 1);

initial if (UNIQUE_TAPS != 32 || HALF != (1 << GPW))
    $display("zoom_fir_half: TAPS = %0d is not supported (two lanes of 16 folded taps)", TAPS);

// coefficients: the first UNIQUE_TAPS of the file (the mirror half is the same values)
reg signed [COEFF_WIDTH-1:0] coeff [0:UNIQUE_TAPS-1];
initial $readmemh(COEFF_FILE, coeff);

// an address without its bank bit
function [BAW-1:0] bank_addr(input [AW-1:0] a);
    bank_addr = {a[AW-1:GPW+1], a[GPW-1:0]};
endfunction

// ---------------------------------------------------------------------------------- write side, job queue
reg [AW-1:0] wr_ptr = {AW{1'b0}};
reg          phase = 1'b0;
reg          kp1 = 1'b0, kp2 = 1'b0;                   // a kept job, two clocks after its input
reg [AW-1:0] pend = {AW{1'b0}};                        // kept jobs not started yet
reg [AW-1:0] np = {{(AW-1){1'b0}}, 1'b1};              // job pointer of the next job: 1, 3, 5, ...

// the sample, its address and "a sample came" one clock after in_strobe; the last as three kept copies
// (tap counter, port B address, valid bit), since it becomes a clock enable and a select
reg [2:0]             hold /* synthesis syn_preserve = 1 */;
reg [AW-1:0]          wa_q = {AW{1'b0}};
reg [2*IN_WIDTH-1:0]  wd_q = {2*IN_WIDTH{1'b0}};
initial hold = 3'd0;
always @(posedge clock) begin
    hold <= {3{in_strobe & ~rst}};
    wa_q <= wr_ptr;
    wd_q <= {in_i, in_q};
end

// ---------------------------------------------------------------------------------- clock 0: issue
reg            v0 = 1'b0;
reg [GPW-1:0]  gp0 = {GPW{1'b0}};
reg [AW-1:0]   jp0 = {AW{1'b0}};
reg            last0 = 1'b0;                            // gp0 == HALF - 1 while v0, kept as a register
wire           start = (pend != {AW{1'b0}}) & (~v0 | last0) & ~hold[0];

always @(posedge clock) begin
    if (rst) begin
        wr_ptr <= {AW{1'b0}};
        phase  <= 1'b0;
        kp1    <= 1'b0;
        kp2    <= 1'b0;
        pend   <= {AW{1'b0}};
        np     <= {{(AW-1){1'b0}}, 1'b1};
        v0     <= 1'b0;
        gp0    <= {GPW{1'b0}};
        last0  <= 1'b0;
    end else begin
        if (in_strobe) begin
            wr_ptr <= wr_ptr + 1'b1;
            phase  <= ~phase;
        end
        kp1 <= in_strobe & phase;
        kp2 <= kp1;
        pend <= pend + {{(AW-1){1'b0}}, kp2} - {{(AW-1){1'b0}}, start};
        if (start) begin
            v0  <= 1'b1;
            gp0 <= {GPW{1'b0}};
            last0 <= (HALF == 1);
            jp0 <= np;
            np  <= np + 2'd2;
        end else if (!hold[0]) begin                   // a clock that writes a sample: the tap waits
            if (v0 && !last0) begin
                gp0   <= gp0 + 1'b1;
                last0 <= (gp0 == HALF - 2);
            end else begin
                v0    <= 1'b0;
                last0 <= 1'b0;
            end
        end
    end
end

// ---------------------------------------------------------------------------------- clock 1: the four addresses
// lane 1 reads x[n-k] and x[n-(TAPS-1-k)] for k = gp0, lane 2 the same for k = gp0 + HALF
reg [AW-1:0]  r1_a1 = {AW{1'b0}}, r1_a2 = {AW{1'b0}}, r1_b1 = {AW{1'b0}}, r1_b2 = {AW{1'b0}};
reg           w1 = 1'b0;                               // this clock's step writes the new sample instead
reg [AW-1:0]  wa1 = {AW{1'b0}};
reg [2*IN_WIDTH-1:0] wd1 = {2*IN_WIDTH{1'b0}};
reg [GPW-1:0] ca1 = {GPW{1'b0}};
reg           v1 = 1'b0, f1 = 1'b0, l1 = 1'b0;

always @(posedge clock) begin
    r1_a1 <= jp0 - {{(AW-GPW){1'b0}}, gp0} - 1'b1;
    r1_a2 <= jp0 - {{(AW-GPW){1'b0}}, gp0} - 1'b1 - HALF[AW-1:0];
    r1_b1 <= jp0 - TAPS[AW-1:0] + {{(AW-GPW){1'b0}}, gp0};
    r1_b2 <= jp0 - TAPS[AW-1:0] + {{(AW-GPW){1'b0}}, gp0} + HALF[AW-1:0];
    w1    <= hold[1];
    wa1   <= wa_q;
    wd1   <= wd_q;
    ca1   <= gp0;
    v1    <= v0 & ~rst & ~hold[2];
    f1    <= (gp0 == {GPW{1'b0}});
    l1    <= last0;
end

// ---------------------------------------------------------------------------------- clock 2: sorted into the banks
// bank 0 holds the addresses with bit GPW = 0. Of the two addresses of a side, the one with the bit set is
// in bank 1, the other (16 less or more) in bank 0
reg [BAW-1:0] aa0 = {BAW{1'b0}}, aa1 = {BAW{1'b0}}, ab0 = {BAW{1'b0}}, ab1 = {BAW{1'b0}};
reg           we0 = 1'b0, we1 = 1'b0;
reg [2*IN_WIDTH-1:0] wd2 = {2*IN_WIDTH{1'b0}};
reg           sa2 = 1'b0, sb2 = 1'b0;                  // lane 1's address of that side is in bank 1
reg [GPW-1:0] ca2 = {GPW{1'b0}};
reg           v2 = 1'b0, f2 = 1'b0, l2 = 1'b0;

always @(posedge clock) begin
    aa0 <= bank_addr(r1_a1[GPW] ? r1_a2 : r1_a1);
    aa1 <= bank_addr(r1_a1[GPW] ? r1_a1 : r1_a2);
    ab0 <= w1 ? bank_addr(wa1) : bank_addr(r1_b1[GPW] ? r1_b2 : r1_b1);
    ab1 <= w1 ? bank_addr(wa1) : bank_addr(r1_b1[GPW] ? r1_b1 : r1_b2);
    we0 <= w1 & ~wa1[GPW];
    we1 <= w1 &  wa1[GPW];
    wd2 <= wd1;
    sa2 <= r1_a1[GPW];
    sb2 <= r1_b1[GPW];
    ca2 <= ca1;
    v2  <= v1 & ~rst;  f2 <= f1;  l2 <= l1;
end

// ---------------------------------------------------------------------------------- clocks 3 and 4
wire [2*IN_WIDTH-1:0] ma0, ma1, mb0, mb1;              // block RAM outputs (zoom_tdp_ram)
reg signed [COEFF_WIDTH-1:0] c3a = {COEFF_WIDTH{1'b0}}, c3b = {COEFF_WIDTH{1'b0}};
reg           sa3 = 1'b0, sb3 = 1'b0;
reg           v3 = 1'b0, f3 = 1'b0, l3 = 1'b0;
reg [2*IN_WIDTH-1:0] oa0 = {2*IN_WIDTH{1'b0}}, oa1 = {2*IN_WIDTH{1'b0}}, ob0 = {2*IN_WIDTH{1'b0}}, ob1 = {2*IN_WIDTH{1'b0}};
reg signed [COEFF_WIDTH-1:0] c4a = {COEFF_WIDTH{1'b0}}, c4b = {COEFF_WIDTH{1'b0}};
reg           sa4 = 1'b0, sb4 = 1'b0;
reg           v4 = 1'b0, f4 = 1'b0, l4 = 1'b0;

always @(posedge clock) begin
    // clock 3 (the block RAM reads: zoom_tdp_ram)
    c3a <= coeff[{1'b0, ca2}];
    c3b <= coeff[{1'b1, ca2}];
    sa3 <= sa2;  sb3 <= sb2;
    v3  <= v2 & ~rst;  f3 <= f2;  l3 <= l2;
    // clock 4
    oa0 <= ma0;  oa1 <= ma1;  ob0 <= mb0;  ob1 <= mb1;
    c4a <= c3a;  c4b <= c3b;
    sa4 <= sa3;  sb4 <= sb3;
    v4  <= v3 & ~rst;  f4 <= f3;  l4 <= l3;
end

zoom_tdp_ram #(.W(IN_WIDTH), .AW(BAW)) u_dly0_i (.clock(clock), .aa(aa0), .qa(ma0[2*IN_WIDTH-1:IN_WIDTH]),
    .ab(ab0), .web(we0), .db(wd2[2*IN_WIDTH-1:IN_WIDTH]), .qb(mb0[2*IN_WIDTH-1:IN_WIDTH]));
zoom_tdp_ram #(.W(IN_WIDTH), .AW(BAW)) u_dly0_q (.clock(clock), .aa(aa0), .qa(ma0[IN_WIDTH-1:0]),
    .ab(ab0), .web(we0), .db(wd2[IN_WIDTH-1:0]), .qb(mb0[IN_WIDTH-1:0]));
zoom_tdp_ram #(.W(IN_WIDTH), .AW(BAW)) u_dly1_i (.clock(clock), .aa(aa1), .qa(ma1[2*IN_WIDTH-1:IN_WIDTH]),
    .ab(ab1), .web(we1), .db(wd2[2*IN_WIDTH-1:IN_WIDTH]), .qb(mb1[2*IN_WIDTH-1:IN_WIDTH]));
zoom_tdp_ram #(.W(IN_WIDTH), .AW(BAW)) u_dly1_q (.clock(clock), .aa(aa1), .qa(ma1[IN_WIDTH-1:0]),
    .ab(ab1), .web(we1), .db(wd2[IN_WIDTH-1:0]), .qb(mb1[IN_WIDTH-1:0]));

// ---------------------------------------------------------------------------------- clock 5: pair sums
// lane 1 is the sample pair (a1, b1), lane 2 (a2, b2); a2 / b2 are in the other bank than a1 / b1
wire [2*IN_WIDTH-1:0] a1d = sa4 ? oa1 : oa0;
wire [2*IN_WIDTH-1:0] a2d = sa4 ? oa0 : oa1;
wire [2*IN_WIDTH-1:0] b1d = sb4 ? ob1 : ob0;
wire [2*IN_WIDTH-1:0] b2d = sb4 ? ob0 : ob1;
wire signed [IN_WIDTH-1:0] a1_i = a1d[2*IN_WIDTH-1:IN_WIDTH], a1_q = a1d[IN_WIDTH-1:0];
wire signed [IN_WIDTH-1:0] b1_i = b1d[2*IN_WIDTH-1:IN_WIDTH], b1_q = b1d[IN_WIDTH-1:0];
wire signed [IN_WIDTH-1:0] a2_i = a2d[2*IN_WIDTH-1:IN_WIDTH], a2_q = a2d[IN_WIDTH-1:0];
wire signed [IN_WIDTH-1:0] b2_i = b2d[2*IN_WIDTH-1:IN_WIDTH], b2_q = b2d[IN_WIDTH-1:0];

reg signed [PAIR_WIDTH-1:0]  x1i = {PAIR_WIDTH{1'b0}}, x1q = {PAIR_WIDTH{1'b0}};
reg signed [PAIR_WIDTH-1:0]  x2i = {PAIR_WIDTH{1'b0}}, x2q = {PAIR_WIDTH{1'b0}};
reg signed [COEFF_WIDTH-1:0] k1 = {COEFF_WIDTH{1'b0}}, k2 = {COEFF_WIDTH{1'b0}};
reg           acc5 = 1'b1;
reg [4:0]     ld = 5'd0;                               // last tap, clocks 5 to 9

always @(posedge clock) begin
    // a clock without a tap adds 0
    if (v4) begin
        x1i <= {a1_i[IN_WIDTH-1], a1_i} + {b1_i[IN_WIDTH-1], b1_i};
        x1q <= {a1_q[IN_WIDTH-1], a1_q} + {b1_q[IN_WIDTH-1], b1_q};
        x2i <= l4 ? {a2_i[IN_WIDTH-1], a2_i} : ({a2_i[IN_WIDTH-1], a2_i} + {b2_i[IN_WIDTH-1], b2_i});
        x2q <= l4 ? {a2_q[IN_WIDTH-1], a2_q} : ({a2_q[IN_WIDTH-1], a2_q} + {b2_q[IN_WIDTH-1], b2_q});
        k1  <= c4a;
        k2  <= c4b;
    end else begin
        x1i <= {PAIR_WIDTH{1'b0}};
        x1q <= {PAIR_WIDTH{1'b0}};
        x2i <= {PAIR_WIDTH{1'b0}};
        x2q <= {PAIR_WIDTH{1'b0}};
        k1  <= {COEFF_WIDTH{1'b0}};
        k2  <= {COEFF_WIDTH{1'b0}};
    end
    acc5 <= ~(v4 & f4);
    ld   <= {ld[3:0], v4 & l4 & ~rst};
end

// ---------------------------------------------------------------------------------- clocks 6 to 10
wire signed [47:0] p1i, p1q, p2i, p2q;
wire signed [26:0] mk1 = k1, mk2 = k2;                 // sign-extended to the block's ports
wire signed [17:0] m1i = x1i, m1q = x1q, m2i = x2i, m2q = x2q;
rx_mac #(.PRELOAD(ROUND)) u_mac1_i (.clock(clock), .a(mk1), .b(m1i), .acc(acc5), .p(p1i));
rx_mac #(.PRELOAD(ROUND)) u_mac1_q (.clock(clock), .a(mk1), .b(m1q), .acc(acc5), .p(p1q));
rx_mac #(.PRELOAD(48'd0)) u_mac2_i (.clock(clock), .a(mk2), .b(m2i), .acc(acc5), .p(p2i));
rx_mac #(.PRELOAD(48'd0)) u_mac2_q (.clock(clock), .a(mk2), .b(m2q), .acc(acc5), .p(p2q));

reg [SUMW-1:0] sum_i = {SUMW{1'b0}}, sum_q = {SUMW{1'b0}};

always @(posedge clock) begin
    if (ld[3]) begin
        sum_i <= p1i[SUMW-1:0] + p2i[SUMW-1:0];
        sum_q <= p1q[SUMW-1:0] + p2q[SUMW-1:0];
    end
    if (rst) begin
        out_strobe <= 1'b0;
        out_i      <= {OUT_WIDTH{1'b0}};
        out_q      <= {OUT_WIDTH{1'b0}};
    end else begin
        out_strobe <= ld[4];
        if (ld[4]) begin
            out_i <= sum_i[SHIFT +: OUT_WIDTH];
            out_q <= sum_q[SHIFT +: OUT_WIDTH];
        end
    end
end

endmodule

// A memory with two ports for one block RAM in true-dual-port mode (18 bits or fewer per port): port A
// reads, port B writes or else reads ("write, else read": the 138K has no read-before-write mode,
// docs/TANG_LESSONS.md section 8). Registered reads; the output register is the caller's.
module zoom_tdp_ram #(
    parameter W  = 16,
    parameter AW = 9
)(
    input               clock,
    input      [AW-1:0] aa,
    output reg [W-1:0]  qa,
    input      [AW-1:0] ab,
    input               web,
    input      [W-1:0]  db,
    output reg [W-1:0]  qb
);
reg [W-1:0] mem [0:(1<<AW)-1];
integer k;
initial begin
    for (k = 0; k < (1 << AW); k = k + 1) mem[k] = {W{1'b0}};
    qa = {W{1'b0}};
    qb = {W{1'b0}};
end
always @(posedge clock) qa <= mem[aa];
always @(posedge clock)
    if (web) mem[ab] <= db;
    else     qb <= mem[ab];
endmodule
