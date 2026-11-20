// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Stand-in for one GW5A DSP multiplier, used only by tools/yosys_res.sh. yosys' synth_gowin maps
// multipliers to DSP blocks for gw1n/gw2a but not for gw5a, so on gw5a every `*` becomes LUT logic
// and the LUT count is wrong by thousands. tools/yosys_res.sh splits every multiplier into pieces of
// at most 27 x 36 bits (one GW5A DSP in MULT27X36 mode, Gowin UG305) and leaves each piece as one
// instance of this black box, so the statistics count it as one DSP and no LUTs.

(* blackbox *)
module MULBB (A, B, Y);
    parameter A_WIDTH  = 27;
    parameter B_WIDTH  = 36;
    parameter Y_WIDTH  = 63;
    parameter A_SIGNED = 0;
    parameter B_SIGNED = 0;
    input  [A_WIDTH-1:0] A;
    input  [B_WIDTH-1:0] B;
    output [Y_WIDTH-1:0] Y;
endmodule
