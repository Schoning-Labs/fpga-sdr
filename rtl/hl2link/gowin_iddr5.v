// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// RGMII receive DDR input stage: samples 5 bits (RX_CTL and RXD[3:0]) on both edges of the receive
// clock that the PHY forwards. Not used in the current design, where the Hermes-Lite 2 arrives
// over the SFP lane and the RJ45 socket belongs to the network unit (docs/HL2_SFP.md section 9),
// and kept together with the other RGMII pieces for a board that wires the HL2 link to an RGMII
// PHY.
//
// What DDR and RGMII mean, for a beginner: RGMII is the reduced gigabit media independent
// interface, which connects an Ethernet PHY chip to the FPGA with only four data wires per
// direction. At 1000 Mbit/s each wire has to carry 250 Mbit/s, which would need a 250 MHz clock
// with one bit per tick, so instead the interface uses DDR (double data rate): one 125 MHz clock
// carries one four-bit nibble on its rising edge and the next nibble on its falling edge, which
// makes one byte per clock period. The input flip-flop that captures data on both edges of a clock
// is the IDDR primitive of the Gowin chip, and this module wraps it.
//
// Compile time choice: with GOWIN_IDDR defined, five IDDR primitives are instantiated (one per
// pin), each behind an IODELAY. Without it, a behavioural model is used, so that every testbench
// in sim/ runs on a plain simulator. The two branches present the same pairing of nibbles.
//
// Timing: at the rising edge of `clk` this module presents the byte whose low nibble was driven
// during the half cycle before the PREVIOUS rising edge, and whose high nibble was driven during
// the half cycle before THIS rising edge. That is one full `clk` period of latency from "nibble
// on the pins" to "q_rise and q_fall valid", which is what a same-cycle-paired IDDR output
// normally gives. The receiver that uses this stage is the only place that has to agree with this pairing.

`timescale 1ns / 1ps

module gowin_iddr5 #(
    parameter integer RX_DLY_STEPS = 170    // IODELAY steps of about 12.5 ps on each data pin (see below)
) (
    input  wire       clk,          // RGMII RXC, 125 MHz, forwarded by the PHY
    input  wire [4:0] d,        // {rx_ctl, rxd[3:0]}, RGMII pins
    output reg  [4:0] q_rise,   // nibble driven just before this rising edge (the frame's "high" nibble)
    output reg  [4:0] q_fall    // nibble driven just before the preceding falling edge ("low" nibble)
);

`ifdef GOWIN_IDDR

    // Gowin's IDDR primitive takes one data pin per instance and returns Q0 (rising-edge-aligned)
    // and Q1 (falling-edge-aligned), sampled together at the next rising edge of CLK. Five
    // single-bit instances cover RX_CTL and RXD[3:0].
    genvar i;
    generate
        for (i = 0; i < 5; i = i + 1) begin : IDDR_BIT
            // Input delay. The PHY's RXDLY strap puts each RXC edge in the middle of the data, but
            // RXC then needs about 2.9 ns from its pin (which is not a clock pin, so the path is
            // ordinary wiring up to a global clock line) to the IDDR clock, and the data only
            // 1.4 ns, so without a delay the IDDR would sample at the very end of the data, with
            // the hold time missing. The delay moves the data back under the clock edge.
            // IODELAY (UG304-1.3.2E section 4.4.1): static mode, 256 steps of about 12.5 ps, and
            // the timing report counts 0.61 ns plus 12.5 ps per step. 170 steps (2.7 ns in all)
            // leave about 1.6 ns on both sides with the clock delay of the full build. The value
            // has to be centered again from the report (setup and hold slack of the path from
            // rgmii_rxd to IDDR_BIT in gowin/p1/sdr.sdc) when the clock delay changes.
            wire d_dly;
            IODELAY #(.C_STATIC_DLY(RX_DLY_STEPS), .DYN_DLY_EN("FALSE"), .ADAPT_EN("FALSE")) dly_inst (
                .DI(d[i]), .DO(d_dly), .DF(), .SDTAP(1'b0), .VALUE(1'b0), .DLYSTEP(8'd0)
            );
            IDDR iddr_inst (
                .D  (d_dly),
                .CLK(clk),
                .Q0 (q_rise[i]),
                .Q1 (q_fall[i])
            );
        end
    endgenerate

`else

    // Behavioural model for simulation (and for any non-Gowin target): a plain DDR input register
    // pair. The falling-edge sample is captured at the falling edge and then picked up at the next
    // rising edge together with the rising-edge sample, which gives the pairing described in the
    // header.
    reg [4:0] d_fall_capture = 5'b0;

    always @(negedge clk) d_fall_capture <= d;

    always @(posedge clk) begin
        q_rise <= d;
        q_fall <= d_fall_capture;
    end

`endif

endmodule
