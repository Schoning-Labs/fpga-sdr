<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# S11: `tr-gui`, the front-panel UI

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Work package S11 (`docs/PLAN.md`). Owner decisions this builds on: `docs/DECISIONS.md` ("GUI:
Slint (pure Rust, runs without an OS, software renderer)... Display: 1920x1080 output... Layout
must also scale down to small LCD panels later (for example 1024x600)"), and the compositor
design in `docs/ARCHITECTURE.md` section 3.5 and 5.6.

## What this is

`fw/tr-gui` is the radio's front-panel UI, written in `.slint` (`fw/tr-gui/ui/`), plus the Rust
glue to run it through Slint's software renderer into a pixel buffer. It holds **no radio logic**:
the whole state the panel can show is one Rust struct, `tr_gui::PanelState`
(`fw/tr-gui/src/model.rs`), and nothing in this crate decides what that state should be. Later,
`tr-app` will own a `PanelState`, update it as the radio's actual state changes (a new decode
arrives, the operator changes band, the HL2 reports a trip), and call `apply_state()` to push it
into the running window. Today only a demo `PanelState::demo()` exists, used by the screenshot
test below.

## Layout

Two root components, `ui/panel_1920x1080.slint` and `ui/panel_1024x600.slint`, built from the same
the files under `ui/components/`: frequency display (VFO A/B), band buttons, mode buttons
(LSB/USB/CW/AM/FM/DIGI), filter width, AGC, NR/NB, an RX slice list (up to 8 receivers,
docs/ARCHITECTURE.md 3.2), TX status with a loud inhibit indicator, the N2ADR filter-board
indicator, an S-meter, a digital-mode decode list (FT8 first), and a menu button with a drop-down.
The 1920x1080 layout puts spectrum and waterfall side by side with a wide sidebar, using the full
window height (both the FPGA-window column and the sidebar column stretch to fill it, so there is
no dead strip below the RX slice list); the 1024x600 layout stacks them with a single narrower
sidebar and smaller type, because there is no room for two wide columns. In both sizes the
waterfall gets more height than the spectrum (about 60/40), since the scrolling history is the
part an operator watches continuously. Every component takes a `compact: bool` (or is given fixed
sizes by the parent) so the same `.slint` file serves both layouts.

Band buttons are the 11 ham bands (160, 80, 60, 40, 30, 20, 17, 15, 12, 10, and Gen for general
coverage) -- **not** the N2ADR low-pass filter groups (several bands sharing one filter, several
bands to one button, docs/ARCHITECTURE.md 8), which is a different concept shown only in the
N2ADR indicator (for example "30/20 m LPF" when the filter covering 30 m is also the one covering
20 m) and never doubles as a band selector. `ui/components/band_buttons.slint` lists all 11 in one
row on the large panel; at 1024x600 there is not room for one row of 11 without truncating them,
so it wraps into two rows of 6 and 5 instead.

The frequency display (`ui/components/frequency_display.slint`) is sized like a transceiver's main
display, not a status line: VFO A's digits are asked for at 64px (1920x1080) / 42px (1024x600) --
see "A font-size pitfall" below for why the font-size and the rendered digit height are not the
same number, and why those two sizes are not simply 58px/34px scaled down to the review's 48-64px /
32+px targets. Measured on the rendered PNG (`tests/screenshots.rs`
`bright_ink_row_span`/`vfo_a_digit_height_is_at_least` check): **47px tall at 1920x1080, 30px tall
at 1024x600**, both above the 44px/28px targets. VFO A is grouped the same way as everywhere else
in the panel (`14.074`) with its last three (Hz) digits in a smaller size beside it, and VFO B
smaller still beneath it. Mode and filter width are read out beside VFO A, so the operator sees
what they are listening to without looking elsewhere on the panel.

The FT8 decode list (`ui/components/digital_panel.slint`) is a fixed-height-row, top-aligned,
scrolling list, not a panel that grows with its content: each row is exactly 22 px tall at
1920x1080 (14 px at 1024x600), newest decode first (`PanelState::digital_decodes` is expected in
that order; the component only ever draws it top to bottom, it does not sort), inside a `Flickable`
sized to hold about 40 rows' worth of scrolling before it needs to grow the panel. Columns: time,
dB, DT (the decode's time offset from the slot boundary), frequency offset, message.

The S-meter (`ui/components/s_meter.slint`) is one tight block: the "S-meter" label, the S-unit
reading (e.g. "S9+18") and a numeric dBm readout sit directly above the bar with no gap, and the
bar itself has scale marks at S1, S3, S5, S7, S9 and +20/+40/+60 dB above S9, matching a
conventional analogue meter face.

The spectrum and waterfall areas are not drawn by Slint at all. Each is an `FpgaWindow`
(`ui/components/fpga_window.slint`): a plain rectangle filled with the compositor's key colour,
RGB565 `0xF81F` (full-intensity magenta, `#ff00ff` at 24-bit precision -- the two round-trip
losslessly through the RGB565 conversion). Per `docs/ARCHITECTURE.md` 3.5, the FPGA compositor
shows its own spectrum/waterfall layer wherever Slint's output is exactly that colour, and shows
Slint's output everywhere else. `FpgaWindow` draws nothing else inside that rectangle -- not even
its own label, which is reserved a strip above the key-colour area instead -- because any other
pixel there would incorrectly hide the real spectrum. The menu (`ui/components/menu_bar.slint`) is
the one place this project intentionally draws over the key-colour area: it opens as a normal
Slint overlay on top of everything, which is exactly the point of the key-colour design (a menu
can cover the waterfall without a second alpha plane).

## Rust side

- `src/model.rs`: `PanelState` and its pieces (`Vfo`, `Mode`, `AgcMode`, `TxInhibitReason`,
  `RxSlice`, `DigitalDecode`). All formatting (frequency grouping, S-meter label, dB/Hz text) is
  done here in plain Rust, not in `.slint` expressions, so it has normal unit tests
  (`cargo test -p tr-gui`).
- `src/platform.rs`: `FramebufferPlatform`, the `slint::platform::Platform` implementation this
  project needs to run without an OS (docs/ARCHITECTURE.md 5.6). It has no input handling and no
  event loop of its own -- there is no input until USB/MIDI arrives (owner decision) -- only
  `render_rgb565()`, which renders the current frame into a caller-supplied `Rgb565Pixel` buffer.
  The clock `duration_since_start` needs is supplied by the caller as a closure, so this file
  never has to choose between `std::time::Instant` (host) and a hardware timer (firmware, once
  `tr-ae350`/WP C1 exists).
- `src/lib.rs`: the two generated panel modules (`size_1920x1080`, `size_1024x600`) and
  `apply_state()` for each, which pushes a `PanelState` into that window's `PanelModel` Slint
  global. Both panels are compiled as **separate** Slint programs (`build.rs`) because
  `slint::include_modules!()` can only ever point at the last file a build script compiled; the
  two modules `include!()` their generated code directly by its fixed `$OUT_DIR` filename instead.

## Licensing: why only the software renderer

`docs/DECISIONS.md` requires pure Rust with no C or C++ anywhere, including no C GUI toolkits.
Checked against Slint 1.18.1's own feature list (`slint` crate, `default-features = false`):

| Slint feature | Pulls in | Used here? |
|---|---|---|
| `renderer-skia` | Google Skia, C++ | no |
| `backend-qt` | Qt, C++ | no |
| `renderer-femtovg` | OpenGL via `glutin`/`gl` (not C, but a GPU-accelerated path this project doesn't need) | no |
| `renderer-software` | pure Rust (`i-slint-renderer-software`) | **yes, the only renderer feature enabled** |

`fw/tr-gui/Cargo.toml` sets `default-features = false` and only
`["compat-1-2", "unsafe-single-threaded", "libm", "renderer-software"]` -- the exact feature set
Slint's own bare-metal guide (bundled in the `slint` crate as `mcu.md`) recommends for a `no_std`
target with no OS thread-local storage and no `std` floating point. This is the *same* feature set
used for the host build and the firmware build, so there is exactly one Slint renderer in this
project, everywhere.

## A font-size pitfall (why VFO A's digits are literal `58px`-style numbers, not `compact ? a : b`)

The first version of this panel set VFO A's font size through a property bound to a conditional
expression: `property <length> main-size: compact ? 34px : 58px; ... font-size: main-size;`. It
compiled, it rendered, the layout gave the text the right amount of space, and a quick look at the
screenshot suggested it worked. It did not: the actual glyphs came out about 8px tall regardless of
size, because of how the software renderer gets its fonts.

`build.rs` configures `EmbedResourcesKind::EmbedForSoftwareRenderer` (Slint's own recommendation for
a target with no filesystem and no runtime font rasterizer budget, docs/ARCHITECTURE.md 5.6): at
compile time, the compiler scans the `.slint` source for the font sizes actually used and
pre-rasterizes exactly those into bitmaps baked into the binary. That scan only recognises a literal
number written directly on a `font-size:` binding -- `font-size: 58px;` -- not a property that
happens to evaluate to 58, and not a `compact ? 34px : 58px` conditional, even though both of its
branches are themselves literals. A font size that scan does not see gets no bitmap, and the
renderer silently substitutes its own small built-in default at run time -- no error, no warning,
the wrong pixels. This matches what shipped: `font-size: main-size;` never resolved to a size the
embedder could see, so the "58px" VFO A text and the "16px" mode/AGC buttons next to it ended up the
same handful of pixels tall, and the difference (drastic for the frequency display, barely
noticeable everywhere else, which is why only the frequency display was caught by eye) was the only
symptom.

Fixed by making every `font-size:` in `ui/components/frequency_display.slint` a plain literal
number, written twice (once under `if !compact`, once under `if compact`) rather than shared
through a property or a conditional. This is more repetition than the original, on purpose: it also
keeps the *set* of font sizes this file asks the embedder for small and enumerable (one file, a
dozen literal numbers to read off), which is the stated point of `EmbedForSoftwareRenderer` in the
first place. Other components in this crate still size text with `compact ? a : b` (for example
`ui/components/s_meter.slint`'s tick labels) -- their sizes are small enough, and close enough to
whatever the renderer's fallback turned out to be, that the same bug would be hard to see by eye.
Nothing has verified they are actually rendering at their intended size rather than a coincidentally
similar fallback; only VFO A had a "no radio logic here" easy, load-bearing pixel-measurement test
added for it (see the done-test below). Auditing the rest is unstarted work, not a checked fact.

## `no_std`

`fw/tr-gui/src/lib.rs` is `#![cfg_attr(not(test), no_std)]`: a `no_std` crate (with `alloc`) for
everything except `cargo test`, which needs `std::fs` for the screenshot PNGs and
`std::time::Instant` for the render clock. `cargo build --target riscv32imafc-unknown-none-elf -p
tr-gui` builds the same source as a genuinely `no_std` `rlib` -- there is no separate "embedded"
copy of this crate.

## Done-test

```
cd fw
cargo test -p tr-gui                                          # renders both sizes, writes PNGs
cargo build --target riscv32imafc-unknown-none-elf -p tr-gui   # no_std firmware-target build
```

Both are also part of `bash tools/check.sh` (the riscv32imafc line now includes `-p tr-gui`
alongside the AE350-only crates).

`fw/tr-gui/tests/screenshots.rs` renders both panel sizes through
`FramebufferPlatform`/`render_rgb565` -- the exact path the firmware will use -- with a
representative `PanelState::demo()` (a receiver outside the selected filter, an inhibited
transmitter, ten FT8 decodes newest-first, NR on), and writes:

- `docs/img/panel_1920x1080.png`
- `docs/img/panel_1024x600.png`

The test also asserts, so a future change that silently breaks any of these properties fails
`cargo test`: the spectrum `FpgaWindow`'s interior is still exactly the key colour (`0xF81F`) after
a full render; the frame is not blank (more than 10,000 / 5,000 pixels differ from the background);
and VFO A's digits, measured as the tallest run of near-white pixel rows in the frequency display
(`bright_ink_row_span`), are at least 44px tall at 1920x1080 and 28px tall at 1024x600 -- the check
added for the font-size pitfall above, since "the layout box is the right size" and "the digits are
the right size" turned out to be two different, independently checkable claims.

**On "the software-renderer image equals the desktop render"** (the done-test wording in
`docs/PLAN.md`): confirmed, and checked automatically, not just asserted in prose. This project has
exactly one renderer by design (the licensing table above): there is no separate
GPU-accelerated desktop renderer for a "real" desktop image to be compared against, which means
the claim only has teeth if it is read as *the render is deterministic* -- the same state produces
the same image every time, on the host and later on the board, rather than depending on incidental
state (timing, buffer reuse, uninitialized memory) that would make "desktop" and "framebuffer"
renders drift apart in practice even while sharing code. `renders_both_panel_sizes` checks exactly
that: for each size it constructs *two independent* windows and panel components from the same
`PanelState`, renders each into its own buffer, and asserts the two `Rgb565Pixel` buffers are
byte-for-byte identical before writing the PNG from the first one. If a future change introduced
incidental non-determinism (an uninitialized buffer, a stray timer-driven animation, output that
depended on construction order), this comparison would fail `cargo test` even though a single
render still "looked right".

## What is unfinished

- **No radio logic drives it yet.** `tr-app` (WP C1+) does not exist; nothing calls
  `apply_state()` outside the screenshot test. This was explicit scope for S11 ("no radio logic
  here").
- **No input.** The `request-*` callbacks in `ui/model.slint` (band/mode/AGC select, NR/NB toggle,
  RX slice select, TX toggle, menu open/select) are wired from the buttons up to those callbacks,
  but nothing in this crate handles them -- there is no input device until USB/MIDI, which is
  deferred (`docs/DECISIONS.md`). MIDI controller mapping (owner's later wish) is not started.
  The 4 physical buttons mentioned in `docs/ARCHITECTURE.md` 5.6 are not wired either.
  The filter-width control is a read-out, not yet adjustable (no control surface exists to adjust
  it from).
  Frequency entry (typing/encoder-tuning a VFO) has no control surface either -- the frequency
  display shows `PanelState`, it does not accept input.
- **No animation/partial-redraw measurement.** `docs/ARCHITECTURE.md` 5.5 assumes Slint redraws
  only dirty regions on real hardware; this WP does not measure it (that is WP S2, blocked on
  `tr-ae350`/T4's QEMU path for instruction counts, and ultimately on the board for cycles).
  `render_rgb565()` here always does a from-scratch first render (`RepaintBufferType::ReusedBuffer`
  still needs a full first frame); the test does not exercise a second, partial redraw.
- **No real font/image assets chosen.** The panel uses Slint's default font and no images (flat
  colours and text only), which keeps this WP self-contained (`EmbedForSoftwareRenderer` in
  `build.rs` pre-processes whatever is used, so this is a content choice, not a technical gap).
- **Filter-curve overlay, tuning cursor, and other FPGA-window overlays** (docs/ARCHITECTURE.md
  3.5 point 3: passbands, grid, filter curves) are drawn by the FPGA compositor, not this crate;
  `tr-gui` only reserves the rectangles.
