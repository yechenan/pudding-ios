#!/usr/bin/env bash
# pudding 启动菜单：在安卓和 iOS 之间自己选，不再受自动回安卓的时间窗口限制。
#
#   bash menu.sh
#
# 设计前提（和 HANDOFF.md 一致）：
#  · iOS 只通过 `fastboot boot` 临时引导，不写任何分区；断电/长按电源就回安卓。
#  · 造镜像（tools/prepare_run.sh）必须手机在安卓、adb 可见（它要读 pinned 文件的 extents）。
#  · 不带 pandora_reboot_after 时内核不会自己重启，会一直停在 iOS，直到你长按电源。
#  · 内核每秒把日志写进 pinned 的 ioslog.img，所以手动重启后照样能拉日志（菜单第 5 项）。
set -uo pipefail
cd "$(dirname "$0")"
export MSYS_NO_PATHCONV=1
ADB=tools/platform-tools/adb.exe
FB=tools/platform-tools/fastboot.exe

BASE_ARGS="debug=0x0 serial=3 cpus=8 bootcpu=7 keepsyms=1 -v rd=ufsroot0 ufsrw=1 rootrw=1 pandora_touch=0 pandora_keys=0 pandora_logsecs=1"
TAIL_ARGS="unentitled_ios_sim_launch=1 cs_enforcement_disable=1"
DEF_EXTRA="pandora_thumbs_start=120 pandora_thumbs_every=60"

have_adb() { "$ADB" devices 2>/dev/null | grep -q "	device$"; }
have_fb()  { "$FB" devices 2>/dev/null | grep -q "fastboot"; }

newest_kernel() {
	ls -1t relink/kernel-0* 2>/dev/null | head -1
}

state() {
	echo "---- 状态 ----"
	if have_adb; then
		echo "adb      : $( "$ADB" shell getprop ro.product.device 2>/dev/null | tr -d '\r') （安卓）"
	elif have_fb; then
		echo "fastboot : 在 bootloader"
	else
		echo "adb      : 无设备 —— 手机大概在 iOS 里（要回安卓：长按电源 ~10 秒）"
	fi
	st=$( "$ADB" shell "su -c '/data/local/tmp/pinfile status /data/local/tmp/iosroot-pin.img'" 2>/dev/null | tr -d '\r')
	[ -n "$st" ] && echo "pinned   : $st"
	echo "内核     : $(newest_kernel)"
	echo "镜像     : $(ls -l pudding-hw/rootfs/ios-root.img 2>/dev/null | awk '{print $5" bytes "$6" "$7" "$8}')"
	echo "-------------"
}

boot_ios() { # $1=窗口秒数或 none  $2=额外参数
	local window=$1 extra=$2 tag k tmp
	tag="manual-$(date +%m%d-%H%M%S)"
	k=$(newest_kernel)
	printf '内核 [默认 %s]: ' "$k"; read -r tmp; [ -n "${tmp:-}" ] && k="relink/kernel-$tmp"
	[ -f "$k" ] || { echo "没有这个内核：$k"; return 1; }

	if ! have_adb; then
		echo "!! 手机不在安卓（adb 不可见）：造镜像必须先在安卓状态。"
		return 1
	fi

	if [ "$window" = "none" ]; then
		CMDLINE="$BASE_ARGS $extra $TAIL_ARGS"
		echo "== 无时间窗口：iOS 会一直跑，回安卓请长按电源 ~10 秒"
	else
		CMDLINE="$BASE_ARGS pandora_reboot_after=$window $extra $TAIL_ARGS"
		echo "== ${window} 秒后自动回安卓"
	fi

	echo "== 造镜像 $tag（读 pinned extents + 链接内核，约 1-2 分钟）"
	PD_CMDLINE="$CMDLINE" bash tools/prepare_run.sh "$k" "boot-$tag" "${window/none/0}" "$extra" 2>&1 | tail -4
	[ -f "boot-$tag/loader-boot.img" ] || { echo "造镜像失败"; return 1; }

	if ! have_fb; then
		echo "== 重启到 bootloader"
		"$ADB" reboot bootloader >/dev/null 2>&1
		for _ in $(seq 1 60); do have_fb && break; sleep 2; done
	fi
	have_fb || { echo "!! 没进 fastboot"; return 1; }

	echo "== fastboot boot boot-$tag/loader-boot.img"
	"$FB" boot "boot-$tag/loader-boot.img" 2>&1 | tail -3
	echo "== 已引导。日志：安卓下运行本菜单第 5 项，名字用 run-$tag"
	echo "run-$tag" > out/.last-run
}

boot_existing() {
	local d img
	echo "现成镜像："
	ls -1dt boot-*/loader-boot.img 2>/dev/null | head -8 | nl -w2 -s') '
	printf '选一个（可写 run43 / boot-run43 / 序号，回车取消）: '; read -r d
	[ -n "${d:-}" ] || return 0
	case "$d" in
	[0-9]*) img=$(ls -1dt boot-*/loader-boot.img 2>/dev/null | head -8 | sed -n "${d}p") ;;
	*) img="boot-${d#boot-}/loader-boot.img" ;;
	esac
	[ -f "${img:-}" ] || { echo "没有这个镜像：${img:-?}"; return 1; }
	python - "$img" <<'PY'
import sys
b = open(sys.argv[1].replace('loader-boot.img', 'payload.bin'), 'rb').read(0x2a8)
print('cmdline:', b[0x48:0x48+608].split(b'\0')[0].decode())
PY
	if ! have_fb; then
		have_adb || { echo "!! 手机既不在安卓也不在 bootloader"; return 1; }
		"$ADB" reboot bootloader >/dev/null 2>&1
		for _ in $(seq 1 60); do have_fb && break; sleep 2; done
	fi
	"$FB" boot "$img" 2>&1 | tail -3
}

build_only() {
	local tag k w extra tmp
	tag="img-$(date +%m%d-%H%M%S)"
	k=$(newest_kernel)
	printf '内核 [默认 %s]: ' "$k"; read -r tmp; [ -n "${tmp:-}" ] && k="relink/kernel-$tmp"
	printf '额外参数 [默认 %s]: ' "$DEF_EXTRA"; read -r extra; extra=${extra:-$DEF_EXTRA}
	printf '窗口秒数（回车=无窗口）: '; read -r w
	if [ -n "${w:-}" ]; then
		PD_CMDLINE="$BASE_ARGS pandora_reboot_after=$w $extra $TAIL_ARGS" \
			bash tools/prepare_run.sh "$k" "boot-$tag" "$w" "$extra" 2>&1 | tail -3
	else
		PD_CMDLINE="$BASE_ARGS $extra $TAIL_ARGS" \
			bash tools/prepare_run.sh "$k" "boot-$tag" 0 "$extra" 2>&1 | tail -3
	fi
	echo "== 造好：boot-$tag/loader-boot.img（用第 3 项启动）"
}

pull_log() {
	local n
	printf '这轮日志叫什么 [默认 %s]: ' "$(cat out/.last-run 2>/dev/null | sed 's/^run-//')"
	read -r n
	n=${n:-$(cat out/.last-run 2>/dev/null | sed 's/^run-//')}
	[ -n "${n:-}" ] || n=manual
	bash tools/pull_log.sh "$n"
}

restore() {
	echo "!! 会用 pudding-hw/rootfs/ios-root.img 覆盖手机上的 pinned 镜像（约 8-15 分钟），"
	echo "   并且下一次开机要重建 LaunchServices 库（~835 秒才 present）。"
	printf '确认？(yes/回车取消): '; read -r a
	[ "$a" = "yes" ] && bash tools/restore_root.sh
}

push_docs() {
	printf '提交说明: '; read -r msg
	[ -n "${msg:-}" ] || msg="chore: update docs"
	git -C pudding-standalone add -A
	git -C pudding-standalone -c user.email=agent@local -c user.name=agent commit -q -m "$msg" || echo "（没有新改动）"
	GITHUB_TOKEN=$(tr -d '\r\n' < .gh_token) python tools/gh_push.py \
		--repo yechenan/pudding-ios --dir pudding-standalone --branch main --message "$msg" 2>&1 | tail -3
}

while :; do
	echo
	echo "======== pudding 菜单 ========"
	state
	echo " 1) 启动 iOS —— 不设时间窗口（手动长按电源回安卓）"
	echo " 2) 启动 iOS —— N 秒后自动回安卓"
	echo " 3) 用现成的 loader-boot.img 启动（不重建）"
	echo " 4) 回到安卓"
	echo " 5) 拉取上一次 iOS 日志 + 缩略图"
	echo " 6) 只造镜像，不启动"
	echo " 7) 恢复镜像到手机（restore_root.sh）"
	echo " 8) 推文档/补丁到 GitHub"
	echo " 0) 退出"
	printf '选择: '; read -r c
	case "${c:-}" in
	1) echo; boot_ios none "" ;;
	2) printf '窗口秒数: '; read -r w; [ -n "${w:-}" ] && boot_ios "$w" "" || echo "没输入秒数" ;;
	3) boot_existing ;;
	4)
		if have_adb; then "$ADB" reboot; echo "== 安卓重启中"
		elif have_fb; then "$FB" reboot; echo "== 从 bootloader 重启"
		else echo "== 手机在 iOS：长按电源 ~10 秒回安卓"; fi ;;
	5) pull_log ;;
	6) build_only ;;
	7) restore ;;
	8) push_docs ;;
	0) exit 0 ;;
	*) echo "?" ;;
	esac
done
