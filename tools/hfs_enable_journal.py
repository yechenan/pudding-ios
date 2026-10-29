#!/usr/bin/env python3
"""Turn on HFS+ journaling on an existing volume image, without rewriting any data.

    python tools/hfs_enable_journal.py IMG [--dry-run]

Why this instead of mkfs + tar: the iOS root image we have was formatted journaled
by Apple's newfs (it still carries /.journal, /.journal_info_block, a valid
JournalInfoBlock at vhp->journalInfoBlock and an 8 MiB journal file).  The journaled
bit was cleared later only so Linux's hfsplus driver (libguestfs) would mount it
read-write (MISTAKES #6).  All the structures are still there and valid, so turning
journaling back on is exactly what `diskutil enableJournal` does: set
kHFSVolumeJournaledMask and let the next mount build the journal.

Two edits, both 4 bytes:
  1. volume header attributes (byte 1028, BE32) |= 0x2000 kHFSVolumeJournaledMask
  2. JournalInfoBlock flags (at vhp->journalInfoBlock * blockSize) |= 0x4
     kJIJournalNeedInitMask  -> tells XNU to journal_create() a fresh, consistent
     journal header instead of trusting the stale one (the one on disk was written
     with jhdr_size=512 by the formatter, which would make journal_open() switch the
     device block size; journal_create() rebuilds it for the real 4 KiB device).

hfs_late_journal_init (hfs_vfsutils.c:2683) then: finds /.journal_info_block and
/.journal by name in the root directory, checks their extents against the JIB
(self-healing if they differ), and since needInit is set calls journal_create()
(hfs_journal.c:1814) which writes a clean header (start == end == blockSize) and
clears the bit.  If any of that fails the mount still proceeds without journaling,
i.e. the worst case is today's behaviour, not a brick.
"""
import os
import struct
import sys

VOL_JOURNALED = 0x2000
JI_IN_FS = 0x00000001
JI_NEED_INIT = 0x00000004


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    path = argv[1]
    dry = '--dry-run' in argv[2:]
    if not os.path.isfile(path):
        print('no such file: %s' % path)
        return 2
    with open(path, 'r+b') as f:
        f.seek(1024)
        vh = bytearray(f.read(512))
        if vh[0:2] not in (b'H+', b'HX'):
            print('no HFS/HFSX signature at 1024 (got %r)' % bytes(vh[0:2]))
            return 1
        ver = struct.unpack_from('>H', vh, 2)[0]
        attrs = struct.unpack_from('>I', vh, 4)[0]
        jibblk = struct.unpack_from('>I', vh, 12)[0]
        bs, total = struct.unpack_from('>II', vh, 40)
        print('%s: %s v%d attrs=0x%08x journaled=%s blockSize=%d jibblk=%d'
              % (path, vh[0:2].decode(), ver, attrs, bool(attrs & VOL_JOURNALED), bs, jibblk))
        if bs * total != os.path.getsize(path):
            print('!! volume header geometry (%d x %d) does not match file size %d'
                  % (bs, total, os.path.getsize(path)))
            return 1
        if jibblk == 0 or (jibblk + 1) * bs > os.path.getsize(path):
            print('!! journalInfoBlock %d out of range' % jibblk)
            return 1
        f.seek(jibblk * bs)
        jib = bytearray(f.read(512))
        jflags = struct.unpack_from('>I', jib, 0)[0]
        joff = struct.unpack_from('>Q', jib, 36)[0]
        jsize = struct.unpack_from('>Q', jib, 44)[0]
        print('  JIB @%d: flags=0x%08x inFS=%s needInit=%s offset=%d size=%d (%.1f MiB)'
              % (jibblk * bs, jflags, bool(jflags & JI_IN_FS), bool(jflags & JI_NEED_INIT),
                 joff, jsize, jsize / 2.0**20))
        if not (jflags & JI_IN_FS):
            print('!! JIB says the journal is on another device; refusing')
            return 1
        if jsize < 256 * 1024 or jsize > 1024**3:
            print('!! journal size %d is outside what journal_open accepts' % jsize)
            return 1
        if joff % bs or jsize % bs:
            print('!! journal offset/size not a multiple of the block size')
            return 1
        if joff + jsize > os.path.getsize(path):
            print('!! journal runs past EOF')
            return 1

        new_attrs = attrs | VOL_JOURNALED
        new_jflags = jflags | JI_NEED_INIT
        print('  edits: attrs 0x%08x -> 0x%08x ; jib flags 0x%08x -> 0x%08x'
              % (attrs, new_attrs, jflags, new_jflags))
        if dry:
            print('--dry-run: not writing')
            return 0
        struct.pack_into('>I', vh, 4, new_attrs)
        f.seek(1024)
        f.write(vh)
        struct.pack_into('>I', jib, 0, new_jflags)
        f.seek(jibblk * bs)
        f.write(jib)
        f.flush()
        os.fsync(f.fileno())

    with open(path, 'rb') as f:
        f.seek(1024)
        vh2 = f.read(512)
        a2 = struct.unpack_from('>I', vh2, 4)[0]
        jb2 = struct.unpack_from('>I', vh2, 12)[0]
        f.seek(jb2 * bs)
        jf2 = struct.unpack_from('>I', f.read(4))[0]
    ok = bool(a2 & VOL_JOURNALED) and bool(jf2 & JI_NEED_INIT)
    print('  read back: attrs=0x%08x jib flags=0x%08x  %s' % (a2, jf2, 'OK' if ok else 'MISMATCH'))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
