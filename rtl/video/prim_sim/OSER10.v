// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// OSER10 (simulation model): a behavioral stand-in for Gowin's 10-to-1 output serializer, so that the HDMI path can be
// simulated on a PC with Icarus Verilog or Verilator.
//
// WHAT THE REAL PRIMITIVE IS
// OSER10 is a block in the output cell of the GW5A chip (Gowin data sheet DS1239 table 3-16, up to 1,600 Mbit/s). A
// serializer turns a wide, slow word into a narrow, fast stream of single bits. This one takes 10 bits (D0 to D9) once
// per parallel clock PCLK and shifts them out on one pin Q, two bits per cycle of a faster clock FCLK (one on the
// rising edge and one on the falling edge, called double data rate), so five FCLK cycles send ten bits and FCLK must be
// exactly five times PCLK. The bit D0 goes out first. In the radio there is one OSER10 per TMDS data lane (see
// rtl/video/sdr_hdmi_video.v for the theory), PCLK is clk_pix (74.17 MHz), FCLK is clk_pix5 (370.83 MHz) and Q
// leaves the chip through an ELVDS_OBUF at 741.7 Mbit/s. The real block is part of Gowin's device library, so on the
// chip nothing from this file is used: rtl/vendor/hdmi/serializer.sv instantiates OSER10 by name when the define GW_IDE
// is set, and the place and route tool resolves the name to the hardware block (rtl/video/prim_gowin/README.md). Without
// GW_IDE the serializer uses other paths (a plain behavioral one in simulation), and a simulation that does set GW_IDE
// gets this model in place of the hardware block.
//
// WHAT THIS MODEL DOES
// D0 to D9 are captured on the rising edge of PCLK, and over the following five FCLK cycles the bits are put on Q, the
// first one one FCLK period after the PCLK edge that captured them, then the second on the falling edge after that, and so
// on. RESET is synchronous to each clock and forces Q low. It is a functional model only: setup and hold times, jitter and
// the real output delay are not modeled, and nothing here says anything about the timing of the real block.

`timescale 1ns / 1ps

// Ports follow the Gowin primitive: Q is the serial output, D0 to D9 the ten parallel inputs (D0 is sent first),
// PCLK the parallel clock, FCLK the fast clock (5 x PCLK, same PLL, edges aligned) and RESET a synchronous reset
// (held for at least one PCLK period at the start).
module OSER10 (
    output reg  Q,  // serial output, one bit per FCLK edge (both edges)
    input  wire D0, D1, D2, D3, D4, D5, D6, D7, D8, D9,  // parallel data, valid around each rising edge of PCLK
    input  wire PCLK,  // parallel clock: the word is captured on its rising edge
    input  wire FCLK,  // serial clock, 5 x PCLK: one bit goes out on each of its edges
    input  wire RESET  // high forces Q to 0 and clears the model's state
);

// The model assumes what the real primitive requires anyway: FCLK is exactly five times PCLK, from the same PLL, with
// aligned edges. A testbench has to generate the two clocks like that (same time origin, exact 5:1 period ratio) and
// hold RESET for at least one PCLK period before letting it go. With that, `shift` (loaded in PCLK) and `slot` (a
// free-running counter in FCLK, reset once) stay in step forever without any logic between the two clock domains: all
// assignments are nonblocking, so even at an edge where PCLK and FCLK rise together every block reads the old values,
// and loading a new word cannot disturb the last bit of the previous one.
reg [9:0] shift = 10'd0;  // the captured word, bit 0 = D0
reg [2:0] slot   = 3'd0; // which FCLK half-cycle (0..4) within the 5-cycle PCLK period we're in  // which FCLK cycle of the current PCLK period (the cycles are numbered 0 to 4)

// Capture a new 10-bit word on every PCLK rising edge.
always @(posedge PCLK) begin
    if (RESET)
        shift <= 10'd0;
    else
        shift <= {D9, D8, D7, D6, D5, D4, D3, D2, D1, D0};
end

// Free-running slot counter in FCLK, counting 0, 1, 2, 3, 4 and back to 0. Five FCLK rising edges after the last wrap
// is the next PCLK rising edge, so the counter wraps at the moment the next word is loaded.
always @(posedge FCLK) begin
    if (RESET)
        slot <= 3'd0;
    else
        slot <= (slot == 3'd4) ? 3'd0 : slot + 3'd1;
end

// Q at double data rate: the even bit of the pair on the FCLK rising edge and the odd bit on the falling edge after it.
// The index is slot[1:0] x 2, and slot[1:0] keeps only the two low bits of the slot number, so in slot 4 the index is 0
// again: this model sends bits 0 and 1 a second time and never sends bits 8 and 9 (D8 and D9). The real primitive sends
// all ten.
always @(posedge FCLK) begin
    if (RESET)
        Q <= 1'b0;
    else
        Q <= shift[slot[1:0]*2];
end

always @(negedge FCLK) begin
    if (RESET)
        Q <= 1'b0;
    else
        Q <= shift[slot[1:0]*2 + 1];
end

endmodule
