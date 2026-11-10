#!/usr/bin/env python3
"""Add the Fabric loader and the mods below to a game directory made by
fetch-minecraft.py. The last line printed is FABRIC_ID=<fabric id>.

    python3 -I scripts/fetch-fabric.py <minecraft version> <game dir>
    python3 -I scripts/fetch-fabric.py --update <minecraft version> <game dir>
    python3 -I scripts/fetch-fabric.py --add <modrinth slug>... <minecraft version>
    python3 -I scripts/fetch-fabric.py --remove <modrinth slug>... <minecraft version>

It installs exactly what scripts/fabric-lock.json lists for the version: the
loader's profile, its libraries' SHA-1s and each mod's file and SHA-512.
--update locks the newest stable loader and each mod's newest Modrinth release
for the version, with their required dependencies: the mods below and any
added with --add. --add locks a mod's newest release and the dependencies it
needs that aren't locked yet, and changes nothing else. --remove takes a mod
out with the dependencies nothing else needs.

    sodium           far fewer draw calls, which cost most since every GL call is translated twice
    immediatelyfast  batches immediate-mode drawing (GUI, text, entities)
    ferrite-core     less memory, since tvOS jetsams the app at about 2 GB
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


def modrinth_version(project, mc):
    """A project's newest release for mc on Fabric (or its newest build), or None."""
    query = urllib.parse.urlencode({"loaders": '["fabric"]', "game_versions": '["%s"]' % mc})
    versions = get_json(MODRINTH % (project, query))
    return next((v for v in versions if v["version_type"] == "release"), versions[0]) if versions else None


def dependency_version(project, pinned, mc):
    """The version of a required dependency to lock, and a note when it isn't
    simply its newest release for mc. None when Fabric doesn't need it: a
    multi-loader jar can list another loader's library as required."""
    v = modrinth_version(project, mc)
    if v:
        return v, None
    info = get_json("https://api.modrinth.com/v2/project/%s" % project)
    if "fabric" not in info.get("loaders", []):
        return None, "%s is only for %s, so Fabric doesn't need it" % (info["title"], " and ".join(info.get("loaders", [])))
    if pinned:
        return get_json("https://api.modrinth.com/v2/version/%s" % pinned), "%s isn't marked for %s, so the version it was pinned to" % (info["title"], mc)
    versions = get_json(MODRINTH % (project, urllib.parse.urlencode({"loaders": '["fabric"]'})))
    if not versions:
        sys.exit("[fabric] %s has no Fabric build at all" % info["title"])
    v = next((v for v in versions if v["version_type"] == "release"), versions[0])
    return v, "%s isn't marked for %s, so its newest Fabric release, %s" % (info["title"], mc, v["version_number"])


def dependencies(v):
    """A version's required dependencies, as (project, the version it pins or None)."""
    return [(d["project_id"], d.get("version_id")) for d in v.get("dependencies", [])
            if d.get("dependency_type") == "required" and d.get("project_id")]


def lock_entry(v, needed_by):
    f = next((f for f in v["files"] if f.get("primary")), v["files"][0])
    return {"file": f["filename"], "version": v["version_number"], "for": needed_by, "url": f["url"],
            "sha512": f["hashes"]["sha512"], "project": v["project_id"], "needs": required(v)}


def required(v):
    return sorted({d["project_id"] for d in v.get("dependencies", []) if d.get("dependency_type") == "required" and d.get("project_id")})


def project_id(slug):
    return get_json("https://api.modrinth.com/v2/project/%s" % urllib.parse.quote(slug))["id"]


def fill_in(mods):
    """Entries locked before entries said their project and dependencies get them, from Modrinth by file hash."""
    for m in mods:
        if "project" not in m or "needs" not in m:
            v = get_json("https://api.modrinth.com/v2/version_file/%s?algorithm=sha512" % m["sha512"])
            m["project"], m["needs"] = v["project_id"], required(v)


def add(entry, mc, slugs):
    """Locks the mods and the dependencies they need that aren't locked, or nothing if any can't be."""
    mods = entry["mods"]
    fill_in(mods)
    locked = {m["project"] for m in mods}
    queue = [(slug, None, None) for slug in slugs]
    added, notes = [], []
    while queue:
        project, needed_by, pinned = queue.pop(0)
        if needed_by:
            v, note = dependency_version(project, pinned, mc)
            if note:
                notes.append("%s needs it: %s" % (needed_by, note))
            if not v:
                continue
        else:
            v = modrinth_version(project, mc)
            if not v:
                sys.exit("[fabric] %s has no Fabric build for %s. Nothing was locked" % (project, mc))
        if v["project_id"] in locked:
            if not needed_by:
                notes.append("%s is already locked" % project)
            continue
        locked.add(v["project_id"])
        added.append(lock_entry(v, needed_by))
        name = added[-1]["file"].rsplit(".jar", 1)[0]
        queue += [(d, name if needed_by else project, pin) for d, pin in dependencies(v) if d not in locked]
    mods += added
    for m in added:
        print("[fabric] locked %s%s" % (m["file"], " (for %s)" % m["for"] if m["for"] else ""))
    for n in notes:
        print("[fabric] " + n)


def remove(entry, slugs):
    mods = entry["mods"]
    fill_in(mods)
    gone = {project_id(slug) for slug in slugs}
    for m in mods:
        if m["project"] in gone and m["for"]:
            sys.exit("[fabric] %s came in for %s, so remove that instead" % (m["file"], m["for"]))
    keep = {m["project"] for m in mods if m["for"] is None and m["project"] not in gone}
    by_project = {m["project"]: m for m in mods}
    todo = list(keep)
    while todo:  # what the mods left still need
        for d in by_project.get(todo.pop(), {}).get("needs", []):
            if d not in keep:
                keep.add(d)
                todo.append(d)
    for m in mods:
        if m["project"] not in keep:
            print("[fabric] removed %s" % m["file"])
    entry["mods"] = [m for m in mods if m["project"] in keep]


def resolve(mc, extra=()):
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
    mods, done = [], set()
    queue = [(slug, None) for slug in list(MODS) + list(extra)]
    while queue:
        project, needed_by = queue.pop(0)
        if project in done:
            continue
        done.add(project)
        if needed_by:
            v, note = dependency_version(project, None, mc)
            if note:
                print("[fabric] %s needs it: %s" % (needed_by, note))
        else:
            v = modrinth_version(project, mc)
            if not v:
                print("[fabric] %s: no build for %s, skipped" % (project, mc))
        if not v or v["project_id"] in done and project != v["project_id"]:
            continue
        done.add(v["project_id"])
        queue += [(d, project) for d, _ in dependencies(v)]
        mods.append(lock_entry(v, needed_by))
    return {"loader": loader, "profile": profile, "mods": mods}


def save(lock):
    with open(LOCK, "w") as f:
        json.dump(dict(sorted(lock.items())), f, indent=1)
        f.write("\n")


def main():
    argv = sys.argv[1:]
    lock = json.load(open(LOCK)) if os.path.exists(LOCK) else {}
    if argv and argv[0] in ("--add", "--remove"):
        if len(argv) < 3:
            sys.exit(__doc__)
        mc = argv[-1]
        entry = lock.get(mc) or sys.exit("no %s in scripts/fabric-lock.json. Run with --update first" % mc)
        if argv[0] == "--add":
            add(entry, mc, argv[1:-1])
        else:
            remove(entry, argv[1:-1])
        save(lock)
        return
    args = [a for a in argv if a != "--update"]
    if len(args) != 2:
        sys.exit(__doc__)
    mc, game = args
    client = os.path.join(game, "versions", mc, mc + ".jar")
    if not os.path.exists(client):
        sys.exit("no %s. Run fetch-minecraft.py first" % client)
    if "--update" in sys.argv:
        added = [m.get("project") for m in lock.get(mc, {}).get("mods", []) if m.get("for") is None and m.get("project")]
        lock[mc] = resolve(mc, added)
        save(lock)
        print("[fabric] locked loader %s and %d mods for %s in scripts/fabric-lock.json" % (lock[mc]["loader"], len(lock[mc]["mods"]), mc))
    entry = lock.get(mc) or sys.exit("no %s in scripts/fabric-lock.json. Run with --update to lock the newest loader and mods" % mc)

    profile = entry["profile"]
    fid = profile["id"]
    vdir = os.path.join(game, "versions", fid)
    os.makedirs(vdir, exist_ok=True)
    with open(os.path.join(vdir, fid + ".json"), "w") as f:
        json.dump(profile, f, indent=2)
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
