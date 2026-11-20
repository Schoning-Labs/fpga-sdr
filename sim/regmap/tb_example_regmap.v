// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Testbench for the register map generator (docs/REGMAP.md): the tool `xtask regmap` turns a description of a
// register block in TOML (hw/regmap/example.toml, a small sample block with an id, a control register with two
// fields, a status register with write-one-to-clear flags and an array of four channel registers) into a
// Verilog header (hw/regmap/generated/example_regs.vh) and a Rust module with the same addresses and fields, so
// that the hardware and the firmware cannot disagree about the layout. This is the Verilog half of the test of
// that round trip, the Rust half being fw/tr-regs/tests/example_regmap.rs. Both halves check the generated
// output against the same numbers, written down by hand from the TOML, so that if the generator ever drifts from
// the TOML in only one of the two languages, one of the two testbenches notices.
//
// Pass: every macro of the generated header (block base and size, register offsets, absolute addresses, reset
// values, field positions and widths, array offset, stride, count and the address of every instance) has the
// expected value; the bench prints "PASS", otherwise one "FAIL" line per wrong value and a count.
//
// The bench is self-contained, since it includes the generated header by a path relative to the repository
// root, which is where tools/check.sh runs iverilog from. To run it alone, from the repository root:
//   iverilog -g2012 -o tb.vvp sim/regmap/tb_example_regmap.v && vvp tb.vvp

`timescale 1ns / 1ps
`include "hw/regmap/generated/example_regs.vh"

module tb_example_regmap;

    integer errors;

    // Compare a 32-bit value (an address or a reset value) with the expected one; the label, up to 40
    // characters, names the macro in the failure message.
    task check32;
        input [8*40-1:0] label;
        input [31:0] got;
        input [31:0] want;
        begin
            if (got !== want) begin
                $display("FAIL: %0s = 32'h%08h, expected 32'h%08h", label, got, want);
                errors = errors + 1;
            end
        end
    endtask

    // The same for a plain number (a bit position, a width or a count).
    task check;
        input [8*40-1:0] label;
        input integer got;
        input integer want;
        begin
            if (got !== want) begin
                $display("FAIL: %0s = %0d, expected %0d", label, got, want);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        errors = 0;

        // Block: the base address and the size of the register page.
        // Block.
        check32("EXAMPLE_BASE", `EXAMPLE_BASE, 32'hE8EE_0000);
        check32("EXAMPLE_SIZE", `EXAMPLE_SIZE, 32'h0000_1000);

        // id: read-only, no fields; the reset value is the identification word read by software.
        // id: RO, no fields.
        check32("EXAMPLE_ID_ADDR", `EXAMPLE_ID_ADDR, 32'h0000_0000);
        check32("EXAMPLE_ID_ABS_ADDR", `EXAMPLE_ID_ABS_ADDR, 32'hE8EE_0000);
        check32("EXAMPLE_ID_RESET", `EXAMPLE_ID_RESET, 32'h1CE5_0001);

        // ctrl: read-write, two fields (enable in bit 0, mode in bits 2:1).
        // ctrl: RW, two fields.
        check32("EXAMPLE_CTRL_ADDR", `EXAMPLE_CTRL_ADDR, 32'h0000_0004);
        check32("EXAMPLE_CTRL_RESET", `EXAMPLE_CTRL_RESET, 32'h0000_0000);
        check("EXAMPLE_CTRL_ENABLE_LSB", `EXAMPLE_CTRL_ENABLE_LSB, 0);
        check("EXAMPLE_CTRL_ENABLE_MSB", `EXAMPLE_CTRL_ENABLE_MSB, 0);
        check("EXAMPLE_CTRL_ENABLE_WIDTH", `EXAMPLE_CTRL_ENABLE_WIDTH, 1);
        check("EXAMPLE_CTRL_MODE_LSB", `EXAMPLE_CTRL_MODE_LSB, 1);
        check("EXAMPLE_CTRL_MODE_MSB", `EXAMPLE_CTRL_MODE_MSB, 2);
        check("EXAMPLE_CTRL_MODE_WIDTH", `EXAMPLE_CTRL_MODE_WIDTH, 2);

        // status: two write-one-to-clear flags (overflow in bit 0, error in bit 1).
        // status: two W1C fields.
        check32("EXAMPLE_STATUS_ADDR", `EXAMPLE_STATUS_ADDR, 32'h0000_0008);
        check32("EXAMPLE_STATUS_RESET", `EXAMPLE_STATUS_RESET, 32'h0000_0000);
        check("EXAMPLE_STATUS_OVERFLOW_LSB", `EXAMPLE_STATUS_OVERFLOW_LSB, 0);
        check("EXAMPLE_STATUS_OVERFLOW_WIDTH", `EXAMPLE_STATUS_OVERFLOW_WIDTH, 1);
        check("EXAMPLE_STATUS_ERROR_LSB", `EXAMPLE_STATUS_ERROR_LSB, 1);
        check("EXAMPLE_STATUS_ERROR_WIDTH", `EXAMPLE_STATUS_ERROR_WIDTH, 1);

        // channel: read-write array of 4 registers, 4 bytes apart, from offset 0x10; the gain field takes the
        // low 8 bits and every instance resets to 0x80.
        // channel: RW array, count 4, stride 4, base offset 0x10.
        check32("EXAMPLE_CHANNEL_OFFSET", `EXAMPLE_CHANNEL_OFFSET, 32'h0000_0010);
        check32("EXAMPLE_CHANNEL_STRIDE", `EXAMPLE_CHANNEL_STRIDE, 32'h0000_0004);
        check("EXAMPLE_CHANNEL_COUNT", `EXAMPLE_CHANNEL_COUNT, 4);
        check32("EXAMPLE_CHANNEL_RESET", `EXAMPLE_CHANNEL_RESET, 32'h0000_0080);
        check("EXAMPLE_CHANNEL_GAIN_LSB", `EXAMPLE_CHANNEL_GAIN_LSB, 0);
        check("EXAMPLE_CHANNEL_GAIN_MSB", `EXAMPLE_CHANNEL_GAIN_MSB, 7);
        check("EXAMPLE_CHANNEL_GAIN_WIDTH", `EXAMPLE_CHANNEL_GAIN_WIDTH, 8);

        // Array addressing for every instance: offset + 4 * index, and the absolute address that adds the
        // block's base.
        // Array addressing, every instance.
        check32("EXAMPLE_CHANNEL_ADDR(0)", `EXAMPLE_CHANNEL_ADDR(0), 32'h0000_0010);
        check32("EXAMPLE_CHANNEL_ADDR(1)", `EXAMPLE_CHANNEL_ADDR(1), 32'h0000_0014);
        check32("EXAMPLE_CHANNEL_ADDR(2)", `EXAMPLE_CHANNEL_ADDR(2), 32'h0000_0018);
        check32("EXAMPLE_CHANNEL_ADDR(3)", `EXAMPLE_CHANNEL_ADDR(3), 32'h0000_001C);
        check32("EXAMPLE_CHANNEL_ABS_ADDR(2)", `EXAMPLE_CHANNEL_ABS_ADDR(2), 32'hE8EE_0018);

        if (errors == 0) begin
            $display("PASS");
        end else begin
            $display("FAIL: %0d error(s)", errors);
        end
        $finish;
    end

endmodule
