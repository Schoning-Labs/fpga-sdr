// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// usbh_regs: the register page 0x0F `usbh` (hw/regmap/usbh.toml, docs/USB_HOST.md section 7) of the USB host, in clk_dsp,
// behind a regbus_leg (rtl/top/regbus_leg.v): strobes bus_wr / bus_rd for one clock, address and write data held until the next
// access to this page; the decode is registered (as rtl/usb/usb_regs.v), so a write lands one clock after its
// strobe and read data stands two clocks after it.
//
// It is the firmware's window on the USB host: the firmware does what needs a table or happens once per plug-in (reset, enumeration,
// descriptors, class drivers) by writing and reading these registers, and the logic in usbh_port.v does everything with a
// deadline (frames, transactions, retries). The page has three address ranges, selected by bus_addr[15:8]: 0x00 the registers of both
// ports together (id, swap and interrupt enables, speaker and microphone settings, counters), 0x01 port 0 and 0x02 port 1, whose registers
// (in word steps of 4 bytes) are 0 port control (mode, speed, device address), 1 port status, 2 transaction, 3 receive FIFO pop, 4 and 5 the two
// interrupt slots, 8 receive FIFO level, and whose offset 0x40 to 0x7F is the send buffer (16 words, 64 bytes) that holds the data of
// a SETUP or OUT transaction. Exact bit fields are in the generated header hw/regmap/generated/usbh_regs.vh and usbh.toml.
// A transaction is started by one write to the transaction register, which loads kind, endpoint, toggle, length and NAK limit
// together and flips the start toggle; the firmware then waits for the done flag (a status bit, or interrupt line 13) and reads
// the result.
//
// Two registers per port have a side effect on a read, so their value is copied at the read strobe:
//   port_status   the read clears ev_line and ev_done
//   rx_pop        the oldest word of the receive FIFO; the read takes it out
//
// To the 48 MHz clock (rtl/usbh/usbh_port.v takes them through its own registers): the settings are held here
// and a transaction is started by the toggle go_t, flipped by the write to `xfer` that also loads its fields.
// From the 48 MHz clock: done_t (a toggle, three registers here; x_res has stood since before it flipped),
// the line state, `gone` and the slot faults (two registers each; the lines also have to hold still for 65,536
// clocks, 0.5 ms), and the frame number and the speaker fill, which are read-outs only and are taken when two
// samples in a row agree. This is the usual way over a clock boundary that has no FIFO: a value that holds still is read after it has
// been stable for a while, a single bit goes through two registers, and an event goes as a toggle through three registers whose last two are compared.
//
// Gowin specifics: ordinary logic on the 120 MHz clock; the syn_preserve registers are the crossing registers, which must not be merged or
// retimed by the tool. The send buffers and the receive FIFOs themselves are in usbh_top.v. Terms are in docs/learn/GLOSSARY.md.

`timescale 1ns / 1ps
`include "hw/regmap/generated/usbh_regs.vh"

module usbh_regs (
    input  wire        clk,  // register clock, 120 MHz
    input  wire        rst,  // synchronous reset
    // register bus from the regbus_leg of this page: write and read strobes (one clock), the 16-bit offset inside the page, the write data, the data read
    input  wire        bus_wr,
    input  wire        bus_rd,
    input  wire [15:0] bus_addr,
    input  wire [31:0] bus_wdata,
    output reg  [31:0] bus_rdata = 32'd0,
    output reg         irq = 1'b0,  // interrupt, line 13: a record waits, a transaction is done or a line changed, each with its own enable
    // both ports
    output reg         swap = 1'b0,  // 1 = the two wires of the pads are exchanged (which pad of a port is D+ depends on how the board is plugged in)
    output reg  [13:0] spk = 14'h3000,        // speaker settings, as the register: bit 0 enable, 1 port, 5:2 endpoint, 6 mono, 7 3-byte samples, 13:8 most samples per frame (48 after reset)
    output reg  [7:0]  mic = 8'd0,  // microphone settings: bit 0 enable, 1 port, 5:2 endpoint, 6 mono, 7 3-byte samples
    input  wire [7:0]  spk_fill_u,  // samples waiting in the speaker FIFO (from the 48 MHz clock, read-out only)
    input  wire        ev_spk_over,           // one-clock pulse: a speaker sample was dropped (this clock)
    input  wire        ev_mic_bad_t_u,  // toggle from the 48 MHz clock: a bad microphone packet was dropped
    input  wire [31:0] mic_count,             // samples passed on by the microphone path (this clock)
    // per port (bit or slice p), settings to the 48 MHz clock
    output wire [5:0]  mode,  // 3 bits per port: 0 off, 1 reset (SE0), 2 run, 3 suspend, 4 resume
    output wire [1:0]  ls,  // 1 bit per port: 1 = low-speed device
    output wire [13:0] addr,  // 7 bits per port: device address
    output wire [1:0]  go_t,  // 1 bit per port: start toggle of the transaction
    output wire [47:0] xfer,                  // per port 24 bits, as the register: kind (2), endpoint (4), data toggle, length (7), NAK limit (8) in bits 15:0 and 23:16
    input  wire [1:0]  done_t_u,  // toggle from the 48 MHz clock, one per port: a transaction ended
    input  wire [5:0]  x_res_u,  // 3 bits per port: the transaction's result code
    output wire [51:0] slot,                  // port 0 slot 0, slot 1, port 1 slot 0, slot 1; 13 bits each (enable, endpoint, interval), as the register
    input  wire [3:0]  slot_err_u,  // per slot, from the 48 MHz clock: stopped by a fault
    input  wire [1:0]  line_dp_u,  // D+ of each port after the synchronizer (48 MHz clock)
    input  wire [1:0]  line_dn_u,  // D- of each port after the synchronizer (48 MHz clock)
    input  wire [1:0]  gone_u,  // per port: the device was pulled out
    input  wire [21:0] frame_u,  // frame numbers of the two ports, 11 bits each
    // receive FIFOs, read side (clk)
    input  wire [17:0] rf_data,  // the oldest word of each FIFO, 9 bits per port
    input  wire [21:0] rf_avail,  // words in each FIFO, 11 bits per port
    output wire [1:0]  rf_pop,  // one-clock pulse per port: take the oldest word out
    // send buffers, write side (clk)
    output reg  [1:0]  tx_we = 2'b00,  // one-clock pulse per port: write tx_wd to word tx_wa
    output reg  [3:0]  tx_wa = 4'd0,  // word address in the send buffer (0 to 15)
    output reg  [31:0] tx_wd = 32'd0  // the word to write
) /* synthesis syn_maxfan = 10000 syn_srlstyle = "registers" */;

    // ---------------------------------------------------------------- bus decode (one clock after the strobe)
    // wr_d, rd_d: the strobes one clock later. a_glob: the address is in the common range; a_port: in the range of port 0 or 1; a_tx: it is in the
    // send buffer; a_lo: the low byte of the address. They are registered to keep the decode short.
    reg        wr_d = 1'b0, rd_d = 1'b0;
    reg        a_glob = 1'b0, a_tx = 1'b0;
    reg [1:0]  a_port = 2'b00;
    reg [7:0]  a_lo = 8'd0;
    always @(posedge clk) begin
        wr_d   <= bus_wr;
        rd_d   <= bus_rd;
        a_glob <= (bus_addr[15:8] == 8'h00);
        a_port <= {bus_addr[15:8] == 8'h02, bus_addr[15:8] == 8'h01};
        a_tx   <= (bus_addr[7:6] == 2'b01);
        a_lo   <= bus_addr[7:0];
    end

    // ---------------------------------------------------------------- crossings from the 48 MHz clock
    // dn_s0, dn_s1: the done toggle of each port through three registers. bad_s: the microphone toggle. st_a, st_b: the status bits
    // through two registers. ro_a, ro_b, ro: the slowly changing read-outs (frame numbers, speaker fill) taken when two samples agree.
    reg [2:0]  dn_s0 = 3'd0, dn_s1 = 3'd0 /* synthesis syn_preserve = 1 */;
    reg [2:0]  bad_s = 3'd0 /* synthesis syn_preserve = 1 */;
    reg [9:0]  st_a = 10'd0, st_b = 10'd0 /* synthesis syn_preserve = 1 */;
    reg [29:0] ro_a = 30'd0, ro_b = 30'd0, ro = 30'd0;
    always @(posedge clk) begin
        dn_s0 <= {dn_s0[1:0], done_t_u[0]};
        dn_s1 <= {dn_s1[1:0], done_t_u[1]};
        bad_s <= {bad_s[1:0], ev_mic_bad_t_u};
        st_a  <= {slot_err_u, gone_u, line_dn_u, line_dp_u};
        st_b  <= st_a;
        ro_a  <= {spk_fill_u, frame_u};
        ro_b  <= ro_a;
        if (ro_a == ro_b) ro <= ro_b;
    end
    // A transaction is done in the clock in which the last two toggle registers differ; likewise a bad microphone packet.
    wire [1:0] done_p = {dn_s1[2] ^ dn_s1[1], dn_s0[2] ^ dn_s0[1]};
    wire       ev_mic_bad = bad_s[2] ^ bad_s[1];

    // Counters for the two events that need one here: dropped speaker samples (8 bits) and bad microphone packets (16 bits).
    reg [7:0]  n_spk_over = 8'd0;
    reg [15:0] n_mic_bad = 16'd0;
    always @(posedge clk) begin
        if (rst) begin
            n_spk_over <= 8'd0; n_mic_bad <= 16'd0;
        end else begin
            if (ev_spk_over) n_spk_over <= n_spk_over + 8'd1;
            if (ev_mic_bad)  n_mic_bad  <= n_mic_bad + 16'd1;
        end
    end

    // ---------------------------------------------------------------- per port
    // irq_en: interrupt enables (record waiting, transaction done, line change). rd_p: each port's read data. irq_p: each port's interrupt.
    reg  [2:0] irq_en = 3'd0;
    wire [31:0] rd_p [0:1];
    wire [1:0]  irq_p;
    genvar p;
    generate for (p = 0; p < 2; p = p + 1) begin : port
    // Per port: sel = this port's range is addressed. line = {gone, D-, D+} from the 48 MHz clock. line_c: the candidate, line_f: the
    // value that has held still long enough (hold counts up to 65,535 clocks, about 0.5 ms), which is what the firmware sees as
    // the line state. busy: a transaction is running. ev_line, ev_done: events for the firmware. result: the last result code.
    // stat_copy, pop_copy: values copied at a read. mode_r, ls_r, go_r, addr_r, xfer_r, s0_r, s1_r: the registers written by the firmware.
        wire        sel = a_port[p];
        wire [2:0]  line = {st_b[4 + p], st_b[2 + p], st_b[p]};      // gone, dn, dp
        reg  [2:0]  line_c = 3'd0, line_f = 3'd0;
        reg  [15:0] hold = 16'd0;
        reg         busy = 1'b0, ev_line = 1'b0, ev_done = 1'b0;
        reg  [2:0]  result = 3'd0;
        reg  [31:0] stat_copy = 32'd0, pop_copy = 32'd0;
        reg  [2:0]  mode_r = 3'd0;
        reg         ls_r = 1'b0, go_r = 1'b0, pop_r = 1'b0;
        reg  [6:0]  addr_r = 7'd0;
        reg  [23:0] xfer_r = 24'd0;
        reg  [12:0] s0_r = 13'h140, s1_r = 13'h140;
        // Outputs to the port logic; the interrupt slots' reset value 13'h140 is endpoint 0, interval 10 ms, not enabled.
        assign mode[3 * p +: 3]   = mode_r;
        assign ls[p]              = ls_r;
        assign addr[7 * p +: 7]   = addr_r;
        assign go_t[p]            = go_r;
        assign xfer[24 * p +: 24] = xfer_r;
        assign slot[26 * p +: 26] = {s1_r, s0_r};
        assign rf_pop[p]          = pop_r;
        // avail: words in this port's receive FIFO. stat: the port status register, {frame number (bits 26:16), slot faults (11:10), ev_done, ev_line,
        // rx_any, result, busy, line_f}. irq_p: an interrupt when an enabled event is pending.
        wire [10:0] avail = rf_avail[11 * p +: 11];
        wire        rx_any = (avail != 11'd0);
        wire [31:0] stat = {5'd0, ro[11 * p +: 11], 4'd0, st_b[6 + 2 * p +: 2], ev_done, ev_line, rx_any,
                            result, busy, line_f};
        assign irq_p[p] = (irq_en[0] && rx_any) || (irq_en[1] && ev_done) || (irq_en[2] && ev_line);

        always @(posedge clk) begin
            pop_r <= 1'b0;
            // The line state counts only when it has held still: a change restarts the wait, and a settled new value is
            // reported with ev_line.
            if (line != line_c) begin
                line_c <= line;
                hold   <= 16'd0;
            end else if (hold != 16'hFFFF) begin
                hold <= hold + 16'd1;
            end else if (line_f != line_c) begin
                line_f  <= line_c;
                ev_line <= 1'b1;
            end
            // A transaction finished: the result code is taken and the done flag is raised.
            if (done_p[p]) begin
                busy    <= 1'b0;
                ev_done <= 1'b1;
                result  <= x_res_u[3 * p +: 3];
            end
            if (rst) begin
                mode_r <= 3'd0;
                ls_r   <= 1'b0;
                addr_r <= 7'd0;
                s0_r   <= 13'h140;
                s1_r   <= 13'h140;
                busy <= 1'b0; ev_line <= 1'b0; ev_done <= 1'b0;
            end else begin
                // Writes to the port's registers: control (mode, speed, address), the transaction (which also starts it, sets busy and
                // clears the done flag), and the two interrupt slots.
                if (wr_d && sel && !a_tx) begin
                    case (a_lo[5:2])
                        4'd0: begin
                            mode_r <= bus_wdata[2:0];
                            ls_r   <= bus_wdata[3];
                            addr_r <= bus_wdata[10:4];
                        end
                        4'd2: begin
                            xfer_r  <= bus_wdata[23:0];
                            go_r    <= ~go_r;
                            busy    <= 1'b1;
                            ev_done <= 1'b0;
                        end
                        4'd4: s0_r <= bus_wdata[12:0];
                        4'd5: s1_r <= bus_wdata[12:0];
                        default: ;
                    endcase
                end
                // Reading the status copies it first and then clears the two event flags; reading the pop register copies the oldest word and takes it out.
                if (rd_d && sel && !a_tx && a_lo[5:2] == 4'd1) begin
                    stat_copy <= stat;
                    ev_line   <= 1'b0;
                    ev_done   <= 1'b0;
                end
                if (rd_d && sel && !a_tx && a_lo[5:2] == 4'd3) begin
                    pop_copy  <= {rx_any, 22'd0, rf_data[9 * p +: 9]};
                    pop_r    <= rx_any;
                end
            end
        end
        // The port's read data by register number; zero if the address is not in its range.
        assign rd_p[p] = (!sel || a_tx) ? 32'd0 :
                         (a_lo[5:2] == 4'd0) ? {21'd0, addr_r, ls_r, mode_r} :
                         (a_lo[5:2] == 4'd1) ? stat_copy :
                         (a_lo[5:2] == 4'd2) ? {8'd0, xfer_r} :
                         (a_lo[5:2] == 4'd3) ? pop_copy :
                         (a_lo[5:2] == 4'd4) ? {19'd0, s0_r} :
                         (a_lo[5:2] == 4'd5) ? {19'd0, s1_r} :
                         (a_lo[5:2] == 4'd8) ? {21'd0, avail} : 32'd0;
    end endgenerate

    // ---------------------------------------------------------------- both ports
    // Both ports: the interrupt, the send buffer writes (one word per write to the send buffer range of the addressed port), and the common registers.
    always @(posedge clk) begin
        irq   <= |irq_p;
        tx_we <= {2{wr_d && a_tx}} & a_port;
        tx_wa <= a_lo[5:2];
        tx_wd <= bus_wdata;
        if (rst) begin
            swap <= 1'b0; irq_en <= 3'd0; spk <= 14'h3000; mic <= 8'd0;
        end else if (wr_d && a_glob) begin
            case (a_lo)
                8'h04: begin swap <= bus_wdata[0]; irq_en <= bus_wdata[10:8]; end
                8'h10: spk <= bus_wdata[13:0];
                8'h14: mic <= bus_wdata[7:0];
                default: ;
            endcase
        end
        // Read data of both ports and of the common range, ORed together (only the addressed one is nonzero).
        bus_rdata <= rd_p[0] | rd_p[1] |
                     (!a_glob ? 32'd0 :
                      (a_lo == 8'h00) ? `USBH_ID_RESET :
                      (a_lo == 8'h04) ? {21'd0, irq_en, 7'd0, swap} :
                      (a_lo == 8'h10) ? {18'd0, spk} :
                      (a_lo == 8'h14) ? {24'd0, mic} :
                      (a_lo == 8'h18) ? {n_mic_bad, n_spk_over, ro[29:22]} :
                      (a_lo == 8'h1C) ? mic_count : 32'd0);
    end

endmodule
