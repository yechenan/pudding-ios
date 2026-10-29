#!/usr/bin/env python3
"""Check the HFS+ volume header / journal of a raw image the way XNU's hfs does.

    python tools/hfs_journal_check.py IMG [IMG ...]

Why: a journaled HFSX volume that Linux's hfsplus driver cannot mount rw must be
built by (1) mkfs.hfsplus -J, (2) clearing the journaled bit so Linux can write,
(3) tar-in, (4) setting the bit back.  Before pushing such an image to the phone
we want to prove that the journal structure is what hfs_vfsutils.c /
hfs_journal.c expect, because the phone is the only place that can actually
mount it.

Checks (all read-only):
  * HFSX signature, block size, free blocks
  * if kHFSVolumeJournaledMask (0x2000) is set:
      - journalInfoBlock points inside the volume
      - JournalInfoBlock.flags has kJIJournalInFSMask (journal lives on this
        device) and offset/size are sane  [hfs_vfsutils.c hfs_early_journal_init]
      - journal header magic is 'JNLx' (either endianness: journal_open()
        accepts a byte-swapped header and swaps it)
      - 0 < start <= size, 0 < end <= size, start/end multiples of 512,
        256 KiB <= size <= 1 GiB, blhdr_size >= 0 and compatible with size
        [hfs_journal.c journal_open]
      - start == end  -> journal is empty (nothing to replay)
"""
import os
import struct
import sys

BE32 = lambda b, o=0: struct.unpack_from('>I', b, o)[0]
BE16 = lambda b, o=0: struct.unpack_from('>H', b, o)[0]
BE64 = lambda b, o=0: struct.unpack_from('>Q', b, o)[0]
LE32 = lambda b, o=0: struct.unpack_from('<i', b, o)[0]
LE64 = lambda b, o=0: struct.unpack_from('<q', b, o)[0]

VOL_JOURNALED = 0x2000
VOL_UNMOUNTED = 0x0100
VOL_INCONSISTENT = 0x0400
JI_IN_FS = 0x00000001
JI_OTHER_DEV = 0x00000002
JI_NEED_INIT = 0x00000004
JOURNAL_HEADER_MAGIC = 0x4A4E4C78   # 'JNLx'
OLD_JOURNAL_HEADER_MAGIC = 0x4A484452  # 'JHDR'


def check(path):
    rc = 0
    errs = []
    size = os.path.getsize(path)
    with open(path, 'rb') as f:
        f.seek(1024)
        vh = f.read(512)
        if vh[0:2] not in (b'H+', b'HX'):
            print('  !! no HFS/HFSX signature at 1024 (got %r)' % vh[0:2])
            return 1
        sig = vh[0:2].decode()
        ver = BE16(vh, 2)
        attrs = BE32(vh, 4)
        lastmnt = vh[8:12]
        jibblk = BE32(vh, 12)
        files, folders = struct.unpack_from('>II', vh, 32)
        bs, total, free = struct.unpack_from('>III', vh, 40)
        print('  volume: %s ver=%d attrs=0x%08x journaled=%s unmounted=%s inconsistent=%s'
              % (sig, ver, attrs, bool(attrs & VOL_JOURNALED), bool(attrs & VOL_UNMOUNTED),
                 bool(attrs & VOL_INCONSISTENT)))
        print('  lastMounted=%r  blockSize=%d total=%.2f GiB free=%.2f GiB fileCount=%d folderCount=%d'
              % (lastmnt, bs, bs * total / 2.0**30, bs * free / 2.0**30, files, folders))
        if bs * total > size:
            errs.append('volume header claims %d bytes but file is %d' % (bs * total, size))
        if not (attrs & VOL_JOURNALED):
            print('  NOT JOURNALED - nothing more to check')
            return 1 if errs else rc
        if jibblk == 0 or (jibblk + 1) * bs > size:
            errs.append('journalInfoBlock %d out of range' % jibblk)
            print('  !! %s' % errs[-1])
            return 1
        f.seek(jibblk * bs)
        jib = f.read(512)
        flags = BE32(jib, 0)
        joff = BE64(jib, 36)
        jsize = BE64(jib, 44)
        print('  jib @block %d (byte %d): flags=0x%08x inFS=%s otherDev=%s needInit=%s offset=%d size=%d (%.1f MiB)'
              % (jibblk, jibblk * bs, flags, bool(flags & JI_IN_FS), bool(flags & JI_OTHER_DEV),
                 bool(flags & JI_NEED_INIT), joff, jsize, jsize / 2.0**20))
        if not (flags & JI_IN_FS):
            errs.append('journal is not inside the filesystem (kJIJournalInFSMask clear)')
        if flags & JI_NEED_INIT:
            print('  journal marked kJIJournalNeedInitMask: hfs would journal_create() it at mount')
        if jsize < 256 * 1024 or jsize > 1024**3:
            errs.append('journal size %d outside [256KiB, 1GiB] (journal_open rejects)' % jsize)
        if joff % 512 or jsize % 512:
            errs.append('journal offset/size not 512-aligned')
        if joff + jsize > size:
            errs.append('journal [%d,%d) runs past EOF' % (joff, joff + jsize))
        if flags & JI_NEED_INIT:
            # hfs_late_journal_init / hfs_early_journal_init call journal_create() and never
            # reach journal_open(), so an all-zero journal header here is expected: mkfs has
            # not initialized it yet, XNU will.
            print('  journal header not initialized by mkfs - XNU will journal_create() it at mount')
        elif joff:
            f.seek(joff)
            jh = f.read(64)
            magic_le = LE32(jh, 0)
            magic_be = struct.unpack_from('>i', jh, 0)[0]
            swapped = magic_le != JOURNAL_HEADER_MAGIC and magic_le != OLD_JOURNAL_HEADER_MAGIC
            use = (lambda o, n: struct.unpack_from('>' + n, jh, o)[0]) if swapped else \
                  (lambda o, n: struct.unpack_from('<' + n, jh, o)[0])
            magic = use(0, 'i')
            endian = use(4, 'i')
            start = use(8, 'q')
            end = use(16, 'q')
            jhsize = use(24, 'q')
            blhdr = use(32, 'i')
            cksum = use(36, 'i')
            jhdrsz = use(40, 'i')
            seq = use(44, 'i')
            print('  journal header @%d: magic=0x%08x (%s) %s endian=0x%08x start=0x%x end=0x%x size=0x%x blhdr=%d jhdr_size=%d seq=%d'
                  % (joff, magic & 0xffffffff,
                     'JNLx' if magic == JOURNAL_HEADER_MAGIC else ('JHDR' if magic == OLD_JOURNAL_HEADER_MAGIC else 'BAD'),
                     'byte-swapped' if swapped else 'native', endian & 0xffffffff, start, end, jhsize, blhdr, jhdrsz, seq))
            if magic not in (JOURNAL_HEADER_MAGIC, OLD_JOURNAL_HEADER_MAGIC):
                errs.append('journal header magic is bad (journal_open rejects)')
            if not (0 < start <= jhsize):
                errs.append('jhdr start 0x%x out of (0, size]' % start)
            if not (0 < end <= jhsize):
                errs.append('jhdr end 0x%x out of (0, size]' % end)
            if start % 512 or end % 512:
                errs.append('jhdr start/end not multiples of 512')
            if jhsize < 256 * 1024 or jhsize > 1024**3:
                errs.append('jhdr size 0x%x outside [256KiB,1GiB]' % jhsize)
            if blhdr < 0:
                errs.append('blhdr_size negative')
            elif jhdrsz > 0 and (blhdr // 16 - 1) > (jhsize // jhdrsz):
                errs.append('blhdr_size/jhdr_size incompatible (journal_open rejects)')
            if jhdrsz and jhdrsz != bs:
                print('  note: jhdr_size %d != fs blockSize %d (journal_open would switch block size)' % (jhdrsz, bs))
            if jhsize != jsize:
                errs.append('jib size %d != jhdr size %d' % (jsize, jhsize))
            if start == end:
                print('  journal is EMPTY (start==end): nothing to replay')
            else:
                print('  journal is NOT empty (start=0x%x end=0x%x): a replay will happen on mount'
                      % (start, end))
                # replay is fine only if the journal really holds our transactions; after a
                # Linux tar-in it never does, so treat this as an error.
                errs.append('journal not empty after a non-journaled (Linux) copy')
    for e in errs:
        print('  !! %s' % e)
    return 1 if errs else 0


def main(argv):
    rc = 0
    for p in argv[1:]:
        print('== %s (%d bytes)' % (p, os.path.getsize(p)))
        try:
            rc |= check(p)
        except Exception as exc:  # noqa: BLE001 - report and keep going
            print('  !! exception: %s' % exc)
            rc = 1
    return rc


if __name__ == '__main__':
    sys.exit(main(sys.argv))
