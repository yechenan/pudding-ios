#!/usr/bin/env bash
# 把一份新的 iOS 负载放进开机菜单的槽位（boot_<slot> 里，只动槽位）。
#
#   tools/bootmenu_slot.sh [--kernel NAME] [--args "EXTRA"] [--keep-args] [--yes]
#
# 为什么必须用它而不是直接 fastboot flash boot_a：
#  · 菜单按"三个 pinned 文件的 extents 指纹"决定能不能进 iOS；镜像一换（restore_root 之后）
#    指纹就变了，槽位里的旧 iOS 会读写到别人的块上 —— 必须先刷新槽位；
#  · 它只改槽位那一块，boot_a 里的菜单和原装安卓内核不动，写坏也只坏槽位（菜单显示 iOS off）。
#
# 步骤：准备 extents（手机必须在安卓）→ 重造 loader（payload 的 ADT 带这些 extents）
#      → slot.py 打槽位包 → push → 手机端 helper 写 boot_<slot> 并读回核对。
set -euo pipefail
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1
ADB=tools/platform-tools/adb.exe
BM=work-bootmgr
HELPER=/data/local/tmp/bm_update_helper.sh
KERNEL=relink/kernel-0262
EXTRA=""
KEEP=()
YES=0

while [ $# -gt 0 ]; do
	case $1 in
	--kernel) KERNEL=relink/kernel-$2; shift 2 ;;
	--args) EXTRA=$2; shift 2 ;;
	--keep-args) KEEP=(--keep-args); shift ;;
	--yes) YES=1; shift ;;
	*) sed -n '2,16p' "$0"; exit 2 ;;
	esac
done

[ -f "$BM/phone/update_helper.sh" ] || { echo "missing $BM/phone/update_helper.sh"; exit 1; }
"$ADB" devices | grep -q "	device$" || { echo "手机不在安卓（adb 不可见）"; exit 1; }

echo "== 1/4 读 extents + 重造 loader（窗口=0，不自动回安卓）"
bash tools/prepare_run.sh "$KERNEL" boot-slot 0 "$EXTRA" 2>&1 | tail -3

echo "== 2/4 打槽位包"
python -I "$BM/slot.py" boot-slot/loader-boot.img "$BM/out/slot.img" "${KEEP[@]}" \
	--label "$(basename "$KERNEL") $(date +%m%d-%H%M)" \
	--extents out/next/rt-root.json out/next/rt-log.json out/next/rt-fw.json | tail -3

echo "== 3/4 手机端检查"
"$ADB" push "$BM/phone/update_helper.sh" $HELPER > /dev/null
info=$("$ADB" shell "su -c 'sh $HELPER info'" | tr -d '\r')
echo "$info"
case $info in *"dev "*"slot "*) ;; *) echo "helper info failed"; exit 1 ;; esac
max=$(echo "$info" | awk '/^slot /{print $3}')
size=$(stat -c %s "$BM/out/slot.img")
[ "$size" -le "$max" ] || { echo "槽位放不下：$size > $max"; exit 1; }
echo "fits: $size of $max bytes"

if [ "$YES" != "1" ]; then
	echo "只检查不写；加 --yes 写入"
	exit 0
fi

echo "== 4/4 写入"
"$ADB" push "$BM/out/slot.img" /data/local/tmp/bm_slot.img > /dev/null
local_sum=$(sha256sum < "$BM/out/slot.img" | cut -c1-64)
phone_sum=$("$ADB" shell "su -c 'sha256sum /data/local/tmp/bm_slot.img'" | tr -d '\r' | cut -c1-64)
[ "$local_sum" = "$phone_sum" ] || { echo "push 后校验不一致"; exit 1; }
res=$("$ADB" shell "su -c 'sh $HELPER write /data/local/tmp/bm_slot.img'" | tr -d '\r')
"$ADB" shell "su -c 'rm -f /data/local/tmp/bm_slot.img'" >/dev/null 2>&1 || true
echo "$res"
case $res in "write ok"*) echo "== 槽位已更新";; *) echo "== 写失败"; exit 1 ;; esac
