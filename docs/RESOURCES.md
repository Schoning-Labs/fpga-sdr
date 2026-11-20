<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# Chip resource ledger: see ARCHITECTURE.md section 3.14

The authoritative, block-by-block DSP/BSRAM/logic accounting for the GW5AST-138 lives in
[ARCHITECTURE.md](ARCHITECTURE.md) section 3.14, not here. This file is a pointer and a one-paragraph
summary, kept short on purpose so it does not drift out of sync with the real table.

## In short (2026-09-26, after the rebalance work)

- Chip: 298 DSP blocks, **340 BSRAM primitives of 18 kbit** (not 36 kbit; [BOARD.md](BOARD.md)), 138,240 LUT4.
- Every block with RTL was re-measured with `tools/yosys_res.sh` (yosys gw5a synthesis with multipliers
  counted as DSP blocks, logic = LUT + ALU + LUT RAM), and every planned block was derived from its own
  specification, including blocks the first ledger missed (zoom averaging stage, IQ writer, HL2 TX sample
  FIFO, DDR3 controller). **As the design stands today it does not fit**: 261 DSP (88 %), 353 BSRAM (104 %),
  over 244,000 logic (177 %), mostly from RTL structure (delay lines in flip-flops, a combinational
  divider, memories that cannot map to BSRAM, one CORDIC per mixer), not from missing capability.
- **Rebalanced** (changes C1-C14 in 3.14, work packages at the end of [PLAN.md](PLAN.md)): **164 DSP (55 %),
  226 BSRAM (66.5 %), about 104,300 logic (75 %; 71 % without yosys's LUT1 buffers)**. Every capability the
  owner asked for is kept.
- Logic is the binding resource and sits just above the 70 % target, with 40 % of it still estimates. One
  owner decision is open (3.14, last part): accept up to about 75 % until Gowin's own synthesis measures it
  (recommended), or trim now from a ranked list.
