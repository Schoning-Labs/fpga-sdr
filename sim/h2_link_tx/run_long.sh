#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
#
# Runs the full-length version of tb_h2_link_tx.v: 50 ms of checked link time after the rate lock has had time to close
# the start-up fill deficit (about 20 ms in the worst case, see the header of rtl/hl2link/tx_rate_lock.v). The default
# run of the testbench uses a much shorter SIM_US with the same checks, so this one is the long soak, and it takes
# tens of CPU-minutes. Run it by hand from anywhere:
#   ./sim/h2_link_tx/run_long.sh            # 50 ms
#   ./sim/h2_link_tx/run_long.sh 5000       # another length, in microseconds
# It compiles the bench with -DSIM_US, runs it, prints the output and CPU time, deletes its temporary files, and exits
# non-zero unless the bench printed PASS. The bench writes its first transmit frame to sim/out/h2_tx_frame0.hex,
# so the folder sim/out has to exist.

set -euo pipefail
# The include paths inside the testbench are relative to the repo root.
cd "$(dirname "$0")/../.."   # repo root

us="${1:-50000}"
out="sim/h2_link_tx/build_long.vvp"
log="sim/h2_link_tx/build_long.log"

echo "building tb_h2_link_tx with SIM_US=$us ..."
iverilog -g2012 -DSIM_US="$us" -o "$out" sim/h2_link_tx/tb_h2_link_tx.v

echo "running (tens of CPU-minutes at the default 50 ms) ..."
if command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -Command "\$p = Start-Process -FilePath vvp -ArgumentList '$out' -NoNewWindow -PassThru -RedirectStandardOutput '$log'; \$null = \$p.Handle; \$p.WaitForExit(); Write-Output ('vvp CPU time {0:N1} s, wall time {1:N1} s' -f \$p.TotalProcessorTime.TotalSeconds, (\$p.ExitTime - \$p.StartTime).TotalSeconds)"
else
    { time vvp "$out" > "$log"; } 2>&1
fi
cat "$log"

status=0
grep -q "^PASS" "$log" || status=1
rm -f "$out" "$log"
exit $status
