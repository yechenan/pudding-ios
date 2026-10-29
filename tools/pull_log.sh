#!/usr/bin/env bash
# Pull the last iOS session's kernel log from the pinned log file (phone in Android).
#
#   tools/pull_log.sh NAME
#
# The kernel writes its log ring into /data/local/tmp/ioslog.img every second
# (pandora_logsecs=1), so the log survives a boot that ended by a long power press
# as well as one that ended by pandora_reboot_after. Decodes NAME.img into
# out/ioslog-NAME.txt and renders any thumbnails into out/thumbsNAME/.
set -uo pipefail
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1
ADB=tools/platform-tools/adb.exe
NAME=${1:-manual}
DEV="\$(readlink -f /dev/block/by-name/userdata)"

echo "== pull log"
"$ADB" exec-out "su -c '/data/local/tmp/pinfile rawread /data/local/tmp/ioslog.img $DEV'" > "out/$NAME.raw"
ls -l "out/$NAME.raw" || exit 1

# pinfile prints a few diagnostics lines before the data: cut at the log magic.
python - "$NAME" <<'PY'
import sys
name = sys.argv[1]
d = open(f'out/{name}.raw', 'rb').read()
i = d.find(b'PANDORLG')
if i < 0:
    print('== no PANDORLG in the raw read'); sys.exit(1)
if i:
    print(f'== skipping {i} bytes before the log header')
open(f'out/{name}.img', 'wb').write(d[i:])
PY
python -I data-a-live/tools/pandora_log.py "out/$NAME.img" "out/ioslog-$NAME.txt" || exit 1
python -I data-a-live/tools/fbdump.py "out/$NAME.img" "out/$NAME" 2>/dev/null || true
python -I tools/thumbs.py "out/ioslog-$NAME.txt" "out/thumbs$NAME" 2>/dev/null || true
echo "== log: out/ioslog-$NAME.txt"
grep -ac "" "out/ioslog-$NAME.txt" 2>/dev/null | sed 's/^/   lines: /'
echo "== done"
