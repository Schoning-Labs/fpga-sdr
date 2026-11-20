// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// A network socket on SFP lane 0: everything between the raw lane words and the CPU's packet memory
// (docs/SFP_LINKS.md section 4). It contains the comma alignment, 8b/10b and the PCS (sfp_phy.v), an
// Ethernet MAC (rtl/n1/gmii_mac_tx.v and gmii_mac_rx.v) and the packet memory that the firmware reads and
// writes. The chip does not use it: SFP0 carries the Hermes-Lite 2 link, and rtl/sfp/sfp_top.v is built
// with NET_MAC = 0. It is kept with its testbench (sim/sfp/tb_sfp_net.v), which also checks the PCS that
// the HL2 link uses.
//
// What a MAC is, for a beginner: the media access control layer builds and takes apart Ethernet frames. On
// transmit it adds the preamble and the FCS (frame check sequence) to a frame prepared by software, and on
// receive it checks the FCS and gives good frames to the memory. The PCS below it (sfp_phy.v) does the line
// coding, and this module adds the memory for the CPU around the MAC.
//
// Three clocks:
//   txc   lane 0 transmit word clock: coder, PCS transmit side and negotiation, MAC transmit
//   rxc   lane 0 recovered word clock: aligner, decoder, PCS receive side, MAC receive, ring write side
//   clk   clk_dsp: the CPU's side of the packet memory and every register (the page is in sfp_top.v)
// Either lane clock may be stopped: nothing in `clk` waits for them (sfp_xstat ages the status out).
//
// Packet memory, two-clock block RAMs with a 32-bit port at the CPU:
//   transmit buffer  512 words (2 KB), one frame in flight: the CPU writes the frame (destination MAC to
//                    last payload byte, at least 60 bytes, no FCS; byte k of the frame in bits 8(k%4)+7..8(k%4)
//                    of word k/4), then its length; `tx_busy` until the MAC has read it. A frame that
//                    waits while the link is down is dropped.
//   receive ring     2,048 words (8 KB). A frame is one header word (its length in bytes, FCS not
//                    included) and then ceil(length / 4) data words, same byte order. `rx_wr_ptr` (in words)
//                    moves past a frame only when its FCS was good and it fitted; the CPU moves
//                    `rx_rd_ptr` when it has read one. The writer never passes `rx_rd_ptr`.
// The CPU talks to a block RAM with 32-bit words, four bytes per register access, while the MAC works with
// single bytes, which is why each memory has a wide port on the CPU side and a byte-wide access on the MAC
// side (the MAC side reads or writes a word and picks its byte).

`timescale 1ns / 1ps

module sfp_net #(
    parameter integer TIMER_X     = 1250000,
    parameter integer TIMER_SGMII = 200000
) (
    // ---- lane 0 (line order: bit 0 first on the line)
    input  wire        txc,              // lane 0 transmit word clock
    output wire [9:0]  tx_word,          // word to send
    input  wire        rxc,              // lane 0 recovered receive word clock
    input  wire        rx_vld,           // rx_word is new
    input  wire [9:0]  rx_word,          // word received
    // ---- clk_dsp side
    input  wire        clk,              // clk_dsp
    input  wire        cfg_enable,       // 0: both lane-clock sides held in reset
    input  wire        cfg_sgmii,        // 1: SGMII, 0: 1000BASE-X
    input  wire        cfg_an,           // 1: auto-negotiation on
    input  wire        cfg_restart_tog,  // toggles: restart negotiation
    // transmit buffer
    input  wire        txb_we,           // write txb_wdata to word txb_addr
    input  wire [8:0]  txb_addr,         // word address in the transmit buffer
    input  wire [31:0] txb_wdata,        // four frame bytes
    input  wire        tx_send,          // pulse with tx_len
    input  wire [10:0] tx_len,           // frame length in bytes, FCS not included
    output reg         tx_busy = 1'b0,   // a frame is queued or being sent
    // receive ring
    input  wire [10:0] rxr_addr,         // word address in the receive ring
    output reg  [31:0] rxr_rdata = 32'd0,   // one clock after rxr_addr
    input  wire [10:0] rx_rd_ptr,        // the CPU's read pointer, in words
    output wire [10:0] rx_wr_ptr,        // write pointer past the newest good frame, in words
    output wire [15:0] rx_frames,        // frames added to the ring
    output wire [15:0] rx_dropped,       // frames dropped (bad FCS, too big, ring full)
    output wire [15:0] rx_crc_errors,    // frames with a bad FCS
    output wire [15:0] align_losses,     // times the aligner lost its lock
    // status
    output wire        st_link_up,       // link up
    output wire        st_an_done,       // negotiation complete
    output wire        st_rx_sync,       // receive side has symbol lock
    output wire        st_rx_idle,       // idle ordered sets are arriving
    output wire        st_aligned,       // the aligner's lock
    output wire [15:0] st_partner,       // the partner's last configuration word
    output reg         irq_rx = 1'b0,    // pulse: a frame was added to the ring
    output wire        irq_link          // pulse: link went up or down
) /* synthesis syn_srlstyle = "registers" */;

    // ---------------------------------------------------------------- aligner, decoder, PCS, coder (sfp_phy.v)
    // The whole line layer is in sfp_phy.v, which the HL2 link uses on the same lane. It gives the MAC the
    // received bytes (`mrx_*`, with a byte enable) and takes the transmit bytes (`mac_d`, `mac_en`).
    wire [7:0]  mac_d, mrx_d;
    wire        mac_en, mrx_dv, mrx_er, mrx_ce, link_up, tx_rst, rx_rst;
    sfp_phy #(.TIMER_X(TIMER_X), .TIMER_SGMII(TIMER_SGMII)) u_phy (
        .txc(txc), .tx_word(tx_word), .rxc(rxc), .rx_vld(rx_vld), .rx_word(rx_word),
        .clk(clk), .cfg_enable(cfg_enable), .cfg_sgmii(cfg_sgmii), .cfg_an(cfg_an), .cfg_restart_tog(cfg_restart_tog),
        .rx_rst(rx_rst), .g_rx_d(mrx_d), .g_rx_dv(mrx_dv), .g_rx_er(mrx_er), .g_rx_ce(mrx_ce), .rx_locked(),
        .tx_rst(tx_rst), .g_tx_d(mac_d), .g_tx_en(mac_en), .tx_link_up(link_up),
        .st_link_up(st_link_up), .st_an_done(st_an_done), .st_rx_sync(st_rx_sync), .st_rx_idle(st_rx_idle),
        .st_aligned(st_aligned), .st_partner(st_partner), .align_losses(align_losses), .code_errors(),
        .irq_link(irq_link)
    );
    // The MAC's enable one clock late, as the PCS sees it (sfp_phy.v has a register between them), so
    // that the interframe gap count below sees the end of the frame on the PCS's side.
    reg         mtx_en = 1'b0;
    always @(posedge txc) mtx_en <= mac_en;

    // ---------------------------------------------------------------- transmit buffer and MAC (txc)
    // The CPU writes the frame into `txmem` (clk) and then its length with `tx_send`. The length crosses to
    // txc through a cdc_word, `pending` says that a frame waits, the MAC reads the memory byte by byte
    // (a word, then one of its four bytes picked by `tx_bsel`), and when it has taken the frame (or the
    // link is down, which drops the frame) `done_tog` toggles back to clk and clears `tx_busy`.
    reg [31:0] txmem [0:511];
    always @(posedge clk) if (txb_we) txmem[txb_addr] <= txb_wdata;

    wire [13:0] mt_addr;
    reg  [31:0] tx_q = 32'd0;
    reg  [1:0]  tx_bsel = 2'd0;
    always @(posedge txc) begin
        tx_q    <= txmem[mt_addr[10:2]];
        tx_bsel <= mt_addr[1:0];
    end
    wire [7:0] mt_data = tx_q[8*tx_bsel +: 8];

    wire [10:0] tlen_t;
    wire        tsend_t;
    cdc_word #(.W(11)) u_xsend (.clk_a(clk), .d_a(tx_len), .send_a(tx_send), .clk_b(txc), .q_b(tlen_t), .valid_b(tsend_t));

    reg        pending = 1'b0, done_tog = 1'b0;
    reg [4:0]  gap = 5'd0;               // clocks since the MAC's last byte, up to 20: interframe gap
    wire       taken;
    always @(posedge txc) begin
        if (mac_en || mtx_en) gap <= 5'd0; else if (gap != 5'd20) gap <= gap + 5'd1;
        if (tx_rst) pending <= 1'b0;
        else if (tsend_t) pending <= 1'b1;
        else if (pending && (taken || !link_up)) begin pending <= 1'b0; done_tog <= ~done_tog; end
    end
    gmii_mac_tx u_mtx (
        .clk(txc), .rst(tx_rst), .link_up(link_up),
        .tx_has_frame(pending && (gap == 5'd20)), .tx_frame_len({5'd0, tlen_t}),
        .tx_rd_addr(mt_addr), .tx_rd_data(mt_data), .tx_frame_taken(taken),
        .mac_tx_data(mac_d), .mac_tx_en(mac_en)
    );

    // done_tog comes back into clk through three flip-flops and an edge detect, and clears tx_busy.
    reg [2:0] done_s = 3'd0;
    always @(posedge clk) begin
        done_s <= {done_s[1:0], done_tog};
        if (tx_send) tx_busy <= 1'b1;
        else if ((done_s[2] ^ done_s[1]) || !cfg_enable) tx_busy <= 1'b0;
    end

    // ---------------------------------------------------------------- MAC receive and ring (rxc)
    // The MAC delivers the frame bytes with a start, a valid strobe, an end and, at the end, whether the FCS
    // was good. The bytes are packed four to a word into the ring as they arrive. The place of the header
    // word (at `wr_ptr`) is reserved when the frame starts and the length is written into it at the end,
    // and the frame only counts (`wr_ptr` moves past it) when its FCS was good and it did not run into
    // the CPU's read pointer.
    wire        r_sof, r_valid, r_eof, r_good;
    wire [7:0]  r_data;
    wire [31:0] r_crc_errs;
    gmii_mac_rx u_mrx (
        .clk(rxc), .rst(rx_rst), .mac_rx_data(mrx_d), .mac_rx_dv(mrx_dv), .mac_rx_er(mrx_er), .ce(mrx_ce),
        .rx_sof(r_sof), .rx_valid(r_valid), .rx_data(r_data), .rx_eof(r_eof), .rx_crc_good(r_good),
        .cnt_crc_errors(r_crc_errs)
    );

    wire [10:0] rdp_r;                   // the CPU's read pointer as the writer sees it (crossed with sfp_xstat)
    sfp_xstat #(.W(11), .AGE(7)) u_xrdp (.clk_a(clk), .d_a(rx_rd_ptr), .clk_b(rxc), .q_b(rdp_r), .alive(), .upd_b());

    reg [31:0] rxmem [0:2047];
    reg        w_en = 1'b0;
    reg [10:0] w_addr = 11'd0;
    reg [31:0] w_data = 32'd0;
    always @(posedge rxc) if (w_en) rxmem[w_addr] <= w_data;
    always @(posedge clk) rxr_rdata <= rxmem[rxr_addr];

    reg [10:0] wr_ptr = 11'd0, wp = 11'd0;      // committed / working (next data word)
    reg [23:0] acc = 24'd0;                     // the first three bytes of the word being assembled
    reg [10:0] blen = 11'd0;                    // bytes of the frame so far (counted up to 1,600)
    // active: a frame is being received; over: it does not fit (too long or ring full); flush: the last,
    // partly filled word is to be written; hdr: the header word is to be written; good_q: the frame's FCS was good.
    reg        active = 1'b0, over = 1'b0, flush = 1'b0, hdr = 1'b0, good_q = 1'b0;
    reg [15:0] c_frames = 16'd0, c_dropped = 16'd0;
    // The "ring is full" compare is registered. wp moves at most every fourth clock (a word is written
    // for four bytes), and the compare is used when a word is to be written, a frame starts or the last
    // partial word is written, never in the clock after wp moved, so the registered flag is never stale
    // when it matters.
    reg        full_q = 1'b0;
    always @(posedge rxc) full_q <= ((wp + 11'd1) == rdp_r);
    wire       full = full_q;

    always @(posedge rxc) begin
        w_en <= 1'b0;
        if (rx_rst) begin
            wr_ptr <= 11'd0; wp <= 11'd0; active <= 1'b0; flush <= 1'b0; hdr <= 1'b0;
            c_frames <= 16'd0; c_dropped <= 16'd0;
        end else begin
            if (flush) begin                      // last, partly filled word of the frame
                flush <= 1'b0; hdr <= 1'b1;
                if (blen[1:0] != 2'd0) begin
                    if (full) over <= 1'b1;
                    else begin w_en <= 1'b1; w_addr <= wp; w_data <= {8'd0, acc}; wp <= wp + 11'd1; end
                end
            end else if (hdr) begin               // header word, then the frame counts
                hdr <= 1'b0;
                if (good_q && !over) begin
                    w_en <= 1'b1; w_addr <= wr_ptr; w_data <= {21'd0, blen};
                    wr_ptr <= wp; c_frames <= c_frames + 16'd1;
                end else begin
                    wp <= wr_ptr + 11'd1;
                    c_dropped <= c_dropped + 16'd1;
                end
            end
            if (r_valid && (r_sof || active)) begin
                if (r_sof) begin
                    active <= 1'b1; over <= full; blen <= 11'd1; wp <= wr_ptr + 11'd1;
                    acc[7:0] <= r_data;
                end else begin
                    if (blen == 11'd1600) over <= 1'b1; else blen <= blen + 11'd1;
                    case (blen[1:0])
                        2'd0: acc[7:0]   <= r_data;
                        2'd1: acc[15:8]  <= r_data;
                        2'd2: acc[23:16] <= r_data;
                        default: begin
                            if (full) over <= 1'b1;
                            else if (!over) begin
                                w_en <= 1'b1; w_addr <= wp; w_data <= {r_data, acc}; wp <= wp + 11'd1;
                            end
                        end
                    endcase
                end
            end
            if (r_eof && active) begin
                active <= 1'b0; flush <= 1'b1; good_q <= r_good;
            end
        end
    end

    // ---------------------------------------------------------------- status into clk
    // The ring's counters and write pointer cross into clk as one word (sfp_xstat). The frame count
    // crosses as 5 bits and is widened here, since it moves by far less than 32 between two words, and
    // the interrupt pulses when the write pointer has moved.
    wire [47:0] xr;
    wire        xr_upd;
    sfp_xstat #(.W(48), .AGE(9)) u_xr (
        .clk_a(rxc), .d_a({r_crc_errs[15:0], c_dropped, c_frames[4:0], wr_ptr}),
        .clk_b(clk), .q_b(xr), .alive(), .upd_b(xr_upd)
    );
    // (the frame count crosses as 5 bits and is widened here: it moves by far less than 32 between words)
    reg [15:0] frames_w = 16'd0;
    reg [4:0]  frames_l = 5'd0;
    reg [10:0] wr_ptr_q = 11'd0;
    always @(posedge clk) begin
        irq_rx <= 1'b0;
        if (!cfg_enable) begin
            frames_w <= 16'd0; frames_l <= 5'd0; wr_ptr_q <= 11'd0;
        end else if (xr_upd) begin
            frames_w <= frames_w + {11'd0, xr[15:11] - frames_l};
            frames_l <= xr[15:11];
            wr_ptr_q <= xr[10:0];
            irq_rx   <= (xr[10:0] != wr_ptr_q);
        end
    end
    assign rx_wr_ptr     = wr_ptr_q;
    assign rx_frames     = frames_w;
    assign rx_dropped    = xr[31:16];
    assign rx_crc_errors = xr[47:32];

endmodule
