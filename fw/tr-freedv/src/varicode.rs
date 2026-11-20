// SPDX-License-Identifier: LGPL-2.1-only
//
// Rust translation of parts of Codec 2 release 1.2.0 (https://github.com/drowe67/codec2):
// src/varicode.c (code 1: varicode_encode1, varicode_decode1, decode_one_bit), and the table
// src/varicode_table.h (the PSK31 varicode; Clint Turner KA7OEI after Peter Martinez G3PLX).
// Copyright (C) 2012-2020 David Rowe. All rights reserved.
// Modified 2026 by Franz Schöning, https://www.schoning.com: translated from C to Rust.
//
// This program is free software; you can redistribute it and/or modify it under the terms of
// the GNU Lesser General Public License version 2.1, as published by the Free Software
// Foundation. This program is distributed in the hope that it will be useful, but WITHOUT ANY
// WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
// PURPOSE. See the GNU Lesser General Public License for more details.

//! The text channel of FreeDV 700D/700E: a few bits per modem frame ([`crate::Rx::txt_bits`], 4 in
//! 700D, 2 in 700E) carry ASCII text, mostly the sender's call sign, in the PSK31 varicode (code 1
//! of the reference implementation, the one it starts with and the FreeDV program uses). Each
//! character is a bit pattern starting and ending with a 1; two zeros in a row end it. The bits are
//! not error corrected, so a character is sometimes lost or wrong.
//!
//! Not translated: code 2 (the short code, two bits at a time) and code 3 (raw bits).

/// Longest code of a character plus the two zeros after it.
pub const MAX_BITS: usize = 12;

pub static TABLE: [u16; 128] = [
    0xAAC0, 0xB6C0, 0xBB40, 0xDDC0, 0xBAC0, 0xD7C0, 0xBBC0, 0xBF40,
    0xBFC0, 0xEF00, 0xE800, 0xDBC0, 0xB740, 0xF800, 0xDD40, 0xEAC0,
    0xBDC0, 0xBD40, 0xEB40, 0xEBC0, 0xD6C0, 0xDAC0, 0xDB40, 0xD5C0,
    0xDEC0, 0xDF40, 0xEDC0, 0xD540, 0xD740, 0xEEC0, 0xBEC0, 0xDFC0,
    0x8000, 0xFF80, 0xAF80, 0xFA80, 0xED80, 0xB540, 0xAEC0, 0xBF80,
    0xFB00, 0xF700, 0xB780, 0xEF80, 0xEA00, 0xD400, 0xAE00, 0xD780,
    0xB700, 0xBD00, 0xED00, 0xFF00, 0xBB80, 0xAD80, 0xB580, 0xD680,
    0xD580, 0xDB80, 0xF500, 0xDE80, 0xF680, 0xAA00, 0xEB80, 0xABC0,
    0xAF40, 0xFA00, 0xEB00, 0xAD00, 0xB500, 0xEE00, 0xDB00, 0xFD00,
    0xAA80, 0xFE00, 0xFE80, 0xBE80, 0xD700, 0xBB00, 0xDD00, 0xAB00,
    0xD500, 0xEE80, 0xAF00, 0xDE00, 0xDA00, 0xAB80, 0xDA80, 0xAE80,
    0xBA80, 0xBD80, 0xAB40, 0xFB80, 0xF780, 0xFD80, 0xAFC0, 0xB680,
    0xB7C0, 0xB000, 0xBE00, 0xBC00, 0xB400, 0xC000, 0xF400, 0xB600,
    0xAC00, 0xD000, 0xF580, 0xBF00, 0xD800, 0xEC00, 0xF000, 0xE000,
    0xFC00, 0xDF80, 0xA800, 0xB800, 0xA000, 0xDC00, 0xF600, 0xD600,
    0xDF00, 0xBA00, 0xEA80, 0xADC0, 0xDD80, 0xAD40, 0xB5C0, 0xED40,
];

/// Bits of the code of `c` (0 to 127; anything else is sent as a space) with the two zeros that
/// end it, one per byte, written to `out`; returns how many. This is the transmit side
/// (`varicode_encode1`): the receiver tests use it, transmit will.
pub fn encode(c: u8, out: &mut [u8; MAX_BITS]) -> usize {
    let c = if c >= 128 { b' ' } else { c };
    let mut packed = TABLE[c as usize];
    let (mut n, mut zeros) = (0, 0);
    while zeros < 2 && n <= MAX_BITS {
        if packed & 0x8000 != 0 {
            out[n] = 1;
            zeros = 0;
        } else {
            out[n] = 0;
            zeros += 1;
        }
        packed <<= 1;
        n += 1;
    }
    n
}

/// The receive side (`varicode_decode1` with its state): feed it the text bits one at a time.
#[derive(Clone, Copy, Debug, Default)]
pub struct Decoder {
    /// Inside a code (a 1 has been seen).
    started: bool,
    n_zeros: u8,
    v_len: u8,
    packed: u16,
}

impl Decoder {
    pub const fn new() -> Self {
        Self { started: false, n_zeros: 0, v_len: 0, packed: 0 }
    }

    fn reset(&mut self) {
        *self = Self::new();
    }

    /// One bit (0 or 1); returns the character when this bit completes one.
    pub fn push_bit(&mut self, bit: u8) -> Option<u8> {
        if !self.started {
            if bit == 0 {
                return None;
            }
            self.started = true;
        }
        if bit != 0 {
            // A code longer than 16 bits only comes from bit errors; it is dropped below.
            if self.v_len < 16 {
                self.packed |= 0x8000 >> self.v_len;
            }
            self.n_zeros = 0;
        } else {
            self.n_zeros += 1;
        }
        self.v_len += 1;
        let mut found = None;
        if self.n_zeros == 2 {
            // End of the code; with bit errors there may be no match.
            for (i, &t) in TABLE.iter().enumerate() {
                if t == self.packed {
                    found = Some(i as u8);
                }
            }
            self.reset();
        } else if self.v_len as usize > MAX_BITS {
            // Too long: a bit error. Start again.
            self.reset();
        }
        found
    }

    /// The text bits of one modem frame (one bit per byte); `sink` gets each character completed.
    pub fn push_bits(&mut self, bits: &[u8], mut sink: impl FnMut(u8)) {
        for &b in bits {
            if let Some(c) = self.push_bit(b & 1) {
                sink(c);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    extern crate std;
    use super::*;
    use std::vec::Vec;

    fn send(text: &str) -> Vec<u8> {
        let mut bits = Vec::new();
        for c in text.bytes() {
            let mut b = [0u8; MAX_BITS];
            let n = encode(c, &mut b);
            bits.extend_from_slice(&b[..n]);
        }
        bits
    }

    fn receive(bits: &[u8], chunk: usize) -> Vec<u8> {
        let mut d = Decoder::new();
        let mut out = Vec::new();
        for c in bits.chunks(chunk) {
            d.push_bits(c, |ch| out.push(ch));
        }
        out
    }

    #[test]
    fn every_character_round_trips() {
        let all: Vec<u8> = (0..128).collect();
        let mut bits = Vec::new();
        for &c in &all {
            let mut b = [0u8; MAX_BITS];
            let n = encode(c, &mut b);
            assert!(n >= 3 && n <= MAX_BITS && b[n - 1] == 0 && b[n - 2] == 0 && b[0] == 1);
            bits.extend_from_slice(&b[..n]);
        }
        assert_eq!(receive(&bits, 1), all);
    }

    #[test]
    fn known_codes_of_the_psk31_table() {
        // 'e' is 11, space is 1, 'a' is 1011 (PSK31): with the two end zeros
        let code = |c: u8| {
            let mut b = [0u8; MAX_BITS];
            let n = encode(c, &mut b);
            b[..n].to_vec()
        };
        assert_eq!(code(b'e'), [1, 1, 0, 0]);
        assert_eq!(code(b' '), [1, 0, 0]);
        assert_eq!(code(b'a'), [1, 0, 1, 1, 0, 0]);
        assert_eq!(code(200), [1, 0, 0], "above 127: a space");
    }

    #[test]
    fn text_in_frames_of_two_and_four_bits() {
        let text = "CQ CQ de VK5DGR";
        let mut bits = send(text);
        // idle: the transmitter sends zeros when it has nothing to say
        bits.extend_from_slice(&[0; 30]);
        for chunk in [1, 2, 4, 7] {
            assert_eq!(receive(&bits, chunk), text.as_bytes(), "chunks of {chunk}");
        }
    }

    #[test]
    fn a_bit_error_costs_a_character_not_the_text() {
        let text = "K1XYZ K1XYZ K1XYZ";
        let mut bits = send(text);
        // flip a bit inside the second character
        let first = send("K").len();
        bits[first + 2] ^= 1;
        let got = receive(&bits, 4);
        assert!(got.len() >= text.len() - 2 && got.len() <= text.len() + 1);
        assert_eq!(got.last(), Some(&b'Z'));
        assert!(got.ends_with(b"K1XYZ K1XYZ"), "{}", std::string::String::from_utf8_lossy(&got));
        let mut d = Decoder::new();
        // a long run of ones is a code that never ends: dropped, the decoder restarts
        let mut out = Vec::new();
        d.push_bits(&[1; 40], |c| out.push(c));
        d.push_bits(&[0; 4], |c| out.push(c));
        d.push_bits(&send("OK"), |c| out.push(c));
        assert!(out.ends_with(b"OK") && out.len() <= 3, "{out:?}");
    }
}
