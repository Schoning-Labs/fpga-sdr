// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// zoom_cic_narrow: the extra decimation of the zoom DDC for the narrow spans, 24 kHz down to 3 kHz
// (docs/ZOOM_IN_CHIP.md section 12): a third CIC of STAGES stages behind cic_var_pow2, with a
// decimation of 2, 4, 8 or 16 (`shift` 1 to 4; 0 passes the samples through). It is used only when
// cic_var_pow2 is already at its largest decimation (64), so the samples come 640 clocks apart or more,
// and that is slow enough for this CIC to be worked out one add at a time by one adder, with its
// 2 x 2 x STAGES words of state in LUT RAM: about 450 LUT, no block RAM, no multiplier. Adding four more
// decimations to cic_var_pow2 itself would have made its 66 accumulators 126 bits wide (3,000 registers
// more). The terms (CIC, integrator, comb, bit growth) are explained in docs/learn/GLOSSARY.md.
//
// What it computes, per channel (I, then Q), for every input word x:
//   integrators   v = x;  for s = 0 .. STAGES-1:  I[s] = I[s] + v;  v = I[s]
//   every 2^shift-th input also the combs:        for s:  t = v - D[s];  D[s] = v;  v = t
//   output        v / 2^(STAGES*shift - 2*gain), rounded half up, saturated to WIDTH bits
// The accumulators are WIDTH + STAGES*MAX_SHIFT bits (60) and wrap. With gain = 0 the DC gain is 1, as
// in the other CIC stages. `gain` (0 to 3) multiplies by 4^gain = 1, 4, 16 or 64 (0, 12, 24 or 36 dB):
// at a span of a few kHz the noise in the band is far below one step of a 16-bit word that is scaled
// for the ADC's full scale, and the 16-bit words and the spectrum's power words behind this stage
// would round it away.
//
// One add takes four clocks (two halves of 30 bits, memory read and write registered):
//   0  state word read from LUT RAM        1  low half        2  high half (carry from a register)
//   3  write word and strobe registered    (the write lands in the next step's clock 0)
// The value handed from stage to stage (v, 60 bits) takes its orders from a command register, one clock
// after the sequence gives them, in six kept copies of 10 loads each: as a clock enable straight from the
// state register it would be one net of 59 loads, which is too slow. Every order is given at least one
// clock before v is read, so nothing else moves.
// After the arithmetic the output is shifted right one bit a clock, range-checked and rounded: at most
// 4 * 44 + 2 * 47 clocks per input. REQUIRES in_strobe pulses at least 300 clocks apart when shift != 0
// (a pulse that comes while one is worked on is lost), and `shift` and `gain` changed only while rst
// is high. rst clears the state memories at one word a clock (32 clocks for all; whatever is left in
// them is gone from the output after STAGES output words in any case).
//
// shift = 0: out_strobe and the word are in_strobe and the word read at in_strobe, one clock later.
//
// Where it sits: rtl/zoom/zoom_ddc.v puts it behind cic_var_pow2, so its input is the 16-bit I and Q words of that CIC
// at 120 ksps (one word every 640 clocks, which is why the 300 clock minimum between strobes
// is always met), and what it hands on goes to zoom_fir_half, the half-band filter that decimates by two more, and
// then to zoom_cic_comp. With shift = 4 the rate behind this block is 7.5 ksps, and 3.75 ksps behind the half-band
// filter, which is the 3 kHz span.

module zoom_cic_narrow #(
    parameter STAGES    = 11,   // integrator and comb stages
    parameter WIDTH     = 16,   // bits of one sample
    parameter MAX_SHIFT = 4     // decimation up to 2^MAX_SHIFT
)(
    input                         clock,
    input                         rst,       // synchronous reset
    input      [2:0]              shift,     // 0: pass through; 1..MAX_SHIFT: decimate by 2^shift
    input      [1:0]              gain,      // output gain 4^gain, saturating (only with shift != 0)
    input                         in_strobe, // one-clock pulse per input sample (at least 300 clocks apart)
    input      signed [WIDTH-1:0] in_i,      // input I
    input      signed [WIDTH-1:0] in_q,      // input Q
    output reg                    out_strobe,// one-clock pulse per output sample
    output reg signed [WIDTH-1:0] out_i,     // output I
    output reg signed [WIDTH-1:0] out_q      // output Q
) /* synthesis syn_maxfan = 10000 syn_srlstyle = "registers" */;

localparam integer ACC = WIDTH + STAGES * MAX_SHIFT;
localparam integer LW  = ACC / 2;
localparam integer HW  = ACC - LW;
localparam integer SW  = $clog2(STAGES);
localparam integer AW  = SW + 1;                        // {channel, stage}

localparam [2:0] S_IDLE = 3'd0, S_OP = 3'd1, S_SHIFT = 3'd2, S_RNDA = 3'd3, S_RNDB = 3'd4;

// ---------------------------------------------------------------------------------------- settings
reg [2:0] n_q = 3'd0;                                   // shift, limited to MAX_SHIFT
reg       byp = 1'b1;
reg [3:0] mask = 4'd0;                                  // decimation - 1
reg [5:0] tot = 6'd0;                                   // STAGES * shift
reg [5:0] shamt = 6'd0;                                 // bits to shift right before the rounding bit
always @(posedge clock) begin
    n_q <= (shift > MAX_SHIFT) ? MAX_SHIFT[2:0] : shift;
    byp <= (shift == 3'd0);
    case (n_q)
        3'd0:    begin mask <= 4'b0000; tot <= 6'd0;          end
        3'd1:    begin mask <= 4'b0001; tot <= 1 * STAGES;    end
        3'd2:    begin mask <= 4'b0011; tot <= 2 * STAGES;    end
        3'd3:    begin mask <= 4'b0111; tot <= 3 * STAGES;    end
        default: begin mask <= 4'b1111; tot <= 4 * STAGES;    end
    endcase
    shamt <= tot - {3'd0, gain, 1'b0} - 6'd1;
end

// ---------------------------------------------------------------------------------------- state memories
// integrators (mi) and comb delays (mc), each in a low and a high half with a write strobe of its own
reg [LW-1:0] mi_l [0:(1<<AW)-1] /* synthesis syn_ramstyle = "distributed_ram" */;
reg [HW-1:0] mi_h [0:(1<<AW)-1] /* synthesis syn_ramstyle = "distributed_ram" */;
reg [LW-1:0] mc_l [0:(1<<AW)-1] /* synthesis syn_ramstyle = "distributed_ram" */;
reg [HW-1:0] mc_h [0:(1<<AW)-1] /* synthesis syn_ramstyle = "distributed_ram" */;
integer ik;
initial for (ik = 0; ik < (1 << AW); ik = ik + 1) begin
    mi_l[ik] = {LW{1'b0}}; mi_h[ik] = {HW{1'b0}}; mc_l[ik] = {LW{1'b0}}; mc_h[ik] = {HW{1'b0}};
end

reg [2:0]        st = S_IDLE;
reg [1:0]        ph = 2'd0;
reg              kind = 1'b0;                           // 0 integrator, 1 comb
reg              ch = 1'b0;                             // 0 I, 1 Q
reg [SW-1:0]     s = {SW{1'b0}};
reg              dec_r = 1'b0;
reg [3:0]        cnt = 4'd0;
reg [5:0]        shc = 6'd0;
reg signed [WIDTH-1:0] xi = {WIDTH{1'b0}}, xq = {WIDTH{1'b0}};
reg [ACC-1:0]    v = {ACC{1'b0}};                       // the value handed from stage to stage
reg [ACC-1:0]    m = {ACC{1'b0}};                       // the state word read
reg [LW+1:0]     lo = {(LW+2){1'b0}};                   // {carry, low half, 1}
reg [HW-1:0]     hi = {HW{1'b0}};
wire [AW-1:0]    a = {ch, s};
wire [ACC-1:0]   res = {hi, lo[LW:1]};

// v + m (integrator) or v - m = v + ~m + 1 (comb), in two halves, the carry on the adder's carry input
wire [LW-1:0] ml = m[LW-1:0]   ^ {LW{kind}};
wire [HW-1:0] mh = m[ACC-1:LW] ^ {HW{kind}};
wire [LW+1:0] lo_w = {1'b0, v[LW-1:0], 1'b1} + {1'b0, ml, kind};
wire [HW:0]   hi_w = {v[ACC-1:LW], 1'b1} + {mh, lo[LW+1]};

reg [1:0]      we_i /* synthesis syn_preserve = 1 */;
reg [1:0]      we_c /* synthesis syn_preserve = 1 */;
reg [AW-1:0]   wa = {AW{1'b0}};
reg [ACC-1:0]  wd = {ACC{1'b0}};
reg [AW-1:0]   clr = {AW{1'b0}};
initial begin we_i = 2'b00; we_c = 2'b00; end
wire op_last = (st == S_OP) && (ph == 2'd3);
always @(posedge clock) begin
    we_i <= {2{rst | (op_last & ~kind)}};
    we_c <= {2{rst | (op_last &  kind)}};
    wa   <= rst ? clr : a;
    wd   <= rst ? {ACC{1'b0}} : (kind ? v : res);
    clr  <= clr + 1'b1;
    if (we_i[0]) mi_l[wa] <= wd[LW-1:0];
    if (we_i[1]) mi_h[wa] <= wd[ACC-1:LW];
    if (we_c[0]) mc_l[wa] <= wd[LW-1:0];
    if (we_c[1]) mc_h[wa] <= wd[ACC-1:LW];
end

// ---------------------------------------------------------------------------------------- output rounding
reg                 zf = 1'b0, of = 1'b0, sg = 1'b0;
reg signed [WIDTH:0] r17 = {(WIDTH+1){1'b0}};
reg signed [WIDTH-1:0] oi = {WIDTH{1'b0}};
localparam signed [WIDTH-1:0] VMAX = {1'b0, {(WIDTH-1){1'b1}}};
localparam signed [WIDTH-1:0] VMIN = {1'b1, {(WIDTH-1){1'b0}}};
wire signed [WIDTH-1:0] rnd = !(zf | of)                   ? (sg ? VMIN : VMAX)
                            : (r17[WIDTH] != r17[WIDTH-1]) ? VMAX
                            :                                r17[WIDTH-1:0];

// ---------------------------------------------------------------------------------------- sequence
// the input words wait here (taken at every in_strobe: the next one is far away)
always @(posedge clock) if (in_strobe) begin xi <= in_i; xq <= in_q; end

// ---- v: orders 0 keep, 1 the I word, 2 the Q word, 3 the result of the add, 4 one bit to the right
localparam integer VG = 10;                             // bits per copy of the order
localparam integer NVG = (ACC + VG - 1) / VG;
reg  [2:0]         v_ord;
reg  [3*NVG-1:0]   v_cmd /* synthesis syn_preserve = 1 */;
initial v_cmd = {(3*NVG){1'b0}};
always @(*) begin
    v_ord = 3'd0;
    if (!rst) case (st)
        S_IDLE:  if (!byp && in_strobe) v_ord = 3'd1;
        S_OP:    if (ph == 2'd3) v_ord = (s == STAGES - 1 && !kind && !dec_r && !ch) ? 3'd2 : 3'd3;
        S_SHIFT: if (shc != 6'd0) v_ord = 3'd4;
        S_RNDB:  if (!ch) v_ord = 3'd2;
        default: v_ord = 3'd0;
    endcase
end
wire [ACC-1:0] v_xi = {{(ACC-WIDTH){xi[WIDTH-1]}}, xi};
wire [ACC-1:0] v_xq = {{(ACC-WIDTH){xq[WIDTH-1]}}, xq};
wire [ACC-1:0] v_sh = {v[ACC-1], v[ACC-1:1]};
integer vg;
always @(posedge clock) begin
    v_cmd <= {NVG{v_ord}};
    for (vg = 0; vg < NVG; vg = vg + 1)
        case (v_cmd[3*vg +: 3])
            3'd1: v[vg*VG +: VG] <= v_xi[vg*VG +: VG];
            3'd2: v[vg*VG +: VG] <= v_xq[vg*VG +: VG];
            3'd3: v[vg*VG +: VG] <= res[vg*VG +: VG];
            3'd4: v[vg*VG +: VG] <= v_sh[vg*VG +: VG];
            default: ;
        endcase
end

always @(posedge clock) begin
    out_strobe <= 1'b0;
    if (rst) begin
        st    <= S_IDLE;
        cnt   <= 4'd0;
        out_i <= {WIDTH{1'b0}};
        out_q <= {WIDTH{1'b0}};
    end else case (st)
        S_IDLE: if (byp) begin                                 // pass-through: the sequence never starts
            out_strobe <= in_strobe;
            if (in_strobe) begin
                out_i <= in_i;
                out_q <= in_q;
            end
        end else if (in_strobe) begin
            dec_r <= ((cnt & mask) == mask);
            cnt   <= ((cnt & mask) == mask) ? 4'd0 : cnt + 4'd1;
            ch    <= 1'b0;
            kind  <= 1'b0;
            s     <= {SW{1'b0}};
            ph    <= 2'd0;
            st    <= S_OP;
        end
        S_OP: begin
            ph <= ph + 2'd1;
            case (ph)
                2'd0: m  <= kind ? {mc_h[a], mc_l[a]} : {mi_h[a], mi_l[a]};
                2'd1: lo <= lo_w;
                2'd2: hi <= hi_w[HW:1];
                default: begin
                    if (s != STAGES - 1) begin
                        s <= s + 1'b1;
                    end else begin
                        s <= {SW{1'b0}};
                        if (!kind && dec_r) begin
                            kind <= 1'b1;                      // the combs go on from the last integrator
                        end else if (kind) begin
                            shc <= shamt;
                            st  <= S_SHIFT;
                        end else if (!ch) begin
                            ch <= 1'b1;                        // no output this time: the other channel
                        end else begin
                            st <= S_IDLE;
                        end
                    end
                end
            endcase
        end
        S_SHIFT: begin
            if (shc != 6'd0) begin
                shc <= shc - 6'd1;
            end else begin
                st <= S_RNDA;
            end
        end
        S_RNDA: begin                                          // v[WIDTH:0] = {word, rounding bit}
            zf  <= ~|v[ACC-1:WIDTH];
            of  <=  &v[ACC-1:WIDTH];
            sg  <= v[ACC-1];
            r17 <= $signed({v[WIDTH], v[WIDTH:1]}) + $signed({1'b0, v[0]});
            st  <= S_RNDB;
        end
        S_RNDB: begin
            if (!ch) begin
                oi   <= rnd;
                ch   <= 1'b1;
                kind <= 1'b0;
                s    <= {SW{1'b0}};
                ph   <= 2'd0;
                st   <= S_OP;
            end else begin
                out_i      <= oi;
                out_q      <= rnd;
                out_strobe <= 1'b1;
                st         <= S_IDLE;
            end
        end
        default: st <= S_IDLE;
    endcase
end

endmodule
