# HL2 receiver RTL (simulation far end only)

Unmodified copies of Hermes-Lite 2 raw front-end gateware files, used only as the far end of the
H2 link testbench (`sim/h2_link_tx/tb_h2_link_tx.v`): the network receive chain that parses our TX
frames and the duplex TX sink that plays them back. They are not part of the fpga-sdr FPGA build.
`sim/h1_link_rx/hl2/` already vendors the *send*-side files (`rawstream.v` and its Ethernet send
chain) this same testbench reuses for the echo path back through H1.

Source: github.com/Schoning-Labs/Hermes-Lite2, branch `hl2-rawfront-release`, commit `ea4bf66`,
`gateware/rtl/txsink.v` and `gateware/rtl/ethernet/{mac_recv,ip_recv,udp_recv}.v`.
Authors and licence as stated in each file header (GPL-2.0-or-later), kept under that licence in this folder (see the LICENSE file here),
separate from the Apache-2.0 files of the rest of the repository.

**One mechanical rename:** `txsink.v`'s embedded `cdc_word` module (its own copy of the
same request/acknowledge crossing `rawstream.v` uses) is renamed here to `hl2_cdc_word`, a plain
text substitution with no logic change -- see `sim/h1_link_rx/hl2/README.md` for why (this
repository's own, differently-shaped `rtl/hl2link/cdc_word.v` would otherwise collide with it).
