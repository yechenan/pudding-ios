# 交接：现状、下一步、以及踩过的坑（2026-10-29）

这份文档是给"下一次会话/下一个人"的：先看这里，不用重新踩一遍。

> **先读 `docs/MISTAKES.md`。** 那是"每次犯错都必须追加"的记录，最新的在最上面，
> 每条都写了"做了什么 / 后果（带轮次号和日志行）/ 以后的规矩"。这里的"坑"是环境事实，
> 那边是**判断错误**——两类都要看。

## 一分钟现状

- 手机：小米 17（pudding / SM8850），iOS 16.7.16（20H392，iPhone X 的 iPSW）。
- **已打通：内核 → 用户态 → SpringBoard → 锁屏 → 桌面**（2026-10-29 21:40，Setup 已被跳过）。
- 跳过 Setup 的关键**不是偏好**，而是把 SpringBoard 的 `-[SBSetupManager updateInSetupMode]`
  在 dyld 缓存里打成 `ret`（要连 CodeDirectory 的页哈希一起改，否则 4K 校验会拒绝）。
  细节和字节都在 `PUDDING_STATUS.md` 的 2026-10-29 21:40 那一节。
- 桌面侧已可用：触摸（`pandora_touch=15`）、电源/音量键（`pandora_keys=3`）、
  画面铺满（`sweetfb_fill=1`）、CPU 合成显示。
- 还没做：Wi-Fi（无 WCN 驱动）、音频输出、GPU 合成、USB 数据。
- 根卷仍是"非日志式"：硬复位后要先 `tools/clear_dirty_bit.sh`（2 秒），
  卷真的损坏时必须 `restore_root.sh`（12 分钟，且下次启动要重建 LaunchServices 表 ~835 秒）。
- 上游同机型仓库：`ShueiTsuki/data-a-live`（他们更领先：GPU/音频/触摸全通），
  镜像侧脚本 `bangprovn/ios-fuxi`。

## 仓库和文件都在哪

| 东西 | 路径 |
|---|---|
| 我们的补丁仓库 | `pudding-standalone/`（推到 `yechenan/pudding-ios`，token 在 `.gh_token`） |
| 状态文档 | `pudding-standalone/docs/PUDDING_STATUS.md`（按时间追加，最新在最下面） |
| 内核源码树 | `ci4/buildtree/xnu`（完整 xnu-8796 + 我们的补丁） |
| 内核产物 | `relink/kernel-0250 … kernel-0262` |
| 镜像 | `pudding-hw/rootfs/ios-root.img`（当前）、`ios-root.orig.img`（原始）、`ios-root.pretweaks.img` |
| 工具 | `tools/`（run_boot / prepare_run / restore_root / root_tweaks / thumbs / run_report / gh_push） |
| 日志 | `out/ioslog-runNN.txt`、缩略图 `out/thumbsNN/`、帧转储 `out/runNN-surface.png` |

## 常用命令（照抄就能跑）

```bash
# 0) 交互菜单（推荐入口）：选安卓 / iOS、有没有时间窗口、拉日志、恢复镜像、推文档
bash menu.sh

# 1) 造一轮启动镜像（手机必须在安卓、adb 可见；会读 pinned 文件的 extents）
#    第三个参数是窗口秒数；写 0 就是"不自动回安卓"（手机停在 iOS 直到长按电源）
bash tools/prepare_run.sh relink/kernel-0262 boot-runNN 0 \
  "pandora_thumbs_start=120 pandora_thumbs_every=60"

# 2) 跑一轮（自动 fastboot boot → 等回安卓 → 拉日志 → 解码 + 出图）
bash tools/run_boot.sh boot-runNN/loader-boot.img runNN 400

# 2b) 手动流程：只拉上一轮的日志（手机手动重启回安卓之后）
bash tools/pull_log.sh NAME

# 2c) 把手机上的 pinned 镜像拉回主机（保住 lsd 建好的 LaunchServices 库，约 10 分钟）
bash tools/pull_root.sh

# 3) 只有需要干净基线时才恢复镜像（约 5 分钟，且下一次开机要 14 分钟重建 lsd 库）
bash tools/restore_root.sh [镜像路径]

# 4) 推文档/补丁
GITHUB_TOKEN=$(tr -d '\r\n' < .gh_token) python tools/gh_push.py \
  --repo yechenan/pudding-ios --dir pudding-standalone --branch main --message "..."
```

## 手动调试的工作方式（2026-10-29 起）

`bash menu.sh` 是本机入口：菜单第 1 项**不设时间窗口**（不传 `pandora_reboot_after`），
iOS 会一直跑，屏幕上看到什么就停在哪；要回安卓就长按电源 ~10 秒。
内核每秒把日志写进 pinned 的 `ioslog.img`，所以**手动重启也不丢日志**——回安卓后菜单第 5 项
（或 `tools/pull_log.sh NAME`）能把这一轮的日志和缩略图拉出来。

要点：

- 无窗口的轮次没有"自动回安卓"，所以**不要**再用 `tools/run_boot.sh` 等它——
  它在等 `sys.boot_completed`，会一直等下去。
- 造镜像仍然必须在**安卓**状态（菜单会检查），因为 `prepare_run.sh` 要 `pinfile extents`。
- 一轮 iOS 不重启就不会自己结束；改内核/参数前先想清楚这轮要看什么。


## 必须知道的 22 个坑（每条都真实踩过）

### 启动 / 镜像

1. **第一次开机 14 分钟不是挂死**。SpringBoard 在等 `lsd` 重建 LaunchServices 数据库
   （`__LAUNCH_SERVICES_IS_RESEEDING_ITS_DATABASE_AND_MAY_BLOCK__`），上游说约 25 分钟。
   同一个镜像**第二次起只要 ~70 秒**。实测：run37 首次 present 在 **835.3 s**，run38 只要 **59.1 s**。
   所以：不要每轮都恢复镜像，恢复了就要等 14 分钟。**任何"看 UI 出不出来"的轮次窗口必须 ≥1500 s**，
   否则结论全是"被自己掐死的"。
2. **恢复镜像会丢掉运行时创建的目录**。典型：`/private/var/keybags` 是 fw pack 在运行时建的；
   如果从本地镜像重写回去，这个目录就没了，下一次开机会在 12 秒时
   `FATAL KEYBAG ERROR: kb_load → REBOOTING INTO RECOVERY MODE`。恢复后先确认：
   `guestfish ... mkdir /private/var/keybags; chmod 0700`。
3. **`adb push` 写到 pinned 文件里是密文**（/data/local/tmp 是 FBE）。必须用
   `pinfile rawwrite`（`tools/restore_root.sh` 已经封装，约 1m50s）。
4. **libguestfs 遇到脏卷只肯只读挂载**。清除 HFS 卷属性（偏移 1028 处的 4 字节大端：
   清 0x2000 journaled、置 0x100 unmounted）可以强制 rw，但**这样写回去会让
   `hfs_mark_inconsistent` 爆到几千条**（run36 实测），之后系统行为不可信。优先 `fsck.hfsplus -fy`。
5. **guestfish 的 `mkdir-p` 对深路径会失败**（"No such file or directory"），要一层一层 `mkdir`，
   并且用 `-mkdir` 前缀忽略"已存在"。

### 启动参数

6. **`sweetnoexec=Setup` 会让 SpringBoard 永远停在苹果 logo** —— 它在等 Setup 启动。
7. **`sweetnoexec=mobileactivationd` 等价不了"没有这个服务"**：进程被挡住，但 launchd 仍然
   注册着 MachServices，客户端连上来就卡住，整机卡死。要"没有激活服务"，只能让 job 表里那条
   **没有 MachServices**（`/usr/bin/true` 桩）。
8. **`ignition_level=1` 在本镜像上会崩**：libignition 在 level≥2 才挂 preboot/cryptex，
   level 1 时 `/usr/lib/libobjc-trampolines.dylib` 不存在 →
   `couldn't dlopen libobjc-trampolines.dylib` → SpringBoard 崩 200~400 次。
   要用上游那套参数，必须先把 cryptex 里的文件硬链接到根卷（见下一条）。
9. **上游 `fuxi-stage-root.py` 的 staging 是必需的**：把
   `/private/preboot/Cryptexes/{OS,App}` 里每个文件 `ln` 到根卷同名路径（我们的镜像是 3140 个条目），
   外加 `/private/var/db/{diagnostics,uuidtext,diagnostics/timesync}` 和 `/private/var/keybags/systembag.kb`。
10. **`pandora_gesture` 和 `pandora_touch` 是两个不同的参数**：后者是触摸驱动，前者是手势注入；
    混用会把触摸驱动也打开。

### 看屏幕 / 操作

11. **帧转储只在 present 时触发**。Setup 的静态页面几乎不 present，所以"到点截图"抓不到；
    `pandora_fbdump=20` 能抓到过渡帧，但最后一张常停在动画中间。
12. **最可靠的"看屏幕"是缩略图**：`pandora_thumbs_start/_every`，60×130 的灰度，能认出页面和布局
    （文字读不出来）。`tools/thumbs.py` 渲染成 PNG。
13. **点击坐标必须按像素量**：截图是 375×812，呈现坐标要 ×3（1125×2436）。
    我就是靠重新量 `Connect to Mac or PC` 的矩形（y 370–430）才发现之前点空了 250 px。
14. **Setup 的 Wi-Fi 页有隐藏出口**：点 `Connect to Mac or PC`（**561,1200**）会弹
    "Continue without Wi-Fi?"，Continue 在 **(378,1383)**；Back 在 **(120,200)**。
15. **`pandora_kill=NAME:SECONDS[:REPEAT]`**（kernel-0257）能在指定时刻 SIGKILL 某个进程，
    用于测试"UI 等待别的进程"这类场景。

### 工具链

16. **`prepare_run.sh` 需要 adb**（要读 extents）。手机在 iOS 里时会报
    `adb.: no devices/emulators found`，所以造镜像必须在安卓状态下做。
17. **不要在一轮还没回来时又起一轮**。run33 就是这么废掉的（`adb reboot bootloader` 失败，
    后面全乱）。一轮之间看 `job_output` 或 `adb devices`。
18. **`PD_CMDLINE` 覆盖**：`tools/prepare_run.sh` 支持 `PD_CMDLINE="... @WINDOW@ ..."` 整套替换
    内核命令行（默认那套带 `-v`，上游那套不带）。
19. **本地编 C++ 还不行**：`iokit/Kernel/arm/SweetFramebuffer.cpp` 本地编译会在
    `AppleARMBacklight` 处报错（`does not refer to a value`），所以涉及它的改动（例如
    `pandora_fbdump_at` 定时转储）只能靠 CI 的 .o 重链接，暂时用不上。
20. **写 C 代码时别用 Python heredoc 拼 `\n`**：会写成真换行把字符串切断
    （`printf("... <换行> ")`），编译报 "expected expression"。用 edit 工具写带转义的字符串。
21. **`pandora_fbdump_at=SECS` 会把整轮打死**（kernel-0262 实测）。到点后 `sweet_fb_dump_now()`
    先要一块 12.9 MB 的内核缓冲，分配失败 → `kmem_alloc(...) failed with 3` → 内核重启。
    run39（300 s）死在 300.175 s，run42/run43（600 s）死在 600.187 s。
    **不要再用这条参数**；要看画面用 `pandora_thumbs_*`，要全帧就等以后把 dump 的内存改成预分配。
22. **`pandora_reboot_after` 不传 = 不自动回安卓**。手机停在 iOS，直到长按电源 ~10 秒；
    日志每秒落盘，手动重启后照样能用 `tools/pull_log.sh` 拉回来。`menu.sh` 第 1 项就是这个模式。

## 开机菜单（不用电脑也能选 iOS / 安卓，2026-10-29 起）

移植自上游 `ShueiTsuki/data-a-live/bootmgr`，源码在 `work-bootmgr/`（`build-pudding.sh` 是
pudding 版打包脚本）。

**做了什么**：`boot_a` 现在不只是安卓内核，而是一段菜单程序 + 2 MiB 处的原装安卓内核 +
后面的 iOS 槽位（整个 96 MiB 分区镜像，sha256 `06dbccf1…`，原装 `boot_a` 备份 `dbf0c13e…`）。

**开机时**：正常开机时屏幕下方出现 `Volume up  iOS  5` 倒数 5 秒。
- 这 5 秒内按**音量上** → 从槽位启动 iOS（**没有时间窗口**，不会自己回安卓，长按电源回安卓）；
- 不按 → 原样进安卓（菜单把原装内核交出去，和原装开机一样）；
- 充电器/静默等其它开机模式 → 直接进安卓，不显示这行。

**换 iOS（菜单和安卓都不动）**：

```bash
bash tools/bootmenu_slot.sh            # 只检查
bash tools/bootmenu_slot.sh --yes      # 重造 loader（窗口=0）+ 写槽位 + 读回核对
# 或：bash menu.sh 第 8 项
```

它做三件事：读手机上三个 pinned 文件的**当前** extents → 用它们重造 loader（payload 的 ADT 里
就带着这些 extents）→ `slot.py` 打槽位包 → 手机端 helper **只写槽位那一段**，写完读回核对，
槽位以外的字节必须没变。

**必须记住的一条规则**：**任何改动 pinned 根镜像的操作（`restore_root.sh`、手工编辑后推回）之后，
都要重新跑一次 `tools/bootmenu_slot.sh --yes`。** 槽位里记着建包时三个文件的 extents 指纹；extents
一变，旧槽位的 iOS 会读到/写到别的块上 —— 那不只是一个"进不去"的问题，是**会写坏安卓数据**。
（上游用 `bootmgr/guard/` 那个 Magisk 模块在开机时核对指纹并自动把槽位 `armed` 清 0；我们还没装，
所以现在靠这条纪律。）

**回滚**（菜单有问题、安卓起不来时）：音量下+电源 进 fastboot，然后

```bash
fastboot flash boot_a backup/pudding-stock/boot_a.img   # sha256 dbf0c13e…，原装
```

**只进内存地试菜单**（不写任何分区）：

```bash
# 调试版：任何开机模式都显示调试数字 + 倒数 9 秒
wsl -d Ubuntu2404 -e bash -lc "cd /mnt/c/Users/叶晨安/Desktop/Apple/work-bootmgr && bash build-pudding.sh --slot-from ../../boot-slot/loader-boot.img --any-mode --wait-ms 9000"
fastboot boot work-bootmgr/out/boot-menu.img
```

**移植时核对过的设备条件**（都是必须对上的）：
- 音量上 = TLMM GPIO 101（`0x0f165000`，低有效），和我们 `fuxi_keys.c` 里的常量一致；
- 帧缓冲 `0xfc800000`、1220×2656、stride 4880；
- 正常开机的 bootargs 里有 `bootmonitor.bootmode=normal` / `mca_log.charge_boot_mode=0` /
  `silent_boot.mode=nonsilent`（菜单用它判断"是不是普通开机"）；
- `/chosen/linux,initrd-start|end` 是 8 字节属性（菜单要拿它们确认不与内核区重叠）；
- 我们这台 **A 槽在用、B 槽全 0**，所以菜单只能写 `boot_a`（上游那台写的是 `boot_b`）。

## 现在的两个死结（按优先级）

### A. Setup 为什么没被跳过（挡在锁屏前的最后一道）

镜像里已经有 `com.apple.purplebuddy` 的
`SetupDone=true / SetupFinishedAllSteps=true / SetupVersion=11 / daemonizeNeedsToRun=false`
（`pandora_cat` 在运行中读出来也是 `true`，十六进制 `09`），**但 Setup 照样启动**
（run38：SpringBoard 59.1 s present 锁屏，59.15 s `exec Setup`）。

2026-10-29 已排除的：

- **"抄上游 Setup 段"是空操作**：上游 `ios-fuxi/tools/sweet-root-tweaks.py` 的 Setup 段与我们
  `tools/root_tweaks.py` **逐键相同**（5 个 plist、`/private/var/mobile/Library/Preferences/`、
  501:501 0600、binary plist），从镜像里读回来的值也对；
- **启动参数不是原因**：上游 `tools/ios_test.sh` 的参数与 run40/41 完全相同；
- **补丁序列不是原因**：我们停在 0262，上游 0263–0295 全是亮度/音频/oslog/pathlog/installer-rename，
  没有一条与 Setup 相关（他们 0262 时代就进桌面了）。

剩下的真实差异（下一步验证）：

- **他们的 `mobileactivationd` 是真 job（有 MachServices），我们桩成 `/usr/bin/true` 且 0 个
  MachServices**。他们的结论是激活走 ADT 安全状态 + 本地 Hactivation。要验证"mad 不在"是否正是
  SpringBoard 判定要跑 Setup 的原因。
- 想直接看判定理由：给 `com.apple.SpringBoard` 的 launchd job 加 `OS_ACTIVITY_DT_MODE=YES`
  （上游 `sweet-root-tweaks.py --oslog` 的做法），os_log 会经 `sweetnull` 进内核日志。
  注意这会走一次镜像改写 + 推回（≈一次 835 s 的 lsd 重建）。

### B. `mobileactivationd` 一启动就崩（激活）

- 现象：`CRASH mobileactivation sig 5 code 0x600000001 sub 0x100cb13bc`，每次开机崩 100+ 次，
  崩点在 `copyReverseProxyDictionary`。
- 已试无效：补 `SystemConfiguration/preferences.plist`；手工造它的容器 + `data_ark.plist`
  （`-ActivationState=Activated` 等 6 个键）；`sweetnoexec` 挡住它。
- 上游的结论是：**激活靠 ADT 的 `/chosen` security-status 属性**（Hactivation 本地分支），
  他们那台机器 `mobileactivationd` 的系统容器也不存在、激活数据包直接跳过。
- 所以如果 A 解决了（Setup 不跑），B 也许根本不用修 —— 先攻 A。

## 上游值得抄的东西

| 文件 | 用途 |
|---|---|
| `ShueiTsuki/data-a-live/PLAN.md` | 全局进度、每个子系统踩坑记录（GPU/声音/亮度/电量） |
| `bangprovn/ios-fuxi/tools/fuxi-stage-root.py` | cryptex 硬链接 + /var/db + keybag 的 staging（**我们缺这步**） |
| `bangprovn/ios-fuxi/tools/sweet-root-tweaks.py` | 36 KB 的完整 tweaks（我们只有 6 KB 的 ios-sweet 版） |
| `bangprovn/ios-fuxi/tools/mkiosroot.sh` | 从 iPSW 的三份 APFS 卷（System/Data/App）拼 HFS+ 根 |
| `ShueiTsuki/data-a-live/ios_test.sh` | 启动参数（`ignition_level=1 launchd_unsecure_cache=1 wdt=-1 …`） |
