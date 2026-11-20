# hdl-util/hdmi (vendored)

Source: https://github.com/hdl-util/hdmi
Commit: 83b1c9543a91b776671a44e68e130f81cae437b7 (`master`, fetched 2026-09-25)
License: MIT OR Apache-2.0 (both full texts included here as `LICENSE-MIT` and `LICENSE-APACHE`,
copied unmodified from the upstream repository). Dual MIT/Apache-2.0 is compatible with this
project's Apache-2.0 (used under either license; we take it under Apache-2.0 here, which asks that modified files say so).
Author: Sameer Puri (https://github.com/sameer) and contributors.

The nine files in `src/` (`hdmi.sv`, `tmds_channel.sv`, `serializer.sv`, `packet_picker.sv`,
`packet_assembler.sv`, `audio_sample_packet.sv`, `audio_clock_regeneration_packet.sv`,
`audio_info_frame.sv`, `auxiliary_video_information_info_frame.sv`, `source_product_description_info_frame.sv`)
were vendored unmodified. Three have been changed since, each with a "modified 2026 by" note in its
header that says what and why: `packet_picker.sv` (Icarus Verilog compatibility; the audio sample
strobe; the sample buffer as a packed vector), `audio_clock_regeneration_packet.sv` and `hdmi.sv`
(the audio sample strobe: `clk_audio` is a one-pixel-clock strobe per audio sample, not a clock,
docs/AUDIO_OUT.md section 4). The other files are byte-for-byte from the commit above.

WP TCLOSE2 (timing closure of the full-chip build ls6 at 148.75 MHz, each edit has a "modified 2026" note in its file):
`tmds_channel.sv` encodes video in three clock steps instead of one (ones of the byte and XOR/XNOR choice; q_m and its
ones; running disparity and output), two clocks more latency, mode/control/island inputs delayed to match
(`sim/video/tb_hdmi_video.v` delays lengthened by two); `hdmi.sv` takes `packet_enable` from a register (same value,
same clock, computed from the next `cx`); `packet_picker.sv` selects header and sub-packets by a one-hot copy of
`packet_type` kept in a register (null and idle packets give zeros instead of undefined values).

Why this core: DECISIONS.md and ARCHITECTURE.md section 3.5 call for HDMI with audio (data
islands), which needs a real TMDS+data-island encoder, not Gowin's video-only DVI TX IP
(BOARD.md, "HDMI / DVI output"). `serializer.sv` already has a Gowin `OSER10` path behind
`` `GW_IDE`` alongside its Xilinx `OSERDESE2` and Altera `ALTLVDS_TX` paths, and a `` `VERILATOR``
escape hatch that leaves `tmds`/`tmds_clock` undriven and instead exposes the pre-serialization
10-bit-per-channel codes as `tmds_internal` (marked `verilator public_flat` in `hdmi.sv`) for
testbenches that check the TMDS/data-island encoding without simulating the physical serial line.

Used by (this package, V1): `rtl/video/sdr_hdmi_video.v`, which instantiates `hdmi` with
`VIDEO_ID_CODE` 16 (1080p60), 34 (1080p30) or 4 (720p60) — CEA-861 video IDs the core already
supports natively, so no local fork of the timing generator was needed.

`OSER10` itself is a Gowin primitive, not part of this vendored core: see
`rtl/video/prim_sim/OSER10.v` (our own simulation model) and `rtl/video/prim_gowin/README.md`
(where the real primitive comes from on hardware) for how the `` `GW_IDE`` path is satisfied on
each side.
