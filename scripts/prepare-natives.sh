#!/usr/bin/env bash
# Minecraft 1.21.11's native libraries (LWJGL 3.3.3, OpenAL, MobileGlues, ANGLE
# and others), taken from Amethyst's iOS build and relabelled for tvOS and the
# simulator into build/natives/<sdk>.
source "$(dirname "$0")/lib.sh"

IPA="$ROOT/deps/amethyst-ipa/extracted/Payload/AngelAuraAmethyst.app"
[ -d "$IPA" ] || "$ROOT/scripts/prepare-runtime.sh"
MINOS=26.0
SDK=27.2

LIBS="liblwjgl.dylib liblwjgl_opengl.dylib liblwjgl_stb.dylib liblwjgl_tinyfd.dylib
      libfreetype.dylib libopenal.dylib libmobileglues.dylib libspirv-cross-c-shared.0.dylib
      libtinygl4angle.dylib libAmethystAccountJNI.dylib libEGL.framework libGLESv2.framework"

for target in appletvsimulator:8 appletvos:3; do
    name="${target%%:*}"
    plat="${target##*:}"
    dst="$BUILD/natives/$name"
    say "relabelling natives for $name (platform $plat)"
    rm -rf "$dst"
    mkdir -p "$dst"
    for l in $LIBS; do
        ditto "$IPA/Frameworks/$l" "$dst/$l"
    done
    if [ "$plat" = 8 ]; then
        # This ANGLE is the iOS device build. It only offers GLES 3 on Apple GPU
        # family 3 and up, which the simulator doesn't report, and MobileGlues
        # needs GLES 3. Patch it to return 3.0 as ANGLE's simulator builds do.
        /usr/bin/python3 -I - "$dst/libGLESv2.framework/libGLESv2" <<'PY' || die "ANGLE simulator patch failed"
import subprocess, sys
path = sys.argv[1]
sym = "__ZNK2rx10DisplayMtl24getMaxSupportedESVersionEv"
addr = next(int(l.split()[0], 16) for l in subprocess.check_output(["nm", path], text=True).splitlines() if l.endswith(" " + sym))
expect = bytes.fromhex("f44fbea9fd7b01a9")          # stp x20, x19, [sp,#-0x20]! ; stp x29, x30, [sp,#0x10]
patch = bytes.fromhex("600080d2c0035fd6")           # mov x0, #3 (gl::Version{3, 0}) ; ret
data = bytearray(open(path, "rb").read())
cur = bytes(data[addr:addr + 8])                    # __TEXT starts at file offset 0
if cur == patch:
    print("    ANGLE: already patched"); sys.exit(0)
if cur != expect:
    sys.exit("unexpected bytes at %#x: %s" % (addr, cur.hex()))
data[addr:addr + 8] = patch
open(path, "wb").write(data)
print("    ANGLE: getMaxSupportedESVersion -> GLES 3.0 (simulator copy)")
PY
    fi
    while IFS= read -r -d '' f; do
        if file -b "$f" | grep -q 'Mach-O'; then
            vtool -set-build-version "$plat" "$MINOS" "$SDK" -replace -output "$f" "$f" 2>/dev/null \
                || die "vtool failed on $f"
            codesign -f -s - "$f" 2>/dev/null
        fi
    done < <(find "$dst" -type f -print0)
    # Frameworks must say they're for tvOS, or installation is refused.
    for fw in "$dst"/*.framework; do
        plutil -replace CFBundleSupportedPlatforms -json "[\"$( [ "$plat" = 8 ] && echo AppleTVSimulator || echo AppleTVOS )\"]" "$fw/Info.plist" 2>/dev/null || true
        plutil -remove UIDeviceFamily "$fw/Info.plist" 2>/dev/null || true
        plutil -replace MinimumOSVersion -string "$MINOS" "$fw/Info.plist" 2>/dev/null || true
        codesign -f -s - "$fw" 2>/dev/null
    done
done
say "done: build/natives/{appletvsimulator,appletvos}"
