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

# dyld opens the shared cache by path: either /System/Library/Caches/com.apple.dyld/
# or, on iOS 16, /System/Cryptexes/OS/System/Library/Caches/com.apple.dyld/.
# Give it both: a symlink for the cryptex mount point and a hard link at the
# legacy path (no extra space). sudo: the cryptex files are root-only.
echo "dyld caches on the three volumes:"
sudo find "$mnt/os" "$mnt/sys" "$mnt/app" -name 'dyld_shared_cache*' -printf '  %p %s
' 2>/dev/null | head -20 || true

cache=$(sudo find "$mnt/dst" -name 'dyld_shared_cache_arm64e' -print -quit 2>/dev/null || true)
if [ -n "$cache" ]; then
	sudo mkdir -p "$mnt/dst/System/Library/Caches/com.apple.dyld"
	sudo ln -f "$cache" "$mnt/dst/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e" || true
	echo "dyld cache hard link: $cache -> /System/Library/Caches/com.apple.dyld/"
else
	echo "WARNING: no dyld_shared_cache_arm64e in the image" >&2
fi

# iOS 16 mounts the SystemOS cryptex at /System/Cryptexes/OS; here it lives
# under /private/preboot, so point the well-known path at it.
sudo mkdir -p "$mnt/dst/System/Cryptexes"
sudo ln -sfn ../../private/preboot/Cryptexes/OS "$mnt/dst/System/Cryptexes/OS"
sudo ln -sfn ../../private/preboot/Cryptexes/App "$mnt/dst/System/Cryptexes/App"
ls -l "$mnt/dst/System/Cryptexes/"

sync
sudo umount "$mnt/dst" || hdiutil detach "$mnt/dst" -force
echo "image: $(ls -l "$out")"
