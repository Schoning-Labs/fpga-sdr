<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# Register map sources

One TOML file per fabric block (see `docs/ARCHITECTURE.md` section 4.1 for the block list and
base addresses). Format, validation rules and the generator are documented in
`docs/REGMAP.md`; run `cd fw && cargo run -p xtask -- regmap` after editing any file here, which
regenerates `generated/` below and `fw/tr-regs/src/generated.rs` -- `tools/check.sh` does the
same and fails if either is stale.

- `example.toml` -- generator self-test fixture, not a real fabric block (`status = "test"`).
- `rx_bank.toml`, `hl2_link.toml`, `spectrum.toml`, `video.toml`, `audio.toml`, `tx.toml` --
  drafts (`status = "draft"`) for the six blocks docs/ARCHITECTURE.md already describes
  registers for. Base address and page size are fixed; the register/field layout is this WP's
  proposal, to be edited and promoted to `status = "final"` by whoever builds that block's own
  work package (docs/PLAN.md tracks R, H, F, V, X, A).
- `generated/` -- generated Verilog `` `include `` files, one per block above. Committed; see
  docs/REGMAP.md "Why generated files are committed".
- `usb.toml` -- the USB audio device (docs/USB_AUDIO.md, `rtl/usb/usb_regs.v`), `status = "final"`.
- `usbh.toml` -- the USB host on the Pmod board (docs/USB_HOST.md, `rtl/usbh/usbh_regs.v`), `status = "final"`.
