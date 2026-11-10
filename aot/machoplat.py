"""Relabels Mach-O objects for another Apple platform, in place, and says
which platforms one is for.

    python3 -I aot/machoplat.py <platform> <minos> <sdk> <file.o>...

The platform is LC_BUILD_VERSION's number (3 tvOS, 8 tvOS simulator). macOS and
tvOS share the arm64 ABI, so an object built for one links for the other once
its build version says so. Objects without a build version (native-image's own)
are left alone. Idea from NucleusFramework/graalvm-mobile (MIT).
"""
import struct
import sys

LC_BUILD_VERSION = 0x32
TVOS, TVOS_SIMULATOR = 3, 8


def version(text):
    parts = [int(p) for p in text.split(".")] + [0, 0]
    return parts[0] << 16 | parts[1] << 8 | parts[2]


PLATFORMS = {1: "macOS", 2: "iOS", 3: "tvOS", 4: "watchOS", 6: "Mac Catalyst", 7: "iOS simulator",
             8: "tvOS simulator", 9: "watchOS simulator", 11: "visionOS", 12: "visionOS simulator"}
LC_VERSION_MIN = {0x24: "macOS", 0x25: "iOS", 0x2F: "tvOS", 0x30: "watchOS"}


def platforms(data):
    """The platforms a Mach-O file (or each slice of a universal one) is built for, by name."""
    if data[:4] == b"\xca\xfe\xba\xbe":  # universal: big-endian header, then (cputype, subtype, offset, size, align) per slice
        count = struct.unpack_from(">I", data, 4)[0]
        out = set()
        for i in range(count):
            offset, size = struct.unpack_from(">II", data, 8 + i * 20 + 8)
            out |= platforms(data[offset:offset + size])
        return out
    if len(data) < 32 or struct.unpack_from("<I", data, 0)[0] != 0xFEEDFACF:
        return set()
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off, out = 32, set()
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd == LC_BUILD_VERSION:
            p = struct.unpack_from("<I", data, off + 8)[0]
            out.add(PLATFORMS.get(p, "platform %d" % p))
        elif cmd in LC_VERSION_MIN:
            out.add(LC_VERSION_MIN[cmd])
        off += size
    return out


def relabel(paths, platform, minos, sdk):
    for path in paths:
        data = bytearray(open(path, "rb").read())
        magic, _, _, _, ncmds = struct.unpack_from("<IiiII", data, 0)
        if magic != 0xFEEDFACF:
            raise ValueError("%s isn't a 64-bit Mach-O file" % path)
        off, found = 32, False
        for _ in range(ncmds):
            cmd, size = struct.unpack_from("<II", data, off)
            if cmd == LC_BUILD_VERSION:
                struct.pack_into("<III", data, off + 8, platform, version(minos), version(sdk))
                found = True
            off += size
        if found:
            with open(path, "wb") as f:
                f.write(data)


if __name__ == "__main__":
    relabel(sys.argv[4:], int(sys.argv[1]), sys.argv[2], sys.argv[3])
