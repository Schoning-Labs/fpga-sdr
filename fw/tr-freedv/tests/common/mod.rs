// SPDX-License-Identifier: LGPL-2.1-only
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Test signals shared by the tests and by `examples/fdvnoise.rs`, which makes the same files for
//! the reference programs (docs/FREEDV.md section 4): a fixed-seed channel and the transmitter.
#![allow(dead_code)]

use tr_freedv::ofdm::Mode;
use tr_freedv::varicode;
use tr_freedv::Tx;

/// Gaussian noise from a fixed-seed generator.
pub struct Noise(pub u64);
impl Noise {
    pub fn uniform(&mut self) -> f64 {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        ((self.0 >> 11) as f64 + 0.5) / (1u64 << 53) as f64
    }
    pub fn gauss(&mut self) -> f64 {
        (-2.0 * self.uniform().ln()).sqrt() * (2.0 * std::f64::consts::PI * self.uniform()).cos()
    }
}

/// The channel of the tests: frequency shift by `foff` Hz (single sideband, by a Hilbert
/// transformer), level scaled by `gain`, white noise for `snr_3k_db` in 3 kHz (None = no noise).
pub fn channel(x: &[i16], foff: f64, gain: f64, snr_3k_db: Option<f64>, seed: u64) -> Vec<i16> {
    // analytic signal: 127-tap Hilbert FIR
    const N: usize = 127;
    let h: Vec<f64> = (0..N)
        .map(|i| {
            let k = i as i64 - (N as i64 / 2);
            if k % 2 == 0 {
                0.0
            } else {
                let w = 0.54 - 0.46 * (2.0 * std::f64::consts::PI * i as f64 / (N as f64 - 1.0)).cos();
                2.0 / (std::f64::consts::PI * k as f64) * w
            }
        })
        .collect();
    let xf: Vec<f64> = x.iter().map(|&s| s as f64).collect();
    let power = xf.iter().map(|v| v * v).sum::<f64>() / xf.len() as f64;
    let sigma = snr_3k_db.map(|snr| (power / 10f64.powf(snr / 10.0) / 0.75).sqrt()).unwrap_or(0.0);
    let mut noise = Noise(seed);
    let mut out = Vec::with_capacity(x.len());
    for n in 0..x.len() {
        let re = if n >= N / 2 { xf[n - N / 2] } else { 0.0 };
        let mut im = 0.0;
        for (i, &c) in h.iter().enumerate() {
            if c != 0.0 && n >= i {
                im += c * xf[n - i];
            }
        }
        let a = 2.0 * std::f64::consts::PI * foff * n as f64 / 8000.0;
        let v = (re * a.cos() - im * a.sin() + sigma * noise.gauss()) * gain;
        out.push(v.clamp(-32768.0, 32767.0) as i16);
    }
    out
}

/// `seconds` of FreeDV test frames (the receiver knows their bits) from our modulator.
pub fn test_frame_signal(mode: &'static Mode, seconds: usize) -> Vec<i16> {
    let tx = Tx::new(mode);
    let spf = tx.samples_per_frame();
    let mut out = Vec::new();
    let mut frame = vec![0i16; spf];
    while out.len() < seconds * 8000 {
        tx.tx_test_frame(&mut frame);
        out.extend_from_slice(&frame);
    }
    out
}

/// Speech (8 kHz, 16 bit) through our encoder and modulator, with `text` sent over and over in
/// the text channel (varicode), `seconds` long.
pub fn speech_text_signal(mode: &'static Mode, speech: &[i16], text: &[u8], seconds: usize) -> Vec<i16> {
    let mut enc = tr_codec2::Encoder700c::new();
    let tx = Tx::new(mode);
    let per = tx.speech_per_frame();
    let spf = tx.samples_per_frame();
    let mut code_bits = Vec::new();
    for &c in text.iter() {
        let mut b = [0u8; varicode::MAX_BITS];
        let n = varicode::encode(c, &mut b);
        code_bits.extend_from_slice(&b[..n]);
    }
    let mut out = Vec::new();
    let (mut pos, mut tpos) = (0, 0);
    let ntxt = mode.ntxtbits;
    let mut frame = vec![0i16; spf];
    while out.len() < seconds * 8000 && pos + per <= speech.len() {
        let mut data = [0u8; 112];
        for (i, f) in speech[pos..pos + per].chunks_exact(320).enumerate() {
            let bytes = enc.encode(f.try_into().unwrap());
            for n in 0..28 {
                data[i * 28 + n] = (bytes[n >> 3] >> (7 - (n & 7))) & 1;
            }
        }
        let mut txt = [0u8; 4];
        for t in txt[..ntxt].iter_mut() {
            *t = code_bits[tpos % code_bits.len()];
            tpos += 1;
        }
        tx.tx_bits(&data, &txt[..ntxt], &mut frame);
        out.extend_from_slice(&frame);
        pos += per;
    }
    out
}
