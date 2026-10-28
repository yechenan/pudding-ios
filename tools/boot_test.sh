#!/usr/bin/env bash
# Build a boot image from a kernel + ADT, boot it on the phone, and pull the kernel log.
#
#   boot_test.sh KERNEL ADT [OUTDIR] [SECONDS_UNTIL_AUTO_REBOOT]
#
# The kernel is built into a boot.img inside WSL (mk_boot_local.sh), then flashed
# with `fastboot boot` (nothing is written to the phone's flash), the phone is
# left alone until pandora_reboot_after brings Android back, and the pinned log
# file is decoded with tools/read_klog.py.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
kernel=$(realpath "$1")
adt=$(realpath "$2")
out=$(realpath "${3:-$root/out}")
wait_s=${4:-180}

ADB="$root/tools/platform-tools/adb.exe"
FASTBOOT="$root/tools/platform-tools/fastboot.exe"

cmdline="debug=0x0 serial=3 cpus=8 bootcpu=7 keepsyms=1 -v rd=ufsroot0 ufsrw=1 rootrw=1"
cmdline="$cmdline pandora_touch=0 pandora_keys=0 pandora_reboot_after=$wait_s"
cmdline="$cmdline unentitled_ios_sim_launch=1 cs_enforcement_disable=1"

mkdir -p "$out"
wsl_kernel=$(printf '%s' "$kernel" | sed 's|^/c/|/mnt/c/|')
wsl_adt=$(printf '%s' "$adt" | sed 's|^/c/|/mnt/c/|')
wsl_out=$(printf '%s' "$out" | sed 's|^/c/|/mnt/c/|')

echo "== building boot.img"
wsl -e bash -lc "cd /mnt/c/$(printf '%s' "$root" | sed 's|^/c/||') && bash tools/mk_boot_local.sh '$wsl_kernel' '$wsl_adt' '$wsl_out' '$cmdline'" | tail -2

echo "== rebooting to the bootloader"
"$ADB" reboot bootloader
sleep 8
"$FASTBOOT" devices

echo "== fastboot boot"
"$FASTBOOT" boot "$out/loader-boot.img"

echo "== waiting ${wait_s}s for the kernel's auto-reboot"
sleep $((wait_s + 30))
"$ADB" wait-for-device
sleep 5

echo "== kernel log"
python "$root/tools/read_klog.py" "$out/ioslog.txt"
echo "log: $out/ioslog.txt"
