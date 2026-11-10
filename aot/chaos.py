"""Seeded chaos for the native image (aot.py chaos). The same seed gives the
same run, so a failure can be replayed.

The world side is a timeline of server console commands for a local test
server, all aimed at @a, so they need no player name: hops between
dimensions, structures placed beside the player, mob waves, explosions,
particles, effects, items, blocks, weather, time and game modes. The player
side is a script for the app's input test (mctv/Sources/MCInput.m), through
Minecraft's own keyboard and mouse: looking, attacking, the hotbar, the
inventory, chat and commands, F1 to F5, the pause menu and advancements.
Controlify reads the controller itself, so a script can't drive it.

assess() reads what a run left behind and says how it went.
"""
import random
import os
import re
import statistics

MOBS = ("zombie skeleton creeper spider enderman witch slime villager iron_golem horse wolf cat fox bee "
        "parrot axolotl frog goat allay sniffer camel armadillo breeze bogged armor_stand boat minecart").split()
NETHER_MOBS = "blaze ghast piglin hoglin strider wither_skeleton magma_cube zombified_piglin".split()
END_MOBS = "enderman shulker endermite".split()
STRUCTURES = {
    "overworld": ("village_plains village_desert village_taiga desert_pyramid jungle_pyramid igloo swamp_hut "
                  "pillager_outpost shipwreck ruined_portal trail_ruins trial_chambers").split(),
    "the_nether": "bastion_remnant fortress nether_fossil ruined_portal_nether".split(),
    "the_end": ["end_city"],
}
PARTICLES = ("flame smoke large_smoke heart crit enchanted_hit enchant portal explosion cloud end_rod "
             "totem_of_undying cherry_leaves snowflake soul_fire_flame glow note bubble happy_villager "
             "angry_villager campfire_cosy_smoke dragon_breath witch firework sonic_boom sculk_soul "
             "electric_spark wax_on scrape gust infested item_slime splash dripping_lava ash warped_spore "
             "spore_blossom_air composter squid_ink glow_squid_ink dolphin egg_crack poof dust_plume").split()
EFFECTS = ("speed slowness haste jump_boost nausea regeneration fire_resistance invisibility blindness "
           "night_vision darkness glowing levitation slow_falling conduit_power wither poison absorption "
           "dolphins_grace weaving oozing").split()
ITEMS = ("diamond_sword netherite_pickaxe bow crossbow trident shield map spyglass compass recovery_compass "
         "clock elytra totem_of_undying firework_rocket writable_book ender_pearl snowball potion splash_potion "
         "experience_bottle fishing_rod bundle brush mace wind_charge goat_horn player_head white_banner "
         "diamond_helmet carved_pumpkin torch lantern water_bucket lava_bucket flint_and_steel tnt saddle "
         "name_tag lead").split()
BLOCKS = ("glass red_stained_glass water lava oak_leaves cherry_leaves sea_lantern glowstone beacon chest "
          "ender_chest campfire redstone_lamp slime_block honey_block ice snow_block sculk_sensor spawner "
          "end_gateway conduit enchanting_table lectern bell decorated_pot shulker_box scaffolding cobweb "
          "moss_block amethyst_cluster copper_bulb crafter trial_spawner vault heavy_core").split()

# Set up once the player is in. Game rules have had two spellings, so both.
SETUP = ["gamerule doImmediateRespawn true", "gamerule immediate_respawn true", "gamerule keepInventory true",
         "gamerule keep_inventory true", "difficulty normal", "gamemode creative @a"]


def server_timeline(seed, seconds):
    """[(seconds after the player joins, console command)]."""
    r = random.Random("server-%s" % seed)
    out = [(1, c) for c in SETUP]
    t, dim = 5.0, "overworld"
    while t < seconds:
        kind = r.choices(["hop", "structure", "mobs", "particles", "effect", "item", "blocks", "weather",
                          "time", "gamemode", "boom", "ride", "text", "clean"],
                         [6, 4, 6, 6, 4, 5, 4, 2, 2, 2, 2, 2, 2, 2])[0]
        cmds, pause = [], r.uniform(2, 6)
        if kind == "hop":
            dim = r.choices(["overworld", "the_nether", "the_end"], [6, 3, 1])[0]
            if dim == "overworld":
                cmds.append("execute in minecraft:overworld run spreadplayers %d %d 0 1 false @a"
                            % (r.randint(-20000, 20000), r.randint(-20000, 20000)))
            elif dim == "the_nether":
                cmds.append("execute in minecraft:the_nether run spreadplayers %d %d 0 1 under 110 false @a"
                            % (r.randint(-3000, 3000), r.randint(-3000, 3000)))
            else:
                cmds.append("execute in minecraft:the_end run spreadplayers 0 0 0 60 false @a")
            pause = r.uniform(10, 20)  # a new dimension or far chunks take loading
        elif kind == "structure":
            cmds.append("execute at @a run place structure minecraft:%s ~24 ~ ~24" % r.choice(STRUCTURES[dim]))
            pause = r.uniform(6, 12)
        elif kind == "mobs":
            pool = MOBS if dim == "overworld" else NETHER_MOBS if dim == "the_nether" else END_MOBS
            for _ in range(r.randint(2, 8)):
                cmds.append("execute at @a run summon minecraft:%s ~%d ~1 ~%d" % (r.choice(pool), r.randint(-8, 8), r.randint(-8, 8)))
        elif kind == "particles":
            cmds.append("execute at @a run particle minecraft:%s ~ ~1 ~ 3 2 3 0.05 %d force"
                        % (r.choice(PARTICLES), r.randint(50, 400)))
        elif kind == "effect":
            cmds.append("effect give @a minecraft:%s %d 1 true" % (r.choice(EFFECTS), r.randint(5, 30))
                        if r.random() < 0.8 else "effect clear @a")
        elif kind == "item":
            item = r.choice(ITEMS)
            cmds.append("item replace entity @a weapon.mainhand with minecraft:%s" % item if r.random() < 0.5
                        else "give @a minecraft:%s %d" % (item, r.randint(1, 16)))
        elif kind == "blocks":
            cmds.append("execute at @a run fill ~3 ~-1 ~3 ~7 ~3 ~7 minecraft:%s" % r.choice(BLOCKS))
        elif kind == "weather":
            cmds.append("weather %s 600" % r.choice(["clear", "rain", "thunder"]))
        elif kind == "time":
            cmds.append("time set %s" % r.choice(["day", "noon", "sunset", "night", "midnight", "sunrise"]))
        elif kind == "gamemode":
            cmds.append("gamemode %s @a" % r.choices(["creative", "survival", "spectator", "adventure"], [5, 3, 1, 1])[0])
        elif kind == "boom":
            cmds.append(r.choice(["execute at @a run summon minecraft:tnt ~5 ~1 ~5 {fuse:30}",
                                  "execute at @a run summon minecraft:lightning_bolt ~6 ~ ~6",
                                  "execute at @a run summon minecraft:wind_charge ~2 ~2 ~2"]))
        elif kind == "ride":
            mount = r.choice(["horse", "pig", "boat", "minecart", "camel", "strider" if dim == "the_nether" else "horse"])
            cmds += ["execute at @a run summon minecraft:%s ~1 ~ ~1 {Tags:[\"chaos\"]}" % mount,
                     "execute as @a run ride @s mount @e[tag=chaos,limit=1,sort=nearest]"]
            pause = r.uniform(5, 10)
        elif kind == "text":
            n = r.randint(1, 9999)
            cmds.append(r.choice(["title @a title {\"text\":\"chaos %d\",\"color\":\"gold\"}" % n,
                                  "say chaos %d" % n, "xp add @a %d levels" % r.randint(1, 30)]))
        elif kind == "clean":
            cmds += ["execute as @a run ride @s dismount", "kill @e[type=!minecraft:player]", "save-all"]
        out += [(round(t, 1), c) for c in cmds]
        t += pause
    return out


# HID usage codes for Minecraft's default keys
KEYS = {"inventory": 0x08, "chat": 0x17, "command": 0x38, "enter": 0x28, "escape": 0x29, "f1": 0x3a, "f2": 0x3b,
        "f3": 0x3c, "f5": 0x3e, "jump": 0x2c, "sneak": 0xe1, "sprint": 0xe0, "drop": 0x14, "swap": 0x09,
        "tab": 0x2b, "advancements": 0x0f}


def input_script(seed, seconds):
    """A script for the app's -inputtest, played from the first frame, with
    input for all of seconds. A minute without any and the game caps itself at
    30 fps (FramerateLimitTracker, the inactivity limit), which isn't a dip."""
    r = random.Random("input-%s" % seed)
    steps, t = ["frame", "wait 25"], 0.0  # in the world by then
    while t < seconds:
        kind = r.choices(["look", "attack", "use", "hotbar", "inventory", "chat", "command", "fkey", "pause",
                          "move", "drop", "advancements"], [8, 4, 3, 4, 2, 2, 2, 3, 1, 3, 1, 1])[0]
        wait = r.uniform(0.5, 3)
        if kind == "look":
            steps.append("pointer %d %d" % (r.randint(100, 1820), r.randint(100, 980)))
        elif kind == "attack":
            steps.append("click")
        elif kind == "use":
            steps.append("click right")
        elif kind == "hotbar":
            steps.append("key %d" % (0x1e + r.randint(0, 8)))
        elif kind == "inventory":
            steps += ["key %d" % KEYS["inventory"], "wait %.1f" % r.uniform(1, 3), "key %d" % KEYS["escape"]]
        elif kind == "chat":
            steps += ["key %d" % KEYS["chat"], "wait 0.5", "type chaos %d" % r.randint(1, 999), "key %d" % KEYS["enter"]]
        elif kind == "command":
            steps += ["key %d" % KEYS["command"], "wait 0.5", "type %s" % r.choice(["help", "seed", "me waves", "list"]),
                      "wait 0.5", "key %d" % KEYS["enter"]]
        elif kind == "fkey":
            steps.append("key %d" % KEYS[r.choice(["f1", "f2", "f3", "f5"])])
        elif kind == "pause":
            steps += ["key %d" % KEYS["escape"], "wait %.1f" % r.uniform(1, 3), "key %d" % KEYS["escape"]]
        elif kind == "move":
            steps.append("key %d" % KEYS[r.choice(["jump", "sneak", "sprint", "swap", "tab"])])
        elif kind == "drop":
            steps.append("key %d" % KEYS["drop"])
        elif kind == "advancements":
            steps += ["key %d" % KEYS["advancements"], "wait %.1f" % r.uniform(1, 3), "key %d" % KEYS["escape"]]
        steps.append("wait %.1f" % wait)
        t = sum(float(s.split()[1]) for s in steps if s.startswith("wait "))
    return "; ".join(steps)


BENIGN = re.compile(r"user properties|Realms|realms|narrator|401|NSObject|SDLNativesLoader|SteamDeck|loadFromNatives"
                    r"|codename|Log4J2|window icon|post effect|system info|retrieving info")


def assess(java_log, mctv_log, server_log, seconds):
    """What a chaos run left behind, as a dict for report.json."""
    def read(path):  # a log the run never wrote (the app stopped before Java started) reads as empty
        return open(path, errors="replace").read() if path and os.path.exists(path) else ""
    java, mctv, server = read(java_log), read(mctv_log), read(server_log)
    report = {}
    if not java:
        report["no_java_log"] = True
    report["app_failed"] = sorted(set(re.findall(r"\[FAILED\] (.+)", mctv)))  # the app's own reasons for stopping
    # the screen sweep (mctv.aot.Sweep, -Dmctv.sweep): each settings screen, the game's and the mods'
    sweep = re.findall(r"\[sweep\] (.+?): (opened|FAILED)", java)
    report["screens"] = {"opened": len([n for n, r in sweep if r == "opened"]),
                         "failed": sorted({n for n, r in sweep if r == "FAILED"}),
                         "finished": "[sweep] done:" in java} if "[sweep]" in java else None
    report["crashed"] = bool(re.search(r"---- Minecraft Crash Report|Fatal error|Exception in thread \"(main|Render thread)\"", java))
    report["joined"] = len(re.findall(r"joined the game", server))
    report["disconnects"] = sorted(set(re.findall(r"lost connection: (.+)", server)))
    report["commands_failed"] = sorted(set(m.strip() for m in re.findall(
        r"(Unknown or incomplete command.*|Incorrect argument.*|No entity was found|Unknown game rule.*)", server)))[:20]
    report["missing_registrations"] = sorted(set(re.findall(r"Missing(?:Reflection|JNI|Foreign)\w*Error: .*?'([^']+)'", java)))
    # Probes, which find nothing on a desktop either: Log4j's config names, LWJGL's natives (the app's
    # Frameworks), Netty's native transports and JNA's library, which tvOS hasn't got
    report["missing_resources"] = sorted(set(r for r in re.findall(r"MissingResourceRegistrationError: .*?'([^']+)'", java)
                                             if not re.match(r"/?(log4j2|lib|META-INF/native|com/sun/jna)", r)))
    report["undefined_classes"] = sorted(set(re.findall(r"Tried to define class:\s+(\S+)", java)))
    heads = [l.strip() for l in java.splitlines() if re.match(r"^\S*(Exception|Error)\b.*:", l.strip())
             and not BENIGN.search(l) and "RegistrationError" not in l]
    report["errors"] = sorted(set(h[:200] for h in heads))[:30]
    # The app's 10 s samples. The first is the game starting (its first frames, shaders, resources), so apart.
    # With each, the render thread's CPU time a frame and the app's CPU use (% of one core), which
    # tell builds apart when both hold 60 fps.
    samples = re.findall(r"frames: ([\d.]+) fps, slowest (\d+) ms(?:, render thread ([\d.]+) ms a frame, cpu (\d+)%)?", mctv)
    fps, slow = [float(s[0]) for s in samples[1:]], [int(s[1]) for s in samples[1:]]
    render, cpu = [float(s[2]) for s in samples[1:] if s[2]], [int(s[3]) for s in samples[1:] if s[3]]
    report["fps"] = {"samples": len(fps), "median": statistics.median(fps) if fps else None,
                     "lowest": min(fps) if fps else None, "slowest_frame_ms": max(slow) if slow else None,
                     "starting_slowest_ms": int(samples[0][1]) if samples else None,
                     "render_thread_ms": round(statistics.median(render), 2) if render else None,
                     "cpu_percent": round(statistics.median(cpu)) if cpu else None}
    # -XX:+PrintGC's pauses. Serial: "GC(4) Pause Incremental GC (Collect on allocation) 50.51M->5.26M 4.794ms".
    # G1: "GC(3) Pause Young (Normal) (G1 Evacuation Pause) 70M->22M(104M) 1.126ms", and Remark, Cleanup and Full,
    # with its marking concurrent and so not a pause.
    gcs = [(kind, float(ms)) for kind, ms in re.findall(r"GC\(\d+\) Pause (Incremental|Full) GC \([^)]*\) \S+ ([\d.]+)ms", java)]
    gcs += [(kind, float(ms)) for kind, ms in re.findall(r"GC\(\d+\) Pause (Young|Remark|Cleanup|Full)(?! GC).*? ([\d.]+)ms$", java, re.M)]
    full = [ms for kind, ms in gcs if kind == "Full"]
    report["gc"] = {"collections": len(gcs), "full": len(full),
                    "longest_ms": round(max(ms for _, ms in gcs)) if gcs else None,
                    "longest_full_ms": round(max(full)) if full else None,
                    "total_ms": round(sum(ms for _, ms in gcs)) if gcs else None}
    mem = [int(m) for m in re.findall(r"memory: (\d+) MB in use", mctv)]
    report["memory_mb"] = {"peak": max(mem) if mem else None, "first": mem[0] if mem else None, "last": mem[-1] if mem else None}
    # What the server did, from its command feedback, so a pass can't be a quiet run
    kinds = {"hops": r"Spread \d+ entit", "hop failures": r"Could not spread", "structures": r"Generated structure",
             "summons": r"Summoned new", "particles": r"Displaying particle", "fills": r"Successfully filled",
             "items": r"Replaced a slot|Gave \d+", "effects": r"Applied effect", "game modes": r"game mode",
             "cleanups": r"Killed \d+"}
    report["activity"] = {k: len(re.findall(v, server)) for k, v in kinds.items()}
    report["passed"] = (not report["crashed"] and not report["app_failed"] and report["joined"] > 0 and not report["missing_registrations"]
                        and (report["screens"] is None or report["screens"]["finished"] and not report["screens"]["failed"])
                        and not report["undefined_classes"] and report["activity"]["hops"] > 0)
    return report
