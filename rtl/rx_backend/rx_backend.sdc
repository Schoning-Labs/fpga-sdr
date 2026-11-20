// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Timing exceptions for rtl/rx_backend/rx_backend.v (Gowin SDC, SUG940), to be added to the
// project's constraints next to the clk_dsp clock (gowin/res.sh --sdc does this for the
// measurement). Every path that starts at a register named rbmc_* (the register bus's latched
// write address and data, latched read address and read fields) is a two-clock path: the RTL
// only loads those registers on an access, holds them for at least two clocks (bus contract:
// two writes, or two reads, at least two clocks apart), and only captures their results on the
// clock two clocks after they were loaded, through an enable that is itself a one-clock path.
// See rx_backend.v "register bus" for the rules the RTL keeps. The pattern needs no hierarchy
// prefix ("*" matches across hierarchy levels), so it holds wherever rx_backend is instantiated;
// nothing else in the design may name a register rbmc_*.
//
// WP LS5: written as a largest delay of two clocks, not as set_multicycle_path. Gowin V1.9.11.03 does not
// apply set_multicycle_path to a path whose clock is a create_generated_clock (a PLL output): the timing
// report lists the constraint as active and then "No timing paths to report" for it, and the paths are
// timed against one clock. Seen in the full-chip build of 0c735b5 (rbmc_wa2 -> coefficient memories,
// -1.33 ns at a 6.667 ns relation) and reproduced on a 30-line design: with the clock on a pin the lines
// work, with the same clock out of a PLL they do not; set_max_delay works in both. The stand-alone runs
// (gowin/res.sh, clock on a pin) never showed it. 16.3 ns = two clocks of 120 MHz less 0.37 ns (was 13.0 ns at 150 MHz); the hold
// check stays the ordinary one (same edge), which is what "-hold -start 1" asked for.
set_max_delay -from [get_regs {*rbmc_*}] 16.3
