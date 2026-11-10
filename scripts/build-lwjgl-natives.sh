#!/usr/bin/env bash
# LWJGL 3.4.3's own natives, which nobody ships for tvOS. Built for tvOS and
# its simulator from LWJGL's tag, with the flags of its macOS build, into
# build/deps/lwjgl/<sdk>. patches/lwjgl has two changes from AngelAuraMC's iOS fork.
#
#   scripts/build-lwjgl-natives.sh
source "$(dirname "$0")/lib.sh"

LWJGL_TAG=3.4.3
LWJGL_COMMIT=30fac9b95f99cda97312232be25ba55297bf9951   # what Mojang's 3.4.3 natives say they're built from
FFI_VERSION=3.8.0   # what LWJGL-CI builds for 3.4.3
FFI_SHA256=7da3e2d9a171eb0a038f592ecad3ff2bb2550f3496d87b3b29ad0cf4430c0db4
MINOS=26.0

DEPS="$ROOT/deps/lwjgl3"
LW="$DEPS/lwjgl3"
FFI="$DEPS/libffi-$FFI_VERSION"
OUTDIR="$BUILD/deps/lwjgl"
JARS="$BUILD/game/libraries/org/lwjgl"   # Mojang's LWJGL jars (scripts/fetch-minecraft.py)
JOBS=$(sysctl -n hw.ncpu)
JDK="$ROOT/deps/graalvm/Contents/Home"   # for the JNI headers (scripts/setup.sh installs it)
[ -f "$JDK/include/darwin/jni_md.h" ] || die "no JNI headers in $JDK/include. Run scripts/setup.sh"
mkdir -p "$DEPS"

# Sources ---------------------------------------------------------------------
if [ "$(git -C "$LW" rev-parse HEAD 2>/dev/null)" != "$LWJGL_COMMIT" ]; then
    say "cloning LWJGL $LWJGL_TAG"
    rm -rf "$LW"
    git init -q "$LW"
    git -C "$LW" fetch -q --depth 1 https://github.com/LWJGL/lwjgl3 "refs/tags/$LWJGL_TAG"
    git -C "$LW" -c advice.detachedHead=false checkout -q FETCH_HEAD
    [ "$(git -C "$LW" rev-parse HEAD)" = "$LWJGL_COMMIT" ] || die "tag $LWJGL_TAG isn't commit $LWJGL_COMMIT"
fi
git -C "$LW" checkout -q -- modules   # undo the last run's patches

if [ ! -f "$FFI/configure" ]; then
    tgz="$DEPS/libffi-$FFI_VERSION.tar.gz"
    [ -f "$tgz" ] || curl -fsSL -o "$tgz" "https://github.com/libffi/libffi/releases/download/v$FFI_VERSION/libffi-$FFI_VERSION.tar.gz"
    echo "$FFI_SHA256  $tgz" | shasum -a 256 -c --status || { rm -f "$tgz"; die "libffi tarball checksum mismatch"; }
    tar -xzf "$tgz" -C "$DEPS"
fi

apply_patches "$LW" "$ROOT/patches/lwjgl"

# Build -----------------------------------------------------------------------
M="$LW/modules/lwjgl"
for target in appletvsimulator:arm64-apple-tvos$MINOS-simulator appletvos:arm64-apple-tvos$MINOS; do
    sdk="${target%%:*}"
    TARGET=(-target "${target#*:}" -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)")
    CC=$(xcrun --sdk "$sdk" -f clang)
    CXX=$(xcrun --sdk "$sdk" -f clang++)
    work="$DEPS/work/$sdk"
    out="$OUTDIR/$sdk"
    rm -rf "$work" "$out"
    mkdir -p "$work/libffi" "$out"

    say "$sdk: libffi $FFI_VERSION"
    (cd "$work/libffi" && "$FFI/configure" --host=aarch64-apple-darwin --disable-shared --disable-docs \
        CC="$CC" CFLAGS="${TARGET[*]} -O2" LDFLAGS="${TARGET[*]}" >configure.log 2>&1) \
        || die "libffi configure failed, see $work/libffi/config.log"
    grep -q '^#define FFI_EXEC_TRAMPOLINE_TABLE 1' "$work/libffi/fficonfig.h" || die "libffi isn't using its trampoline table"
    make -C "$work/libffi" -j"$JOBS" >"$work/libffi/make.log" 2>&1 || die "libffi build failed, see $work/libffi/make.log"

    # Same flags as LWJGL's macOS build, with tvOS in place of macOS.
    COMMON=(-O3 -flto=auto -fPIC -DNDEBUG -DLWJGL_MACOS -DLWJGL_arm64 "${TARGET[@]}"
            -I"$JDK/include" -I"$JDK/include/darwin" -I"$M/core/src/main/c" -I"$M/core/src/main/c/macos")
    # build <module> <c|c++> <warning flags> <include dirs...> -- <sources...> [-- <link args...>]
    build() {
        local module="$1" lang="$2" warn="$3" name obj cc
        shift 3
        local inc=() src=() link=()
        while [ "$1" != -- ]; do inc+=(-I"$1"); shift; done; shift
        while [ $# -gt 0 ] && [ "$1" != -- ]; do src+=("$1"); shift; done
        [ $# -gt 0 ] && { shift; link=("$@"); }
        name=$([ "$module" = core ] && echo lwjgl || echo "lwjgl_$module")
        obj="$work/$module"
        mkdir -p "$obj"
        if [ "$lang" = c ]; then cc=("$CC" -c -ObjC); else cc=("$CXX" -c -std=c++20); fi
        # shellcheck disable=SC2086
        (cd "$obj" && printf '%s\0' "${src[@]}" | xargs -0 -n 8 -P "$JOBS" "${cc[@]}" "${COMMON[@]}" $warn "${inc[@]}") \
            || die "$sdk: compiling $module failed"
        "$([ "$lang" = c ] && echo "$CC" || echo "$CXX")" -dynamiclib -Wl,-no_compact_unwind "${TARGET[@]}" \
            -O3 -flto=auto -fPIC -install_name "@rpath/lib$name.dylib" -o "$out/lib$name.dylib" \
            "$obj"/*.o ${link[@]+"${link[@]}"} || die "$sdk: linking $module failed"
        strip -u -r "$out/lib$name.dylib"
        codesign -f -s - "$out/lib$name.dylib" 2>/dev/null
    }

    say "$sdk: compiling LWJGL $LWJGL_TAG natives"
    build core c "-Werror -Wfatal-errors -Wall -Wextra -pedantic" \
        "$M/core/src/main/c/libffi" "$M/core/src/main/c/libffi/aarch64" -- \
        "$M"/core/src/main/c/*.c "$M"/core/src/generated/c/*.c "$M"/core/src/generated/c/macos/*.c \
        "$M"/jawt/src/generated/c/*.c -- \
        -framework CoreFoundation "$work/libffi/.libs/libffi_convenience.a"
    build opengl c "-Werror -Wfatal-errors" "$M/opengl/src/main/c" -- \
        $(ls "$M"/opengl/src/generated/c/* | grep -v '/org_lwjgl_opengl_WGL\.c$')
    build stb c "-Werror -Wfatal-errors" "$M/stb/src/main/c" -- "$M"/stb/src/generated/c/*
    build vma c++ "-Werror -Wfatal-errors" "$M/vma/src/main/c" "$M/vulkan/src/main/c" -- \
        "$M"/vma/src/generated/c/*.cpp
done

# Checks ----------------------------------------------------------------------
for target in appletvsimulator:TVOSSIMULATOR appletvos:TVOS; do
    sdk="${target%%:*}"
    for f in "$OUTDIR/$sdk"/*.dylib; do
        vtool -show-build "$f" | grep -q "platform ${target#*:}$" || die "$f isn't built for ${target#*:}"
        vtool -show-build "$f" | grep -q "minos $MINOS$" || die "$f doesn't have minos $MINOS"
        bad=$(otool -L "$f" | tail -n +2 | awk '{print $1}' | grep -v -E \
            '^(@rpath/liblwjgl[_a-z]*\.dylib|/usr/lib/libSystem\.B\.dylib|/usr/lib/libc\+\+\.1\.dylib|/System/Library/Frameworks/CoreFoundation\.framework/CoreFoundation)$' || true)
        [ -z "$bad" ] || die "$f links $bad"
    done
done

# Every native method in Mojang's 3.4.3 jars must be exported, except other
# platforms' ones.
jar() { echo "$JARS/$1/$LWJGL_TAG/$1-$LWJGL_TAG.jar"; }
if [ -f "$(jar lwjgl)" ]; then
    for sdk in appletvsimulator appletvos; do
        d="$OUTDIR/$sdk"
        say "$sdk: JNI exports against the $LWJGL_TAG jars"
        /usr/bin/python3 -I - \
            "$(jar lwjgl)" "$d/liblwjgl.dylib" '^org\.lwjgl\.system\.(linux|windows|freebsd)\.' \
            "$(jar lwjgl-opengl)" "$d/liblwjgl_opengl.dylib" '^org\.lwjgl\.opengl\.WGL\.' \
            "$(jar lwjgl-stb)" "$d/liblwjgl_stb.dylib" '^$' \
            "$(jar lwjgl-vma)" "$d/liblwjgl_vma.dylib" '^org\.lwjgl\.util\.vma\.Vma\.nvmaGetMemoryWin32Handle' \
            <<'PY' || die "$sdk: JNI exports don't match the jars"
import re, struct, subprocess, sys, zipfile

def natives(data):  # (name, descriptor) of each native method in a class file
    count, cp, pos, i = struct.unpack(">H", data[8:10])[0], {}, 10, 1
    while i < count:
        tag = data[pos]
        if tag == 1:
            n = struct.unpack(">H", data[pos + 1:pos + 3])[0]
            cp[i] = data[pos + 3:pos + 3 + n].decode("utf-8", "replace")
            pos += 3 + n
        elif tag in (3, 4, 9, 10, 11, 12, 17, 18): pos += 5
        elif tag in (5, 6): pos += 9; i += 1
        elif tag in (7, 8, 16, 19, 20): pos += 3
        elif tag == 15: pos += 4
        else: raise ValueError("constant pool tag %d" % tag)
        i += 1
    pos += 6
    pos += 2 + 2 * struct.unpack(">H", data[pos:pos + 2])[0]
    found = []
    for methods in (False, True):
        n = struct.unpack(">H", data[pos:pos + 2])[0]; pos += 2
        for _ in range(n):
            acc, name, desc, nattr = struct.unpack(">HHHH", data[pos:pos + 8]); pos += 8
            for _ in range(nattr):
                pos += 6 + struct.unpack(">I", data[pos + 2:pos + 6])[0]
            if methods and acc & 0x0100:
                found.append((cp[name], cp[desc]))
    return found

def mangle(s):
    m = {"/": "_", "_": "_1", ";": "_2", "[": "_3"}
    return "".join(m.get(c) or (c if c.isascii() and c.isalnum() else "_0%04x" % ord(c)) for c in s)

failed = False
args = sys.argv[1:]
for jar, dylib, allowed in zip(args[0::3], args[1::3], args[2::3]):
    exports = set(subprocess.check_output(["xcrun", "dyld_info", "-exports", dylib], text=True).split())
    total, skipped, missing = 0, 0, []
    with zipfile.ZipFile(jar) as z:
        for e in z.namelist():
            if not e.endswith(".class") or e.startswith("META-INF/"):
                continue
            for name, desc in natives(z.read(e)):
                total += 1
                short = "_Java_" + mangle(e[:-6]) + "_" + mangle(name)
                if short in exports or short + "__" + mangle(desc[1:desc.index(")")]) in exports:
                    continue
                java = e[:-6].replace("/", ".") + "." + name + desc
                if re.match(allowed, java):
                    skipped += 1
                else:
                    missing.append(java)
    print("    %-22s %4d natives, %3d for other platforms, %d missing" % (dylib.split("/")[-1], total, skipped, len(missing)))
    for m in missing:
        print("      missing " + m)
    failed |= bool(missing)
sys.exit(1 if failed else 0)
PY
    done
else
    say "no LWJGL $LWJGL_TAG jars in $JARS, skipping the JNI check (scripts/fetch-minecraft.py 26.3 build/game fetches them)"
fi

ls -l "$OUTDIR"/*/*.dylib
say "done: build/deps/lwjgl/{appletvsimulator,appletvos}"
