#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
"""Generates the out-of-context measurement wrapper that gowin/res.sh --wrap puts around a block (gowin/reports/README.md, "Measurement setup").

Gowin EDA has no out-of-context place-and-route mode, so a block measured on its own either gets one package pin per port
bit or goes through a wrapper like this one.  Measuring with a pin per port is possible for the blocks that fit under the
GW5AST-138's 312 user I/O, but it distorts timing: place-and-route pulls the logic next to each port's pad, spread across the
whole die, and the routing between those pads becomes the critical path (for one block, 81 % of a 9.4 ns path was routing,
for example one 5.5 ns net).

The wrapper this writes:
  - every input port bit (all except the clock and `rst`) is a register bit on one of several
    input shift chains, at most --chain bits each (`si[k]`, all shifting on `in_shift`),
    holding its value between shifts and driving the DUT input directly;
  - every output port bit is captured into a plain register every clock (`cap`, no mux in
    front of it, so the DUT's own output path ends on a bare flip-flop D input, the same as it
    would in the real design where the consumer registers it), and a second rank (`oc`) loads
    from `cap` or shifts out on `so[k]` under `out_shift`;
  - `rst` goes straight from its pad to the DUT (an unconstrained input: Gowin does not time
    pad-to-register paths without set_input_delay, and the real design's reset is a
    synchronized, replicated net that is not what these block measurements are about).
So the only top-level pins are clk, rst, in_shift, out_shift, si[*] and so[*], and every timed
path is register to register: wrapper input register -> DUT -> wrapper capture register, or
entirely inside the DUT.  Overhead: IN_BITS + 2 x OUT_BITS registers and about OUT_BITS LUTs
(the second rank's load/shift mux); no DSP, no BSRAM.  The script prints these counts.

Port list and widths come from yosys (`hierarchy -top`, so parameters are elaborated the way
the block is instantiated with its defaults), which has to be on the PATH (oss-cad-suite, in C:/tools/oss-cad-suite on
the author's PC; gowin/res.sh puts it there itself).  Run from the repository root like every other tool here.

Usage: gowin/gen_wrap.py <top> <out.v> [--chain N] [--clk PORT] [--clk2 PORT] <file.v> ...
--chain is the longest shift chain (default 64 bits), --clk the clock port of the block (default clk), and --clk2 a second
clock port, which is connected straight to a pad.
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile


def ports_of(top, files):
    """The ports of module `top` as (name, direction, width) tuples, as yosys elaborates it from `files`."""
    with tempfile.TemporaryDirectory() as td:
        js = os.path.join(td, "p.json").replace("\\", "/")
        script = "".join(f"read_verilog -sv -defer {f}; " for f in files)   # -defer: a module whose default parameter is an empty file name is only read with its real parameters
        script += f"hierarchy -top {top}; proc; write_json {js}"
        r = subprocess.run(["yosys", "-q", "-p", script], capture_output=True, text=True)
        if r.returncode != 0:
            sys.stderr.write(r.stdout + r.stderr)
            sys.exit("gen_wrap: yosys could not read the design")
        with open(js) as fh:
            mod = json.load(fh)["modules"][top]
    return [(n, p["direction"], len(p["bits"])) for n, p in mod["ports"].items()]


def main():
    """Writes the wrapper module <top>_ooc_wrap with the input and output shift chains around the block, and prints the overhead."""
    ap = argparse.ArgumentParser()
    ap.add_argument("top")
    ap.add_argument("out")
    ap.add_argument("--chain", type=int, default=64)
    ap.add_argument("--clk", default="clk")
    ap.add_argument("--clk2", default=None)    # a second clock port: straight from a pad to the block (for a block with two clocks, such as the video compositor)
    ap.add_argument("files", nargs="+")
    a = ap.parse_args()

    ports = ports_of(a.top, a.files)
    ins = [(n, w) for n, d, w in ports if d == "input" and n not in (a.clk, a.clk2, "rst")]
    outs = [(n, w) for n, d, w in ports if d == "output"]
    if any(d == "inout" for _, d, _ in ports):
        sys.exit("gen_wrap: inout ports are not supported")
    has_rst = any(n == "rst" for n, _, _ in ports)
    in_bits = sum(w for _, w in ins)
    out_bits = sum(w for _, w in outs)
    # Number of chains: the bit counts divided by the chain length, rounded up (the double minus is a ceiling division), at least one.
    C = a.chain
    n_si = max(1, -(-in_bits // C))
    n_so = max(1, -(-out_bits // C))
    wrap = f"{a.top}_ooc_wrap"

    L = []
    L.append("// SPDX-License-Identifier: Apache-2.0")
    L.append("// Copyright 2026 Franz Schöning, https://www.schoning.com")
    L.append("// Generated by gowin/gen_wrap.py (see that file's header); not hand-edited.")
    L.append(f"// {a.top}: {in_bits} input bits on {n_si} chain(s), {out_bits} output bits on "
             f"{n_so} chain(s), at most {C} bits each.")
    L.append("`timescale 1ns / 1ps")
    L.append(f"module {wrap} (")
    L.append("    input  wire clk,")
    L.append("    input  wire rst,")
    if a.clk2:
        L.append(f"    input  wire {a.clk2},")
    L.append("    input  wire in_shift,")
    L.append("    input  wire out_shift,")
    L.append(f"    input  wire [{n_si - 1}:0] si,")
    L.append(f"    output wire [{n_so - 1}:0] so")
    L.append(");")
    L.append(f"    localparam IN_BITS  = {max(in_bits, 1)};")
    L.append(f"    localparam OUT_BITS = {max(out_bits, 1)};")
    L.append("    reg [IN_BITS-1:0]  in_r;")
    L.append("    reg [OUT_BITS-1:0] cap, oc;")
    for k in range(n_si):
        lo, hi = k * C, min(in_bits, (k + 1) * C) - 1
        if in_bits == 0:
            break
        if hi == lo:
            L.append(f"    always @(posedge clk) if (in_shift) in_r[{lo}] <= si[{k}];")
        else:
            L.append(f"    always @(posedge clk) if (in_shift) in_r[{hi}:{lo}] <= "
                     f"{{in_r[{hi - 1}:{lo}], si[{k}]}};")
    L.append("    wire [OUT_BITS-1:0] dut_out;")
    L.append("    always @(posedge clk) cap <= dut_out;")
    for k in range(n_so):
        lo, hi = k * C, min(out_bits, (k + 1) * C) - 1
        if hi == lo:
            L.append(f"    always @(posedge clk) oc[{lo}] <= out_shift ? 1'b0 : cap[{lo}];")
        else:
            L.append(f"    always @(posedge clk) oc[{hi}:{lo}] <= out_shift ? "
                     f"{{oc[{hi - 1}:{lo}], 1'b0}} : cap[{hi}:{lo}];")
        L.append(f"    assign so[{k}] = oc[{hi}];")
    conns = [f"        .{a.clk}({'clk'})"]
    if has_rst:
        conns.append("        .rst(rst)")
    if a.clk2:
        conns.append(f"        .{a.clk2}({a.clk2})")
    pos = 0
    for n, w in ins:
        conns.append(f"        .{n}(in_r[{pos + w - 1}:{pos}])")
        pos += w
    pos = 0
    for n, w in outs:
        conns.append(f"        .{n}(dut_out[{pos + w - 1}:{pos}])")
        pos += w
    L.append(f"    {a.top} u_dut (")
    L.append(",\n".join(conns))
    L.append("    );")
    L.append("endmodule")
    with open(a.out, "w", newline="\n") as fh:
        fh.write("\n".join(L) + "\n")
    print(f"gen_wrap: {wrap}: in {in_bits} bits / {n_si} chains, out {out_bits} bits / {n_so} "
          f"chains; wrapper overhead {in_bits + 2 * out_bits} registers, about {out_bits} LUTs")


if __name__ == "__main__":
    main()
