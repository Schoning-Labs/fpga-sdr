// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Taken from an earlier design by the same author; modified 2026 by
// Franz Schöning for fpga-sdr: a playback and a capture AudioStreaming interface instead of one recording interface and MIDI; no bulk endpoints (docs/USB_AUDIO.md).
//
// usb_ep0: control endpoint 0 of the USB sound card, which answers every request a host sends to find out what the
// device is and to set it up (this process is called enumeration), without any firmware. It is the endpoint that
// usb_audio.v connects to usb_fs_core.v whenever the token is for endpoint 0; its answers are either small values
// made on the spot or descriptors read out of a ROM that holds the data the PC wants to see. Because it is plain
// logic, the board shows up on a PC as a sound card as soon as the bitstream has loaded and the pull-up of the bus
// has been switched on (usb_audio.v).
//
// Control transfers and enumeration, for a beginner. Endpoint 0 is the one endpoint every USB device must have, and
// the host uses it for control transfers, which have up to three stages. In the setup stage the host sends a SETUP
// token and a data packet of exactly 8 bytes, the request: bmRequestType (bit 7 = direction, 1 means device to host,
// bits 6:5 = who defines the request, 0 = USB itself, 1 = the device class, bits 4:0 = whom it is for, 0 = device,
// 1 = interface, 2 = endpoint), bRequest (the request number), wValue and wIndex (two 16-bit arguments) and
// wLength (how many bytes the data stage may carry). An optional data stage follows, with IN or OUT packets
// starting with DATA1, and then a status stage in the opposite direction with a packet of zero length. After the
// host has reset the bus the device answers at address 0, and the host learns about it in a fixed order: it asks
// for the device descriptor (GET_DESCRIPTOR), which holds the USB version, the vendor and product numbers and the
// largest packet of endpoint 0; it assigns an address (SET_ADDRESS, which must only take effect after the status
// stage of that very request is done); it reads the configuration descriptor, which lists everything the device offers as
// a tree of interfaces and endpoints, and the string descriptors with the names; and it selects a configuration
// (SET_CONFIGURATION), after which the device is usable. A sound card of USB Audio Class 1.0 has one AudioControl
// interface (the knobs and the topology, no data) and one or more AudioStreaming interfaces, each of which has
// alternate setting 0 without any endpoint (the stream is switched off and takes no bandwidth) and alternate
// setting 1 with the isochronous endpoint (the stream is on); the host switches a stream on with SET_INTERFACE.
// Here there are three interfaces: 0 the AudioControl, 1 the playback AudioStreaming (PC to radio, endpoint 0x01 and
// its feedback endpoint 0x81) and 2 the capture AudioStreaming (radio to PC, endpoint 0x82); usb_ep_play.v and usb_ep_cap.v
// explain the isochronous side. Terms are in docs/learn/GLOSSARY.md.
//
// Requests (USB 2.0 section 9.4 unless marked):
//   GET_DESCRIPTOR       device, configuration 0, strings 0..5 from the ROM directory; anything
//                        else (including DEVICE_QUALIFIER, which a full-speed-only device must
//                        STALL: USB 2.0 9.6.2) -> STALL. Reply = min(descriptor length, wLength).
//   SET_ADDRESS          takes effect after the status stage.
//   SET/GET_CONFIGURATION value 0 or 1; setting it clears the halt flags and every toggle and
//                        returns the AudioStreaming interface to alternate setting 0.
//   SET/GET_INTERFACE    interfaces 1 (playback) and 2 (capture), both AudioStreaming: alt 0 or 1;
//                        interface 0: alt 0.
//   GET_STATUS           device (self-powered), interface, endpoint (never halted: every endpoint
//                        but 0 is isochronous).
//   SET/CLEAR_FEATURE    ENDPOINT_HALT and DEVICE_REMOTE_WAKEUP accepted and ignored; others STALL.
//   UAC1 endpoint requests (UAC1 5.2.3.2.3): SET_xxx to an endpoint with a data stage is
//                        accepted and ignored (only 48 kHz exists); GET_CUR/MIN/MAX/RES of the
//                        sampling frequency return 48000 (RES: 1).
// Everything else is answered with STALL until the next SETUP.
//
// Data stage: packets of up to USB_EP0_MAX (64) bytes; a zero-length packet ends a reply that is a
// whole number of packets long and shorter than wLength (USB 2.0 5.5.3). The host may end the
// data stage early by starting the status stage.
//
// The descriptor ROM. rom holds USB_ROM_SIZE (512) bytes read from ROM_FILE (rtl/usb/usb_desc_rom.hex, made by
// fw/tr-usb together with usb_desc_params.vh, so that the descriptors are written once, in Rust). The first
// USB_ROM_SLOTS (8) x 4 bytes are a directory, one slot per descriptor (offset and length, 16 bits each, low byte first):
// slot 0 the device descriptor, slot 1 the configuration descriptor with all its interfaces and endpoints (the
// host asks for it as one block), and slots 2 to 7 the string descriptors 0 to 5. A GET_DESCRIPTOR first reads the
// slot (E_DIR, 5 steps of one byte each), then sends the descriptor from its offset.
//
// Latency: a request is decoded in a few clocks after the end of the SETUP data packet, a byte of the reply is
// ready 1 clock after its address was set, and the core fetches the next byte only every 32 clocks, so the ROM has plenty of time.
//
// Gowin specifics: the ROM is a 512 x 8 bit memory with a registered read, which the tool puts into one block RAM
// and fills at configuration time with the contents of the hex file (so the file must be found at the path in ROM_FILE
// relative to where the tool or the simulator is started). No DSP and no clock line beyond clk_usb are involved.

`timescale 1ns / 1ps

// ROM_FILE: path of the descriptor hex file.
module usb_ep0 #(
    parameter ROM_FILE = "rtl/usb/usb_desc_rom.hex"
) (
    input  wire        clk,  // 48 MHz USB clock
    input  wire        rst,           // reset or bus reset (synchronous)
    // from usb_fs_core, already qualified for endpoint 0 (the core's token is for endpoint 0 and the right direction)
    input  wire        out_setup,  // 1 while the packet is a SETUP
    input  wire        out_wr,  // one-clock pulse: out_data is a byte of the packet
    input  wire [7:0]  out_data,  // the received byte (the 8 bytes of the request, or the data stage's)
    input  wire        out_commit,  // one-clock pulse: the packet was good
    input  wire        out_abort,  // one-clock pulse: the packet was bad
    output wire        out_ok,  // 1 = endpoint 0 can take an OUT packet now
    output wire        out_stall,  // 1 = endpoint 0 answers STALL
    output wire        in_ready,  // 1 = an IN packet is ready to be sent (data stage or status stage)
    output wire        in_stall,  // 1 = answer IN tokens with STALL
    output wire [9:0]  in_len,  // bytes in the packet to send (0 to 64)
    output wire [7:0]  in_data,  // the byte at the current position of the packet to send
    input  wire        in_rd,  // one-clock pulse: the core took the byte, step to the next
    input  wire        in_commit,  // one-clock pulse: the host acknowledged the packet
    input  wire        in_rewind,  // one-clock pulse: the host did not acknowledge, send the packet again from its start
    // device state
    // device state
    output reg  [6:0]  dev_addr,  // the address the host assigned (0 until SET_ADDRESS has finished)
    output reg         configured,  // 1 after SET_CONFIGURATION 1: the audio interfaces can be switched on
    output reg         alt_play,      // playback AudioStreaming interface: alternate setting (1 = streaming on)
    output reg         alt_cap,       // capture AudioStreaming interface: alternate setting (1 = streaming on)
    output reg  [3:0]  tog_clear      // one-clock pulse per endpoint number: sets that endpoint's data toggle back to DATA0
) /* synthesis syn_maxfan = 10000 syn_srlstyle = "registers" */;
    // The generated parameters: ROM size and slots, packet sizes, endpoint and interface numbers, 48000 Hz.
    `include "rtl/usb/usb_desc_params.vh"

    // NIF: interfaces in the configuration. RAW: ROM address bits.
    localparam integer NIF = USB_NUM_IFACES;
    localparam integer RAW = $clog2(USB_ROM_SIZE);
    // The descriptor ROM, with a registered read (that is what lets the tool use block RAM).
    reg [7:0] rom [0:USB_ROM_SIZE-1];
    initial $readmemh(ROM_FILE, rom);
    reg [RAW-1:0] rom_addr;
    reg [7:0]     rom_q;
    always @(posedge clk) rom_q <= rom[rom_addr];

    // States of the control transfer: wait for a SETUP, decode it, read the directory slot, send the data stage (IN), take the data
    // stage (OUT), the status stage (IN or OUT), and the STALL state that lasts until the next SETUP.
    localparam E_IDLE = 3'd0, E_DECODE = 3'd1, E_DIR = 3'd2, E_DATA_IN = 3'd3,
               E_DATA_OUT = 3'd4, E_STATUS_IN = 3'd5, E_STATUS_OUT = 3'd6, E_STALL = 3'd7;
    // su: the 8 bytes of the SETUP packet; su_idx counts them.
    reg [2:0]  st;

    reg [7:0]  su [0:7];
    reg [3:0]  su_idx;
    // The fields of the request: bmRequestType, bRequest, wValue, wIndex, wLength (the 16-bit fields come low byte first).
    wire [7:0]  bm   = su[0];
    wire [7:0]  breq = su[1];
    wire [15:0] wval = {su[3], su[2]};
    wire [15:0] widx = {su[5], su[4]};
    wire [15:0] wlen = {su[7], su[6]};

    // The reply being prepared.
    // from_rom: the reply comes from the ROM (else from reply[]). base: ROM offset of the descriptor.
    reg        from_rom;
    reg [RAW-1:0] base;
    reg [15:0] total;       // bytes to send in the data stage
    reg [15:0] pos, pos_c;  // position in the reply: tentative (moves with each byte read) and committed (at the last acknowledged packet)
    reg        zlp_due;     // 1 = a zero-length packet must follow the last full packet
    // reply[]: the short answers made on the spot (status words, the configuration number, the sampling frequency).
    reg [7:0]  reply [0:3];
    // new_addr: the address of a SET_ADDRESS, applied after its status stage (set_addr). dir_*: the directory read.
    reg [6:0]  new_addr;
    reg        set_addr;
    reg [2:0]  dir_k;       // directory read step
    reg [15:0] dir_off;
    reg [2:0]  dir_slot;

    // Bytes of the reply not yet acknowledged, and the size of the next packet (at most USB_EP0_MAX).
    wire [15:0] left = total - pos_c;
    wire [15:0] pkt  = (left > USB_EP0_MAX) ? USB_EP0_MAX[15:0] : left;

    // What the core sees: a packet to send in the data stage and the status stage, the byte at pos, and the STALL state.
    assign in_ready  = (st == E_DATA_IN) || (st == E_STATUS_IN);
    assign in_len    = (st == E_DATA_IN) ? pkt[9:0] : 10'd0;
    assign in_data   = from_rom ? rom_q : reply[pos[1:0]];
    assign in_stall  = (st == E_STALL);
    assign out_stall = (st == E_STALL);
    // OUT packets are accepted as a data stage (E_DATA_OUT), as the status stage of a read, or while a read is still going on
    // (the host may go on to the status stage early)
    assign out_ok    = (st == E_DATA_OUT) || (st == E_STATUS_OUT) || (st == E_DATA_IN);

    // ROM address: the directory entry while reading it (slot x 4 + the byte number), else the descriptor's offset + position.
    always @(*) begin
        if (st == E_DIR) rom_addr = {dir_slot, 2'b00} + dir_k[1:0];
        else             rom_addr = base + pos[RAW-1:0];
    end

    // Starts a short reply made of reply[0..], n bytes long, cut to wLength.
    task start_reply_regs(input integer n);
        begin
            from_rom <= 1'b0;
            total    <= (wlen < n) ? wlen : n;
            st       <= E_DATA_IN;
        end
    endtask

    // The control endpoint's state machine, with the pulses cleared every clock.
    always @(posedge clk) begin
        tog_clear <= 4'd0;
        if (rst) begin
            st         <= E_IDLE;
            dev_addr   <= 7'd0;
            configured <= 1'b0;
            alt_play   <= 1'b0;
            alt_cap    <= 1'b0;
            su_idx     <= 4'd0;
            set_addr   <= 1'b0;
            pos        <= 16'd0;
            pos_c      <= 16'd0;
            from_rom   <= 1'b0;
            base       <= {RAW{1'b0}};
            reply[3]   <= 8'd0;
        end else begin
            // ---- incoming bytes: the 8 request bytes of a SETUP go into su; a bad packet starts over
            if (out_wr && out_setup) begin
                if (su_idx < 4'd8) su[su_idx[2:0]] <= out_data;
                su_idx <= su_idx + 4'd1;
            end
            if (out_abort) su_idx <= 4'd0;

            // A good SETUP packet: restart the reply and decode the request if all 8 bytes came, else STALL.
            if (out_commit && out_setup) begin
                su_idx <= 4'd0;
                pos    <= 16'd0;
                pos_c  <= 16'd0;
                zlp_due <= 1'b0;
                set_addr <= 1'b0;
                st <= (su_idx == 4'd8) ? E_DECODE : E_STALL;
            end else begin
                case (st)
                    // Decode the request. bmRequestType[6:5] = 0 is a standard request; the class requests (type 1) for the
                    // sampling frequency of the audio endpoint come after it.
                    E_DECODE: begin
                        st <= E_STALL;       // unless a case below accepts the request
                        if (bm[6:5] == 2'b00) begin
                            case (breq)
                                8'h00: begin // GET_STATUS: device 2 bytes, bit 0 = self-powered; interface and endpoint: 0
                                    if (bm == 8'h80) begin
                                        reply[0] <= 8'h01; reply[1] <= 8'h00; start_reply_regs(2);
                                    end else if (bm == 8'h81) begin
                                        reply[0] <= 8'h00; reply[1] <= 8'h00; start_reply_regs(2);
                                    end else if (bm == 8'h82) begin
                                        reply[0] <= 8'h00;
                                        reply[1] <= 8'h00; start_reply_regs(2);
                                    end
                                end
                                8'h01, 8'h03: begin // CLEAR_FEATURE, SET_FEATURE
                                    if (bm == 8'h02 && wval == 16'd0) begin
                                        st <= E_STATUS_IN;           // endpoint halt: ignored
                                    end else if (bm == 8'h00 && wval == 16'd1) begin
                                        st <= E_STATUS_IN;           // remote wakeup: ignored
                                    end
                                end
                                8'h05: if (bm == 8'h00) begin    // SET_ADDRESS (applied after the status stage)
                                    new_addr <= wval[6:0];
                                    set_addr <= 1'b1;
                                    st <= E_STATUS_IN;
                                end
                                8'h06: if (bm == 8'h80) begin    // GET_DESCRIPTOR: wValue high = type (1 device, 2 configuration, 3 string), low = index
                                    if (wval[15:8] == 8'd1) begin
                                        dir_slot <= 3'd0; dir_k <= 3'd0; st <= E_DIR;
                                    end else if (wval[15:8] == 8'd2 && wval[7:0] == 8'd0) begin
                                        dir_slot <= 3'd1; dir_k <= 3'd0; st <= E_DIR;
                                    end else if (wval[15:8] == 8'd3 && wval[7:0] < USB_ROM_SLOTS - 2) begin
                                        dir_slot <= wval[2:0] + 3'd2; dir_k <= 3'd0; st <= E_DIR;
                                    end
                                end
                                8'h08: if (bm == 8'h80) begin    // GET_CONFIGURATION
                                    reply[0] <= {7'd0, configured}; start_reply_regs(1);
                                end
                                8'h09: if (bm == 8'h00) begin    // SET_CONFIGURATION: back to alternate setting 0, toggles of endpoints 1 to 3 cleared
                                    if (wval == 16'd0 || wval == USB_CONFIG_VALUE) begin
                                        configured <= (wval != 16'd0);
                                        alt_play  <= 1'b0;
                                        alt_cap   <= 1'b0;
                                        tog_clear <= 4'b1110;
                                        st <= E_STATUS_IN;
                                    end
                                end
                                8'h0A: if (bm == 8'h81 && configured && widx < NIF) begin  // GET_INTERFACE
                                    reply[0] <= {7'd0, (widx == USB_IF_PLAY) ? alt_play :
                                                       (widx == USB_IF_CAP)  ? alt_cap : 1'b0};
                                    start_reply_regs(1);
                                end
                                8'h0B: if (bm == 8'h01 && configured) begin // SET_INTERFACE: switches a stream on (1) or off (0)
                                    if (widx == USB_IF_PLAY && wval < 16'd2) begin
                                        alt_play <= wval[0];
                                        tog_clear[USB_EP_PLAY] <= 1'b1;
                                        st <= E_STATUS_IN;
                                    end else if (widx == USB_IF_CAP && wval < 16'd2) begin
                                        alt_cap <= wval[0];
                                        tog_clear[USB_EP_CAP] <= 1'b1;
                                        st <= E_STATUS_IN;
                                    end else if (widx < NIF && wval == 16'd0) begin
                                        st <= E_STATUS_IN;
                                    end
                                end
                                default: ;
                            endcase
                        end else if (bm == 8'h22 && breq[7] == 1'b0 && wlen != 16'd0) begin
                            st <= E_DATA_OUT;              // UAC1 SET_xxx to the endpoint
                        end else if (bm == 8'hA2 && wval[15:8] == 8'h01 &&
                                     breq >= 8'h81 && breq <= 8'h84) begin
                            // UAC1 GET_CUR/MIN/MAX/RES, sampling frequency control
                            if (breq == 8'h84) begin
                                reply[0] <= 8'd1; reply[1] <= 8'd0; reply[2] <= 8'd0;
                            end else begin
                                reply[0] <= USB_SAMPLE_RATE[7:0];
                                reply[1] <= USB_SAMPLE_RATE[15:8];
                                reply[2] <= USB_SAMPLE_RATE[23:16];
                            end
                            start_reply_regs(3);
                        end
                    end
                        // Read the directory slot: bytes offset low, offset high, length low, length high, one per clock.
                    E_DIR: begin
                        // rom_addr = slot*4 + k; rom_q holds the byte of step k-1
                        dir_k <= dir_k + 3'd1;
                        case (dir_k)
                            3'd1: dir_off[7:0]  <= rom_q;
                            3'd2: dir_off[15:8] <= rom_q;
                            3'd3: total[7:0]    <= rom_q;
                            3'd4: begin
                                total <= ({rom_q, total[7:0]} < wlen) ? {rom_q, total[7:0]} : wlen;
                                base  <= dir_off[RAW-1:0];
                                from_rom <= 1'b1;
                                st <= ({rom_q, total[7:0]} == 16'd0) ? E_STALL : E_DATA_IN;
                            end
                            default: ;
                        endcase
                    end
                    // Data stage of a read: send packets of up to 64 bytes; an acknowledged packet moves the committed position,
                    // and a full packet at the end of a reply shorter than wLength is followed by a zero-length one.
                    E_DATA_IN: begin
                        if (in_rd) pos <= pos + 16'd1;
                        if (in_rewind) pos <= pos_c;
                        if (in_commit) begin
                            pos_c <= pos;
                            if (zlp_due) begin
                                st <= E_STATUS_OUT;
                            end else if (pkt < USB_EP0_MAX || pos == total) begin
                                // short packet, or the reply is complete
                                if (pkt == USB_EP0_MAX && total < wlen) zlp_due <= 1'b1;
                                else st <= E_STATUS_OUT;
                            end
                        end
                        if (out_commit) st <= E_IDLE;     // host went on to the status stage
                    end
                    // Data stage of a write (class request): only a status stage follows.
                    E_DATA_OUT: begin
                        // The only requests with a data stage (UAC1 SET_xxx) carry 3 bytes, one
                        // packet; the bytes are not used.
                        if (out_commit) st <= E_STATUS_IN;
                    end
                    // Status stage of a write: the zero-length IN packet; a pending address takes effect when it is acknowledged.
                    E_STATUS_IN: if (in_commit) begin
                        st <= E_IDLE;
                        if (set_addr) dev_addr <= new_addr;
                    end
                    // Status stage of a read: the host's zero-length OUT packet.
                    E_STATUS_OUT: if (out_commit) st <= E_IDLE;
                    default: ;
                endcase
            end
        end
    end

endmodule
