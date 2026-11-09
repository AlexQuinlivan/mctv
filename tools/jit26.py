# SPDX-License-Identifier: AGPL-3.0-only
# Ports StikDebug's universal JIT script (AGPL-3.0), as bundled by Amethyst-iOS. See LICENSE.AGPL.
"""
jit26.py - the JIT26 debugger protocol for lldb on your build Mac.

This is the protocol StikDebug's "universal" script serves on-device
(Amethyst-iOS Natives/resources/UniversalJIT26.js), plus Amethyst's extension
(UniversalJIT26Extension.js). StikDebug doesn't run on tvOS, so lldb on your
build Mac attaches over the network instead.

App side (shared/jit26_calls.c):
  brk #0xf00d with x16 = command:
    0  detach
    1  prepare region (x0 = addr or 0 to allocate, x1 = len) -> x0 = RX address
    2  "send script" (x0 = text, x1 = len): enables the Amethyst extension
    3  [ext] detach after the first brk #0x69 (x0 != 0)
    4  [ext] rewrite x1 bytes at x0 in place (prepare for patching)
  brk #0x69, x0 = len:
    before the extension: return 0x690000E0 ("universal script present")
    after the extension:  allocate + prepare a region of len bytes -> x0
                          (Amethyst's libjvm uses this for its code cache)

To prepare a region, the debugger writes one byte to every 16 KB page of an
executable mapping while attached (`M<addr>,1:69` packets, as StikDebug does).
On TXM devices (A15+/M2+, iOS/tvOS 26+), only such pages can run code after
detach.

Usage (inside lldb, process attached and stopped):
    command script import /path/to/tools/jit26.py
    jit26 serve [-v]
Before attaching, run this so the JVM's own fault handling doesn't stop in lldb:
    settings set platform.plugin.darwin.ignored-exceptions EXC_BAD_ACCESS|EXC_BAD_INSTRUCTION|EXC_ARITHMETIC
"""
from __future__ import print_function

import os
import re
import shlex
import struct
import sys
import time

import lldb

JIT_PAGE = 0x4000
BRK_MASK, BRK_BASE = 0xFFE0001F, 0xD4200000
LEGACY_UNIVERSAL_MAGIC = 0x690000E0
PASS_SIGNALS = ("SIGSEGV", "SIGBUS", "SIGILL", "SIGFPE", "SIGUSR1", "SIGUSR2", "SIGPIPE",
                "SIGXCPU", "SIGALRM", "SIGURG", "SIGCHLD", "SIGWINCH", "SIGINFO", "SIGIO", "SIGPROF")


def log(msg):
    print("[jit26] " + msg)
    sys.stdout.flush()


class Server(object):
    def __init__(self, debugger, verbose=False):
        self.dbg = debugger
        self.ci = debugger.GetCommandInterpreter()
        self.process = debugger.GetSelectedTarget().GetProcess()
        self.verbose = verbose
        self.extension = False
        self.detach_after_first = False
        self.done = False
        self.regions = []
        self.brks = 0
        self.raw_regs = os.environ.get("JIT26_RAW_REGS") == "1"  # write registers with raw P packets
        self.touch = os.environ.get("JIT26_TOUCH", "byte")  # "byte" sends an M packet per page, "bulk" zero-fills fresh regions

    # -- gdb-remote helpers -------------------------------------------------
    def packet(self, payload):
        ret = lldb.SBCommandReturnObject()
        self.ci.HandleCommand("process plugin packet send '%s'" % payload, ret)
        text = ret.GetOutput() or ""
        m = re.search(r"response:\s*(\S*)", text)
        if not ret.Succeeded() or m is None:
            raise RuntimeError("packet %r failed: %s %s" % (payload[:48], text.strip(), ret.GetError()))
        return m.group(1)

    def alloc_rx(self, size):
        resp = self.packet("_M%x,rx" % size)
        if not resp or resp.startswith("E"):
            raise RuntimeError("_M%x,rx failed: %r" % (size, resp))
        return int(resp, 16)

    def touch_pages(self, addr, size):
        pages = (size + JIT_PAGE - 1) // JIT_PAGE
        t = time.time()
        for i in range(pages):
            resp = self.packet("M%x,1:69" % (addr + i * JIT_PAGE))
            if resp != "OK":
                raise RuntimeError("page write at 0x%x failed: %r" % (addr + i * JIT_PAGE, resp))
            if self.verbose and i and i % 1024 == 0:
                log("  %d/%d pages" % (i, pages))
        dt = max(time.time() - t, 1e-6)
        log("prepared %d pages (%d MB) at 0x%x in %.2f s (%.0f pages/s)"
            % (pages, size >> 20, addr, dt, pages / dt))

    def zero_fill(self, addr, size):
        """Prepare a fresh (all-zero) region by writing zeros over all of it.
        lldb sends big binary packets, so this takes far fewer network round
        trips than one M packet per page. Returns False if lldb refuses."""
        chunk = 1 << 20
        zeros = bytes(chunk)
        t = time.time()
        for off in range(0, size, chunk):
            n = min(chunk, size - off)
            err = lldb.SBError()
            wrote = self.process.WriteMemory(addr + off, zeros[:n], err)
            if not err.Success() or wrote != n:
                log("zero-fill at 0x%x failed (%s, %d/%d bytes), so it writes one page at a time"
                    % (addr + off, err, wrote, n))
                return False
        dt = max(time.time() - t, 1e-6)
        pages = size // JIT_PAGE
        log("zero-filled %d pages (%d MB) at 0x%x in %.2f s (%.0f pages/s)"
            % (pages, size >> 20, addr, dt, pages / dt))
        return True

    def prepare_region(self, addr, size):
        if size == 0:
            return addr
        fresh = addr == 0
        if fresh:
            addr = self.alloc_rx(size)
            log("allocated RX region 0x%x (%d MB)" % (addr, size >> 20))
        # Zero-filling only suits memory we just allocated, which is already zero.
        # An app-supplied region may hold code, so it gets one byte per page.
        if not (fresh and self.touch == "bulk" and self.zero_fill(addr, size)):
            self.touch_pages(addr, size)
        self.regions.append((addr, size))
        return addr

    def rewrite(self, addr, size):
        err = lldb.SBError()
        done = 0
        while done < size:
            n = min(0x10000, size - done)
            data = self.process.ReadMemory(addr + done, n, err)
            if not err.Success():
                raise RuntimeError("read 0x%x failed: %s" % (addr + done, err))
            self.process.WriteMemory(addr + done, data, err)
            if not err.Success():
                raise RuntimeError("write 0x%x failed: %s" % (addr + done, err))
            done += n
        log("rewrote %d bytes at 0x%x" % (size, addr))

    # -- register helpers ---------------------------------------------------
    @staticmethod
    def reg(frame, name):
        return frame.FindRegister(name).GetValueAsUnsigned()

    def regnum(self, name):
        """gdb-remote register number, from debugserver's qRegisterInfo."""
        if not hasattr(self, "_regnums"):
            self._regnums = {}
            for n in range(0, 200):
                info = self.packet("qRegisterInfo%x" % n)
                if not info or info.startswith("E"):
                    break
                fields = dict(kv.split(":", 1) for kv in info.split(";") if ":" in kv)
                for key in ("name", "alt-name", "generic"):
                    if key in fields:
                        self._regnums.setdefault(fields[key], n)
                if "x0" in self._regnums and "pc" in self._regnums:
                    break  # each query is a network round trip on the Apple TV
            if self.verbose:
                log("register numbers: x0=%s pc=%s (%d registers)"
                    % (self._regnums.get("x0"), self._regnums.get("pc"), len(self._regnums)))
        if name not in self._regnums:
            raise RuntimeError("debugserver has no register %s" % name)
        return self._regnums[name]

    def write_reg_raw(self, thread, name, value):
        n, tid = self.regnum(name), thread.GetThreadID()
        le = struct.pack("<Q", value).hex()
        ok = self.packet("P%x=%s;thread:%x;" % (n, le, tid))
        if ok != "OK":
            raise RuntimeError("P packet for %s answered %r" % (name, ok))
        back = self.packet("p%x;thread:%x;" % (n, tid))
        if back != le:
            raise RuntimeError("raw %s: wrote %s, read back %r" % (name, le, back))

    def write_reg(self, thread, name, value):
        # Always go through a fresh frame 0. Writing pc makes lldb rebuild the
        # thread's frames, and a stale frame can't write volatile registers.
        if self.raw_regs:
            return self.write_reg_raw(thread, name, value)
        err = lldb.SBError()
        if thread.GetFrameAtIndex(0).FindRegister(name).SetValueFromCString("0x%x" % value, err):
            got = thread.GetFrameAtIndex(0).FindRegister(name).GetValueAsUnsigned()
            if got == value:
                return
            log("setting %s through lldb: wrote 0x%x, read back 0x%x" % (name, value, got))
        elif not self.raw_regs:
            # Over the network to the Apple TV, lldb can refuse register writes
            # ("unable to write back to register") although reads work. Log its
            # view of the state, then write with raw gdb-remote packets.
            f = thread.GetFrameAtIndex(0)
            log("lldb can't write %s (%s): state=%s stop_id=%d thread valid=%s frame valid=%s. "
                "switching to raw P packets" % (
                    name, err, lldb.SBDebugger.StateAsCString(self.process.GetState()),
                    self.process.GetStopID(), thread.IsValid(), f.IsValid()))
            self.raw_regs = True
        self.write_reg_raw(thread, name, value)

    def reply(self, thread, pc, x0=None):
        """Return from a brk call. The result (if any) goes in x0, then pc moves
        past the brk. x0 goes first because writing pc invalidates the thread's frames."""
        if x0 is not None:
            self.write_reg(thread, "x0", x0)
        self.write_reg(thread, "pc", pc + 4)

    def find_brk(self):
        for thread in self.process:
            if thread.GetStopReason() in (lldb.eStopReasonNone, lldb.eStopReasonInvalid):
                continue
            pc = thread.GetFrameAtIndex(0).GetPC()
            err = lldb.SBError()
            insn = self.process.ReadUnsignedFromMemory(pc, 4, err)
            if err.Success() and (insn & BRK_MASK) == BRK_BASE:
                return thread, pc, (insn >> 5) & 0xFFFF
        return None

    def describe_stop(self):
        parts = []
        for t in self.process:
            r = t.GetStopReason()
            if r in (lldb.eStopReasonNone, lldb.eStopReasonInvalid):
                continue
            parts.append("thread %d reason %d '%s' pc 0x%x" % (
                t.GetIndexID(), r, t.GetStopDescription(256), t.GetFrameAtIndex(0).GetPC()))
        return "; ".join(parts) or "no thread has a stop reason"

    # -- protocol -----------------------------------------------------------
    def handle(self, thread, pc, imm):
        frame = thread.GetFrameAtIndex(0)
        x0, x1, x16 = self.reg(frame, "x0"), self.reg(frame, "x1"), self.reg(frame, "x16")
        if imm not in (0xF00D, 0x69, 0x68):
            log("brk #0x%x at 0x%x is not a JIT26 call, so the process stays stopped" % (imm, pc))
            return False
        self.brks += 1
        if self.verbose:
            log("brk #0x%x x16=0x%x x0=0x%x x1=0x%x (thread %d)" % (imm, x16, x0, x1, thread.GetIndexID()))

        if imm == 0x69:
            if self.extension:
                self.reply(thread, pc, self.prepare_region(0, x0))
                if self.detach_after_first:
                    self.detach()
            else:
                self.reply(thread, pc, LEGACY_UNIVERSAL_MAGIC)
            return True

        result = None
        if imm == 0x68 or x16 == 2:
            err = lldb.SBError()
            text = self.process.ReadMemory(x0, x1, err) if x1 else b""
            self.extension = True
            log("script received (%d bytes): Amethyst extension semantics enabled" % len(text or b""))
        elif x16 == 0:
            self.reply(thread, pc)
            self.detach()
            return True
        elif x16 == 1:
            if not (x0 == 0 and x1 == 0):
                result = self.prepare_region(x0, x1)
        elif x16 == 3 and self.extension:
            self.detach_after_first = x0 != 0
            log("detach after first legacy region: %s" % self.detach_after_first)
        elif x16 == 4 and self.extension:
            self.rewrite(x0, x1)
        else:
            log("unknown command x16=%d (extension=%s), ignored" % (x16, self.extension))
        self.reply(thread, pc, result)
        return True

    def detach(self):
        total = sum(s for _, s in self.regions)
        log("detaching: %d brk calls, %d regions, %d MB prepared" % (self.brks, len(self.regions), total >> 20))
        err = self.process.Detach()
        if not err.Success():
            log("detach failed: %s" % err)
        self.done = True

    def serve(self):
        self.dbg.SetAsync(False)
        for sig in PASS_SIGNALS:
            self.ci.HandleCommand("process handle %s -s false -p true -n false" % sig, lldb.SBCommandReturnObject())
        log("serving JIT26 requests for pid %d" % self.process.GetProcessID())
        while not self.done:
            state = self.process.GetState()
            if state == lldb.eStateExited:
                log("process exited (status %d)" % self.process.GetExitStatus())
                return False
            if state in (lldb.eStateDetached, lldb.eStateInvalid):
                return False
            if state == lldb.eStateStopped:
                found = self.find_brk()
                if found:
                    if not self.handle(*found):
                        return False
                    if self.done:
                        break
                elif self.verbose:
                    log("stop: %s" % self.describe_stop())
            err = self.process.Continue()
            if not err.Success():
                log("continue failed: %s" % err)
                return False
        return True


def jit26_command(debugger, command, exe_ctx, result, internal_dict):
    args = shlex.split(command)
    if not args or args[0] not in ("serve",):
        result.AppendMessage("usage: jit26 serve [-v]")
        return
    server = Server(debugger, verbose="-v" in args)
    try:
        ok = server.serve()
    except Exception as e:  # leave the process stopped for inspection
        log("error: %s" % e)
        ok = False
    result.AppendMessage("jit26: %s" % ("detached" if ok else "stopped without detaching"))
    if not ok:
        result.SetStatus(lldb.eReturnStatusFailed)


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand("command script add -o -f %s.jit26_command jit26" % __name__)
    log("loaded. Once attached, run jit26 serve [-v]")
