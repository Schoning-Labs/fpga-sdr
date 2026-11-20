// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Testbench for the minimal HL2 test build (docs/HL2MIN.md section 7): the whole of rtl/hl2min/hl2min_core.v, as
// rtl/hl2min/hl2min_top.v wires it (everything except the pins and Gowin's transceiver block), against models of everything
// around it. The minimal build is a small design without a processor that brings up the real Hermes-Lite 2 (HL2) over an
// SFP cage and counts every lost packet, so this bench is its full dress rehearsal: the I2C setup of the clock chip, the
// auto-negotiation of the copper SFP module, the discovery and start of the HL2, and the receive of its raw sample stream.
// The terms used below (SFP, PCS, 8b/10b, ordered set, auto-negotiation, I2C) are explained in docs/learn/GLOSSARY.md.
//
// The surroundings, one model each:
//   - a clock chip on the I2C bus (answers at address 0x60, records the register writes, and shows SYS_INIT in register 0 on
//     its first two reads);
//   - the transceiver lane, as sim/sfp/sfp_lane_model.v (the receive words are cut at an arbitrary bit position). With
//     -DGAPS (the default of run.sh) the receive buffer is read by a clock 2.56 % faster than the words come, so some receive
//     clocks carry no word, as in sim/sfp/tb_sfp_net.v;
//   - the copper SFP module, written here from IEEE 802.3 clauses 36 and 37 and not from our own PCS: auto-negotiation in
//     1000BASE-X, then idle and the HL2's frames with start, end and carrier extend codes (/S/, /T/, /R/) on even
//     positions, and an elastic queue between the HL2's bytes and its symbols (a frame that starts on an odd position
//     waits one symbol, and idle is dropped to win the time back);
//   - the HL2: its own send RTL (rawstream.v, udp_send, ip_send, mac_send and rgmii_send, copied into sim/h1_link_rx/hl2
//     and used by tb_h1_link_rx.v too) in test pattern mode, on a clock that is PPM parts per million off ours (+100 by
//     default, -100 with -DPPM_NEG). Its command side is a model in this bench: it takes our frames off the line, checks their
//     FCS and their kind, answers a discovery, accepts register 0x30, and starts and stops the stream on command. Any
//     other frame from us counts as a safety error, since the radio must never send the HL2 anything else.
// To keep the run short the core's "second" is 200 us and its UART runs at 12.5 Mbaud, and the bench prints every UART line.
//
// Pass: the clock chip got its 40 register writes, the multiplexer is on channel 3, the PCS link is up, the right cage's
// transmitter is on and the right lane's PCS is released, the chip ID shows on every UART line, the core has learned the
// HL2's addresses, none of our frames had a bad FCS, the HL2 was started, more than 50 raw frames came in, and there was no
// loss at all (lost frames, bad FCS, length errors, overflows, fill samples, pattern errors all 0, the HL2's own FIFO never
// overflowed, no safety error). With -DGAPS the bench also demands more than 1000 clocks without a word. It prints
// "PASS", or "FAIL: n errors" after the individual ERROR lines.
// -DDROP: one byte of one raw frame is corrupted on the line, and then exactly one frame must count as lost, with one bad FCS.
// -DLANE1: the core is built for lane 1 (HL2MIN_LANE=1) and the bench is that lane, which checks that cage SFP1's
// transmitter is the one switched on and lane 1's PCS the one released.
//
// Run, from the repo root: bash sim/hl2min/run.sh   (or with -DSIM_SECS=<n> for a longer run than the default 16 UART lines)

`timescale 1ns / 1ps

// The HL2's send RTL and the FIFO model it needs (see dcfifo_sim_stub.v).
`include "sim/h1_link_rx/dcfifo_sim_stub.v"
`include "sim/h1_link_rx/hl2/rawstream.v"
`include "sim/h1_link_rx/hl2/udp_send.v"
`include "sim/h1_link_rx/hl2/ip_send.v"
`include "sim/h1_link_rx/hl2/mac_send.v"
`include "sim/h1_link_rx/hl2/crc32.v"
`include "sim/h1_link_rx/hl2/rgmii_send.v"
// Picosecond timescale for the delays below, set after the includes so that the last included file's own directive does not win.
`timescale 1ps / 1fs

module tb_hl2min;
// 8b/10b encode and decode functions (enc8b10b_d, enc8b10b_k, dec8b10b), found through the -I rtl/n1 of run.sh.
`include "tab_8b10b.vh"

    localparam [47:0] HL2_MAC = 48'h02_00_00_00_00_02;
    localparam [31:0] HL2_IP  = 32'h0a63_0002;
    localparam [47:0] MY_MAC  = 48'h02_54_52_00_00_01;     // the core's defaults
    localparam [31:0] MY_IP   = 32'hA9FE_4D01;
    localparam [15:0] MY_PORT = 16'd51000;
    // HL2 register 0x30 as the core writes it: N = 968 samples per frame in the top 16 bits (0x03C8), bit 1 test pattern, bit 0 raw mode.
    localparam [31:0] REG30   = 32'h03C8_0003;
    // clk_50m clocks per UART bit: 50 MHz / 4 = 12.5 Mbaud.
    localparam integer BAUD   = 4;
`ifdef LANE1
    localparam integer LANE = 1;
`else
    localparam integer LANE = 0;
`endif
`ifdef SIM_SECS
    localparam integer SECS = `SIM_SECS;
`else
    localparam integer SECS = 16;
`endif

    // ------------------------------------------------------------------ clocks (ps)
    // clk_50m: 50 MHz (half period 10,000 ps). sfp_txc: the lane's 125 MHz transmit word clock (1.25 Gbit/s in 10 bit words),
    // offset by 1300 ps. pclk is the HL2's 125 MHz byte clock and clk_ad its 76.8 MHz sample clock, both run off by
    // 100 ppm from the nominal 4000 ps and 6510.4167 ps half periods, so that the HL2 is faster than we expect
    // (PH = 4000 / 1.0001 = 3999.6 ps) or, with -DPPM_NEG, slower (4000 * 1.0001 = 4000.4 ps). The receive side has to absorb that.
    // ------------------------------------------------------------------ clocks (ps)
    reg clk_50m = 0;  always #10000 clk_50m = ~clk_50m;
    reg sfp_txc = 0;  initial begin #1300; forever #4000 sfp_txc = ~sfp_txc; end
`ifdef PPM_NEG
    localparam real PH = 4000.4, PAD = 6510.4167 * 1.0001;      // the HL2 100 ppm slow
`else
    localparam real PH = 3999.6, PAD = 6510.4167 / 1.0001;      // the HL2 100 ppm fast
`endif
    reg pclk = 0;     initial begin #2100; forever #(PH) pclk = ~pclk; end
    reg clk_ad = 0;   initial begin #1733; forever #(PAD) clk_ad = ~clk_ad; end

    integer errors = 0;
    // The comparison is `!== 1'b1` so that a condition that evaluates to X counts as a failure.
    `define CHECK(cond, msg) if ((cond) !== 1'b1) begin errors = errors + 1; $display("ERROR t=%0t: %s", $time, msg); end

    // ------------------------------------------------------------------ DUT
    wire [9:0]  ln0_tx, d_rx;
    wire        d_rxc, scl_o, sda_o, uart_txd;
    wire [1:0]  ln_rst_n, ln_rx_rst, ln_tx_rst, txdis;
    wire [3:0]  led_on;
    wire        n19, p19, p26, por_n;
    reg         rst = 1'b1;
    wire        scl, sda;
    reg         s_sda = 1'b1;          // clock chip model: 0 = pulls SDA low
    assign scl = scl_o;
    assign sda = sda_o & s_sda;
    wire [9:0]  p_tx;
    reg  [9:0]  line_err = 10'd0;

`ifdef GAPS
    // With GAPS, the lane's receive words are queued (256 entries) and read by a clock of 7800 ps period, 2.56 % faster than the
    // 125 MHz word clock, so some of its clocks find the queue empty and carry no word (g_vld 0). `gaps` counts them.
    reg g_rxc = 0;  initial begin #700; forever #3900 g_rxc = ~g_rxc; end
    reg [9:0] gq [0:255];
    integer gw = 0, gr = 0, gaps = 0;
    reg [9:0] g_rx = 10'd0;
    reg       g_vld = 1'b0;
    always @(posedge d_rxc) begin gq[gw % 256] = d_rx; gw = gw + 1; end
    always @(posedge g_rxc) begin
        if (gr < gw - 2) begin g_rx <= gq[gr % 256]; g_vld <= 1'b1; gr = gr + 1; end
        else begin g_vld <= 1'b0; gaps = gaps + 1; end
    end
`else
    wire       g_rxc = d_rxc;
    wire [9:0] g_rx = d_rx;
    wire       g_vld = 1'b1;
`endif

    // The core with shortened times. CLK_HZ and SEC_CLKS make its "second" 10,000 clk_50m clocks = 200 us, BAUD_DIV is
    // clocks per UART bit, I2C_QDIV = 4 gives about 3 Mbit/s on I2C instead of 100 kbit/s (50 MHz / (4 * 4)), and TIMER_X = 3000
    // shortens the PCS link timer from 10 ms to 24 us of sfp_txc.
    hl2min_core #(.CLK_HZ(200_000), .SEC_CLKS(10_000), .BAUD_DIV(BAUD), .I2C_QDIV(4), .TIMER_X(3000), .LANE(LANE)) dut (
        .clk_50m(clk_50m), .rst(rst),
        .sfp_txc(sfp_txc), .n1_rxc(g_rxc), .ln0_tx(ln0_tx), .ln0_rx(g_rx), .ln0_rx_vld(g_vld),
        .serdes_por_n(por_n), .ln_rst_n(ln_rst_n), .ln_rx_rst(ln_rx_rst), .ln_tx_rst(ln_tx_rst),
        .ln0_stat({3'b111, ln_rst_n[LANE]}), .sfp_diag(12'h0), .sfp_tx_disable(txdis),
        .twi_scl_o(scl_o), .twi_sda_o(sda_o), .twi_scl_i(scl), .twi_sda_i(sda),
        .sel_n19(n19), .sel_p19(p19), .sel_p26(p26), .uart_txd(uart_txd), .led_on(led_on)
    );
    // The lane model between the bench's module side (pclk, p_tx) and the core (the core's transmit words come out through
    // ln0_tx), with a receive word cut at OFFSET (4) bits and the option to flip bits of a word through `err`.
    sfp_lane_model #(.W(10), .OFFSET(4)) u_to_dut (
        .tx_clk(pclk), .tx_word(p_tx), .rx_clk(d_rxc), .rx_word(d_rx), .err(line_err), .cut(1'b0));

    // ------------------------------------------------------------------ clock chip (I2C slave at 0x60)
    // Just enough of the clock chip for the core's start-up: it acknowledges the address 0x60 and every byte after, remembers
    // the register number and counts the register writes (the last register and value are kept for the check), and
    // answers reads of register 0 with SYS_INIT (bit 7) set for the first two reads and clear afterwards, as the chip
    // reports when it has finished its own initialization. SDA is wired-AND, so pulling it low is `s_sda` = 0.
    // ------------------------------------------------------------------ clock chip (I2C slave at 0x60)
    integer cc_bit = 0, cc_byte = 0, cc_writes = 0, cc_reads = 0;
    reg [7:0] cc_sh = 0, cc_reg = 0, cc_last_reg = 0, cc_last_val = 0, cc_out = 0;
    reg       cc_rd = 0, cc_on = 0, cc_reading = 0;
    always @(negedge sda) if (scl) begin cc_on = 1; cc_bit = 0; cc_byte = 0; cc_reading = 0; end   // start
    always @(posedge sda) if (scl) begin cc_on = 0; s_sda <= 1'b1; end                              // stop
    always @(posedge scl) if (cc_on) begin
        if (cc_bit < 8) cc_sh = {cc_sh[6:0], sda};
        cc_bit = cc_bit + 1;
    end
    always @(negedge scl) if (cc_on) begin
        #2000;
        if (cc_bit == 8) begin                                // acknowledge slot
            if (cc_reading) s_sda <= 1'b1;
            else if (cc_byte == 0) begin cc_rd = cc_sh[0]; s_sda <= (cc_sh[7:1] == 7'h60) ? 1'b0 : 1'b1; end
            else begin
                s_sda <= 1'b0;
                if (cc_byte == 1) cc_reg = cc_sh;
                else begin cc_last_reg = cc_reg; cc_last_val = cc_sh; cc_writes = cc_writes + 1; end
            end
        end else if (cc_bit == 9) begin                        // the byte is over
            cc_bit = 0; cc_byte = cc_byte + 1;
            if (cc_byte == 1 && cc_rd) begin                  // read: register 0, SYS_INIT on the first two reads
                cc_reading = 1; cc_reads = cc_reads + 1;
                cc_out = (cc_reads <= 2) ? 8'h80 : 8'h00;
                s_sda <= cc_out[7];
            end else s_sda <= 1'b1;
        end else if (cc_reading && cc_bit < 8) s_sda <= cc_out[7 - cc_bit];
    end

    // ------------------------------------------------------------------ the HL2: send side (its RTL)
    // The HL2's raw stream sender is clocked by pclk and fed by a counter as ADC data (the test pattern replaces it anyway).
    // ------------------------------------------------------------------ the HL2: send side (its RTL)
    reg         run = 1'b0;
    reg  [5:0]  cmd_addr = 6'h0;
    reg  [31:0] cmd_data = 32'h0;
    reg         cmd_rqst = 1'b0;
    reg         discover_rqst = 1'b0;
    reg  [11:0] adc = 12'h0;
    always @(posedge clk_ad) adc <= adc + 12'd1;
    wire [1:0]  udp_tx_request;
    wire [15:0] udp_tx_length;
    wire [7:0]  udp_tx_data;
    wire        udp_tx_enable, udp0_tx_enable, udp_tx_busy;
    wire [1:0]  pkt_req;
    wire [7:0]  pkt_data;
    wire [10:0] pkt_len;
    reg         pkt_en;
    reg         raw_mode;
    rawstream #(.FIFO_AW(14)) far_i (
        .clk_ad(clk_ad), .adc_data(adc), .clk(pclk), .run(run),
        .cmd_addr(cmd_addr), .cmd_data(cmd_data), .cmd_rqst(cmd_rqst), .raw_mode(raw_mode),
        .pkt_tx_request(pkt_req), .pkt_tx_length({5'h0, pkt_len}), .pkt_tx_data(pkt_data), .pkt_tx_enable(pkt_en),
        .udp_tx_request(udp_tx_request), .udp_tx_length(udp_tx_length), .udp_tx_data(udp_tx_data),
        .udp_tx_enable(udp_tx_enable), .udp0_tx_enable(udp0_tx_enable), .udp_tx_busy(udp_tx_busy),
        .dup_on(1'b0), .dup_status(160'd0), .tx_status(8'h01)
    );
    // Packer for discovery replies, copied from tb_h1_link_rx.v (the reply's payload is zero apart from the 0xEF 0xFE header and a
    // status byte that says whether the HL2 is running).
    // discovery-reply packer (sim/h1_link_rx/tb_h1_link_rx.v)
    localparam P_IDLE = 2'd0, P_REQ = 2'd1, P_SEND = 2'd2;
    reg [1:0] p_state = P_IDLE;
    reg [7:0] p_byte = 8'h0;
    reg [5:0] p_cnt = 6'h0;
    reg       p_pending = 1'b0;
    reg [10:0] p_len = 11'd0;
    always @(posedge pclk) begin
        if (discover_rqst) p_pending <= 1'b1;
        case (p_state)
            P_IDLE: if (p_pending) begin p_len <= 11'h3c; p_state <= P_REQ; end
            P_REQ: begin p_byte <= 8'hef; if (pkt_en) begin p_state <= P_SEND; p_cnt <= 6'h3a; p_pending <= 1'b0; end end
            P_SEND: begin
                p_cnt <= p_cnt - 6'd1;
                case (p_cnt)
                    6'h3a: p_byte <= 8'hfe;
                    6'h39: p_byte <= run ? 8'h03 : 8'h02;
                    6'h00: begin p_byte <= 8'h00; p_state <= P_IDLE; end
                    default: p_byte <= 8'h00;
                endcase
            end
        endcase
    end
    assign pkt_req = (p_state == P_REQ) ? 2'b10 : 2'b00;
    assign pkt_data = p_byte;
    assign pkt_len = p_len;
    // Send arbitration of the HL2's network.v, as in tb_h1_link_rx.v.
    reg tx_ready = 1'b0, tx_start = 1'b0;
    wire rgmii_tx_active;
    assign udp_tx_enable = tx_start;
    assign udp0_tx_enable = tx_start;
    assign udp_tx_busy = tx_ready | tx_start | rgmii_tx_active;
    always @(posedge pclk)
        if (rgmii_tx_active) begin tx_ready <= 1'b0; tx_start <= 1'b0; end
        else if (tx_ready) tx_start <= 1'b1;
        else if (udp_tx_request == 2'b10) tx_ready <= 1'b1;
    wire udp_tx_active, ip_tx_active, mac_tx_active;
    wire [7:0] udp_data, ip_tx_data, mac_tx_data;
    wire [15:0] udp_length;
    reg  [7:0] tdp; reg tep = 1'b0;
    udp_send udp_send_inst (.reset(1'b0), .clock(pclk), .tx_enable(udp_tx_enable), .data_in(udp_tx_data),
        .length_in(udp_tx_length), .local_port(16'd1024), .destination_port(MY_PORT),
        .active(udp_tx_active), .data_out(udp_data), .length_out(udp_length), .port_ID(8'h00));
    ip_send ip_send_inst (.data_in(udp_data), .tx_enable(udp_tx_active), .is_icmp(1'b0), .length(udp_length),
        .destination_ip(MY_IP), .data_out(ip_tx_data), .active(ip_tx_active), .clock(pclk), .reset(1'b0), .local_ip(HL2_IP));
    mac_send mac_send_inst (.data_in(ip_tx_data), .tx_enable(ip_tx_active), .destination_mac(MY_MAC),
        .data_out(mac_tx_data), .active(mac_tx_active), .clock(pclk), .local_mac(HL2_MAC), .reset(1'b0));
    always @(posedge pclk) begin tdp <= mac_tx_data; tep <= mac_tx_active; end
    rgmii_send #(.SIM(1)) rgmii_send_inst (.data(tdp), .tx_enable(tep), .active(rgmii_tx_active), .clock(pclk),
        .PHY_TX(), .PHY_TX_EN());
    initial begin
        udp_send_inst.byte_no = 16'd0; udp_send_inst.sending = 1'b0;
        ip_send_inst.byte_no = 5'd0;   ip_send_inst.sending = 1'b0;
    end
    // Wire tap: the framed byte stream of rgmii_send (preamble, SFD, frame, FCS) and its `sending` flag.
    wire       far_sending = rgmii_send_inst.sending;
    wire [7:0] far_byte    = rgmii_send_inst.shift_reg[63:56];

    // ------------------------------------------------------------------ the module: queue and 1000BASE-X sender (pclk)
    // The HL2's bytes go into a 1024 entry queue, each with its `sending` flag, and every pclk clock one 8b/10b symbol
    // goes out (the encoded 10 bit word is `p_code`, and `p_rd` is the running disparity of the encoder). Until the
    // negotiation is done (`p_mode` 0) the symbols are configuration ordered sets: the comma K28.5 (0xBC), then D21.5 (0xB5)
    // or D2.2 (0x42) in turn, then the two bytes of the configuration word `p_word`, which is 0x0020 (full duplex, bit 5)
    // and, once the other side's word has been seen three times, 0x4020 (the same with the acknowledge bit, bit 14).
    // ------------------------------------------------------------------ the module: queue and 1000BASE-X sender (pclk)
    reg [8:0] mq [0:1023];
    integer   mw = 0, mr = 0;
    always @(posedge pclk) begin mq[mw % 1024] = {far_sending, far_byte}; mw = mw + 1; end
    reg        p_rd = 0, p_mode = 0, pos = 0, c2 = 0;
    reg [9:0]  p_code = 0;
    reg [2:0]  ms = 0;                   // 0 idle-even, 1 idle-odd, 2 data, 3 /R/ (then maybe one more)
    reg [1:0]  cpos = 0;
    reg [15:0] p_word = 16'h0020;
    assign p_tx = {p_code[0], p_code[1], p_code[2], p_code[3], p_code[4], p_code[5], p_code[6], p_code[7], p_code[8], p_code[9]};
    // Encodes one symbol, a data byte or, with k = 1, a control code, using and updating the running disparity.
    task psym(input [7:0] d, input k);
        reg [10:0] e;
        begin e = k ? enc8b10b_k(d, p_rd) : enc8b10b_d(d, p_rd); p_code <= e[10:1]; p_rd = e[0]; end
    endtask
    wire [8:0] head = mq[mr % 1024], next = mq[(mr + 1) % 1024];
    integer lvl;
    // The sender, one symbol per clock. After the negotiation it sends idle, which is K28.5 followed by D5.6 (0xC5, /I1/) or D16.2
    // (0x50, /I2/), the second one chosen by the disparity so that it leaves the running disparity as the standard
    // wants. When a frame waits at the head of the queue and the position is even it sends /S/ (K27.7, 0xFB) in place of
    // the comma, then the frame's bytes, then /T/ (K29.7, 0xFD) and /R/ (K23.7, 0xF7), with every start and end on an even
    // position as clause 36 requires. While idle, one extra byte is taken out of the queue whenever more than 8 are waiting, which is
    // the dropped idle that wins back the time lost by a frame that started on an odd position.
    // position as clause 36 requires. In idle the queue read is a little ahead of the write (dropping one idle when more than 8 entries wait).
    // ms: 0 idle at an even position, 1 idle at an odd position, 2 frame data, 3 /R/ after /T/.
    always @(posedge pclk) begin
        lvl = mw - mr;
        if (!p_mode) begin                                   // configuration ordered sets
            case (cpos)
                2'd0: psym(8'hBC, 1);
                2'd1: psym(c2 ? 8'h42 : 8'hB5, 0);
                2'd2: psym(p_word[7:0], 0);
                default: begin psym(p_word[15:8], 0); c2 = ~c2; end
            endcase
            cpos = cpos + 2'd1;
            if (lvl > 6) mr = mr + 1;
            pos = 0; ms = 0;
        end else begin
            case (ms)
                3'd0: if (head[8] && lvl > 0) begin psym(8'hFB, 1); mr = mr + 1; ms = 2; end
                      else begin psym(8'hBC, 1); if (lvl > 0) mr = mr + 1; if (lvl > 8 && !next[8]) mr = mr + 1; ms = 1; end
                3'd1: begin
                          psym(!p_rd ? 8'hC5 : 8'h50, 0);   // /I1/ when the disparity before the comma was positive (it flips)
                          if (lvl > 0 && !head[8]) mr = mr + 1;
                          ms = 0;
                      end
                3'd2: if (head[8]) begin psym(head[7:0], 0); mr = mr + 1; end
                      else begin psym(8'hFD, 1); mr = mr + 1; ms = 3; end
                default: begin psym(8'hF7, 1); if (lvl > 0 && !head[8]) mr = mr + 1; ms = pos ? 3'd0 : 3'd3; end
            endcase
            pos = ~pos;
        end
    end
    // (/R/ repeats until the next symbol is on an even position, so after /T/ /R/ a frame of odd length gets one more /R/.)
    // (/R/ repeats until the next symbol is even: after /T/ /R/ a frame of odd length gets one more)

    // ------------------------------------------------------------------ the module: receive side (our words, sfp_txc)
    // The lane's 10 bit ports carry their bits in the reverse order of the decoder's, so p_tx and rcode both reverse them.
    // The decoder result rdec is {control flag, byte}.
    // ------------------------------------------------------------------ the module: receive side (our words, sfp_txc)
    wire [9:0] rcode = {ln0_tx[0], ln0_tx[1], ln0_tx[2], ln0_tx[3], ln0_tx[4], ln0_tx[5], ln0_tx[6], ln0_tx[7], ln0_tx[8], ln0_tx[9]};
    wire [9:0] rdec = dec8b10b(rcode);
    reg [7:0]  prev_d = 0; reg prev_k = 0;
    reg [1:0]  rpos = 0; reg [7:0] clo = 0;
    reg [15:0] d_cfg = 0; integer d_cfg_n = 0;
    reg        in_f = 0;
    reg [7:0]  df [0:255]; integer df_len = 0;
    integer    disc_req = 0, disc_done = 0, reg_req = 0, reg_done = 0;
    // The HL2's command side is a model: what it finds in our frames (a discovery request, a write of register 0x30) is
    // carried out in the HL2's own clock (pclk), by pulsing the discovery request of the packer and writing register 0x30
    // of rawstream.v.
    // the HL2's command side acts in its own clock
    always @(posedge pclk) begin
        discover_rqst <= 1'b0; cmd_rqst <= 1'b0;
        if (disc_done < disc_req) begin discover_rqst <= 1'b1; disc_done = disc_done + 1; end
        else if (reg_done < reg_req && !cmd_rqst) begin cmd_addr <= 6'h30; cmd_data <= REG30; cmd_rqst <= 1'b1; reg_done = reg_done + 1; end
    end
    // Counters for what our radio sends: frames, bad FCS, and the HL2 commands the bench recognized.
    integer    safety_err = 0, our_frames = 0, our_bad_fcs = 0, n_disc = 0, n_start = 0, n_stop = 0, n_reg = 0;
    // One byte of the Ethernet CRC-32 (reflected polynomial 0xEDB88320).
    function [31:0] crc_byte(input [31:0] c, input [7:0] b);
        integer i; reg [31:0] x;
        begin x = c ^ {24'd0, b}; for (i = 0; i < 8; i = i + 1) x = x[0] ? ((x >> 1) ^ 32'hEDB88320) : (x >> 1); crc_byte = x; end
    endfunction
    // Judges one frame of ours, collected in df[0 .. df_len-1] as 0x55 preamble bytes, 0xD5 SFD, the frame and the FCS: finds the SFD, recomputes the
    // CRC-32 over everything between it and the FCS, compares it with the FCS (bad ones are counted), and then classifies the
    // frame by its UDP payload. The kinds that the radio is allowed to send an HL2 are a discovery request, a start or stop
    // command and the write of register 0x30; anything else is a safety error.
    task our_frame;                      // df[0..df_len-1]: 0x55 .. 0xD5, frame, FCS
        integer i, s, n; reg [31:0] c, w; reg [15:0] dport;
        begin
            s = 0; while (s < df_len && df[s] == 8'h55) s = s + 1;
            if (df[s] != 8'hD5) begin errors = errors + 1; $display("ERROR: our frame without SFD"); end
            s = s + 1; n = df_len - s - 4;
            c = 32'hFFFFFFFF; for (i = 0; i < n; i = i + 1) c = crc_byte(c, df[s + i]); c = ~c;
            w = {df[s+n+3], df[s+n+2], df[s+n+1], df[s+n]};
            our_frames = our_frames + 1;
            if (w !== c) our_bad_fcs = our_bad_fcs + 1;
            // UDP destination port, bytes 36 and 37 of the frame.
            dport = {df[s+36], df[s+37]};
            // EtherType 0x0800 (IPv4), IP protocol 17 (UDP) and the HPSDR magic 0xEF 0xFE at the start of the UDP payload.
            if (!({df[s+12], df[s+13]} == 16'h0800 && df[s+23] == 8'h11 && df[s+42] == 8'hEF && df[s+43] == 8'hFE)) begin
                safety_err = safety_err + 1; $display("SAFETY: frame from us that is not an HL2 command");
            // Discovery request: type 2 to port 1025 or 1024. The HL2 answers it.
            end else if (df[s+44] == 8'h02 && (dport == 16'd1025 || dport == 16'd1024)) begin
                n_disc = n_disc + 1; disc_req = disc_req + 1;
            // Start (data byte 0x81, bit 0 set) or stop (0x00) of the stream, type 4 to port 1024, sent to the HL2's own MAC address.
            end else if (df[s+44] == 8'h04 && dport == 16'd1024 && (df[s+45] == 8'h81 || df[s+45] == 8'h00)) begin
                if (df[s+45][0]) n_start = n_start + 1; else n_stop = n_stop + 1;
                if ({df[s], df[s+1], df[s+2], df[s+3], df[s+4], df[s+5]} != HL2_MAC) begin errors = errors + 1; $display("ERROR: start/stop not to the HL2's MAC"); end
                run <= df[s+45][0];
            // Write of register 0x30: type 5 to port 1025, command 0x7F, address 0x60 (register 0x30 shifted left by one), the value in the next four bytes, sent to the HL2's IP.
            end else if (df[s+44] == 8'h05 && dport == 16'd1025 && df[s+45] == 8'h7F && df[s+46] == 8'h60) begin
                n_reg = n_reg + 1;
                `CHECK({df[s+47], df[s+48], df[s+49], df[s+50]} == REG30, "register 0x30 value")
                `CHECK({df[s+30], df[s+31], df[s+32], df[s+33]} == HL2_IP, "register write not to the HL2's IP")
                reg_req = reg_req + 1;
            end else begin
                safety_err = safety_err + 1; $display("SAFETY: frame from us of a kind not allowed (byte 2 = %h, port %0d)", df[s+44], dport);
            end
        end
    endtask
    // Per sfp_txc clock: between /S/ and /T/ the data bytes are collected into df, and outside a frame the bench looks
    // for configuration words (a K28.5 comma, then D21.5 or D2.2, then the low and the high byte of the word).
    // d_cfg_n counts how many times in a row the same configuration word came.
    always @(posedge sfp_txc) begin
        if (in_f) begin
            if (rdec[8] && rdec[7:0] == 8'hFD) begin in_f = 0; our_frame; end
            else if (!rdec[8] && df_len < 256) begin df[df_len] = rdec[7:0]; df_len = df_len + 1; end
        end else if (rdec[8] && rdec[7:0] == 8'hFB) begin in_f = 1; df_len = 0; end
        else if (rpos == 1) begin clo = rdec[7:0]; rpos = 2; end
        else if (rpos == 2) begin
            rpos = 0;
            if ({rdec[7:0], clo} == d_cfg) d_cfg_n = d_cfg_n + 1; else d_cfg_n = 1;
            d_cfg = {rdec[7:0], clo};
        end else if (prev_k && prev_d == 8'hBC && !rdec[8] && (rdec[7:0] == 8'hB5 || rdec[7:0] == 8'h42)) rpos = 1;
        prev_d = rdec[7:0]; prev_k = rdec[8];
    end

    // ------------------------------------------------------------------ negotiation, the module's side
    // Once our configuration word has come three times in a row the module sends it back acknowledged, and when
    // our acknowledged word has been seen more than 1000 times the negotiation is done and the module goes to idle.
    // ------------------------------------------------------------------ negotiation, the module's side
    integer acks = 0;
    always @(posedge pclk) if (!p_mode) begin
        if (d_cfg_n >= 3 && (d_cfg & 16'hBFFF) == 16'h0020) p_word <= 16'h4020; else p_word <= 16'h0020;
        if (d_cfg_n >= 3 && d_cfg == 16'h4020 && cpos == 2'd0) acks = acks + 1;
        if (acks > 1000) begin p_mode <= 1'b1; $display("t=%0t: module: negotiation done, idle", $time); end
    end

    // ------------------------------------------------------------------ UART (12.5 Mbaud: BAUD clocks of 50 MHz a bit)
    // Receiver of the core's UART line, 8 data bits, least significant first, sampled in the middle of each bit.
    // It collects a line up to the newline, prints it, counts it, and counts the lines that carry the chip ID.
    // ------------------------------------------------------------------ UART (12.5 Mbaud: BAUD clocks of 50 MHz a bit)
    reg [8*200-1:0] ln = 0; integer ln_n = 0, lines = 0, id_lines = 0;
    reg [7:0] ch;
    integer k;
    always begin
        @(negedge uart_txd);
        repeat (BAUD / 2) @(posedge clk_50m);
        for (k = 0; k < 8; k = k + 1) begin repeat (BAUD) @(posedge clk_50m); ch[k] = uart_txd; end
        repeat (BAUD) @(posedge clk_50m);
        if (ch == 8'h0A) begin
            $display("UART: %0s", ln);
            if (ln[8*19-1:0] == "id=0123456789abcdef") id_lines = id_lines + 1;   // chip ID (OTP model, sim/net/otp_model.v)
            ln = 0; ln_n = 0; lines = lines + 1;
        end
        else if (ch != 8'h0D) begin ln = {ln[8*199-1:0], ch}; ln_n = ln_n + 1; end
    end

`ifdef DROP
    // One byte of a raw frame is flipped on the line, in the middle of a frame (300 words after its start), after more than 40 frames have been received.
    // one byte of a raw frame flipped on the line, after the stream has run for a while
    initial begin
        wait (dut.c_raw > 32'd40);
        @(posedge d_rxc); while (!(far_sending)) @(posedge d_rxc);
        repeat (300) @(posedge d_rxc);
        line_err <= 10'h021; @(posedge d_rxc); line_err <= 10'd0;
        $display("t=%0t: one byte corrupted on the line", $time);
    end
`endif

    // ------------------------------------------------------------------ run and checks
    // ------------------------------------------------------------------ run and checks
    initial begin
        $display("tb_hl2min: lane %0d, HL2 clock %0s100 ppm, %0s", LANE, (PH < 4000.0) ? "+" : "-",
`ifdef GAPS
            "receive gaps");
`else
            "no receive gaps");
`endif
        // Hold reset for 20 clocks of clk_50m, then run until the core has printed SECS lines (one per 200 us "second").
        repeat (20) @(posedge clk_50m); rst = 1'b0;
        wait (lines >= SECS);
        @(posedge clk_50m);
        $display("clock chip: %0d register writes, last %0d = %h; %0d status reads", cc_writes, cc_last_reg, cc_last_val, cc_reads);
        // The core started the clock chip, programmed its registers (40 writes, the last one register 3 = 0xFC), and chose
        // multiplexer channel 3.
        `CHECK(cc_writes == 40 && cc_last_reg == 8'd3 && cc_last_val == 8'hFC, "clock chip writes")
        `CHECK(n19 === 1'b1 && p19 === 1'b1 && p26 === 1'b0, "multiplexer not on channel 3")
        `CHECK(dut.st_link === 1'b1, "PCS link not up")
        // Only the HL2's cage (lane 0 or lane 1) has its transmitter on and its PCS released, and the core has learned the HL2's addresses from its discovery reply.
        `CHECK(txdis === ((LANE == 1) ? 2'b01 : 2'b10), $sformatf("cage transmitters %b (1 = off)", txdis))
        `CHECK(ln_rx_rst === ((LANE == 1) ? 2'b01 : 2'b10) && ln_tx_rst === ((LANE == 1) ? 2'b01 : 2'b10),
               $sformatf("PCS resets rx %b tx %b", ln_rx_rst, ln_tx_rst))
        `CHECK(id_lines >= SECS, $sformatf("chip ID on %0d of %0d UART lines", id_lines, lines))
        `CHECK(dut.known === 1'b1 && dut.hl2_ip_r == HL2_IP && dut.hl2_mac_r == HL2_MAC, "the HL2 not learned")
        $display("our frames: %0d (discovery %0d, stop %0d, register 0x30 %0d, start %0d), bad FCS %0d, safety errors %0d",
                 our_frames, n_disc, n_stop, n_reg, n_start, our_bad_fcs, safety_err);
        // Our frames: none with a bad FCS, none outside the allowed kinds, and the HL2 was started.
        `CHECK(our_bad_fcs == 0 && safety_err == 0, "our frames")
        `CHECK(n_start >= 1 && n_reg >= 1, "the HL2 was not started")
        // Receive of the raw stream: more than 50 raw frames, and no loss. With -DDROP the one corrupted frame must count as
        // exactly one lost frame and one bad FCS, and without it every loss counter must stay 0.
        $display("HL2 side: raw frames %0d sent... FIFO overflows %0d", dut.c_raw, far_i.ovf_cnt);
        `CHECK(dut.c_raw > 32'd50, "too few raw frames")
`ifdef DROP
        `CHECK(dut.c_lost == 32'd1 && dut.max_gap == 32'd1, $sformatf("lost %0d gap %0d, expected 1 and 1", dut.c_lost, dut.max_gap))
        `CHECK(dut.c_crc == 32'd1, "bad FCS count")
`else
        `CHECK(dut.c_lost == 32'd0 && dut.c_crc == 32'd0 && dut.c_len == 16'd0, "loss on the link")
        `CHECK(dut.c_gsmp == 32'd0, "fill samples")
`endif
        `CHECK(dut.c_drain == 16'd0 && dut.c_over == 16'd0 && dut.c_idx == 16'd0, "overflow in the receive chain")
        `CHECK(dut.c_pat == 32'd0, "sample pattern errors")
        `CHECK(far_i.ovf_cnt == 16'd0, "the HL2's FIFO overflowed")
`ifdef GAPS
        $display("receive clocks without a word: %0d", gaps);
        `CHECK(gaps > 1000, "no receive gaps")
`endif
        if (errors == 0) $display("PASS"); else $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
