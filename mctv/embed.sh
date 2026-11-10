#!/bin/bash
# Xcode build phase. Copies the game (libmctvgame.dylib, from aot/aot.py) and
# the native libraries (scripts/prepare-natives.sh) into the app's Frameworks,
# and signs each with the app's identity (ad hoc for the simulator).
set -euo pipefail

NATIVES="$MCTV_NATIVES_DIR/$PLATFORM_NAME"
APP="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
[ -d "$NATIVES" ] || { echo "error: $NATIVES missing. Run scripts/prepare-natives.sh"; exit 1; }
[ -f "$MCTV_GAME_LIBRARY" ] || { echo "error: no game library. Build the app with aot/aot.py"; exit 1; }

mkdir -p "$APP/Frameworks"
rsync -a --delete "$NATIVES/" "$APP/Frameworks/"  # exactly these, whatever an earlier build left
cp "$MCTV_GAME_LIBRARY" "$APP/Frameworks/"

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] || [ "${CODE_SIGNING_ALLOWED:-YES}" = "NO" ]; then IDENTITY=-; fi
find "$APP/Frameworks" -type f -name '*.dylib' -print0 | while IFS= read -r -d '' f; do
    codesign -f -s "$IDENTITY" --timestamp=none --generate-entitlement-der "$f" >/dev/null
done
echo "embedded the game and natives for $PLATFORM_NAME (signed with ${IDENTITY:0:12})"
