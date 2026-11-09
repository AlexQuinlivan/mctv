#!/usr/bin/env python3
"""Download one Minecraft version from Mojang's servers into a game directory
laid out the way Amethyst's launcher.jar expects. Files already there with the
right SHA-1 are skipped.

    python3 -I scripts/fetch-minecraft.py 1.21.11 build/mcgame
    python3 -I scripts/fetch-minecraft.py 26.3 build/mc26 --lwjgl build/java-26/lwjgl

--lwjgl DIR also puts the version's own LWJGL Java jars (no natives) in DIR,
for versions newer than the LWJGL the app bundles.
"""
import concurrent.futures
import hashlib
import json
import os
import sys
import urllib.request

MANIFEST = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"
RESOURCES = "https://resources.download.minecraft.net"
UA = {"User-Agent": "mctv-fetch/1.0"}

# LWJGL comes from Amethyst's build, and native jars can't load on tvOS.
# The netty-transport-classes-* and netty-transport-native-unix-common jars are
# plain Java and must stay. Without them even single-player hangs at "Loading terrain".
SKIP_PREFIXES = ("org.lwjgl",)
SKIP_PARTS = (":natives-", "netty-transport-native-epoll:", "netty-transport-native-kqueue:")


def get(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60) as r:
        return r.read()


def sha1(path):
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch(url, path, want_sha1=None):
    """Returns 1 if downloaded, 0 if already present."""
    if os.path.exists(path) and (want_sha1 is None or sha1(path) == want_sha1):
        return 0
    os.makedirs(os.path.dirname(path), exist_ok=True)
    data = get(url)
    if want_sha1 and hashlib.sha1(data).hexdigest() != want_sha1:
        raise RuntimeError("SHA-1 mismatch for " + url)
    tmp = path + ".part"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, path)
    return 1


def allowed(lib):
    """Mojang's library rules, evaluated for macOS, which is what the app's JVM reports."""
    ok = True
    for rule in lib.get("rules", []):
        os_name = rule.get("os", {}).get("name")
        if os_name is None or os_name == "osx":
            ok = rule["action"] == "allow"
        elif rule["action"] == "allow":
            ok = False if os_name != "osx" else ok
    return ok


def main():
    version, out = sys.argv[1], sys.argv[2]
    lwjgl_dir = sys.argv[sys.argv.index("--lwjgl") + 1] if "--lwjgl" in sys.argv else None
    manifest = json.loads(get(MANIFEST))
    entry = next((v for v in manifest["versions"] if v["id"] == version), None)
    if not entry:
        sys.exit("unknown version %s" % version)
    vdir = os.path.join(out, "versions", version)
    fetch(entry["url"], os.path.join(vdir, version + ".json"), entry.get("sha1"))
    info = json.load(open(os.path.join(vdir, version + ".json")))

    jobs = []
    client = info["downloads"]["client"]
    jobs.append((client["url"], os.path.join(vdir, version + ".jar"), client["sha1"]))

    skipped = []
    lwjgl = 0
    for lib in info["libraries"]:
        name = lib["name"]
        art = lib.get("downloads", {}).get("artifact")
        if lwjgl_dir and art and name.startswith("org.lwjgl") and ":natives-" not in name:
            jobs.append((art["url"], os.path.join(lwjgl_dir, os.path.basename(art["path"])), art["sha1"]))
            lwjgl += 1
        if not art or not allowed(lib) or name.startswith(SKIP_PREFIXES) or any(p in name for p in SKIP_PARTS):
            skipped.append(name)
            continue
        jobs.append((art["url"], os.path.join(out, "libraries", art["path"]), art["sha1"]))

    idx = info["assetIndex"]
    idx_path = os.path.join(out, "assets", "indexes", idx["id"] + ".json")
    fetch(idx["url"], idx_path, idx["sha1"])
    objects = json.load(open(idx_path))["objects"]
    for obj in objects.values():
        h = obj["hash"]
        jobs.append(("%s/%s/%s" % (RESOURCES, h[:2], h), os.path.join(out, "assets", "objects", h[:2], h), h))

    logging = info.get("logging", {}).get("client", {}).get("file")
    if logging:
        jobs.append((logging["url"], os.path.join(out, logging["id"]), logging["sha1"]))

    print("[fetch] %s: client + %d libraries + %d assets (%d libraries skipped)%s"
          % (version, len(info["libraries"]) - len(skipped), len(objects), len(skipped),
             ", %d LWJGL jars to %s" % (lwjgl, lwjgl_dir) if lwjgl_dir else ""), flush=True)
    done = new = 0
    with concurrent.futures.ThreadPoolExecutor(16) as pool:
        futures = [pool.submit(fetch, *j) for j in jobs]
        for f in concurrent.futures.as_completed(futures):
            new += f.result()
            done += 1
            if done % 500 == 0:
                print("[fetch]   %d/%d files" % (done, len(jobs)), flush=True)
    print("[fetch] done: %d files, %d downloaded, java %s, assets index %s"
          % (len(jobs), new, info["javaVersion"]["majorVersion"], idx["id"]), flush=True)


if __name__ == "__main__":
    main()
