#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
"""Fan-out and pin counts from a Gowin synthesis netlist (.vg).

The netlist is the structural Verilog that Gowin synthesis writes (the .vg file in the build's gwsynthesis folder), and this
script only reads it, without the Gowin software.  Fan-out is the number of input pins one net drives, and nets with a very high
fan-out are the usual cause of slow routing, which is why the nets with the most loads are listed with their driver and the
units they load.  The netlist is flattened bit by bit (module ports joined to the nets outside). Printed:
  - per unit (instance path prefix, --depth levels): cells, input pins, pins per cell
  - the nets with the most loads (clock pins left out), with the driving cell and how the loads spread over units
  - a histogram of loads per net

    python tools/gowin_fanout.py <sdr_top.vg> [--depth 3] [--top 40] [--under u_core/]
"""
import argparse
import re
import sys
from collections import Counter, defaultdict

# Port names of the Gowin primitives that are outputs (everything else on a primitive counts as an input pin), and the clock
# input ports, whose pins are not counted as loads.
OUT_PORTS = {"F", "Q", "SUM", "COUT", "DO", "DOUT", "O", "OF", "CASO", "DOA", "DOB", "CLKOUT", "CLKOUT0", "CLKOUT1",
             "CLKOUT2", "CLKOUT3", "CLKOUT4", "CLKOUT5", "CLKOUT6", "CLKFBOUT", "LOCK", "Q0", "Q1", "Q2", "Q3", "Q4",
             "Q5", "Q6", "Q7", "DF", "IO", "OB", "OEN"}
CLK_PORTS = {"CLK", "CLKA", "CLKB", "PCLK", "FCLK", "CLKIN", "ICLK"}

# Regular expressions for the netlist text: a name with an optional bit select (escaped names start with a backslash and end
# with a blank), a declaration of a port or wire, one .port(expression) connection, and the first line of an instance.
IDENT = re.compile(r"\s*(\\\S+\s|[A-Za-z_][\w$]*)\s*(\[(\d+)(?::(\d+))?\])?\s*")
DECL = re.compile(r"^\s*(input|output|inout|wire)\s*(\[(\d+):(\d+)\])?\s*(\\\S+\s|[A-Za-z_][\w$]*)\s*;")
CONN = re.compile(r"\.(\\\S+\s|[A-Za-z_][\w$]*)\s*\(([^()]*)\)")
HEAD = re.compile(r"^\s*(\\?\S+)\s+(\\\S+\s|[A-Za-z_][\w$]*)\s*\(\s*$")


def nm(s):
    """A netlist name without the backslash of an escaped identifier and without surrounding blanks."""
    s = s.strip()
    return s[1:] if s.startswith("\\") else s


class Mod:
    """One module of the netlist: the widths and directions of its names and its instances."""

    def __init__(self):
        self.width = {}     # name -> (msb, lsb) or None for a scalar
        self.dir = {}       # port -> input / output / inout
        self.insts = []     # (cell, name, [(port, expr)])


def parse(vg):
    """Reads the .vg file into a dict from module name to Mod.  It understands only the plain layout that Gowin synthesis writes
    (one declaration per line, instances with one connection per line, ending in a line that starts with ");")."""
    mods = {}
    cur = None
    buf = None
    with open(vg, encoding="utf-8", errors="replace") as f:
        for line in f:
            if line.startswith("module "):
                cur = Mod()
                mods[nm(line.split()[1].split("(")[0])] = cur
                continue
            if cur is None:
                continue
            if line.startswith("endmodule"):
                cur = None
                continue
            if buf is None:
                m = DECL.match(line)
                if m:
                    n = nm(m.group(5))
                    cur.width[n] = (int(m.group(3)), int(m.group(4))) if m.group(2) else None
                    if m.group(1) != "wire":
                        cur.dir[n] = m.group(1)
                    continue
                m = HEAD.match(line)
                if m and m.group(1) not in ("module", "defparam", "assign", "wire", "input", "output", "inout"):
                    buf = [nm(m.group(1)), nm(m.group(2)), ""]
                continue
            if line.lstrip().startswith(");"):
                cur.insts.append((buf[0], buf[1], [(nm(p), e) for p, e in CONN.findall(buf[2])]))
                buf = None
            else:
                buf[2] += line
    return mods


def bits(expr, mod):
    """list of net bit names, most significant first; None for a constant bit"""
    expr = expr.strip()
    if not expr:
        return []
    if expr[0] == "{":
        out = []
        for part in expr[1:expr.rindex("}")].split(","):
            out += bits(part, mod)
        return out
    m = re.match(r"(\d+)'[bhd]", expr)
    if m:
        return [None] * int(m.group(1))
    m = IDENT.fullmatch(expr + " ")       # an escaped name ends with a blank
    if not m:
        return [None]
    n = nm(m.group(1))
    if m.group(2):
        a = int(m.group(3))
        b = int(m.group(4)) if m.group(4) is not None else a
        step = -1 if a >= b else 1
        return ["%s[%d]" % (n, i) for i in range(a, b + step, step)]
    w = mod.width.get(n)
    if w is None:
        return [n]
    step = -1 if w[0] >= w[1] else 1
    return ["%s[%d]" % (n, i) for i in range(w[0], w[1] + step, step)]


class Flat:
    """The flattened design: every primitive cell with the net on each of its pins, nets from different hierarchy levels joined."""

    def __init__(self, mods):
        self.mods = mods
        used = {c for m in mods.values() for c, _, _ in m.insts}
        self.top = [m for m in mods if m not in used][-1]
        self.par = {}
        self.loads = []     # (net id, cell path, cell, port)
        self.drv = {}       # net id -> (cell path, cell, port)
        self.cells = Counter()
        self.ncell = 0
        self.walk(self.top, "")

    def find(self, x):
        """The representative of the net x (union-find with path compression)."""
        p = self.par
        r = x
        while r in p:
            r = p[r]
        while x in p and p[x] != r:
            p[x], x = r, p[x]
        return r

    def union(self, a, b):
        """Declares the nets a and b to be the same net."""
        ra, rb = self.find(a), self.find(b)
        if ra != rb:
            self.par[ra] = rb

    def walk(self, modname, path):
        """Descends into module `modname` (instance path `path`): sub-module ports are joined to the nets outside, and every primitive cell is recorded with its driven and loaded nets."""
        mod = self.mods[modname]
        for cell, name, conns in mod.insts:
            p = path + name
            if cell in self.mods:
                sub = self.mods[cell]
                for port, expr in conns:
                    outer = bits(expr, mod)
                    inner = bits(port, sub)
                    for o, i in zip(reversed(outer), reversed(inner)):
                        if o is not None:
                            self.union((path, o), (p + "/", i))
                self.walk(cell, p + "/")
            else:
                if cell in ("VCC", "GND"):
                    continue
                self.ncell += 1
                self.cells[cell] += 1
                for port, expr in conns:
                    for b in bits(expr, mod):
                        if b is None or b in ("VCC", "GND"):
                            continue
                        if port in OUT_PORTS:
                            self.drv[(path, b)] = (p, cell, port)
                        elif port not in CLK_PORTS:
                            self.loads.append(((path, b), p, cell, port))


def unit(path, depth):
    """The first `depth` levels of an instance path, which name the unit a cell belongs to."""
    parts = path.split("/")
    return "/".join(parts[:min(depth, len(parts) - 1)]) or "(top)"


def main():
    """Parses and flattens the netlist and prints the unit table, the fan-out histogram and the nets with the most loads."""
    ap = argparse.ArgumentParser()
    ap.add_argument("vg")
    ap.add_argument("--depth", type=int, default=3)
    ap.add_argument("--top", type=int, default=40)
    ap.add_argument("--under", default="")
    a = ap.parse_args()
    fl = Flat(parse(a.vg))
    drv = {fl.find(k): v for k, v in fl.drv.items()}
    fan = defaultdict(list)
    pins = Counter()
    cells = Counter()
    seen = set()
    for net, p, cell, port in fl.loads:
        fan[fl.find(net)].append((p, port))
        u = unit(p, a.depth)
        pins[u] += 1
        if p not in seen:
            seen.add(p)
            cells[u] += 1
    print("cells %d, nets with loads %d, input pins %d (clock pins not counted)" % (fl.ncell, len(fan), len(fl.loads)))
    print("\nunit: cells with inputs, input pins, pins per cell")
    for u, n in pins.most_common(30):
        print("  %-60s %7d %8d  %.2f" % (u, cells[u], n, n / cells[u]))
    hist = Counter()
    for r, l in fan.items():
        n = len(l)
        hist[next(b for b in (1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 10 ** 9) if n <= b)] += 1
    print("\nloads per net (up to): " + ", ".join("%s: %d" % ("more" if b == 10 ** 9 else b, hist[b]) for b in sorted(hist)))
    big = sorted(fan.items(), key=lambda kv: -len(kv[1]))
    print("\nloads over 64: nets %d, pins %d; over 256: nets %d, pins %d" % (
        sum(1 for _, l in big if len(l) > 64), sum(len(l) for _, l in big if len(l) > 64),
        sum(1 for _, l in big if len(l) > 256), sum(len(l) for _, l in big if len(l) > 256)))
    print("\nnets with the most loads (driver cell and port; load pins by port; loads by unit)")
    shown = 0
    for r, l in big:
        d = drv.get(r, ("(port or hard block) " + str(r[0]) + str(r[1]), "", ""))
        if a.under and not d[0].startswith(a.under):
            continue
        ports = Counter(p for _, p in l)
        units = Counter(unit(p, a.depth + 1) for p, _ in l)
        print("  %5d  %s %s.%s | %s | %s" % (len(l), d[0], d[1], d[2],
              " ".join("%s:%d" % kv for kv in ports.most_common(4)),
              " ".join("%s:%d" % kv for kv in units.most_common(3))))
        shown += 1
        if shown >= a.top:
            break
    return 0


if __name__ == "__main__":
    sys.exit(main())
