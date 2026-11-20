// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Testbench for the chip ID reader rtl/net/chip_dna.v, which reads the chip's factory ID (a 64-bit number that
// differs from chip to chip, used to tell several boards on one network apart) through Gowin's OTP primitive.
// The primitive is replaced by the model in sim/net/otp_model.v. The reader captures the 128-bit register
// (plus one bit) in raw, and the ID is raw[95:32].
//
// Pass: the ID read back equals 0123456789abcdef, which is the value the model holds; the bench prints
// "PASS: tb_dna id <hex>", otherwise "FAIL: tb_dna raw <hex>" or a timeout message.
//
// How to run: from the repository root,
//   iverilog -g2012 -o sim/out/tb_dna.vvp sim/net/tb_dna.v && vvp sim/out/tb_dna.vvp
`include "sim/net/otp_model.v"
`include "rtl/net/chip_dna.v"
module tb_dna;
    // A 100 MHz register clock; the reader divides it by 32 for the OTP clock (3.125 MHz).
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;
    // raw is the captured register, done goes high when the read is finished.
    wire [128:0] raw; wire done;
    chip_dna u (.clk(clk), .rst(rst), .raw(raw), .done(done));
    // Release reset after 100 ns, wait until the read is done, then compare the ID bits.
    initial begin
        #100 rst = 0;
        wait (done); #100;
        if (raw[95:32] === 64'h01234567_89abcdef) $display("PASS: tb_dna id %h", raw[95:32]);
        else $display("FAIL: tb_dna raw %h", raw);
        $finish;
    end
    // Watchdog: 20 ms of simulated time (the read itself takes about 150 us).
    initial begin #20000000; $display("FAIL: tb_dna timeout"); $finish; end
endmodule
