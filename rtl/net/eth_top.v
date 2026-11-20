// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Ethernet unit for the board's RJ45 socket: an Ethernet MAC (media access control, the layer that builds and
// takes apart frames) for the RTL8211F PHY chip over RGMII at 100 Mbit/s full duplex, with a register page for
// the CPU and an MDIO master for the PHY's own registers. It is the same logic as in an earlier design
// by the same author, and in this radio it serves the home network side (control, GUI, TCI and
// the loader), while the Hermes-Lite 2 link runs over the SFP lane instead (docs/HL2_SFP.md section 9).
// rtl/net/net_unit.v wraps it in the register page of the AE350's bus. The page is at 0xE924_0000.
// It is written from scratch and takes nothing from another core.
//
// What RGMII is, for a beginner: the reduced gigabit media independent interface connects an Ethernet PHY
// chip (the chip that turns Ethernet's signals on the cable into digital bits) to the FPGA with four data
// wires, a control wire and a clock in each direction. At 1000 Mbit/s the data goes on both edges of a
// 125 MHz clock, but at 100 Mbit/s the clock is 25 MHz and a four-bit nibble is valid at its rising edge, so
// two nibbles make a byte and a frame is a stream of nibbles. That is slow enough to do without any of the
// FPGA's fast I/O blocks, and this unit handles every pin with ordinary registers in one fabric clock.
//
// Everything runs on clk (100 MHz, or 150 MHz with DIV = 6); there is no Ethernet clock in the design:
//   transmit  25 MHz = clk / 4. TXC is a register toggling every second clock; TXD and TX_CTL change one clock
//             before its rising edge, in the middle of its low half (RGMII 2.0 section 5.0: at 10/100 the nibble
//             is valid at the rising edge; section 3.4: TX_CTL is also taken at the falling edge, as TX_EN XOR
//             TX_ER, so it must not change there).
//   receive   RXC, RXD and RX_CTL through two synchronizer registers, four samples per RXC period; the nibble
//             and data-valid from the sample 10 to 20 ns after RXC's rising edge. The error bit of the falling
//             edge (RGMII 3.4) is not sampled: its window is half a period and a sample with margin on both
//             sides does not exist at four samples per period; a frame with a line error fails the CRC.
//   PHY reference clock (25 MHz) = clk / 4 from a register.
// One frame out (2,048-byte buffer), a ring of frames in (4,096 bytes: per frame one word {next pointer,
// length} and the bytes with the checksum), CRC-32 both ways, address filter, counters.
// MDIO: clause 22, MDC = clk / 64.
//
// Register bus: `we` / `re` one clock with `a` (word offset) and `wd`; `rd` holds the word in the clock after
// `re` and is 0 otherwise. The word offsets are in the read multiplexer at the end of the file: 0x00 id, 0x01
// control (receive enable, transmit enable, PHY reset, and the accept-all, broadcast and multicast filters),
// 0x02 status (frame waiting, transmit busy, RXC running, and the PHY's in-band link, speed and duplex),
// 0x03 flags (write 1 to clear), 0x04 interrupt enable, 0x05 and 0x06 MAC address, 0x07 MDIO, 0x08 transmit
// length (write: send), 0x09 transmit data, 0x0A transmit pointer (write: reset), 0x0B receive length, 0x0C
// receive data, 0x0D receive done (write: release the frame), 0x0E receive count, 0x0F dropped counts, 0x10
// transmit count.

`default_nettype none

module eth_top #(
    parameter integer DIV = 4             // clk / 25 MHz: 4 (clk 100 MHz) or 6 (clk 150 MHz)
) (
    input  wire        clk,               // 100 MHz (DIV 4) or 150 MHz (DIV 6)
    input  wire        rst,               // synchronous reset, active high
    input  wire        we,                // register write strobe, one clock, with a and wd
    input  wire        re,                // register read strobe, one clock, with a
    input  wire [5:0]  a,                 // register word offset
    input  wire [31:0] wd,                // write data
    output reg  [31:0] rd,                // read data, valid in the clock after re, 0 otherwise
    output wire        irq,               // interrupt, a level: a flag is set and enabled
    // pins
    output reg         rgmii_txc,         // transmit clock to the PHY, 25 MHz
    output reg  [3:0]  rgmii_txd,         // transmit nibble
    output reg         rgmii_tx_ctl,      // transmit enable
    input  wire        rgmii_rxc,         // receive clock from the PHY
    input  wire [3:0]  rgmii_rxd,         // receive nibble
    input  wire        rgmii_rx_ctl,      // receive data valid
    output reg         phy_clk,           // 25 MHz reference clock for the PHY
    output wire        phy_rst_n,         // PHY reset, active low
    output reg         mdc,               // management clock
    input  wire        mdio_i,            // management data in
    output reg         mdio_o,            // management data out
    output reg         mdio_oe,           // 1: drive mdio_o
    // The 25 MHz phase counter (0 .. DIV - 1; the pins change entering phase 0), for a build that makes
    // TXC and the PHY's reference clock outside this unit
    output wire [2:0]  ph_o
) /* synthesis syn_maxfan = 10 */;
    // CRC-32 of IEEE 802.3 (reflected form, polynomial 0xEDB88320), four bits per step, low bit first. This
    // is the same calculation as crc32_eth.v does for a byte (see there for what a CRC is), done for the
    // nibble at a time that RGMII delivers.
    function [31:0] crc_nib(input [31:0] c, input [3:0] n);
        integer i; reg [31:0] r;
        begin
            r = c;
            for (i = 0; i < 4; i = i + 1)
                r = {1'b0, r[31:1]} ^ ((r[0] ^ n[i]) ? 32'hEDB88320 : 32'h0);
            crc_nib = r;
        end
    endfunction

    // ---------------------------------------------------------------- registers
    // Control bits: c_rx and c_tx enable the receiver and the transmitter, c_prst holds the PHY in reset
    // (it is 1 after reset), c_all accepts every frame, c_bc accepts broadcast frames (1 after reset) and c_mc
    // accepts multicast frames. `ie` enables the interrupt for each flag. The flags f_txd (a frame was sent),
    // f_drop (a good frame did not fit in the ring) and f_mdio (an MDIO transaction finished) are set by the
    // hardware and cleared by writing 1 to their bit of register 3. `mac` is our MAC address, bytes 5 to 0.
    reg        c_rx = 1'b0, c_tx = 1'b0, c_prst = 1'b1, c_all = 1'b0, c_bc = 1'b1, c_mc = 1'b0;
    reg [3:0]  ie = 4'd0;
    reg        f_txd = 1'b0, f_drop = 1'b0, f_mdio = 1'b0;
    reg [47:0] mac = 48'h0100_004A_5402;                // bytes 5..0: 02:54:4A:00:00:01 on the wire
    assign phy_rst_n = !c_prst;
    wire       w_txlen = we && a == 6'h08;
    wire       w_txd   = we && a == 6'h09;
    wire       w_txp   = we && a == 6'h0A;
    wire       w_ack   = we && a == 6'h0D;
    wire       w_mdio  = we && a == 6'h07;
    wire       r_rxd   = re && a == 6'h0C;
    always @(posedge clk) begin
        if (rst) begin
            c_rx <= 1'b0; c_tx <= 1'b0; c_prst <= 1'b1; c_all <= 1'b0; c_bc <= 1'b1; c_mc <= 1'b0; ie <= 4'd0;
            mac <= 48'h0100_004A_5402;
        end else begin
            if (we && a == 6'h01) begin
                c_rx <= wd[0]; c_tx <= wd[1]; c_prst <= wd[2]; c_all <= wd[3]; c_bc <= wd[4]; c_mc <= wd[5];
            end
            if (we && a == 6'h04) ie <= wd[3:0];
            if (we && a == 6'h05) mac[31:0] <= wd;
            if (we && a == 6'h06) mac[47:32] <= wd[15:0];
        end
    end

    // ---------------------------------------------------------------- 25 MHz phase, clocks to the PHY
    // DIV phases per period (4 for a 100 MHz clk; 6 for a 150 MHz clk, with the PHY clock high in phases 3, 4,
    // 5). The receiver needs no change for either: it takes the nibble from the second synchronizer register
    // when it sees RXC rise, which is 10 to 20 ns after the edge with DIV 4 and 6.7 to 13.3 ns with DIV 6,
    // inside the 40 ns the nibble holds.
    reg [2:0] ph = 3'd0;
    initial begin rgmii_txc = 1'b0; phy_clk = 1'b0; rgmii_txd = 4'd0; rgmii_tx_ctl = 1'b0; end
    wire      ph_hi = (ph >= DIV / 2 - 1) && (ph < DIV - 1);
    // TXC is high from one clock after the pins change for half the period, so TXD and TX_CTL change a
    // quarter period away from both TXC edges. The PHY takes TX_CTL at both edges (RGMII 2.0 section 3.4: TX_EN
    // at the rising, TX_EN XOR TX_ER at the falling edge) and delays TXC by 2 ns (TXDLY strap), so with TX_CTL
    // changing at the falling edge it would read the frame's last nibble as an error.
    wire      tx_hi = (ph < DIV / 2);
    always @(posedge clk) begin
        ph <= (ph == DIV - 1) ? 3'd0 : ph + 3'd1;
        rgmii_txc <= tx_hi;                               // rises one clock after the pins change
        phy_clk   <= ph_hi;
    end
    assign ph_o = ph;
    wire tn = (ph == DIV - 1);                            // the pins change entering phase 0 (TXC falls)

    // ---------------------------------------------------------------- transmit
    // The CPU writes the frame word by word into `txm` (register 9, the write pointer counts up, register
    // 10 resets it) and then its length (register 8), which starts the transmission. A frame shorter than 60
    // bytes is padded with zeros up to 60 (`tx_tot`), because Ethernet needs at least 64 bytes with the FCS.
    // The state machine `ts` sends, one nibble per 25 MHz step (`tn` marks the step): 1 the preamble (15
    // nibbles 5 and then the delimiter D, which is the preamble 0x55 x7 and the SFD 0xD5 with the low
    // nibble first), 2 the data nibbles, low nibble of each byte first, with the CRC running, 3 the FCS
    // (8 nibbles, inverted CRC), 4 the quiet gap of 24 nibbles (12 bytes) before the next frame.
    (* syn_ramstyle = "block_ram" *) reg [31:0] txm [0:511];
    reg [8:0]  tx_wp = 9'd0, tx_ra = 9'd0;
    reg [31:0] tx_q = 32'd0;
    reg [10:0] tx_len = 11'd0;
    reg        tx_req = 1'b0;
    reg [2:0]  ts = 3'd0;                                 // 0 idle, 1 preamble, 2 data, 3 checksum, 4 gap
    reg [10:0] tb = 11'd0;                                // byte or nibble counter of the state
    reg        thn = 1'b0;
    reg [31:0] tcrc = 32'd0;
    reg [31:0] tx_cnt = 32'd0;
    wire [10:0] tx_tot = (tx_len < 11'd60) ? 11'd60 : tx_len;
    wire [7:0] tbyte = (tb >= tx_len) ? 8'h00 : (tb[1:0] == 2'd0) ? tx_q[7:0] : (tb[1:0] == 2'd1) ? tx_q[15:8]
                     : (tb[1:0] == 2'd2) ? tx_q[23:16] : tx_q[31:24];
    wire [3:0] tnib = thn ? tbyte[7:4] : tbyte[3:0];
    wire [31:0] tfcs = ~tcrc;
    wire       tx_busy = tx_req || ts != 3'd0;
    always @(posedge clk) begin
        if (w_txd) begin txm[tx_wp] <= wd; tx_wp <= tx_wp + 9'd1; end
        if (w_txp) tx_wp <= 9'd0;
        tx_ra <= tb[10:2];
        tx_q <= txm[tx_ra];
        if (rst) begin ts <= 3'd0; tx_req <= 1'b0; rgmii_tx_ctl <= 1'b0; tx_wp <= 9'd0; tx_cnt <= 32'd0; f_txd <= 1'b0; end
        else begin
            if (w_txlen && !tx_busy && c_tx) begin tx_len <= wd[10:0]; tx_req <= 1'b1; end
            if (we && a == 6'h03 && wd[1]) f_txd <= 1'b0;
            if (tn) begin
                case (ts)
                    3'd0: begin
                        rgmii_tx_ctl <= 1'b0; rgmii_txd <= 4'd0;
                        if (tx_req) begin tx_req <= 1'b0; ts <= 3'd1; tb <= 11'd0; end
                    end
                    3'd1: begin                           // 15 nibbles 5, then D
                        rgmii_tx_ctl <= 1'b1; rgmii_txd <= (tb == 11'd15) ? 4'hD : 4'h5;
                        tb <= tb + 11'd1;
                        if (tb == 11'd15) begin ts <= 3'd2; tb <= 11'd0; thn <= 1'b0; tcrc <= 32'hFFFF_FFFF; end
                    end
                    3'd2: begin
                        rgmii_txd <= tnib; tcrc <= crc_nib(tcrc, tnib);
                        thn <= ~thn;
                        if (thn) begin
                            tb <= tb + 11'd1;
                            if (tb + 11'd1 == tx_tot) begin ts <= 3'd3; tb <= 11'd0; end
                        end
                    end
                    3'd3: begin
                        rgmii_txd <= tfcs[tb[2:0]*4 +: 4];
                        tb <= tb + 11'd1;
                        if (tb == 11'd7) begin ts <= 3'd4; tb <= 11'd0; end
                    end
                    default: begin                        // 24 nibbles between frames
                        rgmii_tx_ctl <= 1'b0; rgmii_txd <= 4'd0;
                        tb <= tb + 11'd1;
                        if (tb == 11'd0) begin tx_cnt <= tx_cnt + 32'd1; f_txd <= 1'b1; end
                        if (tb == 11'd23) ts <= 3'd0;
                    end
                endcase
            end
        end
    end

    // ---------------------------------------------------------------- receive: pins to nibbles
    // The pins go through two registers (`rc_s` for RXC, `rd_s0` and `rd_s1` for the data and control),
    // and a rising edge of RXC is found as a step of its synchronized copy (`rise_d`). On that edge the
    // nibble and the data-valid flag are taken (`r_nib`, `r_dv`) from the second data register, and `rn`
    // pulses one clock later to say that a new nibble is ready. Between frames the PHY reports the link
    // state, the speed and the duplex mode in the nibble itself (in-band status), and it is taken when
    // two nibbles in a row are equal (`inband`). `rc_run` is high while RXC keeps running, which shows
    // that the PHY has a link.
    reg [2:0] rc_s /* synthesis syn_preserve = 1 */;
    reg [4:0] rd_s0 /* synthesis syn_preserve = 1 */;
    reg [4:0] rd_s1 /* synthesis syn_preserve = 1 */;
    initial begin rc_s = 3'd0; rd_s0 = 5'd0; rd_s1 = 5'd0; end
    reg       rise_d = 1'b0, rn = 1'b0;
    reg [3:0] r_nib = 4'd0, r_idle = 4'd0;
    reg       r_dv = 1'b0;
    reg [7:0] rc_to = 8'd0;
    reg       rc_run = 1'b0;
    reg [3:0] inband = 4'd0;
    always @(posedge clk) begin
        rc_s <= {rc_s[1:0], rgmii_rxc};
        rd_s0 <= {rgmii_rx_ctl, rgmii_rxd}; rd_s1 <= rd_s0;
        rise_d <= rc_s[1] && !rc_s[2];
        rn <= rise_d;
        if (rise_d) begin r_nib <= rd_s1[3:0]; r_dv <= rd_s1[4]; end
        // between frames: link, speed, duplex (taken when two nibbles in a row are equal)
        if (rn && !r_dv) begin r_idle <= r_nib; if (r_idle == r_nib) inband <= r_nib; end
        if (rise_d) begin rc_to <= 8'd0; rc_run <= 1'b1; end
        else if (rc_to == 8'd255) rc_run <= 1'b0;
        else rc_to <= rc_to + 8'd1;
    end

    // ---------------------------------------------------------------- receive: frames into the ring
    // The state machine `rs` (stepping once per nibble, on `rn`): 0 waits for a frame, 1 skips the preamble
    // until the delimiter D, 2 takes the data (two nibbles make a byte, `rlo` holds the low one, the CRC
    // runs over all of it including the FCS, and the first six bytes are compared with our MAC address,
    // the broadcast address and the multicast bit), 3 skips a frame that is not wanted, 4 finishes the last
    // partly filled word, 5 writes the header word. Four bytes are collected in `rw` and written to the ring
    // as one word. The header word {next pointer, length} is written in front of the frame at the end, and
    // only then `wp` moves, so the CPU never sees half a frame. A frame is kept only if the CRC register
    // holds the fixed remainder 0xDEBB20E3 (which is what a correct FCS gives), its length is from 64 to
    // 1,518 bytes, and the address filter accepts it. A good frame that does not fit sets `f_drop`.
    (* syn_ramstyle = "block_ram" *) reg [31:0] rxm [0:1023];
    reg [9:0]  wp = 10'd0, wt = 10'd0, rp = 10'd0;
    reg        m_we = 1'b0;
    reg [9:0]  m_wa = 10'd0;
    reg [31:0] m_wd = 32'd0;
    reg [2:0]  rs = 3'd0;                                 // 0 idle, 1 preamble, 2 data, 3 skip, 4 last word, 5 header
    reg        rhn = 1'b0;
    reg [3:0]  rlo = 4'd0;
    reg [11:0] rb = 12'd0;                                // bytes of the frame so far
    reg [23:0] rw = 24'd0;
    reg [31:0] rcrc = 32'd0;
    reg        r_ovf = 1'b0, a_uni = 1'b0, a_bc = 1'b0, a_mc = 1'b0;
    reg [31:0] rx_cnt = 32'd0;
    reg [15:0] n_room = 16'd0, n_bad = 16'd0;
    wire [7:0] rbyte = {r_nib, rlo};
    wire [7:0] macb = (rb[2:0] == 3'd0) ? mac[7:0] : (rb[2:0] == 3'd1) ? mac[15:8] : (rb[2:0] == 3'd2) ? mac[23:16]
                    : (rb[2:0] == 3'd3) ? mac[31:24] : (rb[2:0] == 3'd4) ? mac[39:32] : mac[47:40];
    wire       room = (wt + 10'd1 != rp);
    wire       accept = c_all || a_uni || (a_bc && c_bc) || (a_mc && !a_bc && c_mc);
    wire       fr_ok = !rhn && rcrc == 32'hDEBB20E3 && rb >= 12'd64 && rb <= 12'd1518 && accept;
    always @(posedge clk) begin
        m_we <= 1'b0;
        if (m_we) rxm[m_wa] <= m_wd;
        if (rst) begin
            rs <= 3'd0; wp <= 10'd0; wt <= 10'd0; rx_cnt <= 32'd0; n_room <= 16'd0; n_bad <= 16'd0; f_drop <= 1'b0;
        end else begin
            if (we && a == 6'h03 && wd[2]) f_drop <= 1'b0;
            if (re && a == 6'h0F) begin n_room <= 16'd0; n_bad <= 16'd0; end
            if (rn) begin
                case (rs)
                    3'd0: if (r_dv) rs <= (c_rx && r_nib == 4'h5) ? 3'd1 : 3'd3;
                    3'd1: begin
                        if (!r_dv) rs <= 3'd0;
                        else if (r_nib == 4'hD) begin
                            rs <= 3'd2; rhn <= 1'b0; rb <= 12'd0; rcrc <= 32'hFFFF_FFFF;
                            a_uni <= 1'b1; a_bc <= 1'b1; a_mc <= 1'b0;
                            wt <= wp + 10'd1; r_ovf <= (wp + 10'd1 == rp);
                        end else if (r_nib != 4'h5) rs <= 3'd3;
                    end
                    3'd2: begin
                        if (!r_dv) rs <= 3'd4;
                        else begin
                            rcrc <= crc_nib(rcrc, r_nib);
                            rhn <= ~rhn;
                            if (!rhn) rlo <= r_nib;
                            else begin
                                if (rb < 12'd6) begin
                                    if (rbyte != macb) a_uni <= 1'b0;
                                    if (rbyte != 8'hFF) a_bc <= 1'b0;
                                    if (rb == 12'd0) a_mc <= rbyte[0];
                                end
                                if (rb[1:0] == 2'd3) begin
                                    if (room && !r_ovf) begin m_we <= 1'b1; m_wa <= wt; m_wd <= {rbyte, rw}; wt <= wt + 10'd1; end
                                    else r_ovf <= 1'b1;
                                end else rw <= {rbyte, rw[23:8]};
                                if (rb != 12'hFFF) rb <= rb + 12'd1;
                            end
                        end
                    end
                    3'd3: if (!r_dv) rs <= 3'd0;
                    default: ;
                endcase
            end
            // end of frame: the last, partly filled word, then the header word; or the frame is dropped
            if (rs == 3'd4) begin
                rs <= 3'd5;
                if (rb[1:0] != 2'd0) begin
                    if (room && !r_ovf) begin
                        m_we <= 1'b1; m_wa <= wt; wt <= wt + 10'd1;
                        m_wd <= (rb[1:0] == 2'd1) ? {24'd0, rw[23:16]} : (rb[1:0] == 2'd2) ? {16'd0, rw[23:8]} : {8'd0, rw};
                    end else r_ovf <= 1'b1;
                end
            end
            if (rs == 3'd5) begin
                rs <= 3'd0;
                if (fr_ok && !r_ovf) begin
                    m_we <= 1'b1; m_wa <= wp; m_wd <= {6'd0, wt, 5'd0, rb[10:0] - 11'd4};
                    wp <= wt; rx_cnt <= rx_cnt + 32'd1;
                end else if (fr_ok) begin
                    f_drop <= 1'b1; if (n_room != 16'hFFFF) n_room <= n_room + 16'd1;
                end else if (accept || c_all) begin
                    if (n_bad != 16'hFFFF) n_bad <= n_bad + 16'd1;
                end
            end
        end
    end

    // ---------------------------------------------------------------- receive: the processor's side
    // When `rp` differs from `wp` a frame is waiting. Its header word is read (three clocks for address,
    // memory and register), `hd_v` is set, and the length and next pointer are held. The CPU then reads the
    // data words one by one through register 12 (`r_off` counts up with every read) and releases the frame
    // by writing register 13, which moves `rp` on to the next frame.
    reg [9:0]  r_off = 10'd0;
    reg [31:0] rx_q = 32'd0;
    reg [9:0]  rx_ra = 10'd0;
    reg        hd_v = 1'b0;
    reg [1:0]  hd_w = 2'd0;
    reg [10:0] hd_len = 11'd0;
    reg [9:0]  hd_nx = 10'd0;
    always @(posedge clk) begin
        rx_ra <= rp + r_off;
        rx_q <= rxm[rx_ra];
        if (rst) begin rp <= 10'd0; r_off <= 10'd0; hd_v <= 1'b0; hd_w <= 2'd0; end
        else begin
            if (!hd_v) begin
                // a frame is there: its header word is read (three clocks for address, memory, register)
                if (rp == wp || m_we) hd_w <= 2'd0;
                else if (hd_w != 2'd3) hd_w <= hd_w + 2'd1;
                else begin hd_v <= 1'b1; hd_len <= rx_q[10:0]; hd_nx <= rx_q[25:16]; r_off <= 10'd1; hd_w <= 2'd0; end
            end else begin
                if (r_rxd) r_off <= r_off + 10'd1;
                if (w_ack) begin rp <= hd_nx; r_off <= 10'd0; hd_v <= 1'b0; end
            end
        end
    end

    // ---------------------------------------------------------------- MDIO
    // A write to register 7 starts a transaction: 32 bits of preamble, start, read or write code, PHY
    // address, register address, turnaround and 16 data bits, shifted out MSB first (`msh`) at MDC = clk / 64,
    // with MDC low for the first half of each bit. For a read, the output is released from bit 46 on and
    // the PHY's data is sampled on MDC's rising edge into `m_din`. See mdio_ctrl.v for what MDIO is.
    reg [5:0]  mdiv = 6'd0;
    reg [6:0]  mbit = 7'd0;
    reg        m_busy = 1'b0, m_rdop = 1'b0;
    reg [63:0] msh = 64'd0;
    reg [15:0] m_din = 16'd0;
    initial begin mdc = 1'b0; mdio_o = 1'b1; mdio_oe = 1'b0; end
    always @(posedge clk) begin
        if (rst) begin m_busy <= 1'b0; mdc <= 1'b0; mdio_oe <= 1'b0; f_mdio <= 1'b0; mdiv <= 6'd0; end
        else begin
            if (we && a == 6'h03 && wd[3]) f_mdio <= 1'b0;
            if (w_mdio && !m_busy) begin
                m_busy <= 1'b1; m_rdop <= wd[30]; mbit <= 7'd0; mdiv <= 6'd0;
                msh <= {32'hFFFF_FFFF, 2'b01, wd[30] ? 2'b10 : 2'b01, wd[25:21], wd[20:16], 2'b10, wd[15:0]};
            end else if (m_busy) begin
                mdiv <= mdiv + 6'd1;
                if (mdiv == 6'd0) begin
                    mdc <= 1'b0;
                    if (mbit == 7'd64) begin m_busy <= 1'b0; mdio_oe <= 1'b0; f_mdio <= 1'b1; end
                    else begin mdio_o <= msh[63]; msh <= {msh[62:0], 1'b1}; mdio_oe <= !m_rdop || mbit < 7'd46; end
                end
                if (mdiv == 6'd32 && mbit != 7'd64) begin
                    mdc <= 1'b1;
                    if (m_rdop && mbit >= 7'd48) m_din <= {m_din[14:0], mdio_i};
                end
                if (mdiv == 6'd63) mbit <= mbit + 7'd1;
            end
        end
    end

    // ---------------------------------------------------------------- interrupt, read
    // The flags {MDIO done, frame dropped, frame sent, frame waiting} raise the interrupt when enabled. The
    // read multiplexer `m` gives the register selected by `a`, and `rd` registers it, so read data is valid
    // one clock after the read strobe.
    wire [3:0] fl = {f_mdio, f_drop, f_txd, hd_v};
    assign irq = |(fl & ie);
    reg [31:0] m;
    always @* begin
        case (a)
            6'h00: m = 32'h4554_0001;
            6'h01: m = {26'd0, c_mc, c_bc, c_all, c_prst, c_tx, c_rx};
            6'h02: m = {25'd0, inband[3], inband[2:1], inband[0], rc_run, tx_busy, hd_v};
            6'h03: m = {28'd0, fl};
            6'h04: m = {28'd0, ie};
            6'h05: m = mac[31:0];
            6'h06: m = {16'd0, mac[47:32]};
            6'h07: m = {m_busy, 15'd0, m_din};
            6'h08: m = {31'd0, tx_busy};
            6'h0B: m = hd_v ? {21'd0, hd_len} : 32'd0;
            6'h0C: m = rx_q;
            6'h0E: m = rx_cnt;
            6'h0F: m = {n_bad, n_room};
            6'h10: m = tx_cnt;
            default: m = 32'd0;
        endcase
    end
    initial rd = 32'd0;
    always @(posedge clk) rd <= re ? m : 32'd0;
endmodule

`default_nettype wire
