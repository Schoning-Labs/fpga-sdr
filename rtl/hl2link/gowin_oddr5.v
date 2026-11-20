// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// RGMII transmit DDR output stage: drives 5 bits (TX_CTL and TXD[3:0]) on both edges of our own
// transmit clock. Not used in the current design, where the HL2 link leaves over the SFP lane and
// the RJ45 socket belongs to the network unit (docs/HL2_SFP.md section 9), and kept together with
// the other RGMII pieces for a board that wires the HL2 link to an RGMII PHY.
//
// What DDR and RGMII mean, for a beginner: RGMII connects an Ethernet PHY chip to the FPGA with
// only four data wires per direction. At 1000 Mbit/s the interface uses DDR (double data rate):
// a 125 MHz clock carries one four-bit nibble on its rising edge and the next nibble on its
// falling edge, which is one byte per clock period. The output flip-flop that drives a pin from
// two data inputs, one for each half of the period, is the ODDR primitive of the Gowin chip, and
// this module wraps it. Unlike the receive side (gowin_iddr5.v, whose clock is forwarded by the
// PHY) this clock is ours to define, a 125 MHz clock derived from the 50 MHz board oscillator.
//
// Compile time choice: with GOWIN_ODDR defined, five ODDR primitives are instantiated, one per
// pin. Without it, a behavioural model is used, so that every testbench in sim/ runs on a plain
// simulator.
//
// Timing: the pins present `d_rise` from this rising edge until the next falling edge, then
// `d_fall` until the next rising edge, which is the standard DDR output shape (RGMII 2.0: TXD[3:0]
// low nibble at the rising edge, high nibble at the falling edge; the transmitter that uses this stage is the only
// place that has to agree with which nibble goes into which input).
//
// Both halves are captured at the SAME (rising) edge and then released by a clock-level
// multiplexer. They are not captured at their own edge each (posedge for `d_rise`, negedge for
// `d_fall`), because `d_rise` and `d_fall` are combinational functions of the transmitter's shift
// register, which is a plain posedge register on this same `clk`. A posedge capture of `d_rise`
// is then an ordinary one-clock pipeline stage and sees the shift register's previous value, but
// a negedge capture of `d_fall` sees the same shift register half a period later, after the
// update from the intervening posedge has landed, which is a whole period of skew between the two
// halves that a real ODDR primitive (which samples D0 and D1 at one clock edge) does not have.
// The skew would tear the low nibble of one byte away from the right neighbour. Capturing both
// halves at the rising edge together removes it.

`timescale 1ns / 1ps

module gowin_oddr5 (
    input  wire       clk,      // our transmit clock, 125 MHz
    input  wire [4:0] d_rise,   // {tx_ctl, txd[3:0]} to present from this rising edge
    input  wire [4:0] d_fall,   // ... from the following falling edge
    output wire [4:0] q         // RGMII pins
);

`ifdef GOWIN_ODDR

    // Gowin's ODDR primitive takes one data pin per instance, with D0 output at the rising edge of
    // CLK and D1 at the falling edge. Five single-bit instances cover TX_CTL and TXD[3:0].
    genvar i;
    generate
        for (i = 0; i < 5; i = i + 1) begin : ODDR_BIT
            ODDR oddr_inst (
                .CLK(clk),
                .D0 (d_rise[i]),
                .D1 (d_fall[i]),
                .TX (1'b0),
                .Q0 (q[i]),     // GW5A ODDR: Q0 data, Q1 tristate control
                .Q1 ()
            );
        end
    endgenerate

`else

    // Behavioural model for simulation (and for any non-Gowin target): both halves captured
    // together at the rising edge (see the header for why not one capture per edge), then released
    // by a clock-level multiplexer, high during the first half of the period (matching `d_rise`)
    // and low during the second (matching `d_fall`). That is exactly the DDR output waveform a
    // real ODDR produces, with no relative skew between the two halves.
    reg [4:0] q_rise_r = 5'b0;
    reg [4:0] q_fall_r = 5'b0;

    always @(posedge clk) begin
        q_rise_r <= d_rise;
        q_fall_r <= d_fall;
    end

    assign q = clk ? q_rise_r : q_fall_r;

`endif

endmodule
