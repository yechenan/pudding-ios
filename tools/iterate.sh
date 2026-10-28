#!/usr/bin/env bash
# One iteration from a finished CI run: kernel -> boot.img -> phone -> log.
#
#   iterate.sh RUN_ID [ADT] [OUTDIR]
#
# Downloads the xnu-kernel artifact of RUN_ID, builds a boot image with ADT
# (default: the one with the firmware pack extents), boots it with fastboot
# (nothing is written to the phone), waits for pandora_reboot_after, and pulls
# the kernel log.  Prints the lines that matter for the current bring-up.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
run=${1:?run id}
adt=${2:-$root/boot-new/adt-fw.adt}
out=${3:-$root/out/run-$run}
wait_s=${pandora_wait:-180}

ADB="$root/tools/platform-tools/adb.exe"
FASTBOOT="$root/tools/platform-tools/fastboot.exe"
export MSYS_NO_PATHCONV=1

token=$(cat "$root/.gh_token")
repo=$(grep -o 'pudding-ios' /dev/null 2>/dev/null || true)
repo=${REPO:-yechenan/pudding-ios}

mkdir -p "$out"

# The ADT with the firmware-pack extents is easy to lose (it is rebuildable from
# the pinned files' extent JSONs), so regenerate it when it is missing.
if [ ! -f "$adt" ]; then
	echo "== regenerating $adt"
	mkdir -p "$(dirname "$adt")"
	wsl -e bash -lc "cd /mnt/c/$(printf '%s' "$root" | sed 's|^/c/||') && D22AP_ADT=pudding-hw/d22ap.adt \
		python3 data-a-live/tools/mkadt_pandora.py '$(printf '%s' "$adt" | sed 's|^/c/|/mnt/c/|')' \
		--root-extents pudding-hw/iosroot-extents.json \
		--log-extents pudding-hw/ioslog-extents.json \
		--fw-extents pack/fw-extents.json" | tail -1
fi

echo "== artifact of run $run"
art=$(curl -s -H "Authorization: Bearer $token" \
	"https://api.github.com/repos/$repo/actions/runs/$run/artifacts" |
	python -c "import sys,json;print([a['id'] for a in json.load(sys.stdin)['artifacts'] if a['name']=='xnu-kernel'][0])")
curl -sL -H "Authorization: Bearer $token" \
	"https://api.github.com/repos/$repo/actions/artifacts/$art/zip" -o "$out/kernel.zip"
(cd "$out" && unzip -o -q kernel.zip)
ls -l "$out/kernel.development.pandora"

echo "== boot.img"
wsl -e bash -lc "cd /mnt/c/$(printf '%s' "$root" | sed 's|^/c/||') && bash tools/mk_boot_local.sh \
	'$(printf '%s' "$out" | sed 's|^/c/|/mnt/c/|')/kernel.development.pandora' \
	'$(printf '%s' "$adt" | sed 's|^/c/|/mnt/c/|')' \
	'$(printf '%s' "$out" | sed 's|^/c/|/mnt/c/|')' \
	'debug=0x0 serial=3 cpus=8 bootcpu=7 keepsyms=1 -v rd=ufsroot0 ufsrw=1 rootrw=1 pandora_touch=0 pandora_keys=0 pandora_reboot_after=$wait_s pandora_logsecs=1 unentitled_ios_sim_launch=1 cs_enforcement_disable=1'" |
	tail -1

echo "== boot"
"$ADB" devices
"$ADB" reboot bootloader
sleep 10
"$FASTBOOT" boot "$out/loader-boot.img"
echo "   waiting $((wait_s + 30))s for the auto-reboot"
sleep $((wait_s + 30))
"$ADB" wait-for-device
sleep 5
python "$root/tools/read_klog.py" "$out/ioslog.txt"

echo "== interesting lines"
grep -a -E "PANDORA PREBOOT|libignition|ignition|MKB_INIT|keybag|AMFI|panic|restart type|Bootstrapper|usermanagerd|SpringBoard" \
	"$out/ioslog.txt" | tail -40
