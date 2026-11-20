// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
//! Host test of the front panel at both sizes: it renders the panel at 1920x1080 and at 1024x600
//! through the code path the firmware uses (`FramebufferPlatform` in src/platform.rs, the software
//! renderer, an `Rgb565Pixel` buffer) and writes each as a PNG to docs/img/ for a human to look at.
//! The panel is filled from `PanelState::demo()`.
//!
//! Besides the screenshots the test checks three things. A second render of the same state,
//! through a second and independently constructed window and component, must give a byte for byte
//! identical `Rgb565Pixel` buffer. This project has exactly one renderer everywhere
//! (docs/DECISIONS.md: no C/C++ GUI backends, so no GPU-accelerated desktop path exists to
//! compare against), and the claim worth checking is that the render is reproducible
//! (docs/S11_GUI.md has the longer explanation). The interior of the spectrum window, where the
//! FPGA draws, must still be exactly the compositor key color. And the digits of VFO A must
//! measure at least 44 px tall (1920x1080) or 28 px (1024x600) in the rendered buffer, which is
//! a pixel measurement and not just a check that something was drawn.
//!
//! The height check exists because of how Slint's software renderer finds its font sizes. It
//! pre-rasterizes glyph bitmaps at compile time (build.rs, `EmbedForSoftwareRenderer`) for the
//! sizes it sees written as literals. A size reached only through a property or a conditional
//! expression, such as `compact ? 34px : 58px`, is invisible to that scan, so no bitmap exists
//! for it and the renderer silently substitutes a small default. Every layout box keeps the right
//! size and nothing errors, but the ink on screen comes out around 8 px tall, which a PNG diff
//! would not catch. So every VFO A and B `font-size:` in `ui/components/frequency_display.slint`
//! is a bare literal on the `Text` element. The sizes asked for (64 px and 42 px at the two
//! panel sizes) are larger than the minimums above because a digit's ink height is only about
//! 70 % of the font's em size.
//!
//! Both sizes are rendered from one `#[test]` function, not two: `slint::platform::set_platform`
//! installs a single, process-wide platform, and the `unsafe-single-threaded` Slint feature this
//! crate builds with (Cargo.toml) means the whole render path assumes one thread. `cargo test`
//! runs `#[test]` functions in parallel by default, so two tests would race two threads over that
//! single platform.

use std::path::PathBuf;
use std::time::Instant;

use slint::platform::software_renderer::Rgb565Pixel;
use slint::ComponentHandle;
use tr_gui::platform::{new_window, render_rgb565, FramebufferPlatform};
use tr_gui::PanelState;

/// RGB565 to 8-bit RGB, the same widening every RGB565 framebuffer viewer does. The round trip
/// is not exact for green, which keeps 6 bits, because of the target pixel format and not
/// because of this test.
fn rgb565_to_rgb888(px: Rgb565Pixel) -> [u8; 3] {
    let v = px.0;
    let r5 = (v >> 11) & 0x1f;
    let g6 = (v >> 5) & 0x3f;
    let b5 = v & 0x1f;
    let r = (r5 << 3) | (r5 >> 2);
    let g = (g6 << 2) | (g6 >> 4);
    let b = (b5 << 3) | (b5 >> 2);
    [r as u8, g as u8, b as u8]
}

fn write_png(path: &std::path::Path, width: u32, height: u32, rgb: &[u8]) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let file = std::fs::File::create(path).unwrap_or_else(|e| panic!("creating {}: {e}", path.display()));
    let mut encoder = png::Encoder::new(std::io::BufWriter::new(file), width, height);
    encoder.set_color(png::ColorType::Rgb);
    encoder.set_depth(png::BitDepth::Eight);
    let mut writer = encoder.write_header().unwrap();
    writer.write_image_data(rgb).unwrap();
}

fn docs_img_dir() -> PathBuf {
    // fw/tr-gui/tests/ to the repository's shared docs/img, not a crate-local directory.
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../docs/img")
}

/// Counts pixels that are exactly the compositor key color (RGB565 0xF81F,
/// docs/ARCHITECTURE.md 3.5) within the given rectangle (x, y, width, height), to confirm the
/// FPGA windows really are left untouched.
fn count_key_colour(buffer: &[Rgb565Pixel], width: usize, rect: (usize, usize, usize, usize)) -> usize {
    let (x0, y0, w, h) = rect;
    let mut n = 0;
    for y in y0..y0 + h {
        for x in x0..x0 + w {
            if buffer[y * width + x].0 == 0xF81F {
                n += 1;
            }
        }
    }
    n
}

fn save_png(width: usize, height: usize, name: &str, buffer: &[Rgb565Pixel]) {
    let rgb: Vec<u8> = buffer.iter().flat_map(|p| rgb565_to_rgb888(*p)).collect();
    write_png(&docs_img_dir().join(name), width as u32, height as u32, &rgb);
}

/// The pixel-row span (inclusive) of "bright ink" (an approximately-white pixel, `Theme.text-
/// primary` = `#e6ecf5`) anywhere within `rect` (x, y, width, height), or `None` if there is
/// none. Used to measure how tall the rendered VFO A digits actually are, in pixels, as opposed
/// to what font size was asked for (see the module comment).
///
/// The threshold (every channel above 180/255) only matches `text-primary`. Every other color
/// used near the frequency display has at least one channel below it, checked against
/// `ui/components/theme.slint`: `Theme.accent` is blue with a green channel of 169, `Theme.text-dim`
/// is gray with every channel under 166, and the S-meter fill is amber or green. So a generously
/// sized `rect` cannot accidentally pick up some other label instead.
fn bright_ink_row_span(
    buffer: &[Rgb565Pixel],
    width: usize,
    rect: (usize, usize, usize, usize),
) -> Option<(usize, usize)> {
    let (x0, y0, w, h) = rect;
    let mut min_y = None;
    let mut max_y = None;
    for y in y0..y0 + h {
        let row_has_ink = (x0..x0 + w).any(|x| {
            let [r, g, b] = rgb565_to_rgb888(buffer[y * width + x]);
            r > 180 && g > 180 && b > 180
        });
        if row_has_ink {
            min_y.get_or_insert(y);
            max_y = Some(y);
        }
    }
    min_y.zip(max_y)
}

#[test]
fn renders_both_panel_sizes() {
    let start = Instant::now();
    FramebufferPlatform::install(move || start.elapsed())
        .expect("installing the Slint platform must only happen once per process");

    // --- 1920x1080 ---
    let width = 1920usize;
    let height = 1080usize;

    let window = new_window(width as u32, height as u32);
    let ui = tr_gui::size_1920x1080::MainWindow1920x1080::new().unwrap();
    tr_gui::size_1920x1080::apply_state(&ui, &PanelState::demo());
    ui.show().unwrap();
    slint::platform::update_timers_and_animations();
    let mut buffer = vec![Rgb565Pixel(0); width * height];
    let drew = render_rgb565(&window, &mut buffer, width);
    assert!(drew, "the freshly created 1920x1080 window should have needed a first redraw");
    ui.hide().unwrap();

    // Render the same state a second time, through a second, independently constructed window
    // and component (see the module comment for why this is the reproducibility check).
    let window2 = new_window(width as u32, height as u32);
    let ui2 = tr_gui::size_1920x1080::MainWindow1920x1080::new().unwrap();
    tr_gui::size_1920x1080::apply_state(&ui2, &PanelState::demo());
    ui2.show().unwrap();
    slint::platform::update_timers_and_animations();
    let mut buffer2 = vec![Rgb565Pixel(0); width * height];
    render_rgb565(&window2, &mut buffer2, width);
    ui2.hide().unwrap();
    assert!(
        buffer.iter().map(|p| p.0).eq(buffer2.iter().map(|p| p.0)),
        "1920x1080: a second render of the same state must be pixel-identical to the first"
    );

    // The interior of the (larger, top-left) spectrum FPGA window must still be exactly the key
    // color: nothing Slint draws may have painted over it (docs/ARCHITECTURE.md 3.5).
    let key_pixels = count_key_colour(&buffer, width, (100, 150, 400, 100));
    assert_eq!(key_pixels, 400 * 100, "1920x1080 spectrum FpgaWindow area must be untouched key colour");

    let background = buffer[0].0;
    let non_background = buffer.iter().filter(|p| p.0 != background).count();
    assert!(
        non_background > 10_000,
        "1920x1080: expected substantial drawn content, got {non_background} differing pixels"
    );

    // VFO A's digits must actually be big, not just asked to be (see the module comment). The
    // region covers the frequency display's "A" row and a margin either side; it does not need to
    // be pixel-exact (see `bright_ink_row_span` for why a generous region is still a precise test).
    let (min_y, max_y) = bright_ink_row_span(&buffer, width, (1470, 95, 380, 65))
        .expect("no bright VFO A digit pixels found in the frequency display at 1920x1080");
    let digit_height = max_y - min_y + 1;
    assert!(
        digit_height >= 44,
        "1920x1080: VFO A digits measured {digit_height}px tall, wanted >= 44px \
         (rows {min_y}..={max_y})"
    );

    save_png(width, height, "panel_1920x1080.png", &buffer);

    // --- 1024x600 ---
    let width = 1024usize;
    let height = 600usize;

    let window = new_window(width as u32, height as u32);
    let ui = tr_gui::size_1024x600::MainWindow1024x600::new().unwrap();
    tr_gui::size_1024x600::apply_state(&ui, &PanelState::demo());
    ui.show().unwrap();
    slint::platform::update_timers_and_animations();
    let mut buffer = vec![Rgb565Pixel(0); width * height];
    let drew = render_rgb565(&window, &mut buffer, width);
    assert!(drew, "the freshly created 1024x600 window should have needed a first redraw");
    ui.hide().unwrap();

    let window2 = new_window(width as u32, height as u32);
    let ui2 = tr_gui::size_1024x600::MainWindow1024x600::new().unwrap();
    tr_gui::size_1024x600::apply_state(&ui2, &PanelState::demo());
    ui2.show().unwrap();
    slint::platform::update_timers_and_animations();
    let mut buffer2 = vec![Rgb565Pixel(0); width * height];
    render_rgb565(&window2, &mut buffer2, width);
    ui2.hide().unwrap();
    assert!(
        buffer.iter().map(|p| p.0).eq(buffer2.iter().map(|p| p.0)),
        "1024x600: a second render of the same state must be pixel-identical to the first"
    );

    let background = buffer[0].0;
    let non_background = buffer.iter().filter(|p| p.0 != background).count();
    assert!(
        non_background > 5_000,
        "1024x600: expected substantial drawn content, got {non_background} differing pixels"
    );

    let (min_y, max_y) = bright_ink_row_span(&buffer, width, (480, 55, 540, 85))
        .expect("no bright VFO A digit pixels found in the frequency display at 1024x600");
    let digit_height = max_y - min_y + 1;
    assert!(
        digit_height >= 28,
        "1024x600: VFO A digits measured {digit_height}px tall, wanted >= 28px \
         (rows {min_y}..={max_y})"
    );

    save_png(width, height, "panel_1024x600.png", &buffer);
}
