# 交接：现状、下一步、以及踩过的坑（2026-10-29）

这份文档是给"下一次会话/下一个人"的：先看这里，不用重新踩一遍。

## 一分钟现状

- 手机：小米 17（pudding / SM8850），iOS 16.7.16（20H392，iPhone X 的 iPSW）。
- 已经做到：**内核能启动、iOS 用户态能跑、界面能渲染（SpringBoard 出画面）、能用内核注入点击操作**。
- 还卡在：**Setup（设置向导）过不去 → 进不了锁屏/桌面**。
- 上游同机型仓库已经到桌面：`ShueiTsuki/data-a-live`（作者机器上锁屏/桌面/GPU/触摸/音量都能用），
  镜像侧脚本在 `bangprovn/ios-fuxi`。

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
# 1) 造一轮启动镜像（手机必须在安卓、adb 可见；会读 pinned 文件的 extents）
bash tools/prepare_run.sh relink/kernel-0262 boot-runNN 400 \
  "pandora_fbdump=20 pandora_thumbs_start=50 pandora_thumbs_every=10 pandora_gesture=90:2:562,2400,562,1100"

# 2) 跑一轮（自动 fastboot boot → 等回安卓 → 拉日志 → 解码 + 出图）
bash tools/run_boot.sh boot-runNN/loader-boot.img runNN 400

# 3) 只有需要干净基线时才恢复镜像（约 5 分钟，且下一次开机要 14 分钟重建 lsd 库）
bash tools/restore_root.sh [镜像路径]

# 4) 推文档/补丁
GITHUB_TOKEN=$(tr -d '\r\n' < .gh_token) python tools/gh_push.py \
  --repo yechenan/pudding-ios --dir pudding-standalone --branch main --message "..."
```

## 必须知道的 20 个坑（每条都真实踩过）

### 启动 / 镜像

1. **第一次开机 14 分钟不是挂死**。SpringBoard 在等 `lsd` 重建 LaunchServices 数据库
   （`__LAUNCH_SERVICES_IS_RESEEDING_ITS_DATABASE_AND_MAY_BLOCK__`），上游说约 25 分钟。
   同一个镜像**第二次起只要 ~70 秒**。所以：不要每轮都恢复镜像，恢复了就要等 14 分钟。
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

## 现在的两个死结（按优先级）

### A. Setup 为什么没被跳过（挡在锁屏前的最后一道）

镜像里已经有 `com.apple.purplebuddy` 的
`SetupDone=true / SetupFinishedAllSteps=true / SetupVersion=11 / daemonizeNeedsToRun=false`
（`pandora_cat` 在运行中读出来也是 `true`，十六进制 `09`），**但 Setup 照样启动**。
上游用同样的偏好就跳过了，差别还没找到。已知的候选：

- 我们的镜像不是他们 `mkiosroot.sh + fuxi-stage-root.py + sweet-root-tweaks.py` 的产物，
  `/private/var` 是手工补的骨架，可能缺他们那套 Data 卷内容；
- 他们的 tweaks 版本（`ios-fuxi/tools/sweet-root-tweaks.py`，36 KB）比我们用的
  ios-sweet 版（6 KB）多很多项，Setup 那一段可能还有别的键；
- 值得试：把他们的 `sweet-root-tweaks.py` 里的 Setup 段原样抄过来重打镜像。

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
