// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// fft_r22sdf: a streaming FFT (fast Fourier transform) of any power-of-two size, built as a radix-2^2
// single-path delay-feedback pipeline with decimation in frequency. It takes one sample per
// valid pulse and gives one transform value per sample, with no dead time between transforms,
// which is what the full-band spectrum display (16,384 points, 4,687.5 transforms per second
// from the 76.8 Msps ADC stream, 4.6875 kHz per bin) and the zoom spectrum (4,096 points) need.
// Decision and measurements: docs/F1_FFT.md; system role: docs/ARCHITECTURE.md section 3.3. The
// terms (FFT, bin, butterfly, twiddle factor, bit-reversed order) are explained in
// docs/learn/GLOSSARY.md.
//
// How it is built: an FFT of N = 2^LOG_N points is LOG_N butterfly stages (fft_bf.v), each
// combining samples that are N/2, N/4, ... 1 apart in the stream, with a twiddle multiplication
// (fft_twmul.v) inserted after every second stage. A pair of stages is a radix-4 step, which is
// why the structure is called radix-2^2: the multiplication by -j inside the pair costs nothing
// (swap and negate), so a real multiplier is needed only once for every two stages, which gives
// 6 multipliers (24 DSP blocks, four real multiplies each) for 16,384 points. Each stage has a
// delay line of N/2, N/4 ... samples (fft_delay.v), which together hold about N samples, so the
// whole FFT needs only about one frame of memory and not the several frames of other designs
// (35 block RAMs of 18 kbit at 16,384 points, against about 6 times that for a conventional
// pipelined design with input and output buffers). The first delay line stores only the real
// part when the input is real (REAL_IN = 1).
//
// * One complex (or real) sample per in_valid; in_valid may be high on consecutive cycles or have
//   any gaps. Every sample belongs to a transform: frames are consecutive blocks of 2^LOG_N valid
//   samples counted from reset (no dead time, no start signal).
// * One output per input: out_valid follows in_valid after a fixed pipeline delay (63 clocks from
//   the last sample of a frame to the first output word, in the full-band configuration). The
//   first 2^LOG_N - 1 outputs after reset are suppressed (pipeline filling); from then on output
//   frame f is the transform of input frame f.
// * Output order is bit-reversed: out_index counts 0 .. 2^LOG_N - 1 within a frame and out_bin is
//   the frequency bin of the current word (bit-reverse of out_index). out_first marks index 0.
//   There is no reorder buffer here on purpose: the users drop half of the words (the mirror
//   half of a real input's spectrum) and put the rest in order after taking the power.
// * Full precision: out = sum_n x[n] exp(-j 2 pi k n / N) with no scaling, output width
//   IW + LOG_N bits (the data grows by one bit in every stage, 15 bits in and 29 bits out for the
//   full-band FFT). The only rounding is in the twiddle multipliers (18-bit twiddles, scaled by
//   (2^17 - 1) / 2^17, so the gain is 1 - 7.6e-6 per multiplier: -0.0004 dB for 16k points).
//   No overflow is possible for any input whose magnitude is <= 2^(IW-1) (any real input).
// * Multiplier inputs are IW + LOG_N - 2 bits wide at most; keep that <= 27 for one DSP (27x18)
//   per real multiply: IW <= 15 at LOG_N = 14, IW <= 17 at LOG_N = 12.
// A frame is accurate to 105 to 114 dB below a tone (the FFT's own error), which is 38 dB below the
// noise floor of a 12-bit ADC, so the ADC and not the FFT limits the dynamic range.
//
// Parameters: LOG_N (>= 3), IW (input width per component), REAL_IN (1: imaginary input ignored,
// first delay line stores the real part only), TW_DIR (directory of the twiddle ROM files,
// relative to where the simulator or synthesiser runs).
//
// INJ_S (docs/ZOOM_FIT.md section 2; 0 = off, else an even stage number): a second, shorter transform
// through the same hardware. Behind stage INJ_S the stream is a sequence of blocks of 2^(LOG_N - INJ_S)
// words, and the stages from INJ_S + 1 on are a complete streaming FFT of that size which transforms every
// block on its own. With INJ_S set, a block of 2^(LOG_N - INJ_S) complex samples of IW + INJ_S bits may
// be put in there (inj_valid, inj_re, inj_im), between two blocks of the main stream:
//   - the caller stops in_valid when a multiple of 2^(LOG_N - INJ_S) main samples has gone in (for the
//     main frames to stay whole in time: at a frame boundary), waits until the stages in front have passed
//     their last word on (their register delay, 2 + 7 clocks per twiddle multiplier; 32 clocks is safe),
//     gives exactly 2^(LOG_N - INJ_S) words with inj_valid (any gaps), and then goes on with in_valid;
//   - inj_valid and in_valid are never high for words that would meet at the injection point.
// The transform of the block put in comes out on out_ivalid / out_ifirst / out_iindex / out_ibin with the
// data on out_re / out_im (sign-extended to their width), in bit-reversed order like the main output;
// out_valid and out_index skip those words. One register stage is added in front of stage INJ_S + 1.
// The values of the main transform are unchanged.

`timescale 1ns / 1ps

module fft_r22sdf #(
    parameter integer LOG_N   = 14,       // log2 of the transform size N (14: 16,384 points)
    parameter integer IW      = 15,       // bits of one input component (real or imaginary part)
    parameter integer REAL_IN = 1,        // 1: real input
    parameter         TW_DIR  = "rtl/fft/tw/",   // directory of the twiddle ROM files
    parameter integer SR_LUT  = 0,        // delay lines of up to 32 words as LUT RAM, not block RAM
    parameter integer LUT_MAX_W = 64,     // delay lines of up to this many words as LUT RAM (the zoom FFT sets 128)
    parameter integer TW_LUT_MAX = 32,    // twiddle ROMs of up to this many words in LUTs (the full-band spectrum FFT sets 128)
    parameter integer TW_M1_ONE = 0,      // fft_twmul.v M1_ONE: one clock less per twiddle multiplier (enough at 120 MHz)
    parameter integer INJ_S   = 0         // 0, or the stage behind which the blocks of a second stream are put in (see above)
) (
    input  wire                    clk,
    input  wire                    rst,         // synchronous reset, restarts the frame count
    input  wire                    in_valid,    // one-clock pulse per input sample (any gaps)
    input  wire [IW-1:0]           in_re,       // input, real part, two's complement
    input  wire [IW-1:0]           in_im,       // input, imaginary part (ignored when REAL_IN = 1)
    output reg                     out_valid,   // an output word is valid (the first N - 1 after reset are dropped)
    output reg                     out_first,   // the word is the first of its frame (out_index = 0)
    output reg  [LOG_N-1:0]        out_index,   // position in the frame, 0 .. N - 1, bit-reversed order
    output wire [LOG_N-1:0]        out_bin,     // frequency bin of the word, the bit-reverse of out_index
    output reg  [IW+LOG_N-1:0]     out_re,      // transform value, real part, unscaled
    output reg  [IW+LOG_N-1:0]     out_im,      // imaginary part
    // the second stream (INJ_S != 0 only; leave open otherwise)
    input  wire                    inj_valid,
    input  wire [IW+INJ_S-1:0]     inj_re,
    input  wire [IW+INJ_S-1:0]     inj_im,
    output reg                     out_ivalid,
    output reg                     out_ifirst,
    output reg  [LOG_N-INJ_S-1:0]  out_iindex,
    output wire [LOG_N-INJ_S-1:0]  out_ibin
);

    localparam integer N  = 1 << LOG_N;
    localparam integer OW = IW + LOG_N;
    localparam integer MW = OW + 1;            // width of the per-stage buses (widest stage)

    // Stage s (1..LOG_N) takes bus s-1 (width IW+s-1) and drives bus s (width IW+s). v[s] is the
    // valid flag of bus s and br/bi the real and imaginary parts, all sign extended to MW bits.
    wire [LOG_N:0] v;
    wire [MW-1:0]  br [0:LOG_N];
    wire [MW-1:0]  bi [0:LOG_N];

    assign v[0]  = in_valid;
    assign br[0] = {{(MW-IW){in_re[IW-1]}}, in_re};
    assign bi[0] = {{(MW-IW){in_im[IW-1]}}, in_im};

    // What stage s takes: bus s-1, or behind the injection point the registered choice between bus INJ_S
    // and the second stream.
    wire [LOG_N:0] sv;
    wire [MW-1:0]  sr [0:LOG_N];
    wire [MW-1:0]  si [0:LOG_N];
    localparam integer JW = IW + INJ_S;
    localparam integer TL = LOG_N - INJ_S;      // log2 of the block behind the injection point
    wire jpush;                                  // a block starts at the injection point
    wire jtag;                                   // and it belongs to the second stream

    genvar s;
    generate
        for (s = 1; s <= LOG_N; s = s + 1) begin : g_in
            if (INJ_S != 0 && s == INJ_S + 1) begin : g_inj
                reg          jv = 1'b0, jt = 1'b0;
                reg [MW-1:0] jr = {MW{1'b0}}, ji = {MW{1'b0}};
                reg [TL-1:0] jcnt = {TL{1'b0}};
                always @(posedge clk) begin
                    jv <= rst ? 1'b0 : (v[s-1] | inj_valid);
                    jt <= inj_valid;
                    jr <= inj_valid ? {{(MW-JW){inj_re[JW-1]}}, inj_re} : br[s-1];
                    ji <= inj_valid ? {{(MW-JW){inj_im[JW-1]}}, inj_im} : bi[s-1];
                    if (rst)     jcnt <= {TL{1'b0}};
                    else if (jv) jcnt <= jcnt + 1'b1;
                end
                assign sv[s-1] = jv;
                assign sr[s-1] = jr;
                assign si[s-1] = ji;
                assign jpush   = jv && (jcnt == {TL{1'b0}});
                assign jtag    = jt;
            end else begin : g_thru
                assign sv[s-1] = v[s-1];
                assign sr[s-1] = br[s-1];
                assign si[s-1] = bi[s-1];
            end
        end
        if (INJ_S == 0) begin : g_noinj
            assign jpush = 1'b0;
            assign jtag  = 1'b0;
        end
    endgenerate

    // The stages. Stage s has a delay line of L = N / 2^s samples. D is
    // the number of samples that have passed before the stage sees the first one it needs, and
    // CINIT turns that into the starting position of the stage's own counter, so that the
    // counters need no start signal. Odd stages are BF2I, even stages BF2II, and a twiddle
    // multiplier follows each BF2II whose remaining frame (LOGNP) is at least 8 samples.
    generate
        for (s = 1; s <= LOG_N; s = s + 1) begin : g_st
            localparam integer WI    = IW + s - 1;
            localparam integer L     = N >> s;
            localparam integer D     = N - (N >> (s - 1));     // sample delay before this stage
            localparam integer P     = 4 * L;
            localparam integer CINIT = (P - (D % P)) % P;
            localparam integer TYPE  = (s % 2 == 1) ? 1 : 2;
            localparam integer LOGNP = LOG_N - s + 2;            // frame size after this pair
            localparam integer HASM  = ((TYPE == 2) && (LOGNP >= 3)) ? 1 : 0;

            wire           bv;
            wire [WI:0]    bor, boi;
            fft_bf #(
                .IW(WI), .L(L), .TYPE(TYPE),
                .REAL_IN((s == 1) ? REAL_IN : 0), .CNT_INIT(CINIT), .SR_LUT(SR_LUT), .LUT_MAX_W(LUT_MAX_W)
            ) u_bf (
                .clk(clk), .rst(rst),
                .in_valid(sv[s-1]), .in_re(sr[s-1][WI-1:0]), .in_im(si[s-1][WI-1:0]),
                .out_valid(bv), .out_re(bor), .out_im(boi)
            );

            if (HASM != 0) begin : g_mul
                localparam integer NPM  = 1 << LOGNP;
                localparam integer DM   = N - (N >> s);
                localparam integer MINI = (NPM - (DM % NPM)) % NPM;
                wire          mv;
                wire [WI:0]   mr, mi;
                fft_twmul #(
                    .W(WI + 1), .LOG_NP(LOGNP), .CNT_INIT(MINI), .TW_DIR(TW_DIR), .TW_LUT_MAX(TW_LUT_MAX), .M1_ONE(TW_M1_ONE)
                ) u_mul (
                    .clk(clk), .rst(rst),
                    .in_valid(bv), .in_re(bor), .in_im(boi),
                    .out_valid(mv), .out_re(mr), .out_im(mi)
                );
                assign v[s]  = mv;
                assign br[s] = {{(MW-WI-1){mr[WI]}}, mr};
                assign bi[s] = {{(MW-WI-1){mi[WI]}}, mi};
            end else begin : g_nomul
                assign v[s]  = bv;
                assign br[s] = {{(MW-WI-1){bor[WI]}}, bor};
                assign bi[s] = {{(MW-WI-1){boi[WI]}}, boi};
            end
        end
    endgenerate

    // Whose block is at the output (INJ_S != 0). A block that goes in at the injection point comes out
    // 2^TL - 1 words later, so at most two tags wait; the queue holds four. Word j at the output (counted
    // from reset) is the first of a block when j = 2^TL - 1 (mod 2^TL); the words before the first block
    // are the pipeline filling and count as words of the main stream.
    wire tag_now;
    generate
        if (INJ_S != 0) begin : g_tag
            reg [3:0]    tq = 4'd0;
            reg [1:0]    twp = 2'd0, trp = 2'd0;
            reg [TL-1:0] tcnt = 1;
            reg          tfirst = 1'b0;                 // the next output word starts a block
            reg          tcur = 1'b0;
            always @(posedge clk) begin
                if (rst) begin
                    twp <= 2'd0; trp <= 2'd0; tcnt <= 1; tfirst <= 1'b0; tcur <= 1'b0;
                end else begin
                    if (jpush) begin
                        tq[twp] <= jtag;
                        twp     <= twp + 2'd1;
                    end
                    if (v[LOG_N]) begin
                        tcnt   <= tcnt + 1'b1;
                        tfirst <= (tcnt == {TL{1'b1}});
                        if (tfirst) begin
                            tcur <= tq[trp];
                            trp  <= trp + 2'd1;
                        end
                    end
                end
                if (v[LOG_N] && tag_now) out_iindex <= tfirst ? {TL{1'b0}} : tcnt;
                out_ivalid <= !rst && v[LOG_N] && tag_now;
                out_ifirst <= !rst && v[LOG_N] && tag_now && tfirst;
            end
            assign tag_now = tfirst ? tq[trp] : tcur;
            genvar bb;
            for (bb = 0; bb < TL; bb = bb + 1) begin : g_irev
                assign out_ibin[bb] = out_iindex[TL-1-bb];
            end
        end else begin : g_notag
            assign tag_now = 1'b0;
            assign out_ibin = {(LOG_N-INJ_S){1'b0}};
            always @(posedge clk) begin
                out_ivalid <= 1'b0;
                out_ifirst <= 1'b0;
                out_iindex <= {(LOG_N-INJ_S){1'b0}};
            end
        end
    endgenerate
    wire ov_main = v[LOG_N] && !tag_now;

    // Output framing. Output count j (valid words of the main stream since reset) holds frame position
    // (j - (N - 1)) mod N; the first N - 1 words are the pipeline filling and are dropped.
    reg [LOG_N-1:0] ocnt   = 1;
    reg             primed = 1'b0;
    always @(posedge clk) begin
        if (rst) begin
            ocnt      <= 1;
            primed    <= 1'b0;
            out_valid <= 1'b0;
            out_first <= 1'b0;
        end else begin
            out_valid <= ov_main && (primed || ocnt == 0);
            out_first <= ov_main && (ocnt == 0);
            if (ov_main) begin
                ocnt <= ocnt + 1'b1;
                if (ocnt == 0) primed <= 1'b1;
            end
        end
        if (ov_main) out_index <= ocnt;
        if (v[LOG_N]) begin
            out_re    <= br[LOG_N][OW-1:0];
            out_im    <= bi[LOG_N][OW-1:0];
        end
    end

    genvar b;
    generate
        for (b = 0; b < LOG_N; b = b + 1) begin : g_rev
            assign out_bin[b] = out_index[LOG_N-1-b];
        end
    endgenerate

endmodule
