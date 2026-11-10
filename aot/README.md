# Building the game

`aot.py` builds Minecraft 26.3 with Fabric and the mods in `scripts/fabric-lock.json`, or vanilla, compiled ahead of time with GraalVM Native Image into the app's `libmctvgame.dylib`, and builds, installs and runs the app around it. Run `scripts/setup.sh` first.

## Use it

```sh
python3 -I aot/aot.py sim --world          # build everything and play in the simulator's test world
python3 -I aot/aot.py sim --multiplayer    # the same, joined to a local test server
python3 -I aot/aot.py device               # the Apple TV
python3 -I aot/aot.py run --trace          # play on this Mac's JVM, recording what the image needs
python3 -I aot/aot.py add <slug>           # add a mod from Modrinth, audit it and play it (Adding a mod)
python3 -I aot/aot.py audit                # check every dynamic site the analysis left is reviewed
python3 -I aot/aot.py chaos --seed 1       # a seeded chaos run against a local test server
python3 -I aot/aot.py pgo                  # profile a chaos run for profile-guided optimisation
```

`--quick` builds the image faster, and it runs slower. Test runs are muted unless you add `--sound`. `--vanilla` leaves Fabric out. Runs on this Mac open a game window for `--seconds`. `python3 -I aot/aot.py --help` has the rest.

## GraalVM

GraalVM Community Edition in `deps/graalvm` runs the bake and compiles the app's Java. Oracle GraalVM in `deps/graalvm-oracle` builds the image, because it has the G1 collector for macOS arm64 and the tvOS build takes it too. Both are release 25.5.5.0.3, and `scripts/setup.sh` installs them. Oracle publishes no checksum, so setup checks the SHA-256 the release had when this was written and that Oracle America (VB5E2TV963) signed it.

`--graal ce` builds the image with Community Edition instead, which only has the Serial collector. Its full collections stop the game for about 300 ms on the Apple TV, where G1's pauses stay under about 20 ms once the game is playing. Each builder gets its own image folder and chaos reports.

## Profile-guided optimisation

`aot.py pgo` builds an image that counts what runs, plays it through a chaos run in the simulator and saves the counts in `aot/pgo/fabric.iprof.gz`. Images are built with them from then on, unless you add `--no-pgo`. The TV runs the same code, so the simulator's profile serves it too. A shared library doesn't write its profile by default, so the profiling build adds `-H:+ProfilingEnableProfileDumpHooks`, and the run has it write every 30 s and copies it just after a write. Make a new profile after changing mods.

With a profile the game's machine code is about a quarter of the size, 92 MB against 397 MB. It made no difference to frame times in the simulator, where the game isn't short of CPU.

## Chaos runs

`aot.py chaos` plays the game against a test server on this Mac for `--minutes`. A timeline from `--seed` drives the server's console (teleports, structures, mobs, game modes), and an input script from the same seed drives the player until the end. Partway in, the run opens every settings screen, the game's and each mod's, where mods reflect most. The report (`build/aot/<profile>/chaos/<seed>...`) has crashes, missing registrations, the screens, frame times, CPU, collections and memory. `--device` runs it on the Apple TV, which must be on this Mac's network. `--mac` runs the world side on this Mac.

## Adding a mod

```sh
python3 -I aot/aot.py add modmenu          # a Modrinth slug, or several
python3 -I aot/aot.py remove modmenu       # back out
```

`add` locks the mod's newest release for 26.3 and any dependencies that aren't locked yet, leaving every other mod as it is. It bakes, audits, builds the image and plays a chaos run in the muted simulator. Then it lists what in the run's log came from the new mod, and, if the app crashed natively, where. `--no-chaos` stops after the audit. `remove` takes the mod out with the dependencies nothing else needs. Both are `scripts/fetch-fabric.py --add` and `--remove` underneath. The bake and the simulator run the mod on this Mac, so add only mods you trust.

Most mods need nothing more. The bake applies their mixins, the image keeps their classes whole so their reflection on themselves works, and their entrypoints are registered from their metadata. Reflection the analysis can't settle inside a mod is left to the chaos run, which fails on any lookup the image is missing.

The audit stops for a person on three things, each listed with where its values come from:

- **Code that makes classes while running** (generated serializers, proxies of interfaces it can't see, class bytes read by name). It needs compat code in `aot/java/compat/<mod id>`, which replaces it and is only built when that mod is there. Sodium's is the example.
- **Native code**, a library loaded or a call through FFM. It needs that library built for tvOS and shipped in the app, as Controlify's SDL is.
- **Reflection outside mods**, which only changes with Minecraft, Fabric or a library.

Once one is handled, or fine as it is, it goes in `aot/reviewed.json` under a reason, and the audit prints a block to paste. If a run still turns something up missing, `aot.py gaps <log>` turns it into metadata for `aot/config/common`, and a library quirk goes in `aot/fixups.json` with its reason.

Some mods are known not to work yet:

- Iris calls OpenGL, and the app renders only through Vulkan.
- Simple Voice Chat carries its audio codecs (Opus, RNNoise, LAME, Speex) for desktops only.
- Kotlin mods (Zoomify) bring kotlin-reflect, whose annotation proxies the audit stops on.

## How it works

1. **Bake** (`java/bake`). Fabric starts on GraalVM's JVM as it does for the game, and stops before launching it. Every class in the game, the mods and the libraries is then loaded without being run, and a capture agent keeps the bytes the JVM was given, after Fabric's mixins and class tweaks and the app's agent (`java/mctv-agent`). Classes those name that no jar has, which Mixin generates, are asked for until none are left. Mixin's own classes are merged into their targets, so they're left out. Mixin's session id is fixed and every entry is dated 1980, so the same inputs bake the same bytes. `build/aot/fabric/bake/bake.json` lists what was baked and what couldn't load, which is optional integrations for mods that aren't installed.
2. **Flat launch** (`java/runtime-fabric`). `FlatFabric` is Fabric's Knot without what an image can't do and the bake already did: its class loader, class tweaks and transformers. Fabric still finds the mods in `mods/`, reads their metadata and resources from their jars and runs their entrypoints. Mixin is started with no configs, and each config's plugin gets its `onLoad`, which mods use to load their settings.
3. **Analysis** (`java/bake/.../Analysis.java`). Dataflow over every method that reflects, loads a class by name, makes a proxy, reads class bytes by name, defines a class, loads a native library or calls through FFM. It follows values through locals, casts, `Class.forName`, `loadClass` and javac 1.4's class caches. A lookup on constants GraalVM can fold is left to it, and a lookup on one of several constants or with a dynamic name gets those classes' members registered. A method that only reflects on what it's given, a Class or a class's name, is checked at its callers instead, including calls through a superclass or interface method it overrides, and as far up as callers pass their own parameters on. That covers Fabric's events (a proxy and an array for each), JNA's libraries, Sodium's dependency injection and Minecraft's Vulkan structs. Classes for other operating systems (`fixups.json`, otherPlatforms) are skipped. What's left goes to `audit.json` with where its values come from, and `aot.py audit` checks it against `aot/reviewed.json` before any image.
4. **Image**. native-image compiles the baked class path with the options in `aot/fixups.json`, the metadata in `aot/config` (hand-written and traced), the interfaces of method-reference entrypoints (worked out by the bake), and the classes recorded while tracing. The tvOS image is a relocatable object, relinked as `libmctvgame.dylib` with GraalVM's own libraries relabeled for tvOS (`machoplat.py`).
5. **App**. `mctv/` is built with `libmctvgame.dylib` in its Frameworks, and calls its `run_main` with Minecraft's own arguments.

| File | What it is |
|---|---|
| `aot.py` | The pipeline. Each stage skips work whose inputs haven't changed |
| `fixups.json` | Library quirks, with why for each |
| `reviewed.json` | Every site the analysis leaves, grouped, with why it's fine in the image |
| `chaos.py` | Seeded chaos runs, and what a run's log says about it |
| `config/common` | Metadata the trace can't see. Assets, probes, Fabric's Log4j handling |
| `config/traced` | What a traced run used, sorted so changes diff cleanly |
| `java/bake` | The bake, its analysis, its capture agent, and recording classes defined while playing |
| `java/runtime-common` | The vanilla main class, the screen sweep, and the JDK's MethodHandleProxies on Proxy for images |
| `java/runtime-fabric` | FlatFabric, its game provider and Mixin service, and its one substitution |
| `java/compat/<mod id>` | Code for one mod, built only with it. Sodium's vertex copier, which otherwise makes a class per pair of formats, and mods' screens for the sweep |
| `machoplat.py` | Relabels macOS objects for tvOS |
| `native/tvos_stubs.c` | What the Apple TV's compiler runtime lacks |

## Limits

- Mixin options, such as Sodium's mixin settings, are fixed when the game is baked. Mods' ordinary settings work as usual.
- A mod that generates classes while playing needs compat code (Sodium's is in `java/compat/sodium`). The audit stops on any such site until it's handled. `aot.py run --trace` can record generated classes instead, but only the ones that run saw, which isn't enough when they depend on order of use, as Sodium's did.
- The bake is reproducible. The image is a function of the bake and the config, but GraalVM doesn't promise identical bytes from build to build.
