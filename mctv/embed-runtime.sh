#!/bin/bash
# Xcode build phase. Copies the relabelled Java runtime, native libraries and
# jars into the app and signs every Mach-O with the app's identity (ad-hoc for
# the simulator). The inputs come from:
#   scripts/prepare-runtime.sh   Java 25 runtime
#   scripts/prepare-natives.sh   LWJGL, MobileGlues, ANGLE, OpenAL...
#   scripts/build-java.sh        launcher.jar, lwjgl.jar
set -euo pipefail

ROOT="$PROJECT_DIR/.."
SRC="$ROOT/build/runtime/$PLATFORM_NAME/java-25"
NATIVES="${MCTV_NATIVES_DIR:-$ROOT/build/natives}/$PLATFORM_NAME"
LIBS="${MCTV_JAVA_DIR:-$ROOT/build/java}/libs"
APP="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
DST="$APP/java/java-25"

for need in "$SRC" "$NATIVES" "$LIBS"; do
    if [ ! -d "$need" ]; then
        echo "error: $need missing. Run scripts/prepare-runtime.sh, prepare-natives.sh and build-java.sh"
        exit 1
    fi
done

mkdir -p "$DST" "$APP/java/libs" "$APP/Frameworks"
rsync -a --delete "$SRC/" "$DST/"
rsync -a --delete "$LIBS/" "$APP/java/libs/"
rsync -a "$NATIVES/" "$APP/Frameworks/"

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] || [ "${CODE_SIGNING_ALLOWED:-YES}" = "NO" ]; then IDENTITY=-; fi
sign() { codesign -f -s "$IDENTITY" --timestamp=none --generate-entitlement-der "$1" >/dev/null; }
find "$DST" "$APP/Frameworks" -type f -name '*.dylib' -print0 | while IFS= read -r -d '' f; do sign "$f"; done
for fw in "$APP"/Frameworks/*.framework; do sign "$fw"; done
echo "embedded Java runtime, natives and jars for $PLATFORM_NAME (signed with ${IDENTITY:0:12})"
