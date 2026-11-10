#!/usr/bin/env bash
# Gets a fresh clone ready to build. Checks the tools, writes config/signing.env,
# installs GraalVM in deps/ and builds the native libraries. Safe to run again,
# and finished steps are skipped.
#
#   scripts/setup.sh              everything, asking for what it needs
#   scripts/setup.sh --sim-only   skip the Apple TV's signing settings
#   scripts/setup.sh --check      only check the tools
#
# Then python3 -I aot/aot.py sim --world plays in the simulator and
# python3 -I aot/aot.py device installs on the Apple TV.
source "$(dirname "$0")/lib.sh"

GRAAL_CE_URL=https://github.com/graalvm/graalvm-ce-builds/releases/download/graal-25.5.5.0.3/graalvm-community-jdk-25i5-25.0.5.0.3_macos-aarch64_bin.tar.gz
GRAAL_CE_SHA256=54369d4a5931a5a2101c7c52444a4e7e6647a3a4e041335053cda6fd22295e0c
GRAAL_ORACLE_URL=https://gds.oracle.com/download/graal/25i5/archive/graalvm-jdk-25i5-25.0.5.0.3_macos-aarch64_bin.tar.gz
GRAAL_ORACLE_SHA256=3c51d8ef62c63eb8454727f32d67aaff39afabe4c90b3c811c11547029c10819
ORACLE_TEAM=VB5E2TV963  # Oracle America's Developer ID, which signs its macOS builds

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
    [ -t 0 ] || die "setup needs answers. Run it in a terminal, or fill in config/signing.env from the example"
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
for tool in xcodegen cmake git rsync; do  # meson and ninja come pinned, in build/meson-venv
    command -v "$tool" >/dev/null || missing+=("$tool")
done
[ -x /opt/homebrew/bin/python3 ] || missing+=(python)
if [ ${#missing[@]} -gt 0 ]; then
    command -v brew >/dev/null || die "missing ${missing[*]}. Install Homebrew (https://brew.sh), then run this again"
    say "missing ${missing[*]}"
    if yes_no "install them with Homebrew now?" y; then
        brew install "${missing[@]}"
    else
        die "install them with: brew install ${missing[*]}"
    fi
fi
[ "$CHECK_ONLY" = 0 ] || { say "tools are ready"; exit 0; }

mkdir -p "$ROOT/config"
if [ "$SIM_ONLY" = 0 ] && [ ! -f "$ROOT/config/signing.env" ]; then
    say "Apple TV signing. Add your Apple ID in Xcode > Settings > Accounts first"
    user=$(id -un | tr -cd 'a-z0-9')
    prefix=$(ask "bundle ID (your own reverse domain)" "com.${user:-me}.mctv")
    team=$(ask "team ID (leave empty to read it from Xcode)" "")
    "$ROOT/scripts/set-team.sh" --prefix "$prefix" ${team:+--team "$team"}
fi

# <folder> <url> <sha256>: a GraalVM release, unpacked so <folder>/Contents/Home is its home.
install_graal() {
    local dest="$1" url="$2" sum="$3" tmp
    tmp=$(mktemp -d)
    say "downloading ${url##*/}"
    curl -fL --progress-bar -o "$tmp/graal.tar.gz" "$url" || die "couldn't download $url"
    [ "$(shasum -a 256 "$tmp/graal.tar.gz" | cut -d' ' -f1)" = "$sum" ] || die "${url##*/} doesn't match its SHA-256"
    mkdir -p "$tmp/x"
    tar -xzf "$tmp/graal.tar.gz" -C "$tmp/x"
    rm -rf "$dest"
    mv "$tmp/x"/* "$dest"
    rm -rf "$tmp"
}
if [ ! -x "$ROOT/deps/graalvm/Contents/Home/bin/native-image" ]; then
    install_graal "$ROOT/deps/graalvm" "$GRAAL_CE_URL" "$GRAAL_CE_SHA256"
fi
if [ ! -x "$ROOT/deps/graalvm-oracle/Contents/Home/bin/native-image" ]; then
    say "Oracle GraalVM builds the game with the G1 collector, which keeps it from stuttering."
    say "It's free to use under Oracle's GraalVM Free Terms and Conditions: https://www.oracle.com/downloads/licenses/graal-free-license.html"
    if yes_no "download it, accepting those terms?" y; then
        install_graal "$ROOT/deps/graalvm-oracle" "$GRAAL_ORACLE_URL" "$GRAAL_ORACLE_SHA256"
        for tool in java native-image; do
            codesign --verify --strict "$ROOT/deps/graalvm-oracle/Contents/Home/bin/$tool" 2>/dev/null \
                && codesign -dv "$ROOT/deps/graalvm-oracle/Contents/Home/bin/$tool" 2>&1 | grep -q "TeamIdentifier=$ORACLE_TEAM" \
                || die "deps/graalvm-oracle/Contents/Home/bin/$tool isn't signed by Oracle"
        done
    else
        say "without it, build with --graal ce, which has only the Serial collector (aot/README.md)"
    fi
fi

# The game's files come first, since the native builds check their exports against its LWJGL jars.
say "fetching the game, and drawing the app's art from its files"
ensure_art 26.3

D="$BUILD/deps"
build() {  # <marker file> <script>
    if [ -f "$1" ]; then
        say "${2##*/}: already built"
    else
        "$ROOT/scripts/$2"
    fi
}
build "$D/lwjgl/appletvos/liblwjgl.dylib" build-lwjgl-natives.sh
build "$D/thirdparty/appletvos/libshaderc.dylib" build-lwjgl-thirdparty.sh
build "$D/sdl/appletvos/libSDL3.dylib" build-sdl.sh
build "$D/moltenvk/appletvos/libMoltenVK.dylib" build-moltenvk.sh
build "$D/openal/appletvos/libopenal.dylib" build-openal.sh
"$ROOT/scripts/prepare-natives.sh"

say "ready. Next:"
echo "  python3 -I aot/aot.py sim --world     play in the simulator"
[ "$SIM_ONLY" = 1 ] || echo "  python3 -I aot/aot.py device          install on the Apple TV (pair it in Xcode's Device Hub first)"
exit 0
