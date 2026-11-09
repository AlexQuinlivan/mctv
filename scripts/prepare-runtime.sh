#!/usr/bin/env bash
# Relabels the Java 25 runtime from Amethyst's iOS CI build for tvOS and the
# simulator, into build/runtime/<sdk>/java-25.
# The CI build stands in for Amethyst's Makefile download, whose host is gone.
source "$(dirname "$0")/lib.sh"

AMETHYST_COMMIT=f98c413
AMETHYST_CI_RUN=37242039920   # "Development build" run for $AMETHYST_COMMIT
IPA_SHA256=9e934826b921f6d0153fbea8cf9442f61ab58720d9725b285a389b044789c556
IPA_DIR="$ROOT/deps/amethyst-ipa"
APP="$IPA_DIR/extracted/Payload/AngelAuraAmethyst.app"
MINOS=26.0
SDK=27.2

if [ ! -d "$APP" ]; then
    say "downloading Amethyst CI build $AMETHYST_CI_RUN ($AMETHYST_COMMIT)"
    mkdir -p "$IPA_DIR"
    gh run download "$AMETHYST_CI_RUN" -R AngelAuraMC/Amethyst-iOS -n org.angelauramc.amethyst-ios.ipa -D "$IPA_DIR"
    echo "$IPA_SHA256  $(ls "$IPA_DIR"/*.ipa)" | shasum -a 256 -c --status \
        || { rm -f "$IPA_DIR"/*.ipa; die "Amethyst's CI build doesn't match its SHA-256"; }
    unzip -q -o "$IPA_DIR"/*.ipa -d "$IPA_DIR/extracted"
fi

relabel_tree() {  # <dir> <vtool platform number>
    local dir="$1" plat="$2" f
    while IFS= read -r -d '' f; do
        if file -b "$f" | grep -q 'Mach-O'; then
            vtool -set-build-version "$plat" "$MINOS" "$SDK" -replace -output "$f" "$f" 2>/dev/null
            codesign -f -s - "$f" 2>/dev/null
        fi
    done < <(find "$dir" -type f -print0)
}

for target in appletvsimulator:8 appletvos:3; do
    name="${target%%:*}"
    plat="${target##*:}"
    dst="$BUILD/runtime/$name/java-25"
    say "relabelling Java 25 runtime for $name (platform $plat)"
    rm -rf "$dst"
    mkdir -p "$(dirname "$dst")"
    ditto "$APP/java_runtimes/java-25-openjdk" "$dst"
    # Links CoreMIDI, which tvOS doesn't have. Only javax.sound loads it.
    rm -f "$dst/lib/libjsound.dylib"
    relabel_tree "$dst" "$plat"
    vtool -show-build "$dst/lib/server/libjvm.dylib" | grep -E 'platform' | sed 's/^/    libjvm: /' >&2
done

say "done: build/runtime/*/java-25"
