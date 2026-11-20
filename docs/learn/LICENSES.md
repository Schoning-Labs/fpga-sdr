<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# Licenses in fpga-sdr

fpga-sdr is released under the Apache License 2.0 for everything Franz Schöning wrote, and that part is simple. The
harder part is that a working radio is built from more than the author's own code: a GUI toolkit fetched by Cargo, an
FT8 decoder that is a port of WSJT-X, Rust translations of Codec 2 and FreeDV, a few Hermes-Lite 2 and HPSDR Verilog
files used by simulations, an HDMI encoder, and Gowin's encrypted IP that the build reads from the Gowin install. Each
of these comes with its own license, and each license says something different about two separate things, which are
worth keeping apart while reading this page:

1. **The source repository.** Can the file sit in an Apache-2.0 repository at all, and if so, in its own folder with
   its own license file, or only as something a script fetches?
2. **The built images.** The firmware (`ft8fw`, the Rust program on the AE350) and the bitstream (the `.fs` file loaded
   into the FPGA) are each one combined work made from many sources. The license of a built image is decided by the
   strictest license among its parts.

This repository publishes source only. It contains no bitstream and no firmware image, and anyone who wants to run the
radio builds both from the source with their own Gowin license (the README says how). The firmware you build is a
GPL-3.0 work as a whole, for the reasons in sections 1 and 2, and the bitstream you build contains Gowin's encrypted IP,
which is why none is handed out (section 9).

Apache-2.0 code can be combined into a GPL-3.0 work (the Free Software Foundation lists Apache-2.0 as compatible with
GPL-3.0, though not with GPL-2.0-only), so keeping our source under Apache-2.0 is never in the way of a GPL-3.0 image.
The reverse is not true: GPL code cannot become Apache-2.0 by being placed in an Apache repository, which is why the
GPL files named in section 11 stay as they are.

What follows was read from the actual license texts: the three Slint licenses shipped in the Slint 1.18.1 crate
(`LICENSES/`), mfsk-core's `LICENSE` and `Cargo.toml`, `COPYING.LGPL-2.1` and `NOTICE` in the two FreeDV crates, the
license files in `rtl/vendor/hdmi`, the headers of the Hermes-Lite and HPSDR files, `cargo metadata` and `cargo tree`
for the dependency licenses (offline, from `fw/Cargo.lock`), and the Gowin install. Gowin's IP license agreement (linked
from gowinsemi.com/en/support/ip) was not part of this reading, because no Gowin IP is distributed with this repository
or with any image made from it.

This page is an engineer's reading of the licenses, not legal advice.

## 1. Slint (GUI toolkit, `slint` 1.18.1 and its `i-slint-*` crates)

**License:** `GPL-3.0-only OR LicenseRef-Slint-Royalty-free-2.0 OR LicenseRef-Slint-Software-3.0`, i.e. the user picks
one of three.

- The **Royalty-free Desktop, Mobile, and Web Applications License 2.0** is the free non-GPL option, but its section 3
  says plainly that it "does not permit the use of the Software within Embedded Systems", and it defines an embedded
  system as a computer system that does one specific task inside a larger electrical system. A bare-metal radio on an
  FPGA board is exactly that, so this license is out for fpga-sdr.
- The **Slint Software License 3.0** does cover embedded systems, but only with a paid license plan (seats for every
  developer). Its section 2(b) waives the per-device royalties for "non-commercial projects, personal projects, and open
  source projects", but the paid plan for the seats is still needed. So it is not free for us either.
- That leaves **GPL-3.0-only**. Note that it is "only", not "or later".

**In the repository:** Slint itself is not in git; Cargo fetches it from crates.io. Our own code that uses it
(`fw/tr-gui`, its `.slint` files and the calls in `tr-app`) is Apache-2.0, because writing code against a library's API
does not make that code GPL. Nothing is added to the repository for Slint.

**Built firmware:** contains Slint, so the firmware image as a whole is a GPL-3.0 work and, because of the "only",
GPL-3.0 exactly. Anyone who gives a built firmware image to someone else must give the complete corresponding source
with it or offer it (GPL-3.0 section 6), which for fpga-sdr is the repository at the same commit plus `Cargo.lock`
and the crates it names. The Slint attribution widget (`AboutSlint`) is a condition of the royalty-free license only,
not of the GPL, so it is not required, though showing it is a friendly thing to do.

Buying Slint's paid plan would not give a non-GPL firmware, because mfsk-core (section 2) would still make the image
GPL-3.0.

## 2. mfsk-core (FT8, FT4 and WSPR decoder) and the WSJT-X algorithms

**License:** GPL-3.0-or-later, by Naoki Sakurai (JL1NIE) and contributors. mfsk-core is a Rust implementation of the
WSJT-X decoders by Joe Taylor K1JT and the WSJT team, which are GPL-3.0 as well.

**In the repository:** `fw/vendor/mfsk-core` is a patched copy of version 0.11.0 with its `LICENSE` (full GPL-3.0
text). It sits in the Apache-2.0 repository as a separate folder under its own license. The GPL asks for two things
here, and both are met: the modified files carry a notice that they were changed and when (section 5a), which
`fw/vendor/VENDOR_PATCH.md` and the header in its `Cargo.toml` do, and the license notices stay intact. The NOTICE file
says once that this folder is GPL-3.0 and not Apache-2.0, so nobody copies from it thinking otherwise. Fetching
mfsk-core from crates.io instead of vendoring it is not possible, because the firmware needs the nine changes listed in
`VENDOR_PATCH.md`.

**The algorithms:** copyright protects the code and does not extend to the method behind it. Writing new code that follows the same steps as
WSJT-X (a Costas correlation, a coarse sync, an LDPC decoder) is not a derivative work. The FT8 front end in `rtl/ft8`
and most of `fw/tr-modes/src/frontend` (the spectrogram, the Costas sync model in `sync.rs`, the subtraction in
`subtract.rs`, the baseband and the schedulers) is Apache-2.0 on that basis.

**Three files that follow WSJT-X routines closely** keep a GPL-3.0-or-later header, with the original attribution and a
"modified 2026 by Franz Schöning" note, because their code follows routines of WSJT-X as mfsk-core translates them
closely enough that the header of the upstream license is the safe one:

- `fw/tr-modes/src/frontend/candidates.rs` follows the tail of WSJT-X's `sync8` (candidate selection) through
  mfsk-core's `coarse_sync`, modified to take the output of the FPGA sync engine.
- `fw/tr-modes/src/frontend/decode.rs` follows the fine-sync power of WSJT-X's `sync8d` as mfsk-core translates it.
- `fw/tr-modes/src/txbb.rs` follows the FT8 transmit waveform of WSJT-X (`gen_ft8wave` and `gfsk_pulse`), rewritten as a
  streaming complex baseband at 48 ksps.

They stay GPL-3.0-or-later until the author confirms that they were written from the algorithm and not translated
(see "Open points").

**Built firmware:** contains mfsk-core and these three files, so it is GPL-3.0, the same result as section 1.

## 3. Codec 2 and FreeDV, the Rust ports (`fw/tr-codec2`, `fw/tr-freedv`)

**License:** LGPL-2.1, by David Rowe and contributors (with LDPC code by Matthew C. Valenti and others, and LDPC codes by
Bill Cowley VK5DSP).

**What a Rust port obliges:** a translation from C to Rust is a "work based on the Library" in the LGPL's own words, the
same as a modified copy, so the translated source stays LGPL-2.1. The two crates do everything the license asks of a
modified library: they carry `SPDX-License-Identifier: LGPL-2.1-only`, the original copyright lines, a "modified 2026 by
Franz Schöning" note saying what changed (section 2a and 2c), and the full license text in `COPYING.LGPL-2.1`. They sit
in their own folders, so they stay in the Apache-2.0 repository as they are.

**Built firmware:** the firmware links the crates statically. The LGPL normally asks that a user can relink the
program with a changed library (section 6), which is awkward for a bare-metal image. Section 3 of the LGPL-2.1 gives a
simpler way: any copy of the library may be used under the ordinary GPL version 2 or later instead. The crates'
`NOTICE` files say that the copy inside the firmware is used under GPL-3.0-or-later on that basis. Since the firmware is
GPL-3.0 anyway (sections 1 and 2), this costs nothing, and the source stays LGPL so it can go back to the Codec 2
project.

The test vectors in `tests/vectors/` are outputs of the C reference programs run on Codec 2's own speech files; they
are part of the LGPL crates and stay there.

## 4. hdl-util HDMI (`rtl/vendor/hdmi`)

**License:** MIT OR Apache-2.0, by Sameer Puri and contributors, both license texts in the folder. We take it under
Apache-2.0, which matches the repository. Three files carry "modified 2026" notes.

**In the repository:** both licenses ask that the copyright notice stays with the code, and under Apache-2.0 the
modified files must say they were changed (section 4b), which their notes do.

**Built bitstream:** permissive; only the notice (in NOTICE) is needed.

## 5. Hermes-Lite 2 and HPSDR gateware

**License:** GPL-2.0-or-later for the HPSDR, Metis and Hermes code by Alex Shovkoplyas VE3NEA, Phil Harman VK6APH, Steve
Haynal KF7O, James Ahlstrom and others.

**How the repository references Hermes-Lite 2:** the HL2 side of the link lives in the author's public fork,
github.com/Schoning-Labs/Hermes-Lite2, branch `hl2-rawfront-release`. fpga-sdr refers to it by URL and branch in the
documents and does not carry the HL2 gateware build. No file of that gateware is part of the chip build any more, and
what the repository holds of it is used by two simulations only:

| Where | Files | Status |
|---|---|---|
| `rtl/rx/cic_integrator.v`, `cic_comb.v`, `cic_fixed.v`, `cic_var.v`, `rtl/tx/CicInterpM5.v`, `fw/tr-rxmodel/src/cic.rs` | the receive CIC decimators, the transmit CIC interpolator and the Rust model of the receive filters | clean-room rewrites under Apache-2.0, in the bitstream |
| `sim/rx/ref/cic_*.v` | reference copies of the four receive CIC modules for one comparison bench | copies of the new modules with `_ref` added to the module names, Apache-2.0 |
| `sim/h1_link_rx/hl2/` | `crc32.v`, `ip_send.v`, `mac_send.v`, `rgmii_send.v`, `udp_send.v` from HPSDR Metis via Hermes-Lite 2, and `rawstream.v` | GPL-2.0-or-later, simulation only, `LICENSE` (GPL-2.0) in the folder |
| `sim/h2_link_tx/hl2/` | `ip_recv.v`, `mac_recv.v`, `udp_recv.v` from HPSDR Metis via Hermes-Lite 2, and `txsink.v` | GPL-2.0-or-later, simulation only, `LICENSE` (GPL-2.0) in the folder |
| `fw/tr-hl2/src/protocol.rs`, `pc/discover.rs` | ported from the author's own `rawcap` in his fork | Apache-2.0 there, so Apache-2.0 here |

**The CIC rewrites:** the five Verilog files and the Rust model are clean-room rewrites, which means they were written
from specifications of the behavior the filters must have and not from the HPSDR or Hermes-Lite source. Each was then
checked bit for bit against the original in simulation (the benches are in `sim/cic_clean`), so the radio behaves as
before while the files are the author's own. The originals are no longer in the repository.

**The RGMII stages:** `rgmii_rx_phy.v` and `rgmii_tx_phy.v` were derived from HPSDR's `rgmii_recv.v` and `rgmii_send.v`
and were not part of the chip build (the HL2 link runs over the SFP lane). They have been removed from the repository.

**The two author-written files in the simulation folders:** `rawstream.v` (the raw stream sender) and `txsink.v` (the
transmit frame receiver) are the author's own files from his Hermes-Lite 2 fork, where they are released as
GPL-2.0-or-later like the rest of Hermes-Lite 2. They keep that license here, in the folders that hold the other HL2
files, so that every file of such a folder carries one license.

**Built bitstream:** nothing in `rtl/` is GPL or LGPL, so these files have no effect on a bitstream.

## 6. Sipeed's Tang Mega 138K Pro examples

**License:** Apache-2.0 (the files we followed say so). Some lines of `gowin/p1/sdr.cst`, `sdr.sdc`,
`gowin/ladder/*`, the SerDes parameter files and the DDR3 settings in `hw/gowin/mem/gwmc_param.v` follow Sipeed's
`ae350_customized_demo`, `sfp+/customized_phy` and DDR3 examples. Pin numbers and IP settings are mostly facts about the
board, but since Sipeed published them under Apache-2.0, NOTICE carries an attribution. There is no other obligation,
and no effect on the images beyond the notice.

## 7. Other Cargo dependencies

`cargo tree` for the firmware target (`tr-app`, `riscv32imafc-unknown-none-elf`, normal dependencies, no proc macros)
gives 59 crates. Apart from Slint, mfsk-core and our own crates, all of them are permissive:

| License | Crates in the firmware |
|---|---|
| MIT OR Apache-2.0 (and the same with other spellings) | arrayvec, bitflags, cfg-if, chrono, const-field-offset, crc, crc-catalog, critical-section, embedded-hal, euclid, field-offset, hash32, heapless, num-complex, num-traits, once_cell, pin-project, portable-atomic, riscv, riscv-rt, riscv-types, scopeguard, stable_deref_trait, unicode-segmentation, vtable |
| MIT | derive_more, libm, memoffset, pin-weak, rgb, slab, strum, taffy |
| Zlib OR Apache-2.0 OR MIT | bytemuck |
| Zlib | slotmap |
| 0BSD | managed, smoltcp |
| Unlicense OR MIT | byteorder |

The host-side tools and build steps pull in about 480 more crates (Slint's compiler and desktop back ends such as `winit`,
`image`, `serialport`, `hound` and so on). Their licenses, from `cargo metadata`, are MIT, Apache-2.0, BSD-2/3-Clause,
ISC, Zlib, BSL-1.0, Unicode-3.0, CC0, MPL-2.0 (`serialport`, used by `tr-loader-send`; file-level copyleft that only
matters if serialport's own files are changed), and two dual licenses where the permissive side is taken
(`unescaper`: MIT OR GPL-3.0-only, take MIT; `r-efi`: MIT OR Apache-2.0 OR LGPL-2.1-or-later, take MIT). None of
these is committed; Cargo fetches them.

**Obligation:** MIT, BSD and Zlib ask that their copyright notice comes along with binary copies. Whoever distributes a
firmware image therefore needs a third-party notices file next to it. The practical way is to generate it with
`cargo about` or `cargo license` from `fw/Cargo.lock`, for the firmware target only.

## 8. RISC-V and the Andes AE350

The AE350 SoC (Andes N25F core, buses, peripherals) is Gowin IP (section 9), not in the repository. The firmware uses
public facts about it: the Andes V5 custom CSR numbers for cache control in `tr-ae350/src/cctl.rs` and register
addresses from Gowin's AE350 user guide. Facts and register numbers are not copyrightable, so these files are ours.
The `riscv` and `riscv-rt` crates are MIT OR Apache-2.0.

## 9. Gowin IP and tool-generated files

**What the build uses:** `gowin/p1/build.sh` regenerates the AE350 SoC, the DDR3 controller, the SerDes PHY and the
PLL modules from the `ipcore` folder of the Gowin install at build time. Those sources are encrypted
(`pragma protect`, "GOWIN Encrypt Version 2.3") and some only have a "GOWIN EMB" author line with no license at all.
Gowin's website says access to its IP is subject to its End User License Agreement.

**In the repository:** the encrypted IP sources and the generated wrappers are not in git (the `impl/` folders are
ignored). What the repository does hold is safe: the `.ipc`, `.mod` and `serdes.toml` files are settings the IDE writes
from our choices, with no Gowin code in them, and `param.v`, `define.vh` and `gwmc_param.v` are parameter lists in our
own words. The Gowin primitives (`OSER10`, `ELVDS_OBUF`, the SerDes hard block) are parts of the chip;
`rtl/video/prim_sim/OSER10.v` and `sim/net/otp_model.v` are our own behavioral models of them, written from the
primitive guide, not copied from Gowin's simulation library. The 64-bit chip ID in `otp_model.v` is an invented value.

**Built bitstream:** every fpga-sdr bitstream contains Gowin's encrypted AE350, DDR3 and SerDes IP, and Gowin's terms
decide what may be done with it. Because that agreement has not been checked for the redistribution of a design that
contains the IP, no bitstream is published, and users build with their own Gowin license. The GW5AST-138 is not
supported by the Education edition, so the build needs a Gowin license that covers this chip, which the README says.

## 10. Test audio, captures and measurement data

| Data | Source and license | Where | Status |
|---|---|---|---|
| WSJT-X sample recordings (`qso1`, `qso3_busy` and others) | WSJT-X `samples/`, GPL-3.0-or-later, fetched from mfsk-core's repository by `tools/fetch_test_audio.sh` | `captures/` (ignored) | fetched, never committed |
| FT8 testbench vectors made from `qso1` and `qso3_busy` (7 hex files) | values of the same recordings | `sim/ft8/vectors/` (ignored) | not in the repository; `tools/make_ft8_vectors.sh` makes them from the fetched recordings, so no GPL data sits in the Apache tree |
| Synthetic FT8 vectors and the window table (4 hex files) | ours | `sim/ft8/vectors/` | ours, Apache-2.0 |
| Codec 2 speech (`hts1a`, `ve9qrp`) and FreeDV sample signals | Codec 2 and freedv-gui repositories, LGPL-2.1, fetched by `tools/fetch_freedv_test.sh` | `captures/freedv/` (ignored) | fetched, never committed |
| Codec 2 / FreeDV reference outputs | made from the above by the C programs | inside the LGPL crates | part of those crates (section 3) |
| HL2 captures, our own recordings | ours | `captures/` (ignored) | not in git |
| Filter measurements of DK1CG's Hermes-Lite 2 filter board | read off plots on the Hermes-Lite2 wiki | not in the repository | left out (see "Open points") |
| Schematic of the USB host Pmod | github.com/wuxx/icesugar, no license stated | not in the repository | linked, not copied |

The generators in `tools/` and the register map tool in `fw/xtask` write an Apache-2.0 header into the files they make,
so a generated file says on its first line under which license it can be used. Hex files hold data only and carry no
header.

## 11. Files that carry a GPL or LGPL header

Outside `fw/vendor`, `fw/tr-codec2`, `fw/tr-freedv` and `rtl/vendor`, which are third-party code under their own
licenses (sections 2, 3 and 4), exactly these files carry one:

| File | License in the header | Why |
|---|---|---|
| `fw/tr-modes/src/frontend/candidates.rs` | GPL-3.0-or-later | follows WSJT-X `sync8` through mfsk-core `coarse_sync` |
| `fw/tr-modes/src/frontend/decode.rs` | GPL-3.0-or-later | follows WSJT-X `sync8d` as mfsk-core translates it |
| `fw/tr-modes/src/txbb.rs` | GPL-3.0-or-later | follows WSJT-X `gen_ft8wave` and `gfsk_pulse` |
| `sim/h1_link_rx/hl2/crc32.v`, `ip_send.v`, `mac_send.v`, `rgmii_send.v`, `udp_send.v` | GPL-2.0-or-later (notice text) | HPSDR Metis code by VE3NEA, VK6APH and others, taken from Hermes-Lite 2 |
| `sim/h1_link_rx/hl2/rawstream.v` | GPL-2.0-or-later (SPDX) | the author's raw stream sender, released as GPL-2.0-or-later in his Hermes-Lite 2 fork |
| `sim/h2_link_tx/hl2/ip_recv.v`, `mac_recv.v`, `udp_recv.v` | GPL-2.0-or-later (notice text) | HPSDR Metis code from Hermes-Lite 2, two of them modified 2026 |
| `sim/h2_link_tx/hl2/txsink.v` | GPL-2.0-or-later (SPDX) | the author's transmit frame receiver from the same fork |

That is 3 files of GPL-3.0-or-later in the firmware and 10 files of GPL-2.0-or-later in two simulation folders, each
with a `LICENSE` file (GPL-2.0 text). No file of `rtl/`, `gowin/`, `hw/`, `tools/` or of any other crate under `fw/`
carries a GPL or LGPL header, and no file anywhere carries an LGPL header other than the two Codec 2 and FreeDV crates.

## Decision table

| Part | License | In the Apache-2.0 repository | Obligations | Built firmware | Built bitstream |
|---|---|---|---|---|---|
| Our code (RTL, firmware, tools, docs) | Apache-2.0 | yes | header, NOTICE | part of a GPL-3.0 image | part of the image |
| CIC filters (five Verilog files, Rust model) | Apache-2.0, clean-room rewrites | yes | header | none | part of the image |
| Slint 1.18.1 | GPL-3.0-only (royalty-free license excludes embedded; commercial needs a paid plan) | not committed, fetched by Cargo | source offer for the image | makes it GPL-3.0-only | none |
| mfsk-core 0.11.0, patched | GPL-3.0-or-later | yes, own folder `fw/vendor/mfsk-core` | keep LICENSE, change notes (present) | GPL-3.0 | none |
| Three FT8 files in `tr-modes` | GPL-3.0-or-later | yes, GPL header kept | keep header | GPL-3.0 | none |
| WSJT-X algorithms | not copyrightable as methods | n/a | none | none | none |
| Codec 2 / FreeDV Rust ports | LGPL-2.1-only | yes, own folders | keep COPYING, NOTICE, change notes (present) | used under GPL via LGPL section 3 | none |
| hdl-util HDMI | MIT OR Apache-2.0, taken as Apache-2.0 | yes, own folder | keep notices | none | notice |
| HL2 modules in `sim/` | GPL-2.0-or-later | yes, own folders with LICENSE | keep headers | none | none |
| Sipeed examples | Apache-2.0 | yes (lines in our files) | NOTICE attribution | none | none |
| Permissive Cargo crates | MIT, Apache, BSD, Zlib, 0BSD, ... | fetched | notices file with a distributed image | notices | none |
| Gowin encrypted IP | Gowin terms | never | Gowin's agreement | none | contained in every bitstream; none is published |
| Gowin IDE settings (`.ipc`, `.mod`, `.toml`) | ours (settings) | yes | none | none | none |
| WSJT-X recordings | GPL-3.0-or-later | fetched, not committed | attribution | none | none |
| Codec 2 / FreeDV speech | LGPL-2.1 | fetched, not committed | attribution | none | none |

## Open points

- **The three FT8 files.** `candidates.rs`, `decode.rs` and `txbb.rs` keep their GPL-3.0-or-later headers until the
  author confirms that they were written from the algorithm and not translated from mfsk-core or WSJT-X; with that
  confirmation they can move to Apache-2.0.
- **DK1CG's filter data.** The filter measurements and the plots made from them are left out of the repository until
  DK1CG has been asked for permission to publish them.
