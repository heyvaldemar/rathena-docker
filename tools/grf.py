#!/usr/bin/env python3
# Minimal GRF reader — enough to find a string inside Ragnarok's data archives.
#
# WHY THIS EXISTS. The client opens the pack author's YouTube channel when the
# in-game settings window is closed. Nothing in Ragnarok.exe, in any DLL, in
# data/ or System/ contains that address, in either ASCII or UTF-16 — checked.
# That leaves the GRF archives, whose entries are zlib-compressed, so a plain
# string search over the 2.5 GB file finds nothing no matter how the bytes are
# encoded. To see inside, the container has to be understood.
#
# FORMAT (version 0x200), from the header outwards:
#   0x00  "Master of Magic\0"           16 bytes
#   0x10  encryption watermark          14 bytes
#   0x1E  file-table offset             uint32, relative to 46
#   0x22  seed                          uint32
#   0x26  filecount + seed + 7          uint32
#   0x2A  version                       uint32  (0x200)
# At 46 + table offset: compressed size, uncompressed size, then a zlib blob of
# entries. Each entry is a NUL-terminated name followed by 17 bytes:
#   compressed size, compressed size aligned, real size, flags, offset.
import struct, sys, zlib


def entries(path):
    f = open(path, "rb")
    head = f.read(46)
    if head[:15] != b"Master of Magic":
        raise SystemExit("%s is not a GRF" % path)
    table_off, seed, count_raw, version = struct.unpack_from("<IIII", head, 30)
    count = count_raw - seed - 7
    f.seek(46 + table_off)
    packed, unpacked = struct.unpack("<II", f.read(8))
    table = zlib.decompress(f.read(packed))
    if len(table) != unpacked:
        raise SystemExit("table size mismatch: %d vs %d" % (len(table), unpacked))

    pos = 0
    for _ in range(count):
        end = table.index(b"\0", pos)
        name = table[pos:end]
        pos = end + 1
        csize, csize_aligned, rsize, flags, offset = struct.unpack_from("<IIIBI", table, pos)
        pos += 17
        yield f, name, csize, rsize, flags, offset


def read(f, csize, rsize, flags, offset):
    """Entry contents, or None when it is not a plain deflated file.

    flag 1 means "this is a file"; flags 2 and 4 mark the DES-encrypted forms
    used by old archives. Those are skipped rather than half-decoded — this tool
    exists to search, not to be a complete implementation, and saying so beats
    returning silence that looks like "not found".
    """
    if not flags & 1 or flags & 6:
        return None
    f.seek(46 + offset)
    try:
        return zlib.decompress(f.read(csize))
    except zlib.error:
        return None
