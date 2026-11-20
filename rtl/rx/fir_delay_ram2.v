// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// fir_delay_ram2: the circular delay-line memory that two fir_decim instances share. The two
// receivers have separate rings in one physical block RAM, so that a bank of 8 receivers needs
// 4 blocks and not 8. The block is a true dual-port memory (two independent ports, each able to
// read and write at the same time), and its address space is split into two halves by a fixed
// high bit: port A always addresses the low half (receiver A's own RING_DEPTH-entry ring) and
// port B the high half (receiver B's). Each port has its own write address and its own
// synchronous read address (the data appears one clock after the address), which is what the
// sequencer in fir_decim.v needs: a write for every new sample and a read on every step of its
// multiply pass. fir_decim.v explains why the ring must be deeper than the number of taps and
// why the read is registered.
//
// Where it sits: rx_bank.v instantiates one of these per pair of receivers (an odd leftover
// receiver gets a block to itself with port B unused). Each word is 32 bits, the 16-bit I and Q
// samples side by side. The two rings together are 2 x 128 words of 32 bits, which is 8 kbit and
// so small enough for one 18-kbit Gowin block RAM.

module fir_delay_ram2 #(
  parameter RING_DEPTH = 128, // per receiver; total memory depth is 2x this
  parameter WORD_W     = 32   // bits per word, {I, Q}
)(
  input clock,                // DSP clock, both ports

  // port A: the first receiver
  input                      wr_a,                              // write enable
  input      [$clog2(RING_DEPTH)-1:0] waddr_a,                  // write address
  input      [WORD_W-1:0]   wdata_a,                            // word to write
  input      [$clog2(RING_DEPTH)-1:0] raddr_a,                  // read address
  output reg [WORD_W-1:0]   rdata_a,                            // word read, one clock after raddr_a

  // port B: the second receiver
  input                      wr_b,
  input      [$clog2(RING_DEPTH)-1:0] waddr_b,
  input      [WORD_W-1:0]   wdata_b,
  input      [$clog2(RING_DEPTH)-1:0] raddr_b,
  output reg [WORD_W-1:0]   rdata_b
) /* synthesis syn_maxfan = 10000 */;

// Two separate arrays, not one array addressed by {region_bit, offset}: yosys's automatic
// memory inference (the `memory` pass) wants a plain signal as the index, not a concatenation
// expression, and an indexed-by-concatenation single array measured far worse (fell back to
// flip-flops entirely, 0 BSRAM) than this, which infers cleanly the same way a lone
// fir_decim's own private ring already does.
reg [WORD_W-1:0] mem_a [0:RING_DEPTH-1];
reg [WORD_W-1:0] mem_b [0:RING_DEPTH-1];
// Both rings start at zero, which stands in for a reset of the contents (fir_decim.v clears
// them again by writing zeros when a receiver is disabled).
integer mi;
initial for (mi = 0; mi < RING_DEPTH; mi = mi + 1) begin
  mem_a[mi] = {WORD_W{1'b0}};
  mem_b[mi] = {WORD_W{1'b0}};
end

// Port A: a write and a registered read, both on every clock if wanted.
always @(posedge clock) begin
  if (wr_a) mem_a[waddr_a] <= wdata_a;
  rdata_a <= mem_a[raddr_a];
end

// Port B: the same, for the other receiver.
always @(posedge clock) begin
  if (wr_b) mem_b[waddr_b] <= wdata_b;
  rdata_b <= mem_b[raddr_b];
end

endmodule
