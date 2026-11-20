<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# Minimal HL2 test on the board (2026-10-21)

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

**Build:** hl2sfp commit 14fd2d1, `HL2MIN_LANE=1 gowin/hl2min/build.sh` (Gowin V1.9.12.04, 104 s; 2 setup end points 0.07 ns short on `sfp_txc`, the
control link, the receive clock `n1_rxc` 132 MHz for 125). No processor, no DDR3. Loaded into SRAM with the board loader tool `board.py load --no-program`, which is not part of this repository
(board lock held, no flash write, no cable reset); module in cage SFP1 (lane 1, 1.25 Gbit/s 1000BASE-X), HL2 with the test-pattern firmware on the other end.
Raw UART lines: `gowin/reports/hl2min_lane1_board/`.

**Result (first board run of the SFP link and of the HL2 against the Tang):**
- Link up 3 s after load (PCS status 0x5f); frames from t = 6 s; 79,340 frames a second, 120.4 Mbyte/s (963 Mbit/s with headers), steady.
- 0 bad FCS, 0 length errors, 0 FIFO overflows, 0 hold-FIFO overflows for the whole run (414 s, 32.4 million frames).
- **One loss event: 68,692 packets at t = 21 s**, the moment the HL2 took its link-local address (169.254.19.221). In that second 10,648 frames arrived
  instead of 79,340 (10,648 + 68,692 = 79,340 exactly: a pause of 0.866 s). Afterwards 0 lost for 393 s (about 31 million frames).
- Cause NOT established: the Tang's counters show no error of its own, and the HL2 announced the address change in that second, so an HL2-side pause is the likely cause
  (the HL2's sequence counter kept running). Not proven. A second run without an address change (the HL2 keeps its address) would show whether the pause repeats.
- The owner's requirement (100 % of the raw data): met for the 393 s after the address was assigned; the start-up pause is open.
