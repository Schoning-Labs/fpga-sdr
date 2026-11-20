// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Taken from an earlier design by the same author; modified 2026 by
// Franz Schöning for fpga-sdr: isochronous OUT endpoints (out_iso: any data toggle, no handshake) (docs/USB_AUDIO.md).
//
// usb_fs_core: the packet engine of the USB device. usb_fs_phy.v hands it single bytes, and it works out which
// packets those bytes make up, checks them, passes the data on to the right endpoint, and sends the answers that
// the USB protocol demands. It sits between usb_fs_phy.v (wires, bits, bytes) and the endpoint modules
// (usb_ep0.v, usb_ep_play.v, usb_ep_cap.v), which are chosen through `ep` and `ep_in`, and the whole unit
// is put together in usb_audio.v. It runs on the 48 MHz clock clk_usb, so one byte arrives every 32 clocks.
//
// USB packets, as much as this file needs (the wire level is in usb_fs_phy.v). Everything on the bus happens as a
// transaction that the host starts. A transaction has up to three packets: a token, which the host sends to say
// what is about to happen and to which device and endpoint, then a data packet in one direction, and then a
// handshake from the receiver of the data. Each packet begins with a PID, a packet identifier byte, whose upper four
// bits are the inverse of the lower four as a safety check (so a damaged PID is recognized and the packet is
// ignored), and the PID says what kind of packet it is:
//   token       OUT (host will send data), IN (host asks for data), SETUP (like OUT, but starts a control
//               transfer) and SOF (start of frame, sent once every 1 ms by the host). A token is the PID and
//               16 more bits: 7 bits of device address, 4 bits of endpoint number and a 5-bit CRC5. In a SOF the 11 bits
//               before the CRC5 are the frame number.
//   data        DATA0 or DATA1, the PID, the payload of up to 64 bytes (1,023 on an isochronous endpoint at full
//               speed) and a 16-bit CRC16 over the payload. The two PIDs alternate, one per packet (the data
//               toggle), which lets the receiver tell a packet it has already seen (the sender repeats it when it
//               missed the handshake) from the next one.
//   handshake   ACK (received well), NAK (not ready now, ask again later) and STALL (this will never work), each a
//               PID alone.
// A CRC (cyclic redundancy check) is a few extra bits computed from all the others, so a receiver that computes
// the same thing over the data plus the CRC gets a fixed number (the residual) if nothing was damaged. An endpoint
// is a numbered mailbox inside the device, one per direction (IN means to the host); endpoint 0 is the control
// endpoint that every device has (see usb_ep0.v). A device answers only to tokens carrying its own address, which
// the host hands out during enumeration (usb_ep0.v).
//
// Isochronous endpoints carry audio. They are scheduled once per 1 ms frame, they have no handshake and no
// retry (a late or damaged packet is of no use to a live stream), and their data PID is always DATA0 in this core.
//
// What the core does with each token, with a good CRC5 and our address (it latches the endpoint number `ep` and
// the direction `ep_in`, and the top level multiplexes the selected endpoint's status inputs from them):
//
//  - SETUP/OUT: the data packet's payload bytes go to the endpoint (out_wr/out_data) while they
//    arrive; at the end the packet is out_commit-ed (good CRC, expected toggle, endpoint had room)
//    or out_abort-ed. Answer: ACK, NAK (endpoint full: out_ok low at token time), STALL, or ACK
//    without commit for a repeated packet (wrong toggle: the host missed our ACK). A SETUP is
//    always accepted on endpoint 0 and resets its toggles (USB 2.0 section 8.5.3).
//  - IN: STALL, NAK (nothing ready), or a data packet of in_len bytes read with in_rd from the
//    endpoint's tentative read position (in_data must show the byte at that position; the core
//    reads the next byte at least 32 clocks later). Isochronous endpoints always send DATA0 and
//    commit at once, an empty packet when nothing is ready; otherwise the host's ACK commits the packet and
//    flips the toggle, and a missing ACK rewinds it for a retry.
//  - Isochronous OUT (out_iso): the data packet is taken with either toggle and committed on a
//    good CRC; no handshake is sent.
//  - SOF: frame number and a one-clock `sof` pulse (the audio endpoint packs its samples on it).
//
// "Tentative" and "commit" make a packet all or nothing: bytes are written to or read from the endpoint's
// buffer before it is known whether the packet was good, and only a commit (or an abort or rewind) at the end
// makes them count, as described in usb_afifo.v.
//
// CRC5 and CRC16 are checked by residual (USB 2.0 section 8.3.5): the LSB-first register
// arithmetic used here leaves 5'h06 and 16'hB001 (the bit-reversed forms of 01100b and 800Dh). The CRC16 of the
// outgoing packet is made byte by byte, and sent inverted, low byte first. While a data packet comes in, two
// bytes are kept back (d1 and d2) so that the two CRC bytes at the end never reach the endpoint.
//
// Latency: a handshake or data answer is started by the PHY about 3 bit times after the host's last bit, so the
// core adds only a few clocks to the PHY's own wait; a data byte reaches the endpoint two bytes (64 clocks) after
// it was received, because of the two-byte delay line.
//
// Gowin specifics: the synthesizer attributes on the module are those of usb_fs_phy.v. No block RAM and no DSP block
// is used; the two CRC functions are small chains of XORs. Terms are in docs/learn/GLOSSARY.md.

`timescale 1ns / 1ps

module usb_fs_core (
    input  wire        clk,  // 48 MHz USB clock
    input  wire        rst,  // synchronous reset, 1 = idle state
    input  wire        bus_reset,  // 1 while the host holds the bus in reset: the engine goes idle, the frame number and the toggles are cleared
    // PHY
    input  wire        rx_active,  // 1 while a packet is arriving
    input  wire        rx_valid,  // one-clock pulse: rx_data is a received byte
    input  wire [7:0]  rx_data,  // the received byte, first bit on the wire in bit 0
    input  wire        rx_eop,  // one-clock pulse at the end of a packet
    input  wire        rx_err,  // with rx_eop: 1 = bit-stuffing error
    output reg         tx_valid,  // 1 while the core has bytes to send; held until the last one was taken
    output reg  [7:0]  tx_data,  // the byte to send (PID, payload, CRC16)
    input  wire        tx_ready,  // one-clock pulse from the PHY: tx_data was taken, the next byte is due within 32 clocks
    input  wire        tx_busy,  // 1 while the PHY is sending
    // device state
    input  wire [6:0]  dev_addr,  // the address the host gave this device, 0 until it does (set by usb_ep0.v)
    output reg         sof,  // one-clock pulse at each good SOF token: one per 1 ms frame
    output reg  [10:0] frame,  // the frame number of the last SOF, 0 to 2047
    // selected endpoint
    output reg  [3:0]  ep,  // endpoint number of the last token addressed to us (0 to 15)
    output reg         ep_in,  // direction of that token: 1 = IN (the device sends), 0 = OUT or SETUP
    // OUT / SETUP data
    output reg         out_setup,  // 1 while the packet is a SETUP (the endpoint starts a control request)
    output reg         out_wr,  // one-clock pulse: out_data is a payload byte of the packet
    output reg  [7:0]  out_data,  // the payload byte, without the CRC
    output reg         out_commit,  // one-clock pulse: the packet was good, keep what was written
    output reg         out_abort,  // one-clock pulse: the packet was bad or not accepted, throw away what was written
    input  wire        out_exists,  // from the endpoint: the selected OUT endpoint exists
    input  wire        out_ok,  // from the endpoint: it has room for a packet now (low gives a NAK)
    input  wire        out_stall,  // from the endpoint: halted (gives a STALL)
    input  wire        out_iso,       // from the endpoint: the selected OUT endpoint is isochronous (any data PID is accepted, no handshake)
    // IN data
    input  wire        in_exists,  // from the endpoint: the selected IN endpoint exists
    input  wire        in_ready,  // from the endpoint: a packet is waiting (low gives a NAK, or an empty packet on isochronous)
    input  wire        in_stall,  // from the endpoint: halted
    input  wire        in_iso,  // from the endpoint: the selected IN endpoint is isochronous
    input  wire [9:0]  in_len,  // bytes in the waiting packet (up to 1,023)
    input  wire [7:0]  in_data,  // the byte at the endpoint's current read position
    output reg         in_rd,  // one-clock pulse: that byte was taken, advance
    output reg         in_commit,  // one-clock pulse: the packet was sent and acknowledged (or isochronous), drop it for good
    output reg         in_rewind,  // one-clock pulse: the packet was not acknowledged, go back to its start for a retry
    // from the endpoint logic: a bit per endpoint number that sends endpoint n's data toggles back to DATA0 (SET_CONFIGURATION,
    // SET_INTERFACE, CLEAR_FEATURE)
    input  wire [3:0]  tog_clear
) /* synthesis syn_maxfan = 10000 syn_srlstyle = "registers" */;
    // Token PIDs (bits 3:0 of the PID byte) and data PIDs; the full byte is {~PID, PID}.
    localparam [3:0] PID_OUT = 4'h1, PID_IN = 4'h9, PID_SOF = 4'h5, PID_SETUP = 4'hD;
    localparam [3:0] PID_DATA0 = 4'h3, PID_DATA1 = 4'hB;
    // The full handshake bytes: ACK, NAK and STALL, each {~PID, PID} with PIDs 2, A and E.
    localparam [7:0] HS_ACK = 8'hD2, HS_NAK = 8'h5A, HS_STALL = 8'h1E;
    // Handshake / data turnaround timeout while the line is idle: 18 bit times (USB 2.0 7.1.19.1) = 72 clocks at 4 clocks per bit
    localparam [7:0] TIMEOUT = 8'd72;

    // CRC16 of USB (polynomial x^16 + x^15 + x^2 + 1, which is 16'hA001 with the bits reversed), one byte at a time, least
    // significant bit first. The start value is all ones and the answer is sent inverted.
    function [15:0] crc16_byte(input [15:0] c, input [7:0] d);
        integer i;
        reg [15:0] x;
        begin
            x = c ^ {8'h00, d};
            for (i = 0; i < 8; i = i + 1) x = x[0] ? ((x >> 1) ^ 16'hA001) : (x >> 1);
            crc16_byte = x;
        end
    endfunction
    // CRC5 of a token (polynomial x^5 + x^2 + 1, 5'h14 reversed) over its 16 bits including the received CRC5 field;
    // a good token leaves the residual 5'h06.
    function [4:0] crc5_16(input [15:0] t);
        integer i;
        reg [4:0] c;
        begin
            c = 5'h1F;
            for (i = 0; i < 16; i = i + 1) c = (c[0] ^ t[i]) ? ((c >> 1) ^ 5'h14) : (c >> 1);
            crc5_16 = c;
        end
    endfunction

    // The states of the engine: wait for a PID (S_IDLE), skip a packet that is not for us, read the two token bytes and
    // the EOP (S_TOK1, S_TOK2, S_TOK_EOP), decide what to answer (S_IN_DECIDE, S_OUT_DECIDE), receive the data
    // packet of an OUT (S_WAIT_DATA, S_DATA), send a handshake (S_HS), send a data packet (S_TX_PID, S_TX_DATA, S_TX_CRC2,
    // S_TX_LAST), wait until the PHY is done (S_TX_END), and wait for the host's handshake of an IN (S_WAIT_HS,
    // S_HS_EOP).
    localparam S_IDLE = 5'd0, S_SKIP = 5'd1, S_TOK1 = 5'd2, S_TOK2 = 5'd3, S_TOK_EOP = 5'd4,
               S_IN_DECIDE = 5'd5, S_OUT_DECIDE = 5'd6, S_WAIT_DATA = 5'd7, S_DATA = 5'd8,
               S_HS = 5'd9, S_TX_PID = 5'd10, S_TX_DATA = 5'd11, S_TX_CRC2 = 5'd12,
               S_TX_LAST = 5'd13, S_TX_END = 5'd14, S_WAIT_HS = 5'd15, S_HS_EOP = 5'd16;
    // st: state. tokpid: PID of the token being handled. tok: its 16 bits (address, endpoint, CRC5).
    reg [4:0]  st;
    reg [3:0]  tokpid;
    reg [15:0] tok;
    // in_tog, out_tog: the data toggle that is due next, one bit per endpoint number (0 = DATA0).
    reg [3:0]  in_tog, out_tog;
    // crc: running CRC16. remaining: payload bytes still to send. nbytes: payload bytes received so far, with the CRC included
    // (saturating). d1, d2: the last two received bytes. hs: PID byte (handshake or data) to send next.
    // timer: clocks of idle line while waiting for an answer.
    reg [15:0] crc;
    reg [9:0]  remaining;
    reg [10:0] nbytes;
    reg [7:0]  d1, d2;
    reg [7:0]  hs;
    reg [7:0]  timer;
    // acc: the endpoint accepts this OUT. stall_l: it answers STALL. wr_en: the bytes of this packet are written to the endpoint
    // (accepted and the toggle is the expected one). dtog: the toggle bit of the data packet received. sent_data: a data
    // packet (rather than a handshake) was sent. iso_l: the IN endpoint is isochronous.
    reg        acc, stall_l, wr_en, dtog, sent_data, iso_l;

    // Pulses default to 0 and are set for one clock; the toggle bits are cleared when the endpoint logic asks (tog_clear).
    always @(posedge clk) begin
        sof        <= 1'b0;
        out_wr     <= 1'b0;
        out_commit <= 1'b0;
        out_abort  <= 1'b0;
        in_rd      <= 1'b0;
        in_commit  <= 1'b0;
        in_rewind  <= 1'b0;
        in_tog     <= in_tog & ~tog_clear;
        out_tog    <= out_tog & ~tog_clear;
    // A bus reset or the main reset puts everything back, including the frame number and the toggles.
        if (rst || bus_reset) begin
            st       <= S_IDLE;
            tx_valid <= 1'b0;
            in_tog   <= 4'd0;
            out_tog  <= 4'd0;
            ep       <= 4'd0;
            ep_in    <= 1'b0;
            frame    <= 11'd0;
            out_setup <= 1'b0;
        end else begin
            case (st)
                // Idle: the first byte of a packet is a PID; a PID whose halves do not match is skipped, and so is any PID that is
                // not a token (a stray data or handshake packet).
                S_IDLE: if (rx_valid) begin
                    if (rx_data[3:0] != ~rx_data[7:4]) begin
                        st <= S_SKIP;
                    end else if (rx_data[3:0] == PID_OUT || rx_data[3:0] == PID_IN ||
                                 rx_data[3:0] == PID_SOF || rx_data[3:0] == PID_SETUP) begin
                        tokpid <= rx_data[3:0];
                        st     <= S_TOK1;
                    end else begin
                        st <= S_SKIP;
                    end
                end
                // Not a packet for us: wait for its end.
                S_SKIP: if (rx_eop || !rx_active) st <= S_IDLE;
                // Token bytes: low byte first (address and the low bits of the endpoint), then the rest and the CRC5.
                S_TOK1: begin
                    if (rx_valid) begin tok[7:0] <= rx_data; st <= S_TOK2; end
                    else if (rx_eop) st <= S_IDLE;
                end
                S_TOK2: begin
                    if (rx_valid) begin tok[15:8] <= rx_data; st <= S_TOK_EOP; end
                    else if (rx_eop) st <= S_IDLE;
                end
                // At the end of the packet the token is checked: no bit error and the CRC5 residual. A SOF gives the frame
                // number; another token has to carry our address, and then it selects the endpoint.
                S_TOK_EOP: begin
                    if (rx_valid) begin
                        st <= S_SKIP;
                    end else if (rx_eop) begin
                        st <= S_IDLE;
                        if (!rx_err && crc5_16(tok) == 5'h06) begin
                            if (tokpid == PID_SOF) begin
                                frame <= tok[10:0];
                                sof   <= 1'b1;
                            end else if (tok[6:0] == dev_addr) begin
                                ep        <= tok[10:7];
                                ep_in     <= (tokpid == PID_IN);
                                out_setup <= (tokpid == PID_SETUP);
                                sent_data <= 1'b0;
                                st        <= (tokpid == PID_IN) ? S_IN_DECIDE : S_OUT_DECIDE;
                            end
                        end
                    end
                end
                // IN token: STALL if halted, NAK if nothing is ready, otherwise send the data packet (an empty one for an
                // isochronous endpoint with nothing waiting). The data PID is DATA1 only when the toggle says so, never on isochronous.
                S_IN_DECIDE: begin
                    iso_l     <= in_iso;
                    if (!in_exists) begin
                        st <= S_IDLE;
                    end else if (in_stall) begin
                        hs <= HS_STALL; st <= S_HS;
                    end else if (!in_ready && !in_iso) begin
                        hs <= HS_NAK; st <= S_HS;
                    end else begin
                        remaining <= in_ready ? in_len : 10'd0;
                        hs <= (!in_iso && in_tog[ep]) ? {~PID_DATA1, PID_DATA1} : {~PID_DATA0, PID_DATA0};
                        st <= S_TX_PID;
                    end
                end
                // OUT or SETUP token: remember whether the endpoint can take the packet. A SETUP only exists on endpoint 0.
                S_OUT_DECIDE: begin
                    timer <= 8'd0;
                    if (!out_exists || (out_setup && ep != 4'd0)) begin
                        st <= S_IDLE;
                    end else begin
                        acc     <= out_setup || (out_ok && !out_stall);
                        stall_l <= !out_setup && out_stall;
                        st      <= S_WAIT_DATA;
                    end
                end
                // Wait for the data packet's PID; give up after 18 bit times of idle line.
                S_WAIT_DATA: begin
                    if (!rx_active) timer <= timer + 8'd1;
                    if (timer == TIMEOUT) st <= S_IDLE;
                    // data PID: write the payload only if the endpoint accepted the token and the toggle matches (a SETUP and an isochronous
                    // packet need no toggle match)
                    if (rx_valid) begin
                        if (rx_data[3:0] == ~rx_data[7:4] &&
                            (rx_data[3:0] == PID_DATA0 || rx_data[3:0] == PID_DATA1)) begin
                            dtog   <= rx_data[3];
                            wr_en  <= acc && (out_setup || out_iso || rx_data[3] == out_tog[ep]);
                            crc    <= 16'hFFFF;
                            nbytes <= 11'd0;
                            st     <= S_DATA;
                        end else begin
                            st <= S_SKIP;
                        end
                    end
                end
                // Receive the data packet. Every byte goes through the CRC, and is passed to the endpoint two bytes late, so the two CRC
                // bytes at the end are never written.
                S_DATA: begin
                    if (rx_valid) begin
                        crc <= crc16_byte(crc, rx_data);
                        if (nbytes != 11'h7FF) nbytes <= nbytes + 11'd1;
                        d1 <= rx_data;
                        d2 <= d1;
                        if (nbytes >= 11'd2 && wr_en) begin
                            out_wr   <= 1'b1;
                            out_data <= d2;
                        end
                    // End of the packet: a bit error, fewer than 2 bytes (no CRC) or a wrong CRC residual means the packet is dropped
                    // silently, without any handshake.
                    end else if (rx_eop) begin
                        if (rx_err || nbytes < 11'd2 || crc != 16'hB001) begin
                            out_abort <= 1'b1;         // corrupted: no answer at all
                            st <= S_IDLE;
                        end else begin
                            st <= S_HS;
                            if (out_setup) begin
                                out_commit <= 1'b1;
                                hs <= HS_ACK;
                                in_tog[0]  <= 1'b1;    // data/status stages start with DATA1
                                out_tog[0] <= 1'b1;
                            end else if (out_iso) begin
                                // isochronous (fpga-sdr): DATA0 whatever came before, no handshake
                                if (acc) out_commit <= 1'b1;
                                else     out_abort  <= 1'b1;
                                st <= S_IDLE;
                            end else if (stall_l) begin
                                out_abort <= 1'b1;
                                hs <= HS_STALL;
                            end else if (!acc) begin
                                out_abort <= 1'b1;
                                hs <= HS_NAK;
                            end else if (dtog != out_tog[ep]) begin
                                out_abort <= 1'b1;     // repeat of a packet we already have
                                hs <= HS_ACK;
                            end else begin
                                out_commit <= 1'b1;
                                out_tog[ep] <= ~out_tog[ep];
                                hs <= HS_ACK;
                            end
                        end
                    end
                end
                // Send a handshake byte, then wait for the PHY to finish.
                S_HS: begin
                    tx_valid <= 1'b1;
                    tx_data  <= hs;
                    if (tx_ready) begin
                        tx_valid <= 1'b0;
                        st <= S_TX_END;
                    end
                end
                // Send a data packet: the PID first, then payload, CRC16 low byte, CRC16 high byte, one byte per tx_ready.
                S_TX_PID: begin
                    tx_valid  <= 1'b1;
                    tx_data   <= hs;
                    crc       <= 16'hFFFF;
                    sent_data <= 1'b1;
                    st        <= S_TX_DATA;
                end
                S_TX_DATA: if (tx_ready) begin
                    if (remaining != 10'd0) begin
                        tx_data   <= in_data;
                        crc       <= crc16_byte(crc, in_data);
                        in_rd     <= 1'b1;
                        remaining <= remaining - 10'd1;
                    end else begin
                        tx_data <= ~crc[7:0];
                        st <= S_TX_CRC2;
                    end
                end
                S_TX_CRC2: if (tx_ready) begin
                    tx_data <= ~crc[15:8];
                    st <= S_TX_LAST;
                end
                S_TX_LAST: if (tx_ready) begin
                    tx_valid <= 1'b0;
                    st <= S_TX_END;
                end
                // Wait for the PHY to be idle again, then either finish (handshake or isochronous) or wait for the host's ACK.
                S_TX_END: if (!tx_busy && !tx_valid) begin
                    timer <= 8'd0;
                    if (!sent_data) st <= S_IDLE;          // handshake sent
                    else if (iso_l) begin
                        in_commit <= 1'b1;                 // isochronous: no handshake
                        st <= S_IDLE;
                    end else st <= S_WAIT_HS;
                end
                // Wait for the host's ACK; a timeout or anything else rewinds the endpoint so the packet is sent again.
                S_WAIT_HS: begin
                    if (!rx_active) timer <= timer + 8'd1;
                    if (timer == TIMEOUT) begin
                        in_rewind <= 1'b1;
                        st <= S_IDLE;
                    end
                    if (rx_valid) begin
                        if (rx_data == HS_ACK) st <= S_HS_EOP;
                        else begin
                            in_rewind <= 1'b1;
                            st <= S_SKIP;
                        end
                    end
                end
                // The ACK must be followed by the end of the packet: only then is the data packet committed and the toggle flipped.
                S_HS_EOP: begin
                    if (rx_valid) begin
                        in_rewind <= 1'b1;
                        st <= S_SKIP;
                    end else if (rx_eop) begin
                        st <= S_IDLE;
                        if (!rx_err) begin
                            in_commit  <= 1'b1;
                            in_tog[ep] <= ~in_tog[ep];
                        end else begin
                            in_rewind <= 1'b1;
                        end
                    end
                end
                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
