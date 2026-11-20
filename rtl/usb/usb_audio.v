// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// usb_audio: the radio as a USB sound card on the "Custom USB" socket of the dock (docs/USB_AUDIO.md), written in
// plain Verilog: USB full speed, USB Audio Class 1.0, 48 kHz 16-bit stereo in both directions. This is the top of
// rtl/usb/ and the only file the rest of the radio instantiates (sdr_core.v). When the cable is plugged into a PC the
// PC asks the device what it is (see usb_ep0.v), finds an audio device with a playback interface and a recording
// interface, and from then on shows it in its sound settings without a driver, because every operating system has a
// built-in one for Audio Class 1.0. Recording on the PC then gets the radio's receiver audio, and playback on the PC
// goes into the radio, where it can be mixed into the outputs, read by the processor, or sent back. The unit's frame
// is the USB device of an earlier design by the same author: its MIDI endpoints are gone, and the
// playback direction, the split into two clock domains and the register page are new.
//
// The pieces, with the clock each runs on:
//   usb_fs_phy   line interface, 48 MHz, 4 samples per bit                            clk_usb
//   usb_fs_core  packets, CRCs, handshakes, toggles                                   clk_usb
//   usb_ep0      control endpoint, every request in hardware, descriptor ROM          clk_usb
//   usb_ep_play  isochronous OUT 0x01 (PC to radio) and its feedback endpoint 0x81    clk_usb
//   usb_afifo    256 samples between the two clocks (playback)                        clk_usb -> clk_dsp
//   usb_play     playback reader, monitor, loop-back, CPU FIFO, peak meters           clk_dsp
//   usb_ep_cap   isochronous IN 0x82 (radio to PC) with its 128-sample FIFO           clk_dsp -> clk_usb
//   usb_regs     register page 0x0E (hw/regmap/usb.toml)                              clk_dsp
//
// The USB basics are spread over the files: the wires, J and K, NRZI and bit stuffing in usb_fs_phy.v; packets, PIDs, CRCs,
// tokens and endpoints in usb_fs_core.v; control transfers and enumeration with descriptors in usb_ep0.v; isochronous
// transfers in usb_ep_cap.v and the feedback endpoint in usb_ep_play.v. Terms are also in docs/learn/GLOSSARY.md.
//
// Data flow. Recording: the radio's receiver stream s_* goes through usb_play.v (which can swap it for the PC's own playback,
// the loop-back) to usb_ep_cap.v, whose FIFO carries it from the 120 MHz clock to the 48 MHz clock, and the packet
// engine and the PHY put it on the wire when the PC asks for it once a millisecond. Playback: the PHY and the packet engine
// receive the PC's packets, usb_ep_play.v turns them into stereo samples and writes the FIFO, which carries them from the 48 MHz
// clock to the 120 MHz clock, and usb_play.v takes one sample per tick of the radio's 48 kHz and hands it to the monitor
// mix, the loop-back and the processor's FIFO. Control requests (endpoint 0) never leave the 48 MHz side, which is why
// the device enumerates without the processor.
//
// Clocks: clk_usb is the 48 MHz output of the DSP PLL (the full-speed bit rate must be within 0.25 %, and 48 MHz
// is exactly 4 clocks per 12 Mbit/s bit); clk_dsp is the radio's 120 MHz clock, whose 48 kHz sample is 2,500 clocks. They are treated as unrelated:
// every signal between them is a Gray-coded FIFO pointer (usb_afifo.v), a level through two registers, or a toggle through
// three (gowin/p1/sdr.sdc). The reset and the connect switch come into the USB clock through two registers each,
// and the status bits and event toggles go the other way in usb_regs.v. The FIFOs are the only path for audio data.
//
// Pins (docs/USB_AUDIO.md section 9): dp/dn = T19/U19, LVCMOS33, bidirectional (dp_o, dn_o, oe); pullup_en =
// M19 (1.5 kohm to D+). The pads themselves are in the top level; this module sees them as separate inputs and outputs.
// The pull-up tells the host that a full-speed device is present: with pullup_en low the device is invisible, and it is high
// after reset (usb.ctrl.connect = 1), so the board enumerates as soon as the bitstream runs.
//
// Audio: s_v/s_l/s_r is the radio's 48 kHz stream (one clock per sample, never stops). m_v/m_l/m_r is the same
// stream two clocks later, with the PC's playback added while usb.ctrl.monitor is set: it replaces s_* as the
// feed of the digital outputs. The PC records s_*, or its own playback with usb.ctrl.loopback.
//
// Latency: recording takes 1 to 2 ms from the receiver's audio to the PC (the samples wait for the next 1 ms frame), playback about 2 ms
// from the PC to the digital outputs (the FIFO is filled to 96 samples before the reader starts), and the monitor path adds 2 clocks.
//
// Gowin specifics: the 48 MHz clk_usb sits on one of the chip's global clock lines (16 in all, the "long wire" ones included), which
// the USB logic needs because on ordinary wiring the clock skew gave hold-time failures; the module's attributes keep the
// fan-out limit high. The two FIFOs are in LUT RAM, the descriptor ROM and the CPU FIFO are in block RAM (1 and 2 blocks), and no DSP block is used.

`timescale 1ns / 1ps

// ROM_FILE: path of the descriptor hex file, passed down to usb_ep0.v.
module usb_audio #(
    parameter ROM_FILE = "rtl/usb/usb_desc_rom.hex"
) (
    input  wire               clk_usb,  // 48 MHz USB clock
    input  wire               clk_dsp,  // 120 MHz radio clock
    input  wire               rst_dsp,  // reset of the radio clock domain (synchronous to clk_dsp)
    // pins
    input  wire               dp_i,  // D+ as read from the pad
    input  wire               dn_i,  // D- as read from the pad
    output wire               dp_o,  // level to drive onto D+
    output wire               dn_o,  // level to drive onto D-
    output wire               oe,  // 1 = drive the pads, 0 = listen
    output wire               pullup_en,  // 1 = switch the 1.5 kohm pull-up of D+ on (announces the device to the host)
    // register bus (clk_dsp, from a regbus_leg): write and read strobe, offset inside the page, write data, read data
    input  wire               bus_wr,
    input  wire               bus_rd,
    input  wire [15:0]        bus_addr,
    input  wire [31:0]        bus_wdata,
    output wire [31:0]        bus_rdata,
    output wire               irq,  // interrupt: the CPU FIFO is at or above its mark (usb.fifo_mark)
    // audio (clk_dsp): the radio's 48 kHz stream in, valid pulse and signed 16-bit left and right samples; and the stream out for the digital outputs
    input  wire               s_v,
    input  wire signed [15:0] s_l,
    input  wire signed [15:0] s_r,
    output wire               m_v,
    output wire signed [15:0] m_l,
    output wire signed [15:0] m_r,
    // the USB host's microphone (rtl/usbh, clk_dsp): the other source of the CPU FIFO (usb.ctrl.speech_src); valid pulse, left, right
    input  wire               x_v,
    input  wire signed [15:0] x_l,
    input  wire signed [15:0] x_r
) /* synthesis syn_maxfan = 10000 syn_srlstyle = "registers" */;
    `include "rtl/usb/usb_desc_params.vh"

    // ---------------------------------------------------------------- reset and connect into clk_usb
    // Bring the radio's reset and the connect switch into the USB clock with two registers each. The reset starts active, so the
    // USB logic is held in reset from power-up until the first clock after the reset of the radio is released.
    wire connect;
    reg [1:0] rst_s = 2'b11 /* synthesis syn_preserve = 1 */;
    reg [1:0] con_s = 2'b00 /* synthesis syn_preserve = 1 */;
    always @(posedge clk_usb) begin
        rst_s <= {rst_s[0], rst_dsp};
        con_s <= {con_s[0], connect};
    end
    wire rst_usb   = rst_s[1];
    wire connected = con_s[1];
    assign pullup_en = connected;

    // ---------------------------------------------------------------- PHY and packet engine
    // The pull-up follows the connect switch; while it is off the PHY and the packet engine are held in reset, so the device
    // does not answer anything either.
    wire       bus_reset, line_se0, rx_active, rx_valid, rx_eop, rx_err, tx_valid, tx_ready, tx_busy;
    wire [7:0] rx_data, tx_data;
    // usb_rst: reset of the whole USB side, including while disconnected.
    wire       usb_rst = rst_usb || !connected;

    // The line interface (see usb_fs_phy.v): the pads, one byte at a time to and from the packet engine.
    usb_fs_phy u_phy (
        .clk(clk_usb), .rst(usb_rst),
        .dp_i(dp_i), .dn_i(dn_i), .dp_o(dp_o), .dn_o(dn_o), .oe(oe),
        .bus_reset(bus_reset), .line_se0(line_se0),
        .rx_active(rx_active), .rx_valid(rx_valid), .rx_data(rx_data), .rx_eop(rx_eop), .rx_err(rx_err),
        .tx_valid(tx_valid), .tx_data(tx_data), .tx_ready(tx_ready), .tx_busy(tx_busy)
    );

    // The packet engine's connections to the endpoints (see usb_fs_core.v): which endpoint is selected, the OUT data path, and the IN data path.
    wire [6:0]  dev_addr;
    wire        sof;
    wire [10:0] frame;
    wire [3:0]  ep;
    wire        ep_in, out_setup, out_wr, out_commit, out_abort, in_rd, in_commit, in_rewind;
    wire [7:0]  out_data;
    wire [3:0]  tog_clear;
    wire        out_exists, out_ok, out_stall, out_iso, in_exists, in_ready, in_stall, in_iso;
    wire [9:0]  in_len;
    wire [7:0]  in_data;

    // The packet engine.
    usb_fs_core u_core (
        .clk(clk_usb), .rst(usb_rst), .bus_reset(bus_reset),
        .rx_active(rx_active), .rx_valid(rx_valid), .rx_data(rx_data), .rx_eop(rx_eop), .rx_err(rx_err),
        .tx_valid(tx_valid), .tx_data(tx_data), .tx_ready(tx_ready), .tx_busy(tx_busy),
        .dev_addr(dev_addr), .sof(sof), .frame(frame),
        .ep(ep), .ep_in(ep_in),
        .out_setup(out_setup), .out_wr(out_wr), .out_data(out_data),
        .out_commit(out_commit), .out_abort(out_abort),
        .out_exists(out_exists), .out_ok(out_ok), .out_stall(out_stall), .out_iso(out_iso),
        .in_exists(in_exists), .in_ready(in_ready), .in_stall(in_stall), .in_iso(in_iso),
        .in_len(in_len), .in_data(in_data),
        .in_rd(in_rd), .in_commit(in_commit), .in_rewind(in_rewind),
        .tog_clear(tog_clear)
    );

    // ---------------------------------------------------------------- endpoints (clk_usb)
    wire configured, alt_play, alt_cap;
    // Whether the two audio streams are on: the PC's SET_INTERFACE and SET_CONFIGURATION set these, registered here because they
    // also leave for the radio clock (a level that crosses a clock domain must come from a flip-flop).
    reg  play_on_u = 1'b0, cap_on_u = 1'b0;
    always @(posedge clk_usb) begin
        play_on_u <= configured && alt_play;
        cap_on_u  <= configured && alt_cap;
    end
    // Which endpoint a token is for, from the endpoint number and the direction. The audio endpoints exist only while their stream is on, and
    // an endpoint that does not exist gets no answer at all (usb_fs_core.v).
    wire sel0  = (ep == 4'd0);
    wire selpo = (ep == USB_EP_PLAY) && play_on_u && !ep_in;      // playback data OUT 0x01
    wire selpf = (ep == USB_EP_PLAY) && play_on_u && ep_in;       // playback feedback IN 0x81
    wire selc  = (ep == USB_EP_CAP)  && cap_on_u  && ep_in;       // capture IN 0x82
    // reset for the endpoints: also on a bus reset by the host.
    wire ep_rst = usb_rst || bus_reset;

    // Endpoint 0, the control endpoint (usb_ep0.v), gets the strobes of the packet engine only when it is the selected one (and an OUT or SETUP, or an IN, as the case may be).
    wire       e0_out_ok, e0_out_stall, e0_in_ready, e0_in_stall;
    wire [9:0] e0_in_len;
    wire [7:0] e0_in_data;
    usb_ep0 #(.ROM_FILE(ROM_FILE)) u_ep0 (
        .clk(clk_usb), .rst(ep_rst),
        .out_setup(out_setup), .out_wr(out_wr && sel0 && !ep_in), .out_data(out_data),
        .out_commit(out_commit && sel0 && !ep_in), .out_abort(out_abort && sel0 && !ep_in),
        .out_ok(e0_out_ok), .out_stall(e0_out_stall),
        .in_ready(e0_in_ready), .in_stall(e0_in_stall), .in_len(e0_in_len), .in_data(e0_in_data),
        .in_rd(in_rd && sel0 && ep_in), .in_commit(in_commit && sel0 && ep_in),
        .in_rewind(in_rewind && sel0 && ep_in),
        .dev_addr(dev_addr), .configured(configured), .alt_play(alt_play), .alt_cap(alt_cap),
        .tog_clear(tog_clear)
    );

    // The playback endpoint (usb_ep_play.v): OUT packets of audio in, the feedback packet out, the FIFO's write side.
    wire        pf_in_ready, pw_push, pw_commit, pw_abort, ev_over_t, ev_bad_t;
    wire [9:0]  pf_in_len;
    wire [7:0]  pf_in_data;
    wire [31:0] pw_data;
    wire [8:0]  pw_free;
    usb_ep_play u_ep_play (
        .clk(clk_usb), .rst(ep_rst), .enable(play_on_u), .sof(sof),
        .out_wr(out_wr && selpo), .out_data(out_data),
        .out_commit(out_commit && selpo), .out_abort(out_abort && selpo),
        .in_ready(pf_in_ready), .in_len(pf_in_len), .in_data(pf_in_data),
        .in_rd(in_rd && selpf), .in_commit(in_commit && selpf),
        .w_push(pw_push), .w_data(pw_data), .w_commit(pw_commit), .w_abort(pw_abort), .w_free(pw_free),
        .ev_over_t(ev_over_t), .ev_bad_t(ev_bad_t)
    );

    // The capture endpoint (usb_ep_cap.v). It is reset by the chip reset only, because its FIFO has a second side in the other clock domain
    // that is reset by rst_dsp at the same time; a bus reset only turns the stream off through the alternate setting.
    wire        c_in_ready, c_v, ev_cap_over;
    wire [9:0]  c_in_len;
    wire [7:0]  c_in_data;
    wire signed [15:0] c_l, c_r;
    usb_ep_cap u_ep_cap (
        .clk_usb(clk_usb), .rst_usb(rst_usb), .enable(cap_on_u), .sof(sof),   // the chip's reset: its FIFO has two sides
        .in_ready(c_in_ready), .in_len(c_in_len), .in_data(c_in_data),
        .in_rd(in_rd && selc), .in_commit(in_commit && selc),
        .clk_aud(clk_dsp), .rst_aud(rst_dsp),
        .aud_valid(c_v), .aud_l(c_l), .aud_r(c_r), .ev_over(ev_cap_over)
    );

    // What the packet engine sees: the endpoint's answers multiplexed by the selected endpoint. Endpoint 0 is the only one that can be
    // halted; the audio endpoints are isochronous, which the engine needs to know (no handshake, always DATA0).
    assign out_exists = !ep_in && (sel0 || selpo);
    assign out_ok     = sel0 ? e0_out_ok : 1'b1;
    assign out_stall  = sel0 ? e0_out_stall : 1'b0;
    assign out_iso    = selpo;
    assign in_exists  = ep_in && (sel0 || selpf || selc);
    assign in_iso     = selpf || selc;
    assign in_ready   = sel0 ? e0_in_ready : selpf ? pf_in_ready : c_in_ready;
    assign in_stall   = sel0 ? e0_in_stall : 1'b0;
    assign in_len     = sel0 ? e0_in_len   : selpf ? pf_in_len   : c_in_len;
    assign in_data    = sel0 ? e0_in_data  : selpf ? pf_in_data  : c_in_data;

    // ---------------------------------------------------------------- playback: USB clock -> radio clock
    wire        speech_src;
    wire        play_on, fifo_en, monitor, loopback, pr_pop, play_run, ev_under, ev_fover;
    wire        f_pop, pk_clr;
    wire [8:0]  pr_avail;
    wire [31:0] pr_data, f_word;
    wire [10:0] f_level;
    wire [14:0] pk_play, pk_cap;

    // The playback FIFO: 256 samples of {R, L}, written on the USB clock by usb_ep_play.v (a packet at a time, committed
    // or dropped whole), read on the radio clock by usb_play.v one sample per tick, and flushed while the stream is off.
    usb_afifo #(.W(32), .AW(8), .LUTRAM(1)) u_play_fifo (
        .wclk(clk_usb), .wrst(rst_usb),
        .w_push(pw_push), .w_data(pw_data), .w_commit(pw_commit), .w_abort(pw_abort), .w_free(pw_free),
        .rclk(clk_dsp), .rrst(rst_dsp),
        .r_pop(pr_pop), .r_commit(pr_pop), .r_rewind(1'b0), .r_flush(!play_on),
        .r_data(pr_data), .r_avail_c(), .r_avail_t(pr_avail)
    );

    // The radio-side playback reader, the monitor mix, the loop-back, the CPU FIFO and the peak meters.
    usb_play u_play (
        .clk(clk_dsp), .rst(rst_dsp),
        .s_v(s_v), .s_l(s_l), .s_r(s_r),
        .stream_on(play_on), .fifo_en(fifo_en), .monitor(monitor), .loopback(loopback),
        .ext_sel(speech_src), .x_v(x_v), .x_l(x_l), .x_r(x_r),
        .r_avail(pr_avail), .r_data(pr_data), .r_pop(pr_pop),
        .m_v(m_v), .m_l(m_l), .m_r(m_r), .c_v(c_v), .c_l(c_l), .c_r(c_r),
        .f_pop(f_pop), .f_word(f_word), .f_level(f_level),
        .run(play_run), .ev_under(ev_under), .ev_fover(ev_fover),
        .pk_clr_play(pk_clr), .pk_clr_cap(pk_clr), .pk_play(pk_play), .pk_cap(pk_cap)
    );

    // the fill of the playback FIFO for the status register: this unit's own registered copy
    reg [8:0] fill_r = 9'd0;
    always @(posedge clk_dsp) fill_r <= pr_avail;

    // ---------------------------------------------------------------- registers (clk_dsp)
    // The register page.
    usb_regs u_regs (
        .clk(clk_dsp), .rst(rst_dsp),
        .bus_wr(bus_wr), .bus_rd(bus_rd), .bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
        .irq(irq),
        .connect(connect), .fifo_en(fifo_en), .monitor(monitor), .loopback(loopback), .speech_src(speech_src),
        .play_on(play_on),
        .configured_u(configured), .play_on_u(play_on_u), .cap_on_u(cap_on_u),
        .ev_over_t_u(ev_over_t), .ev_bad_t_u(ev_bad_t),
        .play_run(play_run), .play_fill(fill_r), .ev_under(ev_under), .ev_cap_over(ev_cap_over),
        .ev_fover(ev_fover), .f_word(f_word), .f_level(f_level), .f_pop(f_pop),
        .pk_play(pk_play), .pk_cap(pk_cap), .pk_clr(pk_clr)
    );

endmodule
