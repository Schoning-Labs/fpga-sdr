// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Standard FT8 messages as the station logic needs them: what a decoded text says, and the three
//! fields of what we send.

use alloc::format;
use alloc::string::{String, ToString};

/// Third field of a message between two stations.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Payload {
    /// 4-character locator.
    Grid(String),
    /// Signal report in dB.
    Report(i8),
    /// "R" + report: yours received, here is mine.
    RReport(i8),
    /// "RRR": roger, roger, roger.
    Rrr,
    /// "RR73": roger and goodbye.
    Rr73,
    /// "73": goodbye.
    S73,
    /// No third field.
    Empty,
}

/// What a decoded message says.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Parsed {
    /// "CQ K1ABC FN42", "CQ DX K1ABC FN42"
    Cq { caller: String, grid: Option<String> },
    /// "K1ABC W9XYZ R-09": `from` to `to`
    Directed { to: String, from: String, payload: Payload },
    /// Free text, telemetry, contest forms: shown, never acted on.
    Other,
}

/// A four-character Maidenhead locator: two letters A to R, two digits.
fn is_grid(s: &str) -> bool {
    let b = s.as_bytes();
    b.len() == 4 && (b'A'..=b'R').contains(&b[0]) && (b'A'..=b'R').contains(&b[1]) && b[2].is_ascii_digit() && b[3].is_ascii_digit()
}

/// A signal report such as "-07" or "+12": a sign and one or two digits.
fn report(s: &str) -> Option<i8> {
    let b = s.as_bytes();
    if !(2..=3).contains(&b.len()) || !(b[0] == b'+' || b[0] == b'-') || !b[1..].iter().all(u8::is_ascii_digit) {
        return None;
    }
    s.parse().ok()
}

/// A call as it is compared and sent: without the angle brackets of a hashed call.
fn call(s: &str) -> String {
    s.trim_matches(|c| c == '<' || c == '>').to_string()
}

/// True for 3 to 11 characters of capital letters, digits and "/" with at least one of each letter and digit. Not a full call sign check.
fn looks_like_call(s: &str) -> bool {
    let s = s.trim_matches(|c| c == '<' || c == '>');
    (3..=11).contains(&s.len()) && s.bytes().any(|c| c.is_ascii_digit()) && s.bytes().any(|c| c.is_ascii_uppercase()) && s.bytes().all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == b'/')
}

/// Sorts a decoded message into a CQ, a message from one station to another, or something else.
/// Only the standard forms are understood; hashed calls in angle brackets are accepted and the brackets dropped.
pub fn parse(text: &str) -> Parsed {
    let mut it = text.split_ascii_whitespace();
    let t: [Option<&str>; 5] = [it.next(), it.next(), it.next(), it.next(), it.next()];
    match t {
        [Some("CQ"), Some(c), None, ..] if looks_like_call(c) => Parsed::Cq { caller: call(c), grid: None },
        [Some("CQ"), Some(c), Some(g), None, ..] if looks_like_call(c) && is_grid(g) => Parsed::Cq { caller: call(c), grid: Some(g.to_string()) },
        // "CQ DX K1ABC FN42", "CQ POTA K1ABC FN42": a word of letters between CQ and the call
        [Some("CQ"), Some(m), Some(c), g, None] if m.len() <= 4 && m.bytes().all(|x| x.is_ascii_uppercase()) && looks_like_call(c) => {
            Parsed::Cq { caller: call(c), grid: g.filter(|g| is_grid(g)).map(str::to_string) }
        }
        [Some(to), Some(from), third, None, ..] if looks_like_call(to) && looks_like_call(from) => {
            let payload = match third {
                None => Payload::Empty,
                Some("RRR") => Payload::Rrr,
                Some("RR73") => Payload::Rr73,
                Some("73") => Payload::S73,
                Some(s) => {
                    if let Some(r) = report(s) {
                        Payload::Report(r)
                    } else if let Some(r) = s.strip_prefix('R').and_then(report) {
                        Payload::RReport(r)
                    } else if is_grid(s) {
                        Payload::Grid(s.to_string())
                    } else {
                        return Parsed::Other;
                    }
                }
            };
            Parsed::Directed { to: call(to), from: call(from), payload }
        }
        _ => Parsed::Other,
    }
}

/// "-07", "+03": a report as it is sent, held to the range every decoder shows.
pub fn report_text(snr_db: i8) -> String {
    format!("{:+03}", snr_db.clamp(-30, 30))
}

/// A message we send, as the three fields the encoder packs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TxMessage {
    /// First field: the called station, or "CQ".
    pub f1: String,
    /// Second field: the sender's call sign.
    pub f2: String,
    /// Third field: locator, report, RR73 or 73. May be empty.
    pub f3: String,
}

impl TxMessage {
    /// A message from its three fields.
    pub fn new(f1: &str, f2: &str, f3: &str) -> Self {
        TxMessage { f1: f1.to_string(), f2: f2.to_string(), f3: f3.to_string() }
    }

    /// The message as it is displayed, fields separated by a space.
    pub fn text(&self) -> String {
        if self.f3.is_empty() {
            format!("{} {}", self.f1, self.f2)
        } else {
            format!("{} {} {}", self.f1, self.f2, self.f3)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(to: &str, from: &str, p: Payload) -> Parsed {
        Parsed::Directed { to: to.to_string(), from: from.to_string(), payload: p }
    }

    #[test]
    fn parses_the_standard_forms() {
        assert_eq!(parse("CQ K1ABC FN42"), Parsed::Cq { caller: "K1ABC".into(), grid: Some("FN42".into()) });
        assert_eq!(parse("CQ DX JA1XYZ PM95"), Parsed::Cq { caller: "JA1XYZ".into(), grid: Some("PM95".into()) });
        assert_eq!(parse("CQ PJ4/K1ABC"), Parsed::Cq { caller: "PJ4/K1ABC".into(), grid: None });
        assert_eq!(parse("K1ABC W9XYZ EN37"), d("K1ABC", "W9XYZ", Payload::Grid("EN37".into())));
        assert_eq!(parse("W9XYZ K1ABC -11"), d("W9XYZ", "K1ABC", Payload::Report(-11)));
        assert_eq!(parse("K1ABC W9XYZ R+05"), d("K1ABC", "W9XYZ", Payload::RReport(5)));
        assert_eq!(parse("W9XYZ K1ABC RR73"), d("W9XYZ", "K1ABC", Payload::Rr73));
        assert_eq!(parse("W9XYZ K1ABC RRR"), d("W9XYZ", "K1ABC", Payload::Rrr));
        assert_eq!(parse("K1ABC W9XYZ 73"), d("K1ABC", "W9XYZ", Payload::S73));
        assert_eq!(parse("K1ABC W9XYZ"), d("K1ABC", "W9XYZ", Payload::Empty));
        assert_eq!(parse("<PJ4/K1ABC> W9XYZ -03"), d("PJ4/K1ABC", "W9XYZ", Payload::Report(-3)));
        assert_eq!(parse("TNX BOB 73 GL"), Parsed::Other);
        assert_eq!(parse("K1ABC W9XYZ 579 MA"), Parsed::Other);
        assert_eq!(parse(""), Parsed::Other);
    }

    #[test]
    fn reports_and_text() {
        assert_eq!(report_text(-7), "-07");
        assert_eq!(report_text(3), "+03");
        assert_eq!(report_text(0), "+00");
        assert_eq!(report_text(-45), "-30");
        assert_eq!(TxMessage::new("CQ", "K1XYZ", "FN42").text(), "CQ K1XYZ FN42");
        assert_eq!(TxMessage::new("K1ABC", "K1XYZ", "").text(), "K1ABC K1XYZ");
    }
}
