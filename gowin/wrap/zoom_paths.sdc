# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
# appended to the clock constraint of a stand-alone zoom run: 300 paths in the timing report, not 25
report_timing -setup -max_paths 300 -max_common_paths 1 -from_clock [get_clocks {clk}] -to_clock [get_clocks {clk}]
