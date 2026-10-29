#!/usr/bin/env python3
"""Flip kHFSVolumeJournaledMask (0x2000) in the HFS+ volume header of a raw image.

    python tools/hfs_set_journal_bit.py IMG off|on [--dry-run]

Why this exists: Linux's hfsplus driver (what libguestfs/guestmount use) refuses to
mount a journaled HFS+ volume read-write, so `tar-in` into a fresh `mkfs.hfsplus -J`
volume fails with "Read-only file system".  The copy is therefore done with the
journaled bit temporarily cleared:

    mkfs.hfsplus -J ... -> bit off -> tar-in -> fsck -> bit on

Clearing the bit does not touch the journal structures (JournalInfoBlock at
vhp->journalInfoBlock, the .journal / .journal_info_block files); mkfs leaves
kJIJournalNeedInitMask set, so the first XNU mount runs hfs_late_journal_init ->
journal_create() and builds a valid, empty journal header itself.  That is why we
never need the (all-zero) journal header that mkfs leaves behind.

The volume header lives at byte 1024; attributes is a big-endian u32 at 1028.
"""
import os
import struct
import sys

VOL_JOURNALED = 0x2000
VOL_UNMOUNTED = 0x0100
VOL_INCONSISTENT = 0x0400


def main(argv):
    if len(argv) < 3 or argv[2] not in ('on', 'off'):
        print(__doc__)
        return 2
    path, want = argv[1], argv[2] == 'on'
    dry = '--dry-run' in argv[3:]
    if not os.path.isfile(path):
        print('no such file: %s' % path)
        return 2
    with open(path, 'r+b') as f:
        f.seek(1024)
        vh = bytearray(f.read(512))
        if vh[0:2] not in (b'H+', b'HX'):
            print('no HFS/HFSX signature at 1024 (got %r)' % bytes(vh[0:2]))
            return 1
        attrs = struct.unpack_from('>I', vh, 4)[0]
        print('%s: %s ver=%d attrs=0x%08x journaled=%s unmounted=%s'
              % (path, vh[0:2].decode(), struct.unpack_from('>H', vh, 2)[0], attrs,
                 bool(attrs & VOL_JOURNALED), bool(attrs & VOL_UNMOUNTED)))
        if bool(attrs & VOL_JOURNALED) == want:
            print('already %s - nothing to do' % ('journaled' if want else 'non-journaled'))
            return 0
        new = (attrs | VOL_JOURNALED) if want else (attrs & ~VOL_JOURNALED)
        print('attrs 0x%08x -> 0x%08x' % (attrs, new))
        if dry:
            print('--dry-run: not writing')
            return 0
        struct.pack_into('>I', vh, 4, new)
        f.seek(1024)
        f.write(vh)
        f.flush()
        os.fsync(f.fileno())
    # read back
    with open(path, 'rb') as f:
        f.seek(1024)
        vh2 = f.read(8)
    attrs2 = struct.unpack_from('>I', vh2, 4)[0]
    ok = bool(attrs2 & VOL_JOURNALED) == want
    print('read back: attrs=0x%08x journaled=%s  %s' % (attrs2, bool(attrs2 & VOL_JOURNALED),
                                                      'OK' if ok else 'MISMATCH'))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
