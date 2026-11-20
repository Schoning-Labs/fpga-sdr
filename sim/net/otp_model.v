// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Behavioral model of Gowin's OTP primitive for simulation, used by the benches of the chip ID reader
// rtl/net/chip_dna.v and of the network unit. The OTP primitive gives access to the chip's factory-programmed
// eFuse bits, among them a 64-bit ID (called DNA) that is different for every chip, and Gowin's simulation
// library declares the module without a body, so this file supplies one. The model follows Gowin's Primitives
// User Guide (SUG283, section 8.9) for MODE 2'b01: a pulse on READ loads the 128-bit register, then SHIFT
// high shifts it out on DOUT, lowest bit first, one bit per CLK; bits 95 to 32 are the DNA. The position of
// the first bit is as measured on the real board: register bit 0 is already on DOUT before the first rising
// edge with SHIFT high, and bit 1 + k appears after rising edge k, which is what the model does. The ID it
// holds, 0123456789abcdef, is an invented value that is easy to recognize. It is not part of any build; only the
// benches include it.
`timescale 1ns/1ps
module OTP #(parameter MODE = 2'b01) (output reg DOUT, input CLK, input READ, input SHIFT);
    // The 128-bit shift register, loaded from PAT on READ.
    reg [127:0] sh = 128'd0;
    // Register layout: bits 127:112 and 111:96 are other fuse regions (made-up values), bits 95:32 are the DNA
    // and bits 31:0 the user region.
    localparam [127:0] PAT = {16'hABCD, 16'h1234, 64'h01234567_89abcdef, 32'h0};
    initial DOUT = 1'b0;
    // On a rising CLK: READ loads the register and puts bit 0 on DOUT at once; SHIFT moves the register right by one
    // bit and presents the next bit on DOUT 3 ns later, as the primitive's output is not instantaneous.
    always @(posedge CLK) begin
        if (READ) begin sh <= PAT; DOUT <= PAT[0]; end
        else if (SHIFT) begin #3 DOUT <= sh[1]; sh <= {1'b0, sh[127:1]}; end
    end
endmodule
