// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Macros Gowin's Customized PHY source reads (docs/SFP_LINKS.md 2.4), for quad 1 lane 0 (1.25 Gbit/s, 10-bit
// words) and lane 1 (2.5 Gbit/s, 20-bit words), both without 8b/10b and word alignment, reference input 1 at
// 125 MHz, lane PLLs. Names and value forms as the IDE writes them (Sipeed example sfp+/customized_phy/1.25G,
// commit d3cebf1, Apache-2.0: its define.vh and param.v for two raw lanes); the settings that reach the hard
// block are in serdes.toml. Used by gowin/p1/build.sh.
`define Q1_LN0
`define Q1_LN0_PMA_WIDTH 10
`define Q1_LN0_TX_GEARBOX 1
`define Q1_LN0_RX_GEARBOX 1
`define Q1_LN0_CHANNEL_BONDING_MASTER_SEL 0
`define Q1_LN0_TX_IF_MST_SEL 0
`define Q1_LN1
`define Q1_LN1_PMA_WIDTH 20
`define Q1_LN1_TX_GEARBOX 1
`define Q1_LN1_RX_GEARBOX 1
`define Q1_LN1_CHANNEL_BONDING_MASTER_SEL 0
`define Q1_LN1_TX_IF_MST_SEL 0
`define MODULE_NAME Customized_PHY_Top
