// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! `tr-sim` is meant to become a program for the PC that takes the samples of a real Hermes-Lite 2 or of a
//! recorded capture through the receiver model, `tr-dsp`, `tr-modes` and `tr-gui`, so that the whole radio
//! software can be tried out without the FPGA board (docs/ARCHITECTURE.md section 5, docs/PLAN.md). At the
//! moment this crate is only a placeholder: it prints its own name and has nothing else in it.

/// The name of the program, returned so that the placeholder has something to test.
fn placeholder() -> &'static str {
    "tr-sim"
}

fn main() {
    println!("{}", placeholder());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn placeholder_name() {
        assert_eq!(placeholder(), "tr-sim");
    }
}
