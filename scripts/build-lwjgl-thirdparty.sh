#!/usr/bin/env bash
# The third-party natives LWJGL 3.4.3 loads for Minecraft, built for
# tvOS and its simulator from LWJGL-CI's forks with their CI flags. LWJGL
# resolves every function of a binding class when it loads, so each library
# carries LWJGL's whole C API.
#   libfreetype.dylib     FreeType with HarfBuzz, libpng and zlib built in
#   libshaderc.dylib      shaderc with glslang and SPIRV-Tools
#   libspirv-cross.dylib  SPIRV-Cross's C API
# libshaderc exports only C functions, so dyld can't mix its glslang and
# SPIRV-Tools with another library's copies.
#
#   scripts/build-lwjgl-thirdparty.sh [--force]
source "$(dirname "$0")/lib.sh"

MINOS=26.0
FREETYPE_REV=f9012ca17a379d2509d2cfada698cdaa239e8552   # LWJGL-CI/freetype LWJGL-3.4.3 (2.14.3)
HARFBUZZ_REV=e6b31477d2d0535cfad3ef3fe338749b7bd3d90b   # LWJGL-CI/harfbuzz LWJGL-3.4.3 (14.3.1)
SHADERC_REV=b85bc9ae86c171e08af56ab647f8cd83bfe12d89    # LWJGL-CI/shaderc LWJGL-3.4.3 (v2026.3)
SPVC_REV=63283768e1d22f50225fabbb63b2c8cb34bf3c39       # LWJGL-CI/SPIRV-Cross LWJGL-3.4.3 (6c09849f)
MESON_REQ="$ROOT/scripts/requirements-meson.txt"   # meson and ninja, locked with hashes

# From the env blocks of each fork's .github/workflows/lwjgl.yml.
FREETYPE_PARAMS="--wrap-mode=default --force-fallback-for=harfbuzz,libpng,zlib -Dbrotli=disabled -Dbzip2=disabled -Dharfbuzz=enabled -Dpng=enabled -Dzlib=system -Dtests=disabled -Dbuildtype=release -Dfreetype2:zlib=disabled -Dfreetype2:png=disabled -Dharfbuzz:experimental_api=true -Dharfbuzz:subset=disabled -Dharfbuzz:raster=disabled -Dharfbuzz:vector=disabled -Db_lto=true -Db_ndebug=true -Derror_strings=true"
SHADERC_PARAMS="-DSHADERC_SKIP_INSTALL=ON -DSHADERC_SKIP_TESTS=ON"
SPVC_PARAMS="-DSPIRV_CROSS_STATIC=OFF -DSPIRV_CROSS_SHARED=ON -DSPIRV_CROSS_CLI=OFF -DSPIRV_CROSS_ENABLE_TESTS=OFF -DSPIRV_CROSS_SKIP_INSTALL=ON -DSPIRV_CROSS_WERROR=ON -DSPIRV_CROSS_FORCE_PIC=ON"

SRC="$ROOT/deps/thirdparty"
DST="$BUILD/deps/thirdparty"
OBJ="$DST/obj"
VENV="$BUILD/meson-venv"
LIBS="libfreetype.dylib libshaderc.dylib libspirv-cross.dylib"
STAMP="$FREETYPE_REV $HARFBUZZ_REV $SHADERC_REV $SPVC_REV tvOS $MINOS $(shasum "$0" | cut -c1-12) $(xcodebuild -version | tr '\n' ' ')"

up_to_date() {
    local sdk l
    for sdk in appletvos appletvsimulator; do
        [ "$(cat "$DST/$sdk/.stamp" 2>/dev/null)" = "$STAMP" ] || return 1
        for l in $LIBS; do [ -f "$DST/$sdk/$l" ] || return 1; done
    done
}
[ "${1:-}" = --force ] && rm -f "$DST"/*/.stamp
if up_to_date; then
    say "up to date in build/deps/thirdparty (--force rebuilds)"
    exit 0
fi
unset SDKROOT MACOSX_DEPLOYMENT_TARGET TVOS_DEPLOYMENT_TARGET CFLAGS CXXFLAGS LDFLAGS
mkdir -p "$SRC" "$OBJ"

# Clones (blobless) or moves a checkout to a pinned commit.
#   checkout <dir> <url> <commit>
checkout() {
    local dir="$1" url="$2" rev="$3"
    if [ ! -d "$dir/.git" ]; then
        say "cloning ${url#https://github.com/} into ${dir#"$ROOT"/}"
        rm -rf "$dir"
        git init -q "$dir"
        git -C "$dir" remote add origin "$url"
    fi
    if [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" != "$rev" ]; then
        git -C "$dir" cat-file -e "$rev^{commit}" 2>/dev/null \
            || git -C "$dir" fetch -q --filter=blob:none origin "$rev" \
            || die "can't fetch $rev from $url"
        git -C "$dir" -c advice.detachedHead=false checkout -q --force "$rev"
    fi
}

checkout "$SRC/freetype" https://github.com/LWJGL-CI/freetype.git "$FREETYPE_REV"
# Meson would clone these at HEAD, so pin them. The second FreeType is the one
# HarfBuzz links against.
checkout "$SRC/freetype/subprojects/harfbuzz" https://github.com/LWJGL-CI/harfbuzz.git "$HARFBUZZ_REV"
checkout "$SRC/freetype/subprojects/freetype" https://github.com/LWJGL-CI/freetype.git "$FREETYPE_REV"
checkout "$SRC/shaderc" https://github.com/LWJGL-CI/shaderc.git "$SHADERC_REV"
checkout "$SRC/SPIRV-Cross" https://github.com/LWJGL-CI/SPIRV-Cross.git "$SPVC_REV"
# shaderc's other DEPS are only for its tests.
for dep in glslang:KhronosGroup/glslang spirv-headers:KhronosGroup/SPIRV-Headers spirv-tools:KhronosGroup/SPIRV-Tools; do
    name="${dep%%:*}"
    rev=$(sed -n "s/^ *'${name/-/_}_revision': *'\([0-9a-f]*\)'.*/\1/p" "$SRC/shaderc/DEPS")
    [ -n "$rev" ] || die "no ${name} revision in shaderc's DEPS"
    checkout "$SRC/shaderc/third_party/$name" "https://github.com/${dep#*:}.git" "$rev"
done

if [ ! -x "$VENV/bin/meson" ] || [ "$(cat "$VENV/.pins" 2>/dev/null)" != "$(shasum "$MESON_REQ")" ]; then
    say "installing meson and ninja into build/meson-venv"
    rm -rf "$VENV"
    /opt/homebrew/bin/python3 -m venv "$VENV"
    "$VENV/bin/pip" install -q --disable-pip-version-check --require-hashes -r "$MESON_REQ"
    shasum "$MESON_REQ" > "$VENV/.pins"
fi
NINJA="$VENV/bin/ninja"

# Copies a built library into place under its LWJGL name.
#   finish <built dylib> <sdk> <name>
finish() {
    local out="$DST/$2/$3"
    cp -fL "$1" "$out"
    chmod 644 "$out"
    install_name_tool -id "@rpath/$3" "$out" 2>/dev/null
    strip -x "$out"
    if [ "$2" = appletvsimulator ]; then
        codesign -v "$out" 2>/dev/null || die "$out lost the linker's ad-hoc signature"
    fi
}

for sdk in appletvos appletvsimulator; do
    [ "$sdk" = appletvos ] && triple="arm64-apple-tvos$MINOS" || triple="arm64-apple-tvos$MINOS-simulator"
    sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)
    mkdir -p "$DST/$sdk" "$OBJ/$sdk"
    rm -f "$DST/$sdk/.stamp"
    log="$OBJ/$sdk/build.log"
    : > "$log"

    # FreeType builds with Meson, like LWJGL's. Its build files bundle HarfBuzz.
    say "$sdk: FreeType + HarfBuzz (log: ${log#"$ROOT"/})"
    cross="$OBJ/$sdk/tvos.cross"
    flags="'-target', '$triple', '-isysroot', '$sysroot'"
    cat > "$cross" <<EOF
[host_machine]
system = 'darwin'
subsystem = '$([ "$sdk" = appletvos ] && echo tvos || echo tvos-simulator)'
kernel = 'xnu'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'

[binaries]
c = ['$(xcrun -f clang)']
cpp = ['$(xcrun -f clang++)']
objc = ['$(xcrun -f clang)']
objcpp = ['$(xcrun -f clang++)']
ar = '$(xcrun -f ar)'
strip = '$(xcrun -f strip)'

[built-in options]
c_args = [$flags]
cpp_args = [$flags]
objc_args = [$flags]
objcpp_args = [$flags]
c_link_args = [$flags]
cpp_link_args = [$flags]
objc_link_args = [$flags]
objcpp_link_args = [$flags]

[properties]
needs_exe_wrapper = true
EOF
    bdir="$OBJ/$sdk/freetype"
    if [ "$(cat "$bdir/.params" 2>/dev/null)" != "$FREETYPE_PARAMS $(cat "$cross")" ]; then
        rm -rf "$bdir"
        # shellcheck disable=SC2086
        PATH="$VENV/bin:$PATH" meson setup "$bdir" "$SRC/freetype" $FREETYPE_PARAMS --cross-file "$cross" >>"$log" 2>&1 \
            || die "FreeType configure failed, see $log"
        echo "$FREETYPE_PARAMS $(cat "$cross")" > "$bdir/.params"
    fi
    PATH="$VENV/bin:$PATH" meson compile -C "$bdir" >>"$log" 2>&1 || die "FreeType build failed, see $log"
    finish "$bdir/libfreetype.dylib" "$sdk" libfreetype.dylib

    cmake_common=(-G Ninja -DCMAKE_MAKE_PROGRAM="$NINJA" -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_SYSTEM_NAME=tvOS -DCMAKE_OSX_SYSROOT="$sdk" -DCMAKE_OSX_ARCHITECTURES=arm64
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MINOS")

    say "$sdk: shaderc"
    bdir="$OBJ/$sdk/shaderc"
    exports="$OBJ/$sdk/shaderc.exports"
    # shellcheck disable=SC2086
    cmake -S "$SRC/shaderc" -B "$bdir" "${cmake_common[@]}" $SHADERC_PARAMS \
        -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-exported_symbols_list,$exports -Wl,-dead_strip" \
        >>"$log" 2>&1 || die "shaderc configure failed, see $log"
    # LWJGL's patch force-loads these without depending on them, so build them first.
    cmake --build "$bdir" --target glslang glslang-default-resource-limits SPIRV-Tools-static SPIRV-Tools-opt \
        >>"$log" 2>&1 || die "shaderc build failed, see $log"
    # Export C functions by name. A pattern like _spv* would also catch
    # spvTargetEnvNameMap, a weak C++ table other libraries export too.
    { echo '_shaderc_*'
      nm -m "$bdir"/third_party/glslang/glslang/libglslang{,-default-resource-limits}.a \
          "$bdir"/third_party/spirv-tools/source/libSPIRV-Tools.a "$bdir"/third_party/spirv-tools/source/opt/libSPIRV-Tools-opt.a \
          | awk '$2 == "(__TEXT,__text)" && $3 == "external" && $4 ~ /^_(glslang_|spv|Sh)/ {print $4}' | sort -u
    } > "$exports"
    rm -f "$bdir"/libshaderc/libshaderc_shared*.dylib
    cmake --build "$bdir" --target shaderc_shared >>"$log" 2>&1 || die "shaderc build failed, see $log"
    finish "$bdir/libshaderc/libshaderc_shared.dylib" "$sdk" libshaderc.dylib

    say "$sdk: SPIRV-Cross"
    bdir="$OBJ/$sdk/spirv-cross"
    # shellcheck disable=SC2086
    cmake -S "$SRC/SPIRV-Cross" -B "$bdir" "${cmake_common[@]}" $SPVC_PARAMS >>"$log" 2>&1 \
        || die "SPIRV-Cross configure failed, see $log"
    cmake --build "$bdir" --target spirv-cross-c-shared >>"$log" 2>&1 || die "SPIRV-Cross build failed, see $log"
    finish "$bdir/libspirv-cross-c-shared.dylib" "$sdk" libspirv-cross.dylib
done

# Checks the platform, the dependencies and that every function LWJGL resolves
# is exported.
JAVAP="$ROOT/deps/graalvm/Contents/Home/bin/javap"
JARS="$BUILD/game/libraries/org/lwjgl"   # Mojang's LWJGL jars (scripts/fetch-minecraft.py)
for sdk in appletvos appletvsimulator; do
    [ "$sdk" = appletvos ] && plat=3 || plat=8
    for l in $LIBS; do
        f="$DST/$sdk/$l"
        bv=$(vtool -show-build "$f" | awk '/platform/{p=$2} /minos/{m=$2} END{print p, m}')
        [ "$bv" = "$plat $MINOS" ] || [ "$bv" = "$( [ $plat = 3 ] && echo TVOS || echo TVOSSIMULATOR) $MINOS" ] \
            || die "$sdk/$l is built for '$bv', expected platform $plat minos $MINOS"
        bad=$(otool -L "$f" | tail -n +3 | awk '{print $1}' | grep -vE '^/usr/lib/lib(c\+\+\.1|System\.B)\.dylib$' || true)
        [ -z "$bad" ] || die "$sdk/$l links $bad"
        # dyld merges exported weak symbols across libraries, so one of these
        # could end up using another library's copy of the same C++ code.
        ! xcrun dyld_info -exports "$f" | grep -q 'weak-def' || die "$sdk/$l exports weak symbols"
    done
done
if [ -x "$JAVAP" ] && [ -f "$JARS/lwjgl-shaderc/3.4.3/lwjgl-shaderc-3.4.3.jar" ]; then
    for pair in freetype:libfreetype.dylib shaderc:libshaderc.dylib spvc:libspirv-cross.dylib; do
        jar="$JARS/lwjgl-${pair%%:*}/3.4.3/lwjgl-${pair%%:*}-3.4.3.jar"
        # shellcheck disable=SC2046
        "$JAVAP" -c -constants -p -cp "$jar" $(unzip -Z1 "$jar" | sed -n 's#/#.#g; s/\$Functions\.class$/$Functions/p') \
            > "$OBJ/${pair%%:*}.javap"
        for sdk in appletvos appletvsimulator; do
            xcrun dyld_info -exports "$DST/$sdk/${pair#*:}" > "$OBJ/$sdk/${pair#*:}.exports"
            /usr/bin/python3 -I - "$OBJ/${pair%%:*}.javap" "$OBJ/$sdk/${pair#*:}.exports" "$sdk/${pair#*:}" <<'PY' \
                || die "$sdk/${pair#*:} is missing functions LWJGL needs"
import re, sys
need, optional, last = set(), set(), None
for line in open(sys.argv[1]):
    m = re.search(r'ldc.*// String (\S+)', line)
    if m:
        last = m.group(1)
    m = re.search(r'APIUtil\.apiGetFunctionAddress(Optional)?\b', line)
    if m:
        (optional if m.group(1) else need).add(last)
have = {l.split()[1][1:] for l in open(sys.argv[2]) if l.strip().startswith('0x')}
miss = sorted(need - have)
opt = sorted(optional - have)
print("    %s: %d of %d functions exported%s" % (sys.argv[3], len(need) - len(miss), len(need),
      ", optional missing: " + " ".join(opt) if opt else ""))
if miss:
    print("    missing: " + " ".join(miss))
    sys.exit(1)
PY
        done
    done
else
    say "skipping the export check (no GraalVM in deps/graalvm, or no LWJGL jars in build/game)"
fi

for sdk in appletvos appletvsimulator; do echo "$STAMP" > "$DST/$sdk/.stamp"; done
say "done: build/deps/thirdparty/{appletvos,appletvsimulator}/{${LIBS// /,}}"
