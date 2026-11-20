<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# Documentation index

There are two kinds of documents in this folder. The ones in [learn](learn) are written for somebody new to FPGAs and radio and are meant to be read in order, and the rest are the design documents written while the radio was built, one per block, which you read when you want to know why a block looks the way it does. Some of the older design documents still say "fpga-sdr", which is the name the project had while it was written, and where one of them disagrees with [DECISIONS.md](DECISIONS.md) or the architecture tour, the decisions file and the tour describe what is built.

## Start here (in this order)

| Document | What it covers |
|---|---|
| [learn/FPGA_PRIMER.md](learn/FPGA_PRIMER.md) | What an FPGA is, what is on this board, and how a design gets into the chip |
| [learn/SDR_PRIMER.md](learn/SDR_PRIMER.md) | Sampling, I/Q, filters, the FFT, demodulation and FT8, with this radio's numbers |
| [learn/ARCHITECTURE_TOUR.md](learn/ARCHITECTURE_TOUR.md) | The whole radio from the antenna to the speaker and the screen, with the file for each part |
| [learn/OUTLINE.md](learn/OUTLINE.md) | The order to read the source files in |
| [learn/GLOSSARY.md](learn/GLOSSARY.md) | Every term used in the code and the documents |
| [learn/HISTORY.md](learn/HISTORY.md) | How the design got to where it is, including the attempts that failed |
| [learn/TOOLS.md](learn/TOOLS.md) | The tools used to build, simulate and run the radio |
| [learn/LICENSES.md](learn/LICENSES.md) | The license of every part and what each one obliges you to do |
| [USER_MANUAL.md](USER_MANUAL.md) | The screens, the keys, and what to check when nothing appears |

## Decisions and plans

| Document | What it covers |
|---|---|
| [DECISIONS.md](DECISIONS.md) | Every decision the owner made, with the date and the reason |
| [ARCHITECTURE.md](ARCHITECTURE.md) | The long design document, with the resource ledger |
| [PLAN.md](PLAN.md) | The work packages and their order |
| [BOARD.md](BOARD.md) | Verified facts about the Tang Mega 138K Pro dock |
| [TANG_LESSONS.md](TANG_LESSONS.md) | What we learned about this board and Gowin's tools |

## Radio input (Hermes-Lite 2 and the network)

[S1_HL2.md](S1_HL2.md), [H1_LINK_RX.md](H1_LINK_RX.md), [H2_LINK_TX.md](H2_LINK_TX.md), [H3_PHY.md](H3_PHY.md), [HL2_SFP.md](HL2_SFP.md), [HL2MIN.md](HL2MIN.md), [HL2MIN_BOARD_RESULT.md](HL2MIN_BOARD_RESULT.md), [N1_SFP.md](N1_SFP.md), [SFP_LINKS.md](SFP_LINKS.md), [NET_ID.md](NET_ID.md), [NETINPUT.md](NETINPUT.md)

## Receiving and demodulating

[RX_DSP.md](RX_DSP.md), [R2_RXMODEL.md](R2_RXMODEL.md), [R4_BACKEND.md](R4_BACKEND.md), [S3_DSP.md](S3_DSP.md), [S5_MODES.md](S5_MODES.md), [S10_FILTERS.md](S10_FILTERS.md), [LISTEN.md](LISTEN.md), [A1_AUDIO.md](A1_AUDIO.md), [AUDIO_OUT.md](AUDIO_OUT.md), [FREEDV.md](FREEDV.md), [USB_AUDIO.md](USB_AUDIO.md), [USB_HOST.md](USB_HOST.md), [X1_TX.md](X1_TX.md)

## Spectrum, waterfall and FFT

[F1_FFT.md](F1_FFT.md), [F2_SPECTRUM.md](F2_SPECTRUM.md), [F3_ZOOM.md](F3_ZOOM.md), [ZOOM_FIT.md](ZOOM_FIT.md), [ZOOM_IN_CHIP.md](ZOOM_IN_CHIP.md), [F4_DDR.md](F4_DDR.md)

## FT8

[F5_FT8SPEC.md](F5_FT8SPEC.md), [F6_SYNC.md](F6_SYNC.md), [F7_CAND.md](F7_CAND.md), [S15_FT8MODEL.md](S15_FT8MODEL.md), [P2_FT8_FW.md](P2_FT8_FW.md), [FT8_CPU.md](FT8_CPU.md), [FT8_OFFLOAD.md](FT8_OFFLOAD.md), [FT8_PASS2.md](FT8_PASS2.md), [CPU_BUDGET.md](CPU_BUDGET.md), [S2_BENCH.md](S2_BENCH.md)

## Screen and HDMI

[V1_VIDEO.md](V1_VIDEO.md), [V2_COMPOSITOR.md](V2_COMPOSITOR.md), [S11_GUI.md](S11_GUI.md)

## Processor, memory and loading

[C1_AE350.md](C1_AE350.md), [C2_LOADER.md](C2_LOADER.md), [LADDER.md](LADDER.md), [MEM_1GB.md](MEM_1GB.md), [REGMAP.md](REGMAP.md), [P1_TOP.md](P1_TOP.md)

## Fitting the chip and closing timing

[FIT.md](FIT.md), [THIN.md](THIN.md), [RESOURCES.md](RESOURCES.md), [CLOCK_STUDY.md](CLOCK_STUDY.md), [ROUTE_CAUSE.md](ROUTE_CAUSE.md), [ROUTE_DIAG.md](ROUTE_DIAG.md), [TOOLCHAIN.md](TOOLCHAIN.md)
