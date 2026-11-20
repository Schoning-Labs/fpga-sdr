// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! `tr-vita49` is meant to become the encoder for VITA-49.2 packets, the format of the data streams and context
//! packets that the radio sends over the network (docs/DECISIONS.md, docs/PLAN.md). At the moment this crate is
//! only a placeholder and contains no encoder yet.

/// The name of the crate, returned so that the placeholder has something to test.
pub fn placeholder() -> &'static str {
    "tr-vita49"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn placeholder_name() {
        assert_eq!(placeholder(), "tr-vita49");
    }
}
