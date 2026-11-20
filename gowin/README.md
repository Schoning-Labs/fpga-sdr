<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# Gowin project and IP

Only `.ipc` IP configuration files and the regeneration script are committed here; Gowin-generated
output is encrypted and git-ignored (see `docs/ARCHITECTURE.md` section 7 and `docs/DECISIONS.md`).

`p1/`: the full-chip project. `gowin/p1/build.sh` regenerates the AE350 IP from
`p1/ip/riscv_ae350_soc.ipc` and the PLLs from `p1/ip/*.mod`, then builds `rtl/top/sdr_top.v` with
`p1/sdr.cst` and `p1/sdr.sdc`.
