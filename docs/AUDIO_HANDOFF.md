# 音频移植：到 2026-10-30 14:45 为止的状态与交接

## 一句话

**内核到 DSP 到功放的整条链已经跑起来了（ADSP 起来、播放图常驻、缓冲区每秒 50 个来回、功放固件加载）；**
**现在只差 iOS 的 HAL（VirtualAudio）不打开我们的设备。** 今天把“为什么没声音”从“路由不给”细化到三个可验证的断点，
其中两个（ADSP 没启动、播放图没加载）已经修好，第三个（HAL 插件扫描卡在 CarPlayHalogen）已经定位并验证了修法方向。

## 今天验证过的事实（有日志，别重做）

1. **ADSP 能起来**（h3）：`pandora_slot=a` 让它去读安卓的 `modem_a` FAT16 分区：

   ```
   PANDORA ADSP: modem_a: LUN 4 blocks 0x1686+0xa000, FAT mount -> 0 (FAT16, 16384-byte clusters)
   PANDORA ADSP: slave-kernel 0x2 after 619 ms → ready after 620 ms
   PANDORA ADSP: channel adsp_apps up after 658 ms; APM ready 1009 ms after the channel came up
   ```

   注意：`pas 13 auth_and_reset -> a0 0 a1 0` 是 **zap 分片**，不是 ADSP 成功，别再被它误导。

2. **扬声器播放图能跑**（h3）：把手机 ACDB 用 `tools/spk_graph.py` 生成的 `spkgraph.bin`（开图 2776 B、
   校准 7128 B/168 参数、TDM 48 B）和 `rcvgraph.bin`、本机 `crus_calr.bin` 打进固件包之后：

   ```
   PANDORA SPK: speaker graph: 4 subgraphs, open 2776 bytes, calibration 7128, TDM 48; 13 commands
   PANDORA SPK: graph open / calibration / MFC / TDM / SPR / volume / prepare / start 全 status 0
   PANDORA SPK: live at 20040 ms: 1006 buffers sent, 1002 back (0 with an error), 4 in flight
   ```

   功放：`PANDORA AMP: 0x40 (B): firmware 0x1820d6 version 7.30.1, 27 algorithms`。

3. **VirtualAudio 现在能被加载**（h5）：只要绕过 `CarPlayHalogen.driver`（见下），mediaserverd 就会打开
   `/Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin/VirtualAudio`（路径日志 19 行 vs h3 的 0 行）。

## 当前卡点（按顺序）

### 1. `mediaserverd` 的 HAL 插件扫描停在 `CarPlayHalogen.driver`

`pandora_pathlog=mediaserverd`（上游 0285，我们的内核里已有）显示，h3 从 12.61 s 开始按顺序打开
`AirPlayHalogen → AppleAOPAudioPlugin → AppleTimeSyncAudioClock → AppleUSBAudio → BTAudioHALPlugin →
BasebandVoice → CarPlayHalogen`，**到 12.672 s 之后再无任何插件加载**（1054 s 复位为止）。
此时 `VirtualAudio.plugin` 的访问计数 = 0，即它根本没被尝试。

h5 验证：用固件包 `files.txt` 把 `CarPlayHalogen.driver/CarPlayHalogen` 覆盖成 8 字节垃圾（原文件备份在
`work-audio/halrestore/CarPlayHalogen`），VirtualAudio 立刻被加载。**真正的修法是查清它为什么在我们拼的根里
加载失败（多半缺依赖），不是长期把它换成垃圾文件。**

### 2. VirtualAudio 加载了也不打开我们的设备

h5：12.75 s 插件加载，到 165 s 仍然只有 12 次 `not routed`，没有一条 `PANDORA AUDIO ... opened by` /
`setProperties`。上游 aud7 的经验是插件加载后会 `open` 设备并取独占（hog mode），要求 `setProperties` 接受
`exclusive access owner`——我们的驱动实现了，但**它连试都没试**。

### 3. 638 s 的内核死锁（h5）

```
Ticket spinlock[0xfffffff007bb4880] timeout after 854336 ticks; cticket: 0x89, nticket: 0x8b,
waiting for 0x8a, current owner: 0xfffffff62af6ec08 (on CPU 1) @lock_ticket.c:386
PANDORA: restart type 4, final log flush 0
```

锁地址可以用 CI 产物里的符号定位（`out/next/ci/kernel.zip` 里有 dSYM、`.exp` 和 138 MB 的 `.a`）。
很可能是我们的 IOAudio2 用户端路径和 HAL 的交互。**下一次先做这件事**。

## 启动参数（h5 的完整组合）

```
GPUPOOL=1024 PD_TOUCH=1 PD_KEYS=1 PD_QUIET=1 LOGO=work-bootmgr/logo.bin
pandora_gpu=15 pandora_gpu_metal=1 pandora_gpu_perf=18 sweetfb_fill=1
pandora_audio=1 pandora_amp=15 pandora_adsp=15 pandora_spk=3 pandora_spk_live=1
pandora_slot=a panic_reboot=1
pandora_pathlog=mediaserverd sweetnull=backboardd,SpringBoard,mediaserverd
```

`pandora_amp=15` 与上游的 `=3` 行为相同（代码里都是 `>=3` 分支）。`pandora_spk_live=1` **必须带**，
否则喇叭图 26 秒后就停、只放测试音，iOS 没声音。

## 固件包（`work-gpu/iosfw-amp-pad4.img`，21 条目，pinned 64 MiB）

- 功放：`cs35l43-dsp1-spk-prot.wmfw` + B/T 各自的 dsp1 与 delta-music 调音（安卓 `/odm/firmware`）；
- 播放图：`spkgraph.bin`（10 092 B）、`rcvgraph.bin`（5 036 B），由手机 ACDB 生成，**不进仓库**；
- 校准：`crus_calr.bin`（本机 8 字节）；
- GPU：`NativeAdrenoMetal` 等（沿用之前的）；
- `files.txt`：安装清单；h5 里加了一行把 `CarPlayHalogen` 覆盖成垃圾（**诊断用，记得还原**）。

## 下一步（按顺序）

1. **符号化 `0xfffffff007bb4880`**：从 `out/next/ci/kernel.zip` 的 dSYM/`.exp` 找出这把锁，定位 638 s 死锁；
   如果是我们驱动的用户端路径，先修它（否则 HAL 一交互就死机）。
2. **查 CarPlayHalogen 的加载失败原因**：对比它依赖的 framework/plist 是否被 stage 进根；修根而不是长期换垃圾。
3. 上面两条通了之后才是“设备模型/路由”问题（上游 aud19：`{ vdef: pap → pspk 扬声器 Speaker }`）。
4. **把“已建表”的镜像拉回来当基线**（`tools/pull_root.sh`），以后每轮不必再付 ~835 秒建表。
5. 上游 `docs/AUDIO_SPEAKER.md` 值得继续照抄；今天已经给上游开了 PR 的分支（`yechenan/data-a-live-fork:pudding-hal-diag`）：
   ①`--amp-fw` 缺 `spkgraph.bin` 时报警；②§6.2 补 `pandora_pathlog` 的验证方法。

## 操作陷阱（今天踩的，见 MISTAKES #51–#57）

- `restore_root.sh` 之后**首次启动会重新建表**（前 30 秒写 250–290 MB），窗口给 300–1500 s 都会在半路被切断；
- `PANDORA IO` 是 UFS 块设备统计，不是音频数据；
- 打开 HAL 之后 `backboardd` 在 12.5 s 就不再输出、画面不再重绘，这是连带现象。
