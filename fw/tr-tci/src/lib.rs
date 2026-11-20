// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! `tr-tci` is meant to become the TCI 2.0 server, which speaks the TCI protocol over WebSocket so that logging
//! and digital-mode programs such as WSJT-X can control the radio over the network (docs/ARCHITECTURE.md,
//! docs/PLAN.md). At the moment this crate is only a placeholder and contains no server yet.

/// The name of the crate, returned so that the placeholder has something to test.
pub fn placeholder() -> &'static str {
    "tr-tci"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn placeholder_name() {
        assert_eq!(placeholder(), "tr-tci");
    }
}
