"""Minimal gdb-remote client for Apple's debugserver, used by jitd.

It does only what the JIT26 handshake needs, and pipelines requests. lldb waits
for each reply before sending the next packet, so preparing 4096 pages costs
4096 network round trips. Here they go out in batches and the replies are read
afterwards.
"""
import socket
import struct
import time

STOP_SIGNALS = {"T", "S"}


class GDBError(RuntimeError):
    pass


class Stop(object):
    """A stop reply. kind is "stop", "exit" or "killed"."""

    def __init__(self, payload):
        self.raw = payload
        self.kind = {"T": "stop", "S": "stop", "W": "exit", "X": "killed"}.get(payload[:1], "other")
        self.signal = int(payload[1:3], 16) if len(payload) >= 3 and self.kind != "other" else 0
        self.fields = {}
        if payload[:1] == "T":
            for part in payload[3:].split(";"):
                if ":" in part:
                    k, v = part.split(":", 1)
                    self.fields.setdefault(k, v)
        self.thread = int(self.fields["thread"], 16) if "thread" in self.fields else None

    def __repr__(self):
        return "Stop(%s sig=%d thread=%s reason=%s)" % (
            self.kind, self.signal, self.thread, self.fields.get("reason"))


class GDBRemote(object):
    def __init__(self, sock, log=None, batch=512):
        self.sock = sock
        self.log = log or (lambda msg: None)
        self.batch = batch
        self.buf = b""
        self.noack = False
        self.regnums = {}

    @classmethod
    def connect(cls, host, port, timeout=10, **kw):
        last = None
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                sock = socket.create_connection((host, port), timeout=timeout)
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                return cls(sock, **kw)
            except OSError as e:
                last = e
                time.sleep(0.1)
        raise GDBError("can't connect to debugserver at %s:%s: %s" % (host, port, last))

    # -- framing ----------------------------------------------------------
    @staticmethod
    def frame(payload):
        data = payload.encode("latin-1")
        return b"$" + data + b"#" + b"%02x" % (sum(data) & 0xFF)

    def _fill(self, timeout):
        self.sock.settimeout(timeout)
        try:
            chunk = self.sock.recv(65536)
        except socket.timeout:
            raise GDBError("debugserver didn't answer within %s s" % timeout)
        if not chunk:
            raise GDBError("debugserver closed the connection")
        self.buf += chunk

    def recv(self, timeout=30):
        """Next packet payload (acks and notifications skipped)."""
        while True:
            start = self.buf.find(b"$")
            if start < 0:
                self.buf = b""
                self._fill(timeout)
                continue
            end = self.buf.find(b"#", start)
            if end < 0 or len(self.buf) < end + 3:
                self._fill(timeout)
                continue
            raw = self.buf[start + 1:end]
            self.buf = self.buf[end + 3:]
            if not self.noack:
                self.sock.sendall(b"+")
            return self.decode(raw)

    @staticmethod
    def decode(raw):
        out = bytearray()
        i = 0
        while i < len(raw):
            c = raw[i]
            if c == 0x7D:  # escaped byte
                out.append(raw[i + 1] ^ 0x20)
                i += 2
            elif c == 0x2A and out:  # run-length, repeats the previous byte
                out.extend(out[-1:] * (raw[i + 1] - 29))
                i += 2
            else:
                out.append(c)
                i += 1
        return out.decode("latin-1")

    def send(self, payload):
        self.sock.sendall(self.frame(payload))

    def request(self, payload, timeout=30):
        self.send(payload)
        return self.recv(timeout)

    def pipeline(self, payloads, timeout=60):
        """Send many packets, then collect their replies in order."""
        replies = []
        for i in range(0, len(payloads), self.batch):
            chunk = payloads[i:i + self.batch]
            self.sock.sendall(b"".join(self.frame(p) for p in chunk))
            for _ in chunk:
                replies.append(self.recv(timeout))
        return replies

    # -- session ----------------------------------------------------------
    def start(self):
        self.sock.sendall(b"+")
        resp = self.request("QStartNoAckMode")
        if resp != "OK":
            raise GDBError("QStartNoAckMode answered %r" % resp)
        self.noack = True

    def set_ignored_exceptions(self, names):
        resp = self.request("QSetIgnoredExceptions:" + "|".join(names))
        if resp != "OK":
            self.log("debugserver didn't accept QSetIgnoredExceptions (%r); faults will stop in the debugger" % resp)

    def main_executable(self):
        """Path of the attached process's main executable (MH_EXECUTE image)."""
        import json
        resp = self.request('jGetLoadedDynamicLibrariesInfos:{"fetch_all_solibs":true}')
        try:
            images = json.loads(resp).get("images", [])
        except ValueError:
            raise GDBError("jGetLoadedDynamicLibrariesInfos answered %r" % resp[:80])
        for image in images:
            if image.get("mach_header", {}).get("filetype") == 2:
                return image.get("pathname")
        return None

    def attach(self, pid, timeout=30):
        self.send("vAttach;%x" % pid)
        stop = self.wait_stop(timeout)
        if stop.kind != "stop":
            raise GDBError("attach to %d failed: %r" % (pid, stop.raw))
        return stop

    def wait_stop(self, timeout=None):
        while True:
            payload = self.recv(timeout)
            if payload[:1] == "O":  # inferior output
                continue
            if payload.startswith("E"):
                raise GDBError("debugserver error %s" % payload)
            return Stop(payload)

    def cont(self):
        self.send("vCont;c")

    def cont_signal(self, thread, signal):
        self.send("vCont;C%02x:%x;c" % (signal, thread))

    def detach(self):
        try:
            return self.request("D", timeout=10)
        except GDBError as e:
            return str(e)

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass

    # -- registers ----------------------------------------------------------
    def load_register_numbers(self, wanted=("x0", "x1", "x16", "pc")):
        replies = self.pipeline(["qRegisterInfo%x" % n for n in range(0, 40)])
        for n, info in enumerate(replies):
            if not info or info.startswith("E"):
                break
            fields = dict(kv.split(":", 1) for kv in info.split(";") if ":" in kv)
            for key in ("name", "alt-name", "generic"):
                if key in fields:
                    self.regnums.setdefault(fields[key], n)
        missing = [w for w in wanted if w not in self.regnums]
        if missing:
            raise GDBError("debugserver has no register(s) %s" % ", ".join(missing))

    def read_registers(self, thread, names):
        replies = self.pipeline(["p%x;thread:%x;" % (self.regnums[n], thread) for n in names])
        out = {}
        for name, hexval in zip(names, replies):
            if not hexval or hexval.startswith("E"):
                raise GDBError("reading %s on thread %x: %r" % (name, thread, hexval))
            out[name] = struct.unpack("<Q", bytes.fromhex(hexval[:16]))[0]
        return out

    def write_registers(self, thread, values):
        """Write a list of (name, value) pairs, in order."""
        payloads = ["P%x=%s;thread:%x;" % (self.regnums[n], struct.pack("<Q", v).hex(), thread)
                    for n, v in values]
        for (name, _), resp in zip(values, self.pipeline(payloads)):
            if resp != "OK":
                raise GDBError("writing %s answered %r" % (name, resp))

    # -- memory -------------------------------------------------------------
    def read_memory(self, addr, size):
        resp = self.request("m%x,%x" % (addr, size))
        if resp.startswith("E") and len(resp) == 3:
            raise GDBError("read 0x%x,%d: %s" % (addr, size, resp))
        return bytes.fromhex(resp)

    def write_memory(self, addr, data):
        resp = self.request("M%x,%x:%s" % (addr, len(data), data.hex()))
        if resp != "OK":
            raise GDBError("write 0x%x,%d: %r" % (addr, len(data), resp))

    def allocate(self, size, perms="rx"):
        resp = self.request("_M%x,%s" % (size, perms))
        if not resp or resp.startswith("E"):
            raise GDBError("_M%x,%s failed: %r" % (size, perms, resp))
        return int(resp, 16)

    def touch_pages(self, addr, size, page):
        """Write one byte (0x69, as StikDebug does) to every page, pipelined."""
        pages = (size + page - 1) // page
        replies = self.pipeline(["M%x,1:69" % (addr + i * page) for i in range(pages)])
        bad = [(i, r) for i, r in enumerate(replies) if r != "OK"]
        if bad:
            i, r = bad[0]
            raise GDBError("page write at 0x%x answered %r (%d failures)" % (addr + i * page, r, len(bad)))
        return pages
