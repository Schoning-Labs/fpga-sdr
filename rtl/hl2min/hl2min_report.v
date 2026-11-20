// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Status line printer of the minimal Hermes-Lite 2 test build (docs/HL2MIN.md section 5). The test
// build has no processor and no screen, so the only way to see what it measures is a serial line:
// this module sends one line of plain ASCII text on the debug UART (a UART is an asynchronous
// serial port, here 115,200 baud, 8 data bits, no parity, 1 stop bit, which any terminal program on
// the PC can show) each time `tick` arrives, once a second.
//
// What a line looks like: the fields of `fields` are latched at the tick, so that a line shows one
// consistent moment. Numbers are decimal without leading zeros, and the `%nx` fields are
// hexadecimal with n digits. Fields 0 to 19 are used in this order (18 and 19 are the high and low
// word of the chip ID):
//   t=%d st=%d ln=%1x pcs=%2x fr=%d by=%d lost=%d gap=%d fcs=%d len=%d ovf=%d hovf=%d fill=%d pat=%d sb=%2x ip=%8x
//   ck=%2x try=%d id=%8x%8x CR LF
// docs/HL2MIN.md section 5 says what every field means. The item table below is the format string
// in a form that logic can walk through: one entry per character or per field.
//
// How it works, step by step:
//   1. At `tick`, all fields are copied into `fl` and the printer starts at item 0.
//   2. Each item is a literal character (sent as it is), a decimal field (converted from binary to
//      decimal digits by the double dabble method, 32 clocks, and sent without leading zeros), a
//      hexadecimal field (its digits sent directly), or the end of the line.
//   3. Every character goes to the UART transmitter, which sends the start bit, eight data bits
//      (least significant first) and the stop bit, each lasting BAUD_DIV clocks, and the printer
//      waits until the character has left before it goes on to the next one.
// A line of about 150 characters takes about 13 ms at 115,200 baud, far less than the second
// between ticks.

`timescale 1ns / 1ps

module hl2min_report #(
    parameter integer NF = 20,                // number of 32-bit fields
    parameter integer BAUD_DIV = 434          // 50 MHz / 115,200
) (
    input  wire            clk,               // 50 MHz board clock
    input  wire            rst,               // synchronous reset, active high
    input  wire            tick,              // one-clock pulse: print one line now (once a second)
    input  wire [NF*32-1:0] fields,           // the values to print, 32 bits each, field 0 in the lowest bits
    output reg             txd = 1'b1         // serial line, idles high
);
    // ---------------------------------------------------------------- format items: {type, digits, argument}
    // type 0 end, 1 character, 2 decimal field, 3 hexadecimal field with `digits` digits.
    // The argument is the ASCII code of the character, or the number of the field. A character
    // item has a comment with the character; a field item is the value printed after its label.
    function [13:0] item(input [7:0] k);
        case (k)
            8'd0: item = {2'd1, 4'd0, 8'd116};   // 't'
            8'd1: item = {2'd1, 4'd0, 8'd61};   // '='
            8'd2: item = {2'd2, 4'd0, 8'd0};   // field 0: seconds since reset
            8'd3: item = {2'd1, 4'd0, 8'd32};   // ' '
            8'd4: item = {2'd1, 4'd0, 8'd115};   // 's'
            8'd5: item = {2'd1, 4'd0, 8'd116};   // 't'
            8'd6: item = {2'd1, 4'd0, 8'd61};   // '='
            8'd7: item = {2'd2, 4'd0, 8'd1};   // field 1: start-up step
            8'd8: item = {2'd1, 4'd0, 8'd32};   // ' '
            8'd9: item = {2'd1, 4'd0, 8'd108};   // 'l'
            8'd10: item = {2'd1, 4'd0, 8'd110};   // 'n'
            8'd11: item = {2'd1, 4'd0, 8'd61};   // '='
            8'd12: item = {2'd3, 4'd1, 8'd2};   // field 2: lane status
            8'd13: item = {2'd1, 4'd0, 8'd32};   // ' '
            8'd14: item = {2'd1, 4'd0, 8'd112};   // 'p'
            8'd15: item = {2'd1, 4'd0, 8'd99};   // 'c'
            8'd16: item = {2'd1, 4'd0, 8'd115};   // 's'
            8'd17: item = {2'd1, 4'd0, 8'd61};   // '='
            8'd18: item = {2'd3, 4'd2, 8'd3};   // field 3: PCS status bits
            8'd19: item = {2'd1, 4'd0, 8'd32};   // ' '
            8'd20: item = {2'd1, 4'd0, 8'd102};   // 'f'
            8'd21: item = {2'd1, 4'd0, 8'd114};   // 'r'
            8'd22: item = {2'd1, 4'd0, 8'd61};   // '='
            8'd23: item = {2'd2, 4'd0, 8'd4};   // field 4: raw frames received
            8'd24: item = {2'd1, 4'd0, 8'd32};   // ' '
            8'd25: item = {2'd1, 4'd0, 8'd98};   // 'b'
            8'd26: item = {2'd1, 4'd0, 8'd121};   // 'y'
            8'd27: item = {2'd1, 4'd0, 8'd61};   // '='
            8'd28: item = {2'd2, 4'd0, 8'd5};   // field 5: bytes per second
            8'd29: item = {2'd1, 4'd0, 8'd32};   // ' '
            8'd30: item = {2'd1, 4'd0, 8'd108};   // 'l'
            8'd31: item = {2'd1, 4'd0, 8'd111};   // 'o'
            8'd32: item = {2'd1, 4'd0, 8'd115};   // 's'
            8'd33: item = {2'd1, 4'd0, 8'd116};   // 't'
            8'd34: item = {2'd1, 4'd0, 8'd61};   // '='
            8'd35: item = {2'd2, 4'd0, 8'd6};   // field 6: raw frames lost by sequence number
            8'd36: item = {2'd1, 4'd0, 8'd32};   // ' '
            8'd37: item = {2'd1, 4'd0, 8'd103};   // 'g'
            8'd38: item = {2'd1, 4'd0, 8'd97};   // 'a'
            8'd39: item = {2'd1, 4'd0, 8'd112};   // 'p'
            8'd40: item = {2'd1, 4'd0, 8'd61};   // '='
            8'd41: item = {2'd2, 4'd0, 8'd7};   // field 7: gap samples inserted
            8'd42: item = {2'd1, 4'd0, 8'd32};   // ' '
            8'd43: item = {2'd1, 4'd0, 8'd102};   // 'f'
            8'd44: item = {2'd1, 4'd0, 8'd99};   // 'c'
            8'd45: item = {2'd1, 4'd0, 8'd115};   // 's'
            8'd46: item = {2'd1, 4'd0, 8'd61};   // '='
            8'd47: item = {2'd2, 4'd0, 8'd8};   // field 8: frames with a bad FCS or code error
            8'd48: item = {2'd1, 4'd0, 8'd32};   // ' '
            8'd49: item = {2'd1, 4'd0, 8'd108};   // 'l'
            8'd50: item = {2'd1, 4'd0, 8'd101};   // 'e'
            8'd51: item = {2'd1, 4'd0, 8'd110};   // 'n'
            8'd52: item = {2'd1, 4'd0, 8'd61};   // '='
            8'd53: item = {2'd2, 4'd0, 8'd9};   // field 9: raw frames with a wrong length
            8'd54: item = {2'd1, 4'd0, 8'd32};   // ' '
            8'd55: item = {2'd1, 4'd0, 8'd111};   // 'o'
            8'd56: item = {2'd1, 4'd0, 8'd118};   // 'v'
            8'd57: item = {2'd1, 4'd0, 8'd102};   // 'f'
            8'd58: item = {2'd1, 4'd0, 8'd61};   // '='
            8'd59: item = {2'd2, 4'd0, 8'd10};   // field 10: our own overflows (ring, drain, index FIFO)
            8'd60: item = {2'd1, 4'd0, 8'd32};   // ' '
            8'd61: item = {2'd1, 4'd0, 8'd104};   // 'h'
            8'd62: item = {2'd1, 4'd0, 8'd111};   // 'o'
            8'd63: item = {2'd1, 4'd0, 8'd118};   // 'v'
            8'd64: item = {2'd1, 4'd0, 8'd102};   // 'f'
            8'd65: item = {2'd1, 4'd0, 8'd61};   // '='
            8'd66: item = {2'd2, 4'd0, 8'd11};   // field 11: the HL2 own overflow count
            8'd67: item = {2'd1, 4'd0, 8'd32};   // ' '
            8'd68: item = {2'd1, 4'd0, 8'd102};   // 'f'
            8'd69: item = {2'd1, 4'd0, 8'd105};   // 'i'
            8'd70: item = {2'd1, 4'd0, 8'd108};   // 'l'
            8'd71: item = {2'd1, 4'd0, 8'd108};   // 'l'
            8'd72: item = {2'd1, 4'd0, 8'd61};   // '='
            8'd73: item = {2'd2, 4'd0, 8'd12};   // field 12: fill samples
            8'd74: item = {2'd1, 4'd0, 8'd32};   // ' '
            8'd75: item = {2'd1, 4'd0, 8'd112};   // 'p'
            8'd76: item = {2'd1, 4'd0, 8'd97};   // 'a'
            8'd77: item = {2'd1, 4'd0, 8'd116};   // 't'
            8'd78: item = {2'd1, 4'd0, 8'd61};   // '='
            8'd79: item = {2'd2, 4'd0, 8'd13};   // field 13: test pattern mismatches
            8'd80: item = {2'd1, 4'd0, 8'd32};   // ' '
            8'd81: item = {2'd1, 4'd0, 8'd115};   // 's'
            8'd82: item = {2'd1, 4'd0, 8'd98};   // 'b'
            8'd83: item = {2'd1, 4'd0, 8'd61};   // '='
            8'd84: item = {2'd3, 4'd2, 8'd14};   // field 14: transmit-safety byte
            8'd85: item = {2'd1, 4'd0, 8'd32};   // ' '
            8'd86: item = {2'd1, 4'd0, 8'd105};   // 'i'
            8'd87: item = {2'd1, 4'd0, 8'd112};   // 'p'
            8'd88: item = {2'd1, 4'd0, 8'd61};   // '='
            8'd89: item = {2'd3, 4'd8, 8'd15};   // field 15: the HL2's IP address
            8'd90: item = {2'd1, 4'd0, 8'd32};   // ' '
            8'd91: item = {2'd1, 4'd0, 8'd99};   // 'c'
            8'd92: item = {2'd1, 4'd0, 8'd107};   // 'k'
            8'd93: item = {2'd1, 4'd0, 8'd61};   // '='
            8'd94: item = {2'd3, 4'd2, 8'd16};   // field 16: clock chip register 0
            8'd95: item = {2'd1, 4'd0, 8'd32};   // ' '
            8'd96: item = {2'd1, 4'd0, 8'd116};   // 't'
            8'd97: item = {2'd1, 4'd0, 8'd114};   // 'r'
            8'd98: item = {2'd1, 4'd0, 8'd121};   // 'y'
            8'd99: item = {2'd1, 4'd0, 8'd61};   // '='
            8'd100: item = {2'd2, 4'd0, 8'd17};   // field 17: start-up attempts
            8'd101: item = {2'd1, 4'd0, 8'd32};   // ' '
            8'd102: item = {2'd1, 4'd0, 8'd105};   // 'i'
            8'd103: item = {2'd1, 4'd0, 8'd100};   // 'd'
            8'd104: item = {2'd1, 4'd0, 8'd61};   // '='
            8'd105: item = {2'd3, 4'd8, 8'd18};   // field 18: chip ID, high word
            8'd106: item = {2'd3, 4'd8, 8'd19};   // field 19: chip ID, low word
            8'd107: item = {2'd1, 4'd0, 8'd13};   // CR
            8'd108: item = {2'd1, 4'd0, 8'd10};   // LF
            8'd109: item = {2'd0, 4'd0, 8'd0};
            default: item = 14'd0;
        endcase
    endfunction

    // ---------------------------------------------------------------- UART transmitter
    // `tsh` holds the 10 bits of the character on the line (start bit 0, 8 data bits low bit first,
    // stop bit 1), `tn` the bits still to send, and `tdiv` counts the clocks within a bit. `tgo` is
    // the printer's request to send `tch`. The line changes at the start of each bit period.
    reg [9:0]  tsh = 10'h3FF;
    reg [3:0]  tn = 4'd0;
    reg [$clog2(BAUD_DIV+1)-1:0] tdiv = 0;
    wire       tbusy = (tn != 4'd0);
    reg        tgo = 1'b0;
    reg [7:0]  tch = 8'd0;
    always @(posedge clk) begin
        if (rst) begin tn <= 4'd0; txd <= 1'b1; end
        else if (tgo && !tbusy) begin tsh <= {1'b1, tch, 1'b0}; tn <= 4'd10; tdiv <= 0; end
        else if (tbusy) begin
            if (tdiv == 0) begin txd <= tsh[0]; tsh <= {1'b1, tsh[9:1]}; end
            if (tdiv == BAUD_DIV - 1) begin tdiv <= 0; tn <= tn - 4'd1; end else tdiv <= tdiv + 1'b1;
        end
    end

    // ---------------------------------------------------------------- printer
    // `ps` is the printer's state, `ip` the item being printed. `bin` and `bcd` hold the number
    // for the binary to decimal conversion, `di` the digit being sent.
    reg [NF*32-1:0] fl = {NF*32{1'b0}};
    reg [7:0]  ip = 8'd0;                  // item
    reg [2:0]  ps = 3'd0;                  // 0 idle, 1 item, 2 binary to BCD, 3 digits out, 4 wait UART
    reg [2:0]  ret = 3'd0;
    reg [31:0] bin = 32'd0;
    reg [39:0] bcd = 40'd0;
    reg [5:0]  step = 6'd0;
    reg [3:0]  di = 4'd0;                  // digit being sent (counting down)
    reg        dec = 1'b0, lead = 1'b0;
    wire [13:0] it = item(ip);
    wire [31:0] fv = fl[32*it[7:0] +: 32];

    // One double-dabble step: add 3 to every BCD digit at 5 or more, then shift left with the next binary bit.
    // The method turns a binary number into decimal digits with only adds and shifts: after 32
    // steps, `bcd` holds the ten decimal digits, four bits each, of the 32-bit value.
    function [39:0] dd(input [39:0] x);
        integer j;
        reg [39:0] y;
        begin
            y = x;
            for (j = 0; j < 10; j = j + 1) if (y[4*j +: 4] >= 4'd5) y[4*j +: 4] = y[4*j +: 4] + 4'd3;
            dd = y;
        end
    endfunction
    wire [39:0] bcd_dd = dd(bcd);
    wire [3:0] dig = dec ? bcd[4*di +: 4] : bin[4*di +: 4];
    wire [7:0] asc = (dig < 4'd10) ? (8'h30 + {4'd0, dig}) : (8'h57 + {4'd0, dig});   // 0-9, a-f

    always @(posedge clk) begin
        tgo <= 1'b0;
        if (rst) ps <= 3'd0;
        else case (ps)
            3'd0: if (tick) begin fl <= fields; ip <= 8'd0; ps <= 3'd1; end
            3'd1: case (it[13:12])
                      2'd0: ps <= 3'd0;
                      2'd1: begin tch <= it[7:0]; tgo <= 1'b1; ip <= ip + 8'd1; ret <= 3'd1; ps <= 3'd4; end
                      2'd2: begin bin <= fv; bcd <= 40'd0; step <= 6'd0; dec <= 1'b1; ps <= 3'd2; end
                      default: begin bin <= fv; dec <= 1'b0; di <= it[11:8] - 4'd1; lead <= 1'b0; ps <= 3'd3; end
                  endcase
            3'd2: begin
                bcd <= {bcd_dd[38:0], bin[31]};
                bin <= {bin[30:0], 1'b0};
                if (step == 6'd31) begin di <= 4'd9; lead <= 1'b1; ps <= 3'd3; end
                step <= step + 6'd1;
            end
            3'd3: begin
                // decimal: leading zeros left out, the last digit always sent
                if (lead && dig == 4'd0 && di != 4'd0) di <= di - 4'd1;
                else begin
                    lead <= 1'b0; tch <= asc; tgo <= 1'b1; ps <= 3'd4;
                    if (di == 4'd0) begin ret <= 3'd1; ip <= ip + 8'd1; end
                    else begin ret <= 3'd3; di <= di - 4'd1; end
                end
            end
            default: if (!tgo && !tbusy) ps <= ret;     // the character has left
        endcase
    end
endmodule
