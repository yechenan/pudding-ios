# 错误记录（每犯一条必须追加，不许只放在脑子里）

规则：**每犯一次错误，就在这张表最上面加一条**，写清"做了什么 / 后果是什么 / 以后怎么做"。
新条目放最上面（最新的在最前）。有具体证据的（轮次号、时间戳、日志行）必须写上。

| # | 错误 | 后果（证据） | 以后的规矩 |
|---|------|--------------|-----------|
| 40 | 用 `grep -n` 直接查内核日志 | 日志里有 NUL 字节，grep 只回 `Binary file … matches`，第 1 轮的日志分析白跑一遍 | 内核日志一律 `grep -a`（`tools/journal_run_report.sh` 已改） |
| 41 | 敲了一条不带长度的 `pinfile rawread` | 它开始把整份 17 GB 镜像往 stdout 吐，差点把 adb 拖死 | `rawread` 必须带 BYTES，或改用 `rawreadat PATH DEV OFFSET LEN`（带诊断前缀，按 HFSX 签名定位） |
| 42 | 以为 `guestmount` 里的 `st_ino` 是真的 | 两条硬链接路径报 ino=4 / ino=11（FUSE 自己编的号）；若照这个用 `rsync -H`，3140 个 cryptex 硬链接会被展开成两倍数据，16 GiB 装不下 | 硬链接分组只认 guestfish `stat`（它给的是驱动真 ino）；FUSE 视图的 inode 不可信 |
| 43 | 在 MSYS 脚本里写 `DEV="\\$(readlink -f …)"` | 本地 bash 先求值失败、留下单个反斜杠 → `pinfile rawwrite` 只收到一个 `\`，直接打 usage（写固件包时踩到） | 要让**手机端**展开就写单引号 `DEV='$(readlink -f …)'`，别用双引号加反斜杠 |
| 44 | 把 `pandora_gpu_perf=578` 当频率用 | 它是 `gpu_opps` 的**档位号 1..18**；578 MHz 是第 10 档，写 578 会被夹到顶档，钉频目的落空 | 改频率前先看 `pandora_gpu.c:1018` 的 `gpu_opps[]` 表 |
| 45 | 给 `run_boot.sh` 接 `tail -30` | 整轮 1000 秒看不到任何实时进度，用户问“是不是在建表”时只能靠算 | 长任务不要接 `tail`，输出直接落文件后 `tail -f` |
| 46 | 用 `grep -rl` 全工作区找字符串 | 扫到 4 份 17 GB 镜像，两分钟不出结果 | grep 一律限定目录并排除 `*.img` |
| 33 | 用 `-e _start` 去链接 C 函数 `_start`（C 符号实际是 `__start`） | 包装器一启动就 `missing symbol called` 崩掉 | C 里写 `void start(void)`，符号才是 `_start`；链接后 `llvm-nm -u` 必须为空（`dyld_stub_binder` 除外） |
| 34 | `-nostdlib` 编译时没关栈保护 | 二进制引用 `___stack_chk_fail`，运行时 `missing symbol called` → SIGABRT | 静态 iOS 二进制一律加 `-fno-stack-protector -fno-builtin`，并检查 `llvm-nm -u` |
| 35 | 凭记忆猜 Darwin syscall 号（以为 `getcwd`=326） | 包装器收到 SIGSYS，诊断信息全丢 | 不用没验证过的 syscall；要用就先在真机上单独验一个小程序；诊断优先走 `open/fcntl/write` 这类已验证的调用 |
| 36 | 把“界面是西班牙语”直接推断成“cfprefsd 没读偏好”，据此否定了整条偏好路线 | 浪费数小时去猜哨兵文件路径；实际偏好是活的（`pandora_cat` dump 从 171 字节长到 273 字节，里面出现系统写的 `SBLastRestoreIdentifier`） | **先做能证伪的测量，再做推断**：怀疑某通道失效，就用 `pandora_cat`/日志证明它到底有没有工作 |
| 37 | 把反汇编标签前一行 `0x1c5aa5d00` 当成函数起点 | 补丁偏移算错（幸好字节断言拦住，没打错函数） | 函数起点要看标签行本身（这里是 `0x1c5aa5d58`）；打补丁一律用 `tools/patch_dyld_cache.py --dry-run` 先核对字节与哈希槽 |
| 38 | 把半截下载的 `NativeAdrenoMetal`（1.29 MB，真实 22 MB）当成产物 | 打包内容错，GPU 插件加载不起来 | staging 前必须核对 `SHA256SUMS` / `SHA256SUMS.metal`；大文件下载完先看大小与哈希 |
| 39 | 往 16 MiB 的 pinned 固件包里塞 39 MB 的 GPU 包 | 写不进（pack 就是那个 pinned 文件本身） | 打包前先算总大小；现在 pinned 文件已 64 MiB，超过就 `pinfile create … 128` 重建并重写 |
| 32 | 用子缓存头里的 mapping 直接算 VMA→文件偏移就动手打补丁 | 在 `dyld_shared_cache_arm64.21` 上算出的偏移指向了别的函数（幸好补丁前有字节断言拦住） | **打补丁前必须断言目标处的指令字节**；子缓存里的偏移不一定是文件偏移（.11 能用、.21 不行），要先用已知函数序言的字节特征在文件里定位 |
| 30 | 直接改 dyld 缓存里的代码，没同步改 CodeDirectory 的页哈希 | 内核 4K 缓存校验拒绝：`check_signature[pid:1]: error = 85` → `dyld cache not loaded` → pid 1 起不来，2.8 秒死机，镜像一度不可启动（靠 cryptex 里那份原文没有、只能重新推镜像恢复） | 改缓存 = 改代码 + 重算该 16 KiB 块的 SHA-256 写回 CodeDirectory 槽位（CD 在文件尾 SuperBlob 里）；改前先把原文备份出来（这次幸好 `work-dyld/` 里有） |
| 31 | 两个 `restore_root.sh`（17 GB）重叠跑 | 两次写同一份 pinned 文件，最后落地的是哪一份不确定（这次靠 sha256 比对才发现是想要的那份） | 一次只跑一个长写盘任务，用 `job_list` 确认没有别的在跑 |
| 29 | 在用户还在摆弄手机时后台启动 12 分钟的 `restore_root.sh`（17 GB 写盘） | adb 中途掉线，`rawwrite` 只写了一半 → pinned 镜像状态未知（可能需要整份重写） | 长时间写盘/刷机前**先确认**“线插着、别动、别拔”，并在开头就说明要多久；恢复后必须跑 HFSX + 状态校验 |
| 28 | 以为"设备不在 adb/fastboot"就是卡死 | 用户只是拔了线，我一度准备按"菜单卡死"排查 | 没设备时先问一句/先等 30 秒，别直接判定故障 |
| 27 | 恢复镜像后没意识到 pinned extents 会变 | 差点用旧 extents 的槽位启动 iOS（会读写到别的块，写坏安卓数据） | 任何镜像改动之后**必须**重跑 `tools/bootmenu_slot.sh --yes` |
| 26 | 槽位里 logo 用了相对路径 | `mk_boot_local.sh` 先 `cd data-a-live/shim/loader`，相对的 `LOGO` 找不到 → 槽位 logo 0 字节，白写一次 | 跨目录前把路径 `realpath` 成绝对；`prepare_run.sh` 与 `mk_boot_local.sh` 都已补 |
| 25 | 把"运行时 HFS 损坏"当成写过滤器拒绝写 | 实际上 `SWEET UFS: refusing write` = **0 次**；真因是根卷"非日志式 + 脏挂载" → `hfs_mark_inconsistent` 303 次 + `containermanager` 崩 404 次（menurun1，0→994 s） | 看到 `hfs_mark_inconsistent` 先查两件事：卷属性（offset 1028 的 0x2000 journaled 位）和挂载时的 "dirty non-journaled" 提示 |
| 24 | 用默认参数（带 `-v`）造"给用户看画面"的镜像 | 用户看到的是滚动的内核文字，不是苹果 logo/进度条，白等十几分钟 | 用户要"看画面"就 `--quiet`（无 `-v` + `sweetfb_noconsole=1` + logo）；`-v` 只用于我自己要现场调试时，并且要提前说明 |
| 23 | 以为给 1500 s 窗口就是"不掐断" | 用户要的是"看它到底能不能进锁屏"，窗口再长也是掐断 | 用户说"看能不能进/等结果" → **不设窗口**（`pandora_reboot_after` 不传）+ thumbs 做时间线 |
| 22 | 用 900 s 窗口跑"看 UI 出不出来"的实验 | lsd 首次建表要 **835 s**（run37 实测），run41/42/43 全部在 present 之前被自己掐死，结论全部作废 | 看 UI 的窗口 ≥1500 s；更稳的是不设窗口 |
| 21 | 把 `pandora_fbdump_at` 当成普通参数带进轮次 | 到点 `sweet_fb_dump_now()` 要 12.9 MB 内核缓冲，分配失败 → `kmem_alloc(...) failed with 3` → 内核重启：run39 死在 300.175 s、run42/43 死在 600.187 s | 新内核参数先用 ≤120 s 的窗口冒烟；`pandora_fbdump_at` 在 0262 上一律不带 |
| 20 | 把 run41–43 的"no present / no Setup"当成新故障 | 实际是"835 s 建表"+"600 s 自灭"两个已知坑叠在一起，浪费了一轮推理 | 下结论前先画时间线：exec → 首次 present → 崩溃点，和已知阈值对照 |
| 19 | 直接用 `dd` 读手机上 pinned 文件来核对卷头 | 读到的是 FBE 密文（乱码），差点误判"镜像头不对" | pinned 文件一律 `pinfile rawread`；`/data/local/tmp` 走 VFS 是密文 |
| 18 | 用 `strings` 判断内核里有没有某个 boot-arg | 这台机器上的 `strings` 对 Mach-O 返回 0 个匹配，我一度以为参数不存在 | 用 `grep -a`/`grep -ao` 查二进制字符串 |
| 17 | 先建槽位、后恢复镜像（顺序反了） | 恢复镜像会改 extents，槽位就作废 | 固定顺序：改镜像 → `restore_root.sh` → `bootmenu_slot.sh --yes` → 启动 |
| 16 | 把 fsck 的"volume appears to be OK"当成"运行期也没问题" | fsck 只验盘上结构；运行期损坏来自挂载状态（脏卷被强制读写挂载） | 区分"盘上损坏"（fsck 管）和"脏挂载"（卷属性/journaled 位管） |
| 15 | 相信环境里给的时间戳 | 环境 sample time 与 `date` 差了几分钟，我按错的时间估窗口 | 一律以 `date` 为准 |
| 14 | 假设上游 `sweet-root-tweaks.py` 的 Setup 段和我们不同 | 逐键比对后**完全相同**，"抄 Setup 段"是空操作，白花时间 | 先 diff 再动手；差异要在文件级确认 |
| 13 | 把"devices.toml 里有 pandora"当成 UniXNU 有额外方案 | 它指向的就是我们已经在用的 `ShueiTsuki/data-a-live` | 看仓库先看它 pin 的是哪个 device repo |
| 12 | 以为 `-v` 只是"多一点日志" | 它决定 loader 画字还是画 logo（`wants_verbose()` 读命令行里的 `-v` 词） | 改命令行前先看 loader/kernel 怎么用这个词 |
| 11 | 在 iOS 运行期间尝试 adb 操作 | iOS 里没有 adb，`prepare_run.sh` 直接失败 | 造镜像/写槽位/拉日志都只在安卓状态做 |
| 10 | 一次会话里连续跑多轮而没有先把上一轮结论写进文档 | 上下文丢了就要重推 | 每轮结束立刻追加 PUDDING_STATUS 并推送 |
| 9 | 把 `pandora_reboot_after` 的默认值留在 `mk_boot.sh`/`mk_boot_local.sh` 里 | 绕过 `prepare_run.sh` 直接调就会带上窗口 | 默认值也要清（已清）；默认必须是"不自动重启" |
| 8 | 用 `sweetnoexec=bluetoothd,fairplayd.H2`（照搬上游） | 我们内核上变成 "Too many corpses" + `kmem_alloc` 失败（run42，599 s） | 上游参数必须逐项验证，不能整套照搬 |
| 7 | 用 `sweetnoexec=Setup` 想"屏蔽 Setup" | SpringBoard 永远停在苹果 logo（它在等 Setup） | 要"没有这个服务"只能改 job 表（去掉 MachServices），不能挡 exec |
| 6 | 为了强制 rw 去清 HFS 卷属性（0x2000 journaled 位） | 卷变成非日志式，硬复位后必脏，脏挂载让 HFS 每次写都判损坏 → containermanagerd 死循环（menurun1） | 不要清 journaled 位；要写镜像就 `fsck.hfsplus -fy`，长期方案是重建日志式卷 |
| 5 | 每轮都恢复镜像 | 每次都要重等 835 秒建表（pitfall 1） | 只在需要干净基线时恢复；平时用"干净镜像 + 不硬复位"或重建日志卷 |
| 4 | 用 40–100 秒的窗口判断"有没有 UI" | 那时连 SpringBoard 都还没 exec，结论无意义 | 判断 UI 至少 900 s 起，实际 ≥1500 s |
| 3 | 把 `pandora_gesture` 当成触摸驱动参数 | 混用会把触摸驱动也打开 | 两个参数分开记：`pandora_gesture` 是注入，`pandora_touch` 是驱动 |
| 2 | 按截图估算点击坐标 | 估错 250 px，白点四轮 | 坐标必须按 375×812 截图量出来再 ×3 |
| 1 | 在一轮没回来时又起一轮 | run33 整轮报废（adb reboot bootloader 失败） | 一轮没结束（`adb devices` 看不到安卓）就不许起下一轮 |

## 每次收尾的检查单

1. 这一轮的结论（含失败原因）写进 `docs/PUDDING_STATUS.md` 了吗？
2. 这一轮犯的错写进本文件最上面了吗？
3. 有没有新的"默认参数"需要改掉（窗口/`-v`/`fbdump_at`/`sweetnoexec`）？
4. 改过镜像吗？改过就必须 `tools/bootmenu_slot.sh --yes`。
5. 推送了吗（`tools/gh_push.py`）？
