// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Parameters Gowin's Customized PHY source reads (docs/SFP_LINKS.md 2.4), for quad 1 lane 0 (1.25 Gbit/s, 10-bit
// words) and lane 1 (2.5 Gbit/s, 20-bit words), both without 8b/10b and word alignment, reference input 1 at
// 125 MHz, lane PLLs. Names and value forms as the IDE writes them (Sipeed example sfp+/customized_phy/1.25G,
// commit d3cebf1, Apache-2.0: its define.vh and param.v for two raw lanes); the settings that reach the hard
// block are in serdes.toml. Used by gowin/p1/build.sh.
parameter q1_ln0_tx_rate = 1.25;
parameter q1_ln0_rx_rate = 1.25;
parameter q1_ln0_refclk_source = 3;
parameter q1_ln0_pll_sel = 2;
parameter q1_ln0_loopback_mode = "off";
parameter q1_ln0_pma_width = 10;
parameter q1_ln0_tx_gearbox = 1;
parameter q1_ln0_rx_gearbox = 1;
parameter q1_ln0_8b10b_encode = 0;
parameter q1_ln0_8b10b_decode = 0;
parameter q1_ln0_word_align = 0;
parameter q1_ln0_rx_bonding_clk_src_sel = "lane_rx_clk";
parameter q1_ln0_channel_bonding = 0;
parameter q1_ln0_channel_bounding_master_sel = 0;
parameter q1_ln0_channel_bonding_align_pattern = 8'h7C;
parameter q1_ln0_2nd_channel_bonding_align_pattern = 8'h7C;
parameter q1_ln0_2nd_channel_bonding_align_pattern_is_k = 0;
parameter q1_ln0_3rd_channel_bonding_align_pattern = 8'h7C;
parameter q1_ln0_3nd_channel_bonding_align_pattern_is_k = 0;
parameter q1_ln0_4th_channel_bonding_align_pattern = 8'h7C;
parameter q1_ln0_4nd_channel_bonding_align_pattern_is_k = 0;
parameter q1_ln0_channel_bonding_max_skew = 8;
parameter q1_ln0_rx_bonding_rd_start_depth = 16;
parameter q1_ln0_tx_if_mst_sel = 0;
parameter q1_ln0_tx_if_rd_start_depth = 16;
parameter q1_ln0_ctc_clk_src_sel = "fabric_clk";
parameter q1_ln0_ctc_2nd_pattern_is_k = 0;
parameter q1_ln0_ctc = 0;
parameter q1_ln0_two_words_ctc = 0;
parameter q1_ln0_ctc_pattern = 8'h7C;
parameter q1_ln0_ctc_2nd_pattern = 8'h7C;
parameter q1_ln0_ctc_rd_start_depth = 16;
parameter q1_ln1_tx_rate = 2.5;
parameter q1_ln1_rx_rate = 2.5;
parameter q1_ln1_refclk_source = 3;
parameter q1_ln1_pll_sel = 2;
parameter q1_ln1_loopback_mode = "off";
parameter q1_ln1_pma_width = 20;
parameter q1_ln1_tx_gearbox = 1;
parameter q1_ln1_rx_gearbox = 1;
parameter q1_ln1_8b10b_encode = 0;
parameter q1_ln1_8b10b_decode = 0;
parameter q1_ln1_word_align = 0;
parameter q1_ln1_rx_bonding_clk_src_sel = "lane_rx_clk";
parameter q1_ln1_channel_bonding = 0;
parameter q1_ln1_channel_bounding_master_sel = 0;
parameter q1_ln1_channel_bonding_align_pattern = 8'h7C;
parameter q1_ln1_2nd_channel_bonding_align_pattern = 8'h7C;
parameter q1_ln1_2nd_channel_bonding_align_pattern_is_k = 0;
parameter q1_ln1_3rd_channel_bonding_align_pattern = 8'h7C;
parameter q1_ln1_3nd_channel_bonding_align_pattern_is_k = 0;
parameter q1_ln1_4th_channel_bonding_align_pattern = 8'h7C;
parameter q1_ln1_4nd_channel_bonding_align_pattern_is_k = 0;
parameter q1_ln1_channel_bonding_max_skew = 8;
parameter q1_ln1_rx_bonding_rd_start_depth = 16;
parameter q1_ln1_tx_if_mst_sel = 0;
parameter q1_ln1_tx_if_rd_start_depth = 16;
parameter q1_ln1_ctc_clk_src_sel = "fabric_clk";
parameter q1_ln1_ctc_2nd_pattern_is_k = 0;
parameter q1_ln1_ctc = 0;
parameter q1_ln1_two_words_ctc = 0;
parameter q1_ln1_ctc_pattern = 8'h7C;
parameter q1_ln1_ctc_2nd_pattern = 8'h7C;
parameter q1_ln1_ctc_rd_start_depth = 16;
parameter q1_refclk1_freq = 125;
