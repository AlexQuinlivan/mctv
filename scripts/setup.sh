#!/usr/bin/env bash
# Gets a fresh clone ready to build. Checks the tools, writes config/, checks
# out Amethyst and builds the native libraries. Safe to run again, and finished
# steps are skipped. The first run takes about an hour, mostly the native builds.
#
#   scripts/setup.sh              everything, asking for what it needs
#   scripts/setup.sh --sim-only   skip the Apple TV and server settings
#   scripts/setup.sh --check      only check the tools
#
# Then scripts/mc-sim.sh plays in the simulator and scripts/mc-device.sh
# installs on the Apple TV.
source "$(dirname "$0")/lib.sh"

AMETHYST_REPO=https://github.com/AngelAuraMC/Amethyst-iOS.git
AMETHYST_COMMIT=f98c4133c72d39e06ceac42b57cc4477c52105fc
SIM_ONLY=0
CHECK_ONLY=0
for a in "$@"; do
    case "$a" in
        --sim-only) SIM_ONLY=1 ;;
        --check) CHECK_ONLY=1 ;;
        *) die "unknown option $a" ;;
    esac
done

ask() {  # <prompt> <default>, prints the answer
    local reply
    [ -t 0 ] || die "setup needs answers. Run it in a terminal, or fill in config/*.env from the examples"
    read -r -p "$1 [$2] " reply
    echo "${reply:-$2}"
}
yes_no() {  # <prompt> <y|n>
    case "$(ask "$1 (y/n)" "$2")" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

say "checking tools"
[ "$(uname -s)/$(uname -m)" = Darwin/arm64 ] || die "needs a Mac with Apple silicon"
xcode-select -p 2>/dev/null | grep -q '\.app/' || die "needs Xcode (not only the Command Line Tools). Install it, open it once, then xcode-select -s /Applications/Xcode.app"
xcrun --sdk appletvos --show-sdk-path >/dev/null 2>&1 || die "Xcode has no tvOS SDK. Install the tvOS platform in Xcode > Settings > Components"
xcrun simctl list runtimes | grep -q "${SIM_RUNTIME##*.}" \
    || say "no tvOS 27.2 simulator runtime. The simulator needs it: xcodebuild -downloadPlatform tvOS"
missing=()
for tool in xcodegen cmake gh git rsync; do  # meson and ninja come pinned, in build/meson-venv
    command -v "$tool" >/dev/null || missing+=("$tool")
done
[ -x /opt/homebrew/bin/python3 ] || missing+=(python)
if ! command -v javac >/dev/null || [ "$(javac -version 2>&1 | sed -E 's/^javac ([0-9]+).*/\1/')" -lt 25 ] 2>/dev/null; then
    missing+=(openjdk)
fi
if [ ${#missing[@]} -gt 0 ]; then
    command -v brew >/dev/null || die "missing ${missing[*]}. Install Homebrew (https://brew.sh), then run this again"
    say "missing ${missing[*]}"
    if yes_no "install them with Homebrew now?" y; then
        brew install "${missing[@]}"
    else
        die "install them with: brew install ${missing[*]}"
    fi
    command -v javac >/dev/null || die "put Homebrew's Java first on your PATH: export PATH=\"/opt/homebrew/opt/openjdk/bin:\$PATH\""
fi
gh auth status >/dev/null 2>&1 || die "log in to GitHub with 'gh auth login'. Amethyst's Java runtime comes from its GitHub Actions build"
[ "$CHECK_ONLY" = 0 ] || { say "tools are ready"; exit 0; }

mkdir -p "$ROOT/config"
if [ "$SIM_ONLY" = 0 ]; then
    if [ ! -f "$ROOT/config/signing.env" ]; then
        say "Apple TV signing. Add your Apple ID in Xcode > Settings > Accounts first"
        user=$(id -un | tr -cd 'a-z0-9')
        prefix=$(ask "bundle ID prefix (your own reverse domain)" "com.${user:-me}.mctv")
        team=$(ask "team ID (leave empty to read it from Xcode)" "")
        "$ROOT/scripts/set-team.sh" --prefix "$prefix" ${team:+--team "$team"}
    fi
    if [ ! -f "$ROOT/config/server.env" ] && yes_no "set up a JIT server (server/README.md)? Without one, the TV needs this Mac at each launch" n; then
        {
            echo "SERVER_HOST=$(ask "SSH host of an always-on computer on the TV's network" "")"
            echo "SERVER_NAME=$(ask "name or address the TV uses to reach it" "")"
            echo "TV_ADDRESSES=$(ask "the Apple TV's IP address" "")"
        } > "$ROOT/config/server.env"
        chmod 600 "$ROOT/config/server.env"
    fi
fi

if [ ! -d "$ROOT/amethyst/.git" ]; then
    say "checking out Amethyst-iOS at ${AMETHYST_COMMIT:0:7}"
    git clone -q "$AMETHYST_REPO" "$ROOT/amethyst"
fi
git -C "$ROOT/amethyst" checkout -q "$AMETHYST_COMMIT"

D="$BUILD/deps26"
build() {  # <marker file> <script>
    if [ -f "$1" ]; then
        say "${2##*/}: already built"
    else
        "$ROOT/scripts/$2"
    fi
}
[ -d "$BUILD/runtime/appletvos/java-25" ] || "$ROOT/scripts/prepare-runtime.sh"
build "$D/lwjgl/appletvos/liblwjgl.dylib" build-lwjgl-natives.sh
build "$D/thirdparty/appletvos/libshaderc.dylib" build-lwjgl-thirdparty.sh
build "$D/sdl/appletvos/libSDL3.dylib" build-sdl.sh
build "$D/moltenvk/appletvos/libMoltenVK.dylib" build-moltenvk.sh

say "ready. Next:"
echo "  scripts/mc-sim.sh        play in the simulator"
[ "$SIM_ONLY" = 1 ] || echo "  scripts/mc-device.sh     install on the Apple TV (pair it in Xcode first)"
[ -f "$ROOT/config/server.env" ] && echo "  scripts/deploy-server.sh   install the JIT server (see server/README.md)"
exit 0
