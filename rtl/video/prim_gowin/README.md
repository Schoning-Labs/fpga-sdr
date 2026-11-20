<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# Gowin serializer primitive (hardware build only)

`OSER10` (and `ELVDS_OBUF` for the differential/emulated-differential TMDS pads, BOARD.md "HDMI
/ DVI output": the port pins are plain `LVCMOS33D` emulated-differential, not a dedicated SerDes
I/O bank) are Gowin standard-cell primitives that come from the Gowin EDA install itself
(`C:/Gowin/.../IDE/simlib` for the simulation stub actually used by their own tools, and the
place-and-route flow resolves `OSER10`/`ELVDS_OBUF` by name against the device library — nothing
needs to be vendored here for a Gowin build to find them).

Nothing to check in until a Gowin build is attempted (PLAN.md WP T1 / this package's outstanding
item: Gowin place-and-route needs a Standard-edition licence, not available yet — see
docs/V1_VIDEO.md). When that happens, the constraints file (pin assignment, `IO_TYPE=LVCMOS33D`
per BOARD.md) and any `ELVDS_OBUF` output buffer wrapping belong in this directory, built with
`` `GW_IDE`` defined so `rtl/vendor/hdmi/serializer.sv` selects its Gowin `OSER10` path (see that
file) instead of the simulation model in `rtl/video/prim_sim/OSER10.v`.
