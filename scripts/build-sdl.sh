#!/usr/bin/env bash
# SDL 3.4.14 (the version LWJGL 3.4.3 and Controlify use) for tvOS and its
# simulator, with MCTV's video backend (mctv/sdl) ahead of UIKit's.
#
#   scripts/build-sdl.sh
source "$(dirname "$0")/lib.sh"

TAG=release-3.4.14
COMMIT=147a8ee32dbf9ac02f3794964490687b6bbda1bc
SRC="$ROOT/deps/sdl3"
MINOS=26.0

[ -d "$SRC/.git" ] || git clone -q --depth 1 --branch "$TAG" https://github.com/libsdl-org/SDL.git "$SRC"
[ "$(git -C "$SRC" rev-parse HEAD)" = "$COMMIT" ] || die "$SRC isn't at $TAG ($COMMIT)"

# patches/sdl registers the backend ahead of UIKit's. Applied to clean copies so re-runs are safe.
git -C "$SRC" checkout -q -- src/video/SDL_video.c src/video/SDL_sysvideo.h
apply_patches "$SRC" "$ROOT/patches/sdl"
# SDL compiles everything in src/video/uikit for tvOS, so the backend goes there.
cp "$ROOT/mctv/sdl/SDL_mctvvideo.m" "$ROOT/mctv/sdl/mctv_sdl.h" "$SRC/src/video/uikit/"

for sdk in appletvos appletvsimulator; do
    work="$BUILD/sdl-build/$sdk"
    out="$BUILD/deps/sdl/$sdk"
    say "building SDL $TAG for $sdk"
    mkdir -p "$work"
    cmake -S "$SRC" -B "$work" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=tvOS -DCMAKE_OSX_SYSROOT="$sdk" -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MINOS" \
        -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST_LIBRARY=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF \
        -DSDL_INSTALL=OFF >"$work.log" 2>&1 || { tail -30 "$work.log"; die "SDL configure failed for $sdk"; }
    cmake --build "$work" --config Release -j "$(sysctl -n hw.ncpu)" >>"$work.log" 2>&1 \
        || { grep -E "error" "$work.log" | head -20; die "SDL build failed for $sdk"; }
    mkdir -p "$out"
    cp "$(cd "$work" && pwd -P)/$(readlink "$work/libSDL3.dylib" 2>/dev/null || echo libSDL3.dylib)" "$out/libSDL3.dylib"
    install_name_tool -id @rpath/libSDL3.dylib "$out/libSDL3.dylib"
    grep -a -q "SDL: MCTV video backend" "$out/libSDL3.dylib" || die "the MCTV backend isn't in the $sdk build"
done
say "SDL ready in build/deps/sdl"
