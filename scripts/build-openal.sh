#!/usr/bin/env bash
# OpenAL Soft, Minecraft's sound, for tvOS and its simulator.
#
#   scripts/build-openal.sh
source "$(dirname "$0")/lib.sh"

TAG=1.25.2
COMMIT=b2c48f7718ef3fcf67921a8b6534c4914e328970
SRC="$ROOT/deps/openal-soft"
MINOS=26.0

[ -d "$SRC/.git" ] || git clone -q --depth 1 --branch "$TAG" https://github.com/kcat/openal-soft.git "$SRC"
[ "$(git -C "$SRC" rev-parse HEAD)" = "$COMMIT" ] || die "$SRC isn't at $TAG ($COMMIT)"

for sdk in appletvos appletvsimulator; do
    work="$BUILD/openal-build/$sdk"
    out="$BUILD/deps/openal/$sdk"
    say "building OpenAL Soft $TAG for $sdk"
    mkdir -p "$work"
    cmake -S "$SRC" -B "$work" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=tvOS -DCMAKE_OSX_SYSROOT="$sdk" -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MINOS" \
        -DLIBTYPE=SHARED -DALSOFT_UTILS=OFF -DALSOFT_EXAMPLES=OFF -DALSOFT_TESTS=OFF -DALSOFT_INSTALL=OFF \
        -DALSOFT_BACKEND_COREAUDIO=ON -DALSOFT_REQUIRE_COREAUDIO=ON \
        `# Its real-time safety check fails on the tvOS 27 SDK's render callback type` \
        -DHAVE_WFUNCTION_EFFECTS=OFF >"$work.log" 2>&1 \
        || { tail -30 "$work.log"; die "OpenAL Soft configure failed for $sdk"; }
    cmake --build "$work" --config Release -j "$(sysctl -n hw.ncpu)" >>"$work.log" 2>&1 \
        || { grep -E "error" "$work.log" | head -20; die "OpenAL Soft build failed for $sdk"; }
    mkdir -p "$out"
    lib=$(find "$work" -maxdepth 1 -name 'libopenal*.dylib' -type f | head -1)
    [ -n "$lib" ] || die "no libopenal.dylib in $work"
    cp "$lib" "$out/libopenal.dylib"
    install_name_tool -id @rpath/libopenal.dylib "$out/libopenal.dylib"
done
say "OpenAL Soft ready in build/deps/openal"
