# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
report_timing -setup -max_paths 300 -max_common_paths 1 -from_clock [get_clocks {clk}] -to_clock [get_clocks {clk}]
