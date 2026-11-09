#!/usr/bin/env bash
# Builds the app for the tvOS simulator, pushes the game and first-run options,
# launches it and captures logs and screenshots.
#
#   scripts/mc-sim.sh                         Minecraft 26.3 with Fabric and the mods
#   scripts/mc-sim.sh --vanilla               without Fabric and the performance mods
#   scripts/mc-sim.sh --server 127.0.0.1      put a "Home" server in the multiplayer list
#   scripts/mc-sim.sh --wait 240 --every 30   watch for 240 s, a screenshot every 30 s
#   scripts/mc-sim.sh --version 1.21.11       the older "MCTV 1.21" app, in its own folders
#   scripts/mc-sim.sh --install-only          build and install, without stopping or launching anything
#   scripts/mc-sim.sh -- -showlog -xmx 1536   app arguments after --
#
# Logs and screenshots land in out/mc-sim-*.
source "$(dirname "$0")/lib.sh"

VERSION=26.3
WAIT=240
EVERY=30
FABRIC=1
INSTALL_ONLY=0
SERVER=
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="$2"; shift ;;
        --wait) WAIT="$2"; shift ;;
        --every) EVERY="$2"; shift ;;
        --vanilla) FABRIC=0 ;;
        --install-only) INSTALL_ONLY=1 ;;
        --server) SERVER="$2"; shift ;;
        --) shift; ARGS+=("$@"); break ;;
        *) die "unknown option $1 (pass app arguments after --)" ;;
    esac
    shift
done

mc_track "$VERSION"
BID=$MC_BUNDLE_ID
[ -d "$BUILD/runtime/appletvsimulator/java-25" ] || "$ROOT/scripts/prepare-runtime.sh"
if [ "$MC_NEXT" = 0 ]; then
    [ -d "$MC_NATIVES/appletvsimulator" ] || "$ROOT/scripts/prepare-natives.sh"
    [ "$MC_JAVA/libs/lwjgl.jar" -nt "$ROOT/scripts/patch-glfw-gamepad.py" ] || "$ROOT/scripts/build-java.sh"
    /usr/bin/python3 -I "$ROOT/scripts/fetch-minecraft.py" "$VERSION" "$MC_GAME"
else
    /usr/bin/python3 -I "$ROOT/scripts/fetch-minecraft.py" "$VERSION" "$MC_GAME" --lwjgl "$MC_JAVA/lwjgl"
fi
LAUNCH=$VERSION
if [ "$FABRIC" = 1 ]; then  # Fabric + Sodium and friends (scripts/fetch-fabric.py)
    LAUNCH=$(/usr/bin/python3 -I "$ROOT/scripts/fetch-fabric.py" "$VERSION" "$MC_GAME" | tee /dev/stderr | sed -n 's/^FABRIC_ID=//p')
    [ -n "$LAUNCH" ] || die "fetch-fabric.py failed"
    # Our rumble mod needs Controlify's GLFW driver, which 26.x's Controlify dropped.
    [ "$MC_NEXT" = 1 ] || "$ROOT/scripts/build-mod.sh" "$MC_GAME"
fi
if [ "$MC_NEXT" = 1 ]; then
    "$ROOT/scripts/prepare-26.sh"  # stops if a native build is missing
    case " ${ARGS[*]-} " in *" -graphics "*) ;; *) ARGS+=(-graphics vulkan) ;; esac
fi
UDID=$(ensure_sim)

ensure_art "$VERSION"
say "building MCTV (tvOS simulator, ad-hoc, no team)"
xcodegen generate --spec "$ROOT/mctv/project.yml" --quiet
xcodebuild -project "$ROOT/mctv/MCTV.xcodeproj" -scheme MCTV -sdk appletvsimulator \
    -configuration Debug -derivedDataPath "$MC_DERIVED" -quiet build \
    CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM= MCTV_BUNDLE_ID="$BID" MCTV_DISPLAY_NAME="$MC_DISPLAY" \
    MCTV_NATIVES_DIR="$MC_NATIVES" MCTV_JAVA_DIR="$MC_JAVA"
APP="$MC_DERIVED/Build/Products/Debug-appletvsimulator/MCTV.app"
xcrun simctl install "$UDID" "$APP"
if [ "$INSTALL_ONLY" = 1 ]; then
    say "installed \"$MC_DISPLAY\" ($BID), not launching it"
    exit 0
fi
# Only one Minecraft at a time. The 1.21.11 and 26.x apps are both MCTV.app.
for b in "$BUNDLE_PREFIX.app" "$BUNDLE_PREFIX.app26"; do
    xcrun simctl terminate "$UDID" "$b" >/dev/null 2>&1 || true
done

DATA="$(xcrun simctl get_app_container "$UDID" "$BID" data)/Library/Caches/mctv"
say "pushing Minecraft $LAUNCH"
mkdir -p "$DATA/minecraft" "$DATA/home"
rsync -a "$MC_GAME/" "$DATA/minecraft/"
echo "$LAUNCH" > "$DATA/minecraft/mctv-version.txt"
/usr/bin/python3 -I "$ROOT/scripts/mc-profile.py" --jar "$MC_GAME/versions/$VERSION/$VERSION.jar" \
    "$DATA/minecraft/options.txt"
[ -n "$SERVER" ] && /usr/bin/python3 -I "$ROOT/scripts/mc-profile.py" --servers-dat "$DATA/minecraft/servers.dat" "Home=$SERVER"
rm -f "$DATA/java.log" "$DATA/mctv.log" "$OUT"/mc-sim-*.png

out=$(xcrun simctl launch "$UDID" "$BID" ${ARGS[@]+"${ARGS[@]}"})
# Simulator apps are Mac processes, so watch the pid simctl printed.
APP_PID="${out##*: }"

say "running, watching for $WAIT s (screenshots every $EVERY s)"
FATAL='A fatal error has been detected|---- Minecraft Crash Report|Exception in thread "(main|Render thread)"'
shot=0
for i in $(seq 1 "$WAIT"); do
    sleep 1
    if ! kill -0 "$APP_PID" 2>/dev/null; then say "app exited after $i s"; break; fi
    if grep -qE "$FATAL" "$DATA/java.log" 2>/dev/null; then say "fatal error in java.log after $i s"; sleep 3; break; fi
    if [ $((i % EVERY)) = 0 ]; then
        shot=$((shot + 1))
        xcrun simctl io "$UDID" screenshot "$OUT/mc-sim-$shot.png" >/dev/null 2>&1 || true
    fi
done
xcrun simctl io "$UDID" screenshot "$OUT/mc-sim-last.png" >/dev/null 2>&1 || true
cp "$DATA/mctv.log" "$OUT/mc-sim-mctv.log" 2>/dev/null || true
cp "$DATA/java.log" "$OUT/mc-sim-java.log" 2>/dev/null || true
for f in "$DATA"/minecraft/crash-reports/*; do [ -f "$f" ] && cp "$f" "$OUT/"; done 2>/dev/null
echo; grep -v '^JLI_Launch' "$OUT/mc-sim-mctv.log" 2>/dev/null | tail -20 || true
echo; tail -40 "$OUT/mc-sim-java.log" 2>/dev/null || true
say "logs in out/mc-sim-java.log and out/mc-sim-mctv.log, screenshots in out/mc-sim-*.png"
