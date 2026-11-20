<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# Toolchain setup

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

## Rust and QEMU

WP T4 (`docs/PLAN.md`). Pinned by `rust-toolchain.toml` at the repo root: rustup installs and uses
this toolchain automatically inside the repo, without changing the machine's global default
toolchain (`rustup default`, used by other projects on this PC).

- Toolchain: stable 1.93.0, with the `riscv32imafc-unknown-none-elf` target and the `rustfmt` and
  `clippy` components. Nothing to run by hand: the first `cargo` command in the repo (or any
  subdirectory of it, e.g. `fw/`) makes rustup install it. To pre-fetch it:

  ```sh
  rustup toolchain install 1.93.0 --profile minimal
  rustup target add riscv32imafc-unknown-none-elf --toolchain 1.93.0
  rustup component add rustfmt clippy --toolchain 1.93.0
  ```

  (`rust-toolchain.toml` does this on its own the first time `cargo`/`rustc`/`rustup` runs here;
  the commands above just do it ahead of time.) Verify with `rustup show` from inside the repo:
  it should report `1.93.0-x86_64-pc-windows-msvc` as the *active* toolchain, "overridden by"
  this repo's `rust-toolchain.toml`, while `rustup default` (the machine-wide default used
  elsewhere) is untouched.

- QEMU for RISC-V (`qemu-system-riscv32`), installed with scoop (already on this PC):

  ```sh
  scoop install qemu
  ```

  This installs the full QEMU suite (all targets, ~200 MB) and adds
  `~\scoop\apps\qemu\current` to the user `PATH`. Open a new shell after installing so it picks up
  the updated `PATH`. Verify with `qemu-system-riscv32 --version`.

Done-test (WP T4): from the repo root,

```sh
mkdir /tmp/t4check && cd /tmp/t4check
cat > Cargo.toml <<'EOF'
[package]
name = "t4check"
version = "0.1.0"
edition = "2021"
EOF
mkdir src && cat > src/main.rs <<'EOF'
#![no_std]
#![no_main]
use core::panic::PanicInfo;
#[panic_handler]
fn panic(_: &PanicInfo) -> ! { loop {} }
#[no_mangle]
pub extern "C" fn _start() -> ! { loop {} }
EOF
cp <repo>/rust-toolchain.toml .
cargo build --target riscv32imafc-unknown-none-elf
qemu-system-riscv32 --version
```

Both commands succeeded on 2026-09-25.

## Gowin EDA Standard (WP T1)

- Installed 2026-09-26: Gowin EDA **Standard** V1.9.11.03, from Gowin's own server
  (`https://cdn.gowinsemi.com.cn/Gowin_V1.9.11.03_x64_win.zip`, 513,376,130 bytes; it contains an NSIS
  installer). Silent install: `Gowin_V1.9.11.03_x64_win.exe /S /D=C:\Gowin\Gowin_V1.9.11.03_x64`
  (installs into `C:\Gowin\Gowin_V1.9.11.03_x64\Gowin_V1.9.11.03_x64`). The Education edition does not
  support the GW5AST-138 and stays installed alongside, unused for this project.
- Licence: Sipeed's public floating-licence server, set in `IDE/bin/gwlicense.ini`:
  ```
  [license]
  lic="106.55.34.119:10559"
  ```
  (original file kept as `gwlicense.ini.orig`). Source: Sipeed wiki, "Install the IDE". The server is
  shared and outside our control; the owner may apply for a personal licence at
  https://www.gowinsemi.com/en/support/license/.
- Verified 2026-09-26: a counter design for `GW5AST-LV138FPG676AC1/I0` (`set_device -name GW5AST-138C`)
  goes through synthesis, place-and-route and bitstream generation with `IDE/bin/gw_sh.exe run.tcl`
  (`run all`).
