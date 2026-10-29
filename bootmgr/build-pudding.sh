#!/bin/bash
# pudding 版开机菜单打包（从 ShueiTsuki/data-a-live 的 bootmgr 移植，2026-10-29）。
#
#   bash build-pudding.sh [--slot-from LOADER] [--stock FILE] [--wait-ms N] [--any-mode]
#                         [--extents DIR]
#
# 与上游的差别只有三处：
#   1. 工具链用 WSL 的 clang/ld.lld/llvm-objcopy（上游用 Windows NDK 的路径）；
#   2. 原装内核默认取 backup/pudding-stock/boot_a.img —— 我们这台 **A 槽在用、B 槽全 0**，
#      所以菜单只能写 boot_a（上游那台是 boot_b）；
#   3. extents 的 JSON 用我们 prepare_run.sh 生成的 out/next/rt-{root,log,fw}.json。
#
# 只写 work-bootmgr/out/，不碰手机。测试：fastboot boot out/boot-menu.img（只在内存里）。
set -euo pipefail
cd "$(dirname "$0")"

root=$(cd .. && pwd)
stock=${STOCK:-$root/backup/pudding-stock/boot_a.img}
ext=${EXTENTS:-$root/out/next}
loader=
mk=()
while [ $# -gt 0 ]; do
	case $1 in
	--slot-from) loader=$2; shift 2 ;;
	--stock) stock=$2; shift 2 ;;
	--extents) ext=$2; shift 2 ;;
	--wait-ms) mk+=(--wait-ms "$2"); shift 2 ;;
	--any-mode) mk+=("$1"); shift ;;
	*) sed -n '2,17p' "$0"; exit 2 ;;
	esac
done
case "$stock" in /*) ;; *) stock=$(realpath "$stock") ;; esac
out=out
mkdir -p "$out"

python3 -I prep.py "$stock" "$out"
if [ -n "$loader" ]; then
	python3 -I slot.py "$loader" "$out/slot.img" \
		--label "$(basename "$loader") $(date +%Y%m%d-%H%M%S)" \
		--extents "$ext/rt-root.json" "$ext/rt-log.json" "$ext/rt-fw.json"
	mk+=(--slot "$out/slot.img")
fi

F='--target=aarch64-none-elf -O2 -ffreestanding -fno-builtin -nostdlib -fno-pic
   -fno-stack-protector -mgeneral-regs-only -mstrict-align -Wall -Wextra -Werror'
clang $F -c start.S -o "$out/start.o"
clang $F -DLINUX="\"$out/linux.Image\"" -c blobs.S -o "$out/blobs.o"
clang $F -c menu.c -o "$out/menu.o"
# 加载地址未知：C 里不允许绝对重定位。
if llvm-readelf -r "$out/menu.o" | grep -q R_AARCH64_ABS; then
	echo "absolute relocation in menu.c" >&2; exit 1
fi
ld.lld -T menu.ld --build-id=none "$out/start.o" "$out/menu.o" "$out/blobs.o" -o "$out/menu.elf"
if llvm-nm -u "$out/menu.elf" | grep -q .; then
	echo "undefined symbols:" >&2; llvm-nm -u "$out/menu.elf" >&2; exit 1
fi
llvm-objcopy -O binary "$out/menu.elf" "$out/Image"
python3 -I mkboot.py "$out" "$stock" "${mk[@]}"
