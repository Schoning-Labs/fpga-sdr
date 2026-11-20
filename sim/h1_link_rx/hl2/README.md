# HL2 sender RTL (simulation far end only)

Copies of Hermes-Lite 2 raw front-end gateware files, used only as the far end of the H1 link
testbench (`sim/h1_link_rx/tb_h1_link_rx.v`) and, with duplex/echo turned on, the H2 link
testbench (`sim/h2_link_tx/tb_h2_link_tx.v`). They are not part of the fpga-sdr FPGA build.

Source: github.com/Schoning-Labs/Hermes-Lite2, branch `hl2-rawfront-release`, commit `ea4bf66`,
`gateware/rtl/rawstream.v` and `gateware/rtl/ethernet/{udp_send,ip_send,mac_send,crc32,rgmii_send}.v`.
Authors and licence as stated in each file header (GPL-2.0-or-later), kept under that licence in this folder (see the LICENSE file here),
separate from the Apache-2.0 files of the rest of the repository.

**One mechanical rename:** `rawstream.v`'s own `cdc_word` module (a request/acknowledge,
no-explicit-send crossing it and `txsink.v` share -- see `sim/h2_link_tx/hl2/txsink.v`, which
defines it) is renamed here to `hl2_cdc_word`, a plain text substitution with no logic change, only
because this repository's own `rtl/hl2link/cdc_word.v` (a different, explicit-`send_a` crossing,
used by the link transmit RTL) would otherwise collide: two modules cannot share one name in one Icarus
compilation. `rawstream.v`'s `ECHO=0` configuration (the receive testbench) never elaborates the
generate branch that instantiates it, so this rename changes nothing for the receive testbench; the transmit
testbench is the first to build with `ECHO=1`, where the branch is live.
