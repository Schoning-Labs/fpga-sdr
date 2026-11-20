// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Testbench for the board link, rtl/blink/blink_top.v, which carries the HL2 sample stream and small control
// words between two boards over an SFP cable (docs/SFP_LINKS.md section 9, docs/learn/GLOSSARY.md). Two
// instances of the link, board A and board B, are connected through two lane models
// (sim/sfp/sfp_lane_model.v), one per direction, which have different clocks (B's clocks are slightly off A's)
// and different bit positions, so each receiver has to find its word boundary and cope with the frequency
// offset.
//
// Stimulus: board A sends a sample stream shaped like the HL2 link's, in bursts at the full clock rate with a
// gap of fill samples (a gap in the source marks samples that the gap filler inserts, which the link leaves
// out and sends again as a new frame after the gap). The stream behind board B's gap filler must carry every
// sample at its own index, bit exact, with fill samples exactly where A had a gap or where the link lost a
// frame. The cases are a clean stream with a gap at the source; one corrupted word on the lane (one frame
// lost, zero-filled, the index unbroken); a dead line (lock lost, link down, up again, and the stream goes
// on); control words in both directions; status in both directions; and the counters.
//
// Pass: no check fails; the bench prints one line per case and then "PASS: tb_blink (n samples bit-exact at
// their index, n zero-filled)", otherwise FAIL lines and "FAILED: n errors".
//
// How to run: from the repository root, `bash sim/blink/run.sh`.

`timescale 1ns / 1ps

module tb_blink;
    // Two register clocks of the boards (clk_a 120 MHz, clk_b about 100 ppm faster) and the lane clocks of
    // their transmitters (txc_a 125 MHz, txc_b 100 ppm slow), so that the two ends are never locked.
    reg clk_a = 0, clk_b = 0, txc_a = 0, txc_b = 0, rst = 1;
    always #4.1667 clk_a = ~clk_a;
    always #4.1663 clk_b = ~clk_b;
    always #4.0    txc_a = ~txc_a;
    always #4.0004 txc_b = ~txc_b;
    integer errors = 0;

    // ---- bus of each end
    // Register write (followed by 4 idle clocks) and register read (data taken 5 clocks later) tasks for each
    // board in its own clock domain.
    // ---- bus of each end
    reg         a_wr = 0, a_rd = 0, b_wr = 0, b_rd = 0;
    reg  [15:0] a_addr = 0, b_addr = 0;
    reg  [31:0] a_wd = 0, b_wd = 0;
    wire [31:0] a_q, b_q;
    reg  [31:0] rdv;
    task awr(input [15:0] a, input [31:0] d); begin
        @(posedge clk_a); a_addr <= a; a_wd <= d; a_wr <= 1; @(posedge clk_a); a_wr <= 0; repeat (4) @(posedge clk_a);
    end endtask
    task ard(input [15:0] a); begin
        @(posedge clk_a); a_addr <= a; a_rd <= 1; @(posedge clk_a); a_rd <= 0; repeat (5) @(posedge clk_a); rdv = a_q;
    end endtask
    task bwr(input [15:0] a, input [31:0] d); begin
        @(posedge clk_b); b_addr <= a; b_wd <= d; b_wr <= 1; @(posedge clk_b); b_wr <= 0; repeat (4) @(posedge clk_b);
    end endtask
    task brd(input [15:0] a); begin
        @(posedge clk_b); b_addr <= a; b_rd <= 1; @(posedge clk_b); b_rd <= 0; repeat (5) @(posedge clk_b); rdv = b_q;
    end endtask

    // ---- board A's source stream, as the gap filler gives it: index = index of this sample + 1
    // ref_s and ref_f remember, by the low 16 bits of the index, the sample sent and whether it was a fill
    // sample, as the reference for board B's output.
    reg  [11:0] s_samp = 0;
    reg         s_valid = 0, s_fill = 0, run = 0;
    reg  [47:0] s_index = 48'h0012_3456_0000;
    reg  [11:0] ref_s [0:65535];
    reg         ref_f [0:65535];
    integer     sent = 0, phase = 0, lfsr = 32'h1234567;
    reg  [15:0] gap_at = 16'd9000;       // 40 fill samples from here
    // The source runs 3,000 clocks at the full rate and then 1,700 silent (4,700 per cycle, which averages
    // 76.6 million samples per second at 120 MHz), with random sample values from a 32-bit LFSR. 40 samples
    // from index 9000 (in the low 16 bits) are fill samples with value 0, which is the gap at the source.
    always @(posedge clk_a) begin
        s_valid <= 0; s_fill <= 0;
        phase <= (phase == 4699) ? 0 : phase + 1;
        if (run && phase < 3000) begin     // 3,000 clocks at the full rate, 1,700 silent: 76.6 M samples/s
            lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            s_valid <= 1;
            s_fill  <= (s_index[15:0] >= gap_at) && (s_index[15:0] < gap_at + 40);
            s_samp  <= ((s_index[15:0] >= gap_at) && (s_index[15:0] < gap_at + 40)) ? 12'd0 : lfsr[11:0];
            ref_s[s_index[15:0]] = ((s_index[15:0] >= gap_at) && (s_index[15:0] < gap_at + 40)) ? 12'd0 : lfsr[11:0];
            ref_f[s_index[15:0]] = (s_index[15:0] >= gap_at) && (s_index[15:0] < gap_at + 40);
            s_index <= s_index + 1;
            sent = sent + 1;
        end
    end

    // ---- the two ends and the lanes
    // Board A has the stream source and board B receives it. Both have their register bus and an interrupt.
    // B's receiver output is o_*, with b_sel showing that its receivers are set to take the link's stream.
    // ---- the two ends and the lanes
    wire [19:0] a_tx, b_tx, a_rxw, b_rxw;
    wire        a_rxc, b_rxc, a_irq, b_irq, a_al, b_al;
    reg  [19:0] ab_err = 0;
    reg         ab_cut = 0;
    wire [11:0] o_samp; wire o_valid, o_fill; wire [47:0] o_index; wire b_sel;

    blink_top a (
        .clk(clk_a), .rst(rst), .bus_wr(a_wr), .bus_rd(a_rd), .bus_addr(a_addr), .bus_wdata(a_wd), .bus_rdata(a_q),
        .src_samp(s_samp), .src_valid(s_valid), .src_is_fill(s_fill), .src_index(s_index),
        .rx_samp(), .rx_valid(), .rx_is_fill(), .rx_index(), .rx_from_link(),
        .txc(txc_a), .tx_word(a_tx), .rxc(a_rxc), .rxw_vld(1'b1), .rxw(a_rxw), .aligned(a_al), .irq(a_irq)
    );
    blink_top b (
        .clk(clk_b), .rst(rst), .bus_wr(b_wr), .bus_rd(b_rd), .bus_addr(b_addr), .bus_wdata(b_wd), .bus_rdata(b_q),
        .src_samp(12'd0), .src_valid(1'b0), .src_is_fill(1'b0), .src_index(48'd0),
        .rx_samp(o_samp), .rx_valid(o_valid), .rx_is_fill(o_fill), .rx_index(o_index), .rx_from_link(b_sel),
        .txc(txc_b), .tx_word(b_tx), .rxc(b_rxc), .rxw_vld(1'b1), .rxw(b_rxw), .aligned(b_al), .irq(b_irq)
    );
    // Lane from A to B with an error mask (ab_err flips bits of a word) and a cut (ab_cut kills the line), and the
    // lane back from B to A, which is kept clean.
    sfp_lane_model #(.W(20), .OFFSET(13)) u_ab (.tx_clk(txc_a), .tx_word(a_tx), .rx_clk(b_rxc), .rx_word(b_rxw),
                                               .err(ab_err), .cut(ab_cut));
    sfp_lane_model #(.W(20), .OFFSET(4)) u_ba (.tx_clk(txc_b), .tx_word(b_tx), .rx_clk(a_rxc), .rx_word(a_rxw),
                                              .err(20'd0), .cut(1'b0));

    // ---- check of board B's stream
    // Every valid sample at B must have the next index (the index that comes with a sample is that of the next
    // one, hence the minus 1), the right upper bits, and either be a fill sample of value 0 or equal what A
    // sent at that index.
    // ---- check of board B's stream
    integer got = 0, got_fill = 0;
    reg [47:0] last_idx = 0; reg have_last = 0;
    wire [47:0] o_idx = o_index - 48'd1;
    always @(posedge clk_b) if (o_valid) begin
        if (have_last && (o_idx !== last_idx + 48'd1)) begin
            errors = errors + 1; if (errors < 20) $display("FAIL: index %h after %h", o_idx, last_idx);
        end
        last_idx = o_idx; have_last = 1;
        if (o_idx[47:16] !== 32'h0012_3456) begin errors = errors + 1; if (errors < 20) $display("FAIL: index %h", o_idx); end
        if (o_fill) begin
            got_fill = got_fill + 1;
            if (o_samp !== 12'd0) begin errors = errors + 1; $display("FAIL: fill sample not zero"); end
        end else begin
            got = got + 1;
            if (ref_f[o_idx[15:0]] !== 1'b0 || o_samp !== ref_s[o_idx[15:0]]) begin
                errors = errors + 1;
                if (errors < 20) $display("FAIL: sample at %h is %h, sent %h (fill %b)", o_idx, o_samp, ref_s[o_idx[15:0]], ref_f[o_idx[15:0]]);
            end
        end
    end
    // Interrupt pulses at each board.
    integer a_irqs = 0, b_irqs = 0;
    always @(posedge clk_a) if (a_irq) a_irqs = a_irqs + 1;
    always @(posedge clk_b) if (b_irq) b_irqs = b_irqs + 1;

    // Sequence of the cases below. Counters read through the registers: 0x24 bad frames at B, 0x2C lock
    // losses, 0x30 link-up count, 0x34 samples queued at A, 0x38 samples received at B, 0x40 control word
    // counters, 0x48 the peer's bad frame count, 0x58 transmit FIFO overflows, 0x5C receive overruns, and
    // 0x60 and 0x64 the sample index of the link's stream.
    integer i, fill_before;
    initial begin
        repeat (20) @(posedge clk_a); rst = 0;
        // Identification register: 0x424C_0001 ('B' 'L', layout version 1).
        ard(16'h0000); if (rdv !== 32'h424C_0001) begin errors = errors + 1; $display("FAIL: id %h", rdv); end
        // Enable A (bit 0) and B (bits 0 and 2: enable, and the receivers take the link's stream), and wait 4,000
        // clocks for the lanes to align and lock; both status words must then show bits 2:0 set, which are
        // aligned, link up and remote link up.
        awr(16'h0004, 32'h1); bwr(16'h0004, 32'h5);
        repeat (4000) @(posedge clk_a);
        ard(16'h0008); if (rdv[2:0] !== 3'b111) begin errors = errors + 1; $display("FAIL: A status %h", rdv); end
        brd(16'h0008); if (rdv[2:0] !== 3'b111) begin errors = errors + 1; $display("FAIL: B status %h", rdv); end
        if (!b_sel) begin errors = errors + 1; $display("FAIL: B's select bit"); end

        // --- stream with a gap at the source (A also sends samples now: control bits 0 and 1)
        awr(16'h0004, 32'h3); run = 1;
        repeat (22000) @(posedge clk_a);
        if (got < 12000) begin errors = errors + 1; $display("FAIL: only %0d samples at B", got); end
        if (got_fill != 40) begin errors = errors + 1; $display("FAIL: %0d fill samples at B, 40 sent", got_fill); end
        brd(16'h0008); if (!rdv[3]) begin errors = errors + 1; $display("FAIL: B does not see A sending"); end
        brd(16'h0024); if (rdv !== 0) begin errors = errors + 1; $display("FAIL: bad frames %0d on a clean line", rdv); end
        $display("  clean stream and source gap: %0d samples, %0d fill at B", got, got_fill);

        // --- one corrupted word: one frame lost and zero-filled; the bit flip is done in the middle of a
        // burst (phase 500 of the source cycle), and the index must stay unbroken, with at least 1 and at most
        // 128 samples filled for the lost frame
        fill_before = got_fill;
        @(posedge clk_a); wait (phase == 500); repeat (3) @(posedge b_rxc);
        ab_err <= 20'h00100; @(posedge b_rxc); ab_err <= 0;
        repeat (9000) @(posedge clk_a);
        brd(16'h0024); if (rdv !== 1) begin errors = errors + 1; $display("FAIL: bad frames %0d, expected 1", rdv); end
        if (got_fill - fill_before < 1 || got_fill - fill_before > 128) begin
            errors = errors + 1; $display("FAIL: %0d samples filled for one lost frame", got_fill - fill_before);
        end
        $display("  one corrupted word: %0d samples zero-filled", got_fill - fill_before);
        ard(16'h0048); if (rdv !== 1) begin errors = errors + 1; $display("FAIL: A reads B's bad count as %0d", rdv); end

        // --- dead line for 400 words: lock lost, link down, then up again; the stream goes on after the
        // line comes back, with the samples of the dead time zero-filled
        fill_before = got_fill;
        wait (phase == 800); ab_cut <= 1; repeat (400) @(posedge txc_a);
        brd(16'h0008); if (rdv[1:0] !== 2'b00) begin errors = errors + 1; $display("FAIL: B status %h on a dead line", rdv); end
        ab_cut <= 0;
        repeat (12000) @(posedge clk_a);
        brd(16'h0008); if (rdv[1:0] !== 2'b11) begin errors = errors + 1; $display("FAIL: B status %h after the line came back", rdv); end
        brd(16'h0030); if (rdv !== 2) begin errors = errors + 1; $display("FAIL: link-up count %0d, expected 2", rdv); end
        brd(16'h002C); if (rdv !== 1) begin errors = errors + 1; $display("FAIL: lock losses %0d", rdv); end
        if (got_fill - fill_before < 300) begin errors = errors + 1; $display("FAIL: only %0d filled after the dead line", got_fill - fill_before); end
        $display("  dead line: %0d samples zero-filled, stream continues", got_fill - fill_before);
        run = 0; repeat (3000) @(posedge clk_a);

        // --- totals: every sample A queued is either at B or was zero-filled (A's count leaves out the 40
        // fill samples of the source gap)
        ard(16'h0034); i = rdv;
        brd(16'h0038);
        if (rdv !== got) begin errors = errors + 1; $display("FAIL: B's sample counter %0d, bench %0d", rdv, got); end
        if (i != sent - 40) begin errors = errors + 1; $display("FAIL: A queued %0d of %0d", i, sent - 40); end
        if (got + got_fill != sent) begin errors = errors + 1; $display("FAIL: B has %0d + %0d fill, A sent %0d", got, got_fill, sent); end
        ard(16'h0058); if (rdv !== 0) begin errors = errors + 1; $display("FAIL: A's FIFO overflowed %0d times", rdv); end
        brd(16'h005C); if (rdv !== 0) begin errors = errors + 1; $display("FAIL: B dropped %0d frames for room", rdv); end
        brd(16'h0060); brd(16'h0064); if (rdv !== 32'h0012) begin errors = errors + 1; $display("FAIL: index high %h", rdv); end

        // --- control words: 5 from A to B, 3 back, each in a 16-deep FIFO and read one by one; the status bit 6
        // shows a word is waiting
        for (i = 0; i < 5; i = i + 1) awr(16'h0010, 32'hC0DE_0000 + i * 32'h0101_0011);
        for (i = 0; i < 3; i = i + 1) bwr(16'h0010, 32'hBEEF_1000 + i);
        repeat (400) @(posedge clk_a);
        for (i = 0; i < 5; i = i + 1) begin
            brd(16'h0008); if (!rdv[6]) begin errors = errors + 1; $display("FAIL: B has no control word %0d", i); end
            brd(16'h0014);
            if (rdv !== 32'hC0DE_0000 + i * 32'h0101_0011) begin errors = errors + 1; $display("FAIL: control word %0d = %h", i, rdv); end
            repeat (12) @(posedge clk_b);
        end
        brd(16'h0008); if (rdv[6]) begin errors = errors + 1; $display("FAIL: a sixth control word at B"); end
        for (i = 0; i < 3; i = i + 1) begin
            ard(16'h0014);
            if (rdv !== 32'hBEEF_1000 + i) begin errors = errors + 1; $display("FAIL: control word back %0d = %h", i, rdv); end
            repeat (12) @(posedge clk_a);
        end
        brd(16'h0040); if (rdv !== 32'h0000_0005) begin errors = errors + 1; $display("FAIL: B's control counters %h", rdv); end
        if (a_irqs < 4 || b_irqs < 6) begin errors = errors + 1; $display("FAIL: interrupts A %0d B %0d", a_irqs, b_irqs); end

        if (errors == 0) $display("PASS: tb_blink (%0d samples bit-exact at their index, %0d zero-filled)", got, got_fill);
        else $display("FAILED: %0d errors", errors);
        $finish;
    end
    // Watchdog: 600 ms of simulated time.
    initial begin #600_000_000; $display("FAIL: timeout"); $finish; end
endmodule
