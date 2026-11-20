// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Start-up sequencer of the minimal Hermes-Lite 2 test build (docs/HL2MIN.md): it brings the SFP
// transceiver up without a processor, by running in hardware the same steps that the firmware of
// the full radio runs (fw/tr-fabric/src/sfp.rs, docs/SFP_LINKS.md 2.3).
//
// Why this is needed: the transceiver of the chip needs a stable 125 MHz reference clock before
// its lane PLL can lock, and on the Tang Mega 138K Pro dock that clock comes from a programmable
// clock chip (an MS5351M, register compatible with the Si5351A) that is configured over I2C. I2C
// is a slow two-wire bus (a clock line SCL and a data line SDA, both open drain: a device can only
// pull a wire low and a resistor pulls it high again) on which a master addresses a chip by a 7-bit
// address, and then writes or reads bytes, each followed by an acknowledge bit from the receiver.
// The clock chip sits behind an I2C multiplexer, a switch chip that connects the bus to one of
// eight branches chosen by three select pins (N19, P19, P26), and branch 3 leads to it.
//
// The sequence, step by step:
//   1. Hold: both lanes in reset (pma_rstn 0), all four PCS resets high, the module's transmitter
//      off.
//   2. Select multiplexer channel 3 (N19 = 1, P19 = 1, P26 = 0, where N19 is select bit 0), and write
//      the MS5351M at I2C address 0x60 with the 40 register writes listed in `wr_item` below, which
//      set both of its PLLs to 750 MHz, divide outputs 0 and 1 by 6 (125 MHz, output 1 inverted),
//      reset the PLLs and switch the outputs on.
//   3. Wait 10 ms, then read the chip's register 0 every millisecond until its SYS_INIT and LOL_A
//      bits are clear (the chip has initialized and PLL A has locked), for at most 100 ms, and go on
//      anyway after that, as the firmware does.
//   4. Take both lanes out of reset (the lane reset holds the lane PLL too), with the PCS resets
//      still high, and wait up to 100 ms for lane 0's PLL to lock. If it does not lock, go back to
//      step 1 and try again, without limit (every attempt is counted in `attempts`).
//   5. Locked: take lane 0's PCS out of reset, enable the PCS, and switch the module's transmitter
//      on. Lane 1 stays with its PCS in reset (idle). While running, lane 0's receive side is reset
//      for a few milliseconds when it has had a signal but no aligner lock for 100 ms.
// With LANE = 1 (HL2MIN_LANE=1, the module in cage SFP1) everything is the same with the roles of
// the two lanes swapped: lane 1's PLL lock, lane 1's PCS released and reset, lane 0 idle with its
// PCS in reset.
// The build uses the default reset form of the quad (no por_n_i, docs/SFP_LINKS.md 2.4), and `por_n`
// is still driven for a build with the global reset form.
//
// I2C engine: open drain, about 100 kbit/s (QDIV clocks of `clk` per quarter of a bit), clock
// stretching honored (a slave may hold SCL low, for up to 1,024 clocks). A byte without
// acknowledge sets `i2c_nack` (shown on the UART line) and the sequence goes on.

`timescale 1ns / 1ps

module hl2min_clkseq #(
    parameter integer CLK_HZ = 50_000_000,   // frequency of clk, used for the millisecond tick
    parameter integer QDIV   = 125,         // clocks per quarter of an I2C bit: 50 MHz / 125 / 4 = 100 kHz
    parameter integer LANE   = 0            // the lane of the HL2 (HL2MIN_LANE): its PCS is released, the other's not
) (
    input  wire       clk,                  // 50 MHz board clock
    input  wire       rst,                  // synchronous reset, active high
    // I2C pins: 0 = pull low
    output reg        scl_o = 1'b1,         // SCL level to drive (0 pulls the wire low, 1 lets go)
    output reg        sda_o = 1'b1,         // SDA level to drive
    input  wire       scl_i,                // SCL as seen on the pin
    input  wire       sda_i,                // SDA as seen on the pin
    output wire       sel_n19,              // multiplexer select bit 0
    output wire       sel_p19,              // bit 1
    output wire       sel_p26,              // bit 2
    // transceiver (levels)
    output reg        por_n = 1'b0,         // power-on reset of the transceiver quad, active low
    output reg  [1:0] ln_rst_n = 2'b00,     // lane resets (the lane PLL included), active low, per lane
    output reg  [1:0] ln_rx_rst = 2'b11,    // PCS receive resets, active high, per lane
    output reg  [1:0] ln_tx_rst = 2'b11,    // PCS transmit resets, active high, per lane
    input  wire       ln0_pll_lock,         // asynchronous; of the lane LANE (named for lane 0, the default)
    input  wire       ln0_signal,           // asynchronous
    input  wire       ln0_aligned,          // asynchronous (the aligner in the recovered clock)
    output reg        pcs_enable = 1'b0,    // the PCS may run (negotiate and send)
    output reg        sfp0_tx_disable = 1'b1,   // the cage of lane LANE: 1 = its module's transmitter off
    // status
    output reg  [2:0] phase = 3'd0,         // 0 hold, 1 I2C, 2 reference wait, 3 lock wait, 4 running
    output reg        i2c_nack = 1'b0,      // a byte was not acknowledged (sticky)
    output reg  [7:0] chip_status = 8'hFF,  // the clock chip's register 0, last read
    output reg  [15:0] attempts = 16'd0,    // start-up attempts (more than 1 means the lane PLL did not lock at once)
    output reg  [15:0] rx_resets = 16'd0    // times the receive side was reset for lack of aligner lock
);
    assign sel_n19 = 1'b1;                 // channel 3: N19 = 1, P19 = 1, P26 = 0 (N19 is the least significant)
    assign sel_p19 = 1'b1;
    assign sel_p26 = 1'b0;

    // ---------------------------------------------------------------- synchronizers
    // The lock, signal and aligner flags and the two I2C inputs come from other clocks or from the
    // pins, so each goes through three flip-flops before the sequencer uses it.
    reg [2:0] s_lock = 3'd0, s_sig = 3'd0, s_al = 3'd0, s_scl = 3'd7, s_sda = 3'd7;
    always @(posedge clk) begin
        s_lock <= {s_lock[1:0], ln0_pll_lock}; s_sig <= {s_sig[1:0], ln0_signal}; s_al <= {s_al[1:0], ln0_aligned};
        s_scl <= {s_scl[1:0], scl_i}; s_sda <= {s_sda[1:0], sda_i};
    end
    wire lock = s_lock[2], sig = s_sig[2], al = s_al[2], scl_in = s_scl[2], sda_in = s_sda[2];

    // ---------------------------------------------------------------- the register writes (fw/tr-fabric/src/sfp.rs)
    // The order of the firmware's program_clock_chip: the first 36 writes of its 125 MHz table,
    // then its output setting, then the last two of the table. Each item is {register, value}.
    // What they do, in the register map of the Si5351A (which the MS5351M follows):
    //   item 0        register 3 = 0xFF: all outputs disabled while the chip is set up
    //   items 1 to 3  registers 16, 17, 18 = 0x80: clock outputs 0, 1 and 2 powered down
    //   items 4 to 11 registers 26 to 33: PLL A's feedback multisynth. Its divider is 30 (the
    //                 25 MHz crystal times 30 gives 750 MHz), stored as P1 = 128 x 30 - 512 =
    //                 3,328 = 0x0D00 (registers 29 and 30) and P3 = 1 (registers 26 and 27), so
    //                 the fraction is 0 / 1
    //   items 12 to 19 registers 34 to 41: the same for PLL B
    //   items 20 to 27 registers 42 to 49: output multisynth 0 divides by 6, stored as
    //                 P1 = 128 x 6 - 512 = 256 = 0x0100 (register 45), so 750 MHz / 6 = 125 MHz
    //   items 28 to 35 registers 50 to 57: the same for output multisynth 1
    //   items 36, 37  registers 16 and 17 = 0x4F and 0x5F: outputs 0 and 1 powered up, integer
    //                 mode, fed by their multisynth at full drive, and output 1 inverted (0x5F has
    //                 the invert bit set)
    //   item 38       register 177 = 0xA0: reset PLL A and PLL B so that they lock to the new settings
    //   item 39       register 3 = 0xFC: outputs 0 and 1 enabled (a zero bit enables)
    function [15:0] wr_item(input [5:0] i);
        case (i)
            6'd0:  wr_item = {8'd3,   8'hFF};
            6'd1:  wr_item = {8'd16,  8'h80};
            6'd2:  wr_item = {8'd17,  8'h80};
            6'd3:  wr_item = {8'd18,  8'h80};
            6'd4:  wr_item = {8'd26,  8'h00};
            6'd5:  wr_item = {8'd27,  8'h01};
            6'd6:  wr_item = {8'd28,  8'h00};
            6'd7:  wr_item = {8'd29,  8'h0D};
            6'd8:  wr_item = {8'd30,  8'h00};
            6'd9:  wr_item = {8'd31,  8'h00};
            6'd10: wr_item = {8'd32,  8'h00};
            6'd11: wr_item = {8'd33,  8'h00};
            6'd12: wr_item = {8'd34,  8'h00};
            6'd13: wr_item = {8'd35,  8'h01};
            6'd14: wr_item = {8'd36,  8'h00};
            6'd15: wr_item = {8'd37,  8'h0D};
            6'd16: wr_item = {8'd38,  8'h00};
            6'd17: wr_item = {8'd39,  8'h00};
            6'd18: wr_item = {8'd40,  8'h00};
            6'd19: wr_item = {8'd41,  8'h00};
            6'd20: wr_item = {8'd42,  8'h00};
            6'd21: wr_item = {8'd43,  8'h01};
            6'd22: wr_item = {8'd44,  8'h00};
            6'd23: wr_item = {8'd45,  8'h01};
            6'd24: wr_item = {8'd46,  8'h00};
            6'd25: wr_item = {8'd47,  8'h00};
            6'd26: wr_item = {8'd48,  8'h00};
            6'd27: wr_item = {8'd49,  8'h00};
            6'd28: wr_item = {8'd50,  8'h00};
            6'd29: wr_item = {8'd51,  8'h01};
            6'd30: wr_item = {8'd52,  8'h00};
            6'd31: wr_item = {8'd53,  8'h01};
            6'd32: wr_item = {8'd54,  8'h00};
            6'd33: wr_item = {8'd55,  8'h00};
            6'd34: wr_item = {8'd56,  8'h00};
            6'd35: wr_item = {8'd57,  8'h00};
            6'd36: wr_item = {8'd16,  8'h4F};      // CLOCK_CHIP_OUTPUTS
            6'd37: wr_item = {8'd17,  8'h5F};
            6'd38: wr_item = {8'd177, 8'hA0};      // PLL reset
            default: wr_item = {8'd3, 8'hFC};      // 39: outputs 0 and 1 on
        endcase
    endfunction
    localparam [5:0] N_WR = 6'd40;      // number of register writes
    localparam [1:0] PCS_RUN = (LANE == 1) ? 2'b01 : 2'b10;     // PCS resets while running: the idle lane's stays high
    localparam [7:0] DEV_W = 8'hC0, DEV_R = 8'hC1;   // 0x60 << 1, with the read/write bit 0 or 1

    // ---------------------------------------------------------------- I2C bit engine
    // The engine does one thing at a time, chosen by `cmd`, when `go` is pulsed, and `busy` is high
    // until it has finished. A bit takes four quarter periods (`q` counts 0 to 3, each lasting QDIV
    // clocks): data is put on SDA in quarter 0, SCL rises at the end of quarter 1 and is sampled in
    // quarter 2, and falls at the end of quarter 3.
    // commands: 0 start, 1 stop, 2 write byte (then read the acknowledge), 3 read byte (then send not-acknowledge)
    reg [1:0]  cmd = 2'd0;
    reg        go = 1'b0, busy = 1'b0;
    reg [7:0]  sh = 8'd0;               // the engine's shift register
    reg [7:0]  wb = 8'd0;               // the byte to write, from the sequence
    reg [3:0]  nbit = 4'd0;             // bit counter within a byte (0 to 7 data, 8 acknowledge)
    reg [1:0]  q = 2'd0;                // quarter of the current bit
    reg [$clog2(QDIV+1)-1:0] qc = 0;    // clocks within the quarter
    reg [10:0] stretch = 11'd0;         // clocks a slave has held SCL low (clock stretching)
    reg        ack_bad = 1'b0;          // the last written byte was not acknowledged
    wire       qtick = (qc == QDIV - 1);
    // the bit now: for write, 8 data bits then the acknowledge read (released); for read, 8 released then NACK (1)
    wire       wbit  = (cmd == 2'd2) ? ((nbit < 4'd8) ? sh[7] : 1'b1) : 1'b1;
    always @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0; scl_o <= 1'b1; sda_o <= 1'b1; qc <= 0; q <= 2'd0;
        end else if (go && !busy) begin
            busy <= 1'b1; q <= 2'd0; qc <= 0; nbit <= 4'd0; stretch <= 11'd0; sh <= wb;
        end else if (busy) begin
            // SCL rises at the end of quarter 1; quarter 2 waits while a slave holds it low
            if (q == 2'd2 && scl_o && !scl_in && !stretch[10]) stretch <= stretch + 11'd1;   // slave holds SCL
            else if (qtick) begin
                qc <= 0; q <= q + 2'd1;
                case (cmd)
                    2'd0: case (q)                                   // start (also a repeated start)
                              2'd0: sda_o <= 1'b1;
                              2'd1: scl_o <= 1'b1;
                              2'd2: sda_o <= 1'b0;
                              default: begin scl_o <= 1'b0; busy <= 1'b0; end
                          endcase
                    2'd1: case (q)                                   // stop
                              2'd0: sda_o <= 1'b0;
                              2'd1: scl_o <= 1'b1;
                              2'd2: sda_o <= 1'b1;
                              default: busy <= 1'b0;
                          endcase
                    default: case (q)                                // one bit of a byte (9 per byte)
                              2'd0: sda_o <= wbit;
                              2'd1: begin scl_o <= 1'b1; stretch <= 11'd0; end
                              2'd2: begin
                                  if (nbit == 4'd8) begin
                                      if (cmd == 2'd2) ack_bad <= sda_in;
                                  end else if (cmd == 2'd3) sh <= {sh[6:0], sda_in};
                                  else sh <= {sh[6:0], 1'b0};
                              end
                              default: begin
                                  scl_o <= 1'b0;
                                  if (nbit == 4'd8) busy <= 1'b0; else nbit <= nbit + 4'd1;
                              end
                          endcase
                endcase
            end else qc <= qc + 1'b1;
        end
    end

    // ---------------------------------------------------------------- sequence
    // A millisecond tick from the 50 MHz clock, and the states of the start-up sequence.
    localparam integer MS = CLK_HZ / 1000;
    reg [$clog2(MS+1)-1:0] msc = 0;
    reg        ms_tick = 1'b0;
    always @(posedge clk) begin ms_tick <= (msc == MS - 1); msc <= (msc == MS - 1) ? 0 : msc + 1'b1; end

    // States: HOLD (step 1), WR (the register writes of step 2), REFWAIT (the 10 ms wait), POLL and
    // POLLGAP (reading register 0 until the chip is ready, with a millisecond between reads), LOCK
    // (waiting for the lane PLL), RUN (step 5). S_DONE_WAIT is not used.
    localparam [3:0] S_HOLD = 4'd0, S_WR = 4'd1, S_REFWAIT = 4'd2, S_POLL = 4'd3, S_POLLGAP = 4'd4,
                     S_LOCK = 4'd5, S_RUN = 4'd6, S_DONE_WAIT = 4'd7;
    reg [3:0]  st = S_HOLD;
    reg [5:0]  wi = 6'd0;           // register write
    reg [3:0]  ui = 4'd0;           // micro step inside a transaction
    reg [7:0]  ms = 8'd0;           // milliseconds in this state
    reg [7:0]  ref_ms = 8'd0;       // milliseconds since the reference wait began
    reg [6:0]  unal_ms = 7'd0;      // milliseconds without aligner lock while a signal is there
    reg [1:0]  rxr_ms = 2'd0;       // milliseconds the receive side has been held in reset
    wire       idle = !busy && !go;
    wire [15:0] wit = wr_item(wi);

    // one transaction step: issue `c` with byte `b`, then advance ui
    task issue(input [1:0] c, input [7:0] b);
        begin cmd <= c; wb <= b; go <= 1'b1; ui <= ui + 4'd1; end
    endtask

    always @(posedge clk) begin
        go <= 1'b0;
        if (rst) begin
            st <= S_HOLD; por_n <= 1'b0; ln_rst_n <= 2'b00; ln_rx_rst <= 2'b11; ln_tx_rst <= 2'b11;
            pcs_enable <= 1'b0; sfp0_tx_disable <= 1'b1; phase <= 3'd0; ms <= 8'd0;
            attempts <= 16'd0; rx_resets <= 16'd0; i2c_nack <= 1'b0;
        end else begin
            if (ms_tick && ms != 8'hFF) ms <= ms + 8'd1;
            if (ms_tick && ref_ms != 8'hFF) ref_ms <= ref_ms + 8'd1;
            if (idle && ack_bad && (cmd == 2'd2)) i2c_nack <= 1'b1;
            case (st)
                S_HOLD: begin
                    phase <= 3'd0; por_n <= 1'b0; ln_rst_n <= 2'b00; ln_rx_rst <= 2'b11; ln_tx_rst <= 2'b11;
                    pcs_enable <= 1'b0; sfp0_tx_disable <= 1'b1;
                    if (ms >= 8'd5) begin st <= S_WR; wi <= 6'd0; ui <= 4'd0; attempts <= attempts + 16'd1; end
                end
                // One register write is: start, device address with the write bit, register
                // number, value, stop (ui 0 to 4), then the next item.
                S_WR: if (idle) begin
                    phase <= 3'd1;
                    case (ui)
                        4'd0: issue(2'd0, 8'd0);
                        4'd1: issue(2'd2, DEV_W);
                        4'd2: issue(2'd2, wit[15:8]);
                        4'd3: issue(2'd2, wit[7:0]);
                        4'd4: issue(2'd1, 8'd0);
                        default: begin
                            ui <= 4'd0;
                            if (wi == N_WR - 6'd1) begin st <= S_REFWAIT; ms <= 8'd0; ref_ms <= 8'd0; end
                            else wi <= wi + 6'd1;
                        end
                    endcase
                end
                S_REFWAIT: begin
                    phase <= 3'd2;
                    if (ms >= 8'd10) begin st <= S_POLL; ui <= 4'd0; end
                end
                // Reading register 0 is: start, device address with the write bit, register
                // number 0, a repeated start, device address with the read bit, read one byte,
                // stop. The chip is ready when SYS_INIT (bit 7) and LOL_A (bit 5) are both clear
                // (mask 0xA0), or after 100 ms anyway.
                S_POLL: if (idle) begin                     // read register 0
                    case (ui)
                        4'd0: issue(2'd0, 8'd0);
                        4'd1: issue(2'd2, DEV_W);
                        4'd2: issue(2'd2, 8'd0);
                        4'd3: issue(2'd0, 8'd0);
                        4'd4: issue(2'd2, DEV_R);
                        4'd5: issue(2'd3, 8'hFF);
                        4'd6: begin chip_status <= sh; issue(2'd1, 8'd0); end
                        default: begin
                            ui <= 4'd0; ms <= 8'd0;
                            if (((chip_status & 8'hA0) == 8'd0) || (ref_ms >= 8'd100)) begin
                                st <= S_LOCK; por_n <= 1'b1; ln_rst_n <= 2'b11;   // lanes run, PCS still in reset
                            end else st <= S_POLLGAP;
                        end
                    endcase
                end
                S_POLLGAP: if (ms >= 8'd1) st <= S_POLL;
                S_LOCK: begin
                    phase <= 3'd3;
                    if (lock) begin
                        st <= S_RUN; ln_rx_rst <= PCS_RUN; ln_tx_rst <= PCS_RUN; pcs_enable <= 1'b1;
                        sfp0_tx_disable <= 1'b0; unal_ms <= 7'd0;
                    end else if (ms >= 8'd100) begin st <= S_HOLD; ms <= 8'd0; end
                end
                // Running: if a signal is there but the aligner has found no lock for 100 ms, reset
                // the receive side for a few milliseconds and try again.
                S_RUN: begin
                    phase <= 3'd4;
                    ln_tx_rst <= PCS_RUN;
                    if (ln_rx_rst[LANE]) begin
                        if (ms_tick) rxr_ms <= rxr_ms + 2'd1;
                        if (rxr_ms == 2'd2) begin ln_rx_rst <= PCS_RUN; unal_ms <= 7'd0; end
                    end else if (al || !sig) unal_ms <= 7'd0;
                    else if (ms_tick) begin
                        if (unal_ms == 7'd100) begin
                            ln_rx_rst <= 2'b11; rxr_ms <= 2'd0; rx_resets <= rx_resets + 16'd1;
                        end else unal_ms <= unal_ms + 7'd1;
                    end
                end
                default: st <= S_HOLD;
            endcase
        end
    end
endmodule
