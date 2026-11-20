// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Stimulus generator for the spectral test of the receive mixer rtl/rx/nco_mixer.v in MODE 0. The
// mixer multiplies a real ADC sample by a complex sine, e^(j t), whose phase t advances by a
// 32 bit tuning word every sample (a numerically controlled oscillator, NCO, see
// docs/learn/GLOSSARY.md), so it moves the tuned frequency down to zero. Any error in the
// oscillator's sine and cosine shows up as unwanted lines (spurs) in the output spectrum, and
// the figure of merit is the spurious-free dynamic range (SFDR), the distance in dB from the wanted
// line to the largest unwanted one. Measuring that needs FFTs, so this bench only produces the
// data and tools/rb4_nco_sfdr.py, which writes the case list, runs this simulation and does the
// analysis, takes it from there. It is not a tb_*.v file for that reason. docs/RX_DSP.md section 10
// has the results.
//
// Input: sim/out/nco_sfdr_cases.txt, whose first line is the number of cases and whose other lines
// are "<tuning word> <tone frequency in cycles/sample> <tone phase>". For each case the bench sets
// the tuning word and feeds SKIP + NS samples of a full-scale 12 bit tone,
// round(2047 cos(2 pi f n + p)), with in_strobe high on every clock.
//
// Output: sim/out/nco_sfdr_out.txt, one line "<x> <phase> <out_i> <out_q>" per output sample, where
// x and phase are the input sample and the NCO phase that this output belongs to. The bench keeps
// its own delay line of LAT - 1 = 6 samples for that, so the analysis can form the ideal output
// G x e^(j 2 pi phase / 2^32) without any assumption about the timing of the pipeline. The first
// SKIP outputs after a change of the tuning word still belong to the previous case and are not
// written. There is no pass or fail here, the verdict comes from the Python tool.
//
// Run from the repository root (tools/rb4_nco_sfdr.py does this):
//   iverilog -g2012 -o sim/out/nco_sfdr.vvp sim/rx/nco_sfdr_sim.v && vvp sim/out/nco_sfdr.vvp

`timescale 1ns / 1ps

`include "rtl/rx/nco_mixer.v"

module nco_sfdr_sim;

  // NS samples per case are analyzed, after SKIP outputs that are discarded while the pipeline
  // still holds the previous case. DLY is the mixer's latency in accepted samples minus one
  // (7 - 1 in MODE 0), which is how far the delay lines below must reach back.
  localparam real PI = 3.14159265358979323846;
  localparam integer NS   = 4096;
  localparam integer SKIP = 16;
  localparam integer DLY  = 6;   // nco_mixer MODE 0: LAT - 1

  // The time scale is arbitrary, the mixer only counts clock edges (2 ns per period here).
  reg clock = 1'b0;
  always #1 clock = ~clock;

  // Tuning word (phase step per sample, one turn = 2^32), the 12 bit input sample and the outputs.
  reg signed [31:0] freq = 32'sd0;
  reg signed [11:0] x = 12'sd0;
  wire              os;
  wire signed [17:0] oi, oq;

  nco_mixer #(.MODE(0), .IN_WIDTH(12), .OUT_WIDTH(18)) dut (
    .clock(clock), .rst(1'b0), .in_strobe(1'b1), .frequency(freq),
    .in_i(x), .in_q(12'sd0), .out_strobe(os), .out_i(oi), .out_q(oq)
  );

  // Delay lines of the input sample and of its NCO phase, so that each output can be written
  // together with the input and phase it came from. ph is the bench's own model of the phase
  // accumulator.
  reg signed [11:0] xd [0:DLY];
  reg [31:0]        pd [0:DLY];
  reg [31:0]        ph = 32'd0;
  integer fi, fo, ncase, c, n, k, r;
  reg [31:0] w;
  real ftone, ptone;

  // For every case: set the tuning word, feed the tone and log the output.
  initial begin
    fi = $fopen("sim/out/nco_sfdr_cases.txt", "r");
    fo = $fopen("sim/out/nco_sfdr_out.txt", "w");
    if (fi == 0 || fo == 0) begin $display("nco_sfdr_sim: cannot open sim/out files"); $finish; end
    r = $fscanf(fi, "%d\n", ncase);
    for (k = 0; k <= DLY; k = k + 1) begin xd[k] = 0; pd[k] = 0; end
    for (c = 0; c < ncase; c = c + 1) begin
      r = $fscanf(fi, "%d %f %f\n", w, ftone, ptone);
      for (n = 0; n < SKIP + NS; n = n + 1) begin
        @(negedge clock);
        freq = w;
        x = $rtoi($floor(2047.0 * $cos(2.0 * PI * ftone * n + ptone) + 0.5));
        // This sample's phase is the accumulator value at this edge, before the step is added.
        for (k = DLY; k > 0; k = k - 1) begin xd[k] = xd[k-1]; pd[k] = pd[k-1]; end
        xd[0] = x; pd[0] = ph;
        ph = (freq == 0) ? 32'd0 : ph + freq;
        // Look just after the rising edge, when the mixer's registers have settled.
        @(posedge clock); #0.1;
        if (os && n >= SKIP) $fdisplay(fo, "%0d %0d %0d %0d", xd[DLY], pd[DLY], oi, oq);
      end
    end
    $fclose(fo);
    $display("nco_sfdr_sim: %0d cases done", ncase);
    $finish;
  end

endmodule
