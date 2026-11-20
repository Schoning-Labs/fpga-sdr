// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// The H1 link testbench (tb_h1_link_rx.v, same stimulus, same checks, same default length) with the sample CDC
// FIFO inside the DUT cut from 1,024 to 256 words, which is what the `define below does through the DUT's
// SAMP_AW parameter. At the real size the FIFO never fills in that test: the 968 sample zero fill that replaces the
// corrupted frame takes 6.5 us of the 150 MHz DSP clock, during which the drain pushes at most about 800
// samples. So the backpressure path, where raw_frame_buffer.v parks a fetched sample while the FIFO is full
// and cdc_sample_fifo.v raises its full flag, would otherwise never run. At 256 words the FIFO stays full for
// several hundred receive clocks during the fill. A combinational loop in the full flag would hang this run,
// and a sample lost on every stall would break its pattern and sample count checks.
//
// Pass criteria and printout are those of tb_h1_link_rx.v ("PASS" on success). Run it from the repo root:
//   iverilog -g2012 -o build/tb_h1_link_rx_bp.vvp sim/h1_link_rx/tb_h1_link_rx_backpressure.v && vvp build/tb_h1_link_rx_bp.vvp

`define TB_SAMP_AW 8
`include "sim/h1_link_rx/tb_h1_link_rx.v"
