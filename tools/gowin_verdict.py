#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
"""Build verdict: from a Gowin timing report (..._tr_content.html): the report's own totals of violated end points
(setup, hold: they include paths between two clocks, which the per-clock table does not show), per clock Fmax
and end points open, the worst path between two different clocks, and the worst listed hold path of each
hold table with its clock skew.   python tools/gowin_verdict.py <tr_content.html>

The argument is the HTML timing report that Gowin place-and-route writes into the build's impl folder.  The script only reads
that file, and everything is printed when it is run, since it has no functions to call and no options.
"""
import html
import re
import sys

s = open(sys.argv[1], encoding="utf8", errors="ignore").read()


def rows(seg):
    """The cells of every table row in an HTML piece as lists of text, tags removed and entities decoded."""
    out = []
    for tr in re.findall(r"<tr.*?</tr>", seg, re.S):
        c = [html.unescape(re.sub(r"<[^>]+>", "", x)).strip() for x in re.findall(r"<t[dh][^>]*>(.*?)</t[dh]>", tr, re.S)]
        if c:
            out.append(c)
    return out


def table_after(title, start=0):
    """The rows of the first table after the heading `title` (searching from `start`) and the position where it ends, or ([], -1)."""
    i = s.find(title, start)
    if i < 0:
        return [], -1
    j = s.find("<table", i)
    k = s.find("</table>", j)
    return rows(s[j:k]), k


# Totals of violated end points as the report states them; they count paths between two clocks as well.
flat = html.unescape(re.sub(r"<[^>]+>", " ", s))
for k in ("Numbers of Setup Violated Endpoints", "Numbers of Hold Violated Endpoints"):
    m = re.search(k + r"\s+(\d+)", flat)
    print(k + ":", m.group(1) if m else "not found")
# One line per clock: its constraint, the Fmax the report found, and how many setup and hold end points are still open.
fm, _ = table_after("Max Frequency Summary")
tns, _ = table_after("Total Negative Slack Summary")
print("clock          constraint   Fmax      setup open  hold open")
op = {}
for r in tns[1:]:
    op[(r[0], r[1])] = r[3]
for r in fm[1:]:
    if len(r) >= 4:
        print(f"{r[1]:14s} {r[2]:12s} {r[3]:12s} {op.get((r[1], 'Setup'), '-'):>6s} {op.get((r[1], 'Hold'), '-'):>10s}")
for k, v in op.items():
    if k[1] == "Hold" and v != "0":
        print("hold open:", k[0], v)
# setup path tables: worst path between two different clocks
pos = 0
while True:
    i = s.find("Setup Paths Table", pos)
    if i < 0:
        break
    t, k = table_after("Setup Paths Table", pos)
    pos = max(k, i + 10)
    x = [r for r in t[1:] if len(r) >= 9 and r[4].split(":")[0] != r[5].split(":")[0]]
    if x:
        r = x[0]
        print(f"between clocks: slack {r[1]:>7s}  {r[4]} -> {r[5]}  {r[2][-50:]} -> {r[3][-50:]}  ({len(x)} listed)")
# hold path tables: worst path per table
pos = 0
while True:
    i = s.find("Hold Paths Table", pos)
    if i < 0:
        break
    t, k = table_after("Hold Paths Table", pos)
    pos = max(k, i + 10)
    if len(t) > 1 and len(t[1]) >= 9:
        r = t[1]
        print(f"hold worst: slack {r[1]:>7s}  skew {r[7]:>7s}  delay {r[8]:>6s}  {r[4]} -> {r[5]}  {r[2][:60]} -> {r[3][:60]}")
