// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Build script: compiles the root `.slint` files of the crate to Rust. There are six of them,
// the two front-panel sizes (1920x1080 and 1024x600), the FT8 operating screen
// (docs/P2_FT8_FW.md), the FreeDV screen, the LISTEN screen on its own for host tests
// (docs/LISTEN.md) and the application window the firmware shows (FT8 view or FreeDV view).
//
// Each `slint_build::compile_with_config` call writes `$OUT_DIR/<file-stem>.rs`, and src/lib.rs
// `include!`s every one of them by that fixed name. `slint::include_modules!()` is not used,
// because it only ever points at the last file compiled here and so cannot serve two files in
// one build.
//
// `EmbedForSoftwareRenderer` turns every image and font into raw pixel data at compile time,
// which is the format the software renderer needs, so no image decoder is needed at run time.

fn main() {
    let config = slint_build::CompilerConfiguration::new()
        .embed_resources(slint_build::EmbedResourcesKind::EmbedForSoftwareRenderer)
        .with_include_paths(vec!["ui/components".into()]);

    slint_build::compile_with_config("ui/panel_1920x1080.slint", config.clone())
        .expect("failed to compile ui/panel_1920x1080.slint");
    slint_build::compile_with_config("ui/panel_1024x600.slint", config.clone())
        .expect("failed to compile ui/panel_1024x600.slint");
    slint_build::compile_with_config("ui/ft8_1920x1080.slint", config.clone())
        .expect("failed to compile ui/ft8_1920x1080.slint");
    slint_build::compile_with_config("ui/fdv_1920x1080.slint", config.clone())
        .expect("failed to compile ui/fdv_1920x1080.slint");
    slint_build::compile_with_config("ui/listen_1920x1080.slint", config.clone())
        .expect("failed to compile ui/listen_1920x1080.slint");
    slint_build::compile_with_config("ui/app_1920x1080.slint", config)
        .expect("failed to compile ui/app_1920x1080.slint");
}
