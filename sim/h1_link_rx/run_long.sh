#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
#
# Runs the full-length version of tb_h1_link_rx.v: 20 ms of link time in test pattern mode, with every
# output sample checked against the expected pattern. The default run of the testbench streams only a few
# microseconds with the same checks, so this one is the long soak, and it takes a few CPU-minutes (see
# docs/H1_LINK_RX.md). Run it by hand from anywhere:
#   ./sim/h1_link_rx/run_long.sh            # 20 ms
#   ./sim/h1_link_rx/run_long.sh 5000       # another length, in microseconds
# It compiles the bench with -DSIM_US, runs it, prints the output and CPU time, deletes its temporary
# files, and exits non-zero unless the bench printed PASS.

set -euo pipefail
# The include paths inside the testbench are relative to the repo root.
cd "$(dirname "$0")/../.."   # repo root

us="${1:-20000}"
out="sim/h1_link_rx/build_long.vvp"
log="sim/h1_link_rx/build_long.log"

echo "building tb_h1_link_rx with SIM_US=$us ..."
iverilog -g2012 -DSIM_US="$us" -o "$out" sim/h1_link_rx/tb_h1_link_rx.v

echo "running ..."
if command -v powershell.exe >/dev/null 2>&1; then
    # Git Bash's `time` does not see the CPU time of a native Windows child process (it reports about 0 s of
    # user time for vvp), so Windows is asked for the process's own figure.
    powershell.exe -NoProfile -Command "\$p = Start-Process -FilePath vvp -ArgumentList '$out' -NoNewWindow -PassThru -RedirectStandardOutput '$log'; \$null = \$p.Handle; \$p.WaitForExit(); Write-Output ('vvp CPU time {0:N1} s, wall time {1:N1} s' -f \$p.TotalProcessorTime.TotalSeconds, (\$p.ExitTime - \$p.StartTime).TotalSeconds)"
else
    { time vvp "$out" > "$log"; } 2>&1
fi
cat "$log"

status=0
grep -q "^PASS" "$log" || status=1
rm -f "$out" "$log"
exit $status
