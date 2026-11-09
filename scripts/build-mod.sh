#!/usr/bin/env bash
# Builds java/mctv-mod, our Fabric mod for controller rumble through Controlify,
# into the game's mods folder.
#
#   scripts/build-mod.sh [game dir]        default build/mcgame
source "$(dirname "$0")/lib.sh"

GAME="${1:-$BUILD/mcgame}"
MODS="$GAME/mods"
SRC="$ROOT/java/mctv-mod"
CONTROLIFY=$(ls "$MODS"/controlify-*.jar 2>/dev/null | head -1)
[ -n "$CONTROLIFY" ] || die "Controlify isn't in $MODS (scripts/fetch-fabric.py puts it there)"
MIXIN=$(find "$GAME/libraries/net/fabricmc/sponge-mixin" -name '*.jar' 2>/dev/null | head -1)
[ -n "$MIXIN" ] || die "sponge-mixin isn't in $GAME/libraries"
LWJGL="$BUILD/java/libs/lwjgl.jar"
unzip -p "$LWJGL" org/lwjgl/glfw/GLFW.class 2>/dev/null | grep -aq nmctvGamepadRumble \
    || die "lwjgl.jar has no rumble natives (scripts/build-java.sh)"

VERSION=$(sed -n 's/^ *"version": "\(.*\)",$/\1/p' "$SRC/resources/fabric.mod.json")
JAR="mctv-$VERSION.jar"
W="$BUILD/mctv-mod"
rm -rf "$W"
mkdir -p "$W/classes"
javac --release 21 -nowarn -proc:none -cp "$CONTROLIFY:$MIXIN:$LWJGL" -d "$W/classes" \
    $(find "$SRC/src" -name '*.java') || die "the mod didn't compile"
cp "$SRC"/resources/* "$W/classes/"
rm -f "$MODS"/mctv-*.jar
(cd "$W/classes" && jar cf "$MODS/$JAR" .)
grep -qx "$JAR" "$MODS/.mctv-managed" 2>/dev/null || echo "$JAR" >> "$MODS/.mctv-managed"
say "built mods/$JAR"
