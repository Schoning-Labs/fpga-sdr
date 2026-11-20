// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// usbh_top: the USB host with two ports, for full and low speed (docs/USB_HOST.md): the unit that goes into sdr_core.v.
// It lets the radio act as a USB host on a Pmod board plugged into the dock (two ports, each with two data pins), so that a headset or
// a USB sound card, a mouse and a keyboard can be connected without a PC: the speaker and the microphone of a headset become audio streams of the radio, and
// mouse and keyboard reports reach the firmware through the register page. This file only wires the pieces together and holds the memories
// between them:
//
//   usbh_regs.v       the register page the firmware talks to (clk_dsp)
//   usbh_port.v x 2   one per port: frame timing and transactions, with its line interface usbh_phy.v (clk_usb)
//   usbh_iso_out.v    the speaker stream, the radio's samples to one chosen port (clk_usb with a FIFO from clk_dsp)
//   usbh_iso_in.v     the microphone stream, from one chosen port to the radio (clk_usb with a FIFO to clk_dsp)
//   send buffers      64 bytes per port, filled by the firmware for SETUP and OUT transactions
//   receive FIFOs     one per port, 1,024 words of 9 bits, for what an IN transaction brings (control data, mouse and keyboard reports)
//
//   clk_usb   48 MHz (the DSP PLL's second output, as the USB device): the two ports (usbh_port.v with its
//             usbh_phy.v), the write side of the receive FIFOs, the USB ends of the two audio FIFOs
//   clk_dsp   the register page (usbh_regs.v), the read side of the receive FIFOs, the write side of the send
//             buffers, the radio ends of the audio FIFOs
//
// Pins: per port one pin of the dock's odd row (a) and one of the even row (b); `swap` says which is D+
// (docs/USB_HOST.md section 4). The pads are in the top level. The Pmod board has no electronics of its own, so the pins are driven and read
// by the FPGA directly (with a medium pull-down set in the constraint file standing in for the host's 15 kohm pull-downs); the firmware finds
// out by trial which way up the board is plugged, and sets `swap` accordingly. The two pins of a port have the same output enable `oe`.
//
// Audio: s_* is the radio's 48 kHz stream for the speaker (one port, `spk`); m_* are the microphone's samples
// at the device's own rate, for the speech FIFO of rtl/usb/usb_play.v. The speaker and the microphone each go to one port, chosen by the firmware
// in the registers `spk` and `mic`, which also hold the format (mono, 3-byte samples) and the endpoint number. Isochronous transfers are explained in
// rtl/usb/usb_ep_cap.v and the host's frame in usbh_port.v.
//
// Between the clocks: Gray-coded FIFO pointers (rtl/usb/usb_afifo.v), toggles through three registers, levels
// through two, and held settings (usbh_regs.v, usbh_port.v). The send buffers are LUT RAM written in clk_dsp
// and read in clk_usb while a transaction runs (the firmware does not write them then), and the receive FIFOs are block RAM (one per port).
//
// Latency: none that matters here; the transaction timing is in usbh_port.v and the audio latency of one frame in usbh_iso_out.v and usbh_iso_in.v.
//
// Gowin specifics: the 48 MHz clock sits on a global clock line; the send buffers (16 x 32 bits per port) are LUT RAM (syn_ramstyle distributed_ram), read
// through a register and a byte select; the receive FIFOs are block RAM (LUTRAM = 0 in usb_afifo.v, 1,024 x 9 bits, one block per port). No DSP block is used. Terms are in docs/learn/GLOSSARY.md.

`timescale 1ns / 1ps

// no parameters
module usbh_top (
    input  wire        clk_usb,  // 48 MHz USB clock
    input  wire        clk_dsp,  // 120 MHz radio clock
    input  wire        rst_dsp,  // reset of the radio clock domain (synchronous to clk_dsp)
    // pins, two ports: a = pad of the dock's odd row, b = pad of the even row; bit 0 is port 0, bit 1 is port 1
    input  wire [1:0]  a_i,  // the a pads as read
    input  wire [1:0]  b_i,  // the b pads as read
    output wire [1:0]  a_o,  // levels to drive onto the a pads
    output wire [1:0]  b_o,  // levels to drive onto the b pads
    output wire [1:0]  oe,  // output enable per port: 1 = the port drives both its pads
    // register bus (clk_dsp, from a regbus_leg of page 0x0F)
    input  wire        bus_wr,
    input  wire        bus_rd,
    input  wire [15:0] bus_addr,
    input  wire [31:0] bus_wdata,
    output wire [31:0] bus_rdata,
    output wire        irq,  // interrupt: a received record, a finished transaction or a line change
    // audio (clk_dsp): the radio's 48 kHz stream in for the speaker (valid pulse, signed 16-bit left and right), and the microphone's samples out
    input  wire               s_v,
    input  wire signed [15:0] s_l,
    input  wire signed [15:0] s_r,
    output wire               m_v,
    output wire signed [15:0] m_l,
    output wire signed [15:0] m_r
) /* synthesis syn_maxfan = 10000 syn_srlstyle = "registers" */;

    // ---------------------------------------------------------------- registers
    // Wires between the register page and the ports. Most are per-port values packed side by side: 3 bits of mode per port, 24 bits of
    // transaction setup per port (kind, endpoint, toggle, length, NAK limit), 26 bits of the two interrupt slots per port, 11 bits of frame number per port,
    // 9 or 11 bits of FIFO data or level per port, and so on. spk (14 bits) and mic (8 bits) are the speaker and microphone settings.
    wire        swap, ev_spk_over, ev_mic_bad_t;
    wire [13:0] spk;
    wire [7:0]  mic, spk_fill;
    wire [31:0] mic_count;
    wire [5:0]  mode, x_res;
    wire [1:0]  ls, go_t, done_t, line_dp, line_dn, gone, rf_pop, tx_we;
    wire [13:0] addr;
    wire [47:0] xfer;
    wire [51:0] slot;
    wire [3:0]  slot_err, tx_wa;
    wire [21:0] frame, rf_avail;
    wire [17:0] rf_rdata;
    wire [31:0] tx_wd;

    // The register page.
    usbh_regs u_regs (
        .clk(clk_dsp), .rst(rst_dsp),
        .bus_wr(bus_wr), .bus_rd(bus_rd), .bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
        .irq(irq),
        .swap(swap), .spk(spk), .mic(mic), .spk_fill_u(spk_fill), .ev_spk_over(ev_spk_over),
        .ev_mic_bad_t_u(ev_mic_bad_t), .mic_count(mic_count),
        .mode(mode), .ls(ls), .addr(addr), .go_t(go_t), .xfer(xfer), .done_t_u(done_t), .x_res_u(x_res),
        .slot(slot), .slot_err_u(slot_err), .line_dp_u(line_dp), .line_dn_u(line_dn), .gone_u(gone),
        .frame_u(frame),
        .rf_data(rf_rdata), .rf_avail(rf_avail), .rf_pop(rf_pop),
        .tx_we(tx_we), .tx_wa(tx_wa), .tx_wd(tx_wd)
    );

    // ---------------------------------------------------------------- into clk_usb
    // Settings brought into the 48 MHz clock with two registers each: the reset, the swap, and the enables of the two audio streams. so_en and si_en turn
    // each enable into one bit per port (the stream's port is spk[1] and mic[1]).
    reg [1:0] rst_s = 2'b11 /* synthesis syn_preserve = 1 */;
    reg [1:0] sw_s = 2'b00, spk_s = 2'b00, mic_s = 2'b00 /* synthesis syn_preserve = 1 */;
    reg [1:0] so_en = 2'b00, si_en = 2'b00;
    always @(posedge clk_usb) begin
        rst_s <= {rst_s[0], rst_dsp};
        sw_s  <= {sw_s[0], swap};
        spk_s <= {spk_s[0], spk[0]};
        mic_s <= {mic_s[0], mic[0]};
        so_en <= {spk_s[1] && spk[1], spk_s[1] && !spk[1]};
        si_en <= {mic_s[1] && mic[1], mic_s[1] && !mic[1]};
    end
    wire rst_usb = rst_s[1];
    wire swap_u  = sw_s[1];

    // ---------------------------------------------------------------- the two ports
    // Per port (below): line interface and transaction engine, send buffer, receive FIFO.
    // Wires from the two ports to the audio ends; each is per port, and the audio ends pick the one of the chosen port.
    wire [1:0]  sof, so_rd, so_commit, si_wr, si_commit, si_abort;
    wire [15:0] si_data;
    wire [9:0]  so_len;
    wire [7:0]  so_data;
    genvar p;
        // port p's own wires and memories: the pad levels, the receive FIFO's write side, and the send buffer
    generate for (p = 0; p < 2; p = p + 1) begin : port
        wire        dp_o, dn_o;
        wire        rf_push, rf_commit, rf_abort;
        wire [8:0]  rf_wdata;
        wire [10:0] rf_free;
        wire [5:0]  txb_addr;
        // send buffer: 16 words of 32 bits (64 bytes) in LUT RAM, written by the firmware on the radio clock, read a word at a time on the USB clock
        // and the byte picked by txsel (the two low address bits), so the port gets a byte at most two clocks after it asked.
        // send buffer: 16 words, written by the firmware, read a byte at a time
        reg  [31:0] txm [0:15] /* synthesis syn_ramstyle = "distributed_ram" */;
        reg  [31:0] txw = 32'd0;
        reg  [1:0]  txsel = 2'd0;
        always @(posedge clk_dsp) if (tx_we[p]) txm[tx_wa] <= tx_wd;
        always @(posedge clk_usb) begin
            txw   <= txm[txb_addr[5:2]];
            txsel <= txb_addr[1:0];
        end

        // The port. D+ is the b pad and D- the a pad, or the other way round when swap is set; the settings are taken from the packed vectors.
        usbh_port u_port (
            .clk(clk_usb), .rst(rst_usb),
            .dp_i(swap_u ? a_i[p] : b_i[p]), .dn_i(swap_u ? b_i[p] : a_i[p]),
            .dp_o(dp_o), .dn_o(dn_o), .oe(oe[p]),
            .mode_a(mode[3 * p +: 3]), .ls_a(ls[p]), .addr(addr[7 * p +: 7]),
            .go_t_a(go_t[p]), .x_kind(xfer[24 * p +: 2]), .x_ep(xfer[24 * p + 2 +: 4]),
            .x_tog(xfer[24 * p + 6]), .x_len(xfer[24 * p + 7 +: 7]), .x_nak(xfer[24 * p + 16 +: 8]),
            .txb_addr(txb_addr), .txb_data(txw[8 * txsel +: 8]),
            .done_t(done_t[p]), .x_res(x_res[3 * p +: 3]),
            .slot_en_a({slot[26 * p + 13], slot[26 * p]}),
            .slot0_ep(slot[26 * p + 1 +: 4]),  .slot0_ivl(slot[26 * p + 5 +: 8]),
            .slot1_ep(slot[26 * p + 14 +: 4]), .slot1_ivl(slot[26 * p + 18 +: 8]),
            .slot_err(slot_err[2 * p +: 2]),
            .rf_push(rf_push), .rf_data(rf_wdata), .rf_commit(rf_commit), .rf_abort(rf_abort),
            .rf_free(rf_free),
            .so_en(so_en[p]), .so_ep(spk[5:2]), .sof(sof[p]),
            .so_len(so_len), .so_data(so_data), .so_rd(so_rd[p]), .so_commit(so_commit[p]),
            .si_en(si_en[p]), .si_ep(mic[5:2]),
            .si_wr(si_wr[p]), .si_data(si_data[8 * p +: 8]), .si_commit(si_commit[p]), .si_abort(si_abort[p]),
            .line_dp(line_dp[p]), .line_dn(line_dn[p]), .gone(gone[p]), .frame(frame[11 * p +: 11])
        );
        // the outputs go to the pads with the same exchange
        assign a_o[p] = swap_u ? dp_o : dn_o;
        assign b_o[p] = swap_u ? dn_o : dp_o;

        // receive FIFO: records of 9-bit words, one block RAM; written by the port (committed per good record) and read by the register page, one word per pop
            usb_afifo #(.W(9), .AW(10), .LUTRAM(0)) u_rf (
            .wclk(clk_usb), .wrst(rst_usb),
            .w_push(rf_push), .w_data(rf_wdata), .w_commit(rf_commit), .w_abort(rf_abort),
            .w_free(rf_free),
            .rclk(clk_dsp), .rrst(rst_dsp),
            .r_pop(rf_pop[p]), .r_commit(rf_pop[p]), .r_rewind(1'b0), .r_flush(1'b0),
            .r_data(rf_rdata[9 * p +: 9]), .r_avail_c(rf_avail[11 * p +: 11]), .r_avail_t()
        );
    end endgenerate

    // ---------------------------------------------------------------- audio, switched to one port each
    // sp, mp: the port chosen for the speaker and for the microphone.
    wire sp = spk[1];
    wire mp = mic[1];
    // The speaker: its FIFO fills from the radio's stream; at the start of frame of the chosen port it prepares a packet that that port reads.
    usbh_iso_out u_spk (
        .clk_usb(clk_usb), .rst_usb(rst_usb),
        .enable(spk_s[1]), .mono(spk[6]), .bytes3(spk[7]), .max_samp(spk[13:8]),
        .sof(sof[sp]), .len(so_len), .data(so_data), .rd(so_rd[sp]), .commit(so_commit[sp]),
        .fill(spk_fill),
        .clk_aud(clk_dsp), .rst_aud(rst_dsp),
        .aud_valid(s_v), .aud_l(s_l), .aud_r(s_r), .ev_over(ev_spk_over)
    );
    // The microphone: the bytes of the chosen port's IN packets become samples on the radio clock.
    usbh_iso_in u_mic (
        .clk_usb(clk_usb), .rst_usb(rst_usb),
        .enable(mic_s[1]), .mono(mic[6]), .bytes3(mic[7]),
        .wr(si_wr[mp]), .data(si_data[8 * mp +: 8]), .commit(si_commit[mp]), .abort(si_abort[mp]),
        .ev_bad_t(ev_mic_bad_t),
        .clk_aud(clk_dsp), .rst_aud(rst_dsp),
        .m_v(m_v), .m_l(m_l), .m_r(m_r), .m_count(mic_count)
    );

endmodule
