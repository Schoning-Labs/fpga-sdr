<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# Contributing

Questions, corrections and improvements are welcome, but keep in mind that this is a one-person project built around one specific board, so replies can take a while and not every change will fit. If you plan something bigger than a fix, open an issue first and describe what you want to do, because that saves you writing code I cannot merge.

## What helps most

- Mistakes in the documents or the comments. This repository is meant for learning, so a sentence that confused you is a bug, and so is a number that does not match the code.
- Results from your own board, good or bad, for example a different Gowin version, a different SFP module or a different monitor.
- Fixes with a testbench or a host test that fails before the fix and passes after it.

## Before you open a pull request

1. Run the simulation or the host test of the block you changed (`sim/<block>/run.sh`, or `cargo test -p <crate>` from `fw/`) and say which one you ran. A full chip build takes about an hour, so only run it if your change touches the top level, the constraints or the clocks.
2. Keep the style of the file you are editing. Every Verilog file is commented for a beginner, and a change should leave it that way.
3. New files start with the header `SPDX-License-Identifier: Apache-2.0` and a copyright line with your name. Code you take from another project keeps its own header and license, and has to sit in a folder of its own, as the third-party parts do now (see [docs/learn/LICENSES.md](docs/learn/LICENSES.md)).
4. Do not add bitstreams, firmware images, vendor PDFs or anything that came out of Gowin's IP generator. The release list in `docs/learn/LICENSES.md` says why.

By sending a pull request you agree that your contribution is licensed under the Apache License 2.0, the same as the rest of the project (except where it goes into one of the third-party folders, where it takes that folder's license).

## Transmit

Transmit is built but has never been tested end to end, so the firmware keeps the last step locked on purpose. If you test it on a dummy load, please report what you saw in an issue. A change that unlocks it by default will not be merged until somebody who holds the license to transmit has proven the whole path, and the unlock has to stay an explicit choice of the operator.
