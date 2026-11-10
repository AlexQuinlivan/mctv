#!/usr/bin/env bash
# MoltenVK 1.4.2, the version Mojang ships on macOS, as a dylib for tvOS
# and the simulator. Upstream only builds a static library for tvOS.
#
#   scripts/build-moltenvk.sh [--force]
source "$(dirname "$0")/lib.sh"

TAG=v1.4.2
COMMIT=db66022459ffb663aa2b50f6b018bc2e124f5edf
MINOS=26.0
W="$ROOT/deps/moltenvk"
SRC="$W/src"
DD="$W/DerivedData"
DST="$BUILD/deps/moltenvk"
LOG="$DST/build.log"
DEPS_STAMP="$TAG, $(xcodebuild -version | tr '\n' ' ')"
STAMP="$DEPS_STAMP tvOS $MINOS, patches $(cat "$ROOT"/patches/moltenvk/*.patch | shasum | cut -c1-12)"

[ "${1:-}" = --force ] && rm -f "$DST/.stamp" "$W/.deps-stamp"
if [ "$(cat "$DST/.stamp" 2>/dev/null)" = "$STAMP" ] \
    && [ -f "$DST/appletvos/libMoltenVK.dylib" ] && [ -f "$DST/appletvsimulator/libMoltenVK.dylib" ]; then
    say "MoltenVK $TAG is up to date in build/deps/moltenvk (--force rebuilds)"
    exit 0
fi

# Upstream pipes through xcpretty when it finds one, and a broken shim fails the
# build, so use a plain PATH.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
# Applies to every xcodebuild below, including the ones fetchDependencies runs.
# The projects default to tvOS 15.0 and add x86_64 to the simulator.
mkdir -p "$W" "$DST"
cat > "$W/tvos.xcconfig" <<EOF
TVOS_DEPLOYMENT_TARGET = $MINOS
ARCHS = arm64
CODE_SIGNING_ALLOWED = NO
EOF
export XCODE_XCCONFIG_FILE="$W/tvos.xcconfig"
: > "$LOG"

if [ ! -d "$SRC/.git" ]; then
    say "cloning MoltenVK $TAG"
    git clone -q -c advice.detachedHead=false --depth 1 --branch "$TAG" \
        https://github.com/KhronosGroup/MoltenVK.git "$SRC"
elif [ "$(git -C "$SRC" describe --tags --exact-match 2>/dev/null)" != "$TAG" ]; then
    say "moving deps/moltenvk/src to $TAG"
    git -C "$SRC" fetch -q --depth 1 origin tag "$TAG"
    git -C "$SRC" checkout -q --force "$TAG"
fi
[ "$(git -C "$SRC" rev-parse HEAD)" = "$COMMIT" ] || die "deps/moltenvk/src isn't at $TAG ($COMMIT)"

# The simulator reports a lower Metal GPU family than any Apple TV, so MoltenVK
# turns off indirect drawing with a base instance, which Minecraft needs.
# The Mac GPU behind the simulator has it, so turn it back on.
MVK="$SRC/MoltenVK/MoltenVK/GPUObjects/MVKDevice.mm"
# patches/moltenvk has two simulator fixes, and the memory stats the app logs.
apply_patches "$SRC" "$ROOT/patches/moltenvk"

# SPIRV-Cross, SPIRV-Tools and friends at the revisions this tag pins.
if [ "$(cat "$W/.deps-stamp" 2>/dev/null)" != "$DEPS_STAMP" ]; then
    say "fetching and building MoltenVK's dependencies (log: ${LOG#"$ROOT"/})"
    (cd "$SRC" && ./fetchDependencies --tvos --tvossim) >>"$LOG" 2>&1 \
        || die "fetchDependencies failed, see $LOG"
    rm -rf "$DD"
    echo "$DEPS_STAMP" > "$W/.deps-stamp"
fi

for sdk in appletvos appletvsimulator; do
    case $sdk in
        appletvos) dest="tvOS"; triple="arm64-apple-tvos$MINOS" ;;
        appletvsimulator) dest="tvOS Simulator"; triple="arm64-apple-tvos$MINOS-simulator" ;;
    esac
    say "building MoltenVK $TAG for $dest"
    (cd "$SRC" && xcodebuild build -quiet -project MoltenVKPackaging.xcodeproj \
        -scheme "MoltenVK Package (tvOS only)" -destination "generic/platform=$dest" \
        -configuration Release -derivedDataPath "$DD") >>"$LOG" 2>&1 \
        || die "MoltenVK build for $dest failed, see $LOG"
    lib="$DD/Build/Products/Release-$sdk/libMoltenVK.a"
    [ -f "$lib" ] || die "no $lib"

    # The frameworks MoltenVK's own tvOS framework target links.
    out="$DST/$sdk/libMoltenVK.dylib"
    mkdir -p "$DST/$sdk"
    rm -f "$out"
    xcrun --sdk "$sdk" clang++ -target "$triple" -dynamiclib \
        -install_name @rpath/libMoltenVK.dylib \
        -compatibility_version 1.0.0 -current_version "${TAG#v}" \
        -Wl,-force_load,"$lib" \
        -framework Metal -framework IOSurface -framework QuartzCore \
        -framework CoreGraphics -framework UIKit -framework Foundation \
        -o "$out" >>"$LOG" 2>&1 || die "linking $out failed, see $LOG"

    nm -gU "$out" | grep -q ' _vkGetInstanceProcAddr$' || die "$out doesn't export vkGetInstanceProcAddr"
    say "  ${out#"$ROOT"/} ($(du -h "$out" | cut -f1 | tr -d ' '))"
done

echo "$STAMP" > "$DST/.stamp"
say "MoltenVK ready in build/deps/moltenvk"
