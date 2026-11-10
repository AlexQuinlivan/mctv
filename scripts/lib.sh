# Shared helpers for the scripts in this folder. Source it, don't run it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
OUT="$ROOT/out"
mkdir -p "$OUT"

SIM_RUNTIME="com.apple.CoreSimulator.SimRuntime.tvOS-27-2"

die() { echo "error: $*" >&2; exit 1; }
say() { echo "==> $*" >&2; }

# Local settings (config/signing.env.example), only needed for the TV.
# shellcheck disable=SC1090
[ -f "$ROOT/config/signing.env" ] && source "$ROOT/config/signing.env"
BUNDLE_PREFIX="${BUNDLE_PREFIX:-com.example.mctv}"

# The app icon and Top Shelf art are drawn from the game's own files by
# make-art.py on each machine, never committed. Redone when the version changes.
#   ensure_art <version>
ensure_art() {
    local version="$1" game="$BUILD/game" brand="$ROOT/mctv/Resources/Assets.xcassets/App Icon & Top Shelf Image.brandassets"
    if [ -f "$brand/Contents.json" ] && [ -f "$ROOT/mctv/TopShelf/Resources/hero.jpg" ] \
        && [ "$(cat "$BUILD/art-made-for" 2>/dev/null)" = "$version" ] \
        && [ "$BUILD/art-made-for" -nt "$ROOT/scripts/make-art.py" ]; then
        return 0
    fi
    local req="$ROOT/scripts/requirements-art.txt"
    if [ "$(cat "$BUILD/art-venv/.pins" 2>/dev/null)" != "$(shasum "$req")" ]; then
        rm -rf "$BUILD/art-venv"
        /opt/homebrew/bin/python3 -m venv "$BUILD/art-venv"
        "$BUILD/art-venv/bin/pip" install -q --disable-pip-version-check --require-hashes -r "$req"
        shasum "$req" > "$BUILD/art-venv/.pins"
    fi
    /usr/bin/python3 -I "$ROOT/scripts/fetch-minecraft.py" "$version" "$game" >/dev/null
    "$BUILD/art-venv/bin/python" "$ROOT/scripts/make-art.py" "$version"
}

# Prints the CoreDevice identifier of the paired Apple TV, or $DEVICE.
find_tv() {
    if [ -n "${DEVICE:-}" ]; then echo "$DEVICE"; return; fi
    local json="$OUT/devices.json"
    xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1 || die "devicectl list devices failed"
    local id
    id=$(/usr/bin/python3 -I - "$json" <<'PY'
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    hw = d.get("hardwareProperties", {})
    if hw.get("reality") == "physical" and (hw.get("platform") == "tvOS" or "tv" in str(hw.get("deviceType", "")).lower()):
        print(d["identifier"])
        break
PY
)
    [ -n "$id" ] || die "no paired Apple TV found. Pair it in Xcode's Device Hub or set DEVICE in config/signing.env"
    echo "$id"
}

# Applies <dir>/*.patch to a git checkout in order. Patches already applied are skipped.
#   apply_patches <checkout> <patch dir>
apply_patches() {
    local src="$1" p
    for p in "$2"/*.patch; do
        git -C "$src" apply --reverse --check "$p" 2>/dev/null && continue
        git -C "$src" apply --check "$p" 2>/dev/null \
            || die "${p#"$ROOT"/} doesn't apply to ${src#"$ROOT"/}. Upstream changed, so the patch needs updating"
        git -C "$src" apply "$p"
    done
}
