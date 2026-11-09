# SPDX-License-Identifier: AGPL-3.0-only
# Ports StikDebug's universal JIT script (AGPL-3.0), as bundled by Amethyst-iOS. See LICENSE.AGPL.
"""The JIT26 handshake over gdb-remote, the same one tools/jit26.py serves in lldb.

The app (shared/jit26_calls.c) calls the debugger with brk instructions.

  brk #0xf00d, x16 = command
    0  detach
    1  prepare region (x0 = addr or 0 to allocate, x1 = len), returns the RX address
    2  "send script", turns on Amethyst's extension semantics (brk #0x68 does too)
    3  [ext] detach after the first brk #0x69 if x0 != 0
    4  [ext] rewrite x1 bytes at x0 in place
  brk #0x69, x0 = len
    before the extension, returns 0x690000E0 ("universal script present")
    after it, allocates and prepares a region of len bytes for libjvm's code cache

Preparing a region means writing one byte to each 16 KB page while attached.
On TXM devices only those pages can run code after the debugger detaches.
"""
import time

from gdbremote import GDBError

JIT_PAGE = 0x4000
BRK_MASK, BRK_BASE = 0xFFE0001F, 0xD4200000
LEGACY_UNIVERSAL_MAGIC = 0x690000E0
SIGTRAP, SIGSTOP = 5, 17
IGNORED_EXCEPTIONS = ("EXC_BAD_ACCESS", "EXC_BAD_INSTRUCTION", "EXC_ARITHMETIC")


class Session(object):
    def __init__(self, gdb, pid, log, max_seconds=600):
        self.gdb = gdb
        self.pid = pid
        self.log = log
        self.max_seconds = max_seconds
        self.extension = False
        self.detach_after_first = False
        self.done = False
        self.regions = []
        self.brks = 0
        self.signals = 0
        self.prepare_seconds = 0.0

    def attach(self, expect_suffix=None):
        """Attach, check the process is ours, and leave it running.
        If it's some other process, detach at once and raise."""
        g = self.gdb
        g.start()
        g.set_ignored_exceptions(IGNORED_EXCEPTIONS)
        t = time.time()
        g.attach(self.pid)
        if expect_suffix:
            path = g.main_executable()
            if not path or not path.endswith(expect_suffix):
                g.detach()
                raise GDBError("process %d is %r, not .../%s, so detached" % (self.pid, path, expect_suffix))
        g.load_register_numbers()
        self.log("attached to %d in %.2f s" % (self.pid, time.time() - t))
        g.cont()

    def serve(self):
        """Handle brk calls until the app asks to detach. Returns True on a clean detach."""
        deadline = time.time() + self.max_seconds
        while not self.done:
            left = deadline - time.time()
            if left <= 0:
                self.log("no detach request after %d s, detaching" % self.max_seconds)
                self.gdb.sock.sendall(b"\x03")
                self.gdb.wait_stop(10)
                self.detach()
                return False
            stop = self.gdb.wait_stop(left)
            if stop.kind in ("exit", "killed"):
                self.log("process %s (%s)" % (stop.kind, stop.raw))
                return False
            if stop.kind != "stop":
                raise GDBError("unexpected reply while running: %r" % stop.raw)
            if stop.signal == SIGTRAP:
                if not self.handle_trap(stop):
                    return False
            elif stop.signal == SIGSTOP:
                self.gdb.cont()
            else:
                # HotSpot raises SIGSEGV and others on purpose. Pass them on.
                self.signals += 1
                self.gdb.cont_signal(stop.thread, stop.signal)
        return True

    def handle_trap(self, stop):
        g, tid = self.gdb, stop.thread
        regs = g.read_registers(tid, ("x0", "x1", "x16", "pc"))
        pc = regs["pc"]
        insn = int.from_bytes(g.read_memory(pc, 4), "little")
        if (insn & BRK_MASK) != BRK_BASE:
            self.log("SIGTRAP at 0x%x is not a brk (0x%08x); continuing" % (pc, insn))
            g.cont()
            return True
        imm = (insn >> 5) & 0xFFFF
        if imm not in (0xF00D, 0x69, 0x68):
            self.log("brk #0x%x at 0x%x is not a JIT26 call, detaching" % (imm, pc))
            self.detach()
            return False
        self.brks += 1
        x0, x1, x16 = regs["x0"], regs["x1"], regs["x16"]
        self.log("brk #0x%x x16=%d x0=0x%x x1=0x%x" % (imm, x16, x0, x1))

        if imm == 0x69:
            if self.extension:
                self.reply(tid, pc, self.prepare(0, x0))
                if self.detach_after_first:
                    return self.detach()
            else:
                self.reply(tid, pc, LEGACY_UNIVERSAL_MAGIC)
            g.cont()
            return True

        result = None
        if imm == 0x68 or x16 == 2:
            self.extension = True
            self.log("script received: Amethyst extension semantics on")
        elif x16 == 0:
            self.reply(tid, pc)
            return self.detach()
        elif x16 == 1:
            if not (x0 == 0 and x1 == 0):
                result = self.prepare(x0, x1)
        elif x16 == 3 and self.extension:
            self.detach_after_first = x0 != 0
        elif x16 == 4 and self.extension:
            self.rewrite(x0, x1)
        else:
            self.log("unknown command x16=%d (extension %s), ignored" % (x16, self.extension))
        self.reply(tid, pc, result)
        g.cont()
        return True

    def reply(self, tid, pc, x0=None):
        values = ([("x0", x0)] if x0 is not None else []) + [("pc", pc + 4)]
        self.gdb.write_registers(tid, values)

    def prepare(self, addr, size):
        if size == 0:
            return addr
        if addr == 0:
            addr = self.gdb.allocate(size, "rx")
        t = time.time()
        pages = self.gdb.touch_pages(addr, size, JIT_PAGE)
        dt = max(time.time() - t, 1e-6)
        self.prepare_seconds += dt
        self.regions.append((addr, size))
        self.log("prepared %d pages (%d MB) at 0x%x in %.2f s (%.0f pages/s)"
                 % (pages, size >> 20, addr, dt, pages / dt))
        return addr

    def rewrite(self, addr, size):
        done = 0
        while done < size:
            n = min(0x4000, size - done)
            self.gdb.write_memory(addr + done, self.gdb.read_memory(addr + done, n))
            done += n
        self.log("rewrote %d bytes at 0x%x" % (size, addr))

    def detach(self):
        total = sum(s for _, s in self.regions)
        resp = self.gdb.detach()
        self.log("detached (%s): %d brk calls, %d signals passed, %d MB prepared in %.2f s"
                 % (resp, self.brks, self.signals, total >> 20, self.prepare_seconds))
        self.done = True
        return True
