#!/usr/bin/env python3
"""Write first-run Minecraft options that suit a TV, unless options.txt exists.

    python3 -I scripts/mc-profile.py [--jar <client jar>] <options.txt path> [pack | -pack ...]
    python3 -I scripts/mc-profile.py --servers-dat <path> NAME=ADDRESS [...]

Each pack is enabled in options.txt, and "-name" disables one. --jar stamps new
options with the game's data version. Without it Minecraft takes the file for a
very old one and upgrades it, and the upgrade resets the renderer to OpenGL.
--servers-dat writes Minecraft's server list as uncompressed NBT.
"""
import json
import os
import struct
import sys
import zipfile

# Minecraft applies graphicsPreset at every start and treats a missing one as
# "fancy" (16 chunks), so "custom" keeps these settings.
OPTIONS = """\
onboardAccessibility:false
skipMultiplayerWarning:true
joinedFirstServer:true
tutorialStep:none
fullscreen:false
graphicsPreset:"custom"
renderDistance:8
simulationDistance:6
maxFps:60
graphicsMode:0
narrator:0
soundCategory_music:0.3
"""


def nbt_string(text):
    data = text.encode("utf-8")
    return struct.pack(">H", len(data)) + data


def nbt_named(tag, name, payload):
    return bytes([tag]) + nbt_string(name) + payload


def write_servers_dat(path, servers):
    """servers is a list of (name, address). The file is TAG_Compound "" { TAG_List "servers" of compounds }."""
    TAG_END, TAG_STRING, TAG_LIST, TAG_COMPOUND = 0, 8, 9, 10
    entries = b"".join(nbt_named(TAG_STRING, "name", nbt_string(n)) +
                       nbt_named(TAG_STRING, "ip", nbt_string(a)) + bytes([TAG_END])
                       for n, a in servers)
    servers_list = nbt_named(TAG_LIST, "servers", bytes([TAG_COMPOUND]) + struct.pack(">i", len(servers)) + entries)
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "wb") as f:
        f.write(nbt_named(TAG_COMPOUND, "", servers_list + bytes([TAG_END])))
    print("[profile] server list %s: %s" % (path, ", ".join("%s=%s" % s for s in servers)))


def main():
    if sys.argv[1] == "--servers-dat":
        return write_servers_dat(sys.argv[2], [tuple(a.split("=", 1)) for a in sys.argv[3:]])
    args = sys.argv[1:]
    jar = None
    if args[0] == "--jar":
        jar, args = args[1], args[2:]
    options, packs = args[0], args[1:]
    if not os.path.exists(options):
        os.makedirs(os.path.dirname(options), exist_ok=True)
        with open(options, "w") as f:
            if jar:
                with zipfile.ZipFile(jar) as z:
                    f.write("version:%d\n" % json.loads(z.read("version.json"))["world_version"])
            f.write(OPTIONS)
    if packs:
        enable_packs(options, packs)
    print("[profile] options %s, packs %s" % (options, packs or "-"))


def enable_packs(options, packs):
    lines = open(options).read().splitlines()
    current = ["vanilla"]
    for line in lines:
        if line.startswith("resourcePacks:"):
            current = json.loads(line.split(":", 1)[1])
    for p in packs:
        if p.startswith("-"):
            current = [c for c in current if c != "file/" + p[1:]]
        elif "file/" + p not in current:
            current.append("file/" + p)
    lines = [l for l in lines if not l.startswith("resourcePacks:")]
    lines.append("resourcePacks:" + json.dumps(current, separators=(",", ":")))
    with open(options, "w") as f:
        f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
