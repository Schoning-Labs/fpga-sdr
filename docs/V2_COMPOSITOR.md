<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# WP V2: the screen compositor

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Branch `v2`. PLAN.md track V. Files: `rtl/video/compositor.v` (register file, top), `compositor_fetch.v`
(DDR3 side), `compositor_pix.v` (pixel pipeline), `compositor_util.v`, `compositor_cfg.vh`;
`sim/video/tb_compositor.v`; `hw/regmap/video.toml`.

## 1. What existed (interfaces)

| Piece | Interface |
|---|---|
| HDMI core (`rtl/vendor/hdmi/hdmi.sv`, wrapped by `rtl/video/sdr_hdmi_video.v`) | outputs `cx`, `cy` = the position it is asking a pixel for **in this clock**; takes `rgb[23:0]` in the same clock. `cx` 0..2199, `cy` 0..1124 (CEA 16 and 34; 1280x720: 1650 x 750), active 1920 x 1080 |
| V1 colour bars | `colorbar_gen`, combinational from `cx`; the top level (not changed) feeds the HDMI core from it |
| Spectrum (`rtl/spectrum/spectrum_pipeline.v`) | `line_rd_addr[10:0]` -> `line_rd_data[15:0]` one clock later (`clk_dsp`), always the finished buffer; signed 16 bit, 1/64 dB, 1,920 columns; the same for the zoom line (idle in P1) |
| Waterfall (`waterfall_writer.v`) | ring of 2,048 lines x 240 lane words, `write_line_ptr` = last finished line, column 0 of a line is the **top byte** of its first word. Ring base register `wf_ring_base` (lane words) |
| DDR3 read arbiter (`rtl/ddr3/ddr3_read_arbiter.v`) | video tier 0: `req/addr/burstlen` held until `gnt`, then `rvalid/rdata` x burstlen, `done`. Addresses are 64-bit lane words. A granted burst runs to its end |
| Stub in `p1_stubs.v` | `compositor_stub` (read tier idle, frame-start interrupt). Now unused; the module is still in that file |

## 2. What the architecture specifies, and the gaps

ARCHITECTURE 3.5 and 4.1 give: Slint layer RGB565 from DDR3 "read ahead two lines into BSRAM"; up to 4 windows, trace or
waterfall, source full-band or zoom; overlays inside windows: frequency and dB grid, up to 8 receiver passbands
(translucent), tuning cursor, filter-board curves; key colour 0xF81F shows the FPGA layer; page 0xE807_0000 holds
"timing, framebuffer base/stride, windows, palette, overlays, filter-curve tables". C10 sizes the memories (12 blocks).

Gaps, each with the default taken (all in `hw/regmap/video.toml`, which was a draft and is now final):

1. **Level to row** is not specified. Per window `win_scale`: `top_level` (signed, 1/64 dB, the level at the top row) and
   `gain` (pixels per dB, Q8.8, same convention as the spectrum block's waterfall gain). Row = (top_level - level) x gain,
   clamped to the window.
2. **Which windows can be waterfalls**: C10 has two waterfall line buffers, so windows 0 and 1 only (bit ignored in 2 and 3).
   Window 0 uses palette 0 and line buffer 0, window 1 palette 1 and line buffer 1.
3. **Waterfall scrolling**: newest line in the top row, older below; the scroll line is latched once per frame so the picture
   never shifts mid-frame. **Since 2026-10-12 (branch `zoom`, section 10) each waterfall window has its own ring and its own
   scroll line**; before that both read the one full-band ring.
4. **Spectrum line crossing into the pixel clock**: the spectrum block's line buffer reads in `clk_dsp`. The compositor
   copies the whole line (1,920 reads) into its own snapshot RAM once per frame, in the vertical blank, and the pixel
   side reads that. A spectrum line that finishes during those 13 us shows as a torn trace for one frame (one in 2,500).
5. **Overlay definitions**: grid = first line and step in pixels per window and direction (0 = off); passbands = screen
   x range, window mask, alpha 0..16 sixteenths, colour; the lowest-numbered enabled passband covering a pixel wins
   (no stacking); cursor = screen x, width, window mask. Order bottom to top: background or fill or palette, grid,
   passband, trace line, cursor. Windows must not overlap.
6. **Palette**: 24-bit colour (the draft said RGB565) x 256 x 2, one BSRAM, written through `palette_index` (bit 8 picks the
   palette) and `palette_data`; takes effect at once, not at the vertical blank.
7. **Key colour** is a register (`key`, reset 0xF81F).
8. **Frame-synchronous registers**: everything but the palette is copied from the register file once per frame, at line
   1,082, so the framebuffer swap and every window change happen in the vertical blank.
9. **Pixel clock**: the P1 top level made 148.75 MHz for 1080p60 when this was written; the radio now runs 1080p30 at 74.167 MHz (50 x 89 / 60, `gowin/p1/sdr.sdc`), because 1080p60 gave a black picture on the board (docs/DECISIONS.md 2026-10-22). The compositor has no dependence on the value.
10. **Colour bars when `ctrl.enable` = 0**: the compositor makes them itself, so the V1 pattern stays visible until the
    firmware has a valid first frame, and the DDR3 is not read.
11. **Zoom snapshot** is a parameter (`ZOOM_SNAP`, 0 in P1): the zoom DDC and 4k FFT are not built in the chip, so a window
    with `source_zoom` shows the full-band line. Setting it costs two more block RAMs.
12. **Filter-board curves (ARCHITECTURE 3.5 item 3) are not built.** Planned: per curve a y value at every 8th column in a
    BSRAM written through an index/data pair (C10: 8 x 241 x 12 bit, 2 blocks), linear interpolation, drawn like the trace
    line in its own colour, one curve thicker. It adds one stage group after the trace line (pipeline stage 20) and 2 BSRAM.

No architecture change is needed.

## 3. The picture, per pixel (the specification the testbench model implements)

1. The window is the lowest-numbered enabled window containing the pixel.
2. Outside every window, or where the Slint pixel is not the key colour: the Slint pixel (RGB565 to RGB888 by bit replication).
3. Else the FPGA layer of the window. Trace window: background colour, or fill colour on rows below the trace; column c = x - win_x
   + win_src; the trace row of a column is yt(c); the trace line covers the rows between yt(c-1) and yt(c) (just yt(c) in the
   window's first column). Waterfall window: palette[byte c of ring line (wf_top_line - row)].
4. Grid lines (colour `col_grid`) replace it: vertical at window columns first + n x step, horizontal (trace windows) likewise.
5. The first enabled passband that covers x and is meant for the window blends over it: out = base + floor((colour - base) x alpha / 16).
6. The trace line (colour `col_trace`), then the cursor (colour `cursor_col`), opaque.
7. `ctrl.enable` = 0: eight colour bars instead of everything.

## 4. Design

**Pixel clock** (`compositor_pix.v`): free-running pipeline of 31 register stages, no clock enables, no resets, at most
about four LUT levels per stage (compares, subtracts and one multiplier per stage). Its counters run 31 clocks ahead of the
HDMI core's `cx, cy` and are re-aligned to them once a frame, so the pixel for `(cx, cy)` is on `rgb` in the same clock
(the testbench checks this at every pixel). Stage plan in the file header. Window membership by registered range compares,
grid by down counters, the spectrum row by a 16 x 16 multiplier (one DSP block), passband and trace blend by three 9 x 5
multipliers. Wide per-frame values are held in a frame copy (`comp_xfer`) whose load enables are kept register copies, one per
12 bits, so no enable net has more than about 20 loads; the module carries `syn_maxfan = 10`.

**DDR3 side** (`compositor_fetch.v`, `clk_dsp`): while line n is shown it fetches line n + 1 into the other half of the line
buffers. Per line, in this order: the Slint line (480 lane words) in 3 bursts of 160 (F4 finding: bursts of 8 starve the
video), then each waterfall window's line (only the words its window shows). Bursts are requested back to back; a 4-entry
descriptor queue tells the sink where each burst's words go. Line address by a pipelined multiply (Slint) and shift-subtract
(waterfall `line x 240`). **No hang is possible**: a burst not granted for 3,000 clocks, or data missing for 3,000 clocks, is
abandoned (`status.lane_error`); a new target line abandons the old one. The pixel side never waits for the fetch side.

**Underrun**: at the start of every displayed line the pixel side compares the gray code of the line with the last line
the fetch side finished; unequal = underrun: `underrun_count` +1, `status.underrun` set, and the line shows what the
buffer holds (the old line, partly overwritten). Counted only while `ctrl.enable` = 1.

**Memories** (18 kbit blocks as Gowin counts them, section 8): 19 blocks against the 12 of C10 (which had 2 more for filter curves, not built).

**Registers** (`compositor_regs`): reads return what was written (a 256 x 32 RAM initialised with the reset values) except the
read-only words; the bus is registered, strobes decoded once; read data in 3 clocks (the bridge waits 6).

## 5. DDR3 read rate

Per displayed line: 480 words Slint + up to 2 x 240 waterfall = 960 words of 8 bytes in a line time of 14.8 us (2,218
`clk_dsp` clocks), i.e. at most 519 MB/s while an all-width, all-height double waterfall is on screen, 249 MB/s for the
Slint layer alone, about 60 MB/s for two 1,000 x 400 waterfalls. The lane reaches 846 MB/s with 180-word bursts
(MEM_1GB.md), so the worst case uses 61 % of the lane and fetching one line takes about 1,400 clocks of the 2,218 available.
Margin is real but not large; the underrun counter is how to see it on the board (risk 4, check B4).

## 6. What the firmware does to show a GUI frame

1. Draw RGB565 into a buffer (stride 3,840 bytes, 8-byte aligned base), key colour 0xF81F in every window rectangle,
   write the D-cache back (`L1D_VA_WB`) before the next step.
2. Registers: `fb_stride`, `win_pos/size/ctrl/src/scale`, grid, colours, palettes (write `palette_index` then `palette_data`,
   256 entries each), the waterfall rings (section 10), passbands, cursor.
3. `ctrl.enable` = 1. The picture appears at the next vertical blank.
4. To swap buffers: finish drawing and write back the cache, write `fb_base` = the other buffer. It takes effect at the next
   blank; `fb_active` reads back the new value from then on, and the old buffer is free. Interrupt 8 (frame start) is the pacing.
5. After each layout change the firmware moves the windows by rewriting `win_pos/size` and the key rectangles together.
   Watch `underrun_count` while bringing it up.

## 7. Verified

`sim/video/tb_compositor.v` (iverilog, 14 s): 96 x 24 active, 240 x 30 total frame so a line is 240 `clk_dsp` clocks (the real
line is 2,200), through the real compositor, the real read arbiter and the lane model with 6 clocks of latency. Every pixel of
frames 1, 2, 3, 5, 6, 7 (15,461 pixels, 8,439 of them FPGA layer: 5,133 waterfall, 1,472 trace line, 1,062 fill; 2,675 grid,
5,816 passband, 224 cursor) equals the reference model, which is written from section 3 and from the register words alone.
Also: register reset values and read-back, a mid-frame write of the framebuffer base, scroll line, cursor, colour and source
offset leaves that frame unchanged and shows in the next (swap on the vertical blank, `fb_active`, `wf_top_line`), a lane held
off for 500 clocks is counted (`underrun_count`, `status.underrun`, clear by write), no hang, the next frame is exact again.
`sim/top/tb_sdr_core.v` still passes (the compositor is idle there: `ctrl.enable` = 0).
Not verified: the real HDMI core with the compositor (the top level is not changed, see section 9); real DDR3 byte order of the
Slint pixels (assumed little-endian: pixel 4k + j in bits 16j+15:16j of lane word k) and of the waterfall words (taken from the writer).

## 8. Size and timing

The timing figures in this section were measured for 1080p60, with `clk_dsp` planned at 150 MHz and `clk_pix` at 148.5 MHz. The radio as built runs `clk_dsp` at 120 MHz and `clk_pix` at 74.167 MHz, which is half the pixel rate, so the pixel-side margins below only get larger.

Gowin EDA 1.9.11.03 Standard, stand-alone (`gowin/res.sh compositor --clk clk --clk2 clk_pix --wrap --sdc gowin/wrap/compositor_ooc.sdc`,
place option 3, route option 1, `clk_dsp` at 6.333 ns = 5 % tighter than 150 MHz, `clk_pix` at 6.4 ns = 5 % tighter than 148.5 MHz,
clocks asynchronous; `res.sh` and `gen_wrap.py` got a `--clk2` option for this). Block alone, wrapper subtracted:

| | Used | Of chip |
|---|---|---|
| Logic (LUT, ALU, LUT RAM) | 4,007 | 2.9 % |
| Registers | 8,179 | 5.9 % (about 5,700 of them are the two copies of the frame description, 1,000 more the delay lines) |
| DSP | 3.5 | 1.2 % (the trace multiplier, three blend multipliers, the line-address multiplier) |
| Block RAM (18 kbit) | 19 | 5.6 % |

Block RAM, measured (a 64-bit or 32-bit wide memory counts two blocks per 512 words, a 24-bit palette also two): Slint lines 4, the two waterfall line
buffers 4 each = 8, spectrum snapshot 2, palettes 2, register read-back 2, one delay line (Slint pixel and key flag, 17 bits x 25) 1 = 19. That is 7 more than the 12 planned
(the plan had counted the palette and read-back as one block each, the waterfall lines as 2 each, and had no snapshot). If the chip needs blocks back: waterfall
lines as one 512 x 64 memory shared by both windows is not possible (two readers), but a palette of 18-bit colour (1 block), a read-back RAM
narrowed to the 24 bits that matter (1 block) and the delay line in registers (-1 block, +425 registers) are each a small change.

Timing, last run (the one before it, with the same pixel logic, was clean at 174.6 MHz): `clk_dsp` 160.5 MHz against 157.9, no failing end point. `clk_pix` **152.2 MHz against
156.25 (6.4 ns): 2 failing end points, worst -0.17 ns**; at the real 148.5 MHz (6.73 ns) the same path has +0.5 ns. The path is the passband colour select (3-bit index
through an 8:1 mux of 24 bits, 4 LUT levels, fan-out 12, `d_pbix` to `pbcol24`); the fix is to split that mux over two stages (one more latency stage, `LAT` 32). Hold: 0 failing.
Four earlier runs found and fixed: a part-select that built a 5,400-LUT shifter, enable nets of 30 to 50 loads in the fetch state machine and the register file,
a 32-bit counter, a decode that Gowin made into a 4-block ROM. No full-chip build was done.

## 9. Edit the top level needs (not done here: `rtl/top/sdr_top.v` is another worker's)

```verilog
wire [23:0] vid_rgb;                                  // new
sdr_hdmi_video #( ..., .EXT_RGB(1) ) u_hdmi (   // add the parameter
    ..., .rgb_ext(vid_rgb));                          // add the port
sdr_core u_core ( ..., .vid_rgb(vid_rgb));      // add the port
```
No new clocks or constraints: the crossings are toggles and gray codes between `clk_dsp` and `clk_pix`, already in separate
asynchronous groups in `sdr.sdc`. `gowin/p1/build.sh` and `sim/top/tb_sdr_core.v` have the four new files.

## 10. A ring and a scroll line per waterfall window (2026-10-12, branch `zoom`)

Before: one ring base (`wf_ring_base`) and one read-only scroll line (`wf_write_line`, moved by the full-band hardware
writer) for both waterfall windows, so a hardware waterfall and a CPU-written one could not be on screen together.

Now (`hw/regmap/video.toml`, block id version 2):

| Register | What |
|---|---|
| `wf_ring_base` 0x070, `wf_write_line` 0x074 (RO) | the **full-band hardware writer**: where it writes, the last line it finished |
| `wf_zoom_ring_base` 0x07C, `wf_zoom_write_line` 0x094 (RO) | the same for the **zoom hardware writer** |
| `wf_win_ring[i]` 0x0A0 + 0x10 i | waterfall window i (0, 1): lane-word address of the ring it shows |
| `wf_win_ctrl[i].line_src` 0x0A4 + 0x10 i | its scroll line: 0 = full-band writer's, 1 = zoom writer's, 2 = `wf_win_line[i]` (CPU) |
| `wf_win_line[i]` 0x0A8 + 0x10 i | the scroll line the CPU writes (a software waterfall) |
| `wf_win_top[i]` 0x0AC + 0x10 i (RO) | the line the window shows in its top row in this frame (replaces `wf_top_line`) |

The line is selected in the register file and goes, with the ring base, into the per-frame description (`CF_WFRING`, `CF_WLTOP`
now hold two values each), so ring, line source and line change together at the vertical blank. The fetch engine's two waterfall
jobs each take their own pair; the pixel side is unchanged. Cost: 32 + 32 + 22 + 4 register bits in the register file, 43 more
bits in each of the two frame copies; no block RAM, no DSP. The reset state shows ring address 0 with the full-band writer's line.

`tb_compositor`: window 0 on ring A with the full-band writer's line, window 1 on ring B with a CPU line; a CPU line written
mid-frame shows in the next frame only; then window 0 switched to the zoom writer's line and window 1 to ring A. 15,478 pixels,
0 errors.
