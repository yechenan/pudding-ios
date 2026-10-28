#!/usr/bin/env python3
"""Link a PANDORA kernel on Linux with cctools-port ld64 (the Apple linker port).

Unlike LLVM's ld64.lld this understands -image_base and -segaddr, so the result
is a kernel that can actually boot:

    relink64.py OBJDIR OUT [--local SRC=OBJ]...

OBJDIR   a directory holding DEVELOPMENT_ARM64_PANDORA/ (objects + link.filelist),
         e.g. the extracted xnu-objects artifact of a CI run
OUT      OUT/kernel.development.pandora.unstripped and .../kernel.development.pandora

Object order comes from OBJDIR/DEVELOPMENT_ARM64_PANDORA/link.filelist; the flags
come from ci3/kernel.development.pandora.link/kernel.development.pandora.linkarguments.
"""
import argparse
import os
import re
import shlex
import subprocess
import sys

LD = '/opt/ld64/bin/aarch64-apple-darwin-ld'
STRIP = '/opt/ld64/bin/aarch64-apple-darwin-strip'
ROOT = '/mnt/c/Users/叶晨安/Desktop/Apple'
CIDIR = os.path.join(ROOT, 'ci3/kernel.development.pandora.link')
CONFIG = 'DEVELOPMENT_ARM64_PANDORA'


def flags(libdir):
    text = open(os.path.join(CIDIR, 'kernel.development.pandora.linkarguments')).read()
    out = []
    for tok in shlex.split(text):
        if tok.startswith('-Wl,'):
            out.extend(tok[4:].split(','))
        elif tok in ('-nostdlib', '-fapple-kext', '-lcc_kext'):
            continue
        elif tok in ('-arch', 'arm64'):
            continue
        elif tok.startswith('-mmacosx-version-min') or tok.startswith('-D'):
            continue
        elif tok == '-lfirehose_kernel':
            out.append('-lfirehose_kernel')
        elif tok.startswith('-L/Users/runner'):
            out.append('-L' + libdir)
        else:
            out.append(tok)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('objdir')
    ap.add_argument('out')
    ap.add_argument('--local', action='append', default=[],
                    metavar='SRCPATH=OBJ', help='use OBJ instead of the archived object for SRCPATH')
    ap.add_argument('--lib', default=None, help='directory with libfirehose_kernel.a')
    ap.add_argument('--extra', action='append', default=[], help='extra object to link (repeatable)')
    a = ap.parse_args()

    cfg = os.path.join(a.objdir, CONFIG)
    flist = os.path.join(cfg, 'link.filelist')
    rels = [p.split('/xnu.obj/', 1)[1] for p in open(flist).read().split()]

    local = {}
    for spec in a.local:
        src, _, obj = spec.partition('=')
        name = os.path.basename(src)
        if name.endswith('.c'):
            name = name[:-2] + '.o'
        elif name.endswith('.cpp'):
            name = name[:-4] + '.cpo'
        local[name] = obj

    objs, missing = [], []
    for rel in rels:
        base = os.path.basename(rel)
        path = local.get(base, os.path.join(a.objdir, rel))
        (objs if os.path.exists(path) else missing).append(path)
    if missing:
        sys.exit('missing %d objects, first: %s' % (len(missing), missing[0]))

    libdir = a.lib or os.path.join(os.path.dirname(a.objdir.rstrip('/')), 'linklibs')
    if not os.path.isdir(libdir):
        libdir = os.path.join(a.objdir, 'linklibs')

    os.makedirs(a.out, exist_ok=True)
    unstrip = os.path.join(a.out, 'kernel.development.pandora.unstripped')
    cmd = [LD, '-arch', 'arm64', '-platform_version', 'macos', '13.5', '14.0']
    cmd += flags(libdir)
    cmd += ['-alias_list', os.path.join(cfg, 'all-alias.exp'), '-o', unstrip]
    cmd += objs + a.extra
    cmd += [os.path.join(a.objdir, CONFIG, n) for n in
            ('version.o', 'lastkerneldataconst.o', 'lastkernelconstructor.o', 'nonlto.o')]
    cmd += ['-L' + libdir, '-lfirehose_kernel', '-lclang_rt.cc_kext']

    print('linking %d objects with %s' % (len(objs), LD))
    r = subprocess.run(cmd, capture_output=True, text=True)
    tail = (r.stdout or '')[-3000:] + (r.stderr or '')[-6000:]
    print(tail)
    if r.returncode:
        sys.exit('ld64 failed: %d' % r.returncode)

    stripped = os.path.join(a.out, 'kernel.development.pandora')
    s = subprocess.run([STRIP, '-S', unstrip, '-o', stripped], capture_output=True, text=True)
    print((s.stdout or '')[-500:] + (s.stderr or '')[-1000:])
    print('unstripped %d bytes, stripped %d bytes' % (os.path.getsize(unstrip), os.path.getsize(stripped)))


main()
