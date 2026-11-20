// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Reference model of the receiver bank as it was before it was rebalanced: N independent
// receivers (rx_channel_ref) that share one ADC input and one register write port, and whose
// output samples are merged onto one stream tagged with a receiver index. Each receiver here has its
// own variable CIC filter and its own FIR with a shift register and a snapshot copy, where the
// current rtl/rx/rx_bank.v shares two CIC engines between the receivers and keeps the FIR delay
// lines in circular buffers. sim/rx/tb_rb3_compare.v runs both side by side on the same stimulus and
// checks that the current bank delivers the same words in the same order. The module is called
// rx_bank_ref so that both can be compiled into one bench.
//
// One shared output stream (valid, index, I and Q) was chosen instead of N parallel IQ buses,
// because everything downstream of the bank (the VITA-49 packetizer, the DDR3 buffering and the
// firmware that reads the samples) has to serialize the samples into one stream or memory
// anyway, so N parallel buses would only move the problem downstream and cost N times the
// wiring for no benefit. The shared stream costs a small skid buffer per receiver and a
// round-robin arbiter here. That is safe because the gap between two samples of the same receiver
// is at least 200 ADC clocks even at the fastest setting of 384 ksps, which is far longer than
// the arbiter needs to drain a collision between up to N receivers (at most N clocks), so a skid
// buffer of one entry per receiver can never overflow.
//
// Register write port (simple synchronous, one write per clock):
//   reg_addr[ADDR_W-1:REG_BITS]   = receiver index (0 .. N-1)
//   reg_addr[REG_BITS-1:0]        = 0 -> phase_inc (32 bit NCO frequency word)
//                                    1 -> control {29'b0, enable, rate_sel[1:0]}
//   reg_wdata[31:0], reg_wr pulses one clock per write.

module rx_bank_ref #(
  parameter N          = 8,
  parameter ADC_WIDTH  = 12,
  parameter FIR_COEFF_FILE = "fir_coeffs.hex"
)(
  input                       clock,        // 76.8 MHz ADC clock
  input                       rst,

  input      [ADC_WIDTH-1:0]  adc_data,
  input                       adc_valid,

  // register write port: reg_addr[0] = 0 -> phase_inc, 1 -> control;
  // reg_addr[IDX_W:1] = channel index
  input                       reg_wr,
  input      [$clog2(N>1?N:2):0] reg_addr,
  input      [31:0]           reg_wdata,

  // shared output IQ stream
  output reg                  out_valid,
  output reg [$clog2(N)-1:0]  out_index,
  output reg signed [23:0]    out_i,
  output reg signed [23:0]    out_q
);

// IDX_W is the width of the receiver index.
localparam IDX_W = (N <= 1) ? 1 : $clog2(N);

// ---------------------------------------------------------------------
// Per receiver configuration registers: tuning word, output rate (0 to 3 for 48, 96, 192, 384 ksps)
// and enable. A write to the control register sets rate_sel from bits 1:0 and enable from bit 2.
// ---------------------------------------------------------------------
reg signed [31:0] phase_inc [0:N-1];
reg [1:0]         rate_sel  [0:N-1];
reg               ch_enable [0:N-1];

integer ri;
always @(posedge clock) begin
  if (rst) begin
    for (ri = 0; ri < N; ri = ri + 1) begin
      phase_inc[ri] <= 32'd0;
      rate_sel[ri]  <= 2'd0;
      ch_enable[ri] <= 1'b0;
    end
  end else if (reg_wr) begin
    if (reg_addr[0] == 1'b0)
      phase_inc[reg_addr[IDX_W:1]] <= reg_wdata[31:0];
    else begin
      rate_sel[reg_addr[IDX_W:1]]  <= reg_wdata[1:0];
      ch_enable[reg_addr[IDX_W:1]] <= reg_wdata[2];
    end
  end
end

// ---------------------------------------------------------------------
// The receiver instances, all fed from the same ADC stream
// ---------------------------------------------------------------------
wire                  ch_valid [0:N-1];
wire signed [23:0]    ch_i     [0:N-1];
wire signed [23:0]    ch_q     [0:N-1];

genvar gi;
generate
  for (gi = 0; gi < N; gi = gi + 1) begin : rx
    rx_channel_ref #(
      .ADC_WIDTH(ADC_WIDTH),
      .FIR_COEFF_FILE(FIR_COEFF_FILE)
    ) u_rx (
      .clock     (clock),
      .rst       (rst),
      .adc_data  (adc_data),
      .adc_valid (adc_valid),
      .phase_inc (phase_inc[gi]),
      .rate_sel  (rate_sel[gi]),
      .enable    (ch_enable[gi]),
      .out_valid (ch_valid[gi]),
      .out_i     (ch_i[gi]),
      .out_q     (ch_q[gi])
    );
  end
endgenerate

// ---------------------------------------------------------------------
// Per receiver skid buffer of one entry (pend_*) and a round-robin arbiter onto the shared stream
// ---------------------------------------------------------------------
reg               pend_valid [0:N-1];
reg signed [23:0] pend_i     [0:N-1];
reg signed [23:0] pend_q     [0:N-1];

// rr_ptr is the receiver where the next search for a pending sample starts, one after the last one served.
reg [IDX_W-1:0] rr_ptr;

// Combinational round-robin selection: which pending receiver (if any) is granted in this clock.
// It is shared as plain wires by the clearing of pend_valid below and by the update of
// out_valid and out_index further down, so that both act on the decision of the same clock. A
// granted entry must be cleared on the same edge that grants it. Clearing it from the
// registered out_valid and out_index would leave it marked pending for one more clock, and the
// search would grant it a second time and emit the same sample twice.
integer si;
reg found;
reg [IDX_W-1:0] found_idx;
always @(*) begin
  found = 1'b0;
  found_idx = rr_ptr;
  for (si = 0; si < N; si = si + 1) begin
    if (!found && pend_valid[(rr_ptr + si[IDX_W-1:0]) % N]) begin
      found = 1'b1;
      found_idx = (rr_ptr + si[IDX_W-1:0]) % N;
    end
  end
end

// A completed sample from a receiver is stored in its skid buffer and marked pending, and a
// granted entry is cleared.
integer pi;
always @(posedge clock) begin
  if (rst) begin
    for (pi = 0; pi < N; pi = pi + 1)
      pend_valid[pi] <= 1'b0;
  end else begin
    for (pi = 0; pi < N; pi = pi + 1) begin
      if (ch_valid[pi]) begin
        pend_valid[pi] <= 1'b1;
        pend_i[pi]     <= ch_i[pi];
        pend_q[pi]     <= ch_q[pi];
      end else if (found && found_idx == pi[IDX_W-1:0]) begin
        pend_valid[pi] <= 1'b0;
      end
    end
  end
end

// Output register: the granted sample goes to the shared stream with its receiver index, and the
// pointer moves on to the next receiver.
always @(posedge clock) begin
  if (rst) begin
    rr_ptr    <= {IDX_W{1'b0}};
    out_valid <= 1'b0;
    out_index <= {IDX_W{1'b0}};
    out_i     <= 24'sd0;
    out_q     <= 24'sd0;
  end else begin
    if (found) begin
      out_valid <= 1'b1;
      out_index <= found_idx;
      out_i     <= pend_i[found_idx];
      out_q     <= pend_q[found_idx];
      rr_ptr    <= found_idx + 1'b1;
    end else begin
      out_valid <= 1'b0;
    end
  end
end

endmodule
