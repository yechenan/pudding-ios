#!/bin/bash
# Build a case-sensitive, journaled HFS+ image of an iOS 16 root filesystem on
# macOS, where hdiutil can read Apple's chunked-LZFSE restore images natively.
#
#   macos-rootfs.sh DMG_DIR OUT.img [SIZE]      （SIZE 默认 16g）
#
# DMG_DIR must contain the IPSW's *.dmg files (087-86698-044 = OS,
# 087-86593-047 = SystemOS cryptex, 087-86715-047 = AppOS cryptex).
# Layout follows ios-fuxi's mkiosroot.sh: OS at /, the cryptexes under
# /System/Cryptexes/{OS,App}, the SystemOS dyld cache hard-linked where
# ignition_level=1 looks for it.
set -euo pipefail

dmgdir=${1:?dmg dir}
out=${2:?out image}
size=${3:-16g}

os=$(ls "$dmgdir"/087-86698-*.dmg)
sysos=$(ls "$dmgdir"/087-86593-*.dmg)
appos=$(ls "$dmgdir"/087-86715-*.dmg)
echo "OS=$os"; echo "SystemOS=$sysos"; echo "AppOS=$appos"

work=$(mktemp -d /tmp/iosroot.XXXXXX)
mnt=$work/mnt
mkdir -p "$mnt/os" "$mnt/sys" "$mnt/app" "$mnt/dst"
cleanup() {
	for m in "$mnt/os" "$mnt/sys" "$mnt/app" "$mnt/dst"; do
		hdiutil detach "$m" -force >/dev/null 2>&1 || true
	done
}
trap cleanup EXIT

hdiutil attach -readonly -nobrowse -noverify -mountpoint "$mnt/os" "$os"
hdiutil attach -readonly -nobrowse -noverify -mountpoint "$mnt/sys" "$sysos"
hdiutil attach -readonly -nobrowse -noverify -mountpoint "$mnt/app" "$appos"
echo "mounted:"; ls "$mnt/os" | head; ls "$mnt/sys" | head -3; ls "$mnt/app" | head -3

# A 16 GiB sparse file, formatted case-sensitive + journaled, then attached.
# newfs_hfs wants a device node, not a path: attach the raw file first.
rm -f "$out"
mkfile -n "$size" "$out"
dev=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$out" | head -1 | awk '{print $1}')
echo "raw device: $dev"
newfs_hfs -s -J -v iOSRoot "$dev"
hdiutil detach "$dev" >/dev/null
hdiutil attach -imagekey diskimage-class=CRawDiskImage -nobrowse -mountpoint "$mnt/dst" "$out"

# OS root: everything, symlinks and hard links preserved.
sudo rsync -aH "$mnt/os/" "$mnt/dst/"          # macOS ships rsync 2.6.9: no --info

# Cryptexes: on the device they are separate volumes under /private/preboot,
# and /System/Cryptexes/{OS,App} are symlinks into them (ios-fuxi's layout).
sudo mkdir -p "$mnt/dst/private/preboot/Cryptexes/OS" "$mnt/dst/private/preboot/Cryptexes/App"
sudo rsync -aH "$mnt/sys/" "$mnt/dst/private/preboot/Cryptexes/OS/"
sudo rsync -aH "$mnt/app/" "$mnt/dst/private/preboot/Cryptexes/App/"

# ignition_level=1 looks for the dyld cache here (ios-fuxi's SWEET addition).
cache=$(find "$mnt/dst/private/preboot/Cryptexes/OS" -name 'dyld_shared_cache_arm64e' -print -quit || true)
if [ -n "$cache" ]; then
	mkdir -p "$mnt/dst/System/Library/Caches/com.apple.dyld"
	ln -f "$cache" "$mnt/dst/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e" || true
	echo "dyld cache: $cache"
fi

sync
sudo umount "$mnt/dst" || hdiutil detach "$mnt/dst" -force
echo "image: $(ls -l "$out")"
