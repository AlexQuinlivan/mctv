#!/usr/bin/env python3
"""Add the Fabric loader and the mods below to a game directory made by
fetch-minecraft.py. The last line printed is FABRIC_ID=<fabric id>.

    python3 -I scripts/fetch-fabric.py <minecraft version> <game dir>
    python3 -I scripts/fetch-fabric.py --update <minecraft version> <game dir>

It installs exactly what scripts/fabric-lock.json lists for the version: the
loader's profile, its libraries' SHA-1s and each mod's file and SHA-512.
--update locks the newest stable loader and each mod's newest Modrinth release
for the version, with their required dependencies.

    sodium           far fewer draw calls, which cost most since every GL call is translated twice
    immediatelyfast  batches immediate-mode drawing (GUI, text, entities)
    ferrite-core     less memory, since tvOS kills the app at about 2 GB
    lithium          lighter ticks for the built-in server
    controlify       controller support, reading the TV's controller as a GLFW gamepad
    no-chat-reports  no chat reporting, and no chat signing warnings
"""
import hashlib
import json
import os
import shutil
import sys
import urllib.parse
import urllib.request

UA = {"User-Agent": "mctv-fetch/1.0 (MCTV, a tvOS launcher)"}
META = "https://meta.fabricmc.net/v2/versions/loader/"
MODRINTH = "https://api.modrinth.com/v2/project/%s/version?%s"
MODS = ("sodium", "immediatelyfast", "ferrite-core", "lithium", "controlify", "no-chat-reports")
MANAGED = ".mctv-managed"  # mods this script put in mods/, so it can remove old versions
LOCK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fabric-lock.json")


def get(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60) as r:
        return r.read()


def get_json(url):
    return json.loads(get(url))


def digest(path, algo):
    h = hashlib.new(algo)
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch(url, path, algo, expect):
    """Download url to path unless it's already there with the expected hash."""
    if not expect:
        sys.exit("no %s hash for %s" % (algo, url))
    if os.path.exists(path) and digest(path, algo) == expect:
        return False
    data = get(url)
    if hashlib.new(algo, data).hexdigest() != expect:
        sys.exit("hash mismatch for %s" % url)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".part"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, path)
    return True


def maven_path(name):
    group, artifact, version = name.split(":")[:3]
    return "%s/%s/%s/%s-%s.jar" % (group.replace(".", "/"), artifact, version, artifact, version)


def resolve(mc):
    """The newest stable loader and mods for mc, as a lock entry."""
    loaders = get_json(META + mc)
    loader = next((l["loader"]["version"] for l in loaders if l["loader"].get("stable")), None)
    if not loader:
        sys.exit("no stable Fabric loader for Minecraft %s" % mc)
    profile = get_json("%s%s/%s/profile/json" % (META, mc, loader))
    for lib in profile["libraries"]:
        if not lib.get("sha1"):
            # The profile gives a SHA-1 for each library but not for the loader jar,
            # so that one comes from the checksum file Maven publishes next to it.
            url = lib.get("url", "https://maven.fabricmc.net/").rstrip("/") + "/" + maven_path(lib["name"])
            lib["sha1"] = get(url + ".sha1").decode().split()[0]
    query = urllib.parse.urlencode({"loaders": '["fabric"]', "game_versions": '["%s"]' % mc})
    mods, done = [], set()
    queue = [(slug, None) for slug in MODS]
    while queue:
        project, needed_by = queue.pop(0)
        if project in done:
            continue
        done.add(project)
        versions = get_json(MODRINTH % (project, query))
        if not versions:
            if needed_by:
                sys.exit("[fabric] %s needs %s, which has no build for %s" % (needed_by, project, mc))
            print("[fabric] %s: no build for %s, skipped" % (project, mc))
            continue
        v = next((v for v in versions if v["version_type"] == "release"), versions[0])
        done.add(v["project_id"])
        for d in v.get("dependencies", []):
            if d.get("dependency_type") == "required" and d.get("project_id"):
                queue.append((d["project_id"], project))
        f = next((f for f in v["files"] if f.get("primary")), v["files"][0])
        mods.append({"file": f["filename"], "version": v["version_number"], "for": needed_by,
                     "url": f["url"], "sha512": f["hashes"]["sha512"]})
    return {"loader": loader, "profile": profile, "mods": mods}


def main():
    args = [a for a in sys.argv[1:] if a != "--update"]
    mc, game = args
    client = os.path.join(game, "versions", mc, mc + ".jar")
    if not os.path.exists(client):
        sys.exit("no %s. Run fetch-minecraft.py first" % client)
    lock = json.load(open(LOCK)) if os.path.exists(LOCK) else {}
    if "--update" in sys.argv:
        lock[mc] = resolve(mc)
        with open(LOCK, "w") as f:
            json.dump(dict(sorted(lock.items())), f, indent=1)
            f.write("\n")
        print("[fabric] locked loader %s and %d mods for %s in scripts/fabric-lock.json" % (lock[mc]["loader"], len(lock[mc]["mods"]), mc))
    entry = lock.get(mc) or sys.exit("no %s in scripts/fabric-lock.json. Run with --update to lock the newest loader and mods" % mc)

    profile = entry["profile"]
    fid = profile["id"]
    vdir = os.path.join(game, "versions", fid)
    os.makedirs(vdir, exist_ok=True)
    with open(os.path.join(vdir, fid + ".json"), "w") as f:
        json.dump(profile, f, indent=2)
    # Amethyst's launcher puts the launch version's own jar on the classpath.
    jar = os.path.join(vdir, fid + ".jar")
    if not os.path.exists(jar) or digest(jar, "sha1") != digest(client, "sha1"):
        shutil.copyfile(client, jar)
    got = 0
    for lib in profile["libraries"]:
        rel = maven_path(lib["name"])
        url = lib.get("url", "https://maven.fabricmc.net/").rstrip("/") + "/" + rel
        got += fetch(url, os.path.join(game, "libraries", rel), "sha1", lib.get("sha1"))
    print("[fabric] loader %s for %s: %d libraries (%d downloaded)" % (entry["loader"], mc, len(profile["libraries"]), got))

    mods = os.path.join(game, "mods")
    os.makedirs(mods, exist_ok=True)
    wanted = []
    for m in entry["mods"]:
        new = fetch(m["url"], os.path.join(mods, m["file"]), "sha512", m["sha512"])
        wanted.append(m["file"])
        print("[fabric] %s %s%s%s" % (m["file"].rsplit(".jar", 1)[0], m["version"],
                                      " (for %s)" % m["for"] if m["for"] else "", " (downloaded)" if new else ""))

    managed = os.path.join(mods, MANAGED)
    old = open(managed).read().split() if os.path.exists(managed) else []
    for name in old:
        if name.startswith("mctv-"):
            continue  # our own mod, from scripts/build-mod.sh
        if name not in wanted and os.path.exists(os.path.join(mods, name)):
            os.remove(os.path.join(mods, name))
            print("[fabric] removed %s" % name)
    with open(managed, "w") as f:
        f.write("\n".join(wanted) + "\n")
    print("FABRIC_ID=%s" % fid)


if __name__ == "__main__":
    main()
