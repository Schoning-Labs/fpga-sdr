// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Reads the chip's factory identification number (a 64-bit "DNA", unique to every Gowin chip) through Gowin's
// OTP (one time programmable memory) primitive, so that several boards on one network can tell themselves
// apart. rtl/net/net_unit.v shows it in its register page, and the minimal test build prints it on its status
// line. docs/NET_ID.md says how the number is used.
//
// How the read works, from the Gowin Primitives User Guide SUG283-3.6.1E section 8.9 (Arora V and Arora III):
// MODE 2'b01 reads the DNA. READ is a pulse of at least one CLK cycle that loads the 128-bit eFuse register into the
// shift register. Then READ goes low and SHIFT goes high, and the 128 bits are shifted out on DOUT, lowest bit
// first, one per CLK. In mode 01, bits 95 to 32 are the valid data (64 bits). The guide gives no clock limit for this
// device (the serial OTP of the GW2AN asks for 2.5 MHz), so CLK here is a register toggling every 16 clocks (clk / 32:
// 1.2 to 4.7 MHz for a clk of 38 to 150 MHz). READ and SHIFT change at CLK's falling edge and DOUT is sampled 15
// clocks after one edge, so the alignment of bit 0 to the first CLK edge does not matter for the sampling instant.
// The guide's timing diagram does not show where the first bit sits, and it has been found by reading the chip:
// raw[0] is DOUT before the first rising edge with SHIFT high and is register bit 0, and raw[1 + k] is the sample
// after edge k, which is register bit 1 + k. So the ID is raw[95:32].
//
// The read runs once after the reset (about 150 us). The state machine `st` is 0 wait (8 periods), 1 READ high (2
// periods), 2 one gap period, 3 shift out (128 periods), 4 done. `done` goes high when raw is complete.

`default_nettype none
module chip_dna (
    input  wire        clk,
    input  wire        rst,          // synchronous reset, active high
    output reg  [128:0] raw,         // raw[k] = register bit k (raw[0] pre-edge sample); raw[128] one bit past the register
    output reg         done          // the read is complete and raw is valid
);
    // The three control signals of the OTP primitive: its own slow clock, READ and SHIFT. DOUT is the data
    // bit, brought into clk through two registers (dq1, dq2).
    reg        otp_clk = 1'b0, otp_read = 1'b0, otp_shift = 1'b0;
    wire       dout;
    OTP #(.MODE(2'b01)) u_otp (.DOUT(dout), .CLK(otp_clk), .READ(otp_read), .SHIFT(otp_shift));
    reg [4:0]  cnt = 5'd0;           // otp_clk high from count 16 to 31
    reg [2:0]  st = 3'd0;            // state, see the header
    reg [7:0]  n = 8'd0;             // periods counted in the state, or bits shifted in
    reg        first = 1'b1;        // the pre-edge sample (raw[0]) has not been taken yet
    reg        dq1 = 1'b0, dq2 = 1'b0;
    always @(posedge clk) begin
        dq1 <= dout; dq2 <= dq1;
        cnt <= cnt + 5'd1;
        if (cnt == 5'd15) otp_clk <= 1'b1;
        if (cnt == 5'd31) otp_clk <= 1'b0;
        if (rst) begin
            cnt <= 5'd0; otp_clk <= 1'b0; otp_read <= 1'b0; otp_shift <= 1'b0; st <= 3'd0; n <= 8'd0; first <= 1'b1;
            done <= 1'b0; raw <= 129'd0;
        end else begin
            // state changes at count 0 (CLK falling edge)
            if (cnt == 5'd0) begin
                case (st)
                    3'd0: begin n <= n + 8'd1; if (n == 8'd7) begin n <= 8'd0; st <= 3'd1; otp_read <= 1'b1; end end   // wait 8 periods
                    3'd1: begin n <= n + 8'd1; if (n == 8'd1) begin n <= 8'd0; st <= 3'd2; otp_read <= 1'b0; end end   // READ high 2 periods
                    3'd2: begin st <= 3'd3; otp_shift <= 1'b1; n <= 8'd0; first <= 1'b1; end                            // one gap period
                    default: ;
                endcase
            end
            if (st == 3'd3) begin
                if (first && cnt == 5'd15) begin raw <= {dq2, raw[128:1]}; first <= 1'b0; end   // before the first rising edge
                if (cnt == 5'd31) begin
                    raw <= {dq2, raw[128:1]}; n <= n + 8'd1;
                    if (n == 8'd127) begin st <= 3'd4; otp_shift <= 1'b0; done <= 1'b1; end
                end
            end
        end
    end
endmodule
`default_nettype wire
