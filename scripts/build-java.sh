#!/usr/bin/env bash
# Copies Amethyst's launcher.jar and lwjgl.jar (LWJGL 3.3.3) from its CI build
# into build/java/libs. Two classes hard-code the native bridge's path, so they
# are recompiled to read $POJAV_NATIVE_LIB instead.
source "$(dirname "$0")/lib.sh"

IPA="$ROOT/deps/amethyst-ipa/extracted/Payload/AngelAuraAmethyst.app"
SRC="$ROOT/amethyst/JavaApp/src"
[ -d "$IPA/libs" ] || "$ROOT/scripts/prepare-runtime.sh"
[ -d "$SRC" ] || die "amethyst/ checkout missing"

W="$BUILD/javaapp"
rm -rf "$W" "$BUILD/java/libs"
mkdir -p "$W/src" "$W/classes" "$BUILD/java/libs"
cp "$IPA"/libs/*.jar "$BUILD/java/libs/"

patch_src() {  # <relative source path>
    mkdir -p "$W/src/$(dirname "$1")"
    sed 's|System.getenv("BUNDLE_PATH") + "/AngelAuraAmethyst"|System.getenv("POJAV_NATIVE_LIB")|' \
        "$SRC/$2/$1" > "$W/src/$1"
    grep -q 'POJAV_NATIVE_LIB' "$W/src/$1" || die "patch didn't apply to $1"
}
patch_src org/lwjgl/glfw/GLFW.java lwjgl
patch_src net/kdt/pojavlaunch/uikit/UIKit.java launcher
# Amethyst stubs GLFW's gamepad API. Wire it to the TV's controller
# (mctv/Sources/MCInput.m) so mods like Controlify see a real gamepad.
/usr/bin/python3 -I "$ROOT/scripts/patch-glfw-gamepad.py" "$W/src/org/lwjgl/glfw/GLFW.java" || die "gamepad patch failed"

CP=$(ls "$BUILD"/java/libs/*.jar | tr '\n' ':')
say "compiling patched GLFW + UIKit (Java 25 bytecode)"
javac --release 25 -nowarn -Xlint:none -cp "$CP" -d "$W/classes" \
    "$W/src/org/lwjgl/glfw/GLFW.java" "$W/src/net/kdt/pojavlaunch/uikit/UIKit.java" 2>&1 \
    | grep -v -E '^Note:|warning' || true
[ -f "$W/classes/org/lwjgl/glfw/GLFW.class" ] || die "GLFW.java didn't compile"
[ -f "$W/classes/net/kdt/pojavlaunch/uikit/UIKit.class" ] || die "UIKit.java didn't compile"

(cd "$W/classes" && jar uf "$BUILD/java/libs/lwjgl.jar" org/lwjgl/glfw/GLFW*.class)
(cd "$W/classes" && jar uf "$BUILD/java/libs/launcher.jar" net/kdt/pojavlaunch/uikit/UIKit*.class)
for j in lwjgl launcher; do
    n=$(unzip -p "$BUILD/java/libs/$j.jar" $( [ $j = lwjgl ] && echo org/lwjgl/glfw/GLFW.class || echo net/kdt/pojavlaunch/uikit/UIKit.class) | strings | grep -c POJAV_NATIVE_LIB)
    [ "$n" -ge 1 ] || die "$j.jar wasn't updated"
done
ls -la "$BUILD/java/libs"
say "Java libs ready in build/java/libs"
