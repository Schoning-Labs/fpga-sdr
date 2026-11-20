// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Board link on SFP lane 1 (docs/SFP_LINKS.md section 5): the connection that carries the Hermes-Lite 2's
// raw sample stream from the board that has the HL2 (board 1) to a second board (board 2), together with
// small control words and status in both directions. This is the top level of the link, with its register page
// 0x0B "blink" (hw/regmap/blink.toml) for the CPU. The line is a 2.5 Gbit/s lane with 20-bit words, which is
// 125 MHz, the same word clock as lane 0, and it carries 2 Gbit/s of payload against the 0.92 Gbit/s that
// the sample stream needs, so no sample packing is needed.
//
// The two directions:
//   send:    the HL2 sample stream behind the gap filler (fill samples left out, a new frame after each gap)
//            goes into a sample FIFO and an index FIFO, then blink_tx.v makes words, sfp_enc20.v codes them, and
//            they leave as lane words (transmit clock `txc`).
//   receive: lane words (recovered clock `rxc`) go through sfp_rx_sym.v (alignment and decoding) and blink_rx.v
//            (frames and CRC) into blink_rx_buf.v, and from there through a second instance of
//            rtl/hl2link/gap_filler.v in clk_dsp, which fills lost frames with zeros in the same way as on board
//            1, to the stream `rx_*` for the receivers. So board 2's receivers see the same samples at the same
//            index as board 1's, and a frame lost on the link costs at most 128 samples.
//   control words: a 16-deep FIFO each way; status both ways.
// The registers are in clk (clk_dsp) and work with both lane clocks stopped.
//
// Offsets: 0x000 id  0x004 ctrl  0x008 status  0x010 ctl_tx (write: queue a word)  0x014 ctl_rx (read: take
// the waiting word)  0x020.. counters (see the generated map)  0x060/0x064 sample index of the link's stream.
//
// Clock domains: txc (lane transmit), rxc (lane recovered receive) and clk (clk_dsp) are asynchronous to each
// other. The crossings are Gray-coded FIFOs (cdc_sample_fifo.v) for samples, indices and control words, and
// held words (sfp_xstat.v, built on cdc_word.v) for status and counters.

`timescale 1ns / 1ps

module blink_top (
    input  wire        clk,                  // clk_dsp, 120 MHz
    input  wire        rst,                  // synchronous reset, active high
    input  wire        bus_wr,               // register write strobe
    input  wire        bus_rd,               // register read strobe
    input  wire [15:0] bus_addr,             // byte address within the page
    input  wire [31:0] bus_wdata,            // write data
    output reg  [31:0] bus_rdata = 32'd0,    // read data
    // ---- the HL2 stream (clk): sample, valid, fill flag, index of the next sample
    input  wire [11:0] src_samp,             // sample from the HL2 link's gap filler
    input  wire        src_valid,            // a sample in this clock
    input  wire        src_is_fill,          // the sample is zero fill for a lost frame (not sent)
    input  wire [47:0] src_index,            // index of the next sample (the sample just given plus one)
    // ---- the link's stream (clk), same form
    output wire [11:0] rx_samp,              // sample received over the link
    output wire        rx_valid,             // a sample in this clock
    output wire        rx_is_fill,           // the sample is zero fill for a frame lost on the link
    output wire [47:0] rx_index,             // index of the next sample
    output wire        rx_from_link,     // ctrl bit: the receivers take the link's stream
    // ---- lane 1 (line order: bit 0 first)
    input  wire        txc,                  // lane 1 transmit word clock
    output wire [19:0] tx_word,              // two coded symbols to send
    input  wire        rxc,                  // lane 1 recovered receive word clock
    input  wire        rxw_vld,              // rxw is a new word
    input  wire [19:0] rxw,                  // received word, two symbols
    output wire        aligned,          // clk
    output reg         irq = 1'b0        // pulse: a control word waits, or the link went up or down
) /* synthesis syn_srlstyle = "registers" */;

    // The control register: bit 0 enables the link (otherwise all three sides are held in reset), bit 1 sends the
    // samples, bit 2 selects the link's stream for the receivers.
    reg [2:0] r_ctrl = 3'd0;             // 0 enable, 1 send samples, 2 receivers from the link
    wire en = r_ctrl[0];
    assign rx_from_link = r_ctrl[2];

    // ---------------------------------------------------------------- resets
    // One reset per clock (`tx_rst`, `rx_rst`, `d_rst`), all from the enable bit. The lane resets are asserted at once
    // when the link is disabled and released in step with their own clock, four clocks later, as in sfp_phy.v.
    reg [3:0] trs = 4'hF, rrs = 4'hF, drs = 4'hF;
    always @(posedge txc or negedge en) if (!en) trs <= 4'hF; else trs <= {trs[2:0], 1'b0};
    always @(posedge rxc or negedge en) if (!en) rrs <= 4'hF; else rrs <= {rrs[2:0], 1'b0};
    always @(posedge clk) drs <= {drs[2:0], !en || rst};
    wire tx_rst = trs[3], rx_rst = rrs[3], d_rst = drs[3];

    // ---------------------------------------------------------------- send side, clk part
    // The HL2 stream is put into the sample FIFO with a start flag (`need_start`) on the first sample and on the
    // first one after a gap (a fill sample means a frame was lost, so the next real one starts a frame), and the
    // index of each start goes into the index FIFO (`src_index - 1`, since `src_index` is the index of the
    // sample after the one just given). A sample that finds the FIFO full is lost (counted in `c_tx_over`), and
    // the next one starts a new frame, so the receiver sees the jump in the index.
    reg         s_we = 1'b0, i_we = 1'b0, need_start = 1'b1;
    reg  [12:0] s_wd = 13'd0;
    reg  [47:0] i_wd = 48'd0;
    wire        s_full;
    reg  [31:0] c_tx_samples = 32'd0;
    reg  [15:0] c_tx_over = 16'd0;
    always @(posedge clk) begin
        s_we <= 1'b0; i_we <= 1'b0;
        if (d_rst || !r_ctrl[1]) begin
            need_start <= 1'b1;
            if (d_rst) begin c_tx_samples <= 32'd0; c_tx_over <= 16'd0; end
        end else if (src_valid) begin
            if (src_is_fill) need_start <= 1'b1;
            else if (s_full) begin
                need_start <= 1'b1; c_tx_over <= c_tx_over + 16'd1;
            end else begin
                s_we <= 1'b1; s_wd <= {need_start, src_samp};
                i_we <= need_start; i_wd <= src_index - 48'd1;
                need_start <= 1'b0; c_tx_samples <= c_tx_samples + 32'd1;
            end
        end
    end

    wire        ts_pop, ts_valid, ti_pop, ti_valid, tc_pop, tc_valid, c_tx_full;
    wire [12:0] ts_data;
    wire [47:0] ti_data;
    wire [31:0] tc_data;
    // 512 deep: the HL2 link hands a whole Ethernet frame of 5,968 samples on at 120 M samples/s, the lane
    // takes 118.5 M/s (128 samples in 135 words), so about 75 samples pile up per frame
    cdc_sample_fifo #(.W(13), .AW(9), .REG_FULL(1)) u_sfifo (
        .wr_clk(clk), .wr_rst(d_rst), .wr_en(s_we), .wr_data(s_wd), .wr_full(s_full),
        .rd_clk(txc), .rd_rst(tx_rst), .rd_en(ts_pop), .rd_data(ts_data), .rd_valid(ts_valid), .rd_empty()
    );
    cdc_sample_fifo #(.W(48), .AW(4)) u_ififo (
        .wr_clk(clk), .wr_rst(d_rst), .wr_en(i_we), .wr_data(i_wd), .wr_full(),
        .rd_clk(txc), .rd_rst(tx_rst), .rd_en(ti_pop), .rd_data(ti_data), .rd_valid(ti_valid), .rd_empty()
    );
    reg         c_we = 1'b0;
    cdc_sample_fifo #(.W(32), .AW(4), .REG_FULL(1)) u_ctfifo (
        .wr_clk(clk), .wr_rst(d_rst), .wr_en(c_we), .wr_data(bus_wdata), .wr_full(c_tx_full),
        .rd_clk(txc), .rd_rst(tx_rst), .rd_en(tc_pop), .rd_data(tc_data), .rd_valid(tc_valid), .rd_empty()
    );

    // ---------------------------------------------------------------- receive side (rxc)
    wire        sy_vld, sy_locked;
    wire [15:0] sy_d, sy_loss;
    wire [1:0]  sy_k, sy_err;
    sfp_rx_sym #(.N(2)) u_rxsym (
        .clk(rxc), .rst(rx_rst), .vld(rxw_vld), .din(rxw),
        .sym_vld(sy_vld), .sym_d(sy_d), .sym_k(sy_k), .sym_err(sy_err), .locked(sy_locked), .cnt_loss(sy_loss)
    );
    wire        f_sof, f_valid, f_commit, f_drop, rc_valid, r_link;
    wire [11:0] f_data;
    wire [47:0] f_idx;
    wire [7:0]  f_n;
    wire [31:0] rc_data;
    wire [3:0]  rem_flags;
    wire [15:0] rem_bad, n_good, n_bad, n_jump, n_ctl, n_ctl_lost, n_up;
    blink_rx u_rx (
        .clk(rxc), .rst(rx_rst), .sym_vld(sy_vld), .sym_d(sy_d), .sym_k(sy_k), .sym_err(sy_err),
        .locked(sy_locked),
        .f_sof(f_sof), .f_valid(f_valid), .f_data(f_data), .f_commit(f_commit), .f_idx(f_idx), .f_n(f_n),
        .c_valid(rc_valid), .c_data(rc_data),
        .link_up(r_link), .rem_flags(rem_flags), .rem_bad(rem_bad),
        .cnt_good(n_good), .cnt_bad(n_bad), .cnt_jump(n_jump), .cnt_ctl(n_ctl), .cnt_ctl_lost(n_ctl_lost),
        .cnt_up(n_up)
    );
    reg [15:0] n_over = 16'd0, n_cdrop = 16'd0;
    wire       rc_full;
    always @(posedge rxc) begin
        if (rx_rst) begin n_over <= 16'd0; n_cdrop <= 16'd0; end
        else begin
            if (f_drop) n_over <= n_over + 16'd1;
            if (rc_valid && rc_full) n_cdrop <= n_cdrop + 16'd1;
        end
    end

    wire        g_pop, g_sof, g_valid, gi_pop, gi_valid;
    wire [11:0] g_data;
    wire [47:0] gi_data;
    blink_rx_buf #(.AW(10)) u_buf (
        .clk_rx(rxc), .rst_rx(rx_rst), .sof(f_sof), .s_valid(f_valid), .s_data(f_data),
        .commit(f_commit), .commit_first_idx(f_idx), .commit_n(f_n), .drop(f_drop),
        .clk_dsp(clk), .rst_dsp(d_rst),
        .samp_pop(g_pop), .samp_sof(g_sof), .samp_data(g_data), .samp_valid(g_valid),
        .idx_pop(gi_pop), .idx_data(gi_data), .idx_valid(gi_valid)
    );
    wire [31:0] g_events, g_samples, g_resync;
    gap_filler u_gap (
        .clk(clk), .rst(d_rst),
        .samp_pop(g_pop), .samp_sof(g_sof), .samp_data(g_data), .samp_valid(g_valid),
        .idx_pop(gi_pop), .idx_data(gi_data), .idx_valid(gi_valid),
        .out_sample(rx_samp), .out_valid(rx_valid), .out_is_fill(rx_is_fill),
        .expected_idx(rx_index), .cnt_gap_events(g_events), .cnt_gap_samples(g_samples),
        .cnt_resync_events(g_resync), .irq_gap()
    );
    reg [31:0] c_rx_samples = 32'd0;
    always @(posedge clk) if (d_rst) c_rx_samples <= 32'd0; else if (rx_valid && !rx_is_fill) c_rx_samples <= c_rx_samples + 32'd1;

    // received control words into clk: a FIFO from rxc to clk, and one word held ready for the CPU (`cr_q`)
    wire        cr_valid, cr_empty;
    wire [31:0] cr_data;
    reg         cr_pop = 1'b0, cr_wait = 1'b0, cr_have = 1'b0;
    reg  [31:0] cr_q = 32'd0;
    cdc_sample_fifo #(.W(32), .AW(4), .REG_FULL(1)) u_crfifo (
        .wr_clk(rxc), .wr_rst(rx_rst), .wr_en(rc_valid), .wr_data(rc_data), .wr_full(rc_full),
        .rd_clk(clk), .rd_rst(d_rst), .rd_en(cr_pop), .rd_data(cr_data), .rd_valid(cr_valid), .rd_empty(cr_empty)
    );

    // ---------------------------------------------------------------- status between the domains
    // rxc -> txc: what my status word says; rxc -> clk: state and counters; clk -> txc: two flags
    wire [17:0] x_rt;
    sfp_xstat #(.W(18), .AGE(7)) u_xrt (.clk_a(rxc), .d_a({r_link && rem_flags[0], r_link, n_bad}), .clk_b(txc), .q_b(x_rt), .alive(), .upd_b());
    reg [1:0] f_s1 = 2'd0, f_s2 = 2'd0;
    always @(posedge txc) begin f_s1 <= {rc_full, r_ctrl[1]}; f_s2 <= f_s1; end

    wire [181:0] x_rc;
    sfp_xstat #(.W(182), .AGE(9)) u_xrc (
        .clk_a(rxc),
        .d_a({rc_full, sy_locked, r_link, rem_flags, n_cdrop, n_over, sy_loss, rem_bad, n_up, n_ctl_lost,
              n_ctl, n_jump, n_bad, n_good, 15'd0}),
        .clk_b(clk), .q_b(x_rc), .alive(), .upd_b()
    );
    wire [15:0] q_good = x_rc[30:15], q_bad = x_rc[46:31], q_jump = x_rc[62:47], q_ctl = x_rc[78:63],
                q_ctl_lost = x_rc[94:79], q_up = x_rc[110:95], q_rem_bad = x_rc[126:111],
                q_loss = x_rc[142:127], q_over = x_rc[158:143], q_cdrop = x_rc[174:159];
    wire [3:0]  q_rem = x_rc[178:175];
    wire        q_link = x_rc[179], q_locked = x_rc[180], q_rcfull = x_rc[181];
    assign aligned = q_locked;

    // ---------------------------------------------------------------- send side, lane part (txc)
    // The status that goes to the other end: its link flag (`x_rt[16]`, the receiver state carried into txc), whether
    // samples are sent and whether the control receive FIFO is full (`f_s2`), and the count of bad frames.
    wire [15:0] w_d, t_frames, t_ctl;
    wire [1:0]  w_k;
    blink_tx u_tx (
        .clk(txc), .rst(tx_rst),
        .s_pop(ts_pop), .s_data(ts_data), .s_valid(ts_valid),
        .i_pop(ti_pop), .i_data(ti_data), .i_valid(ti_valid),
        .c_pop(tc_pop), .c_data(tc_data), .c_valid(tc_valid),
        .st_flags({1'b0, f_s2[1], f_s2[0], x_rt[16]}), .st_bad(x_rt[15:0]), .st_fast(!x_rt[17]),
        .w_d(w_d), .w_k(w_k), .cnt_frames(t_frames), .cnt_ctl(t_ctl)
    );
    sfp_enc20 u_enc (.clk(txc), .rst(tx_rst), .d(w_d), .k(w_k), .q(tx_word));
    wire [31:0] x_tc;
    sfp_xstat #(.W(32), .AGE(9)) u_xtc (.clk_a(txc), .d_a({t_ctl, t_frames}), .clk_b(clk), .q_b(x_tc), .alive(), .upd_b());

    // ---------------------------------------------------------------- registers (clk)
    // A write is taken one clock after the strobe, a read is answered in two steps (as in sfp_top.v). Writing
    // 0x10 queues the control word on the bus, and reading 0x14 releases the one that is held and lets the next
    // one be fetched. Reading 0x60 takes a snapshot of the link stream's sample index so that 0x64 shows the
    // upper bits of the same moment. The interrupt pulses when a control word arrives or the link changes.
    reg         wr_q = 1'b0, rd_q = 1'b0, link_q = 1'b0;
    reg  [31:0] reg_q = 32'd0;
    wire        sel = (bus_addr[15:8] == 8'h00);
    reg  [47:0] idx_snap = 48'd0;
    always @(posedge clk) begin
        wr_q <= bus_wr; rd_q <= bus_rd;
        c_we <= 1'b0; cr_pop <= 1'b0; irq <= 1'b0;
        if (rst) r_ctrl <= 3'd0;
        else if (wr_q && sel) begin
            if (bus_addr[7:0] == 8'h04) r_ctrl <= bus_wdata[2:0];
            if (bus_addr[7:0] == 8'h10) c_we <= 1'b1;
        end
        // one received control word held ready
        if (d_rst) begin cr_have <= 1'b0; cr_wait <= 1'b0; end
        else if (cr_valid) begin cr_q <= cr_data; cr_have <= 1'b1; cr_wait <= 1'b0; irq <= 1'b1; end
        else if (rd_q && sel && (bus_addr[7:0] == 8'h14)) cr_have <= 1'b0;
        else if (!cr_have && !cr_wait && !cr_pop && !cr_empty) begin cr_pop <= 1'b1; cr_wait <= 1'b1; end
        else if (cr_wait && !cr_pop) cr_wait <= 1'b0;
        link_q <= q_link;
        if (link_q != q_link) irq <= 1'b1;
        if (bus_rd && (bus_addr[7:0] == 8'h60)) idx_snap <= rx_index;

        case (bus_addr[7:0])
            8'h00: reg_q <= 32'h424C_0001;
            8'h04: reg_q <= {29'd0, r_ctrl};
            8'h08: reg_q <= {24'd0, 1'b0, cr_have, c_tx_full, q_rem[2], q_rem[1], q_rem[0], q_link, q_locked};
            8'h14: reg_q <= cr_q;
            8'h20: reg_q <= {16'd0, q_good};
            8'h24: reg_q <= {16'd0, q_bad};
            8'h28: reg_q <= {16'd0, q_jump};
            8'h2C: reg_q <= {16'd0, q_loss};
            8'h30: reg_q <= {16'd0, q_up};
            8'h34: reg_q <= c_tx_samples;
            8'h38: reg_q <= c_rx_samples;
            8'h3C: reg_q <= {x_tc[31:16], x_tc[15:0]};
            8'h40: reg_q <= {q_ctl_lost, q_ctl};
            8'h44: reg_q <= {16'd0, q_cdrop};
            8'h48: reg_q <= {16'd0, q_rem_bad};
            8'h4C: reg_q <= g_events;
            8'h50: reg_q <= g_samples;
            8'h54: reg_q <= g_resync;
            8'h58: reg_q <= {16'd0, c_tx_over};
            8'h5C: reg_q <= {16'd0, q_over};
            8'h60: reg_q <= idx_snap[31:0];
            8'h64: reg_q <= {16'd0, idx_snap[47:32]};
            default: reg_q <= 32'd0;
        endcase
        bus_rdata <= sel ? reg_q : 32'd0;
    end

endmodule
