#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
"""Generates rtl/n1/tab_8b10b.vh, the 8b/10b code tables used by enc_8b10b.v and dec_8b10b.v (docs/SFP_LINKS.md, docs/ARCHITECTURE.md 3.8).

8b/10b is the line code of 1000BASE-X (the SFP link of the radio) and of Gigabit Ethernet over fiber in general, defined in IEEE 802.3
clause 36 and originally by Widmer and Franaszek.  Every data byte is sent as a 10-bit code group chosen so that the stream
has about as many ones as zeros (DC balance) and never a long run of equal bits, which the receiver's clock recovery needs.
The encoder keeps a running disparity (the surplus of ones or zeros sent so far, which may only be +1 or -1 at the end of a
code group) and picks the variant of each code that brings the disparity back toward zero, which is why every table row has two
entries, one for each running disparity.  Twelve extra control codes (K codes, such as K28.5 whose bit pattern is the comma
that lets the receiver find the code group boundaries) exist next to the 256 data codes.

This is an original generator, not a vendored file: it builds the standard 8b/10b alphabet from the two public sub-block
tables (5b/6b, 32 rows, and 3b/4b, 8 rows including the D.x.P7/D.x.A7 alternate) and the 12 fixed K-code words, all of
which are technical constants published in the standard itself (also reproduced at
https://en.wikipedia.org/wiki/8b/10b_encoding), and not another project's source code.  The
two-stage composition (5b/6b sub-block, then 3b/4b at the disparity the 5b/6b stage leaves
behind) and the running-disparity bookkeeping are implemented here and cross-checked by
`selftest()` below (round-trip every byte at both starting disparities, check the disparity of every code by counting its ones,
and check the comma of K28.5) before any Verilog is emitted.

What it writes: rtl/n1/tab_8b10b.vh, next to this script, with three Verilog functions: enc8b10b_d (data byte and running
disparity in, code group and new disparity out), enc8b10b_k (the same for the 12 control codes) and dec8b10b (code group in,
valid flag, K flag and byte out).  The functions are consumed by enc_8b10b.v and dec_8b10b.v.

Run: `python3 rtl/n1/gen_8b10b_table.py` from anywhere (the output goes next to the script, and no packages are needed).
Rerun after editing this file and commit the regenerated rtl/n1/tab_8b10b.vh alongside it.
"""

from __future__ import annotations

# --- 5b/6b sub-block: D.0 .. D.31, (RD-6, RD+6) as 6-bit ints, MSB..LSB = a b c d e i ---
D5B6B = [
    (0b100111, 0b011000), (0b011101, 0b100010), (0b101101, 0b010010), (0b110001, 0b110001),
    (0b110101, 0b001010), (0b101001, 0b101001), (0b011001, 0b011001), (0b111000, 0b000111),
    (0b111001, 0b000110), (0b100101, 0b100101), (0b010101, 0b010101), (0b110100, 0b110100),
    (0b001101, 0b001101), (0b101100, 0b101100), (0b011100, 0b011100), (0b010111, 0b101000),
    (0b011011, 0b100100), (0b100011, 0b100011), (0b010011, 0b010011), (0b110010, 0b110010),
    (0b001011, 0b001011), (0b101010, 0b101010), (0b011010, 0b011010), (0b111010, 0b000101),
    (0b110011, 0b001100), (0b100110, 0b100110), (0b010110, 0b010110), (0b110110, 0b001001),
    (0b001110, 0b001110), (0b101110, 0b010001), (0b011110, 0b100001), (0b101011, 0b010100),
]
assert len(D5B6B) == 32

# --- 3b/4b sub-block: y.0 .. y.6, (RD-4, RD+4) as 4-bit ints, MSB..LSB = f g h j ---
D3B4B = [
    (0b1011, 0b0100), (0b1001, 0b1001), (0b0101, 0b0101), (0b1100, 0b0011),
    (0b1101, 0b0010), (0b1010, 0b1010), (0b0110, 0b0110),
]
P7 = (0b1110, 0b0001)   # D.x.P7 (primary y=7)
A7 = (0b0111, 0b1000)   # D.x.A7 (alternate y=7)
# Alternate selection (IEEE 802.3 clause 36.2.4 / Widmer-Franaszek): use A7 instead of P7 only
# for these (x, disparity-into-the-3b4b-stage) combinations, to avoid a run of 5 like bits
# against the preceding 5b/6b code.
ALT7_AT_RD_MINUS = {17, 18, 20}   # disparity into the 3b/4b stage is -1
ALT7_AT_RD_PLUS = {11, 13, 14}    # disparity into the 3b/4b stage is +1

# --- K (control) code words: (x, y) -> (RD-10, RD+10), fixed by the standard ---
KCODES = {
    (28, 0): (0b0011110100, 0b1100001011),
    (28, 1): (0b0011111001, 0b1100000110),
    (28, 2): (0b0011110101, 0b1100001010),
    (28, 3): (0b0011110011, 0b1100001100),
    (28, 4): (0b0011110010, 0b1100001101),
    (28, 5): (0b0011111010, 0b1100000101),
    (28, 6): (0b0011110110, 0b1100001001),
    (28, 7): (0b0011111000, 0b1100000111),
    (23, 7): (0b1110101000, 0b0001010111),
    (27, 7): (0b1101101000, 0b0010010111),
    (29, 7): (0b1011101000, 0b0100010111),
    (30, 7): (0b0111101000, 0b1000010111),
}
assert len(KCODES) == 12


def popcount(v: int, width: int) -> int:
    """The number of ones in the low `width` bits of v."""
    return bin(v & ((1 << width) - 1)).count("1")


def encode_d(byte: int, rd_in: int) -> tuple[int, int]:
    """Encode one data byte (D.x.y) at running disparity rd_in (+-1). Returns (10b code, rd_out)."""
    x = byte & 0x1F
    y = (byte >> 5) & 0x7
    rdm, rdp = D5B6B[x]
    six = rdm if rd_in < 0 else rdp
    # A sub-block changes the running disparity only when it is unbalanced. Comparing the two forms
    # (`rdm != rdp`) would be wrong, because it also "flips" for D.7 (111000 / 000111) and, below, for D.x.3
    # (1100 / 0011), where both forms are balanced and the disparity stays as it was.
    flip6 = popcount(six, 6) != 3
    rd_mid = -rd_in if flip6 else rd_in

    if y == 7:
        use_alt = (rd_mid < 0 and x in ALT7_AT_RD_MINUS) or (rd_mid > 0 and x in ALT7_AT_RD_PLUS)
        m4, p4 = A7 if use_alt else P7
    else:
        m4, p4 = D3B4B[y]
    four = m4 if rd_mid < 0 else p4
    flip4 = popcount(four, 4) != 2
    rd_out = -rd_mid if flip4 else rd_mid

    code = (six << 4) | four
    assert popcount(code, 10) in (4, 5, 6), f"D.{x}.{y} rd_in={rd_in}: bad disparity code {code:010b}"
    return code, rd_out


def encode_k(x: int, y: int, rd_in: int) -> tuple[int, int]:
    """Encode the control code K.x.y at running disparity rd_in (+-1). Returns (10b code, rd_out)."""
    m10, p10 = KCODES[(x, y)]
    code = m10 if rd_in < 0 else p10
    # K28.1, K28.2, K28.3, K28.5, K28.6 are unbalanced; the other seven are balanced and keep the disparity
    rd_out = -rd_in if popcount(code, 10) != 5 else rd_in
    return code, rd_out


def build_tables():
    """Returns (d_table, k_table, decode_table).

    d_table[byte][rd_idx]  -> (code10, rd_out_idx)         rd_idx: 0 -> RD=-1, 1 -> RD=+1
    k_table[(x,y)][rd_idx] -> (code10, rd_out_idx)
    decode_table[code10]   -> ('D', byte) | ('K', byte) | None (never legally transmitted)
    """
    d_table = []
    for byte in range(256):
        row = []
        for rd_in in (-1, 1):
            code, rd_out = encode_d(byte, rd_in)
            row.append((code, 0 if rd_out < 0 else 1))
        d_table.append(row)

    k_table = {}
    for (x, y) in KCODES:
        row = []
        for rd_in in (-1, 1):
            code, rd_out = encode_k(x, y, rd_in)
            row.append((code, 0 if rd_out < 0 else 1))
        k_table[(x, y)] = row

    decode_table: dict[int, tuple[str, int]] = {}
    for byte in range(256):
        for rd_idx in (0, 1):
            code, _ = d_table[byte][rd_idx]
            prev = decode_table.get(code)
            if prev is not None and prev != ("D", byte):
                raise AssertionError(f"D-code collision at {code:010b}: {prev} vs D {byte}")
            decode_table[code] = ("D", byte)
    for (x, y) in KCODES:
        byte = (y << 5) | x
        for rd_idx in (0, 1):
            code, _ = k_table[(x, y)][rd_idx]
            prev = decode_table.get(code)
            if prev is not None:
                raise AssertionError(f"K-code collision at {code:010b}: {prev} vs K {byte}")
            decode_table[code] = ("K", byte)

    return d_table, k_table, decode_table


def selftest(d_table, k_table, decode_table):
    """Checks the tables (round trip, disparity rule, comma of K28.5) and stops with an assertion error if anything is wrong."""
    # Round-trip every byte at both starting disparities; disparity must stay a valid running
    # value (this loop IS the running-disparity chain, not an isolated per-symbol check).
    for rd0 in (0, 1):
        rd = rd0
        for byte in range(256):
            code, rd = d_table[byte][rd]
            kind, got = decode_table[code]
            assert kind == "D" and got == byte, f"D round-trip failed for byte {byte}: got {kind}{got}"
    for (x, y) in KCODES:
        for rd0 in (0, 1):
            code, rd1 = k_table[(x, y)][rd0]
            kind, got = decode_table[code]
            assert kind == "K" and got == ((y << 5) | x), f"K round-trip failed for K{x}.{y}"
    # Disparity by bit count: a code with more ones than zeros is only sent at RD-
    # and leaves RD+, one with fewer only at RD+ and leaves RD-, a balanced one keeps the disparity.
    for table in (d_table, list(k_table.values())):
        for row in table:
            for rd_idx in (0, 1):
                code, rd_out = row[rd_idx]
                ones = popcount(code, 10)
                want = rd_idx if ones == 5 else (1 if ones == 6 else 0)
                assert ones in (4, 5, 6) and rd_out == want and (ones == 5 or (ones == 6) == (rd_idx == 0)),                     f"disparity rule broken for {code:010b} at rd {rd_idx}"
    # Comma property: K28.5 (x=28,y=5) must contain the 0011111 / 1100000 comma sequence used
    # for code-group alignment (IEEE 802.3 36.2.4.9).
    for rd_idx in (0, 1):
        code, _ = k_table[(28, 5)][rd_idx]
        s = format(code, "010b")
        assert "0011111" in s or "1100000" in s, f"K28.5 missing comma: {s}"
    print(f"selftest OK: {len(decode_table)} valid code groups "
          f"({sum(1 for k in decode_table if decode_table[k][0]=='D')} D, "
          f"{sum(1 for k in decode_table if decode_table[k][0]=='K')} K)")


def emit_verilog(d_table, k_table, path):
    """Writes the three Verilog functions as case tables to `path`.  The decode function is built from the global
    decode_table that the main block below creates, so the script has to be run as a program."""
    lines = []
    lines.append("// Generated by rtl/n1/gen_8b10b_table.py -- do not edit by hand.")
    lines.append("// SPDX-License-Identifier: Apache-2.0")
    lines.append("// Copyright 2026 Franz Schöning, https://www.schoning.com")
    lines.append("//")
    lines.append("// 8b/10b code tables (IEEE 802.3 clause 36 / Widmer-Franaszek alphabet), split into two")
    lines.append("// functions consumed by enc_8b10b.v: encode_d (256 data bytes) and encode_k (12 valid")
    lines.append("// control words, packed as {y[2:0], x[4:0]} same as a data byte would be). Each returns")
    lines.append("// {code[9:0], rd_out} for rd_in ('{code, rd}' = table[rd_in][byte]).")
    lines.append("")
    lines.append("function automatic [10:0] enc8b10b_d(input [7:0] byte_in, input rd_in);")
    lines.append("    reg [10:0] t;")
    lines.append("    begin")
    lines.append("        case ({rd_in, byte_in})")
    for byte in range(256):
        for rd_idx in (0, 1):
            code, rd_out = d_table[byte][rd_idx]
            lines.append(f"            9'b{rd_idx}_{byte:08b}: t = {{10'b{code:010b}, 1'b{rd_out}}};")
    lines.append("            default: t = 11'bx;")
    lines.append("        endcase")
    lines.append("        enc8b10b_d = t;")
    lines.append("    end")
    lines.append("endfunction")
    lines.append("")
    lines.append("// x in bits [4:0], y in bits [7:5] of byte_in, same packing as an 8B value.")
    lines.append("function automatic [10:0] enc8b10b_k(input [7:0] byte_in, input rd_in);")
    lines.append("    reg [10:0] t;")
    lines.append("    begin")
    lines.append("        case ({rd_in, byte_in})")
    for (x, y) in sorted(KCODES):
        byte = (y << 5) | x
        for rd_idx in (0, 1):
            code, rd_out = k_table[(x, y)][rd_idx]
            lines.append(f"            9'b{rd_idx}_{byte:08b}: t = {{10'b{code:010b}, 1'b{rd_out}}};")
    lines.append("            default: t = 11'bx; // not a legal K code -- caller must not request it")
    lines.append("        endcase")
    lines.append("        enc8b10b_k = t;")
    lines.append("    end")
    lines.append("endfunction")
    lines.append("")
    lines.append("// Decode: 10-bit code group -> {valid, is_k, byte[7:0]}.")
    lines.append("function automatic [9:0] dec8b10b(input [9:0] code);")
    lines.append("    reg [9:0] t;")
    lines.append("    begin")
    lines.append("        case (code)")
    for code, (kind, byte) in sorted(decode_table.items()):
        is_k = 1 if kind == "K" else 0
        lines.append(f"            10'b{code:010b}: t = {{1'b1, 1'b{is_k}, 8'h{byte:02x}}};")
    lines.append("            default: t = 10'b0; // {valid=0, is_k=0, byte=0}: invalid code group")
    lines.append("        endcase")
    lines.append("        dec8b10b = t;")
    lines.append("    end")
    lines.append("endfunction")
    lines.append("")
    with open(path, "w", encoding="utf-8", newline="\r\n") as f:
        f.write("\n".join(lines) + "\n")
    print(f"wrote {path} ({len(lines)} lines)")


if __name__ == "__main__":
    import pathlib
    d_table, k_table, decode_table = build_tables()
    selftest(d_table, k_table, decode_table)
    out = pathlib.Path(__file__).parent / "tab_8b10b.vh"
    emit_verilog(d_table, k_table, out)
