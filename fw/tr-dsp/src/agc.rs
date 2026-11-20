// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Attack/hang/decay AGC (automatic gain control), the classic three-stage receiver AGC: gain
//! drops fast when a signal appears (attack), holds while it is present or briefly gone (hang),
//! and recovers slowly in silence (decay) so noise between syllables/words is not pumped up.
//!
//! Runs sample-by-sample on the demodulated (real, audio-rate) or magnitude (pre-demod, IQ-rate)
//! signal, one [`Agc`] per receiver. Cost: one `libm::expf`-free exponential smoothing step per
//! sample (2 mul + 1 add on the fast path, an extra reciprocal only when the error term is
//! recomputed) plus a counter decrement while hanging.

/// Attack, hang and decay AGC for one receiver.
pub struct Agc {
    reference: f32,
    min_gain: f32,
    max_gain: f32,
    attack_alpha: f32,
    decay_alpha: f32,
    hang_samples: u32,
    gain: f32,
    hang_counter: u32,
}

impl Agc {
    /// `attack_ms`/`decay_ms` are exponential time constants (63% settling time) for gain
    /// dropping onto a stronger signal / recovering in silence; `hang_ms` is how long the gain
    /// holds after a signal drops before decay starts; `reference` is the target
    /// post-AGC amplitude; gain is clamped to `[min_gain, max_gain]`.
    pub fn new(
        sample_rate_hz: f32,
        attack_ms: f32,
        decay_ms: f32,
        hang_ms: f32,
        reference: f32,
        min_gain: f32,
        max_gain: f32,
    ) -> Self {
        let attack_alpha = time_const_to_alpha(attack_ms, sample_rate_hz);
        let decay_alpha = time_const_to_alpha(decay_ms, sample_rate_hz);
        let hang_samples = (hang_ms * 0.001 * sample_rate_hz).max(0.0) as u32;
        Agc {
            reference,
            min_gain,
            max_gain,
            attack_alpha,
            decay_alpha,
            hang_samples,
            gain: max_gain,
            hang_counter: 0,
        }
    }

    /// Feeds one magnitude sample, returns the (updated, already-clamped) gain to apply to it.
    pub fn process_mag(&mut self, mag: f32) -> f32 {
        let mag = mag.max(1e-9);
        let current = mag * self.gain;
        if current > self.reference {
            // Attack: move toward the gain that would put this sample exactly at the reference.
            let target = (self.reference / mag).clamp(self.min_gain, self.max_gain);
            self.gain += (target - self.gain) * self.attack_alpha;
            self.hang_counter = self.hang_samples;
        } else if self.hang_counter > 0 {
            self.hang_counter -= 1;
        } else {
            let target = (self.reference / mag).clamp(self.min_gain, self.max_gain);
            self.gain += (target - self.gain) * self.decay_alpha;
        }
        self.gain = self.gain.clamp(self.min_gain, self.max_gain);
        self.gain
    }

    /// Feeds one real (audio-rate) sample, returns it scaled by the updated gain.
    pub fn process(&mut self, sample: f32) -> f32 {
        let g = self.process_mag(libm::fabsf(sample));
        sample * g
    }

    /// The current gain.
    pub fn gain(&self) -> f32 {
        self.gain
    }
}

fn time_const_to_alpha(tc_ms: f32, sample_rate_hz: f32) -> f32 {
    let tc_samples = (tc_ms * 0.001 * sample_rate_hz).max(1e-6);
    1.0 - libm::expf(-1.0 / tc_samples)
}

#[cfg(test)]
mod tests {
    use super::*;

    const FS: f32 = 48_000.0;

    /// Attack: a step from a quiet signal to a loud one should bring the post-AGC level to the
    /// reference within about one `attack_ms` time constant (63%) and settle within a few.
    #[test]
    fn attack_time_matches_time_constant() {
        let attack_ms = 5.0;
        let mut agc = Agc::new(FS, attack_ms, 500.0, 200.0, 1.0, 0.01, 100.0);
        // Run in on a quiet signal first so gain sits at max (typical AGC start-up).
        for _ in 0..2000 {
            agc.process_mag(0.001);
        }
        assert!((agc.gain() - 100.0).abs() < 1.0, "gain should be pinned at max on a quiet signal");

        let loud = 2.0; // well above reference once gain settles near 1.0
        let start_gain = agc.gain();
        let target_gain = 1.0 / loud; // 0.5
        // "Settled" means within 5% of the full step (start_gain -> target_gain), the standard
        // settling-time convention, not within 5% of target_gain's own (much smaller) value,
        // which would demand many more time constants purely because target_gain is tiny next
        // to the pinned starting gain.
        let step = start_gain - target_gain;
        let mut settle_sample = None;
        let n = (0.05 * FS) as usize; // 50 ms, 10x the time constant
        for i in 0..n {
            let g = agc.process_mag(loud);
            if settle_sample.is_none() && (g - target_gain).abs() < 0.05 * step.abs() {
                settle_sample = Some(i);
            }
        }
        let settle_ms = settle_sample.expect("AGC never settled") as f32 / FS * 1000.0;
        std::println!("MEASURED AGC attack settle time: {settle_ms} ms (time constant {attack_ms} ms)");
        // 95% settling of a first-order exponential is about 3 time constants.
        assert!(
            settle_ms < 3.5 * attack_ms,
            "attack settle time {settle_ms} ms, expected well under {} ms",
            3.5 * attack_ms
        );
        assert!(settle_ms > 0.3 * attack_ms, "attack settled suspiciously fast: {settle_ms} ms");
    }

    /// Hang: after a loud signal stops, gain must not move for `hang_ms` before decay begins.
    #[test]
    fn hang_holds_gain_before_decay() {
        let hang_ms = 100.0;
        let mut agc = Agc::new(FS, 5.0, 500.0, hang_ms, 1.0, 0.01, 100.0);
        for _ in 0..2000 {
            agc.process_mag(2.0); // settle attacked-down
        }
        let gain_at_drop = agc.gain();
        let hang_samples = (hang_ms * 0.001 * FS) as usize;
        let mut max_dev_during_hang = 0.0f32;
        for _ in 0..hang_samples - 10 {
            let g = agc.process_mag(1e-6); // signal effectively gone
            max_dev_during_hang = max_dev_during_hang.max((g - gain_at_drop).abs());
        }
        std::println!("MEASURED AGC hang: gain held to within {max_dev_during_hang} over {hang_ms} ms hang interval");
        assert!(
            max_dev_during_hang < 1e-6,
            "gain moved by {max_dev_during_hang} during the hang interval"
        );
        // Well past the hang interval, gain should have started recovering toward max.
        for _ in 0..(0.05 * FS) as usize {
            agc.process_mag(1e-6);
        }
        assert!(agc.gain() > gain_at_drop + 0.01, "gain did not decay/recover after hang expired");
    }

    /// Decay: measure the time constant of the gain recovering toward max in silence after the
    /// hang interval, the same way as the attack test.
    #[test]
    fn decay_time_matches_time_constant() {
        let decay_ms = 300.0;
        let mut agc = Agc::new(FS, 5.0, decay_ms, 0.0, 1.0, 0.01, 100.0);
        for _ in 0..2000 {
            agc.process_mag(2.0); // attack down first
        }
        let start_gain = agc.gain();
        let target_gain = 100.0f32; // max, since input goes to ~silence
        let delta_at_63pct = (target_gain - start_gain) * 0.63;
        let mut settle_sample = None;
        let n = (2.0 * FS) as usize; // up to 2 s
        for i in 0..n {
            let g = agc.process_mag(1e-9);
            if settle_sample.is_none() && (g - start_gain) >= delta_at_63pct {
                settle_sample = Some(i);
            }
        }
        let settle_ms = settle_sample.expect("AGC never decayed") as f32 / FS * 1000.0;
        std::println!("MEASURED AGC decay 63% time: {settle_ms} ms (time constant {decay_ms} ms)");
        assert!(
            (settle_ms - decay_ms).abs() < 0.3 * decay_ms,
            "decay 63% time {settle_ms} ms, expected near {decay_ms} ms"
        );
    }
}
