// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Frame sender of the minimal Hermes-Lite 2 test build (docs/HL2MIN.md section 4): it makes the few
// frames that the HL2 needs to start streaming, in logic and without a processor.
//
// What the HL2 expects (docs/rawfront/PROTOCOL.md sections 2 to 5 on the Hermes-Lite 2 release
// branch): small UDP datagrams whose payload starts with the bytes EF FE, the signature of the
// openHPSDR protocol that the HL2 speaks, followed by a command byte:
//   discovery    `EF FE 02` + 57 zero bytes, UDP to port 1025, broadcast (MAC ff:ff:ff:ff:ff:ff, IP 255.255.255.255).
//                Every HL2 on the network answers with its addresses, which is how this build learns them.
//   stop         `EF FE 04 00` + 60 zero bytes, UDP to port 1024, to the HL2's MAC and IP
//   raw mode     `EF FE 05 7F 60 D3 D2 D1 D0` + 51 zero bytes, UDP to port 1025, to the HL2's MAC and IP: a write of
//                register 0x30 (address byte 0x60 = 0x30 x 2, whose bit 0 is the openHPSDR MOX bit, here 0) with the
//                value REG30, which switches the HL2 to raw sample frames and sets their size and test pattern
//   start        `EF FE 04 81` + 60 zero bytes, UDP to port 1024, to the HL2's MAC and IP (bit 0 run, bit 7
//                watchdog off)
// Once a second (`tick`) it sends a discovery, and while the HL2 is known (`known`, meaning that its
// MAC and IP were taken from its discovery reply) but no raw frame has arrived in the last second
// (`streaming` 0) it also sends stop, raw mode and start, in that order. The HL2's gateware takes
// register writes only unicast to port 1025 (dsopenhpsdr1.v), so these three go to its own addresses.
//
// SAFETY: these four are the only frames that this module can make (one case statement, below). None of
// them reaches the HL2's transmit path: there is no TX_PERMIT write (that needs the register bridge on
// port 1027, PROTOCOL.md 9.1), no write to register 0x09 (PA enable, TX gain), 0x31 (duplex, real DAC)
// or 0x3A to 0x3D, no EP2 frame (EF FE 01) and no flash command (EF FE 03), and the MOX bit of the
// register write is 0. With duplex off (register 0x31 is never written, and is 0 after the HL2 starts)
// its transmit sink takes no samples.
//
// How a frame is built: 14 bytes of Ethernet header (destination MAC, our MAC, EtherType 0x0800), 20
// bytes of IPv4 header (version and length 0x45, total length, identification 0, flags 0x4000 "do not
// fragment", time to live 64, protocol 17 for UDP, header checksum, our IP, the destination IP), 8 bytes
// of UDP header (source port MY_PORT, destination port, length, checksum 0, which UDP over IPv4 allows),
// and the payload. A frame is 42 header bytes plus a payload of 60 bytes (discovery and raw mode) or 64
// bytes (stop and start), which is above the 46 bytes of payload that Ethernet needs, so no padding is
// required. The IPv4 header checksum is computed here from the addresses and the length.
// The frame leaves, one byte per clock, through rtl/n1/fcs_append.v (which adds the 4-byte frame check
// sequence) and rtl/hl2link/gmii_tx_out.v (preamble, start-of-frame delimiter, 12-byte gap and link
// gate) to the lane's PCS. Our side is MAC MY_MAC, IP MY_IP and UDP port MY_PORT, the address to which
// the raw stream comes back.

`timescale 1ns / 1ps

module hl2min_sender #(
    parameter [47:0] MY_MAC  = 48'h02_54_52_00_00_01,
    parameter [31:0] MY_IP   = 32'hA9FE_4D01,     // 169.254.77.1
    parameter [15:0] MY_PORT = 16'd51000,
    parameter [31:0] REG30   = 32'h03C8_0003      // N = 968, test pattern, raw mode on
) (
    input  wire        clk,                       // sfp_txc
    input  wire        rst,                       // synchronous reset, active high
    input  wire        tick,                      // once a second
    input  wire        known,                     // the HL2's MAC and IP have been learned
    input  wire [47:0] hl2_mac,                   // the HL2's MAC address
    input  wire [31:0] hl2_ip,                    // the HL2's IPv4 address
    input  wire        streaming,                 // raw frames arrived in the last second
    input  wire        link_up,                   // the PCS sends data
    output wire [7:0]  gmii_txd,                  // byte to the PCS
    output wire        gmii_tx_en,                // the byte is part of a frame
    output reg  [15:0] cnt_sent = 16'd0           // frames sent since reset
);
    // frame types
    localparam [1:0] F_DISC = 2'd0, F_STOP = 2'd1, F_REG = 2'd2, F_START = 2'd3;

    reg  [1:0]  ft = F_DISC;                     // type of the frame being sent
    reg         sending = 1'b0;                  // the frame bytes are being produced
    reg  [6:0]  bi = 7'd0;                       // byte of the frame
    reg  [3:0]  todo = 4'd0;                     // frames still to send this second: bit per type
    reg  [47:0] dmac = 48'd0;                    // destination MAC of the frame being sent
    reg  [31:0] dip = 32'd0;                     // destination IP
    reg  [15:0] dport = 16'd0;                   // destination UDP port
    reg  [15:0] csum = 16'd0;                    // IPv4 header checksum
    wire [6:0]  plen = (ft == F_STOP || ft == F_START) ? 7'd64 : 7'd60;   // UDP payload
    wire [6:0]  flen = 7'd42 + plen;                                    // frame without FCS
    wire [15:0] iplen = {9'd0, plen} + 16'd28;
    wire [15:0] udplen = {9'd0, plen} + 16'd8;

    // IPv4 header checksum: the one's complement of the sum of the ten 16-bit words of the header
    // (the carry out of bit 15 is added back in at the bottom, the two "fold" lines), with the
    // checksum field counted as zero, over: 4500, length, 0000 (id), 4000 (DF), 4011 (TTL 64, UDP), source, destination
    function [15:0] ipsum(input [15:0] len, input [31:0] src, input [31:0] dst);
        reg [19:0] t;
        begin
            t = 20'h04500 + len + 20'h04000 + 20'h04011 + src[31:16] + src[15:0] + dst[31:16] + dst[15:0];
            t = {4'd0, t[15:0]} + {16'd0, t[19:16]};
            t = {4'd0, t[15:0]} + {16'd0, t[19:16]};
            ipsum = ~t[15:0];
        end
    endfunction

    // payload byte k (UDP payload): EF FE, the command byte, then zeros except for the arguments
    function [7:0] pay(input [1:0] f, input [6:0] k);
        begin
            pay = 8'h00;
            if (k == 7'd0) pay = 8'hEF;
            else if (k == 7'd1) pay = 8'hFE;
            else case (f)
                F_DISC:  if (k == 7'd2) pay = 8'h02;
                F_STOP:  if (k == 7'd2) pay = 8'h04;                    // byte 3 = 0: stop
                F_START: if (k == 7'd2) pay = 8'h04; else if (k == 7'd3) pay = 8'h81;
                default: case (k)                                       // register write (port 1025)
                             7'd2: pay = 8'h05;
                             7'd3: pay = 8'h7F;
                             7'd4: pay = 8'h60;                         // register 0x30, MOX bit 0
                             7'd5: pay = REG30[31:24];
                             7'd6: pay = REG30[23:16];
                             7'd7: pay = REG30[15:8];
                             7'd8: pay = REG30[7:0];
                             default: pay = 8'h00;
                         endcase
            endcase
        end
    endfunction

    // The byte of the frame at position `bi`: Ethernet header (0 to 13), IPv4 header (14 to 33), UDP
    // header (34 to 41), then the payload.
    reg [7:0] b;
    always @* begin
        case (bi)
            7'd0:  b = dmac[47:40]; 7'd1: b = dmac[39:32]; 7'd2: b = dmac[31:24];
            7'd3:  b = dmac[23:16]; 7'd4: b = dmac[15:8];  7'd5: b = dmac[7:0];
            7'd6:  b = MY_MAC[47:40]; 7'd7: b = MY_MAC[39:32]; 7'd8: b = MY_MAC[31:24];
            7'd9:  b = MY_MAC[23:16]; 7'd10: b = MY_MAC[15:8]; 7'd11: b = MY_MAC[7:0];
            7'd12: b = 8'h08; 7'd13: b = 8'h00;
            7'd14: b = 8'h45; 7'd15: b = 8'h00; 7'd16: b = iplen[15:8]; 7'd17: b = iplen[7:0];
            7'd18: b = 8'h00; 7'd19: b = 8'h00; 7'd20: b = 8'h40; 7'd21: b = 8'h00;
            7'd22: b = 8'h40; 7'd23: b = 8'h11; 7'd24: b = csum[15:8]; 7'd25: b = csum[7:0];
            7'd26: b = MY_IP[31:24]; 7'd27: b = MY_IP[23:16]; 7'd28: b = MY_IP[15:8]; 7'd29: b = MY_IP[7:0];
            7'd30: b = dip[31:24]; 7'd31: b = dip[23:16]; 7'd32: b = dip[15:8]; 7'd33: b = dip[7:0];
            7'd34: b = MY_PORT[15:8]; 7'd35: b = MY_PORT[7:0]; 7'd36: b = dport[15:8]; 7'd37: b = dport[7:0];
            7'd38: b = udplen[15:8]; 7'd39: b = udplen[7:0]; 7'd40: b = 8'h00; 7'd41: b = 8'h00;
            default: b = pay(ft, bi - 7'd42);
        endcase
    end

    // Sequencing: `todo` holds one bit per frame type still to send in this second (discovery,
    // stop, raw mode, start). When the wire is free the lowest bit set is taken, the destination
    // and checksum are loaded, and the frame bytes are produced one per clock. `start_d` keeps the
    // next frame from starting in the clock after this one, until the wire reports busy.
    wire wire_active;
    reg  start_d = 1'b0;
    always @(posedge clk) begin
        start_d <= 1'b0;
        if (rst) begin
            sending <= 1'b0; todo <= 4'd0; cnt_sent <= 16'd0;
        end else begin
            if (tick) todo <= (known && !streaming) ? 4'b1111 : 4'b0001;
            if (sending) begin
                if (bi == flen - 7'd1) sending <= 1'b0; else bi <= bi + 7'd1;
            end else if (!wire_active && !start_d && (todo != 4'd0)) begin
                // next frame in the order discovery, stop, raw mode, start
                sending <= 1'b1; bi <= 7'd0; start_d <= 1'b1; cnt_sent <= cnt_sent + 16'd1;
                if (todo[0]) begin
                    ft <= F_DISC; todo[0] <= 1'b0; dmac <= 48'hFFFF_FFFF_FFFF; dip <= 32'hFFFF_FFFF; dport <= 16'd1025;
                    csum <= ipsum(16'd88, MY_IP, 32'hFFFF_FFFF);
                end else if (todo[1]) begin
                    ft <= F_STOP; todo[1] <= 1'b0; dmac <= hl2_mac; dip <= hl2_ip; dport <= 16'd1024;
                    csum <= ipsum(16'd92, MY_IP, hl2_ip);
                end else if (todo[2]) begin
                    ft <= F_REG; todo[2] <= 1'b0; dmac <= hl2_mac; dip <= hl2_ip; dport <= 16'd1025;
                    csum <= ipsum(16'd88, MY_IP, hl2_ip);
                end else begin
                    ft <= F_START; todo[3] <= 1'b0; dmac <= hl2_mac; dip <= hl2_ip; dport <= 16'd1024;
                    csum <= ipsum(16'd92, MY_IP, hl2_ip);
                end
            end
        end
    end

    // Frame check sequence and preamble, gap and link gate, to the PCS.
    wire [7:0] app_d;
    wire       app_en;
    fcs_append u_fcs (.clk(clk), .rst(rst), .in_data(b), .in_enable(sending), .out_data(app_d), .out_enable(app_en));
    gmii_tx_out u_out (.clk(clk), .data(app_d), .tx_enable(app_en), .link_up(link_up), .active(wire_active),
                       .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en));
endmodule
