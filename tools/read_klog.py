#!/usr/bin/env python3
"""Read the pinned kernel log file off the phone and decode it.

  python tools/read_klog.py [OUT.txt]

pinfile rawread writes its diagnostics to stdout before the binary, so the
stream is trimmed at the "PANDORLG" header first.
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADB = os.path.join(ROOT, "tools", "platform-tools", "adb.exe")
PINFILE = "/data/local/tmp/pinfile"
LOGFILE = "/data/local/tmp/ioslog.img"
DEV = "/dev/block/by-name/userdata"
BYTES = "8388608"

env = dict(os.environ, MSYS_NO_PATHCONV="1")
out = subprocess.run(
    [ADB, "exec-out", f"su -c '{PINFILE} rawread {LOGFILE} {DEV} {BYTES}'"],
    capture_output=True, env=env, timeout=300).stdout
print(f"raw stream: {len(out)} bytes", file=sys.stderr)

i = out.find(b"PANDORLG")
if i < 0:
    print("no PANDORLG header: the kernel did not flush its log", file=sys.stderr)
    sys.exit(2)
raw = out[i:]
sys.path.insert(0, os.path.join(ROOT, "data-a-live", "tools"))
import pandora_log  # noqa: E402

version, size, total, seq, text = pandora_log.decode(raw)
print(f"header v{version} ring {size} total {total} seq {seq}", file=sys.stderr)

# 0249: v2 appends the boot id, a completion mark and the restart record.
if version >= 2 and len(raw) >= 64:
    import struct
    import time
    boot_id, completed = struct.unpack_from("<QQ", raw, 32)
    rtype, = struct.unpack_from("<I", raw, 48)
    rup, = struct.unpack_from("<Q", raw, 56)
    print("boot %s  completed %d/%d%s  restart %s%s" % (
        time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(boot_id)) if boot_id else "?",
        completed, total, "" if completed == total else "  (LOG CUT SHORT)",
        {0: "none (still running)", 1: "kPERestartCPU", 4: "kPEPanicRestartCPU",
         9: "kPEPanicRestartCPUNoCallouts"}.get(rtype, str(rtype)),
        "  at %.1f s" % (rup / 1e9) if rtype else ""), file=sys.stderr)
dest = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "pudding-hw", "ioslog.txt")
with open(dest, "wb") as f:
    f.write(text)
print(f"wrote {dest} ({len(text)} bytes)", file=sys.stderr)
