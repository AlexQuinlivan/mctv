#!/usr/bin/env python3
"""Builds MCTV. Minecraft 26.3, with Fabric and the mods in
scripts/fabric-lock.json or vanilla, compiled by GraalVM Native Image for
tvOS 27 or this Mac, and the app around it (aot/README.md).

    python3 -I aot/aot.py add <modrinth slug>... [--no-chaos] [--quick] [--seed N] [--minutes M]
    python3 -I aot/aot.py remove <modrinth slug>...
    python3 -I aot/aot.py bake [--vanilla]
    python3 -I aot/aot.py audit [--vanilla]
    python3 -I aot/aot.py run [--vanilla] [--native [--quick]] [--trace] [--seconds N]
    python3 -I aot/aot.py image mac|tvos [--vanilla] [--quick]
    python3 -I aot/aot.py sim [--vanilla] [--quick] [--world | --multiplayer] [--sound] [--wait N] [-- app arguments]
    python3 -I aot/aot.py device [--vanilla] [--quick] [--world | --multiplayer] [--sound] [--wait N] [-- app arguments]
    python3 -I aot/aot.py chaos [--vanilla] [--quick] [--seed N] [--minutes M] [--jvmarg=OPTION]... [--device | --mac [--native] [--trace]]
    python3 -I aot/aot.py pgo [--vanilla] [--seed N] [--minutes M]
    python3 -I aot/aot.py gaps <log>

add     locks mods from Modrinth with the dependencies they need, audits, and
        plays a chaos run in the simulator, saying what in it came from them.
        The bake and the simulator run the mods on this Mac, so add only mods
        you trust. With --no-chaos it stops after the audit.
remove  unlocks mods and the dependencies nothing else needs.
bake    runs Fabric on GraalVM's JVM and keeps every class as it is after
        Fabric's mixins and the app's agent (aot/java/bake). --vanilla bakes
        the game without Fabric.
audit   checks that every site the bake's analysis couldn't settle is in
        aot/reviewed.json, with why it's fine in the image. image runs it
        first and stops if any isn't.
run     plays the baked game on this Mac, on the JVM, or the image with
        --native, straight into a test world. --trace adds what it reflects
        on, calls through JNI and reads as resources to aot/config/traced,
        and records classes mods define while playing.
image   builds the native image. --quick builds faster and runs slower.
sim     builds the app around the image and runs it in the tvOS simulator,
        in the test world with --world, or joined to a local test server
        with --multiplayer. Muted unless --sound.
device  the same on the Apple TV.
chaos   a seeded chaos run against a local test server (aot/chaos.py), in
        the simulator, on the Apple TV with --device, or on this Mac with
        --mac, world side only. Same seed, same run.
pgo     profiles the game for profile-guided optimisation, with an image
        that counts what runs, played through a chaos run in the simulator,
        into aot/pgo/<profile>.iprof.gz. Images are built with it after,
        unless --no-pgo. Oracle GraalVM only.
gaps    turns what a run's log says the image was missing into metadata.

Images are built by Oracle GraalVM with the G1 collector unless --graal ce,
and with aot/pgo's profile when there is one unless --no-pgo.

Each stage runs the ones it needs and skips work whose inputs haven't changed
(stamp.json beside its output). Mods come from scripts/fabric-lock.json and
library quirks from aot/fixups.json, so a new mod needs no code here, and a
trace only if it defines classes while playing.
"""
import argparse
import contextlib
import threading
import fnmatch
import gzip
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "aot"))
import chaos as chaos_lib  # noqa: E402
import machoplat  # noqa: E402

GRAAL = os.path.join(ROOT, "deps/graalvm/Contents/Home")
GRAALS = {"ce": GRAAL, "oracle": os.path.join(ROOT, "deps/graalvm-oracle/Contents/Home")}
# What builds images, set by --graal and --gc: whose native-image and native libraries, and which collector.
# Oracle's, for G1, unless --graal ce (Serial only). The bake and javac stay on CE, since their output is the
# same bytecode either way. And whether the image is built with the profile `aot.py pgo` makes ("use"),
# counts what runs to make one ("instrument"), or neither.
BUILDER = {"graal": "oracle", "gc": "g1", "pgo": "off"}
PGO_DIR = os.path.join(ROOT, "aot/pgo")
BUILD = os.path.join(ROOT, "build")
OUT = os.path.join(BUILD, "aot")
VERSION = "26.3"
GAME = os.path.join(BUILD, "game")                      # scripts/fetch-minecraft.py and fetch-fabric.py
JAVA_LIBS = os.path.join(OUT, "lwjgl")                  # Mojang's LWJGL jars without FFM (lwjgl_jars)
NATIVES = os.path.join(BUILD, "natives")                # scripts/prepare-natives.sh: the app's natives
LOCK = os.path.join(ROOT, "scripts/fabric-lock.json")
FIXUPS_FILE = os.path.join(ROOT, "aot/fixups.json")
REVIEWED_FILE = os.path.join(ROOT, "aot/reviewed.json")
CONFIG = os.path.join(ROOT, "aot/config")
MINOS = "26.0"                                          # the app's deployment target (mctv/project.yml)
WORLD = "aot-test"
SIM_NAME = "MCTV Apple TV 4K (3rd gen)"
SIM_TYPE = "com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-1080p"
SIM_RUNTIME = "com.apple.CoreSimulator.SimRuntime.tvOS-27-2"
JDK_STATIC = "java nio net zip extnet jimage verify management management_ext prefs syslookup".split()
# GraalVM's libraries and the system ones they use (Java's file types, proxies, process info)
LINK_LIBS = ("-ljvm -llibchelper -ldarwin -ljava -lnio -lnet -lzip -lextnet -ljimage -lverify -lmanagement_ext "
             "-lmanagement -lprefs -framework CoreFoundation -framework CoreServices -framework CFNetwork "
             "-framework Foundation -lz -lc++").split()
EPOCH = (1980, 1, 1, 0, 0, 0)


def say(msg):
    print("[aot] " + msg, flush=True)


def die(msg):
    sys.exit("[aot] " + msg)


def run(cmd, log=None, cwd=None, env=None):
    """Runs cmd, into log if given, and stops with its tail if it fails."""
    if log is None:
        subprocess.run(cmd, check=True, cwd=cwd, env=env)
        return
    with open(log, "w") as out:
        rc = subprocess.run(cmd, stdout=out, stderr=subprocess.STDOUT, cwd=cwd, env=env).returncode
    if rc != 0:
        tail = open(log, errors="replace").read().splitlines()[-25:]
        die("%s failed (%d):\n%s\nfull log in %s" % (os.path.basename(cmd[0]), rc, "\n".join(tail), log))


def java(tool):
    return os.path.join(GRAAL, "bin", tool)


def builder_home():
    return GRAALS[BUILDER["graal"]]


def flavour():
    """The image's builder in folder names: nothing for CE with Serial, else like -oracle-g1, then -pgo for
    one built with a profile, or -instrumented for one that makes it."""
    base = "" if (BUILDER["graal"], BUILDER["gc"]) == ("ce", "serial") else "-%s-%s" % (BUILDER["graal"], BUILDER["gc"])
    return base + {"off": "", "use": "-pgo", "instrument": "-instrumented"}[BUILDER["pgo"]]


def pgo_file(profile):
    return os.path.join(PGO_DIR, profile + ".iprof.gz")


def link_libs():
    """GraalVM's libraries to link an image with, and G1's own (compressed references, native-image's default)."""
    return LINK_LIBS + (["-lg1gc-cr"] if BUILDER["gc"] == "g1" else [])


# --- stamps --------------------------------------------------------------

_hashes = {}


def file_hash(path):
    st = os.stat(path)
    key = (path, st.st_size, st.st_mtime_ns)
    if key not in _hashes:
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        _hashes[key] = h.hexdigest()
    return _hashes[key]


def inputs_key(paths, extra=None):
    """A hash of the files' names and contents, and of extra, whatever their folders."""
    h = hashlib.sha256()
    for p in paths:
        files = [p] if os.path.isfile(p) else sorted(
            os.path.join(d, f) for d, _, fs in os.walk(p) for f in fs) if os.path.isdir(p) else []
        for f in files:
            h.update(os.path.relpath(f, os.path.dirname(p)).encode() + b"\0" + file_hash(f).encode())
    h.update(json.dumps(extra, sort_keys=True).encode())
    return h.hexdigest()


def fresh(out, key):
    try:
        return json.load(open(os.path.join(out, "stamp.json")))["inputs"] == key
    except (OSError, ValueError, KeyError):
        return False


def mark(out, key):
    with open(os.path.join(out, "stamp.json"), "w") as f:
        json.dump({"inputs": key}, f)


def write_jar(path, files):
    """A jar with sorted, fixed-date entries, so the same files make the same jar."""
    tmp = path + ".part"
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as z:
        for name in sorted(files):
            z.writestr(zipfile.ZipInfo(name, EPOCH), files[name])
    os.replace(tmp, path)


def javac(sources, classpath, out_jar, manifest=None, extra=()):
    """Compiles a source tree into a deterministic jar."""
    srcs = sorted(os.path.join(d, f) for s in sources for d, _, fs in os.walk(s) for f in fs if f.endswith(".java"))
    key = inputs_key(sources + classpath, [manifest, list(extra)])
    stamp_dir = out_jar + ".d"
    if os.path.exists(out_jar) and fresh(stamp_dir, key):
        return out_jar
    with tempfile.TemporaryDirectory() as classes:
        os.makedirs(stamp_dir, exist_ok=True)
        # Against GraalVM's own JDK 25, not --release, which would hide its modules
        run([java("javac"), "-nowarn", "-encoding", "UTF-8", *extra,
             "-cp", ":".join(classpath), "-d", classes] + srcs, log=os.path.join(stamp_dir, "javac.log"))
        files = {}
        for d, _, fs in os.walk(classes):
            for f in fs:
                p = os.path.join(d, f)
                files[os.path.relpath(p, classes)] = open(p, "rb").read()
        if manifest:
            files["META-INF/MANIFEST.MF"] = ("Manifest-Version: 1.0\n%s\n" % manifest).encode()
        os.makedirs(os.path.dirname(out_jar), exist_ok=True)
        write_jar(out_jar, files)
    os.makedirs(stamp_dir, exist_ok=True)
    mark(stamp_dir, key)
    return out_jar


# --- the game and its libraries -------------------------------------------

FIXUPS = json.load(open(FIXUPS_FILE))


def link_tree(src, dst):
    for d, _, fs in os.walk(src):
        target = os.path.join(dst, os.path.relpath(d, src))
        os.makedirs(target, exist_ok=True)
        for f in fs:
            t = os.path.join(target, f)
            if not os.path.exists(t):
                try:
                    os.link(os.path.join(d, f), t)
                except OSError:
                    shutil.copy2(os.path.join(d, f), t)


def game(fabric):
    """build/game, the game as the launcher lays it out, checked and completed
    by scripts/fetch-minecraft.py, and for Fabric the loader and mods the lock
    names (scripts/fetch-fabric.py). Returns the folder and, for Fabric, its
    version id."""
    g = GAME
    stamp = os.path.join(OUT, "game-stamp")
    os.makedirs(stamp, exist_ok=True)
    key = inputs_key([os.path.join(ROOT, "scripts/fetch-minecraft.py")], VERSION)
    if not fresh(stamp, key) or not os.path.exists(os.path.join(g, "versions", VERSION, VERSION + ".json")):
        say("checking the game files")
        run([sys.executable, "-I", os.path.join(ROOT, "scripts/fetch-minecraft.py"), VERSION, g], log=os.path.join(stamp, "fetch.log"))
        mark(stamp, key)
    fid = None
    if fabric:
        stamp = os.path.join(OUT, "fabric-stamp")
        os.makedirs(stamp, exist_ok=True)
        key = inputs_key([LOCK, os.path.join(ROOT, "scripts/fetch-fabric.py")], VERSION)
        log = os.path.join(stamp, "fabric.log")
        if not fresh(stamp, key) or not os.path.exists(log):
            run([sys.executable, "-I", os.path.join(ROOT, "scripts/fetch-fabric.py"), VERSION, g], log=log)
            mark(stamp, key)
        fid = re.search(r"^FABRIC_ID=(.+)$", open(log).read(), re.M).group(1)
    lwjgl_jars(g)
    return g, fid


def lwjgl_jars(g):
    """Mojang's LWJGL jars in build/aot/lwjgl, the core jar without its Java 25
    classes. Those make native callbacks through the foreign function API.
    Without them LWJGL uses JNI and libffi, which the image is built around
    (java/mctv-agent's FfiUpcalls does the same for mods)."""
    jars = []
    for lib in meta(g)["libraries"]:
        parts = lib["name"].split(":")
        if parts[0] == "org.lwjgl" and len(parts) == 3:
            jars.append(os.path.join(g, "libraries", lib["downloads"]["artifact"]["path"]))
    key = inputs_key(jars, "no FFM")
    if fresh(JAVA_LIBS, key):
        return
    shutil.rmtree(JAVA_LIBS, ignore_errors=True)
    os.makedirs(JAVA_LIBS)
    for jar in jars:
        dest = os.path.join(JAVA_LIBS, os.path.basename(jar))
        if not re.match(r"lwjgl-\d", os.path.basename(jar)):
            shutil.copy2(jar, dest)
            continue
        with zipfile.ZipFile(jar) as src, zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as out:
            for info in src.infolist():
                if not re.match(r"META-INF/versions/(2[5-9]|[3-9]\d)/", info.filename):
                    out.writestr(info, src.read(info))
    mark(JAVA_LIBS, key)


def meta(g, version=VERSION):
    return json.load(open(os.path.join(g, "versions", version, version + ".json")))


def maven_path(name):
    group, artifact, version = name.split(":")[:3]
    return "%s/%s/%s/%s-%s.jar" % (group.replace(".", "/"), artifact, version, artifact, version)


def allowed(lib):
    ok = not lib.get("rules")
    for rule in lib.get("rules", []):
        if rule.get("os", {}).get("name") in (None, "osx"):
            ok = rule["action"] == "allow"
    return ok


def fixed(path):
    """The jar, or a copy without what aot/fixups.json drops from it."""
    rules = [r for pat, r in FIXUPS["jars"].items() if fnmatch.fnmatch(os.path.basename(path), pat)]
    if not rules:
        return path
    out = os.path.join(OUT, "fixed", os.path.basename(path))
    key = inputs_key([path, FIXUPS_FILE])
    if os.path.exists(out) and fresh(out + ".d", key):
        return out
    drops = [d for r in rules for d in r.get("drop", [])]
    files = {}
    with zipfile.ZipFile(path) as z:
        for n in z.namelist():
            if not n.endswith("/") and not any(fnmatch.fnmatch(n, d) for d in drops):
                files[n] = z.read(n)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    write_jar(out, files)
    os.makedirs(out + ".d", exist_ok=True)
    mark(out + ".d", key)
    return out


def download(art, base):
    path = os.path.join(base, art["path"])
    if os.path.exists(path) and hashlib.sha1(open(path, "rb").read()).hexdigest() == art["sha1"]:
        return path
    data = urllib.request.urlopen(art["url"], timeout=120).read()
    if hashlib.sha1(data).hexdigest() != art["sha1"]:
        die("hash mismatch for " + art["url"])
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)
    return path


def libraries(g, mac_natives=False):
    """The game's libraries for macOS, with the app's LWJGL jars (JNI, no FFM).
    With mac_natives, also LWJGL's macOS arm64 natives, for running on this
    Mac. The app brings its own natives."""
    cp, natives = [], []
    for lib in meta(g)["libraries"]:
        if not allowed(lib):
            continue
        parts = lib["name"].split(":")
        group, artifact, version = parts[:3]
        if len(parts) > 3:
            if mac_natives and group == "org.lwjgl" and parts[3] == "natives-macos-arm64":
                natives.append(download(lib["downloads"]["artifact"], os.path.join(OUT, "downloads")))
            continue
        if group == "org.lwjgl":
            cp.append(os.path.join(JAVA_LIBS, "%s-%s.jar" % (artifact, version)))
        elif artifact != "java-objc-bridge":  # AppKit, which tvOS doesn't have
            cp.append(fixed(os.path.join(g, "libraries", lib["downloads"]["artifact"]["path"])))
    return cp, natives


def fabric_libraries(g):
    """Fabric Loader, Mixin and ASM, as the lock's loader profile lists them."""
    return [fixed(os.path.join(g, "libraries", maven_path(l["name"]))) for l in json.load(open(LOCK))[VERSION]["profile"]["libraries"]]


def mod_jars(g):
    return [os.path.join(g, "mods", m["file"]) for m in json.load(open(LOCK))[VERSION]["mods"]]


def loader_jar(g):
    return next(p for p in fabric_libraries(g) if os.path.basename(p).startswith("fabric-loader-"))


def mc_args(g, game_dir, version, username, world=None):
    a = ["--username", username, "--version", version, "--gameDir", game_dir,
         "--assetsDir", os.path.join(g, "assets"), "--assetIndex", meta(g)["assetIndex"]["id"], "--accessToken", "0"]
    return a + (["--quickPlaySingleplayer", world] if world else [])


# --- bake ---------------------------------------------------------------

def agent_jar():
    """The app's own agent (java/mctv-agent), built from this checkout."""
    lwjgl_jars(game(False)[0])
    return javac([os.path.join(ROOT, "java/mctv-agent/src")], [os.path.join(JAVA_LIBS, "lwjgl-3.4.3.jar")],
                 os.path.join(OUT, "tools/mctv-agent.jar"), manifest="Premain-Class: mctv.agent.Agent")


def bake_jar(g):
    return javac([os.path.join(ROOT, "aot/java/bake")], fabric_libraries(g) + libraries(g)[0], os.path.join(OUT, "tools/bake.jar"),
                 manifest="Premain-Class: mctv.aot.bake.Capture")


def bake(profile):
    """Runs the game's class loading on GraalVM's JVM once, with Fabric's
    transformers and the app's agent, and keeps the resulting classes
    (aot/java/bake). Returns bake.json."""
    fabric = profile == "fabric"
    g, fid = game(fabric)
    libs, _ = libraries(g)
    client = os.path.join(g, "versions", VERSION, VERSION + ".jar")
    cp = (fabric_libraries(g) if fabric else []) + libs + [client]
    mods = mod_jars(g) if fabric else []
    agent, tool = agent_jar(), bake_jar(g)
    out = os.path.join(OUT, profile, "bake")
    key = inputs_key(cp + mods + [agent, tool, FIXUPS_FILE], profile)
    if fresh(out, key):
        return json.load(open(os.path.join(out, "bake.json")))
    say("baking %s%s" % ("Minecraft %s" % VERSION, " with %d mods" % len(mods) if fabric else ""))
    shutil.rmtree(out, ignore_errors=True)
    run_dir = os.path.join(out, "game")  # a fresh game folder, so mods' configs start from their defaults
    os.makedirs(os.path.join(run_dir, "mods"))
    for m in mods:
        os.link(m, os.path.join(run_dir, "mods", os.path.basename(m)))
    args = mc_args(g, run_dir, fid or VERSION, "Bake")
    asm = [p for p in fabric_libraries(g) if "/org/ow2/asm/" in p]  # the bake's analysis, not the game's
    run([java("java"), "-Xmx6g", "-javaagent:" + agent, "-javaagent:" + tool, "-Dmctv.bake.game=" + client,
         "-Dmctv.bake.fixups=" + FIXUPS_FILE,
         "-Dmctv.bake.sources=" + ":".join(cp), "-cp", ":".join([tool] + cp + ([] if fabric else asm)),
         "mctv.aot.bake.Bake", profile, out] + args, log=os.path.join(out, "bake.log"), cwd=run_dir)
    result = json.load(open(os.path.join(out, "bake.json")))
    c = result["counts"]
    say("baked %d classes (%d jars changed, %d generated, %d mixins merged), %d couldn't load, see bake.json"
        % (c["captured"], c["changedJars"], c["generated"], c["mixins"], c["failed"]))
    mark(out, key)
    return result


# What the bake's analysis couldn't settle (audit.json), by what it would take to fix: code that makes or
# reads classes while running and native code need a person every time, reflection can be met with metadata.
DEFINES = {"defineClass", "defineHiddenClass", "newProxyInstance", "createArrayBacked", "getClassNode",
           "getClassByteArray", "unanalysable method"}
NATIVE = {"System.load", "System.loadLibrary", "Runtime.load", "Runtime.loadLibrary", "SymbolLookup.libraryLookup",
          "Linker.downcallHandle", "Linker.upcallStub"}


def site_kind(site):
    return "native" if site["api"] in NATIVE else "defines" if site["api"].split(".")[-1] in DEFINES else "reflects"


def preserved_mod_jars(baked):
    """The jars of the mods the image keeps whole (fixups.json, preserve)."""
    return {os.path.basename(cs) for m in baked["mods"] if m["id"] not in FIXUPS["preserve"]["modsExcept"]
            for cs in m["codeSource"]}


def bundled_natives(jar):
    """What native libraries a jar carries, by platform: "macOS, Linux and Windows, none for tvOS"."""
    found = set()
    with zipfile.ZipFile(jar) as z:
        for n in z.namelist():
            low = n.lower()
            if low.endswith(".so") or ".so." in low:
                found.add("Linux")
            elif low.endswith(".dll"):
                found.add("Windows")
            elif low.endswith(".dylib") or low.endswith(".jnilib"):
                found |= machoplat.platforms(z.read(n)) or {"an Apple platform it can't tell"}
    if not found:
        return "no native libraries"
    names = sorted(found)
    listed = names[0] if len(names) == 1 else ", ".join(names[:-1]) + " and " + names[-1]
    return "native libraries for " + listed + ("" if "tvOS" in found else ", none for tvOS")


def audit(profile):
    """The gate before an image. Every site in the bake's audit.json has to be
    in aot/reviewed.json with why it's fine in the image, under "defines" for
    code that makes or reads classes while running, "native" for native code
    and "reflects" for reflection. A mod's reflection needn't be: mods are
    preserved, so it works on their own classes, and a chaos run fails on any
    lookup the image is missing. Runs once per invocation."""
    if profile in AUDITED:
        return
    baked = bake(profile)
    sites = json.load(open(os.path.join(OUT, profile, "bake", "audit.json")))["sites"]
    groups = json.load(open(REVIEWED_FILE))["groups"]
    reviewed = {"defines": set(), "native": set(), "reflects": set()}
    for g in groups:
        if not g.get("why", "").strip():
            die("aot/reviewed.json has a group without a why: %s" % [s for k in reviewed for s in g.get(k, [])][:3])
        for kind in reviewed:
            reviewed[kind].update(g.get(kind, []))
    mod_jars = preserved_mod_jars(baked)
    found = {kind: {} for kind in reviewed}
    in_mods = set()
    for site in sites:
        kind = site_kind(site)
        if kind == "reflects" and site["jar"] in mod_jars and site["site"] not in reviewed[kind]:
            in_mods.add(site["site"])
            continue
        found[kind].setdefault(site["site"], []).append(site)
    missing = {kind: {s: v for s, v in found[kind].items() if s not in reviewed[kind]} for kind in found}
    if profile == "fabric":  # the vanilla bake has a subset
        stale = sorted(s for kind in found for s in reviewed[kind] if s not in found[kind])
        if stale:
            say("aot/reviewed.json lists %d sites the bake no longer has, which can go: %s" % (len(stale), ", ".join(stale)))
    count = sum(len(v) for v in missing.values())
    if count:
        lines = []
        paths = {os.path.basename(p): p for p in baked["classpath"]}
        paths.update({os.path.basename(cs): cs for m in baked["mods"] for cs in m["codeSource"]})
        for jar in sorted({s[0]["jar"] for ss in missing.values() for s in ss.values()}):
            if any(s[0]["jar"] == jar for s in missing["native"].values()) and jar in paths:
                lines.append("  %s carries %s" % (jar, bundled_natives(paths[jar])))
            for kind, ss in missing.items():
                for name, uses in sorted(ss.items()):
                    if uses[0]["jar"] != jar:
                        continue
                    lines.append("    %s  %s" % (kind, name))
                    for detail in sorted({"%s, %s" % (u["api"], u["detail"]) for u in uses}):
                        lines.append("        " + detail)
        skeleton = json.dumps({"why": "", **{k: sorted(v) for k, v in missing.items() if v}}, indent=2)
        die("%d site%s the analysis can't show %s fine in the image:\n%s\n\n"
            "Code that makes classes while running needs compat code (aot/java/compat/<mod id>), and native code a\n"
            "library built for tvOS in the app's Frameworks. Once each is handled, or fine as it is, add it to\n"
            "aot/reviewed.json:\n%s"
            % (count, "" if count == 1 else "s", "is" if count == 1 else "are", "\n".join(lines), skeleton))
    say("all %d sites reviewed (aot/reviewed.json)%s" % (sum(len(v) for v in found.values()),
        ", and %d reflection sites in mods left to the chaos run" % len(in_mods) if in_mods else ""))
    AUDITED.add(profile)


AUDITED = set()


def runtime_jar(profile, baked):
    """The image's own classes: its main class, for Fabric FlatFabric, and the
    compat code in aot/java/compat/<mod id> for each mod the bake has."""
    sources = [os.path.join(ROOT, "aot/java/runtime-common")]
    extra = ("--add-modules", "org.graalvm.nativeimage")  # substitutions (Target_*), from GraalVM's own JDK
    if profile == "fabric":
        sources.append(os.path.join(ROOT, "aot/java/runtime-fabric"))
        mods = {m["id"] for m in baked["mods"]}
        compat = os.path.join(ROOT, "aot/java/compat")
        dirs = [os.path.join(compat, d) for d in sorted(os.listdir(compat)) if d in mods]
        sources += dirs + [mod_sweeps(profile, dirs)]
    return javac(sources, baked["classpath"], os.path.join(OUT, profile, "runtime.jar"), extra=extra)


def mod_sweeps(profile, compat_dirs):
    """mctv.aot.fabric.ModSweeps, written for this build: the screen sweep's steps from each
    compat folder that has a ScreenSweep (mctv.aot.Sweep), with no reflection."""
    calls = []
    for d in compat_dirs:
        for folder, _, files in os.walk(d):
            if "ScreenSweep.java" in files:
                package = os.path.relpath(folder, d).replace(os.sep, ".")
                calls.append("        steps.addAll(%s.ScreenSweep.steps());" % package)
    source = """package mctv.aot.fabric;

/** Written by aot.py (mod_sweeps) for this build's mods: each compat ScreenSweep. */
final class ModSweeps {
    static java.util.List<mctv.aot.Sweep.Step> all() {
        java.util.List<mctv.aot.Sweep.Step> steps = new java.util.ArrayList<>();
%s
        return steps;
    }
}
""" % "\n".join(calls)
    out = os.path.join(OUT, profile, "generated-src")
    path = os.path.join(out, "mctv/aot/fabric/ModSweeps.java")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if not os.path.exists(path) or open(path).read() != source:
        with open(path, "w") as f:
            f.write(source)
    return out


def runtime_classpath(profile, baked):
    """The image's class path: its own classes, the app's agent, whose patches
    (applied at bake time) call its helper classes, then the baked game."""
    return [runtime_jar(profile, baked), agent_jar()] + baked["classpath"]


def main_class(profile):
    return "mctv.aot.fabric.FlatFabric" if profile == "fabric" else "mctv.aot.Launch"


# --- this Mac -------------------------------------------------------------

def controlify_sdl(natives):
    """Controlify's own copy of SDL, as the app has (scripts/prepare-natives.sh),
    from LWJGL's macOS one. Sharing Minecraft's, Controlify empties its event
    queue every tick and the game loses its input."""
    out = os.path.join(OUT, "mac-natives", "libSDL3_controlify.dylib")
    if not os.path.exists(out):
        jar = next(n for n in natives if "lwjgl-sdl" in n)
        with zipfile.ZipFile(jar) as z:
            name = next(n for n in z.namelist() if n.endswith("libSDL3.dylib"))
            os.makedirs(os.path.dirname(out), exist_ok=True)
            with open(out, "wb") as f:
                f.write(z.read(name))
        run(["install_name_tool", "-id", "@rpath/libSDL3_controlify.dylib", out])
        run(["codesign", "-f", "-s", "-", out])
    return out


def make_world(g):
    """A fresh 26.3 world from Mojang's server jar, run headless. A world from
    an older version stops quick play at a backup prompt."""
    gen = os.path.join(OUT, "worldgen")
    world = os.path.join(gen, WORLD)
    if os.path.exists(os.path.join(world, "level.dat")):
        return world
    os.makedirs(gen, exist_ok=True)
    jar = download({"path": "server.jar", **meta(g)["downloads"]["server"]}, gen)
    with open(os.path.join(gen, "eula.txt"), "w") as f:
        f.write("eula=true\n")  # a local test server, under the EULA accepted for the game
    with open(os.path.join(gen, "server.properties"), "w") as f:
        # Servers start with their whitelist on
        f.write("level-name=%s\nlevel-seed=mctv-aot\nonline-mode=false\nwhite-list=false\nserver-ip=127.0.0.1\nserver-port=25599\n" % WORLD)
    p = subprocess.Popen([java("java"), "-Xmx2G", "-jar", jar, "--nogui"], cwd=gen, stdin=subprocess.PIPE,
                         stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT, text=True)
    time.sleep(60)
    p.communicate("stop\n", timeout=120)
    os.remove(os.path.join(world, "session.lock"))
    return world


class TestServer:
    """A running test server: its address, its log, and its console."""

    def __init__(self, process, address, log):
        self.process, self.address, self.log = process, address, log
        self._lock = threading.Lock()

    def command(self, cmd):
        with self._lock:
            if self.process.poll() is None:
                self.process.stdin.write(cmd + "\n")
                self.process.stdin.flush()

    def wait_joined(self, timeout):
        """Seconds since the epoch when a player joined, or None."""
        end = time.time() + timeout
        while time.time() < end:
            if re.search(r"joined the game", open(self.log, errors="replace").read()):
                return time.time()
            time.sleep(1)
        return None


@contextlib.contextmanager
def test_server(g, address):
    """A local 26.3 server with its own copy of the test world, for
    multiplayer tests: offline mode, no whitelist. Yields once it says it's
    ready and stops it afterwards, so its world lock is gone before the next."""
    d = os.path.join(OUT, "test-server")
    shutil.rmtree(d, ignore_errors=True)
    shutil.copytree(make_world(g), os.path.join(d, WORLD))
    os.link(os.path.join(OUT, "worldgen", "server.jar"), os.path.join(d, "server.jar"))
    with open(os.path.join(d, "eula.txt"), "w") as f:
        f.write("eula=true\n")  # a local test server, under the EULA accepted for the game
    with open(os.path.join(d, "server.properties"), "w") as f:
        f.write("level-name=%s\nonline-mode=false\nwhite-list=false\nserver-ip=%s\nserver-port=25599\n" % (WORLD, address))
    log = os.path.join(d, "server.log")
    with open(log, "w") as out:
        p = subprocess.Popen([java("java"), "-Xmx2G", "-jar", "server.jar", "--nogui"], cwd=d, stdin=subprocess.PIPE,
                             stdout=out, stderr=subprocess.STDOUT, text=True)
    try:
        for _ in range(120):
            time.sleep(1)
            if p.poll() is not None:
                die("the test server stopped, see " + log)
            if re.search(r"\]: Done \(", open(log, errors="replace").read()):
                break
        else:
            die("the test server didn't start in 2 minutes, see " + log)
        say("test server ready at %s:25599" % address)
        yield TestServer(p, "%s:25599" % address, log)
    finally:
        if p.poll() is None:
            p.communicate("stop\n", timeout=120)
        joined = re.findall(r"(\S+) joined the game", open(log, errors="replace").read())
        say("test server: %s" % ("%s joined" % ", ".join(joined) if joined else "nobody joined"))


def write_options(path, g, **extra):
    """The TV's first-run options (scripts/mc-profile.py), with Vulkan chosen
    as the app does at every launch (mctv/Sources/main.m), and any extra."""
    if not os.path.exists(path):
        run([sys.executable, "-I", os.path.join(ROOT, "scripts/mc-profile.py"),
             "--jar", os.path.join(g, "versions", VERSION, VERSION + ".jar"), path])
    want = {"preferredGraphicsBackend": '"vulkan"', "startedCleanly": "true", **extra}
    lines = [l for l in open(path).read().splitlines() if l.split(":", 1)[0] not in want]
    with open(path, "w") as f:
        f.write("\n".join(lines + ["%s:%s" % kv for kv in want.items()]) + "\n")


def sync_mods(g, game_dir, fabric):
    """The game folder's mods and Fabric Loader's jar (FlatFabric.LOADER_JAR),
    exactly as the lock says. A vanilla game gets none."""
    mods = os.path.join(game_dir, "mods")
    shutil.rmtree(mods, ignore_errors=True)
    shutil.rmtree(os.path.join(game_dir, ".mctv-aot"), ignore_errors=True)
    if fabric:
        os.makedirs(mods)
        for m in mod_jars(g):
            shutil.copy2(m, mods)
        os.makedirs(os.path.join(game_dir, ".mctv-aot"))
        shutil.copy2(loader_jar(g), os.path.join(game_dir, ".mctv-aot", "fabric-loader.jar"))


def mac_run(profile, native, trace, seconds, quick, server=None, extra=()):
    fabric = profile == "fabric"
    baked = bake(profile)
    g, fid = game(fabric)
    _, natives = libraries(g, mac_natives=True)
    exe = image("mac", profile, quick) if native else None
    out = os.path.join(OUT, profile, "mac-run")
    game_dir = os.path.join(out, "game")
    os.makedirs(os.path.join(game_dir, "saves"), exist_ok=True)
    write_options(os.path.join(game_dir, "options.txt"), g, soundCategory_master="0.0", pauseOnLostFocus="false")
    if not os.path.exists(os.path.join(game_dir, "saves", WORLD)):
        shutil.copytree(make_world(g), os.path.join(game_dir, "saves", WORLD))
    sync_mods(g, game_dir, fabric)
    props = ["-Xms512m", "-Xmx768m", "-Ddev.isxander.sdl.library=" + controlify_sdl(natives)] + list(extra)  # the TV app's heap
    args = mc_args(g, game_dir, fid or VERSION, "AotDev", None if server else WORLD)
    if server:
        args += ["--quickPlayMultiplayer", server]
    if native:
        cmd = [exe] + props + args
    else:
        cmd = [java("java"), "-XstartOnFirstThread"] + props
        if trace:
            # The agent merges into build/aot/<profile>/trace, seeded with the
            # committed metadata. Classes mods define while running (Sodium's
            # vertex serializers) are recorded there too, as predefined classes
            # (aot/java/bake Generated). They're mods' code, so they stay in build.
            work = os.path.join(OUT, profile, "trace")
            os.makedirs(work, exist_ok=True)
            committed = os.path.join(CONFIG, "traced", profile, "reachability-metadata.json")
            if os.path.exists(committed):
                shutil.copy2(committed, os.path.join(work, "reachability-metadata.json"))
            cmd += ["-agentlib:native-image-agent=config-merge-dir=%s,config-write-period-secs=30" % work,
                    "-javaagent:%s=generated=%s" % (bake_jar(g), work),
                    "--add-modules", "jdk.graal.compiler", "--add-exports", "jdk.graal.compiler/jdk.graal.compiler.util=ALL-UNNAMED"]
        cmd += ["-cp", ":".join(runtime_classpath(profile, baked) + natives), main_class(profile)] + args
    log = os.path.join(out, "native.log" if native else "jvm.log")
    watch(cmd, seconds, log, game_dir, world=not server)
    mac_run.log = log
    if trace:
        traced = os.path.join(CONFIG, "traced", profile)
        os.makedirs(traced, exist_ok=True)
        shutil.copy2(os.path.join(OUT, profile, "trace", "reachability-metadata.json"), traced)
        normalize_metadata(os.path.join(traced, "reachability-metadata.json"))


def watch(cmd, seconds, log, cwd, world=True):
    """Runs the game until it exits or seconds pass, then stops it the way
    closing its window would. Reports when it got into the world and its peak
    memory."""
    say("%s ... (log in %s)" % (os.path.basename(cmd[0]), log))
    start = time.time()
    peak = 0
    with open(log, "w") as out:
        p = subprocess.Popen(cmd, stdout=out, stderr=subprocess.STDOUT, cwd=cwd)
        while p.poll() is None and (seconds is None or time.time() - start < seconds):
            rss = subprocess.run(["ps", "-o", "rss=", "-p", str(p.pid)], capture_output=True, text=True).stdout.strip()
            peak = max(peak, int(rss or 0))
            time.sleep(1)
        if p.poll() is None:
            p.send_signal(signal.SIGTERM)  # an orderly exit, so a tracing agent writes its files
            try:
                p.wait(timeout=60)
            except subprocess.TimeoutExpired:
                p.kill()
    text = open(log, errors="replace").read()
    joined = re.search(r"\[(\d\d):(\d\d):(\d\d)\] \[Server thread/INFO\]: .*joined the game", text)
    if not world:
        pass  # joined a server, which logs that itself
    elif joined:
        h, m, s = map(int, joined.groups())
        t = time.localtime(start)
        say("in the world %.0f s after launch" % ((h - t.tm_hour) * 3600 + (m - t.tm_min) * 60 + s - t.tm_sec - start % 1))
    else:
        say("didn't get into the world, see " + log)
    say("peak resident memory %d MB" % (peak >> 10))


# --- metadata ---------------------------------------------------------------

def normalize_metadata(path):
    """Sorts a reachability-metadata.json, so a trace's changes diff cleanly."""
    if not os.path.exists(path):
        return
    data = json.load(open(path))
    for k, v in data.items():
        if isinstance(v, list):
            data[k] = sorted(v, key=lambda e: json.dumps(e, sort_keys=True))
    with open(path, "w") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")


def gaps(log):
    """What a run's log says was missing, in reachability-metadata.json's form."""
    found = {"reflection": set(), "resources": set(), "jni": set()}
    for line in open(log, errors="replace"):
        m = re.search(r"Missing(Reflection|Resource|JNI)RegistrationError: .*?'([^']+)'", line)
        if m:
            kind = {"Reflection": "reflection", "Resource": "resources", "JNI": "jni"}[m.group(1)]
            found[kind].add(m.group(2))
    out = {
        "reflection": [{"type": t} for t in sorted(found["reflection"] | found["jni"])],
        "resources": [{"glob": r} for r in sorted(found["resources"])],
    }
    print(json.dumps(out, indent=2))


# --- native image -----------------------------------------------------------

def image_options(profile, baked, quick):
    """native-image's options, from aot/fixups.json and the bake."""
    dirs = [os.path.join(CONFIG, "common")]
    dirs.append(os.path.join(OUT, profile, "bake/metadata"))  # what the bake worked out
    traced = os.path.join(CONFIG, "traced", profile)
    if os.path.exists(os.path.join(traced, "reachability-metadata.json")):
        dirs.append(traced)
    o = ["-H:+UnlockExperimentalVMOptions", "--exact-reachability-metadata",
         "-H:MissingRegistrationReportingMode=Warn",
         "-H:+IncludeAllLocales", "-H:+ReportExceptionStackTraces",
         "-H:ConfigurationFileDirectories=" + ",".join(dirs),
         "--add-modules=" + ",".join(sorted(FIXUPS["addModules"])),
         "--initialize-at-run-time=" + ",".join(sorted(FIXUPS["initializeAtRunTime"]))]
    preserve = set()
    for source, entry in baked["entryOf"].items():
        if any(fnmatch.fnmatch(os.path.basename(source), p) for p in FIXUPS["preserve"]["jars"]):
            preserve.add(entry)
    if profile == "fabric":
        for mod in baked["mods"]:
            if mod["id"] not in FIXUPS["preserve"]["modsExcept"]:
                preserve.update(baked["entryOf"][s] for s in mod["codeSource"] if s in baked["entryOf"])
    o += ["-H:Preserve=path=" + p for p in sorted(preserve)]
    o += ["-H:Preserve=package=" + p for p in sorted(FIXUPS["preserve"]["packages"])]
    predefined = os.path.join(OUT, profile, "trace", "predefined-classes-config.json")
    if os.path.exists(predefined):
        o.append("-H:PredefinedClassesConfigurationFiles=" + predefined)
    o.append("-Ob" if quick else "-O3")  # -O3: all of GraalVM CE's optimisations, for the build that's played
    return o


TVOS_OPTIONS = ["-Dsvm.platform=org.graalvm.nativeimage.Platform$IOS_AARCH64", "-Dsvm.targetName=iOS",
                "-Dsvm.targetArch=arm64", "-H:PageSize=16384", "-H:+SharedLibrary", "-H:+ExitAfterRelocatableImageWrite"]


def image(target, profile, quick):
    """Builds the image: build/aot/<profile>/image/mac/mc, or for tvOS the
    relocatable object build/aot/<profile>/image/tvos/mc.o, which links for
    the Apple TV and the simulator alike."""
    baked = bake(profile)
    audit(profile)
    g, _ = game(profile == "fabric")
    cp = runtime_classpath(profile, baked)
    if target == "mac":
        cp += libraries(g, mac_natives=True)[1]
    out = os.path.join(OUT, profile, "image", target + flavour())
    options = image_options(profile, baked, quick) + (TVOS_OPTIONS if target == "tvos" else [])
    if BUILDER["gc"] == "g1":
        options.append("--gc=G1")
    if BUILDER["pgo"] == "instrument":  # and writing what it counted, which a shared library doesn't by default
        options += ["--pgo-instrument", "-H:+ProfilingEnableProfileDumpHooks"]
    elif BUILDER["pgo"] == "use":
        options.append("--pgo=" + pgo_file(profile))
    product = os.path.join(out, "mc.o" if target == "tvos" else "mc")
    key = inputs_key(cp + [CONFIG, FIXUPS_FILE] + ([pgo_file(profile)] if BUILDER["pgo"] == "use" else []), options + [builder_home()])
    if os.path.exists(product) and fresh(out, key):
        return product
    say("building the %s image for %s%s%s%s" % (profile, target, ", quickly" if quick else "",
                                                " with %s GraalVM and %s GC" % (BUILDER["graal"], BUILDER["gc"]) if flavour() else "",
                                                {"off": "", "use": ", optimised with aot/pgo/" + profile + ".iprof.gz",
                                                 "instrument": ", counting what runs, for PGO"}[BUILDER["pgo"]]))
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    tmp = os.path.join(out, "tmp")
    # cwd: the builder runs some of Log4j, which makes logs/ where it runs
    run([os.path.join(builder_home(), "bin", "native-image"), "-cp", ":".join(cp)] + options + ["-H:TempDirectory=" + tmp, "-o", os.path.join(out, "mc"),
        main_class(profile)], log=os.path.join(out, "build.log"), cwd=out)
    if target == "tvos":
        obj = next(os.path.join(d, f) for d, _, fs in os.walk(tmp) for f in fs if f == "mc.o")
        os.replace(obj, product)
    shutil.rmtree(tmp, ignore_errors=True)
    say("built %s (%d MB)" % (product, os.path.getsize(product) >> 20))
    mark(out, key)
    return product


# --- tvOS -------------------------------------------------------------------

def kit(sdk):
    """GraalVM's static libraries (Substrate VM's and the JDK's) relabeled for
    tvOS or its simulator, from its macOS arm64 ones."""
    home = builder_home()
    out = os.path.join(OUT, "kit", BUILDER["graal"], sdk)
    libs = sorted(os.path.join(home, "lib/svm/clibraries/darwin-aarch64", f)
                  for f in os.listdir(os.path.join(home, "lib/svm/clibraries/darwin-aarch64")) if f.endswith(".a"))
    libs += [os.path.join(home, "lib/static/darwin-aarch64/lib%s.a" % n) for n in JDK_STATIC]
    sdk_version = subprocess.check_output(["xcrun", "--sdk", "appletvos", "--show-sdk-version"], text=True).strip()
    key = inputs_key(libs, [sdk, MINOS, sdk_version])
    if fresh(out, key):
        return out
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    platform = machoplat.TVOS if sdk == "appletvos" else machoplat.TVOS_SIMULATOR
    for lib in libs:
        with tempfile.TemporaryDirectory() as work:
            run(["ar", "x", lib], cwd=work)
            objs = sorted(os.path.join(work, f) for f in os.listdir(work) if f.endswith(".o"))
            machoplat.relabel(objs, platform, MINOS, sdk_version)
            subprocess.run(["libtool", "-static", "-o", os.path.join(out, os.path.basename(lib))] + objs,
                           check=True, stderr=subprocess.DEVNULL)
    mark(out, key)
    return out


def game_library(sdk, obj):
    """The image linked with GraalVM's libraries into libmctvgame.dylib, which
    the app loads from its Frameworks. A dynamic library, not part of the app's
    executable: a Fabric image's code is one block past arm64's 128 MB branch
    range, which the linker can't put branch islands in, and calls between
    images go through dyld at any distance."""
    out = os.path.join(os.path.dirname(obj), sdk, "libmctvgame.dylib")
    target = "arm64-apple-tvos%s%s" % (MINOS, "-simulator" if sdk == "appletvsimulator" else "")
    k = kit(sdk)
    stubs = [os.path.join(ROOT, "aot/native/tvos_stubs.c")] if sdk == "appletvos" else []  # what the TV's compiler runtime lacks
    key = inputs_key([obj, k] + stubs, [sdk, target, link_libs()])
    if os.path.exists(out) and fresh(os.path.dirname(out), key):
        return out
    os.makedirs(os.path.dirname(out), exist_ok=True)
    run(["xcrun", "--sdk", sdk, "clang", "-target", target, "-dynamiclib", "-o", out, obj] + stubs + ["-L" + k] + link_libs() +
        ["-install_name", "@rpath/libmctvgame.dylib", "-Wl,-w"], log=out + ".log")
    mark(os.path.dirname(out), key)
    return out


def build_app(sdk, obj, bundle_id, team=None):
    """The app, with the game as libmctvgame.dylib in its Frameworks."""
    lib = game_library(sdk, obj)
    link = " ".join(["-L" + os.path.dirname(lib), "-lmctvgame", "-Wl,-rpath,@executable_path/Frameworks"])
    derived = os.path.join(OUT, "derived-" + sdk)
    for d in ("mctv/Resources/Assets.xcassets/App Icon & Top Shelf Image.brandassets", "mctv/TopShelf/Resources"):
        if not os.path.exists(os.path.join(ROOT, d)):
            die("no %s. Run scripts/setup.sh (it draws the app's art)" % d)
    run(["xcodegen", "generate", "--spec", os.path.join(ROOT, "mctv/project.yml"), "--quiet"])
    settings = ["MCTV_BUNDLE_ID=" + bundle_id, "MCTV_NATIVES_DIR=" + NATIVES,
                "MCTV_GAME_LDFLAGS=" + link, "MCTV_GAME_LIBRARY=" + lib]
    if team:
        settings += ["CODE_SIGN_STYLE=Automatic", "DEVELOPMENT_TEAM=" + team]
        extra = ["-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration"]
    else:
        settings += ["CODE_SIGNING_ALLOWED=NO", "DEVELOPMENT_TEAM="]
        extra = []
    run(["xcodebuild", "-project", os.path.join(ROOT, "mctv/MCTV.xcodeproj"), "-scheme", "MCTV", "-sdk", sdk,
         "-configuration", configuration(sdk), "-derivedDataPath", derived, "-quiet", "build"] + extra + settings,
        log=os.path.join(OUT, "xcodebuild-%s.log" % sdk))
    return os.path.join(derived, "Build/Products/%s-%s/MCTV.app" % (configuration(sdk), sdk))


def configuration(sdk):
    """The app shell (the bridges, input and frame pacing in Objective-C) optimised for the Apple TV, debuggable in the simulator."""
    return "Release" if sdk == "appletvos" else "Debug"


def stage(profile, lite):
    """What the app reads from Library/Caches/mctv/minecraft, without the
    jars, which are compiled in: assets (no music with lite), the version
    files, and for Fabric the mods and Fabric Loader's jar. Hard links, so it
    takes no space."""
    fabric = profile == "fabric"
    g, fid = game(fabric)
    out = os.path.join(OUT, profile, "stage", "minecraft")
    shutil.rmtree(out, ignore_errors=True)
    assets = os.path.join(OUT, "stage-assets-lite" if lite else "stage-assets")
    run([sys.executable, "-I", os.path.join(ROOT, "scripts/mc-stage.py"), g, VERSION, assets] + (["--lite"] if lite else []),
        log=assets + ".log")
    link_tree(os.path.join(assets, "minecraft/assets"), os.path.join(out, "assets"))
    for v in [VERSION] + ([fid] if fid else []):
        os.makedirs(os.path.join(out, "versions", v))
        shutil.copy2(os.path.join(g, "versions", v, v + ".json"), os.path.join(out, "versions", v))
    with open(os.path.join(out, "mctv-version.txt"), "w") as f:
        f.write((fid or VERSION) + "\n")
    sync_mods(g, out, fabric)
    return out, g


def signing():
    """config/signing.env (scripts/set-team.sh) as a dict."""
    env, path = {}, os.path.join(ROOT, "config/signing.env")
    for line in open(path) if os.path.exists(path) else []:
        m = re.match(r'\s*([A-Z_]+)="?([^"\n]*?)"?\s*$', line)
        if m:
            env[m.group(1)] = m.group(2)
    return env


class Simulator:
    """A tvOS simulator of its own, made the first time. The app gets every
    asset. It asks to sign in once, as on the TV."""
    sdk, key, lite, team, poll = "appletvsimulator", "sim", False, None, 2

    def __init__(self, sound=False):
        self.sound = sound
        out = subprocess.check_output(["xcrun", "simctl", "list", "devices"], text=True)
        m = re.search(re.escape(SIM_NAME) + r" \(([0-9A-F-]{36})\)", out)
        if m:
            self.udid = m.group(1)
        else:
            say("making the simulator %s" % SIM_NAME)
            r = subprocess.run(["xcrun", "simctl", "create", SIM_NAME, SIM_TYPE, SIM_RUNTIME], capture_output=True, text=True)
            if r.returncode:
                die("couldn't make the simulator (%s). It needs the tvOS 27.2 runtime: xcodebuild -downloadPlatform tvOS" % r.stderr.strip())
            self.udid = r.stdout.strip()
        subprocess.run(["xcrun", "simctl", "boot", self.udid], capture_output=True)
        subprocess.run(["xcrun", "simctl", "bootstatus", self.udid, "-b"], capture_output=True)

    def container(self, bid):
        r = subprocess.run(["xcrun", "simctl", "get_app_container", self.udid, bid, "data"], capture_output=True, text=True)
        return os.path.join(r.stdout.strip(), "Library/Caches/mctv") if r.returncode == 0 else None

    def install(self, app, bid):
        run(["xcrun", "simctl", "install", self.udid, app])
        subprocess.run(["xcrun", "simctl", "terminate", self.udid, bid], capture_output=True)

    def push(self, staged, g, bid, world):
        caches = self.container(bid)
        game_dir = os.path.join(caches, "minecraft")
        os.makedirs(game_dir, exist_ok=True)
        keep = ["saves", "options.txt", "config", "logs", "crash-reports", ".fabric", "screenshots", "servers.dat"]
        run(["rsync", "-a", "--delete"] + [a for k in keep for a in ("--exclude", "/" + k)] + [staged + "/", game_dir + "/"])
        # The simulator plays through this Mac's speakers, so test runs are muted
        mute = {} if self.sound else {"soundCategory_master": "0.0"}
        write_options(os.path.join(game_dir, "options.txt"), g, **mute)
        if world:
            run(["rsync", "-a", "--delete", make_world(g) + "/", os.path.join(game_dir, "saves", WORLD) + "/"])
        for f in ("java.log", "mctv.log"):
            if os.path.exists(os.path.join(caches, f)):
                os.remove(os.path.join(caches, f))

    def launch(self, bid, args):
        return int(subprocess.check_output(["xcrun", "simctl", "launch", self.udid, bid] + args, text=True).rsplit(":", 1)[1])

    def server_address(self):
        return "127.0.0.1"  # the simulator shares this Mac's network

    def alive(self, pid):
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False

    def screenshot(self, path):
        subprocess.run(["xcrun", "simctl", "io", self.udid, "screenshot", path], capture_output=True)

    def crash_report(self, since):
        """The app's newest crash report from after since, which the simulator leaves with the Mac's, or None."""
        reports = os.path.expanduser("~/Library/Logs/DiagnosticReports")
        found = sorted((os.path.getmtime(os.path.join(reports, f)), os.path.join(reports, f))
                       for f in os.listdir(reports) if f.startswith("MCTV-") and f.endswith(".ips")) if os.path.isdir(reports) else []
        found = [p for t, p in found if t >= since]
        return found[-1] if found else None

    def fetch(self, bid, name, dest):
        src = os.path.join(self.container(bid), name)
        if os.path.exists(src):
            shutil.copy2(src, dest)


class AppleTV:
    """The Apple TV paired with this Mac, or DEVICE in config/signing.env.
    Signed by DEVELOPMENT_TEAM. Assets without music, to push quickly. The app
    has a Keychain of its own, so it asks to sign in once. Test runs are muted
    unless --sound, as in the simulator."""
    sdk, key, lite, poll = "appletvos", "device", True, 10

    def __init__(self, sound=False):
        self.sound = sound
        env = signing()
        self.team = env.get("DEVELOPMENT_TEAM") or die("no DEVELOPMENT_TEAM in config/signing.env (scripts/set-team.sh)")
        if self.team in env.get("REFUSE_TEAMS", "").split():
            die("config/signing.env refuses team " + self.team)
        self.dev = env.get("DEVICE")
        if not self.dev:
            listing = json.loads(self.devicectl(["list", "devices"]))
            tv = next((d for d in listing["result"]["devices"] if d.get("hardwareProperties", {}).get("reality") == "physical"
                       and d["hardwareProperties"].get("platform") == "tvOS"), None)
            self.dev = tv["identifier"] if tv else die("no Apple TV paired with this Mac")

    def devicectl(self, args):
        """devicectl's JSON result. Its own options go before a "--", after which everything is the app's."""
        with tempfile.NamedTemporaryFile(suffix=".json") as f:
            cut = args.index("--") if "--" in args else len(args)
            subprocess.run(["xcrun", "devicectl"] + args[:cut] + ["--json-output", f.name] + args[cut:], check=True, capture_output=True)
            return open(f.name).read()

    def install(self, app, bid):
        key, stamp = inputs_key([app], self.dev), os.path.join(OUT, "device-installed")
        if fresh(stamp, key):  # the same app is on the TV already
            return
        self.devicectl(["device", "install", "app", "--device", self.dev, app])
        os.makedirs(stamp, exist_ok=True)
        mark(stamp, key)

    def push(self, staged, g, bid, world):
        self.push_folder(staged, g, bid, world)
        if not self.sound:  # in the TV's own options, keeping the rest of what's changed there
            with tempfile.TemporaryDirectory() as tmp:
                path = os.path.join(tmp, "options.txt")
                self.fetch(bid, "minecraft/options.txt", path)
                write_options(path, g, soundCategory_master="0.0")
                self.devicectl(["device", "copy", "to", "--device", self.dev, "--domain-type", "appDataContainer", "--domain-identifier",
                                bid, "--source", path, "--destination", "Library/Caches/mctv/minecraft/options.txt"])

    def push_folder(self, staged, g, bid, world):
        marker = os.path.join(OUT, "device-options-pushed")
        if not os.path.exists(marker):  # once, so later pushes keep what's changed on the TV
            write_options(os.path.join(staged, "options.txt"), g)
        if world:
            link_tree(make_world(g), os.path.join(staged, "saves", WORLD))
        key, stamp = inputs_key([staged], [self.dev, bid]), os.path.join(OUT, "device-pushed")
        if fresh(stamp, key):  # the TV has this game folder already
            return
        self.devicectl(["device", "copy", "to", "--device", self.dev, "--domain-type", "appDataContainer",
                        "--domain-identifier", bid, "--source", staged, "--destination", "Library/Caches/mctv/minecraft"])
        open(marker, "w").close()
        os.makedirs(stamp, exist_ok=True)
        mark(stamp, key)

    def server_address(self):
        """This Mac's address on the network the TV is on."""
        iface = re.search(r"interface: (\S+)", subprocess.check_output(["route", "-n", "get", "default"], text=True)).group(1)
        return subprocess.check_output(["ipconfig", "getifaddr", iface], text=True).strip()

    def launch(self, bid, args):
        out = json.loads(self.devicectl(["device", "process", "launch", "--device", self.dev, "--terminate-existing", bid, "--"] + args))
        return out["result"]["process"]["processIdentifier"]

    def alive(self, pid):
        try:
            procs = json.loads(self.devicectl(["device", "info", "processes", "--device", self.dev]))
        except subprocess.CalledProcessError:
            return True
        return any(p.get("processIdentifier") == pid for p in procs["result"]["runningProcesses"])

    def screenshot(self, path):
        subprocess.run(["xcrun", "devicectl", "device", "capture", "screenshot", "--device", self.dev, "--destination", path],
                       capture_output=True)

    def fetch(self, bid, name, dest):
        subprocess.run(["xcrun", "devicectl", "device", "copy", "from", "--device", self.dev, "--domain-type",
                        "appDataContainer", "--domain-identifier", bid, "--source", "Library/Caches/mctv/" + name,
                        "--destination", dest], capture_output=True)


FATAL = re.compile(r'Fatal error|---- Minecraft Crash Report|Exception in thread "(main|Render thread)"')


def play(target, profile, quick, world, wait, app_args, multiplayer=False):
    """Runs the app on target, in the test world with world, or with
    multiplayer joined to a local test server."""
    if not multiplayer:
        return _play(target, profile, quick, world, wait, app_args)
    g, _ = game(profile == "fabric")
    with test_server(g, target.server_address()) as server:
        _play(target, profile, quick, False, wait, ["-gamearg", "--quickPlayMultiplayer", "-gamearg", server.address] + app_args)


def _play(target, profile, quick, world, wait, app_args):
    _run(target, _prepare(target, profile, quick), profile, world, wait, app_args)


def _prepare(target, profile, quick):
    """The slow part: the image, the app around it, installed, and the game staged."""
    bid = signing().get("BUNDLE_PREFIX", "com.example.mctv")
    obj = image("tvos", profile, quick)
    say("building MCTV for %s" % target.sdk)
    app = build_app(target.sdk, obj, bid, team=target.team)
    target.install(app, bid)
    staged, g = stage(profile, target.lite)
    return {"bid": bid, "staged": staged, "game": g}


def _run(target, ready, profile, world, wait, app_args):
    """Pushes the game, runs it, and watches its log, taking a screenshot every
    30 s, until it exits, a fatal error shows or wait seconds pass."""
    bid = ready["bid"]
    say("pushing the game")
    target.push(ready["staged"], ready["game"], bid, world)
    args = (["-gamearg", "--quickPlaySingleplayer", "-gamearg", WORLD] if world else []) + app_args
    out = os.path.join(OUT, profile, target.key)
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    log = os.path.join(out, "java.log")
    pid = target.launch(bid, args)
    say("running, watching for %d s" % wait)
    start = time.time()
    shots = 0
    exited = None
    while time.time() - start < wait:
        time.sleep(target.poll)
        target.fetch(bid, "java.log", log)
        if os.path.exists(log) and FATAL.search(open(log, errors="replace").read()):
            say("fatal error in java.log after %.0f s" % (time.time() - start))
            break
        if not target.alive(pid):
            exited = time.time() - start
            say("app exited after %.0f s" % exited)
            break
        if (time.time() - start) // 30 > shots:
            shots += 1
            target.screenshot(os.path.join(out, "%d.png" % shots))
    target.screenshot(os.path.join(out, "last.png"))
    for f in ("java.log", "mctv.log"):
        target.fetch(bid, f, os.path.join(out, f))
    run_info = {"exited_after": exited}
    if exited is not None and hasattr(target, "crash_report"):
        ips = None
        for _ in range(15):  # the report lands a few seconds after the process goes
            ips = target.crash_report(start)
            if ips:
                break
            time.sleep(2)
        if ips:
            shutil.copy2(ips, os.path.join(out, "crash.ips"))
            run_info["native_crash"] = native_crash(ips)
            say("native crash: %s" % run_info["native_crash"]["summary"])
    with open(os.path.join(out, "run.json"), "w") as f:
        json.dump(run_info, f, indent=2)
    report(out)


def native_crash(ips):
    """What a crash report says: the exception and the faulting thread's top frames."""
    head, _, body = open(ips).read().partition("\n")
    d = json.loads(body)
    images = d.get("usedImages", [])
    thread = d["threads"][d.get("faultingThread", 0)]
    frames = []
    for fr in thread.get("frames", [])[:12]:
        i = fr.get("imageIndex")
        image = images[i].get("name") or os.path.basename(images[i].get("path", "?")) if i is not None and i < len(images) else "?"
        frames.append("%s %s" % (image, fr.get("symbol", "+0x%x" % fr.get("imageOffset", 0))))
    exc = d.get("exception", {})
    return {"exception": exc, "frames": frames,
            "summary": "%s in %s" % (exc.get("signal") or exc.get("type"), next((f for f in frames if not f.startswith("?")), "?"))}


def report(out):
    log = os.path.join(out, "java.log")
    if not os.path.exists(log):
        say("no java.log")
        return
    text = open(log, errors="replace").read()
    if re.search(r"Loading Minecraft .* with Fabric Loader", text):
        mods = re.search(r"Loading (\d+) mods", text)
        say("Fabric started with %s mods" % (mods.group(1) if mods else "?"))
    if "joined the game" in text:
        say("in a world")
    missing = sorted(set(re.findall(r"Missing(?:Reflection|JNI)RegistrationError: .*?'([^']+)'", text)))
    defined = sorted(set(re.findall(r"Tried to define class:\s+(\S+)", text)))
    if missing:
        say("%d missing reflection or JNI registrations (aot.py gaps %s)" % (len(missing), log))
    if defined:
        say("classes defined at run time that weren't recorded (aot.py run --trace): " + ", ".join(defined))
    say("logs and screenshots in " + out)


# --- chaos -------------------------------------------------------------------

def feed(server, timeline, stop):
    """Plays a chaos timeline into the server's console, timed from when the
    player joins, until it ends or stop is set."""
    joined = server.wait_joined(300)
    if not joined:
        say("chaos: nobody joined the test server")
        return
    for t, cmd in timeline:
        while time.time() < joined + t:
            if stop.wait(0.2):
                return
        server.command(cmd)


# An instrumented image writes its counts when it exits, which the app never does, so every 30 s, saying
# so in java.log. Relative to the game folder, where the app starts the game.
PROFILING_ARGS = ["-XX:ProfilesDumpFile=pgo.iprof", "-XX:ProfilingDumpPeriod=30", "-XX:+ProfilingDumpVerbose"]
DUMPED = "[PGO] dumped profile"


def collect_profile(target, bid, dest):
    """Copies an instrumented app's counts just after it next writes them. It
    rewrites the one file in place, so it's only whole between writes. Then
    stops the app, which a run otherwise leaves going."""
    log = os.path.join(target.container(bid), "java.log")
    seen = open(log, errors="replace").read().count(DUMPED)
    deadline = time.time() + 120
    while time.time() < deadline:
        time.sleep(1)
        if open(log, errors="replace").read().count(DUMPED) > seen:
            target.fetch(bid, "minecraft/pgo.iprof", dest)
            break
    subprocess.run(["xcrun", "simctl", "terminate", target.udid, bid], capture_output=True)


def chaos(profile, quick, seed, minutes, mac=False, native=False, trace=False, jvmargs=(), device=False, sound=False,
          profiling=False):
    """A seeded chaos run: the world side from the test server's console and,
    in the simulator, the player side from the app's input script (aot/chaos.py).
    Its timelines, logs and report.json go to build/aot/<profile>/chaos/<seed>.
    With profiling, an instrumented image's counts go there too, as pgo.iprof."""
    seconds = minutes * 60
    variant = "".join("-" + re.sub(r"[^A-Za-z0-9=.]+", "", a) for a in jvmargs)  # runtime options under test, in the folder name
    out = os.path.join(OUT, profile, "chaos", str(seed) + ("-mac" if mac else "-tv" if device else "") + flavour() + variant)
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    timeline = chaos_lib.server_timeline(seed, seconds)
    with open(os.path.join(out, "server-timeline.txt"), "w") as f:
        f.writelines("%7.1f  %s\n" % tc for tc in timeline)
    g, _ = game(profile == "fabric")
    stop = threading.Event()
    target = None if mac else AppleTV(sound) if device else Simulator(sound)
    # Everything slow first, so the player joins soon after the server is up
    if mac:
        if native:
            image("mac", profile, quick)
    else:
        ready = _prepare(target, profile, quick)
    with test_server(g, target.server_address() if device else "127.0.0.1") as server:
        feeder = threading.Thread(target=feed, args=(server, timeline, stop), daemon=True)
        feeder.start()
        try:
            if mac:
                mac_run(profile, native, trace, seconds + 30, quick, server=server.address,
                        extra=["-XX:+PrintGC", "-Dmctv.sweep=3"] + list(jvmargs))
                logs = {"java": mac_run.log}
            else:
                script = chaos_lib.input_script(seed, seconds + 30)  # to the end, so the game never idles
                with open(os.path.join(out, "input-script.txt"), "w") as f:
                    f.write(script.replace("; ", "\n") + "\n")
                if profiling:  # none left from an earlier run
                    with contextlib.suppress(FileNotFoundError):
                        os.remove(os.path.join(target.container(ready["bid"]), "minecraft", "pgo.iprof"))
                _run(target, ready, profile, False, seconds + 30,
                     ["-gamearg", "--quickPlayMultiplayer", "-gamearg", server.address,
                      "-inputtest", script, "-jvmarg", "-XX:+PrintGC", "-jvmarg", "-Dmctv.sweep=3"]
                     + [x for a in list(jvmargs) + (PROFILING_ARGS if profiling else []) for x in ("-jvmarg", a)])
                if profiling:
                    collect_profile(target, ready["bid"], os.path.join(out, "pgo.iprof"))
                logs = {"java": os.path.join(OUT, profile, target.key if target else "sim", "java.log"), "mctv": os.path.join(OUT, profile, target.key if target else "sim", "mctv.log")}
        finally:
            stop.set()
            feeder.join(5)
    shutil.copy2(server.log, os.path.join(out, "server.log"))
    for kind, path in logs.items():
        if os.path.exists(path):
            shutil.copy2(path, os.path.join(out, kind + ".log"))
    for png in os.listdir(os.path.join(OUT, profile, target.key)) if not mac else []:
        if png.endswith(".png"):
            shutil.copy2(os.path.join(OUT, profile, target.key if target else "sim", png), out)
    report = chaos_lib.assess(os.path.join(out, "java.log"), os.path.join(out, "mctv.log") if not mac else None,
                              os.path.join(out, "server.log"), seconds)
    run_json = os.path.join(OUT, profile, target.key if target else "sim", "run.json")
    if not mac and os.path.exists(run_json):
        run_info = json.load(open(run_json))
        for f in ("run.json", "crash.ips"):
            if os.path.exists(os.path.join(OUT, profile, target.key if target else "sim", f)):
                shutil.copy2(os.path.join(OUT, profile, target.key if target else "sim", f), out)
        if run_info.get("exited_after") is not None and run_info["exited_after"] < seconds:
            report["crashed"] = True
            report["exited_after_s"] = round(run_info["exited_after"])
        if run_info.get("native_crash"):
            report["native_crash"] = run_info["native_crash"]
        report["passed"] = report["passed"] and not report["crashed"]
    report["seed"], report["minutes"], report["where"] = seed, minutes, "mac" if mac else "simulator"
    report["jvmargs"], report["builder"] = list(jvmargs), dict(BUILDER)
    with open(os.path.join(out, "report.json"), "w") as f:
        json.dump(report, f, indent=2, sort_keys=True)
        f.write("\n")
    say("chaos %s: %s" % (seed, "passed" if report["passed"] else "FAILED"))
    for k in ("crashed", "app_failed", "no_java_log", "exited_after_s", "joined", "screens", "disconnects", "activity", "missing_registrations", "undefined_classes",
              "fps", "gc", "memory_mb"):
        if k in report:
            say("  %s: %s" % (k, report[k]))
    if report.get("native_crash"):
        say("  native crash: %s" % report["native_crash"]["summary"])
        for frame in report["native_crash"]["frames"][:6]:
            say("    " + frame)
    if report["errors"]:
        say("  %d distinct errors in java.log (report.json)" % len(report["errors"]))
    say("timelines, logs and report in " + out)
    if profiling and os.path.exists(os.path.join(out, "pgo.iprof")):
        report["profile_file"] = os.path.join(out, "pgo.iprof")
    return report


def make_profile(profile, seed, minutes):
    """PGO's profile: an instrumented image played through a chaos run in the
    simulator, gzipped into aot/pgo/<profile>.iprof.gz. The TV runs the same
    code, so the simulator's counts serve it too."""
    if BUILDER["graal"] != "oracle":
        die("PGO is in Oracle GraalVM only")
    BUILDER["pgo"] = "instrument"
    report = chaos(profile, False, seed, minutes, profiling=True)  # in the simulator, whose files this Mac can read
    src = report.get("profile_file") or die("the run wrote no profile")
    if not report["passed"]:
        say("the profiling run didn't pass, so look at its report before trusting the profile")
    os.makedirs(PGO_DIR, exist_ok=True)
    dest = pgo_file(profile)
    with open(src, "rb") as f, open(dest + ".tmp", "wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as z:  # the same bytes from the same counts
            shutil.copyfileobj(f, z)
    os.replace(dest + ".tmp", dest)
    say("saved %s (%d MB, %d MB unpacked). Images are built with it from now on" % (
        os.path.relpath(dest, ROOT), os.path.getsize(dest) >> 20, os.path.getsize(src) >> 20))


# --- adding mods -----------------------------------------------------------

def locked_mods():
    return {m["file"]: m for m in json.load(open(LOCK)).get(VERSION, {}).get("mods", [])}


def packages(jar):
    """The packages a mod jar's classes are in, two or three names deep, for finding it in a log."""
    out = set()
    with zipfile.ZipFile(jar) as z:
        for n in z.namelist():
            if n.endswith(".class") and n.count("/") >= 2 and not n.startswith("META-INF/"):
                out.add(".".join(n.split("/")[:3 if n.count("/") >= 3 else 2]))
    return out


def mentions(log, prefixes, limit=12):
    """Errors and warnings in a log that come from these packages, and stack frames in them."""
    found = []
    if not os.path.exists(log):
        return found
    for line in open(log, errors="replace"):
        line = line.rstrip()
        hit = any(p in line for p in prefixes)
        if hit and ("ERROR" in line or "WARN" in line or "Exception" in line or "Error:" in line or line.lstrip().startswith("at ")):
            if line not in found:
                found.append(line)
        if len(found) >= limit:
            break
    return found


def modrinth_project(slug):
    """A Modrinth slug's project id."""
    req = urllib.request.Request("https://api.modrinth.com/v2/project/" + urllib.parse.quote(slug),
                                 headers={"User-Agent": "mctv-aot/1.0 (MCTV, a tvOS launcher)"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())["id"]


def add_mods(slugs, quick, seed, minutes, check):
    """aot.py add: locks the mods and what they need, bakes and audits, and
    unless --no-chaos plays a chaos run in the simulator, then says what in
    the run came from the new mods."""
    before = locked_mods()
    if subprocess.run([sys.executable, "-I", os.path.join(ROOT, "scripts/fetch-fabric.py"), "--add"] + slugs + [VERSION]).returncode:
        die("the lock is as it was")
    after = locked_mods()
    # the mods asked for, whether newly locked or not (a retry after a fix), and what came in with them
    asked = {modrinth_project(slug) for slug in slugs}
    names = {m["file"].rsplit(".jar", 1)[0] for m in after.values() if m.get("project") in asked}
    new = [m for f, m in after.items() if f not in before or m.get("project") in asked or m.get("for") in names | set(slugs)]
    try:
        audit("fabric")
    except SystemExit as stopped:
        print(stopped.code, file=sys.stderr)
        die("to back out: python3 -I aot/aot.py remove " + " ".join(slugs))
    if not check:
        say("audit passed. python3 -I aot/aot.py chaos --seed %d plays it" % seed)
        return
    report = chaos("fabric", quick, seed, minutes)
    g, _ = game(True)
    prefixes = set()
    for m in new:
        prefixes |= packages(os.path.join(g, "mods", m["file"]))
    lines = mentions(os.path.join(OUT, "fabric", "chaos", str(seed), "java.log"), prefixes)
    if lines:
        say("from the new mods in the run's log:")
        for line in lines:
            say("  " + line[:220])
    crash = report.get("native_crash")
    if crash and any(re.search(r"\bGL\w*_n?gl[A-Z]", f) for f in crash["frames"]):
        users = []
        for m in new:
            with zipfile.ZipFile(os.path.join(g, "mods", m["file"])) as z:
                n = sum(1 for e in z.namelist() if e.endswith(".class") and b"org/lwjgl/opengl/" in z.read(e))
            if n:
                users.append("%s (%d classes)" % (m["file"], n))
        say("the crash is in an OpenGL call, and this app renders only through Vulkan. New mods that call OpenGL directly: %s"
            % (", ".join(users) or "none, so look at the frames above"))
    if not report["passed"]:
        die("the chaos run failed (above). To back out: python3 -I aot/aot.py remove " + " ".join(slugs))
    say("%s added and played" % ", ".join(m["file"] for m in new) if new else "played")


def remove_mods(slugs):
    """aot.py remove: unlocks the mods and the dependencies nothing else needs, and audits, which names any
    review entries only they had."""
    if subprocess.run([sys.executable, "-I", os.path.join(ROOT, "scripts/fetch-fabric.py"), "--remove"] + slugs + [VERSION]).returncode:
        die("the lock is as it was")
    audit("fabric")


# --- main -------------------------------------------------------------------

def main():
    argv = sys.argv[1:]
    app_args = []
    if "--" in argv:
        app_args = argv[argv.index("--") + 1:]
        argv = argv[:argv.index("--")]
    p = argparse.ArgumentParser(prog="aot.py", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("command", choices=["add", "remove", "bake", "audit", "run", "image", "sim", "device", "chaos", "pgo", "gaps", "kit"])
    p.add_argument("target", nargs="*")
    p.add_argument("--no-chaos", action="store_true")
    p.add_argument("--jvmarg", action="append", default=[], help="a runtime option for the game in a chaos run, as --jvmarg=-Xmn256m")
    p.add_argument("--vanilla", action="store_true")
    p.add_argument("--graal", choices=sorted(GRAALS), default="oracle", help="whose GraalVM builds the image (deps/graalvm-oracle, deps/graalvm)")
    p.add_argument("--gc", choices=["serial", "g1"], help="the image's collector, G1 with Oracle's and Serial with CE unless set. G1 needs --graal oracle")
    p.add_argument("--no-pgo", action="store_true", help="build the image without aot/pgo's profile")
    p.add_argument("--native", action="store_true")
    p.add_argument("--trace", action="store_true")
    p.add_argument("--quick", action="store_true")
    p.add_argument("--world", action="store_true")
    p.add_argument("--multiplayer", action="store_true")
    p.add_argument("--sound", action="store_true")
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--minutes", type=int, default=10)
    p.add_argument("--mac", action="store_true")
    p.add_argument("--device", action="store_true", help="chaos on the Apple TV, joined to a test server on this Mac")
    p.add_argument("--seconds", type=int, default=90)
    p.add_argument("--wait", type=int, default=150)
    a = p.parse_args(argv)
    target = a.target[0] if a.target else None
    profile = "vanilla" if a.vanilla else "fabric"
    BUILDER.update(graal=a.graal, gc=a.gc or ("g1" if a.graal == "oracle" else "serial"))
    if BUILDER["gc"] == "g1" and a.graal != "oracle":
        die("G1 is in Oracle GraalVM only")
    if a.graal == "oracle" and not a.no_pgo and os.path.exists(pgo_file(profile)):
        BUILDER["pgo"] = "use"
    if not os.path.exists(os.path.join(builder_home(), "bin", "native-image")):
        die("no %s GraalVM in %s (aot/README.md)%s" % (a.graal, os.path.dirname(os.path.dirname(builder_home())),
                                                       ", or --graal ce for CE alone, with Serial GC" if a.graal == "oracle" else ""))
    if not os.path.exists(java("native-image")):
        die("no GraalVM in deps/graalvm (aot/README.md)")
    if a.command in ("add", "remove"):
        if a.vanilla or not a.target:
            die("%s takes Modrinth slugs, for the Fabric build" % a.command)
        if a.command == "remove":
            remove_mods(a.target)
        else:
            add_mods(a.target, a.quick, a.seed, a.minutes, not a.no_chaos)
    elif a.command == "bake":
        bake(profile)
    elif a.command == "audit":
        audit(profile)
    elif a.command == "run":
        mac_run(profile, a.native, a.trace, a.seconds, a.quick)
    elif a.command == "image":
        if target not in ("mac", "tvos"):
            die("image mac or image tvos")
        image(target, profile, a.quick)
    elif a.command == "sim":
        play(Simulator(a.sound), profile, a.quick, a.world, a.wait, app_args, a.multiplayer)
    elif a.command == "device":
        play(AppleTV(a.sound), profile, a.quick, a.world, a.wait, app_args, a.multiplayer)
    elif a.command == "chaos":
        chaos(profile, a.quick, a.seed, a.minutes, a.mac, a.native, a.trace, a.jvmarg, a.device, a.sound)
    elif a.command == "pgo":
        make_profile(profile, a.seed, a.minutes)
    elif a.command == "gaps":
        gaps(target)
    elif a.command == "kit":
        for sdk in ("appletvos", "appletvsimulator"):
            say(kit(sdk))


if __name__ == "__main__":
    main()
