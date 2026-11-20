// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Reference model of one complete receiver as it was before the receiver bank was rebalanced:
// an NCO mixer, a two stage CIC decimator and a compensating FIR decimator, all private to the
// receiver (docs/RX_DSP.md has the signal chain, the bit widths and the gain plan). The
// current rtl/rx/rx_channel.v stops after the fixed CIC and leaves the variable CIC and the
// FIR to the bank, which shares them between receivers. sim/rx/tb_rb3_compare.v runs the
// bank built from this module side by side with the current bank, and checks that both deliver the same
// output words in the same order. The module is called rx_channel_ref so that both can be
// compiled into one bench.
//
// Decimation plan (ADC clock 76.8 MHz, one adc_valid pulse per clock at full rate, and the
// whole receiver also works with a sparser adc_valid):
//   NCO mixer             : no decimation, 76.8 Msps in and out (shifts the tuned frequency to 0)
//   cic_fixed  (STAGES=3) : fixed decimate-by-10  -> 7.68 Msps
//   cic_var    (STAGES=5) : decimate-by-{40,20,10,5}, selected by rate_sel
//                            -> 192k/384k/768k/1536k sps (= 4 x out_rate)
//   fir_decim  (TAPS=65)  : fixed decimate-by-4   -> 48k/96k/192k/384k sps
// (CIC, FIR and the other terms are explained in docs/learn/GLOSSARY.md.)
//
// rate_sel: 2'd0 = 48 ksps, 2'd1 = 96 ksps, 2'd2 = 192 ksps, 2'd3 = 384 ksps.

module rx_channel_ref #(
  parameter ADC_WIDTH = 12,
  parameter FIR_COEFF_FILE = "fir_coeffs.hex"
)(
  input                       clock,       // 76.8 MHz ADC clock, everything runs here
  input                       rst,
  input        [ADC_WIDTH-1:0] adc_data,
  input                       adc_valid,

  input  signed [31:0]        phase_inc,   // NCO phase increment (frequency)
  input  [1:0]                rate_sel,    // 0=48k 1=96k 2=192k 3=384k
  input                       enable,

  output                      out_valid,
  output signed [23:0]        out_i,
  output signed [23:0]        out_q
);

// ---------------------------------------------------------------------
// Stage 1: the NCO mixer (the instance and signal names still say cordic, from the CORDIC mixer
// that the same stage used to be)
// ---------------------------------------------------------------------
wire                  cordic_strobe;
wire signed [17:0]    cordic_i, cordic_q;

wire adc_valid_gated = adc_valid & enable;

// The whole receiver is held in reset while it is disabled, and not only at power-up. The
// mixer's out_strobe pipeline and the decimation counters of the stages behind it would
// otherwise be left in a stale state when `enable` drops. The mixer's valid tracking moves only
// on in_strobe, which has just stopped, so an out_strobe that is high could never clear. Resetting
// while disabled makes every re-enable start clean.
wire chan_rst = rst | ~enable;

// The mixer is the same rtl/rx/nco_mixer.v that the current bank uses, so that the word for word
// comparison against the current bank checks only the later changes behind the mixer.
nco_mixer #(
  .MODE(0), .IN_WIDTH(ADC_WIDTH), .OUT_WIDTH(18)
) u_cordic (
  .clock      (clock),
  .rst        (chan_rst),
  .in_strobe  (adc_valid_gated),
  .frequency  (phase_inc),
  .in_i       (adc_data),
  .in_q       ({ADC_WIDTH{1'b0}}),
  .out_strobe (cordic_strobe),
  .out_i      (cordic_i),
  .out_q      (cordic_q)
);

// ---------------------------------------------------------------------
// Stage 2: fixed CIC, decimate by 10, STAGES = 3, one for I and one for Q. The accumulator needs
// IN_WIDTH + ceil(STAGES x log2(DECIMATION)) = 18 + 10 = 28 bits.
// ---------------------------------------------------------------------
localparam CIC1_DECIM = 10;
localparam CIC1_STAGES = 3;
localparam CIC1_ACC_W = 18 + 10; // IN_WIDTH(18) + ceil(3*log2(10))=10

wire cic1_strobe_i, cic1_strobe_q;
wire signed [15:0] cic1_i, cic1_q;

cic_fixed_ref #(
  .STAGES(CIC1_STAGES), .DECIMATION(CIC1_DECIM),
  .IN_WIDTH(18), .ACC_WIDTH(CIC1_ACC_W), .OUT_WIDTH(16)
) u_cic1_i (
  .rst_all(chan_rst), .clock(clock),
  .in_strobe(cordic_strobe), .out_strobe(cic1_strobe_i),
  .in_data(cordic_i), .out_data(cic1_i)
);

cic_fixed_ref #(
  .STAGES(CIC1_STAGES), .DECIMATION(CIC1_DECIM),
  .IN_WIDTH(18), .ACC_WIDTH(CIC1_ACC_W), .OUT_WIDTH(16)
) u_cic1_q (
  .rst_all(chan_rst), .clock(clock),
  .in_strobe(cordic_strobe), .out_strobe(cic1_strobe_q),
  .in_data(cordic_q), .out_data(cic1_q)
);

// ---------------------------------------------------------------------
// Stage 3: variable CIC, decimate by {40, 20, 10, 5}, STAGES = 5, one for I and one for Q
// ---------------------------------------------------------------------
reg [5:0] cic2_decim;
always @(*) begin
  case (rate_sel)
    2'd0: cic2_decim = 6'd40; // 48 ksps
    2'd1: cic2_decim = 6'd20; // 96 ksps
    2'd2: cic2_decim = 6'd10; // 192 ksps
    default: cic2_decim = 6'd5; // 384 ksps
  endcase
end

wire cic2_strobe_i, cic2_strobe_q;
wire signed [15:0] cic2_i, cic2_q;

cic_var_ref #(
  .STAGES(5), .IN_WIDTH(16), .ACC_WIDTH(43), .OUT_WIDTH(16)
) u_cic2_i (
  .rst_all(chan_rst), .decimation(cic2_decim), .clock(clock),
  .in_strobe(cic1_strobe_i), .out_strobe(cic2_strobe_i),
  .in_data(cic1_i), .out_data(cic2_i)
);

cic_var_ref #(
  .STAGES(5), .IN_WIDTH(16), .ACC_WIDTH(43), .OUT_WIDTH(16)
) u_cic2_q (
  .rst_all(chan_rst), .decimation(cic2_decim), .clock(clock),
  .in_strobe(cic1_strobe_q), .out_strobe(cic2_strobe_q),
  .in_data(cic1_q), .out_data(cic2_q)
);

// ---------------------------------------------------------------------
// Stage 4: compensating FIR, decimate by 4 (the 65 tap filter, 24 bit output)
// ---------------------------------------------------------------------
fir_decim_ref #(
  .TAPS(65), .DECIM(4), .IN_WIDTH(16), .COEFF_WIDTH(20), .OUT_WIDTH(24),
  .COEFF_FILE(FIR_COEFF_FILE)
) u_fir (
  .clock(clock), .rst(chan_rst),
  .in_strobe(cic2_strobe_i), // I and Q strobes are always coincident
  .in_i(cic2_i), .in_q(cic2_q),
  .out_strobe(out_valid),
  .out_i(out_i), .out_q(out_q)
);

endmodule
