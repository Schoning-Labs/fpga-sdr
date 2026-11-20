// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// fir_decim: the last filter of a receiver, a 65-tap FIR low-pass filter that also keeps only
// every fourth output (decimation by 4). Its input is the 16-bit complex stream from the shared
// variable CIC (cic_var_shared.v) at 4 times the receiver's final rate, and its output is the
// 24-bit complex stream that rx_bank.v puts on the shared output bus, at 48, 96, 192 or
// 384 ksps (of Hermes-Lite 2 time). Terms such as FIR, tap and decimation are explained in
// docs/learn/GLOSSARY.md.
//
// What the filter is for: the CIC in front of it removes most of what would alias, but it
// leaves a droop across the passband and a wide, soft transition band. This FIR (designed with
// the Parks-McClellan method by tools/gen_fir_coeffs.py, coefficients in rtl/rx/fir_coeffs.hex)
// has a passband edge at 0.06 cycles per input sample and a stopband edge at 0.19, so the
// usable bandwidth is about +/-48 percent of half the output rate (for example +/-11.5 kHz at
// 48 ksps) and everything that would fold into that band when the rate drops by 4 is held down
// by about 99 dB. The coefficients are 20-bit signed numbers with 19 fraction bits and add up
// to almost exactly 1.0, so the filter has unity gain at DC and the output counts are on the
// same scale as the input counts; the extra bits of the 24-bit output are headroom.
//
// The numbers for one pass: a new output needs 65 taps of I and 65 taps of Q. The FIR input
// arrives at most once per 50 valid ADC samples (the fastest setting is 10 x 5 samples per FIR
// input), so there are at least 50 clocks between inputs and 4 inputs per output, which is
// at least 200 clocks per output. One multiplier is therefore enough: it is time-shared across
// all 65 taps and both channels, 130 multiply-accumulate steps per output.
//
// The delay line is a circular buffer in memory (one word per past input, I and Q packed into
// one 32-bit word because they are always written and read together) and not a shift register.
// A write needs no copy of the line and the read port is separate, so the memory is a simple
// dual-port RAM with one write port (the live sample stream) and one read port (the multiply
// sequencer). The memory itself is in fir_delay_ram2.v, where two receivers share one block;
// this module only drives the ports. A memory read has one clock of latency, and so the
// address generation runs ahead of the multiply-accumulate it feeds.
//
// Why the ring is deeper than the number of taps (RING_DEPTH = 128 for 65 taps): a pass reads
// all taps twice (I then Q), 2 x 65 + 1 cycles from end to end, and a live write can land at any
// point of that window. In a ring exactly 65 deep one such write would advance the write pointer
// onto the cell of the oldest tap (tap 64, which the Q pass reads last of all) and spoil it
// before it was read. With 128 cells the oldest tap is 63 slots further away from the write
// pointer, and at most 3 new inputs can arrive inside one pass (one per 50 clocks over about
// 130), so the collision cannot happen. A power of two also makes the pointer wrap by plain
// truncation, with no compare and subtract.
//
// Reset: while rst is high (a receiver that is switched off is held in reset) the memory is
// cleared by sweeping an address counter and writing zeros. A power-up reset that is too short
// for the sweep is covered by the memory's own initial zeroing, and a disable that lasts
// thousands of clocks leaves the whole ring zero before it is enabled again.
//
// The pipeline of one multiply-accumulate pass (every stage is one short step per clock, so the
// filter closes timing at the DSP clock rate):
//   clock 0  step counter (tap0, qph0): tap 0..64 for I, then again for Q
//   clock 1  ram_raddr = base_ptr - tap (registered); tap, phase and the flags registered
//   clock 2  block RAM read; coefficient ROM read
//   clock 3  I/Q selection of the word, coefficient registered
//   clock 4  rx_mac (a MULTALU27X18 DSP block): input register, product register, and the sum with
//            the previous result inside the block, output register; its result is valid 3 clocks
//            after the operands
// The running sum starts from PRELOAD = 2^(SHIFT-1), which is one half of an output LSB, instead
// of from 0: the block loads it whenever its accumulate-select input is 0 (the first tap of I
// and of Q), so the rounded output is a plain bit slice and no 44-bit adder is needed. The I sum
// is held in a register (iacc) until the Q sum is ready.
// Latency from start_mac to out_strobe: 2 x TAPS + 7 clocks (137), the same for every receiver
// (so the order in which different receivers reach the output arbiter does not depend on the
// receiver). Reset reaches the registers 2 clocks after it reaches the module (rx_fan).
//
// Gowin specific: `GOWIN_DSP` (defined by the Gowin builds) instantiates the DSP block; without
// it rx_mac is a model with the same register stages, which is what every simulation uses. The
// 20-bit coefficient goes on the 27-bit port and the 16-bit sample on the 18-bit port. The
// coefficient ROM is forced into LUTs.

// ---------------------------------------------------------------------------------------------
// rx_mac: p = acc ? (p + a*b) : (PRELOAD + a*b), one product per clock, result 3 clocks after
// the operands. This wraps one multiply-accumulate DSP block (the gain of using a block's own
// accumulator is that the add happens inside the block, at its full clock rate).
// ---------------------------------------------------------------------------------------------
module rx_mac #(
  parameter [47:0] PRELOAD = 48'd0       // value the sum starts from when acc is 0
)(
  input                     clock,
  input  signed [26:0]      a,           // first operand (here the coefficient, sign extended)
  input  signed [17:0]      b,           // second operand (here the sample, sign extended)
  input                     acc,   // 1: add to the previous result, 0: start from PRELOAD
  output signed [47:0]      p            // running sum, 3 clocks behind a and b
);
`ifdef GOWIN_DSP
  // Block configuration: input registers on A and B, a register on the accumulate select, the
  // product register and the output register all clocked by CLK0; every other register is
  // bypassed and every other dynamic select is tied off. Only ACCSEL is dynamic (acc), so the
  // block adds to its own previous output when acc is 1 and to the PRE_LOAD constant when 0.
  wire [47:0] caso;
  wire [26:0] soa;
  MULTALU27X18 #(
    .AREG_CLK("CLK0"), .AREG_CE("CE0"), .AREG_RESET("RESET0"),
    .BREG_CLK("CLK0"), .BREG_CE("CE0"), .BREG_RESET("RESET0"),
    .DREG_CLK("BYPASS"), .DREG_CE("CE0"), .DREG_RESET("RESET0"),
    .C_IREG_CLK("BYPASS"), .C_IREG_CE("CE0"), .C_IREG_RESET("RESET0"),
    .PSEL_IREG_CLK("BYPASS"), .PSEL_IREG_CE("CE0"), .PSEL_IREG_RESET("RESET0"),
    .PADDSUB_IREG_CLK("BYPASS"), .PADDSUB_IREG_CE("CE0"), .PADDSUB_IREG_RESET("RESET0"),
    .ADDSUB0_IREG_CLK("BYPASS"), .ADDSUB0_IREG_CE("CE0"), .ADDSUB0_IREG_RESET("RESET0"),
    .ADDSUB1_IREG_CLK("BYPASS"), .ADDSUB1_IREG_CE("CE0"), .ADDSUB1_IREG_RESET("RESET0"),
    .CSEL_IREG_CLK("BYPASS"), .CSEL_IREG_CE("CE0"), .CSEL_IREG_RESET("RESET0"),
    .CASISEL_IREG_CLK("BYPASS"), .CASISEL_IREG_CE("CE0"), .CASISEL_IREG_RESET("RESET0"),
    .ACCSEL_IREG_CLK("CLK0"), .ACCSEL_IREG_CE("CE0"), .ACCSEL_IREG_RESET("RESET0"),
    .PREG_CLK("CLK0"), .PREG_CE("CE0"), .PREG_RESET("RESET0"),
    .ADDSUB0_PREG_CLK("BYPASS"), .ADDSUB0_PREG_CE("CE0"), .ADDSUB0_PREG_RESET("RESET0"),
    .ADDSUB1_PREG_CLK("BYPASS"), .ADDSUB1_PREG_CE("CE0"), .ADDSUB1_PREG_RESET("RESET0"),
    .CSEL_PREG_CLK("BYPASS"), .CSEL_PREG_CE("CE0"), .CSEL_PREG_RESET("RESET0"),
    .CASISEL_PREG_CLK("BYPASS"), .CASISEL_PREG_CE("CE0"), .CASISEL_PREG_RESET("RESET0"),
    .ACCSEL_PREG_CLK("CLK0"), .ACCSEL_PREG_CE("CE0"), .ACCSEL_PREG_RESET("RESET0"),
    .C_PREG_CLK("BYPASS"), .C_PREG_CE("CE0"), .C_PREG_RESET("RESET0"),
    .FB_PREG_EN("FALSE"), .SOA_PREG_EN("FALSE"),
    .OREG_CLK("CLK0"), .OREG_CE("CE0"), .OREG_RESET("RESET0"),
    .MULT_RESET_MODE("SYNC"), .PRE_LOAD(PRELOAD),
    .DYN_P_SEL("FALSE"), .P_SEL(1'b0), .DYN_P_ADDSUB("FALSE"), .P_ADDSUB(1'b0),
    .DYN_A_SEL("FALSE"), .A_SEL(1'b0),
    .DYN_ADD_SUB_0("FALSE"), .ADD_SUB_0(1'b0), .DYN_ADD_SUB_1("FALSE"), .ADD_SUB_1(1'b0),
    .DYN_C_SEL("FALSE"), .C_SEL(1'b0),
    .DYN_CASI_SEL("FALSE"), .CASI_SEL(1'b0),
    .DYN_ACC_SEL("TRUE"), .ACC_SEL(1'b0), .MULT12X12_EN("FALSE")
  ) u (
    .DOUT(p), .CASO(caso), .SOA(soa), .A(a), .B(b), .C(48'd0), .D(26'd0), .SIA(27'd0), .CASI(48'd0),
    .PSEL(1'b0), .ASEL(1'b0), .CSEL(1'b0), .CASISEL(1'b0), .PADDSUB(1'b0), .ACCSEL(acc),
    .ADDSUB(2'b00), .CLK({1'b0, clock}), .CE(2'b01), .RESET(2'b00)
  );
`else
  // Simulation model of the same block: operand registers (ar, br), the accumulate flag delayed
  // twice (s0, s1) to line up with the product register (mr), then the output register o which
  // adds the product to either its own old value or PRELOAD.
  reg signed [26:0] ar = 27'sd0;
  reg signed [17:0] br = 18'sd0;
  reg signed [44:0] mr = 45'sd0;
  reg               s0 = 1'b0, s1 = 1'b0;
  reg signed [47:0] o  = 48'sd0;
  wire signed [47:0] ld = s1 ? o : PRELOAD;
  always @(posedge clock) begin
    ar <= a;
    br <= b;
    s0 <= acc;
    mr <= ar * br;
    s1 <= s0;
    o  <= ld + {{3{mr[44]}}, mr};
  end
  assign p = o;
`endif
endmodule

module fir_decim #(
  parameter TAPS         = 65,         // filter length, odd, symmetric coefficients
  parameter DECIM        = 4,          // keep one output for every DECIM inputs
  parameter IN_WIDTH     = 16,         // bits of one input sample (I or Q)
  parameter COEFF_WIDTH  = 20,         // bits of one coefficient, signed, COEFF_WIDTH-1 fraction bits
  parameter OUT_WIDTH    = 24,         // bits of one output sample (I or Q)
  parameter COEFF_FILE   = "fir_coeffs.hex",   // one coefficient per line in hexadecimal, read at start-up
  parameter RING_DEPTH   = 128 // TAPS=65 plus margin, see the module header
)(
  input                         clock,       // DSP clock
  input                         rst,         // synchronous reset, held while the receiver is disabled
  input                         in_strobe,   // one-clock pulse per input sample (from the shared CIC)
  input  signed [IN_WIDTH-1:0]  in_i,        // input I, held around in_strobe
  input  signed [IN_WIDTH-1:0]  in_q,        // input Q, held around in_strobe
  output reg                    out_strobe,  // one-clock pulse when a new output pair is ready
  output reg signed [OUT_WIDTH-1:0] out_i,   // output I, unity DC gain, valid from out_strobe until the next pass
  output reg signed [OUT_WIDTH-1:0] out_q,   // output Q

  // circular delay-line memory port: driven here, the memory itself lives in fir_delay_ram2.v so
  // two receivers can share one physical block. One write
  // (live sample stream, plus the reset-time clearing sweep) and one synchronous read (the MAC
  // sequencer), exactly a simple dual-port memory's two ports.
  output                        ram_wr,      // write enable of the delay line
  output     [$clog2(RING_DEPTH)-1:0] ram_waddr,   // write address (ring slot)
  output     [2*IN_WIDTH-1:0]   ram_wdata,   // word written, {I, Q}
  output     [$clog2(RING_DEPTH)-1:0] ram_raddr,   // read address (ring slot)
  input      [2*IN_WIDTH-1:0]   ram_rdata    // word read, {I, Q}, one clock after ram_raddr
) /* synthesis syn_maxfan = 10000 syn_srlstyle = "registers" */;

localparam integer PROD_WIDTH  = IN_WIDTH + COEFF_WIDTH;   // 36 bits: one sample times one coefficient
localparam integer ACC_WIDTH   = PROD_WIDTH + 8; // headroom for TAPS accumulation
localparam integer RAW         = $clog2(RING_DEPTH);       // bits of a ring address
localparam integer TW          = (($clog2(TAPS) > RAW) ? $clog2(TAPS) : RAW); // tap counter width
localparam integer WORD_W      = 2*IN_WIDTH; // packed {i, q}
// output scaling: coefficients are Q(COEFF_WIDTH-1) fixed point (unity gain passband sums to
// approximately 2^(COEFF_WIDTH-1)-1), so shift back down by COEFF_WIDTH-1 bits and round.
localparam integer SHIFT       = COEFF_WIDTH - 1;
localparam [47:0]  ROUND       = 48'd1 << (SHIFT-1);

// ---------------------------------------------------------------------
// reset copies: 4 for the write port registers, 5 for the control registers (<= 14 loads each)
// ---------------------------------------------------------------------
wire [8:0] rf;
rx_fan #(.N(9), .PER(10), .INIT(1'b1)) u_rstfan (.clock(clock), .d(rst), .q(rf));

// ---------------------------------------------------------------------
// coefficient ROM (shared by both channels, both are the same real filter)
// ---------------------------------------------------------------------
// Forced into LUTs by the ROM style attribute. Left alone, Gowin builds a 128 x 32 block-RAM ROM
// for these 65 x 20 bits, which costs 2 blocks per receiver (16 for a bank of 8), while the same
// table in LUTs can be read in the same clock.
(* syn_romstyle = "distributed_rom" *) reg signed [COEFF_WIDTH-1:0] coeff [0:TAPS-1];
initial $readmemh(COEFF_FILE, coeff);

// ---------------------------------------------------------------------
// circular delay-line memory control: a write pointer that advances by one every in_strobe and
// wraps mod RING_DEPTH (a power of two, see the module header for why RING_DEPTH is deeper
// than TAPS). The memory array itself is external (see ram_* ports above and fir_delay_ram2.v).
// ---------------------------------------------------------------------
reg [RAW-1:0] wr_ptr   = {RAW{1'b0}};
reg [RAW-1:0] clr_addr = {RAW{1'b0}}; // swept while rst is held; see the module header
reg           clr_wr   = 1'b0;        // this cycle's reset-sweep write, one cycle behind rst
reg [RAW-1:0] clr_wr_addr = {RAW{1'b0}};

reg [1:0] dcnt      = 2'd0;           // counts inputs 0..DECIM-1; the last one starts a multiply pass
reg       start_mac = 1'b0;           // one-clock pulse: the newest input is the one that starts a pass
reg [RAW-1:0] base_ptr = {RAW{1'b0}}; // wr_ptr's value at the write this MAC sequence's tap 0 corresponds to

reg           live_wr    = 1'b0;      // a live sample is written this clock (one clock after in_strobe)
reg [RAW-1:0] live_waddr = {RAW{1'b0}};
reg [WORD_W-1:0] live_wdata = {WORD_W{1'b0}};

// registered write port; the reset copies pick the reset-sweep write
// While reset is high the port writes zeros at the sweep address, otherwise it forwards the
// live write. The data is cleared in three slices so each reset copy has a few loads.
reg              w_wr    = 1'b0;
reg [RAW-1:0]    w_addr  = {RAW{1'b0}};
reg [WORD_W-1:0] w_data  = {WORD_W{1'b0}};
always @(posedge clock) begin
  w_wr   <= rf[5] ? clr_wr : live_wr;
  w_addr <= rf[5] ? clr_wr_addr : live_waddr;
  w_data[10:0]  <= rf[6] ? 11'd0 : live_wdata[10:0];
  w_data[21:11] <= rf[7] ? 11'd0 : live_wdata[21:11];
  w_data[WORD_W-1:22] <= rf[8] ? {(WORD_W-22){1'b0}} : live_wdata[WORD_W-1:22];
end
assign ram_wr    = w_wr;
assign ram_waddr = w_addr;
assign ram_wdata = w_data;

// write pointer, decimation counter, start of a pass (control copies rf[0..2])
// Every accepted input is written to the ring and advances the pointer. Every DECIM-th input
// also starts a multiply pass (start_mac), because that is when an output is due.
always @(posedge clock) begin
  if (rf[0]) begin
    dcnt        <= 2'd0;
    start_mac   <= 1'b0;
    wr_ptr      <= {RAW{1'b0}};
    clr_wr      <= 1'b1; // address-sweeping clear; see the module header
    live_wr     <= 1'b0;
  end else begin
    start_mac <= 1'b0;
    clr_wr    <= 1'b0;
    live_wr   <= 1'b0;
    if (in_strobe) begin
      live_wr    <= 1'b1;
      wr_ptr <= wr_ptr + 1'b1; // RING_DEPTH is a power of two: plain overflow wraps correctly
      if (dcnt == DECIM-1) begin
        dcnt      <= 2'd0;
        start_mac <= 1'b1;
      end else begin
        dcnt <= dcnt + 2'd1;
      end
    end
  end
end
// the word and its address are registered every clock (no enable: they are used only in the clock
// live_wr is set, one clock after in_strobe, and in_i/in_q hold their value around the strobe)
always @(posedge clock) begin
  live_waddr <= wr_ptr;
  live_wdata <= {in_i, in_q};
end
// base_ptr remembers where the newest sample of the current pass went; the taps are read
// backwards from there. The clear address advances every clock while reset is high and is
// registered once more before it reaches the write port.
always @(posedge clock) begin
  if (rf[1]) begin
    base_ptr <= {RAW{1'b0}};
    clr_addr <= clr_addr + 1'b1;
  end else if (in_strobe && dcnt == DECIM-1) begin
    base_ptr <= wr_ptr; // the address just written above, "tap 0" for this sequence
  end
  if (rf[2]) clr_wr_addr <= clr_addr;
end

// ---------------------------------------------------------------------
// clock 0: step counter, I channel (qph0 = 0) then Q channel, TAPS taps each
// ---------------------------------------------------------------------
// run0 is high while a pass is going on, qph0 says which channel is being read, and tap0 is the
// tap number (0 is the newest sample).
reg          run0 = 1'b0;
reg          qph0 = 1'b0;
reg [TW-1:0] tap0 = {TW{1'b0}};
wire         tap0_last = (tap0 == TAPS-1);
wire         tap0_zero = (tap0 == 0);
always @(posedge clock) begin
  if (rf[3]) begin
    run0 <= 1'b0;
    qph0 <= 1'b0;
    tap0 <= {TW{1'b0}};
  end else if (start_mac) begin
    run0 <= 1'b1;
    qph0 <= 1'b0;
    tap0 <= {TW{1'b0}};
  end else if (run0) begin
    if (tap0_last) begin
      tap0 <= {TW{1'b0}};
      qph0 <= 1'b1;
      if (qph0) run0 <= 1'b0;
    end else begin
      tap0 <= tap0 + 1'b1;
    end
  end
end

// ---------------------------------------------------------------------
// clock 1: read address (registered, goes straight to the block RAM), tap index, flags
// ---------------------------------------------------------------------
// The read address is the newest slot minus the tap number, which walks backwards through the
// ring (wrapping by truncation). The tap number, the channel and the "first tap" flag are
// carried along to meet the data when it comes back.
reg [RAW-1:0] raddr1 = {RAW{1'b0}};
reg [TW-1:0]  tap1   = {TW{1'b0}};
reg           qph1 = 1'b0, first1 = 1'b0, il1 = 1'b0, ql1 = 1'b0;
wire [RAW-1:0] tap0_r = tap0;
always @(posedge clock) begin
  raddr1 <= base_ptr - tap0_r; // power-of-two ring: wraps by truncation
  tap1   <= tap0;
  qph1   <= qph0;
  first1 <= tap0_zero;
end
assign ram_raddr = raddr1;

// flags (reset: a pass cut off by a reset must not produce an output word)
// il* marks the last tap of the I pass and ql* the last tap of the Q pass; they travel down a
// delay line that matches the depth of the multiply pipeline. ilA and qlA are the moment the
// last product of that pass enters the block, and qlC, one more step on, becomes out_strobe.
reg il2 = 1'b0, ql2 = 1'b0, il3 = 1'b0, ql3 = 1'b0, ilA = 1'b0, qlA = 1'b0;
reg qlB = 1'b0, qlC = 1'b0;
always @(posedge clock) begin
  if (rf[4]) begin
    il1 <= 1'b0; ql1 <= 1'b0; il2 <= 1'b0; ql2 <= 1'b0; il3 <= 1'b0; ql3 <= 1'b0;
    ilA <= 1'b0; qlA <= 1'b0; qlB <= 1'b0; qlC <= 1'b0;
    out_strobe <= 1'b0;
  end else begin
    il1 <= run0 & ~qph0 & tap0_last;
    ql1 <= run0 &  qph0 & tap0_last;
    il2 <= il1; ql2 <= ql1;
    il3 <= il2; ql3 <= ql2;
    ilA <= il3; qlA <= ql3;
    qlB <= qlA; qlC <= qlB;
    out_strobe <= qlC;
  end
end

// ---------------------------------------------------------------------
// clock 2: coefficient ROM read (the block RAM read of ram_rdata happens in the same clock)
// ---------------------------------------------------------------------
reg signed [COEFF_WIDTH-1:0] coef2 = {COEFF_WIDTH{1'b0}};
reg qph2 = 1'b0, first2 = 1'b0;
always @(posedge clock) begin
  coef2  <= coeff[tap1];
  qph2   <= qph1;
  first2 <= first1;
end

// ---------------------------------------------------------------------
// clock 3: choose I or Q of the word read; operands of the multiply-accumulate block
// ---------------------------------------------------------------------
// The memory word is {I, Q}, so the upper half is I and the lower half is Q. Both operands are
// sign extended to the block's port widths, and acc is low on the first tap of each channel so
// that the sum restarts from the rounding constant.
reg signed [IN_WIDTH-1:0]    mdat3  = {IN_WIDTH{1'b0}};
reg signed [COEFF_WIDTH-1:0] coef3  = {COEFF_WIDTH{1'b0}};
reg                          first3 = 1'b0;
always @(posedge clock) begin
  mdat3  <= qph2 ? ram_rdata[IN_WIDTH-1:0] : ram_rdata[WORD_W-1:IN_WIDTH];
  coef3  <= coef2;
  first3 <= first2;
end

wire signed [47:0] pmac;
rx_mac #(.PRELOAD(ROUND)) u_mac (
  .clock(clock),
  .a({{(27-COEFF_WIDTH){coef3[COEFF_WIDTH-1]}}, coef3}),
  .b({{(18-IN_WIDTH){mdat3[IN_WIDTH-1]}}, mdat3}),
  .acc(~first3),
  .p(pmac)
);

// ---------------------------------------------------------------------
// result: the I sum is kept when its last tap arrives, the Q sum together with it is the output
// pair. Enables are kept copies (rx_fan), loaded 2 clocks ahead from the flag chain (ilA, qlA).
// ---------------------------------------------------------------------
// The output word is the sum shifted down by SHIFT bits (the coefficient fraction), which is
// a plain slice of the accumulator because the rounding constant was added at the start.
wire [2:0] ei;   // I-sum capture, 24 bits
wire [4:0] eq;   // output registers, 48 bits
rx_fan #(.N(3), .PER(10)) u_efi (.clock(clock), .d(ilA), .q(ei));
rx_fan #(.N(5), .PER(10)) u_efq (.clock(clock), .d(qlA), .q(eq));

reg signed [OUT_WIDTH-1:0] iacc = {OUT_WIDTH{1'b0}};
wire [OUT_WIDTH-1:0] p_slice = pmac[SHIFT +: OUT_WIDTH];
always @(posedge clock) begin
  if (ei[0]) iacc[7:0]   <= p_slice[7:0];
  if (ei[1]) iacc[15:8]  <= p_slice[15:8];
  if (ei[2]) iacc[OUT_WIDTH-1:16] <= p_slice[OUT_WIDTH-1:16];
  if (eq[0]) out_i[9:0]  <= iacc[9:0];
  if (eq[1]) out_i[19:10] <= iacc[19:10];
  if (eq[2]) begin out_i[OUT_WIDTH-1:20] <= iacc[OUT_WIDTH-1:20]; out_q[5:0] <= p_slice[5:0]; end
  if (eq[3]) out_q[15:6] <= p_slice[15:6];
  if (eq[4]) out_q[OUT_WIDTH-1:16] <= p_slice[OUT_WIDTH-1:16];
end

// full-precision sums (before rounding), for the alias tests only: nothing in the design reads them,
// synthesis drops them. Valid from the output strobe until the next pass.
reg signed [ACC_WIDTH-1:0] hi_i = {ACC_WIDTH{1'b0}};
reg signed [ACC_WIDTH-1:0] hi_q = {ACC_WIDTH{1'b0}};
always @(posedge clock) begin
  if (ei[0]) hi_i <= pmac[ACC_WIDTH-1:0] - ROUND[ACC_WIDTH-1:0];
  if (eq[0]) hi_q <= pmac[ACC_WIDTH-1:0] - ROUND[ACC_WIDTH-1:0];
end

endmodule
