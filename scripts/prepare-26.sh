#!/usr/bin/env bash
# Assembles what the Minecraft 26.x app embeds.
#   build/natives-26/<sdk>/  LWJGL, SDL and MoltenVK from the build scripts, a
#                            second SDL for Controlify, libmctvgl, and OpenAL,
#                            MobileGlues and ANGLE from the 1.21.11 natives
#   build/java-26/libs/      Amethyst's launcher jars, Mojang's LWJGL 3.4.3 jars
#                            and mctv-agent.jar
#
#   scripts/prepare-26.sh
source "$(dirname "$0")/lib.sh"
mc_track 26.3

D="$BUILD/deps26"
missing=()
for need in lwjgl/appletvos/liblwjgl.dylib thirdparty/appletvos/libshaderc.dylib \
            sdl/appletvos/libSDL3.dylib moltenvk/appletvos/libMoltenVK.dylib; do
    [ -f "$D/$need" ] || missing+=("$need")
done
if [ ${#missing[@]} -gt 0 ]; then
    die "missing ${missing[*]} under build/deps26 (scripts/build-lwjgl-natives.sh, build-lwjgl-thirdparty.sh, build-sdl.sh, build-moltenvk.sh)"
fi
[ -d "$BUILD/natives/appletvos" ] || "$ROOT/scripts/prepare-natives.sh"
[ -f "$BUILD/java/libs/launcher.jar" ] || "$ROOT/scripts/build-java.sh"
ls "$MC_JAVA/lwjgl"/lwjgl-sdl-*.jar >/dev/null 2>&1 || die "no LWJGL 3.4.3 jars in ${MC_JAVA#$ROOT/}/lwjgl (scripts/mc-sim.sh --version 26.3 fetches them)"

# From 1.21.11's natives (Amethyst's builds, relabelled for tvOS).
CARRY="libopenal.dylib libAmethystAccountJNI.dylib libmobileglues.dylib libspirv-cross-c-shared.0.dylib
       libtinygl4angle.dylib libEGL.framework libGLESv2.framework"

for sdk in appletvos appletvsimulator; do
    out="$MC_NATIVES/$sdk"
    rm -rf "$out"
    mkdir -p "$out"
    for part in lwjgl thirdparty sdl moltenvk; do
        cp "$D/$part/$sdk"/*.dylib "$out/"
    done
    # Controlify gets its own SDL, as on desktop. It drains its SDL's event queue,
    # which would eat Minecraft's mouse and keys if they shared one.
    cp "$out/libSDL3.dylib" "$out/libSDL3_controlify.dylib"
    install_name_tool -id @rpath/libSDL3_controlify.dylib "$out/libSDL3_controlify.dylib" 2>/dev/null
    codesign -f -s - "$out/libSDL3_controlify.dylib" 2>/dev/null  # the app build signs it properly
    for l in $CARRY; do
        ditto "$BUILD/natives/$sdk/$l" "$out/$l"
    done
    # The GL library in front of MobileGlues (mctv/gl/mctv_gl.c).
    target=arm64-apple-tvos26.0; [ "$sdk" = appletvsimulator ] && target=$target-simulator
    xcrun --sdk "$sdk" clang -target "$target" -dynamiclib -O2 -Wall -Werror \
        -install_name @rpath/libmctvgl.dylib -o "$out/libmctvgl.dylib" "$ROOT/mctv/gl/mctv_gl.c"
    say "natives for $sdk: $(ls "$out" | tr '\n' ' ')"
done

rm -rf "$MC_JAVA/libs"
mkdir -p "$MC_JAVA/libs"
for j in "$BUILD"/java/libs/*.jar; do
    [ "$(basename "$j")" = lwjgl.jar ] || cp "$j" "$MC_JAVA/libs/"
done
cp "$MC_JAVA"/lwjgl/*.jar "$MC_JAVA/libs/"
# On Java 25 LWJGL's multi-release core jar uses the foreign function API,
# whose upcall stubs crash Amethyst's JDK by writing straight into the code
# cache. Without those classes LWJGL falls back to JNI and libffi, which work.
core=$(ls "$MC_JAVA/libs"/lwjgl-3.*.jar | grep -v -- '-[a-z]*-3\.' | head -1)
zip -q -d "$core" 'META-INF/versions/25/*' 'META-INF/versions/27/*' >/dev/null
# java/mctv-agent patches classes as they load. It uses LWJGL's libffi binding
# in place of FFM upcalls, so it compiles against the core jar.
W="$BUILD/mctv-agent"
rm -rf "$W"
mkdir -p "$W/classes"
javac --release 25 -nowarn -cp "$core" -d "$W/classes" $(find "$ROOT/java/mctv-agent/src" -name '*.java') || die "the agent didn't compile"
printf 'Premain-Class: mctv.agent.Agent\n' > "$W/manifest.txt"
jar --create --file "$MC_JAVA/libs/mctv-agent.jar" --manifest "$W/manifest.txt" -C "$W/classes" .
left=$(unzip -l "$core" | grep -c 'META-INF/versions/2[5-9]/' || true)
[ "$left" = 0 ] || die "couldn't strip the Java 25 classes from $core"
say "jars: $(ls "$MC_JAVA/libs" | tr '\n' ' ')"
