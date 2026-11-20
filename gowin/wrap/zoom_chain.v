// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// zoom_chain: the zoom receiver, the spectrum pipeline it feeds and the zoom waterfall writer wired together as they
// sit in the chip (docs/ZOOM_IN_CHIP.md section 5), so that the whole chain can be measured alone for size and speed.
// It is not part of the radio itself; rtl/top/sdr_core.v makes the same connections.
//
// WHAT IS IN IT
//   zoom_frontend       (rtl/zoom/zoom_frontend.v) the zoom receiver: its register page 0x06, the downconverter that
//                       narrows the band around a chosen frequency and the window; its 4,096-bin spectrum goes on to the pipeline
//   spectrum_pipeline   (rtl/spectrum/spectrum_pipeline.v) the full-band spectrum and the zoom context, one walk engine
//                       that turns FFT bins into display lines
//   waterfall_writer    the zoom waterfall's writer into DDR3 (rtl/video/waterfall_writer.v), 1,920-byte lines in a
//                       ring of 2,048 lines
// The register bus is the one the core gives: a 16-bit address and 32-bit data word shared by all pages, and one pair of
// read and write strobes per page (wr5 and rd5 for the spectrum page, wr6 and rd6 for the zoom page).
//
// The wrapper around it, which puts the block on shift chains so that it fits into the chip's pins, is
// gowin/wrap/zoom_chain_ooc_wrap.v, written by gowin/gen_wrap.py from this port list. Measured with (from the
// repository root, see gowin/res.sh):
//   gowin/res.sh zoom_chain_ooc_wrap --period-ns 7.92 --opt "place_option 3" --opt "route_option 1" \
//       rtl/rx/nco_mixer.v rtl/rx/cic_var_shared.v rtl/rx/fir_decim.v rtl/rx/fir_delay_ram2.v rtl/rx/rx_channel.v \
//       rtl/zoom/cic_var_pow2.v rtl/zoom/zoom_fir_half.v rtl/zoom/zoom_cic_comp.v rtl/zoom/zoom_ddc.v \
//       rtl/zoom/zoom_window.v rtl/zoom/zoom_spectrum.v rtl/zoom/zoom_frontend.v \
//       rtl/spectrum/spectrum_pipeline.v rtl/video/waterfall_writer.v \
//       gowin/wrap/zoom_chain.v gowin/wrap/zoom_chain_ooc_wrap.v

`timescale 1ns / 1ps

module zoom_chain (
    input  wire               clk,  // clk_dsp, 120 MHz
    input  wire               rst,  // synchronous reset, high = reset
    input  wire signed [11:0] adc_data,  // the HL2 sample stream, 12-bit signed (the receiver bank's input)
    input  wire               adc_valid,  // one-clock pulse: adc_data holds a new sample
    // register bus as the core gives it: one address and data word, a strobe pair per page
    input  wire [15:0]        off,  // register address within the page, 16 bits
    input  wire [31:0]        wd,  // register write data, 32 bits
    input  wire               wr5,  // write strobe of the spectrum page
    input  wire               rd5,  // read strobe of the spectrum page
    input  wire               wr6,  // write strobe of the zoom page
    input  wire               rd6,  // read strobe of the zoom page
    output reg  [31:0]        rd_spec,  // read data of the spectrum page, registered as the core's read multiplexer does
    output reg  [31:0]        rd_zoom,  // read data of the zoom page, registered the same way
    output wire               spec_irq,  // spectrum line done interrupt
    output wire               zspec_irq,  // zoom spectrum line done interrupt
    // line buffers (read by the compositor)
    input  wire [10:0]        line_rd_addr,  // read address into the full-band line buffer, 11 bits
    output wire [15:0]        line_rd_data,  // line data, 16 bits
    input  wire [10:0]        zline_rd_addr,  // read address into the zoom line buffer, 11 bits
    output wire [15:0]        zline_rd_data,  // zoom line data, 16 bits
    // full-band waterfall bytes (its writer is not part of this measurement)
    output wire               wf_valid,  // a waterfall byte is present
    output wire [7:0]         wf_data,  // the waterfall byte, 8 bits
    // zoom waterfall writer (its request/grant/done handshake is that of a client of ddr3_write_arbiter)
    input  wire [31:0]        zwf_ring_base,  // base address of the zoom waterfall ring in DDR3
    output wire [10:0]        zwf_write_line,  // number of the line the writer is on in the ring, 11 bits (2,048 lines)
    output wire               zww_req,  // the writer wants to write a burst
    output wire [31:0]        zww_addr,  // address of the burst, 64-bit words
    output wire [63:0]        zww_wdata,  // data of the current beat, 64 bits
    input  wire               zww_gnt,  // the arbiter took a beat
    input  wire               zww_done  // the burst has landed
);
    // Wires between the three blocks: the zoom bins (valid, first-bin flag, 12-bit bin number, usable flag, 29-bit signed
    // real and imaginary parts) from the zoom receiver to the spectrum pipeline, the two register read data of the zoom
    // page that are OR-ed together, and the waterfall byte stream (valid, start and end of line, data) to the writer.
    wire        zb_valid, zb_first, zb_usable;
    wire [11:0] zb_bin;
    wire signed [28:0] zb_re, zb_im;
    wire [31:0] rd_zoom_fe, rd_zoom_be, rd_spec_w;
    wire        zwf_valid, zwf_sol, zwf_eol, wf_sol, wf_eol;
    wire [7:0]  zwf_data, zww_burst, zww_wmask;

    // The zoom receiver on page 0x06.
    zoom_frontend u_zoom (
        .clk(clk), .rst(rst), .adc_data(adc_data), .adc_valid(adc_valid),
        .bus_wr(wr6), .bus_rd(rd6), .bus_addr(off), .bus_wdata(wd), .bus_rdata(rd_zoom_fe),
        .bin_valid(zb_valid), .bin_first(zb_first), .bin_index(zb_bin), .bin_usable(zb_usable),
        .bin_re(zb_re), .bin_im(zb_im)
    );

    // The spectrum pipeline: full-band registers on page 5's strobes, the zoom context on page 6's.
    spectrum_pipeline u_spectrum (
        .clk(clk), .rst(rst), .adc_data(adc_data), .adc_valid(adc_valid),
        .reg_wr(wr5), .reg_rd(rd5), .reg_addr(off), .reg_wdata(wd), .reg_rdata(rd_spec_w),
        .irq_line_done(spec_irq),
        .line_rd_addr(line_rd_addr), .line_rd_data(line_rd_data),
        .wf_valid(wf_valid), .wf_sol(wf_sol), .wf_eol(wf_eol), .wf_data(wf_data),
        .zoom_in_valid(zb_valid), .zoom_in_first(zb_first), .zoom_in_bin(zb_bin), .zoom_in_usable(zb_usable),
        .zoom_in_re(zb_re), .zoom_in_im(zb_im),
        .zreg_wr(wr6), .zreg_rd(rd6), .zreg_addr(off), .zreg_wdata(wd), .zreg_rdata(rd_zoom_be),
        .zirq_line_done(zspec_irq),
        .zline_rd_addr(zline_rd_addr), .zline_rd_data(zline_rd_data),
        .zwf_valid(zwf_valid), .zwf_sol(zwf_sol), .zwf_eol(zwf_eol), .zwf_data(zwf_data)
    );

    // The zoom waterfall writer: 1,920 bytes per line, 2,048 lines in the ring.
    waterfall_writer #(.LINE_BYTES(1920), .RING_LINES(2048)) u_zwf_writer (
        .clk(clk), .rst(rst),
        .in_valid(zwf_valid), .in_data(zwf_data), .in_ready(),
        .ring_base(zwf_ring_base), .write_line_ptr(zwf_write_line),
        .req(zww_req), .addr(zww_addr), .burstlen(zww_burst), .wdata(zww_wdata), .wmask(zww_wmask),
        .gnt(zww_gnt), .done(zww_done)
    );

    // The core's read multiplexer registers each page's word; the zoom page is the OR of the receiver's and the
    // pipeline's zoom registers, because each answers only for its own addresses.
    always @(posedge clk) begin
        rd_spec <= rd_spec_w;
        rd_zoom <= rd_zoom_fe | rd_zoom_be;
    end
endmodule
