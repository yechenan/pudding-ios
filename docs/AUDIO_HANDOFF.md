# 音频移植：到 2026-10-30 09:35 为止的状态与交接

## 一句话

**整条硬件链已经打通，只差 iOS 的 VirtualAudio 把我们认成输出路由。**
设备三实例注册、ADSP 固件、两颗 CS35L43 的 DSP 固件、CoreAudio 写数据全部正常；
但 `set stream active`（HAL method 6）从未到来，所以没有声音。

## 已经做对的事（不要重做）

1. **内核**：`relink/kernel-audio-05`（CI 同源编译，17,370,504 B，`LC_UNIXTHREAD`）。
   构建路径：改 `xnu/patches/0252-pandora-audio.patch` → push `yechenan/pudding-ios` →
   `POST /repos/yechenan/pudding-ios/actions/workflows/xnu.yml/dispatches {"ref":"main"}` →
   `bash work-audio/ci_fetch.sh <run_id> <name>`（自动下载 `xnu-kernel` + strip + 装到 `relink/`）。
2. **固件包**：`work-gpu/iosfw-amp-pad.img`（64 MiB padded，17 条目），含
   两颗 CS35L43 的 `cs35l43-dsp1-spk-prot.wmfw` + B/T 的 dsp1/delta-music tuning
   （从手机 `/odm/firmware` 取，`adb pull` 前要 `su -c cp` 到 /data/local/tmp）。
   写入用 `tools/push_fw.sh`。
3. **启动参数**（当前最优组合）：
   `GPUPOOL=1024 PD_TOUCH=1 PD_KEYS=1 PD_QUIET=1 LOGO=work-bootmgr/logo.bin` +
   `pandora_gpu=15 pandora_gpu_metal=1 pandora_gpu_perf=18 sweetfb_fill=1
    pandora_audio=1 pandora_audio_tt=1 pandora_amp=15 pandora_adsp=15
    pandora_spk=3 pandora_spk_live=1 panic_reboot=1`
4. **已验证的日志证据**：
   - `PANDORA AUDIO Speaker/Hawking/Codec: registered …48000 Hz … s32`
   - `PANDORA ADSP: pas 13 auth_and_reset -> a0 0 a1 0`
   - `PANDORA AMP: 0x40 loaded: …` / `0x42 loaded: …` / `PANDORA AMP: done`
   - `PANDORA IO: … write 35 cmds 236 KiB`（CoreAudio 在写），但 `device 2 ms (0%)`

## 卡点：VirtualAudio 不给路由

- 上游注释（`PandoraAudio.cpp` 474–475 行）：VirtualAudio **按设备属性生成端口**，
  `kAudioDevicePropertyMute` 在 element 3 上出 receiver 端口、**element 4 才出 speaker 端口**；
- 我们已给 Speaker 加了 element 4 的 mute（kernel-audio-05），**仍然 12 次 `not routed`**；
- 上游 0282/0283/0291 的注释还说过：内置 UID "Speaker" 时"没有任何 category 拿到路由，
  iPhone X 的路由数据库要的不止这一个设备"；`pandora_audio_tt=1`（Thunderbolt）也没用。

## 下一步的候选（按把握排序）

1. **补全设备模型**：除 element-4 mute 外，再声明 `output ports` / `port type`
   （`PA_4CC('s','p','k','r')` 之类）与 `transport type` 的组合，让 VirtualAudio 直接建端口；
   参考上游 0300–0306 的 `setProperty` 调用序列。
2. **拿 VirtualAudio 自己的日志**：上游用的是 `aud13/aud19` unified log；
   我们若能把 `VirtualAudio` 的 os_log 弄进内核日志（`sweetnull`），就能看到它到底为什么跳过我们
   —— 这比盲试快得多。做法参考 HANDOFF 里 `OS_ACTIVITY_DT_MODE=YES` 的思路。
3. **检查 28 秒那波异常**：`bufs 35k / read 2.9 GB / device 8%` 与
   `Failed to handle the new encryption key` 相邻出现，可能是 Hawking 输入环空转，值得先排除。
