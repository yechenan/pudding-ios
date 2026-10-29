#!/usr/bin/env python3
"""Patch one function inside a dyld shared cache subcache, keeping the code signature valid.

    tools/patch_dyld_cache.py SUB_CACHE VMA HEXBYTES [--out FILE] [--dry-run]

SUB_CACHE   e.g. work-dyld/dyld_shared_cache_arm64.21
VMA         the function's virtual address as printed by llvm-objdump (e.g. 0x1c5aa5d58)
HEXBYTES    little-endian bytes to write at that address, e.g. "c0035fd6" (ret)

Why the hash: the kernel's 4K code-signing path (XNU_NATIVE_CS_HASH_CACHE) authenticates every
original 16 KiB block against the hash stored in the cache's CodeDirectory. Patching code without
recomputing that block's hash makes the whole cache fail with `check_signature: error = 85` and
launchd dies ("dyld cache not loaded"). This tool:

  1. maps VMA -> file offset through the subcache's own mapping table (main cache mapping is at
     header+16; entries are {u64 addr, u64 size, u64 fileoff, u32 maxprot, u32 initprot}),
  2. refuses unless the bytes at that offset are what the caller expects,
  3. writes the new bytes,
  4. recomputes the SHA-256 of the covering 16 KiB block,
  5. checks that the CodeDirectory slot currently holds the *original* block's hash (safety),
     then stores the new one.

Use --dry-run first: it prints the mapped offset, the current bytes and the hash slot.
"""
import argparse
import hashlib
import struct
import sys

MAGIC = b'dyld_v1'
SUPERBLOB = 0xfade0cc0
CSSLOT_CODEDIRECTORY = 0


def vma_to_offset(d, vma):
    if not d.startswith(MAGIC):
        sys.exit('not a dyld cache file (magic)')
    mapping_off, mapping_count = struct.unpack_from('<II', d, 16)
    if mapping_count == 0 or mapping_count > 64:
        sys.exit(f'implausible mapping count {mapping_count}')
    for i in range(mapping_count):
        addr, size, fileoff, maxp, initp = struct.unpack_from('<QQQII', d, mapping_off + 32 * i)
        if addr <= vma < addr + size:
            return fileoff + (vma - addr)
    sys.exit(f'VMA {vma:#x} is not inside any mapping of this file')


def code_directory(d):
    i = d.rfind(struct.pack('>I', SUPERBLOB))
    if i < 0:
        sys.exit('no CS_SuperBlob in this file')
    magic, length, count = struct.unpack_from('>III', d, i)
    for k in range(count):
        t, o = struct.unpack_from('>II', d, i + 12 + 8 * k)
        if t == CSSLOT_CODEDIRECTORY:
            cd = i + o
            fields = struct.unpack_from('>IIIIIIIII', d, cd)
            if fields[0] != 0xfade0c02:
                sys.exit('CodeDirectory magic mismatch')
            return cd, fields
    sys.exit('no CodeDirectory slot in the SuperBlob')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('subcache')
    ap.add_argument('vma')
    ap.add_argument('bytes')
    ap.add_argument('--out')
    ap.add_argument('--dry-run', action='store_true')
    a = ap.parse_args()

    vma = int(a.vma, 0)
    new = bytes.fromhex(a.bytes)
    if not new:
        sys.exit('empty replacement')
    d = bytearray(open(a.subcache, 'rb').read())
    off = vma_to_offset(d, vma)
    if off + len(new) > len(d):
        sys.exit('replacement runs past the end of the file')
    old_bytes = bytes(d[off:off + len(new)])
    print(f'VMA {vma:#x} -> file offset {off} ({off:#x})')
    print(f'  current bytes: {old_bytes.hex()}')
    print(f'  new bytes    : {new.hex()}')
    if old_bytes == new:
        sys.exit('already patched')

    page = off - off % 16384
    orig_block = bytes(d[page:page + 16384])
    cd, fields = code_directory(d)
    _, cd_len, cd_ver, cd_flags, hash_off, ident_off, n_special, n_code, code_limit = fields
    hash_size = d[cd + 36]
    hash_type = d[cd + 37]
    if hash_type not in (2, 3, 4):
        sys.exit(f'unsupported hash type {hash_type}')
    slot = cd + hash_off + (off // 16384) * hash_size
    old_slot = bytes(d[slot:slot + hash_size])
    want = hashlib.sha256(orig_block).digest()
    print(f'CodeDirectory at {cd:#x}: ver={cd_ver:#x} hashOff={hash_off} '
          f'hashSize={hash_size} hashType={hash_type} codeLimit={code_limit}')
    print(f'  block {off // 16384} slot at {slot:#x}')
    print(f'  slot now        : {old_slot.hex()}')
    print(f'  original block  : {want.hex()}')
    if code_limit <= off:
        sys.exit('target is outside the signed code limit')
    if hash_type != 2:
        sys.exit('only SHA-256 caches are handled')
    if old_slot != want:
        sys.exit('slot does not hold the original block hash: mapping looks wrong, refusing')

    if a.dry_run:
        print('dry run: nothing written')
        return

    d[off:off + len(new)] = new
    new_hash = hashlib.sha256(bytes(d[page:page + 16384])).digest()
    d[slot:slot + hash_size] = new_hash
    out = a.out or (a.subcache + '.patched')
    open(out, 'wb').write(d)
    print(f'  new block hash  : {new_hash.hex()}')
    print(f'written {out} ({len(d)} bytes) sha256 {hashlib.sha256(bytes(d)).hexdigest()}')


if __name__ == '__main__':
    main()
