#!/usr/bin/env python3
"""jitd gives the MCTV app JIT at launch.

    python3 jitd.py [--config jitd.env]

    POST /jit      {"pid": 1234, "token": "..."}
    POST /hook     {"token": "..."}
    GET  /health

The app (mctv/Sources/JVM.m) starts without a debugger, posts its pid to /jit
and waits. jitd attaches, serves the JIT26 handshake (session.py) and detaches.

/jit and /health answer only JITD_ALLOW addresses, and /jit needs JITD_TOKEN,
the secret built into the app. jitd only attaches to a process whose executable
is MCTV.app/MCTV, and on the TV only to a pid the TV reports for one of the
JITD_BUNDLE_ID apps.

Optional. JITD_ON_JIT is a command to run in the background whenever the TV
asks for JIT, for example to start a game server. With JITD_HOOK_TOKEN set,
another program on a JITD_HOOK_ALLOW address can run it too, with POST /hook.

jitd reaches the Apple TV over Wi-Fi through tvlink.py, paired once with
`pymobiledevice3 remote pair`. Settings come from the environment or from
KEY=VALUE lines in the --config file. See jitd.env.example.
"""
import argparse
import hmac
import http.server
import json
import os
import shlex
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gdbremote import GDBError, GDBRemote  # noqa: E402
from session import Session  # noqa: E402

EXPECT_SUFFIX = "MCTV.app/MCTV"


def log(msg):
    sys.stderr.write("%s jitd: %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg))
    sys.stderr.flush()


def load_config(path):
    cfg = {}
    if path:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    cfg[k.strip()] = v.strip()
    for k, v in os.environ.items():
        if k.startswith("JITD_"):
            cfg[k] = v
    return cfg


# -- backends ------------------------------------------------------------------

class TVBackend(object):
    """The Apple TV over Wi-Fi. tvlink.py runs per request in its own process,
    so pymobiledevice3 only holds memory while a game starts."""

    def __init__(self, cfg):
        here = os.path.dirname(os.path.abspath(__file__))
        self.ssh = cfg.get("JITD_TV_SSH")
        if self.ssh:
            # macOS Local Network privacy keeps launchd jobs off the LAN but not
            # SSH sessions. So tvlink runs over SSH to localhost, with a key that
            # authorized_keys pins to tvlink-ssh.sh.
            conf = os.path.dirname(cfg.get("JITD_TV_SSH_KEY", ""))
            self.cmd = ["ssh", "-F", "/dev/null", "-T", "-i", cfg["JITD_TV_SSH_KEY"],
                        "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none", "-o", "BatchMode=yes",
                        "-o", "StrictHostKeyChecking=accept-new",
                        "-o", "UserKnownHostsFile=%s" % os.path.join(conf, "known_hosts"),
                        "-o", "LogLevel=ERROR", self.ssh, "tvlink"]
            return
        self.cmd = [cfg.get("JITD_TV_PYTHON", sys.executable), os.path.join(here, "tvlink.py"),
                    "--bundle", cfg.get("JITD_BUNDLE_ID") or sys.exit("jitd: set JITD_BUNDLE_ID")]
        if cfg.get("JITD_TV_IDENTIFIER"):
            self.cmd += ["--identifier", cfg["JITD_TV_IDENTIFIER"]]
        if cfg.get("JITD_DDI_DIR"):
            self.cmd += ["--ddi", cfg["JITD_DDI_DIR"]]
        self.cmd.append("--pid")

    def open(self, pid):
        import select
        proc = subprocess.Popen(self.cmd + [str(pid)], stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, text=True)
        line = ""
        if select.select([proc.stdout], [], [], 120)[0]:
            line = proc.stdout.readline().strip()

        def close():
            try:
                proc.stdin.close()
                proc.wait(15)
            except (OSError, subprocess.TimeoutExpired):
                proc.terminate()

        if not line.startswith("PORT "):
            close()
            raise GDBError(line[6:] if line.startswith("ERROR ") else "tvlink gave no port (%r)" % line)
        try:
            gdb = GDBRemote.connect("127.0.0.1", int(line[5:]), timeout=10, log=log)
        except Exception:
            close()
            raise

        def close_all():
            gdb.close()
            close()
        return gdb, close_all


def run_hook(cfg, wait=False):
    """Runs JITD_ON_JIT. Returns (ok, message), and without wait runs in the background."""
    cmd = shlex.split(cfg.get("JITD_ON_JIT", ""))
    if not cmd:
        return False, "no JITD_ON_JIT command"
    result = {}

    def run():
        r = subprocess.run(cmd, capture_output=True, text=True)
        result["ok"] = r.returncode == 0
        result["msg"] = "done" if r.returncode == 0 else r.stderr.strip()
        log("%s: %s" % (cmd[0], "ok" if r.returncode == 0 else r.stderr.strip()))
    if not wait:
        threading.Thread(target=run, daemon=True).start()
        return True, "started"
    run()
    return result["ok"], result["msg"]


# -- HTTP ----------------------------------------------------------------------

class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, addr, cfg, backend):
        super().__init__(addr, Handler)
        self.cfg = cfg
        self.backend = backend
        self.allow = {a.strip() for a in cfg.get("JITD_ALLOW", "").split(",") if a.strip()}
        self.token = cfg.get("JITD_TOKEN", "")
        self.hook_token = cfg.get("JITD_HOOK_TOKEN", "")
        self.hook_allow = {a.strip() for a in cfg.get("JITD_HOOK_ALLOW", "").split(",") if a.strip()}
        self.busy = threading.Lock()
        if not self.allow or not self.token:
            raise SystemExit("JITD_ALLOW and JITD_TOKEN must both be set")


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "jitd/1"

    def log_message(self, fmt, *args):
        pass

    def reply(self, code, ok, message):
        body = json.dumps({"ok": ok, "message": message}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def allowed(self):
        if self.client_address[0] in self.server.allow:
            return True
        log("refused %s %s from %s" % (self.command, self.path, self.client_address[0]))
        self.reply(403, False, "not allowed from this address")
        return False

    def do_GET(self):
        if not self.allowed():
            return
        if self.path != "/health":
            return self.reply(404, False, "not found")
        self.reply(200, True, "busy" if self.server.busy.locked() else "idle")

    def do_POST(self):
        if self.path == "/hook":
            return self.hook()
        if not self.allowed():
            return
        if self.path != "/jit":
            return self.reply(404, False, "not found")
        try:
            length = int(self.headers.get("Content-Length", "0"))
            req = json.loads(self.rfile.read(min(length, 4096)) or b"{}")
            pid = int(req.get("pid", 0))
            token = str(req.get("token", ""))
        except (ValueError, TypeError):
            return self.reply(400, False, "bad request")
        if not hmac.compare_digest(token.encode(), self.server.token.encode()):
            log("bad token from %s" % self.client_address[0])
            return self.reply(403, False, "bad token")
        if pid <= 0:
            return self.reply(400, False, "bad pid")
        if not self.server.busy.acquire(blocking=False):
            return self.reply(409, False, "another JIT session is running")
        log("JIT for pid %d from %s" % (pid, self.client_address[0]))
        run_hook(self.server.cfg)
        try:
            gdb, close = self.server.backend.open(pid)
        except Exception as e:
            self.server.busy.release()
            log("can't reach the debugger for pid %d: %s" % (pid, e))
            return self.reply(502, False, "can't reach the debugger: %s" % e)
        session = Session(gdb, pid, log)
        try:
            session.attach(EXPECT_SUFFIX)
        except Exception as e:
            close()
            self.server.busy.release()
            log("attach to %d failed: %s" % (pid, e))
            return self.reply(500, False, "attach failed: %s" % e)
        threading.Thread(target=self.serve_session, args=(session, close), daemon=True).start()
        self.reply(200, True, "attached")

    def hook(self):
        srv = self.server
        if not srv.hook_token or self.client_address[0] not in srv.hook_allow:
            log("refused /hook from %s" % self.client_address[0])
            return self.reply(403, False, "not allowed")
        try:
            req = json.loads(self.rfile.read(min(int(self.headers.get("Content-Length", "0")), 4096)) or b"{}")
        except ValueError:
            return self.reply(400, False, "bad request")
        if not hmac.compare_digest(str(req.get("token", "")).encode(), srv.hook_token.encode()):
            log("bad hook token from %s" % self.client_address[0])
            return self.reply(403, False, "bad token")
        ok, msg = run_hook(srv.cfg, wait=True)
        self.reply(200 if ok else 500, ok, msg)

    def serve_session(self, session, close):
        try:
            session.serve()
        except Exception as e:
            log("session for pid %d ended with an error: %s" % (session.pid, e))
        finally:
            close()
            self.server.busy.release()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--config", help="KEY=VALUE file (environment variables override it)")
    args = ap.parse_args()
    cfg = load_config(args.config)
    backend = TVBackend(cfg)
    host, _, port = cfg.get("JITD_LISTEN", "127.0.0.1:25566").rpartition(":")
    server = Server((host, int(port)), cfg, backend)
    log("listening on %s:%s, allowing %s" % (host, port, ", ".join(sorted(server.allow))))
    server.serve_forever()


if __name__ == "__main__":
    main()
