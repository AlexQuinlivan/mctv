#!/usr/bin/env python3
"""One debug link to the Apple TV for jitd, in its own short-lived process.

    tvlink.py --pid N --bundle ID[,ID...] [--identifier UDID] [--ddi RESTORE_DIR]

Opens a userspace tunnel to the TV over Wi-Fi with pymobiledevice3 (no root),
mounts the developer disk image if the TV has none, checks that N is the pid the
TV reports for one of the bundles, and forwards the TV's debugserver to a
loopback port. Prints "PORT <n>" and holds the link until stdin closes, or
prints "ERROR <why>" and exits 1.

--ddi is a copy of Xcode's /Library/Developer/DeveloperDiskImages/tvOS_DDI/Restore.
Without it pymobiledevice3 downloads the image.
"""
import argparse
import asyncio
import sys
import time

DEBUGPROXY = "com.apple.internal.dt.remote.debugproxy"


def say(line):
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def note(msg):
    sys.stderr.write("%s tvlink: %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg))
    sys.stderr.flush()


class Tunnel(object):
    """Userspace (no root) tunnel to a TV paired over Wi-Fi.

    pymobiledevice3's UserspaceRsdTunnel always starts with a USB lookup, which
    an Apple TV can never satisfy. This builds the same tunnel from the
    RemotePairing service found over bonjour, with packets going through
    pymobiledevice3's in-process TCP/IP stack instead of a utun device. It uses
    pymobiledevice3 internals, so requirements.txt pins the version."""

    def __init__(self, identifier):
        self.identifier = identifier
        self.stack = None

    async def open(self):
        from contextlib import AsyncExitStack
        from pymobiledevice3.remote import tunnel_service
        from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService
        from pymobiledevice3.remote.userspace_tunnel import UserspaceDialPlane

        t = time.time()
        services = await tunnel_service.get_remote_pairing_tunnel_services(udid=self.identifier)
        if not services:
            raise RuntimeError("no paired TV answered over bonjour (is it awake, and paired with "
                               "`pymobiledevice3 remote pair` as this user?)")
        provider = services[0]
        for extra in services[1:]:
            await extra.close()
        tunnel_service.USE_USERSPACE_TUNNEL = True
        self.stack = AsyncExitStack()
        try:
            self.stack.push_async_callback(provider.close)
            result = await self.stack.enter_async_context(provider.start_tcp_tunnel())
            tun = result.client.tun
            tun.set_peer(result.address)
            dial = await self.stack.enter_async_context(UserspaceDialPlane(tun, result.address))
            rsd = RemoteServiceDiscoveryService((result.address, result.port), open_connection=dial.dial,
                                                auxiliary_metadata=result.auxiliary_metadata)
            self.stack.push_async_callback(rsd.close)
            await rsd.connect()
        except BaseException:
            await self.aclose()
            raise
        note("tunnel to %s up in %.1f s" % (rsd.udid, time.time() - t))
        return rsd

    async def aclose(self):
        if self.stack is not None:
            stack, self.stack = self.stack, None
            await stack.aclose()


async def open_tunnel(identifier):
    tunnel = Tunnel(identifier)
    rsd = await asyncio.wait_for(tunnel.open(), 60)
    return tunnel, rsd


async def run(args):
    from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
    from pymobiledevice3.services.dvt.instruments.process_control import ProcessControl
    from pymobiledevice3.tcp_forwarder import LockdownTcpForwarder

    tunnel, rsd = await open_tunnel(args.identifier)
    try:
        if DEBUGPROXY not in (rsd.peer_info or {}).get("Services", {}):
            # The TV has no developer disk image mounted after a reboot.
            if args.ddi:
                from pathlib import Path
                from pymobiledevice3.services.cryptexd import CryptexdService
                note("installing the developer disk image from %s" % args.ddi)
                await CryptexdService(rsd).auto_install_ddi(restore_dir=Path(args.ddi))
            else:
                from pymobiledevice3.services.mobile_image_mounter import auto_mount
                note("mounting the developer disk image (pymobiledevice3 downloads it)")
                await auto_mount(rsd)
            await tunnel.aclose()
            tunnel, rsd = await open_tunnel(args.identifier)
        bundles = [b for b in args.bundle.split(",") if b]
        running = {}
        async with DvtProvider(rsd) as dvt, ProcessControl(dvt) as pc:
            for b in bundles:
                try:
                    running[b] = await pc.process_identifier_for_bundle_identifier(b)
                except Exception:  # not installed, or not running
                    running[b] = None
        if args.pid not in running.values():
            raise RuntimeError("pid %s isn't one of the apps (%s)" % (
                args.pid, ", ".join("%s as %s" % (b, p) for b, p in running.items())))
        listening = asyncio.Event()
        forwarder = LockdownTcpForwarder(rsd, 0, DEBUGPROXY, listening_event=listening)
        task = asyncio.ensure_future(forwarder.start())
        waiter = asyncio.ensure_future(listening.wait())
        await asyncio.wait({task, waiter}, return_when=asyncio.FIRST_COMPLETED)
        if not listening.is_set():
            task.result()
        say("PORT %d" % forwarder.listening_port)
        # Hold the link until jitd closes our stdin.
        loop = asyncio.get_running_loop()
        await loop.run_in_executor(None, sys.stdin.read)
        waiter.cancel()
        forwarder.stop()
        await asyncio.gather(task, return_exceptions=True)
    finally:
        await tunnel.aclose()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pid", type=int, required=True)
    ap.add_argument("--identifier", default=None)
    ap.add_argument("--bundle", required=True, help="bundle IDs, comma separated")
    ap.add_argument("--ddi", default=None, help="unpacked tvOS DDI Restore directory")
    args = ap.parse_args()
    try:
        asyncio.run(run(args))
    except Exception as e:
        say("ERROR %s: %s" % (type(e).__name__, e))
        sys.exit(1)


if __name__ == "__main__":
    main()
