// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

#![cfg_attr(not(feature = "std"), no_std)]

//! Boot image format shared by the stage-0 loader (`fw/tr-loader`), the packer
//! (`cargo run -p xtask -- image`, `fw/xtask/src/image.rs`) and the PC-side sender
//! (`fw/tr-loader-send`). See docs/C2_LOADER.md "Image format" for the rationale.
//!
//! An image on disk or on the wire is exactly `HEADER_LEN` header bytes immediately followed by
//! `header.length` payload bytes. Every multi-byte field is little-endian, which is the native
//! byte order of both the host PC and the AE350 (and QEMU) RV32 target, so neither side has to
//! swap bytes.
//!
//! The 28-byte header, byte by byte:
//!
//! | Offset | Field | Meaning |
//! |---|---|---|
//! | 0 | `magic` (u32) | the bytes "TRLD" |
//! | 4 | `version` (u16) | 1 |
//! | 6 | `flags` (u16) | reserved, 0 |
//! | 8 | `load_addr` (u32) | where the payload is copied to |
//! | 12 | `entry` (u32) | where execution starts |
//! | 16 | `length` (u32) | payload size in bytes |
//! | 20 | `payload_crc32` (u32) | CRC32 of the payload |
//! | 24 | `header_crc32` (u32) | CRC32 of bytes 0..24 |
//!
//! The crate is `no_std` so the loader can use it, and its `std` feature adds [`host::pack`] for
//! the PC-side tools.

/// On-wire magic, chosen so a hex dump of the first 4 bytes of any packed image reads "TRLD"
/// (Radio LoaDer), which a person can recognize, rather than an opaque number.
pub const MAGIC: u32 = u32::from_le_bytes(*b"TRLD");

/// Current header format version. If the layout ever changes this is bumped, and `from_bytes`
/// keeps rejecting every other version explicitly instead of silently misreading the fields.
pub const VERSION: u16 = 1;

/// Header size in bytes, fixed for `VERSION` 1. `ImageHeader::to_bytes` and `from_bytes` are the
/// only places this layout is encoded, so nothing relies on Rust's `repr(C)` layout rules or on
/// transmuting bytes from the wire, and the host (x86_64) and the target (riscv32) agree
/// byte for byte whatever the compilers do with the struct itself.
pub const HEADER_LEN: usize = 28;

/// A parsed, not-yet-validated image header. Field order matches the on-wire layout (see
/// `to_bytes`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ImageHeader {
    /// Must equal [`MAGIC`] for the header to be considered present at all (checked before
    /// `header_crc32`, so a garbled magic is reported as "not an image" rather than "bad crc").
    pub magic: u32,
    /// Must equal [`VERSION`]; a mismatch is reported distinctly from a CRC failure so a future
    /// format change fails loudly instead of being treated as data corruption.
    pub version: u16,
    /// Reserved for future use (for example compression or signing) and 0 for `VERSION` 1. The
    /// choice between running an image and writing it to flash is not made here, because it is
    /// made at transfer time by a separate command byte (docs/C2_LOADER.md "Protocol").
    pub flags: u16,
    /// Destination address the payload is copied to (in DDR3 on the real board, see
    /// docs/C2_LOADER.md "Flash layout").
    pub load_addr: u32,
    /// Address execution jumps to once the payload is in place and its CRC checks out. Usually
    /// this equals `load_addr` (the payload starts with its own entry point), but it is a separate
    /// field so a payload whose real entry is not its first byte (for example the `e_entry` of
    /// an ELF file) still works.
    pub entry: u32,
    /// Payload length in bytes, immediately following the header on disk/wire.
    pub length: u32,
    /// CRC32 (see [`crc32`]) of the `length` payload bytes.
    pub payload_crc32: u32,
    /// CRC32 of this header's preceding 24 bytes (`magic` through `payload_crc32`), so a
    /// corrupted header -- in particular a corrupted `length` or `load_addr` -- is caught before
    /// it is trusted to size a receive buffer or pick a destination address.
    pub header_crc32: u32,
}

/// Why [`ImageHeader::validate_payload`] or [`ImageHeader::from_bytes`] rejected an image. Each
/// variant prints as its own specific message (see the `Display` impl below and
/// `fw/tr-loader/src/protocol.rs`), so a corrupt image is refused with a clear reason on the
/// console instead of one generic "invalid image".
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ImageError {
    /// Fewer than `HEADER_LEN` bytes were given to `from_bytes`.
    Truncated,
    /// `magic` did not equal [`MAGIC`].
    BadMagic,
    /// `header_crc32` did not match the header's own contents.
    BadHeaderCrc { expected: u32, actual: u32 },
    /// `version` did not equal the [`VERSION`] this crate implements.
    BadVersion { found: u16 },
    /// `payload_crc32` did not match the actual payload bytes.
    BadPayloadCrc { expected: u32, actual: u32 },
    /// `length` exceeds the caller-supplied bound (a receive/destination buffer size).
    TooLarge { length: u32, max: u32 },
}

/// The text the loader prints for each error.
impl core::fmt::Display for ImageError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            ImageError::Truncated => write!(f, "header truncated"),
            ImageError::BadMagic => write!(f, "bad magic (not a fpga-sdr image)"),
            ImageError::BadHeaderCrc { expected, actual } => write!(
                f,
                "header crc mismatch: header says {expected:#010x}, computed {actual:#010x}"
            ),
            ImageError::BadVersion { found } => {
                write!(f, "unsupported image format version {found} (this loader implements {VERSION})")
            }
            ImageError::BadPayloadCrc { expected, actual } => write!(
                f,
                "payload crc mismatch: header says {expected:#010x}, computed {actual:#010x}"
            ),
            ImageError::TooLarge { length, max } => {
                write!(f, "payload too large: {length} bytes, max {max}")
            }
        }
    }
}

impl ImageHeader {
    /// Serializes the header to its `HEADER_LEN`-byte on-wire form (little-endian, see the
    /// module doc). `header_crc32` is always computed afresh from the other fields, so callers
    /// never set it themselves (see [`ImageHeader::new`]).
    pub fn to_bytes(&self) -> [u8; HEADER_LEN] {
        let mut buf = [0u8; HEADER_LEN];
        buf[0..4].copy_from_slice(&self.magic.to_le_bytes());
        buf[4..6].copy_from_slice(&self.version.to_le_bytes());
        buf[6..8].copy_from_slice(&self.flags.to_le_bytes());
        buf[8..12].copy_from_slice(&self.load_addr.to_le_bytes());
        buf[12..16].copy_from_slice(&self.entry.to_le_bytes());
        buf[16..20].copy_from_slice(&self.length.to_le_bytes());
        buf[20..24].copy_from_slice(&self.payload_crc32.to_le_bytes());
        let header_crc32 = crc32(&buf[0..24]);
        buf[24..28].copy_from_slice(&header_crc32.to_le_bytes());
        buf
    }

    /// Builds a header for `payload`, computing both CRC32 fields. `load_addr`, `entry` and
    /// `flags` are the caller's choice (they are the packer's command-line flags), and `version`
    /// is always [`VERSION`].
    pub fn new(load_addr: u32, entry: u32, flags: u16, payload: &[u8]) -> Self {
        let mut header = ImageHeader {
            magic: MAGIC,
            version: VERSION,
            flags,
            load_addr,
            entry,
            length: payload.len() as u32,
            payload_crc32: crc32(payload),
            header_crc32: 0, // filled in below from to_bytes()
        };
        // Go through to_bytes() so header_crc32 is computed in exactly one place and always
        // agrees with the bytes that are actually sent.
        let bytes = header.to_bytes();
        header.header_crc32 = u32::from_le_bytes(bytes[24..28].try_into().unwrap());
        header
    }

    /// Parses and structurally validates a header from [`HEADER_LEN`] or more bytes (only the
    /// first `HEADER_LEN` are read). Checks the magic, the header CRC and the version, in that
    /// order, so the first mismatch found is the one reported. It does **not** check
    /// `payload_crc32`, because the payload usually has not arrived yet when the header is
    /// parsed (see [`ImageHeader::validate_payload`]).
    pub fn from_bytes(buf: &[u8]) -> Result<Self, ImageError> {
        if buf.len() < HEADER_LEN {
            return Err(ImageError::Truncated);
        }
        let magic = u32::from_le_bytes(buf[0..4].try_into().unwrap());
        if magic != MAGIC {
            return Err(ImageError::BadMagic);
        }
        let header_crc32 = u32::from_le_bytes(buf[24..28].try_into().unwrap());
        let computed = crc32(&buf[0..24]);
        if header_crc32 != computed {
            return Err(ImageError::BadHeaderCrc {
                expected: header_crc32,
                actual: computed,
            });
        }
        let version = u16::from_le_bytes(buf[4..6].try_into().unwrap());
        if version != VERSION {
            return Err(ImageError::BadVersion { found: version });
        }
        Ok(ImageHeader {
            magic,
            version,
            flags: u16::from_le_bytes(buf[6..8].try_into().unwrap()),
            load_addr: u32::from_le_bytes(buf[8..12].try_into().unwrap()),
            entry: u32::from_le_bytes(buf[12..16].try_into().unwrap()),
            length: u32::from_le_bytes(buf[16..20].try_into().unwrap()),
            payload_crc32: header_crc32_payload_field(buf),
            header_crc32,
        })
    }

    /// Checks `payload` (which the caller has by now received in full, for example into a DDR3
    /// buffer) against this header's `length` and `payload_crc32`. Callers should compare `length`
    /// with the size of their destination buffer *before* reading that many bytes off the wire,
    /// and this function checks it against `max_len` once more, so a caller that forgets is still
    /// safe.
    pub fn validate_payload(&self, payload: &[u8], max_len: u32) -> Result<(), ImageError> {
        if self.length > max_len {
            return Err(ImageError::TooLarge {
                length: self.length,
                max: max_len,
            });
        }
        if payload.len() as u32 != self.length {
            // The caller handed over a slice of the wrong length, which is a bug in the caller
            // and does not mean the image is corrupt. The loader reads exactly `length` bytes
            // before calling this (fw/tr-loader/src/protocol.rs), so it is never reached there.
            return Err(ImageError::TooLarge {
                length: payload.len() as u32,
                max: self.length,
            });
        }
        let actual = crc32(payload);
        if actual != self.payload_crc32 {
            return Err(ImageError::BadPayloadCrc {
                expected: self.payload_crc32,
                actual,
            });
        }
        Ok(())
    }
}

/// Reads bytes 20..24 (`payload_crc32`) of a header buffer whose magic and header CRC have
/// already been checked. It is a small helper only so that `from_bytes` reads every field once,
/// in the same style.
fn header_crc32_payload_field(buf: &[u8]) -> u32 {
    u32::from_le_bytes(buf[20..24].try_into().unwrap())
}

// --- CRC32 -------------------------------------------------------------------------------
//
// The standard reflected CRC-32 (polynomial 0xEDB88320, initial value 0xFFFFFFFF, final XOR
// 0xFFFFFFFF), which is the same algorithm as zlib, gzip, PNG, the Ethernet frame check
// sequence and Python's `zlib.crc32`. It was picked because an image or a payload can be checked
// against any of those standard tools while packing or debugging. The table form is used (256 x
// u32 = 1 KiB, computed at compile time by the `const fn` below, so there is no setup at run time
// and no external crate) instead of the bit-at-a-time form, because the stage-0 loader checksums
// a whole firmware image (potentially several MB) on every boot or load and 1 KiB is small
// against its 64 KB flash budget (docs/ARCHITECTURE.md 5.4).

/// Builds the 256-entry lookup table: entry `i` is the CRC register after shifting the byte `i`
/// through eight steps of the reflected polynomial.
const fn crc32_table() -> [u32; 256] {
    let mut table = [0u32; 256];
    let mut i = 0;
    while i < 256 {
        let mut c = i as u32;
        let mut j = 0;
        while j < 8 {
            c = if c & 1 != 0 {
                0xEDB8_8320 ^ (c >> 1)
            } else {
                c >> 1
            };
            j += 1;
        }
        table[i] = c;
        i += 1;
    }
    table
}

static CRC32_TABLE: [u32; 256] = crc32_table();

/// CRC32 of `data` (the variant described in the note above: the same value `zlib.crc32` gives).
pub fn crc32(data: &[u8]) -> u32 {
    let mut crc = 0xFFFF_FFFFu32;
    for &byte in data {
        let idx = ((crc ^ byte as u32) & 0xFF) as usize;
        crc = CRC32_TABLE[idx] ^ (crc >> 8);
    }
    crc ^ 0xFFFF_FFFF
}

#[cfg(feature = "std")]
extern crate std;

#[cfg(feature = "std")]
pub mod host {
    //! Host-only (`std`) convenience helpers: packing a header and a payload into one `Vec<u8>`,
    //! which the `image` subcommand of `fw/xtask` uses to write an image file.
    use super::*;
    use std::vec::Vec;

    /// Builds a complete on-disk/on-wire image: header bytes followed by `payload`.
    pub fn pack(load_addr: u32, entry: u32, flags: u16, payload: &[u8]) -> Vec<u8> {
        let header = ImageHeader::new(load_addr, entry, flags, payload);
        let mut out = Vec::with_capacity(HEADER_LEN + payload.len());
        out.extend_from_slice(&header.to_bytes());
        out.extend_from_slice(payload);
        out
    }
}

/// Host tests of the image format: the CRC against known values, and a round trip and a
/// rejection case for each of the checks in `from_bytes` and `validate_payload`.
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn crc32_known_vectors() {
        // Standard textbook CRC-32 values (the same algorithm zlib.crc32 implements).
        assert_eq!(crc32(b""), 0x0000_0000);
        assert_eq!(crc32(b"123456789"), 0xCBF4_3926);
    }

    #[test]
    fn round_trip() {
        let payload = b"fpga-sdr stage-0 loader test payload, some bytes here";
        let header = ImageHeader::new(0x8010_0000, 0x8010_0000, 0, payload);
        let bytes = header.to_bytes();
        let parsed = ImageHeader::from_bytes(&bytes).expect("valid header");
        assert_eq!(parsed, header);
        parsed
            .validate_payload(payload, 1024 * 1024)
            .expect("payload validates");
    }

    #[test]
    fn rejects_bad_magic() {
        let mut bytes = ImageHeader::new(0, 0, 0, b"x").to_bytes();
        bytes[0] ^= 0xFF;
        assert_eq!(ImageHeader::from_bytes(&bytes), Err(ImageError::BadMagic));
    }

    #[test]
    fn rejects_corrupted_header() {
        let mut bytes = ImageHeader::new(0x1000, 0x1000, 0, b"hello world").to_bytes();
        bytes[9] ^= 0x01; // flip a bit inside load_addr, after magic
        match ImageHeader::from_bytes(&bytes) {
            Err(ImageError::BadHeaderCrc { .. }) => {}
            other => panic!("expected BadHeaderCrc, got {other:?}"),
        }
    }

    #[test]
    fn rejects_corrupted_payload() {
        let payload = b"hello world, this is the payload";
        let header = ImageHeader::new(0x1000, 0x1000, 0, payload);
        let mut corrupt = *payload;
        corrupt[3] ^= 0xFF;
        match header.validate_payload(&corrupt, 1024) {
            Err(ImageError::BadPayloadCrc { .. }) => {}
            other => panic!("expected BadPayloadCrc, got {other:?}"),
        }
    }

    #[test]
    fn pack_round_trip_via_host_helper() {
        let payload = b"packed payload bytes";
        let image = host::pack(0x8020_0000, 0x8020_0004, 0, payload);
        assert_eq!(image.len(), HEADER_LEN + payload.len());
        let header = ImageHeader::from_bytes(&image).expect("header parses");
        assert_eq!(header.load_addr, 0x8020_0000);
        assert_eq!(header.entry, 0x8020_0004);
        header
            .validate_payload(&image[HEADER_LEN..], payload.len() as u32)
            .expect("payload validates");
    }
}
