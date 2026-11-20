// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Text form of mfsk-core's per-candidate [`Ft8Effort`], for the host tool, the QEMU trace
//! script and the scheduler's settings.
//!
//! A spec starts from `Ft8Effort::FULL` (four LLR variants, eight OSD searches per failed
//! candidate, npre2 for nsync >= 18, blind-CQ a-priori pass with belief propagation and OSD) and
//! applies comma-separated changes:
//!
//! | Token | Meaning |
//! |---|---|
//! | `full` | no change |
//! | `none` | no OSD anywhere (a-priori pass by belief propagation only) |
//! | `osd=abcd` / `osd=d` / `osd=-` | LLR variants OSD runs on (`-`: none) |
//! | `seeds=12` / `seeds=1` / `seeds=2` | BP-refined OSD seeds (one or two BP iterations) |
//! | `npre2=0` / `npre2=1` | the deeper npre2 search for nsync >= 18 |
//! | `cq=off` / `cq=bp` / `cq=osd` / `cq=bposd` | blind-CQ a-priori pass and its rungs |
//! | `apvar=abcd` | LLR variants the a-priori passes use |
//! | `llr=min` / `llr=full` | LLR variants for belief propagation (a, d / a, b, c, d) |
//! | `kernel=ref` / `kernel=packed` | OSD kernels: mfsk-core's reference or the bit-packed ones (same results) |
//! | `apbp=ms` / `apbp=sp` | belief propagation in the a-priori passes: min-sum (the default) or WSJT-X's sum-product |

use alloc::format;
use alloc::string::String;
use alloc::vec::Vec;

use mfsk_core::engine::pipeline::LlrEffort;
use mfsk_core::ft8::decode_block::Ft8Effort;

/// Parses LLR variant letters (`a` to `d`, or `-` for none) into a bit mask, `a` being bit 0.
fn variants(v: &str) -> Result<u8, String> {
    if v == "-" {
        return Ok(0);
    }
    let mut m = 0u8;
    for c in v.chars() {
        m |= match c {
            'a' => 1,
            'b' => 2,
            'c' => 4,
            'd' => 8,
            _ => return Err(format!("variant '{c}' (use a, b, c, d or -)")),
        };
    }
    Ok(m)
}

/// The letters of the variants in the mask `m` (`-` for none), the inverse of `variants`.
fn variant_letters(m: u8) -> String {
    if m & 0xF == 0 {
        return String::from("-");
    }
    "abcd".chars().enumerate().filter(|(i, _)| m & (1 << i) != 0).map(|(_, c)| c).collect()
}

/// Parses a spec (see the module documentation), or says which token it did not understand.
pub fn parse_effort(spec: &str) -> Result<Ft8Effort, String> {
    let mut e = Ft8Effort::FULL;
    for tok in spec.split(',').map(str::trim).filter(|t| !t.is_empty()) {
        let (k, v) = tok.split_once('=').unwrap_or((tok, ""));
        match k {
            "full" => {}
            "none" => {
                e.osd_variants = 0;
                e.ap_osd = false;
            }
            "osd" => e.osd_variants = variants(v)?,
            "seeds" => {
                e.osd_seeds = match v {
                    "12" | "21" => 0b11,
                    "1" => 0b01,
                    "2" => 0b10,
                    _ => return Err(format!("seeds={v} (use 1, 2 or 12)")),
                }
            }
            "npre2" => e.osd_npre2 = v != "0",
            "cq" => {
                let (on, bp, osd) = match v {
                    "off" => (false, false, false),
                    "bp" => (true, true, false),
                    "osd" => (true, false, true),
                    "bposd" => (true, true, true),
                    _ => return Err(format!("cq={v} (use off, bp, osd or bposd)")),
                };
                e.ap_blind_cq = on;
                e.ap_bp = bp;
                e.ap_osd = osd;
            }
            "apvar" => e.ap_variants = variants(v)?,
            "kernel" => {
                e.osd_packed = match v {
                    "ref" => false,
                    "packed" => true,
                    _ => return Err(format!("kernel={v} (use ref or packed)")),
                }
            }
            "apbp" => {
                e.ap_min_sum = match v {
                    "ms" => true,
                    "sp" => false,
                    _ => return Err(format!("apbp={v} (use ms or sp)")),
                }
            }
            "llr" => {
                e.llr_effort = match v {
                    "min" => LlrEffort::Minimal,
                    "full" => LlrEffort::Full,
                    _ => return Err(format!("llr={v} (use min or full)")),
                }
            }
            _ => return Err(format!("unknown effort token '{tok}'")),
        }
    }
    Ok(e)
}

/// Canonical spec of an effort, which parses back to the same effort.
pub fn effort_spec(e: &Ft8Effort) -> String {
    let seeds = match e.osd_seeds & 3 {
        0b11 => "12",
        0b01 => "1",
        0b10 => "2",
        _ => "-",
    };
    let cq = match (e.ap_blind_cq, e.ap_bp, e.ap_osd) {
        (false, _, _) => "off",
        (true, true, false) => "bp",
        (true, false, true) => "osd",
        (true, true, true) => "bposd",
        (true, false, false) => "off",
    };
    let mut parts: Vec<String> = Vec::new();
    parts.push(format!("osd={}", variant_letters(e.osd_variants)));
    parts.push(format!("seeds={seeds}"));
    parts.push(format!("npre2={}", e.osd_npre2 as u8));
    parts.push(format!("cq={cq}"));
    if e.ap_variants & 0xF != 0xF {
        parts.push(format!("apvar={}", variant_letters(e.ap_variants)));
    }
    if e.llr_effort == LlrEffort::Minimal {
        parts.push(String::from("llr=min"));
    }
    if !e.osd_packed {
        parts.push(String::from("kernel=ref"));
    }
    if !e.ap_min_sum {
        parts.push(String::from("apbp=sp"));
    }
    parts.join(",")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn specs_round_trip() {
        assert_eq!(parse_effort("full").unwrap(), Ft8Effort::FULL);
        let none = parse_effort("none").unwrap();
        assert_eq!(none.osd_searches_max(), 0);
        assert!(!none.ap_osd && none.ap_bp && none.ap_blind_cq);
        assert_eq!(none, Ft8Effort::BP_ONLY);
        for s in ["osd=d,seeds=2,npre2=0,cq=bp", "osd=ad,seeds=12,npre2=1,cq=off", "osd=-,seeds=1,npre2=0,cq=osd,apvar=d,llr=min,kernel=ref", "full,apbp=sp"] {
            let e = parse_effort(s).unwrap();
            assert_eq!(parse_effort(&effort_spec(&e)).unwrap(), e, "{s}");
        }
        assert_eq!(parse_effort("osd=d,seeds=2").unwrap().osd_searches_max(), 1);
        assert!(parse_effort("osd=x").is_err());
    }
}
