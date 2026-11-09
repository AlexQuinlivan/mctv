#!/usr/bin/env bash
# Builds the app with your team, installs it on the Apple TV and pushes the
# game, then launches it with JIT from this Mac and watches logs and screenshots.
#
#   scripts/mc-device.sh                    Minecraft 26.3 with Fabric and the mods, with music (~540 MB)
#   scripts/mc-device.sh --version 1.21.11  the older "MCTV 1.21" app, kept for rolling back
#   scripts/mc-device.sh --vanilla          without Fabric and the performance mods
#   scripts/mc-device.sh --jitd             launch without lldb. The app asks jitd on the
#                                           server for JIT (server/README.md)
#   scripts/mc-device.sh --build-only       build and sign only, without touching the TV
#   scripts/mc-device.sh --lite             leave out music and records (~180 MB), for quick test pushes
#   scripts/mc-device.sh --full             also push every language (~530 MB)
#   scripts/mc-device.sh --push-only        push the game files without building or relaunching.
#                                           The game picks them up the next time it starts
#   scripts/mc-device.sh --no-push          the game is already on the TV
#   scripts/mc-device.sh --wait 420 --every 30
#   scripts/mc-device.sh --trace "Game Memory"   also record an Instruments trace to out/mc-device.trace
#   scripts/mc-device.sh -- -showlog -xmx 900        app arguments after --
#
# Logs, screenshots and crash reports land in out/. JIT setup takes about 80 s
# before anything appears.
source "$(dirname "$0")/lib.sh"
load_signing
load_jit_config

VERSION=26.3
WAIT=420
EVERY=30
BUILD_ONLY=0
PUSH=1
PUSH_ONLY=0
ASSETS=
FABRIC=1
JITD=0
TRACE=
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="$2"; shift ;;
        --wait) WAIT="$2"; shift ;;
        --every) EVERY="$2"; shift ;;
        --build-only) BUILD_ONLY=1 ;;
        --no-push) PUSH=0 ;;
        --full) ASSETS=--full ;;
        --lite) ASSETS=--lite ;;
        --push-only) PUSH_ONLY=1 ;;
        --vanilla) FABRIC=0 ;;
        --jitd) JITD=1 ;;
        --trace) TRACE="$2"; shift ;;
        --) shift; ARGS+=("$@"); break ;;
        *) die "unknown option $1 (pass app arguments after --)" ;;
    esac
    shift
done

mc_track "$VERSION"
BID="$MC_BUNDLE_ID"
STAGE="$BUILD/stage-device"; [ "$MC_NEXT" = 0 ] || STAGE="$STAGE-26"
[ -d "$BUILD/runtime/appletvos/java-25" ] || "$ROOT/scripts/prepare-runtime.sh"
if [ "$MC_NEXT" = 0 ]; then
    [ -d "$MC_NATIVES/appletvos" ] || "$ROOT/scripts/prepare-natives.sh"
    [ "$MC_JAVA/libs/lwjgl.jar" -nt "$ROOT/scripts/patch-glfw-gamepad.py" ] || "$ROOT/scripts/build-java.sh"
else
    /usr/bin/python3 -I "$ROOT/scripts/fetch-minecraft.py" "$VERSION" "$MC_GAME" --lwjgl "$MC_JAVA/lwjgl" >/dev/null
    "$ROOT/scripts/prepare-26.sh"
    case " ${ARGS[*]-} " in *" -graphics "*) ;; *) ARGS+=(-graphics vulkan) ;; esac
fi

if [ "$BUILD_ONLY" = 1 ]; then
    DEST="generic/platform=tvOS"
else
    DEV=$(find_tv)
    UDID=$(tv_udid "$DEV")
    DEST="platform=tvOS,id=$UDID"
    say "Apple TV: $DEV (UDID $UDID)"
fi

if [ "$PUSH_ONLY" = 0 ]; then
ensure_art "$VERSION"
say "building MCTV for tvOS device (team $DEVELOPMENT_TEAM, bundle $BID)"
xcodegen generate --spec "$ROOT/mctv/project.yml" --quiet
xcodebuild -project "$ROOT/mctv/MCTV.xcodeproj" -scheme MCTV -sdk appletvos -destination "$DEST" \
    -configuration Debug -derivedDataPath "$MC_DERIVED" -quiet build \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" MCTV_BUNDLE_ID="$BID" \
    MCTV_DISPLAY_NAME="$MC_DISPLAY" MCTV_NATIVES_DIR="$MC_NATIVES" MCTV_JAVA_DIR="$MC_JAVA" \
    MCTV_JIT_SERVER="$JIT_SERVER" MCTV_JIT_TOKEN="$JIT_TOKEN"
APP="$MC_DERIVED/Build/Products/Debug-appletvos/MCTV.app"
verify_team "$APP"
CHECK="java/java-25/lib/server/libjvm.dylib Frameworks/libmobileglues.dylib Frameworks/libGLESv2.framework"
[ "$MC_NEXT" = 0 ] || CHECK="$CHECK Frameworks/libMoltenVK.dylib Frameworks/libSDL3.dylib Frameworks/libSDL3_controlify.dylib"
for lib in $CHECK; do
    t=$(codesign -dv "$APP/$lib" 2>&1 | sed -n 's/^TeamIdentifier=//p')
    [ "$t" = "$DEVELOPMENT_TEAM" ] || die "$lib is signed by '$t', not $DEVELOPMENT_TEAM"
done
say "app: $(du -sh "$APP" | cut -f1), every library signed by $DEVELOPMENT_TEAM"
fi
/usr/bin/python3 -I "$ROOT/scripts/fetch-minecraft.py" "$VERSION" "$MC_GAME"
LAUNCH=$VERSION
if [ "$FABRIC" = 1 ]; then  # Fabric + Sodium and friends (scripts/fetch-fabric.py)
    LAUNCH=$(/usr/bin/python3 -I "$ROOT/scripts/fetch-fabric.py" "$VERSION" "$MC_GAME" | tee /dev/stderr | sed -n 's/^FABRIC_ID=//p')
    [ -n "$LAUNCH" ] || die "fetch-fabric.py failed"
    # Our rumble mod needs Controlify's GLFW driver, which 26.x's Controlify dropped.
    [ "$MC_NEXT" = 1 ] || "$ROOT/scripts/build-mod.sh" "$MC_GAME"
fi
/usr/bin/python3 -I "$ROOT/scripts/mc-stage.py" "$MC_GAME" "$VERSION" "$STAGE" $ASSETS --launch "$LAUNCH"
if [ "$BUILD_ONLY" = 1 ]; then
    say "build only, not touching the TV"
    exit 0
fi

if [ "$PUSH_ONLY" = 0 ]; then
    say "installing"
    xcrun devicectl device install app --device "$DEV" "$APP" >/dev/null
fi

remote_ls() {  # <dir under the app's data container>
    xcrun devicectl device info files --device "$DEV" --domain-type appDataContainer \
        --domain-identifier "$BID" --subdirectory "$1" 2>/dev/null
}
if [ "$PUSH" = 1 ]; then
    # Options only on the first push, so settings changed in the game survive.
    rm -f "$STAGE/minecraft/options.txt"
    mkdir -p "$STAGE/home"
    [ -f "$STAGE/.options-pushed" ] || /usr/bin/python3 -I "$ROOT/scripts/mc-profile.py" \
        --jar "$MC_GAME/versions/$VERSION/$VERSION.jar" "$STAGE/minecraft/options.txt"
    # The server list too, once, so servers added in the game survive.
    rm -f "$STAGE/minecraft/servers.dat"
    [ -f "$STAGE/.servers-pushed" ] || [ -z "${MC_SERVER:-}" ] || /usr/bin/python3 -I "$ROOT/scripts/mc-profile.py" \
        --servers-dat "$STAGE/minecraft/servers.dat" "Home=$MC_SERVER"
    say "pushing $(du -sh "$STAGE" | cut -f1) to Library/Caches/mctv (unchanged files are skipped)"
    t0=$(date +%s)
    for part in minecraft home; do
        xcrun devicectl device copy to --device "$DEV" --domain-type appDataContainer --domain-identifier "$BID" \
            --source "$STAGE/$part" --destination "Library/Caches/mctv/$part" >/dev/null
    done
    say "pushed in $(( $(date +%s) - t0 )) s"
    remote_ls "Library/Caches/mctv/minecraft/versions/$LAUNCH" | grep -q "$LAUNCH.json" || {
        remote_ls "Library/Caches/mctv" | head -40
        die "the push didn't land at Library/Caches/mctv/minecraft/versions/$LAUNCH (listing above)"
    }
    [ -f "$STAGE/minecraft/options.txt" ] && touch "$STAGE/.options-pushed"
    [ -f "$STAGE/minecraft/servers.dat" ] && touch "$STAGE/.servers-pushed"
fi
if [ "$PUSH_ONLY" = 1 ]; then
    say "pushed only. The game picks up the new files the next time it starts"
    exit 0
fi

fetch() {  # <file under Library/Caches/mctv> <local name>
    xcrun devicectl device copy from --device "$DEV" --domain-type appDataContainer --domain-identifier "$BID" \
        --source "Library/Caches/mctv/$1" --destination "$OUT/$2" >/dev/null 2>&1
}
rm -f "$OUT"/mc-device-*.png "$OUT/mc-device-java.log" "$OUT/mc-device-mctv.log"
if [ "$JITD" = 1 ]; then
    xcrun devicectl device process launch --device "$DEV" --terminate-existing \
        --json-output "$OUT/launch.json" "$BID" -- ${ARGS[@]+"${ARGS[@]}"} >/dev/null
    pid=$(/usr/bin/python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["result"]["process"]["processIdentifier"])' "$OUT/launch.json")
    say "launched pid $pid, which asks $JIT_SERVER for JIT"
else
    xcrun devicectl device process launch --device "$DEV" --start-stopped --terminate-existing \
        --json-output "$OUT/launch.json" "$BID" -- ${ARGS[@]+"${ARGS[@]}"} >/dev/null
    pid=$(/usr/bin/python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["result"]["process"]["processIdentifier"])' "$OUT/launch.json")
    say "launched pid $pid stopped, attaching lldb over the network (JIT preparation takes ~80 s)"
    lldb_jit26 device "$DEV" "$pid" || say "lldb returned an error (see above). Watching anyway"
fi
if [ -n "$TRACE" ]; then
    rm -rf "$OUT/mc-device.trace"
    say "recording an Instruments trace ($TRACE) of pid $pid for $WAIT s to out/mc-device.trace"
    xcrun xctrace record --device "$UDID" --attach MCTV --template "$TRACE" --time-limit "${WAIT}s" \
        --output "$OUT/mc-device.trace" > "$OUT/mc-device-trace.log" 2>&1 &
fi

alive() {
    xcrun devicectl device info processes --device "$DEV" --json-output "$OUT/procs.json" >/dev/null 2>&1 || return 0
    /usr/bin/python3 -I -c 'import json,sys; ps=json.load(open(sys.argv[1]))["result"]["runningProcesses"]; sys.exit(0 if any(p.get("processIdentifier")==int(sys.argv[2]) for p in ps) else 1)' "$OUT/procs.json" "$pid"
}
say "watching for $WAIT s (logs every 10 s, screenshot every $EVERY s)"
FATAL='A fatal error has been detected|---- Minecraft Crash Report|Exception in thread "(main|Render thread)"'
shot=0
for i in $(seq 10 10 "$WAIT"); do
    sleep 10
    fetch java.log mc-device-java.log || true
    if grep -qE "$FATAL" "$OUT/mc-device-java.log" 2>/dev/null; then say "fatal error in java.log after $i s"; break; fi
    if ! alive; then say "app exited after $i s"; break; fi
    if [ $((i % EVERY)) = 0 ]; then
        shot=$((shot + 1))
        xcrun devicectl device capture screenshot --device "$DEV" --destination "$OUT/mc-device-$shot.png" >/dev/null 2>&1 || true
    fi
done
xcrun devicectl device capture screenshot --device "$DEV" --destination "$OUT/mc-device-last.png" >/dev/null 2>&1 || true
fetch java.log mc-device-java.log || true
fetch mctv.log mc-device-mctv.log || true
xcrun devicectl device copy from --device "$DEV" --domain-type appDataContainer --domain-identifier "$BID" \
    --source Library/Caches/mctv/minecraft/crash-reports --destination "$OUT/crash-reports-device" >/dev/null 2>&1 || true
echo; grep -v '^JLI_Launch' "$OUT/mc-device-mctv.log" 2>/dev/null | tail -25 || true
echo; tail -30 "$OUT/mc-device-java.log" 2>/dev/null || true
if [ -n "$TRACE" ]; then
    say "waiting for Instruments to finish the trace"
    wait
    tail -3 "$OUT/mc-device-trace.log"
fi
say "logs in out/mc-device-*.log, screenshots in out/mc-device-*.png, crash logs with scripts/device-crashlogs.sh MCTV"
