#!/usr/bin/env bash
# Pull the pinned iOS root image back from the phone into the host tree.
#
#   tools/pull_root.sh [OUT]        (default pudding-hw/rootfs/ios-root.pulled.img)
#
# Why: the pinned image accumulates runtime state that a host-side rebuild cannot
# recreate cheaply -- above all the LaunchServices database that lsd spends ~835 s
# building on the first boot of a fresh image (pitfall 1 in HANDOFF.md). Editing a
# copy that was pulled *after* a run keeps that database, so the next boot presents
# in ~60 s instead of ~14 min.
#
# pinfile prints a short preamble before the data; it is cut at the HFS+ volume
# header (offset 1024 of the volume must read "HX" for this case-sensitive root).
set -uo pipefail
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1
ADB=tools/platform-tools/adb.exe
OUT=${1:-pudding-hw/rootfs/ios-root.pulled.img}
ROOT=/data/local/tmp/iosroot-pin.img
DEV="\$(readlink -f /dev/block/by-name/userdata)"

st=$("$ADB" shell "su -c '/data/local/tmp/pinfile status $ROOT'" | tr -d '\r')
echo "$st"
case $st in
*": pinned (GC move failures 0)"*) ;;
*) echo "refused: pinned file is not healthy"; exit 1 ;;
esac

echo "== rawread $ROOT (16 GiB, minutes)"
"$ADB" exec-out "su -c '/data/local/tmp/pinfile rawread $ROOT $DEV'" > "$OUT.raw"
ls -l "$OUT.raw" || exit 1

python - "$OUT" <<'PY'
import sys
out = sys.argv[1]
d = open(out + '.raw', 'rb').read()
# The volume header sits at offset 1024 of the HFS+ volume; find it in the first
# 64 KiB so a changed preamble length does not break the cut.
cut = -1
for off in range(0, 65536):
    if d[off + 1024:off + 1026] == b'HX':
        cut = off
        break
if cut < 0:
    print('refused: no HFSX volume header in the first 64 KiB')
    sys.exit(1)
print(f'== cutting {cut} bytes of pinfile preamble')
open(out, 'wb').write(d[cut:])
PY
[ -f "$OUT" ] || exit 1
ls -l "$OUT"

sz=$(stat -c %s "$OUT")
[ "$sz" -gt 16000000000 ] || { echo "refused: $sz bytes is too small for the 16 GiB root"; exit 1; }
python - "$OUT" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read(4096)
sig = d[1024:1026]
print('HFSX at 1024:', sig)
if sig != b'HX':
    sys.exit(1)
PY
echo "== sha256 (minutes)"
sha256sum "$OUT" | tee "$OUT.sha256"
rm -f "$OUT.raw"
echo "== done: $OUT"
