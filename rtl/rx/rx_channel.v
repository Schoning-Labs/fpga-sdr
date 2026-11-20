// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// rx_channel: the first half of one receiver, from the raw ADC word down to a 16-bit complex
// stream at 7.68 Msps. It holds the numerically controlled oscillator mixer (nco_mixer.v), which
// moves the wanted frequency down to zero, and a fixed decimate-by-10 CIC filter (rx_cic_fixed,
// defined at the top of this file), which throws away nine of every ten samples after filtering
// away whatever would fold back onto the wanted signal.
//
// Where it sits: rx_bank.v instantiates one rx_channel per receiver, all of them looking at the
// same ADC samples. Each channel is tuned independently by its own phase increment. Its output
// goes on to the shared variable CIC (cic_var_shared.v) and then to the compensating FIR
// (fir_decim.v), which both live in rx_bank.v because several receivers share them. The terms
// used below (mixer, NCO, decimation, CIC) are explained in docs/learn/GLOSSARY.md.
//
// How the channel works, step by step:
//   1. The 12-bit ADC sample (76.8 million of them per second of Hermes-Lite 2 time) is
//      multiplied by the complex number e^(j t), where t is the NCO phase. Tuning is done by
//      choosing how fast t advances per sample (the phase increment). A signal at exactly the
//      tuned frequency becomes a constant, and signals nearby become slow oscillations around it.
//      The output of this step is two 18-bit streams, I (real part) and Q (imaginary part), at
//      the full input rate. The mixer has a fixed gain of 52.696 (so 12 bits in, 18 bits out).
//   2. Each of I and Q goes through a three-stage CIC decimator with a decimation factor of 10,
//      so the rate drops from 76.8 Msps to 7.68 Msps. Three stages of a decimate-by-10 CIC grow
//      the word by ceil(3 x log2(10)) = 10 bits, so the 28-bit sums inside are rounded back to 16
//      bits at the output. The gain of the filter is 10^3 = 1,000 and the 12 bits that are
//      dropped divide by 4,096, which leaves a DC gain of about 0.244. A full scale ADC tone
//      therefore arrives as roughly 26,000 counts of the 32,767 a 16-bit word can hold.
//
// The whole channel is only ever clocked by the DSP clock (120 MHz). The ADC samples arrive as
// a stream qualified by adc_valid (one pulse per sample, on average one clock in two, sometimes
// several in a row), so every register in the chain advances only when its own strobe is high
// and the decimation counts valid samples, not clocks.
//
// Latency from adc_valid to cic1_strobe: the nco_mixer's own latency of 7 accepted samples plus
// 3 clocks for the input register and for the two clocks that the fan-out copies of the CIC
// controls need.
//
// Fan-out: at this clock rate a control signal that drives hundreds of registers is too slow
// to route, so every reset and enable here is built as several registers that each carry at
// most ten loads (rx_fan and rx_vreg, defined in cic_var_shared.v). Nothing about the arithmetic
// changes because of that; it only adds the fixed clocks of latency listed above.
//
// Gowin specific: the multiplies sit in the nco_mixer (4 DSP blocks per channel and one block
// RAM for its sine table). The CIC stages are plain adders on the carry chains and use no DSP.

// ---------------------------------------------------------------------------------------------
// rx_cic_fixed: a Hogenauer CIC decimator (decimate by DECIM, STAGES integrators and STAGES
// combs) whose resets and enables are kept copies of at most 10 loads each (see rx_fan and
// rx_vreg in cic_var_shared.v). A CIC filter is a boxcar average of DECIM samples applied STAGES
// times over, and it is built without a single multiplier: a chain of integrators (running
// sums) runs at the input rate, then only every DECIM-th result is kept, and a chain of combs
// (differences between this result and the previous one) runs at the lower output rate. The
// integrators overflow on purpose (they are two's complement and only the difference of two
// readings matters), which works as long as the accumulator is wide enough for the real
// output, ACC_WIDTH = IN_WIDTH + ceil(STAGES x log2(DECIM)).
//
// The control and the arithmetic follow the same structure as the usual one-block CIC, but the
// pipeline is spread out so that the copies can be loaded one clock ahead: the integrators
// update 2 clocks after in_strobe (the data is delayed by two registers), the combs 2 clocks
// after the internal out-strobe register, and out_strobe itself leaves 2 clocks later than that.
// The comb result that a consumer reads at out_strobe is the one from the previous decimation
// event, which is harmless because that value is stable for at least DECIM input samples.
// ---------------------------------------------------------------------------------------------
module rx_cic_fixed #(
  parameter STAGES    = 3,
  parameter DECIM     = 10,
  parameter IN_WIDTH  = 18,
  parameter ACC_WIDTH = 28,
  parameter OUT_WIDTH = 16
)(
  input                          clock,      // DSP clock
  input                          rst,        // synchronous reset, held high while the channel is disabled
  input                          in_strobe,  // one-clock pulse for every input sample that is valid
  input  signed [IN_WIDTH-1:0]   in_data,    // input sample, two's complement, held around in_strobe
  output                         out_strobe, // one-clock pulse for every DECIM-th input sample
  output signed [OUT_WIDTH-1:0]  out_data    // rounded output, valid from out_strobe until the next one
) /* synthesis syn_maxfan = 10000 syn_srlstyle = "registers" */;

localparam G  = 10;                       // loads per kept copy of a control signal
localparam NG = (ACC_WIDTH + G - 1) / G;  // copies needed to cover one accumulator word
localparam CW = $clog2(DECIM);            // width of the decimation counter

// Decimation counter: counts accepted input samples from 0 to DECIM-1 and raises ob (one clock)
// on the last one. The counter and ob move only on in_strobe, with the exception that ob falls
// to zero on the first clock without a strobe.
reg [CW-1:0] sample_no = {CW{1'b0}};
reg          ob        = 1'b0;
always @(posedge clock)
  if (rst) begin
    sample_no <= {CW{1'b0}};
    ob        <= 1'b0;
  end else if (in_strobe) begin
    if (sample_no == DECIM-1) begin
      sample_no <= {CW{1'b0}};
      ob        <= 1'b1;
    end else begin
      sample_no <= sample_no + 1'b1;
      ob        <= 1'b0;
    end
  end else
    ob <= 1'b0;

// Two more clocks of delay on the output strobe, so that it appears after the combs have
// finished their update (the combs run 2 clocks after ob).
reg ob_d1 = 1'b0, ob_d2 = 1'b0;
always @(posedge clock) begin
  ob_d1 <= ob;
  ob_d2 <= ob_d1;
end
assign out_strobe = ob_d2;

// Kept copies of the controls: three reset vectors per stage (integrator, comb output, comb
// memory), one enable for the integrators (in_strobe) and two for the combs (ob).
wire [3*STAGES*NG-1:0] rl;
wire [STAGES*NG-1:0]   ei;
wire [2*STAGES*NG-1:0] ec;
rx_fan #(.N(3*STAGES*NG), .PER(G), .INIT(1'b1)) f_rst (.clock(clock), .d(rst),       .q(rl));
rx_fan #(.N(STAGES*NG),   .PER(G))               f_ei  (.clock(clock), .d(in_strobe), .q(ei));
rx_fan #(.N(2*STAGES*NG), .PER(G))               f_ec  (.clock(clock), .d(ob),        .q(ec));

// The input data goes through two registers so that it meets its enable copies, which are two
// clocks late, and is then sign extended to the accumulator width.
reg [IN_WIDTH-1:0] din1 = {IN_WIDTH{1'b0}};
reg [IN_WIDTH-1:0] din2 = {IN_WIDTH{1'b0}};
always @(posedge clock) begin
  din1 <= in_data;
  din2 <= din1;
end
wire [ACC_WIDTH-1:0] din_ext = {{(ACC_WIDTH-IN_WIDTH){din2[IN_WIDTH-1]}}, din2};

// The filter itself, one generate block per stage.
//   integ_q[s]  integrator s (a running sum: new = old + the output of the stage before it)
//   cout_q[s]   comb s output (this reading of the stage before it minus the previous reading)
//   cprev_q[s]  the previous reading of the stage before comb s
// Stage 0 of the integrators is fed by the input and stage 0 of the combs by the last integrator.
wire [STAGES*ACC_WIDTH-1:0] integ_q, cout_q, cprev_q;
genvar gs;
generate
  for (gs = 0; gs < STAGES; gs = gs + 1) begin : stg
    wire [ACC_WIDTH-1:0] i_in;
    if (gs == 0) begin : i_first
      assign i_in = din_ext;
    end else begin : i_next
      assign i_in = integ_q[(gs-1)*ACC_WIDTH +: ACC_WIDTH];
    end
    wire [ACC_WIDTH-1:0] i_d = integ_q[gs*ACC_WIDTH +: ACC_WIDTH] + i_in;
    rx_vreg #(.W(ACC_WIDTH), .G(G)) v_int (
      .clock(clock), .rst(rl[gs*NG +: NG]), .en(ei[gs*NG +: NG]),
      .d(i_d), .q(integ_q[gs*ACC_WIDTH +: ACC_WIDTH]));

    wire [ACC_WIDTH-1:0] c_in;
    if (gs == 0) begin : c_first
      assign c_in = integ_q[(STAGES-1)*ACC_WIDTH +: ACC_WIDTH];
    end else begin : c_next
      assign c_in = cout_q[(gs-1)*ACC_WIDTH +: ACC_WIDTH];
    end
    wire [ACC_WIDTH-1:0] c_d = c_in - cprev_q[gs*ACC_WIDTH +: ACC_WIDTH];
    rx_vreg #(.W(ACC_WIDTH), .G(G)) v_out (
      .clock(clock), .rst(rl[(STAGES+gs)*NG +: NG]), .en(ec[gs*NG +: NG]),
      .d(c_d), .q(cout_q[gs*ACC_WIDTH +: ACC_WIDTH]));
    rx_vreg #(.W(ACC_WIDTH), .G(G)) v_prev (
      .clock(clock), .rst(rl[(2*STAGES+gs)*NG +: NG]), .en(ec[(STAGES+gs)*NG +: NG]),
      .d(c_in), .q(cprev_q[gs*ACC_WIDTH +: ACC_WIDTH]));
  end
endgenerate

// Output rounding: keep the top OUT_WIDTH bits of the last comb and add the bit just below them
// (which rounds half up). The result is registered every clock. It is only meaningful at
// out_strobe, but the last comb changes just once per decimation period (at least DECIM clocks
// apart), so the register is stable around the strobe.
wire [ACC_WIDTH-1:0] ctop = cout_q[(STAGES-1)*ACC_WIDTH +: ACC_WIDTH];
reg  [OUT_WIDTH-1:0] od = {OUT_WIDTH{1'b0}};
always @(posedge clock)
  od <= ctop[ACC_WIDTH-1 -: OUT_WIDTH] + {{(OUT_WIDTH-1){1'b0}}, ctop[ACC_WIDTH-OUT_WIDTH-1]};
assign out_data = od;

endmodule

// ---------------------------------------------------------------------------------------------
// rx_channel: mixer plus fixed CIC for one receiver (see the header of this file).
// ---------------------------------------------------------------------------------------------
module rx_channel #(
  parameter ADC_WIDTH = 12              // bits of one ADC sample, two's complement
)(
  input                       clock,       // DSP clock, 120 MHz
  input                       rst,         // synchronous reset
  input        [ADC_WIDTH-1:0] adc_data,   // raw ADC sample, two's complement, shared by all receivers
  input                       adc_valid,   // one-clock pulse per ADC sample (a sample of Hermes-Lite 2 time)

  input  signed [31:0]        phase_inc,   // NCO phase increment per sample: round(f_Hz / 76.8e6 x 2^32), signed
  input                       enable,      // 1: receiver runs, 0: the whole channel is held in reset

  output                      cic1_strobe, // one-clock pulse per output sample (7.68 Msps)
  output signed [15:0]        cic1_i,      // I (real part) after the CIC, DC gain about 0.244 of the ADC counts x 52.696
  output signed [15:0]        cic1_q,      // Q (imaginary part), same scale
  output [3:0]                chan_rst     // kept copies of the channel reset: [0] FIR, [1] shared CIC I context, [2] shared CIC Q context, [3] used inside this module only
) /* synthesis syn_maxfan = 10000 syn_srlstyle = "registers" */;

// ---------------------------------------------------------------------
// reset and input gating, registered (kept copies)
// ---------------------------------------------------------------------
// The whole channel is held in reset while it is disabled, and not only at power-up. The reason
// is that the mixer tracks which of its pipeline stages hold valid data in a shift register that
// moves only when a sample arrives, so a channel that is switched off in the middle of a
// stream would otherwise keep a stale "valid" bit forever. Holding the reset also guarantees that
// every re-enable (new frequency, new rate) starts from clean filters. rx_bank.v passes
// chan_rst on to the shared CIC engine and the shared FIR delay line, so a disabled receiver is
// cleared there too, exactly as if it had its own hardware.
// The reset, the strobe and the data word all go through one register each, so gating by enable
// and the reset change in the same clock.
reg [3:0] crst_q /* synthesis syn_preserve = 1 */;
reg                  v_q;
reg [ADC_WIDTH-1:0]  adc_q;
initial begin crst_q = 4'hF; v_q = 1'b0; adc_q = {ADC_WIDTH{1'b0}}; end
always @(posedge clock) begin
  crst_q <= {4{rst | ~enable}};
  v_q    <= adc_valid & enable;
  adc_q  <= adc_data;
end
assign chan_rst = crst_q;

// ---------------------------------------------------------------------
// stage 1: the NCO mixer. MODE 0 means a real input (the ADC) and a complex output. It uses the
// same gain, sign convention and 18-bit output width that the Hermes-Lite 2 receive mixer has, so
// every level further down the chain is the same as in that radio.
// ---------------------------------------------------------------------
wire                  mix_strobe;
wire signed [17:0]    mix_i, mix_q;

nco_mixer #(
  .MODE(0), .IN_WIDTH(ADC_WIDTH), .OUT_WIDTH(18)
) u_nco (
  .clock      (clock),
  .rst        (crst_q[3]),
  .in_strobe  (v_q),
  .frequency  (phase_inc),
  .in_i       (adc_q),
  .in_q       ({ADC_WIDTH{1'b0}}),
  .out_strobe (mix_strobe),
  .out_i      (mix_i),
  .out_q      (mix_q)
);

// ---------------------------------------------------------------------
// stage 2: fixed CIC, decimate by 10, three stages, one for I and one for Q.
// 18 bits in and 28 bits for the sums (18 + ceil(3 x log2(10)) = 18 + 10), 16 bits out.
// ---------------------------------------------------------------------
localparam CIC1_DECIM = 10;
localparam CIC1_STAGES = 3;
localparam CIC1_ACC_W = 18 + 10; // IN_WIDTH(18) + ceil(3*log2(10))=10

wire cic1_strobe_i, cic1_strobe_q;

rx_cic_fixed #(
  .STAGES(CIC1_STAGES), .DECIM(CIC1_DECIM),
  .IN_WIDTH(18), .ACC_WIDTH(CIC1_ACC_W), .OUT_WIDTH(16)
) u_cic1_i (
  .rst(crst_q[3]), .clock(clock),
  .in_strobe(mix_strobe), .out_strobe(cic1_strobe_i),
  .in_data(mix_i), .out_data(cic1_i)
);

rx_cic_fixed #(
  .STAGES(CIC1_STAGES), .DECIM(CIC1_DECIM),
  .IN_WIDTH(18), .ACC_WIDTH(CIC1_ACC_W), .OUT_WIDTH(16)
) u_cic1_q (
  .rst(crst_q[3]), .clock(clock),
  .in_strobe(mix_strobe), .out_strobe(cic1_strobe_q),
  .in_data(mix_q), .out_data(cic1_q)
);

// The I and Q strobes are always the same pulse, since both filters are fed by the same mixer
// strobe and count to 10 in step, so one of them is enough.
assign cic1_strobe = cic1_strobe_i;

endmodule
