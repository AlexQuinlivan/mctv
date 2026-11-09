# Shared helpers for the scripts in this folder. Source it, don't run it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
OUT="$ROOT/out"
mkdir -p "$OUT"

SIM_NAME="MCTV Apple TV 4K (3rd gen)"
SIM_TYPE="com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-1080p"
SIM_RUNTIME="com.apple.CoreSimulator.SimRuntime.tvOS-27-2"
LLDB_IGNORED_EXC='EXC_BAD_ACCESS|EXC_BAD_INSTRUCTION|EXC_ARITHMETIC'

die() { echo "error: $*" >&2; exit 1; }
say() { echo "==> $*" >&2; }

# Local settings (config/*.env.example). Only signing.env is required, and only for the TV.
for f in signing server; do
    # shellcheck disable=SC1090
    [ -f "$ROOT/config/$f.env" ] && source "$ROOT/config/$f.env"
done
BUNDLE_PREFIX="${BUNDLE_PREFIX:-com.example.mctv}"
export MCTV_JIT_DOMAIN=localhost  # for project.yml. load_jit_config sets the real one

# Prints the UDID of our simulator, creating and booting it if needed.
ensure_sim() {
    local udid
    udid=$(xcrun simctl list devices | grep -F "$SIM_NAME (" | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' | head -1 || true)
    if [ -z "$udid" ]; then
        say "creating simulator '$SIM_NAME'"
        udid=$(xcrun simctl create "$SIM_NAME" "$SIM_TYPE" "$SIM_RUNTIME")
    fi
    xcrun simctl boot "$udid" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
    echo "$udid"
}

# Folders, bundle ID and name for a Minecraft version. 26.x and 1.21.x each get
# their own, so the two apps can sit side by side.
#   mc_track <version>
# sets MC_GAME, MC_NATIVES, MC_JAVA, MC_DERIVED, MC_BUNDLE_ID, MC_DISPLAY and MC_NEXT (1 for 26.x).
mc_track() {
    case "$1" in
        1.*)
            MC_NEXT=0; MC_GAME="$BUILD/mcgame"; MC_NATIVES="$BUILD/natives"; MC_JAVA="$BUILD/java"
            MC_DERIVED="$BUILD/mctv"; MC_BUNDLE_ID="$BUNDLE_PREFIX.app"; MC_DISPLAY="MCTV 1.21" ;;
        *)
            MC_NEXT=1; MC_GAME="$BUILD/mc26"; MC_NATIVES="$BUILD/natives-26"; MC_JAVA="$BUILD/java-26"
            MC_DERIVED="$BUILD/mctv-26"; MC_BUNDLE_ID="$BUNDLE_PREFIX.app26"; MC_DISPLAY="MCTV" ;;
    esac
}

# The app icon and Top Shelf art are drawn from the game's own files by
# make-art.py on each machine, never committed. Redone when the version changes.
#   ensure_art <version>
ensure_art() {
    local version="$1" game brand="$ROOT/mctv/Resources/Assets.xcassets/App Icon & Top Shelf Image.brandassets"
    case "$version" in 1.*) game="$BUILD/mcgame" ;; *) game="$BUILD/mc26" ;; esac
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

# config/jit.env holds the JIT server's address and the token the app sends it,
# made on first use from SERVER_NAME in config/server.env. MC_SERVER, if set,
# goes in the game's server list as Home.
load_jit_config() {
    local f="$ROOT/config/jit.env"
    if [ ! -f "$f" ]; then
        local jit=""
        [ -n "${SERVER_NAME:-}" ] && jit="http://$SERVER_NAME:25566"
        (umask 077; printf 'JIT_SERVER=%s\nJIT_TOKEN=%s\nMC_SERVER=\n' "$jit" "$(openssl rand -hex 24)" > "$f")
        say "wrote config/jit.env with a new JIT token"
    fi
    # shellcheck disable=SC1090
    source "$f"
    # The app may fetch JIT over plain HTTP from this host (App Transport Security).
    MCTV_JIT_DOMAIN=$(printf '%s' "${JIT_SERVER:-}" | sed -E 's#^[a-z]+://##; s#[:/].*$##')
    export MCTV_JIT_DOMAIN="${MCTV_JIT_DOMAIN:-localhost}"
}

# Checks config/signing.env for the TV builds.
load_signing() {
    [ -f "$ROOT/config/signing.env" ] || die "no config/signing.env. Run scripts/setup.sh, or copy config/signing.env.example"
    [ -n "${DEVELOPMENT_TEAM:-}" ] || die "DEVELOPMENT_TEAM is empty in config/signing.env"
    local t
    for t in ${REFUSE_TEAMS:-}; do
        [ "$DEVELOPMENT_TEAM" != "$t" ] || die "config/signing.env refuses team $t"
    done
    DEVICE="${DEVICE:-}"
}

# Fails unless a built .app is signed by $DEVELOPMENT_TEAM.
verify_team() {
    local app="$1" team
    team=$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
    [ "$team" = "$DEVELOPMENT_TEAM" ] || die "$app is signed by team '$team', expected $DEVELOPMENT_TEAM"
    say "signed by team $team"
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
    [ -n "$id" ] || die "no paired Apple TV found. Pair it in Xcode (Window > Devices and Simulators) or set DEVICE in config/signing.env"
    echo "$id"
}

# Prints the hardware UDID for a CoreDevice identifier.
tv_udid() {
    local json="$OUT/devices.json"
    xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1 || die "devicectl list devices failed"
    local udid
    udid=$(/usr/bin/python3 -I - "$json" "$1" <<'PY'
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    if d["identifier"] == sys.argv[2]:
        print(d.get("hardwareProperties", {}).get("udid", ""))
PY
)
    [ -n "$udid" ] || die "no hardware UDID for device $1"
    echo "$udid"
}

# Attaches lldb to a process and serves JIT until the app detaches.
#   lldb_jit26 sim <pid>
#   lldb_jit26 device <coredevice id> <pid>
lldb_jit26() {
    local kind="$1"
    local attach=()
    if [ "$kind" = sim ]; then
        attach=(-o "process attach -p $2")
    else
        attach=(-o "device select $2" -o "device process attach -p $3")
    fi
    xcrun lldb -b \
        -o "settings set platform.plugin.darwin.ignored-exceptions $LLDB_IGNORED_EXC" \
        "${attach[@]}" \
        -o "command script import $ROOT/tools/jit26.py" \
        -o "jit26 serve -v"
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
