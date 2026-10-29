#!/usr/bin/env bash
# Build a boot.img from a kernel: payload (ADT + cmdline) -> loader -> boot header.
#
#   mk_boot.sh KERNEL ADT OUTDIR "CMDLINE"
#
# Needs WSL (clang/lld) for the loader; everything else runs on the host.
set -euo pipefail

kernel=$(realpath "$1")
adt=$(realpath "$2")
out=$(mkdir -p "$3" && realpath "$3")
cmdline=${4:-"debug=0x0 serial=3 cpus=8 bootcpu=7 keepsyms=1 -v rd=ufsroot0 ufsrw=1 rootrw=1 pandora_touch=0 pandora_keys=0"}

root=$(cd "$(dirname "$0")/.." && pwd)
python "$root/data-a-live/tools/mkpayload.py" "$kernel" "$adt" "$out/payload.bin" --cmdline "$cmdline"

wsl_out=$(printf '%s' "$out" | sed 's|^C:|/mnt/c|; s|^D:|/mnt/d|; s|\\|/|g')
wsl.exe -d Ubuntu2404 -e bash -lc "
set -e
cd '$root/data-a-live/shim/loader'
mkdir -p '$wsl_out'
: > '$wsl_out/logo.bin'
F='--target=aarch64-none-elf -O2 -ffreestanding -fno-builtin -nostdlib -fno-pic -fno-stack-protector -mgeneral-regs-only -mstrict-align -Wall -Wextra -Werror'
clang \$F -c start.S -o '$wsl_out/start.o'
clang \$F -DPAYLOAD=\"'$wsl_out'/payload.bin\" -c payload.S -o '$wsl_out/payload.o'
clang \$F -DLOGO=\"'$wsl_out'/logo.bin\" -c logo.S -o '$wsl_out/logo.o'
clang \$F -c loader.c -o '$wsl_out/loader.o'
ld.lld -T loader.ld --build-id=none '$wsl_out/start.o' '$wsl_out/loader.o' '$wsl_out/logo.o' '$wsl_out/payload.o' -o '$wsl_out/loader.elf'
llvm-objcopy -O binary '$wsl_out/loader.elf' '$wsl_out/Image'
"

python "$root/data-a-live/tools/mkbootimg_v4.py" "$out/Image" "$out/loader-boot.img"
ls -lh "$out/loader-boot.img"
