// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// compositor_util.v: the small building blocks that the compositor files share (rtl/video/compositor*.v, see
// docs/V2_COMPOSITOR.md): a delay line for matching pipeline stages, a dual-clock RAM for the line buffers, the
// once-per-frame copy of the picture description from clk_dsp into the pixel clock, and an event counter.
//
// Why these exist: the pixel pipeline of the compositor (compositor_pix.v) has 31 register stages, and many signals
// are found early and are needed late, so they have to wait the right number of clocks (comp_dly). The line buffers hold
// a whole screen line for the pixel side while the DDR3 side fills the next one, and the two sides run on different
// clocks (comp_ram). The wide picture description changes only in the vertical blanking, which allows the plain copy of
// comp_xfer. All four are plain Verilog with no vendor primitives; the attributes (syn_ramstyle, syn_preserve and so on)
// are hints for the Gowin synthesizer. Terms like LUT RAM and block RAM are in docs/learn/GLOSSARY.md.

`timescale 1ns / 1ps

// comp_dlyram: a delay of N clocks (3 <= N <= 16) built from a small LUT RAM and the output register, instead of N
// flip-flops for every bit. A LUT RAM (distributed RAM) is a memory made from the lookup tables of the logic cells, and since one
// lookup table holds 16 bits it costs a small fraction of the logic that the same number of flip-flops would use.
// The module is the same circuit as ft8_dly in rtl/ft8/ft8_dly.v under another name. How it works: a write pointer `wp`
// and a read pointer `rp` run around the N words, the read pointer one word ahead of the write pointer. Every clock the
// input is stored at `wp` and the word at `rp`, which was stored N-1 clocks earlier, goes into the output register, so the
// output shows the input of N clocks ago.
// W: width of the data in bits. N: delay in clocks.
module comp_dlyram #(
    parameter integer W = 8,
    parameter integer N = 4
) (
    input  wire         clk,  // clock
    input  wire [W-1:0] d,  // data in
    output reg  [W-1:0] q  // data in delayed by N clocks
) /* synthesis syn_maxfan = 10000 */;

// AW: bits of the pointers, enough to count N words (N up to 16). LAST is the highest word number, where a pointer wraps.
    localparam integer AW = (N > 8) ? 4 : (N > 4) ? 3 : 2;
    localparam [AW-1:0] LAST = N - 1;
// the memory: N words, kept in LUT RAM
    reg [W-1:0]  mem [0:N-1] /* synthesis syn_ramstyle = "distributed_ram" */;
// write pointer, starts at word 0, and read pointer, starts at word 1 (one ahead)
    reg [AW-1:0] wp = {AW{1'b0}};
    reg [AW-1:0] rp = {{(AW-1){1'b0}}, 1'b1};
// everything starts at zero, so the first N outputs are zeros
    integer i;
    initial begin
        for (i = 0; i < N; i = i + 1) mem[i] = {W{1'b0}};
        q = {W{1'b0}};
    end
// One store, one load and both pointers one step forward every clock, wrapping from the last word to word 0.
    always @(posedge clk) begin
        mem[wp] <= d;
        q       <= mem[rp];
        wp      <= (wp == LAST) ? {AW{1'b0}} : wp + 1'b1;
        rp      <= (rp == LAST) ? {AW{1'b0}} : rp + 1'b1;
    end

endmodule

// comp_dly: an N-clock delay of a W-bit word (no enable, no reset). The implementation depends on N and REG:
//   N = 0     wire
//   N = 1     one register
//   REG = 0   a plain shift register of N stages, which the synthesizer may turn into a shift register primitive or a
//             RAM if it likes (small and cheap, but not under control)
//   REG = 1   flip-flops for N below 4, and for longer delays a chain of comp_dlyram segments of at most 16 clocks each
//             (a long delay in flip-flops is expensive and the tool left alone would put it in a block RAM, which are
//             better spent on the line buffers)
module comp_dly #(
    parameter integer W = 1,  // data width in bits
    parameter integer N = 1,  // delay in clocks
    parameter integer REG = 0     // 1: build the delay from flip-flops or LUT RAM only, never block RAM
) (
    input  wire         clk,  // clock
    input  wire [W-1:0] d,  // data in
    output wire [W-1:0] q  // data in delayed by N clocks (the same clock as `d`)
);
    generate
        if (N == 0) begin : g0
            assign q = d;
        end else if (N == 1) begin : g1
            reg [W-1:0] r = {W{1'b0}};
            always @(posedge clk) r <= d;
            assign q = r;
// A shift register held in flip-flops: every clock the word moves one stage on, and the oldest word is the output.
        end else if (REG != 0 && N < 4) begin : gnr
            (* syn_srlstyle = "registers" *) reg [W*N-1:0] sh = {(W*N){1'b0}};
            always @(posedge clk) sh <= {sh[W*(N-1)-1:0], d};
            assign q = sh[W*N-1 -: W];
        end else if (REG != 0) begin : gnl
            // NS segments of at most 16 clocks each, one behind the other; the total is N clocks. NS = N / 16 rounded up,
            // and the clocks are spread over the segments as evenly as the division allows (DK below).
            localparam integer NS = (N + 15) / 16;
            wire [W-1:0] t [0:NS];
            assign t[0] = d;
            genvar k;
            for (k = 0; k < NS; k = k + 1) begin : seg
                localparam integer DK = N / NS + ((k < N % NS) ? 1 : 0);
                comp_dlyram #(.W(W), .N(DK)) u (.clk(clk), .d(t[k]), .q(t[k+1]));
            end
            assign q = t[NS];
            // plain shift register, W x N flip-flops (or whatever the tool prefers)
        end else begin : gn
            reg [W*N-1:0] sh = {(W*N){1'b0}};
            always @(posedge clk) sh <= {sh[W*(N-1)-1:0], d};
            assign q = sh[W*N-1 -: W];
        end
    endgenerate
endmodule

// comp_ram: a simple dual-port RAM with one write port in clock clk_w and one read port in clock clk_r, the read data
// registered (it appears one clk_r clock after the address). With both clocks the same, reading the word that is being
// written returns the old word. Built so that it is inferred as block RAM (a Gowin BSRAM of 18 kbit); the compositor's line
// buffers use it with the DDR3 side writing in clk_dsp and the pixel side reading in clk_pix. That is safe without any
// synchronization because the two sides never touch the same half of a buffer at the same time: while a line is shown from
// one half, the next line is written into the other half. With LUT = 1 the same module is built from LUT RAM instead.
module comp_ram #(
    parameter integer DW = 64,  // data width in bits
    parameter integer AW = 10,  // address width in bits (the memory has 2^AW words)
    parameter integer LUT = 0     // 1: LUT RAM, not block RAM (used for the six spare bits of the palette, which would waste half a block)
) (
    input  wire          clk_w,  // write clock
    input  wire          we,  // write enable, high for one word per clk_w
    input  wire [AW-1:0] wa,  // write address
    input  wire [DW-1:0] wd,  // write data
    input  wire          clk_r,  // read clock
    input  wire [AW-1:0] ra,  // read address
    output reg  [DW-1:0] rd  // read data, registered, valid one clk_r after `ra`
);
    generate
        if (LUT != 0) begin : g_lut
            (* syn_ramstyle = "distributed_ram" *) reg [DW-1:0] mem [0:(1 << AW) - 1];
            always @(posedge clk_w) if (we) mem[wa] <= wd;
            always @(posedge clk_r) rd <= mem[ra];
        end else begin : g_blk
            reg [DW-1:0] mem [0:(1 << AW) - 1];
            always @(posedge clk_w) if (we) mem[wa] <= wd;
            always @(posedge clk_r) rd <= mem[ra];
        end
    endgenerate
endmodule

// comp_xfer: the frame copy of the picture description into the pixel clock. `snap` (the register file's own registers in
// clk_dsp, steady from long before load_b until the next frame's capture) is copied into `cfg` (in clk_b, the pixel clock)
// when load_b pulses. No synchronizer is needed for the data because it is steady for most of a frame, including the
// moment of the copy; what makes it steady is the handshake of toggle bits in compositor.v, which orders the capture and the load. The
// copy is done in groups of GR bits, and the enable of each group is a register of its own (copies of the load pulse in a
// kept vector, two levels deep), so that no enable signal drives more than about GR + 10 flip-flops, which keeps the routing
// short enough for the pixel clock (docs/TANG_LESSONS.md section 3).
module comp_xfer #(
    parameter integer W  = 100,  // width of the description in bits (CF_W of compositor_cfg.vh)
    parameter integer GR = 12  // bits per enable group
) (
    input  wire [W-1:0] snap,  // the description in clk_dsp, steady while load_b arrives
    input  wire         clk_b,  // pixel clock
    input  wire         load_b,  // one clk_b pulse: take the description now
  // the copy in clk_b, changes only just after a load pulse
    output wire [W-1:0] cfg
);
// NR groups of GR bits (rounded up); WP is the width padded to a whole number of groups; N1 is the number of first-level
// copies of the pulse, one for every ten groups.
    localparam integer NR = (W + GR - 1) / GR;
    localparam integer WP = NR * GR;
    localparam integer N1 = (NR + 9) / 10;

// `snap` padded with zeros to whole groups, and the pixel side's copy of the same width
    wire [WP-1:0] snap_p = {{(WP - W){1'b0}}, snap};
    reg  [WP-1:0] cfg_p  = {WP{1'b0}};

// first level (b1) and second level (br) of the load pulse copies, kept as separate registers; each br drives one group
    reg [N1-1:0] b1 /* synthesis syn_preserve = 1 */;
    reg [NR-1:0] br /* synthesis syn_preserve = 1 */;
    initial begin b1 = {N1{1'b0}}; br = {NR{1'b0}}; end

// the group enables follow load_b by two clocks and the data move on the third
    always @(posedge clk_b) b1 <= {N1{load_b}};

    genvar g;
    generate
        for (g = 0; g < NR; g = g + 1) begin : grp
            // each group's own enable: copy GR bits when its br is high
            always @(posedge clk_b) begin
                br[g] <= b1[g / 10];
                if (br[g]) cfg_p[g*GR +: GR] <= snap_p[g*GR +: GR];
            end
        end
    endgenerate

    assign cfg  = cfg_p[W-1:0];
endmodule

// comp_cnt32: a 32-bit event counter built as two 16-bit halves. The carry into the upper half is registered, so neither
// half has more than 16 enable loads and no carry chain is longer than 16 bits. The upper half follows the lower one by a
// clock, so for one clock after the lower half wraps `q` is 65,536 too low. `inc` and `clr` should come straight from
// registers. `clr` clears the counter and has priority over `inc`.
module comp_cnt32 (
    input  wire        clk,  // clock
    input  wire        inc,  // one clock high per event to count
    input  wire        clr,  // one clock high to clear the count to 0
    output wire [31:0] q  // the count, 32 bits, wraps at 2^32
);
// lower and upper half, and the registered carry between them
    reg [15:0] lo = 16'd0, hi = 16'd0;
    reg        cy = 1'b0;
// carry = the lower half is about to wrap this clock
    always @(posedge clk) begin
        cy <= inc & (lo == 16'hFFFF);
        if (clr) begin
            lo <= 16'd0;
            hi <= 16'd0;
        end else begin
            if (inc) lo <= lo + 16'd1;
            if (cy)  hi <= hi + 16'd1;
        end
    end
    assign q = {hi, lo};
endmodule
