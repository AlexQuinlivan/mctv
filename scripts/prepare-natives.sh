#!/usr/bin/env bash
# Assembles the native libraries the app embeds, in build/natives/<sdk>, from
# what the build-*.sh scripts made in build/deps: LWJGL, FreeType, shaderc,
# SPIRV-Cross, SDL, MoltenVK and OpenAL Soft.
#
#   scripts/prepare-natives.sh
source "$(dirname "$0")/lib.sh"

D="$BUILD/deps"
missing=()
for need in lwjgl/appletvos/liblwjgl.dylib thirdparty/appletvos/libshaderc.dylib sdl/appletvos/libSDL3.dylib \
            moltenvk/appletvos/libMoltenVK.dylib openal/appletvos/libopenal.dylib; do
    [ -f "$D/$need" ] || missing+=("$need")
done
if [ ${#missing[@]} -gt 0 ]; then
    die "missing ${missing[*]} under build/deps. Run scripts/setup.sh"
fi

for sdk in appletvos appletvsimulator; do
    out="$BUILD/natives/$sdk"
    rm -rf "$out"
    mkdir -p "$out"
    for part in lwjgl thirdparty sdl moltenvk openal; do
        cp "$D/$part/$sdk"/*.dylib "$out/"
    done
    # Controlify gets its own SDL, as on desktop. It drains its SDL's event queue,
    # which would eat Minecraft's mouse and keys if they shared one.
    cp "$out/libSDL3.dylib" "$out/libSDL3_controlify.dylib"
    install_name_tool -id @rpath/libSDL3_controlify.dylib "$out/libSDL3_controlify.dylib" 2>/dev/null
    codesign -f -s - "$out/libSDL3_controlify.dylib" 2>/dev/null  # the app build signs it properly
    say "natives for $sdk: $(ls "$out" | tr '\n' ' ')"
done
