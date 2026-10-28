#!/usr/bin/env python3
"""Decode an iOS 16 restore DMG (UDIF with LZFSE chunks) into a raw disk image.

The DMG trailer is a plist with one "blkx" (mish) table per partition.  The
tables are big-endian; header 200 bytes, then a u32 run count and the runs:

    u32 type, u32 comment, u64 sector, u64 sectorCount, u64 offset, u64 length
    0x00000000 zero fill, 0x00000001 raw, 0x8000000X compressed (LZFSE here),
    0xFFFFFFFF end of table

Runs are written at their sector offsets, so holes stay holes.

    decode_ios_dmg.py IN.dmg OUT.img
"""
import ctypes
import plistlib
import struct
import sys

LIB = '/root/liblzfse_one.so'
RAW, ZERO, END, SKIP = 0x00000001, 0x00000000, 0xFFFFFFFF, 0x00000002
RUN = 40
HEADER = 200

lib = ctypes.CDLL(LIB)
lib.lzfse_dec_one.restype = ctypes.c_size_t
lib.lzfse_dec_one.argtypes = [
    ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t,
    ctypes.POINTER(ctypes.c_size_t), ctypes.POINTER(ctypes.c_int)]

buf = (ctypes.c_char * (16 << 20))()
consumed = ctypes.c_size_t(0)
status = ctypes.c_int(-1)


def lzfse(src, expected):
    n = lib.lzfse_dec_one(src, len(src), buf, len(buf),
                          ctypes.byref(consumed), ctypes.byref(status))
    if status.value != 0:
        return None
    return buf[:n]


def parse_table(mish):
    first_sector, sector_count = struct.unpack_from('>QQ', mish, 8)
    runs = []
    for base in (HEADER + 4, HEADER):
        try:
            t, _c, sec, cnt, off, length = struct.unpack_from('>IIQQQQ', mish, base)
        except struct.error:
            continue
        if t in (RAW, ZERO) or (t & 0x80000000):
            count = struct.unpack_from('>I', mish, HEADER)[0] if base == HEADER + 4 else 0
            p = base
            while p + RUN <= len(mish):
                t, _c, sec, cnt, off, length = struct.unpack_from('>IIQQQQ', mish, p)
                if t == END:
                    break
                runs.append((t, sec, cnt, off, length))
                p += RUN
            if runs:
                return first_sector, sector_count, runs
    raise SystemExit('cannot parse mish table')


def main(src_path, dst_path):
    data = open(src_path, 'rb').read()
    start = data.rfind(b'<?xml')
    end = data.find(b'</plist>', start)
    plist = plistlib.loads(data[start:end + len(b'</plist>')])
    tables = plist['resource-fork']['blkx']

    out = open(dst_path, 'wb')
    written = 0
    for entry in tables:
        first_sector, sector_count, runs = parse_table(entry['Data'])
        print('%-20s sector %d + %d, %d runs' %
              (entry.get('CFName', '?'), first_sector, sector_count, len(runs)))
        for t, sec, cnt, off, length in runs:
            dst = (first_sector + sec) * 512
            size = cnt * 512
            if t in (ZERO, SKIP) or size == 0:
                continue
            if t == RAW:
                chunk = data[off:off + length]
            else:
                chunk = lzfse(data[off:off + length], size)
                if chunk is None:
                    raise SystemExit('run type %#x at sector %d failed to decode' % (t, sec))
            if len(chunk) != size:
                raise SystemExit('run at sector %d: %d bytes, expected %d' %
                                 (sec, len(chunk), size))
            out.seek(dst)
            out.write(chunk)
            written += size
        out.truncate(max(out.tell(), (first_sector + sector_count) * 512))
    out.close()

    # The GPT's alternate header is the last structure in the image.
    with open(dst_path, 'rb+') as f:
        f.seek(512)
        alt = struct.unpack_from('<Q', f.read(512), 32)[0]
        f.truncate((alt + 1) * 512)
    print('wrote %d bytes (%d MiB) of runs' % (written, written >> 20))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1], sys.argv[2]))
