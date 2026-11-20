// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
// Taken over unchanged from an earlier design by the same author, for fpga-sdr; gowin/p1/build.sh puts it on the include path of the IP's source.
// fpga-sdr never defines DDR_512MB.
// The 300 MHz values (2026-10-19/20, owner): tCK 3333, CL 5 and the PLL settings (VCO 1,200 MHz, MDIV 24, memory clock ODIV 4)
// were measured on this board; docs/DECISIONS.md 2026-10-20.
// Settings of Gowin's DDR3 Memory Interface IP (IPUG281-2.6E chapter 7) for the board's
// two SK Hynix H5TQ4G63EFR-RDC (4 Gbit, 16 data lines each: 15 row, 10 column, 3 bank address lines): 32 data
// lines, 1 GB. The values are the ones Sipeed made for this board with the IP's generator (TangMega-138KPro-example,
// ae350_customized_demo and ddr_test/Hynix_400MHz, the same file in both): memory clock 400 MHz (tCK 2,500 ps),
// clock ratio 1:4, burst of 8, tRFC 260 ns, tRCD and tRP 15 ns, tRRD 10 ns, tCKE 10 ns, CL 6, CWL 5, RTT_NOM 60 ohm.
// tools/gowin_build.sh and tools/lad_build.sh put this file on the include path of the IP's source.
parameter DRAM_TYPE = "DDR3";
parameter nCK_PER_CLK = 4;
// 2026-10-19 (owner): memory clock 300 MHz, not Sipeed's 400 MHz (freeze fix: at 400 MHz reads with two or more in flight were lost or corrupted when much logic switched):
// tCK 3,333 ps, CL 5, CWL 5, ratio 1:4 (controller clock 75 MHz).
parameter tCK = 3333;
parameter REG_CTRL = "OFF";
// `DDR_512MB = 16 data lines, one chip, 512 MB (IPUG281-2.6E 7.1 "Dq Width": the total
// width; "Dram Width": one chip's, 16 either way). The define comes from the variant header (or lad_cfg.vh).
`ifdef DDR_512MB
parameter DQ_WIDTH = 16;
`else
parameter DQ_WIDTH = 32;
`endif
parameter DRAM_WIDTH = 16;
parameter ECC = "OFF";
parameter RANK_WIDTH = 1;
parameter BANK_WIDTH = 3;
parameter ROW_WIDTH = 15;
parameter COL_WIDTH = 10;
parameter tRP = 15000;
parameter tRRD = 10000;
parameter tRTP = 7500;
parameter tRCD = 15000;
parameter tRC = 55000;
parameter tRAS = 37500;
parameter tFAW = 40000;
parameter tWTR = 7500;
parameter tCKE = 10000;
parameter tREFI = 7800000;
parameter tRFC = 260000;
parameter tDLLK = 512;
parameter BURST_MODE = "8";
parameter BURST_TYPE = "SEQ";
parameter CL = 5;
parameter CWL = 5;
parameter AL = "0";
parameter SLOT_0_CONFIG = 8'b00000001;
parameter SLOT_1_CONFIG = 8'b00000000;
parameter RTT_NOM = "60";
parameter RTT_WR = "OFF";
parameter USER_REFRESH = "OFF";
parameter ADDR_CMD_MODE = "1T";
parameter OUTPUT_DRV = "LOW";
