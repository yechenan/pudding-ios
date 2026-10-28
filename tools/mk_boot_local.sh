#!/usr/bin/env bash
# Build a boot.img from a kernel and an ADT, from inside WSL (no nested wsl.exe).
#
#   mk_boot_local.sh KERNEL ADT OUTDIR "CMDLINE"
#
# Same three pieces as mk_boot.sh -- payload (ADT + cmdline) -> loader -> boot
# header -- but the loader is compiled directly, so the paths only have to be
# valid in the Linux file system (run it from /mnt/c/... or a copy under /root).
set -euo pipefail

kernel=$(realpath "$1")
adt=$(realpath "$2")
mkdir -p "$3"
out=$(realpath "$3")
cmdline=${4:-"debug=0x0 serial=3 cpus=8 bootcpu=7 keepsyms=1 -v rd=ufsroot0 ufsrw=1 rootrw=1 pandora_touch=0 pandora_keys=0 pandora_reboot_after=120"}

root=$(cd "$(dirname "$0")/.." && pwd)

python3 "$root/data-a-live/tools/mkpayload.py" "$kernel" "$adt" "$out/payload.bin" --cmdline "$cmdline"

cd "$root/data-a-live/shim/loader"
: > "$out/logo.bin"
F='--target=aarch64-none-elf -O2 -ffreestanding -fno-builtin -nostdlib -fno-pic -fno-stack-protector -mgeneral-regs-only -mstrict-align -Wall -Wextra -Werror'
clang $F -c start.S -o "$out/start.o"
clang $F -DPAYLOAD="\"$out/payload.bin\"" -c payload.S -o "$out/payload.o"
clang $F -DLOGO="\"$out/logo.bin\"" -c logo.S -o "$out/logo.o"
clang $F -c loader.c -o "$out/loader.o"
ld.lld -T loader.ld --build-id=none "$out/start.o" "$out/loader.o" "$out/logo.o" "$out/payload.o" -o "$out/loader.elf"
llvm-objcopy -O binary "$out/loader.elf" "$out/Image"

python3 "$root/data-a-live/tools/mkbootimg_v4.py" "$out/Image" "$out/loader-boot.img"
ls -lh "$out/loader-boot.img"
