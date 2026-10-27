# pudding 上的 XNU 内核启动记录（2026-10-27）

内核：CI run `40442577298`，产物 `kernel.development.pandora`（17 MB Mach-O，4 KiB 页）。
ADT：`d22ap`（iPhone X Global 16.7.16 的 DeviceTree，LZFSE 解压）经 `mkadt_pandora.py` 生成：
5 GiB @ `0x8c0000000`、GIC `0x17000000`/GICR `0x17080000`、19.2 MHz、8 核、splash `0xFC800000`，
平台名 `xiaomi,pandora`（与 PANDORA 机器配置匹配，暂未做 PUDDING 专用配置）。
引导：`shim/loader` → `payload.bin`（mkpayload.py）→ boot header v4 → `fastboot boot`。

## 启动参数与结果

| # | cmdline 要点 | 结果 |
|---|---|---|
| 1 | `-v rd=md0`（无内存盘） | 内核完整初始化后 panic：`IOFindBSDRoot: specified root memory device, md0, has not been configured`。**预期行为** |
| 2 | 同 1 + `sweet-init` 内存盘 | `*** SWEET user space: init running as PID 1 ***`，每 5 秒 `SWEET init: still alive` |
| 3 | `cpus=1` + root extents | panic `cpu_common.c:82 Assertion failed: cpu < ml_get_max_cpu_number()` —— 单核与 8 核 ADT 冲突 |
| 4 | `cpus=8 bootcpu=7` | 8 核全起，`cpu 0 … about 2273 MHz`，`cpu 6 … about 1988 MHz` |

## 显示（不用改，直接可用）

```
SWEET FB: AppleCLCD 1220x2656 stride 4880 at 0xfc800000, default surface 1, presented as 1125x2436
SWEET FB: IOFramebufferDisplayRefresh: 120 Hz
SWEET BL: AppleARMBacklight published
```

## 触摸（不用改）

```
PANDORA TOUCH: running, polling GPIO 158
PANDORA TOUCH: first report 0xc0
```

## 内核日志落盘（patch 0129，强烈建议默认开启）

- 需要 `ufsrw=1`，否则日志线程放弃（`PANDORA LOG: no log file … restart hook only`）；
- ADT 里放一个 8 MiB 钉住文件的块位置（`--log-extents`）；
- 电脑端读取：`python tools/read_klog.py`（跳过 pinfile 的提示文字，找 `PANDORLG` 头，解环形缓冲）。

## 完整 cmdline（当前最稳的一条）

```
debug=0xc serial=3 cpus=8 bootcpu=7 keepsyms=1 -v rd=md0 \
pandora_ufs_probe=4 ufsrw=1 pandora_touch=0 pandora_keys=0
```
