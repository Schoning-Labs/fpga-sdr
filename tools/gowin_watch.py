#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
"""Stall watchdog for one Gowin run started by gowin/p1/build.sh (Windows).

    python tools/gowin_watch.py <project dir> [--stall-min 10] [--limit-min 150] [--poll 30]
                                [--done-file F] [--status F]

Reads the gw_sh process ID from <project dir>/gw_sh.pid (written by gowin/p1/build.sh) and watches
that process and its children:
  - CPU time (kernel + user, summed over the process tree) and the size of gw_sh.log. Routing
    writes nothing to the log for a long time but uses CPU: that is progress and is left alone.
  - The run is ended only when the CPU time has not advanced for --stall-min minutes, or when it
    has run longer than --limit-min minutes. It is ended by process ID (taskkill /PID <id> /T /F),
    after checking that the ID still belongs to the process first seen (same creation time).
    Nothing is ever ended by name: other sessions run their own gw_sh.
Writes a small status file (JSON: pid, result = exited | stalled | time-limit | no-pid, wall and
CPU seconds, minutes since the log last grew) and prints one line. --done-file: a file the
launcher writes when the build script has ended (stops the wait for a process ID that never came).
"""
import argparse
import ctypes
import ctypes.wintypes as wt
import json
import os
import subprocess
import sys
import time

# Windows API through ctypes (no extra package), so the script runs only on Windows.  The declarations of argument and return
# types are needed because the default of ctypes would truncate 64-bit handles.
k32 = ctypes.WinDLL("kernel32", use_last_error=True) if os.name == "nt" else None
if k32:
    k32.OpenProcess.restype = wt.HANDLE
    k32.OpenProcess.argtypes = (wt.DWORD, wt.BOOL, wt.DWORD)
    k32.CreateToolhelp32Snapshot.restype = wt.HANDLE
    k32.CreateToolhelp32Snapshot.argtypes = (wt.DWORD, wt.DWORD)
    k32.CloseHandle.argtypes = (wt.HANDLE,)
    k32.GetProcessTimes.argtypes = (wt.HANDLE,) + (ctypes.POINTER(wt.FILETIME),) * 4
    k32.GetExitCodeProcess.argtypes = (wt.HANDLE, ctypes.POINTER(wt.DWORD))
    k32.Process32First.argtypes = k32.Process32Next.argtypes = (wt.HANDLE, ctypes.c_void_p)


class PROCESSENTRY32(ctypes.Structure):
    """The Windows process snapshot entry, of which the process ID and the parent ID are used to find the children of a process."""
    _fields_ = [("dwSize", wt.DWORD), ("cntUsage", wt.DWORD), ("th32ProcessID", wt.DWORD),
                ("th32DefaultHeapID", ctypes.c_void_p), ("th32ModuleID", wt.DWORD), ("cntThreads", wt.DWORD),
                ("th32ParentProcessID", wt.DWORD), ("pcPriClassBase", ctypes.c_long), ("dwFlags", wt.DWORD),
                ("szExeFile", ctypes.c_char * 260)]


def _ft(ft):
    """A Windows FILETIME (units of 100 ns) in seconds."""
    return ((ft.dwHighDateTime << 32) | ft.dwLowDateTime) / 1e7


def proc_times(pid):
    """(creation time, CPU seconds) of a running process, or None when it is gone."""
    h = k32.OpenProcess(0x1000, False, pid)          # PROCESS_QUERY_LIMITED_INFORMATION
    if not h:
        return None
    try:
        code = wt.DWORD()
        if not k32.GetExitCodeProcess(h, ctypes.byref(code)) or code.value != 259:   # STILL_ACTIVE
            return None
        c, e, kt, ut = wt.FILETIME(), wt.FILETIME(), wt.FILETIME(), wt.FILETIME()
        if not k32.GetProcessTimes(h, ctypes.byref(c), ctypes.byref(e), ctypes.byref(kt), ctypes.byref(ut)):
            return None
        return _ft(c), _ft(kt) + _ft(ut)
    finally:
        k32.CloseHandle(h)


def children(pid):
    """Process IDs of all descendants of pid."""
    snap = k32.CreateToolhelp32Snapshot(2, 0)        # TH32CS_SNAPPROCESS
    parent = {}
    pe = PROCESSENTRY32()
    pe.dwSize = ctypes.sizeof(PROCESSENTRY32)
    ok = k32.Process32First(snap, ctypes.byref(pe))
    while ok:
        parent[pe.th32ProcessID] = pe.th32ParentProcessID
        ok = k32.Process32Next(snap, ctypes.byref(pe))
    k32.CloseHandle(snap)
    out, todo = [], [pid]
    while todo:
        p = todo.pop()
        for c, pp in parent.items():
            if pp == p and c not in out and c != pid:
                out.append(c)
                todo.append(c)
    return out


def tree_cpu(pid, created):
    """CPU seconds of pid and its descendants; None when pid is gone (or its ID was reused)."""
    t = proc_times(pid)
    if t is None or abs(t[0] - created) > 1.0:
        return None
    cpu = t[1]
    for c in children(pid):
        tc = proc_times(c)
        if tc and tc[0] >= created - 1.0:            # a child cannot be older than its parent
            cpu += tc[1]
    return cpu


def end_process(pid, created):
    """End pid and its children, by ID, if it is still the process first seen."""
    t = proc_times(pid)
    if t is None or abs(t[0] - created) > 1.0:
        return False
    subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, env=dict(os.environ, MSYS_NO_PATHCONV="1"))
    return True


def watch(proj, stall_min=10.0, limit_min=150.0, poll=30.0, done_file=None, pid_wait_min=15.0,
          out=sys.stdout):
    """Watches the gw_sh process of the project folder `proj` and returns the status dict.

    `result` in the dict is "exited" (the run ended by itself), "stalled" (no CPU progress for stall_min minutes, process ended),
    "time-limit" (running longer than limit_min minutes, process ended) or "no-pid" (the process ID file never appeared,
    for pid_wait_min minutes or until done_file exists).  poll is the check interval in seconds.
    """
    pidfile, log = os.path.join(proj, "gw_sh.pid"), os.path.join(proj, "gw_sh.log")
    st = {"pid": None, "result": "no-pid", "wall_s": 0, "cpu_s": 0, "log_quiet_min": 0}
    t0 = time.time()
    while not os.path.exists(pidfile):               # the script first generates the PLL wrappers
        if (done_file and os.path.exists(done_file)) or time.time() - t0 > pid_wait_min * 60:
            return st
        time.sleep(min(poll, 2.0))
    time.sleep(0.5)
    try:
        pid = int(open(pidfile).read().strip())
    except ValueError:
        return st
    st["pid"] = pid
    first = proc_times(pid)
    if first is None:
        st["result"] = "exited"
        return st
    created = first[0]
    last_cpu, last_cpu_t = -1.0, time.time()
    last_size, last_log_t = -1, time.time()
    print(f"gowin_watch: {proj}: watching process {pid}", file=out, flush=True)
    while True:
        now = time.time()
        cpu = tree_cpu(pid, created)
        st["wall_s"] = int(now - t0)
        if cpu is None:
            st["result"] = "exited"
            break
        size = os.path.getsize(log) if os.path.exists(log) else 0
        if size != last_size:
            last_size, last_log_t = size, now
        if cpu > last_cpu + 1.0:                     # at least one CPU second since the last advance
            last_cpu, last_cpu_t = cpu, now
        st["cpu_s"], st["log_quiet_min"] = int(cpu), round((now - last_log_t) / 60, 1)
        why = None
        if now - last_cpu_t > stall_min * 60:
            why = "stalled"
        elif now - t0 > limit_min * 60:
            why = "time-limit"
        if why:
            ended = end_process(pid, created)
            st["result"] = why
            print(f"gowin_watch: {proj}: process {pid} {'ended' if ended else 'was already gone'}: {why} "
                  f"(CPU {int(cpu)} s, no CPU progress for {(now - last_cpu_t) / 60:.0f} min, log quiet for "
                  f"{st['log_quiet_min']:.0f} min, wall {(now - t0) / 60:.0f} min)", file=out, flush=True)
            break
        time.sleep(poll)
    return st


def main():
    """Command line entry: runs watch() with the options, optionally writes the status file and prints one line."""
    ap = argparse.ArgumentParser()
    ap.add_argument("proj")
    ap.add_argument("--stall-min", type=float, default=10.0)
    ap.add_argument("--limit-min", type=float, default=150.0)
    ap.add_argument("--poll", type=float, default=30.0)
    ap.add_argument("--done-file")
    ap.add_argument("--status")
    a = ap.parse_args()
    if k32 is None:
        sys.exit("gowin_watch: Windows only")
    st = watch(a.proj, a.stall_min, a.limit_min, a.poll, a.done_file)
    if a.status:
        json.dump(st, open(a.status, "w"))
    print(f"gowin_watch: {a.proj}: {st['result']}, wall {st['wall_s'] // 60} min, CPU {st['cpu_s'] // 60} min")


if __name__ == "__main__":
    main()
