#!/usr/bin/env python3
"""Stage what the app needs in Library/Caches/mctv, as hard links into
the downloaded game directory so it takes no extra disk space.

    python3 -I scripts/mc-stage.py <game dir> <version> <stage dir> [--lite | --full] [--launch ID]

By default assets include music and records but only the en_us language (about
440 MB). --lite also leaves out music and records (about 180 MB), for quick
test pushes. --full adds every language (about 530 MB). --launch ID also stages
a version that inherits from <version> (Fabric) plus mods/, and makes it the
one the app launches.
"""
import json
import os
import shutil
import sys

MUSIC = ("minecraft/sounds/music/", "minecraft/sounds/records/")


def link(src, dst):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if os.path.exists(dst):
        if os.path.samefile(src, dst):
            return 0
        os.remove(dst)
    os.link(src, dst)
    return os.path.getsize(src)


def skip(name, mode):
    if mode == "full":
        return False
    if name.startswith(MUSIC):
        return mode == "lite"
    return name.startswith("minecraft/lang/") and name != "minecraft/lang/en_us.json"


def main():
    game, version, stage = sys.argv[1], sys.argv[2], sys.argv[3]
    mode = "full" if "--full" in sys.argv[4:] else "lite" if "--lite" in sys.argv[4:] else "default"
    launch = sys.argv[sys.argv.index("--launch") + 1] if "--launch" in sys.argv else version
    out = os.path.join(stage, "minecraft")
    # Start afresh so nothing left out this time lingers from an earlier stage.
    for sub in ("versions", "libraries", "assets", "mods"):
        shutil.rmtree(os.path.join(out, sub), ignore_errors=True)
    info = json.load(open(os.path.join(game, "versions", version, version + ".json")))
    total = 0
    for name in (version + ".json", version + ".jar"):
        rel = os.path.join("versions", version, name)
        total += link(os.path.join(game, rel), os.path.join(out, rel))
    if launch != version:
        for name in (launch + ".json", launch + ".jar"):
            rel = os.path.join("versions", launch, name)
            total += link(os.path.join(game, rel), os.path.join(out, rel))
        mods = os.path.join(game, "mods")
        for name in open(os.path.join(mods, ".mctv-managed")).read().split():
            total += link(os.path.join(mods, name), os.path.join(out, "mods", name))
    for root, _, files in os.walk(os.path.join(game, "libraries")):
        for f in files:
            src = os.path.join(root, f)
            total += link(src, os.path.join(out, os.path.relpath(src, game)))
    logging = info.get("logging", {}).get("client", {}).get("file", {}).get("id")
    if logging:
        total += link(os.path.join(game, logging), os.path.join(out, logging))
    idx = info["assetIndex"]["id"]
    rel = os.path.join("assets", "indexes", idx + ".json")
    total += link(os.path.join(game, rel), os.path.join(out, rel))
    skipped = 0
    for name, obj in json.load(open(os.path.join(game, rel)))["objects"].items():
        if skip(name, mode):
            skipped += obj["size"]
            continue
        h = obj["hash"]
        rel_obj = os.path.join("assets", "objects", h[:2], h)
        total += link(os.path.join(game, rel_obj), os.path.join(out, rel_obj))
    with open(os.path.join(out, "mctv-version.txt"), "w") as f:
        f.write(launch + "\n")
    print("[stage] %s: %.0f MB staged%s" % (launch, total / 1048576,
          "" if not skipped else ", %.0f MB of %s left out" % (skipped / 1048576, "music, records and languages" if mode == "lite" else "languages")))


if __name__ == "__main__":
    main()
