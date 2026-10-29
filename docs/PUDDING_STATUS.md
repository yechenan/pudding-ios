# pudding 进度（2026-10-28）

| # | 版块 | 状态 | 证据 |
|---|---|---|---|
| 0 | 环境与基线 | ✅ | 解锁（orange）、KernelSU root、24 个分区备份 + SHA-256 |
| 1 | 引导与上屏 | ✅ | `fastboot boot` 自编镜像；EL1、FB `0xFC800000` 1220×2656 stride 4880 |
| 2 | 内核上台 | ✅ | `8/8 CPUs initialized`、`init running as PID 1`、调频 2273/1988 MHz |
| 3 | 存储 | ✅ | UFS 只读 34 分区；16 GiB 固定文件 2040 段；写入 4194304 块，sha256 与镜像一致 |
| 4 | 显示与输入 | 🟡 | 显示驱动免改即用；触摸驱动在跑（GPIO 158）；亮度/按键待真人验证 |
| 5 | iOS 用户态 | 🟡 | `hfs: mounted iOSRoot`、launchd 已加载；**卡在 exec 签名校验（CS_KILLED）** |
| 6 | 外设 | ⬜ | GPU / 声音 / 电量：与 pandora 同款配置，等系统起来 |
| 7 | 可选 | ⬜ | 不接电脑启动（B 槽为空）、Wi-Fi |

## 当前卡点

`process_signature()` 拒绝 launchd 的 exec：

- AMFI 策略已生效（`SWEETAMFI ... rootfs 1`，根卷带 `MNT_ROOTFS`，标为 platform binary）；
- 不是页校验（`cs_debug=1` 无 `CODE SIGNING:` 输出）；
- `cs_enforcement_disable=1` 无效；
- 正在用补丁 `0241` 在 `process_signature` 里打印 `ip_csflags / ip_mac_return / ip_cs_error` 定位。

## 已知约束

- 内核必须在 macOS 上编（CI 排队时间不可控，高峰可达 1 小时以上）；
- `cpus=1` 会触发 `ml_get_max_cpu_number` 断言，启动一律用 `cpus=8 bootcpu=7`；
- 日志文件（补丁 0129）必须 `ufsrw=1` 才会 flush。

## 2026-10-28 进展：iOS 用户态已执行

启动参数（关键）：

```
debug=0x0 serial=3 cpus=8 bootcpu=7 keepsyms=1 -v rd=ufsroot0 ufsrw=1 rootrw=1
pandora_touch=0 pandora_keys=0 pandora_reboot_after=180
unentitled_ios_sim_launch=1 cs_enforcement_disable=1
```

| 里程碑 | 证据 |
|---|---|
| launchd 不再被签名杀掉 | `unentitled_ios_sim_launch=1`（绕过 macOS 目标内核上的 no-sandbox 检查） |
| dyld 共享缓存找到并映射 | 补丁 0241 之外，靠 `cs_enforcement_disable=1` 跳过 uid=0 / trust cache 检查 |
| 共享缓存全量加载 | `PANDORA CS4K: dyld_shared_cache_arm64.01 … .42`，4 GB，12 秒 |
| launchd 执行 | `exec launchd`、`libignition: hello from launchd.1` |

### 当前卡点：preboot 卷

```
libignition: preboot: mounting preboot
libignition: failed to lookup preboot: 25
ERROR: BindFS bindfs_mount: lookup of /private/preboot/5CBE36…/usr/standalone/firmware failed error: 2
com.apple.xpc.launchd <Notice>: No cookie: /private/preboot/5CBE36…/.roots-installed
→ MACH Reboot
```

libignition 查 preboot 走 **IOKit 的 `IOGetApfsPrebootUUID`**（不是 `kern.apfsprebootuuid` 这个 sysctl——补丁 0242 改的是 sysctl，因此没解决它）。

### 下一步（一次做完）

1. 把 preboot UUID 固定为常量 `00000000-0000-0000-0000-000000000001`；
2. 内核：让 `IOGetApfsPrebootUUID` 返回该常量（iokit/Kernel）；
3. 镜像：建 `/private/preboot/<该 UUID>/usr/standalone/firmware` 与 `.roots-installed`；
4. 一次构建 → 一次写盘 → 启动。

### 镜像构建的两个关键修复（已生效）

- dyld 缓存必须链到 `/System/Library/Caches/com.apple.dyld/`，文件是 `dyld_shared_cache_arm64`（**不是 arm64e**），且要用 **iOS 的**那份，不能用 `System/DriverKit/...`；
- 缓存文件的 uid 必须是 0（macOS 建镜像要 `hdiutil attach -owners on`），否则 `shared_region_map` 报 `owned by uid=501`。

### preboot UUID 的正确做法（2026-10-28 定位）

`IOGetApfsPrebootUUID()`（`iokit/bsddev/IOKitBSDInit.cpp`）的实现是：

```c
IORegistryEntry::fromPath("/chosen", gIODTPlane)->getProperty("apfs-preboot-uuid")
```

**它读的是设备树里 `/chosen/apfs-preboot-uuid` 这个属性**，不需要改内核。

因此正确修法是：

1. ADT 的 `/chosen` 下加 `apfs-preboot-uuid = "00000000-0000-0000-0000-000000000001"`；
2. 镜像里按同一个 UUID 建
   `/private/preboot/00000000-0000-0000-0000-000000000001/usr/standalone/firmware`
   和同目录下的 `.roots-installed`；
3. 内核补丁 0242（改 sysctl）可保留也可删——它不是 libignition 走的那条路。

这样 `get_preboot_uuid()`、libignition 的 IOKit 查询、BindFS 的路径拼接三处会同时对齐。

### 2026-10-28 验证：ADT 的 apfs-preboot-uuid 不解决问题

在 `/chosen` 里加了 `apfs-preboot-uuid` 后重启，libignition 仍然：

```
libignition: preboot: mounting preboot
libignition: failed to lookup preboot: 25
libignition: preboot: failed to get preboot device: 25
```

而且 BindFS 用的 UUID 是 `5CBE3601…`（长哈希，与 ADT 里设的常量不同）。

结论：**libignition 要找的是一个 preboot "设备"（IOKit IOService/IOMedia），不是一个 UUID 属性。**
HFSX 根上没有这类设备，所以返回 ENOTSUP(25)。

### 下一步的两个方向

1. **在 IOKit 里造一个虚拟 preboot 设备**（SWEET 内核里 publish 一个带 preboot 角色的 IOService/IOMedia，
   让 libignition 的 IOService 匹配成功）——工作量中等，需要读 libignition 的匹配条件；
2. **绕过 libignition**：它只是启动序列的一部分，可以尝试让 launchd 以 `-x`/单用户等模式跳过
   （需确认 launchd 的参数支持），或 patch launchd 的启动路径——但二进制补丁需要 HFS 写能力。

在动手之前，先确认 libignition 到底匹配什么：从 IPSW 的 dyld 缓存里反汇编 `libignition_core`
或 `libignition.dylib` 的 preboot 查找函数，看它用的 IOKit 类名/属性。

### 2026-10-28 反汇编结果：不是 IOKit，是 APFS 专用的 fsctl + sysctl

先纠正上一条的猜测。libignition **不在独立的 dylib 里，而是静态链在 `/usr/lib/dyld` 中**
（日志里的 `root:libignition-51~1974/libignition_core/RELEASE_ARM64`）。dyld 的符号表还留着
`_ignition_get_devnode_by_role`、`_ignition_get_mount_point_by_role`、`__preboot_fire`。

`__preboot_fire`（role = `0x10` = `VFS_PREBOOT_ROLE`）的顺序是：

1. `_ignition_get_devnode_by_role(0x10, buf)` → 对 `"/"` 发
   `fsctl(fd, 0xc1044a50, …)`，即 **`_IOWR('J', 80, 260)`**，缓冲区是
   `struct { u8 op=2; u8 pad; u16 role; char devnode[256]; }`（260 字节）。
   HFS+ 没有这个 APFS 命令，命令落到 `VNOP_IOCTL` 返回 **ENOTSUP(25)** ——
   就是日志里的 `failed to lookup preboot: 25`。
2. `_ignition_get_mount_point_by_role(0x10, path, &out)` → 读
   **`sysctl vfs.generic.apfs.edt_fstab`**：一张 236（0xEC）字节一条的记录表，
   挂载点字符串在 `+0x20`，`u32` 卷角色在 `+0xE8`，命中 role 后拷出路径。
3. `open(mount_point, O_DIRECTORY…)` + `fmount("apfs", fd, MNT_DONTBROWSE, devnode, …)`。
   **返回 `EBUSY(16)` 时它打印 "preboot already mounted"，并用已经打开的那个目录继续**；
   只有错误不是 EBUSY 才算 ignition 失败。

另外两点推翻了之前的判断：

- **preboot 路径不是 UUID**，是 `/chosen/boot-manifest-hash` 的 96 位十六进制大写：
  `5CBE36011D7D…5205` = `sha384("sweet boot manifest")`。bindfs、`mount -P 1`、launchd 的
  `.roots-installed` cookie 都用这个值，所以改 `apfs-preboot-uuid` 当然没用。
- **preboot 阶段失败并不致命**：日志里 `ignite() returned 25` 之后 launchd 照样跑到 11.9 s，
  真正触发 `MACH Reboot` 的是 keybagd —— `/private/var/keybags/systembag.kb` 不存在，
  `MKB_INIT: Can't load the keybag … Rebooting`。preboot 只是链路里靠前的一环。

### 复现这套分析用的工具（本机可跑，不需要 macOS）

- `tools/decode_ios_dmg.py`：iOS 16 的 restore DMG 是 UDIF + LZFSE 分块，尾部 plist 里有
  每个分区的 `blkx`（mish）运行表；按运行表解码（0=空洞、1=原样、0x8000000x=LZFSE）就是原始
  磁盘镜像。把文件当成"一串 LZFSE 流"解会在第一个全零区失步。
- 解码后用 apfs-fuse 挂 `os.img -s 17408`，就能从 APFS 卷里直接取 `/usr/lib/dyld`。

### 下一步（已实现，补丁 0243）

内核里补齐这几件事，**不用重建 16 GiB 镜像**：

1. `fsctl` 的 `'J', 80` 返回根设备 `/dev/ufsroot0`（role 16）；
2. 注册 `vfs.generic.apfs.edt_fstab`，给出一条 role 16 → `/private/preboot` 的记录；
3. 注册一个名叫 `apfs` 的 vfs，`mount` 直接返回 `EBUSY`，让 libignition 走
   "already mounted" 分支；
4. 首次查询时按 `/chosen/boot-manifest-hash` 建
   `/private/preboot/<大写hex>/{usr/standalone/firmware,cryptex1}` 和 `.roots-installed`，
   这样 bindfs 的 `mount -P 1` 和 launchd 的 cookie 检查也有东西可查。

顺带修了 `xnu.yml`：`cp xnu/patches/*.patch xnu/patches/*.sh` 在没有 `.sh` 时会让整轮 CI 失败
（最近三次 xnu 运行都是这样挂的）。另外 step 3 只拷 `*.patch`，漏掉了
`0020-stage-bearssl.sh`（它把 BearSSL 装进 `libkern/crypto/sweet_bearssl`），
`libkern/crypto` 全部编译失败也是它。

### 2026-10-28 验证：preboot 和 keybag 都过了

同一版内核（run 40635027360）两次 boot 的结果：

**第一版 ADT**：preboot 三个阶段全部按预期走通，ignition 推进到下一步：

```
preboot: mounting preboot
preboot: preboot device: /dev/ufsroot0          ← fsctl 'J',80 由 shim 回答
preboot: preboot mount point: /private/preboot   ← sysctl edt_fstab 由 shim 提供
preboot: preboot already mounted: …              ← apfs vfs 回 EBUSY，走了 already 分支
cryptex1 sniff: detecting cryptex1 directory
cryptex1 sniff: ignition failed: 8               ← 新的坎：cryptex1 目录里没有东西
ignition disabled
```

ignition 失败仍然不致命，launchd 继续；接着 keybagd 因为 `systembag.kb` 是空文件、
MKB 解析不出字典而走 `systembag.kb.writing` 兜底失败（`Unable to load keybag with No Crypto: -7`）。

**第二版 ADT（加了固件包）**：反汇编 `MobileKeyBag` 的 `_KBLoadSystemKeyBag` 看清了格式 ——
`systembag.kb` 是 **binary plist 字典**，只要求字典里 `KeyBagKeys` 是一项 data
（`_getData` 非空即可），`_load_binary_dict` 用 CFPropertyList 解析。于是用
`mkfwpack.py` 做了 2 MiB 固件包（`files.txt` + 78 字节的
`{"KeyBagVersion":3,"KeyBagKeys":<空 data>}`），`pinfile create/rawwrite` 钉住后
`mkadt_pandora.py --fw-extents` 写进 ADT。结果：

```
PANDORA FILES: systembag.kb -> /private/var/keybags/systembag.kb (78 bytes)
MKB_INIT: System Keybag loaded
****** DONE MKB_INIT ****
```

keybag 不再是墙，重启消失，boot 直接推进到真正的用户态早期流程：
`usermanagerd`（建 501 session、99/199 号 persona）、`auearlyboot`、`tzinit`、
`sysstatuscheck`、`prng_seedctl`、`launchd_cache_loader` ……

**当前卡点：AMFI 的 IOKit 接口**

```
exec launchd_cache_loader
Code: /System/Library/xpc/launchd.plist Sig: /System/Library/xpc/launchd.plist.sig
abort: Unable to find AMFI
pid 21 exited … description Unable to find AMFI
PANDORA: restart type 4        ← kPEPanicRestartCPU，即 panic
```

`launchd_cache_loader` 要
`IOServiceGetMatchingService("AppleMobileFileIntegrity")` +
`IOServiceOpen("AppleMobileFileIntegrityUserClient")` 去装 trust cache；
SWEET 的 `bsd/kern/sweet_amfi.c` 只实现了内核侧的 `amfi_*` 接口，**没有 publish 这个
IOService**，于是 loader abort，随后内核 panic（panic 文本没进日志环，只有 restart type 4）。

下一步：在核心里 publish 一个 `AppleMobileFileIntegrity` IOService +
`AppleMobileFileIntegrityUserClient`，按 loader 用到的 selector 返回成功
（先反汇编 `/usr/libexec/launchd_cache_loader` 确认 selector 与参数）。

### 现在的迭代方式（不用每次重建 16 GiB 镜像）

- 内核改动 → 推 `xnu` 补丁 → `xnu.yml`（macOS runner，约 40 min）→ 下 artifact；
- 用户态文件（keybag、以后的 containers/配置等）→ `tools/mkfwpack.py` 打 2 MiB 固件包 →
  `pinfile create 2` + `rawwrite` → `mkadt_pandora.py --fw-extents` → `tools/mk_boot_local.sh`；
- 一次 boot 测试：`tools/boot_test.sh`（建镜像 → `fastboot boot` → 拉日志）。

### 2026-10-28 傍晚：AMFI 补丁卡在 CI 排队，不是代码

- `launchd_cache_loader` 要的东西已经完整反汇编出来：
  `IOServiceMatching("AppleMobileFileIntegrity")` → `IOServiceOpen(type 0)` →
  `IOConnectCallMethod(sel 6, cdhash)`，返回成功即"trusted"。补丁 0244 按
  `SweetKeyStore`（AppleKeyStore）的同一套写法 publish 服务和 user client。
- 顺带加了 `/private/preboot/cryptex1`（`cryptex1 sniff` 的 `fstatat` 失败会返回 8，
  上一轮 ignition 就停在那里）。
- **macOS runner 的坑**：
  - `macos-14` / `macos-13`（带 Xcode 15）今天傍晚整池不调度，连 `ping` 都排着；
  - `macos-15` 能给机器，但镜像只有 Xcode 16/26，`iig` 生成的代码用
    `IORPC.kernelContent`，xnu-8796 的 `IORPC` 没有这个成员 → 成片
    `OSObject.iig.cpp: no member named 'kernelContent'`；
  - 结论：内核必须跑在 Xcode 15 的池子上，只能等；`xnu.yml` 的 `runner` 输入默认
    已改成 `macos-15` 是错的，应改回 `macos-14`，`macos-15` 只用于非内核任务。
- 本地能做的验证都做了：`pandora_preboot.c`（CI 编译命令，0 error）、
  `SweetAMFI.cpp`（同一套 include/flags，0 error）、两个补丁 `git apply --check` 通过。
  上一轮的失败里有一个是真正的代码 bug（`printf` 字符串被写成跨行），已修。

### 2026-10-28 18:00 无人值守：补丁 0245 / 0246

- **0245**：`sweet_amfi.c` 里两个 CoreEntitlements 桩函数原来是 `panic()`，
  改成返回 `kCEQueryCannotBeSatisfied` / `NULL`。`launchd_cache_loader` abort 时
  会查自身 entitlements，一旦走到这里就把整机带走（日志里那次 `restart type 4`
  没有任何 panic 文本，很可能就是这种"无声 panic"）。
- **0246**：给 `IORPC` 增加尾部成员 `kernelContent`。macOS 15 的镜像只有
  Xcode 16/26，它们的 `iig` 生成的代码无条件读写 `rpc.kernelContent`，而
  xnu-8796 没有这个成员 —— 这就是 macos-15 上 34 个 `*.iig.cpp` 全灭的原因。
  前四个字段的位置不变，`IOUserServer.cpp` 里唯一的指定初始化会把新成员置零。
- `xnu.yml`：没有 Xcode 15 时优先选 **Xcode 16.x**（而不是 26.x），配合 0246
  就可以在 macos-15 池上构建，避开 macos-14 的排队。
- 本地验证：`sweet_amfi.c`、`IOUserServer.cpp` 用 CI 编译命令各跑一遍都是
  **0 error**；三个补丁 `git apply --check` 通过。
- 当晚 17:40–18:00 期间 **所有 macOS 池（13/14/15）都排不上机器**，连几十秒的
  `ping` 也被排到 15 分钟上限后取消，只能高频重派抢票。

- 18:10 追加：AMFI 服务的两次发布机会 —— 除了 preboot shim（~0.2 s），
  `pandora_files` 的内核线程在根卷挂载后 2 s 再试一次，
  避免 0.2 s 时 IOKit service root 还没建好导致服务永远不存在。
  另核对 `IOService::newUserClient` 的默认实现确实按
  `IOUserClientClass` 属性用 `OSMetaClass::allocClassWithName` 实例化
  user client（与 AppleKeyStore 同一机制），所以 `0244` 的写法成立。
- launchd 的 boot task 名字（从 `/sbin/launchd` 里取出，按上次日志的顺序）：
  `mount-phase-1 → data-protection → finish-obliteration →
  detect-installed-roots → commit-boot-mode → restore-datapartition →
  mount-phase-2 → init-with-data-volume → MSUEarlyBootTask → fips → keybag →
  usermanagerd → launchd_cache_loader`；之后才是 532 个 LaunchDaemons 的
  daemon 阶段。

- 18:35 试了「本地重链内核」这条路（绕开 macOS runner）：
  - 用 `xnu-objects` artifact 里的 1129 个对象 + `link.filelist` 的顺序 +
    `libfirehose_kernel.a` / `libclang_rt.cc_kext.a`，可以喂给 LLVM 的
    `ld64.lld`；它不认 `-alias_list`，但把 `all-alias.exp` 生成一份
    `符号 = 变体符号` 的汇编（`patchwork/mk_alias_asm.py`）就能补上；
    `-platform_version macos 13.5 14.0` 必须显式给。
  - 这样链接到只剩我们自己的两个符号（说明链路是可行的），但**卡在编译
    IOKit 的 C++**：`OSDefineMetaClassAndStructors` 依赖 Apple clang 的
    kalloc_type 插件，Ubuntu 的 clang 18 会在该宏上直接报
    "does not refer to a value"（对仓库里原本就能编过的 `SweetKeyStore.cpp`
    也一样）——所以本地能编 C、编不了这个 C++ 服务。
  - 结论：纯 C 的补丁可以在本地重链验证；但 `0244`（AMFI 服务）这种 C++ 的
    仍然必须走 CI。相关脚本：`tools/relink_local.py`。

### 2026-10-28 19:25 CI 失败的根因：0245 引用了内核没链接的符号

上一轮 macos-15 构建"编译全过、最后失败"。把失败 run 的 `xnu-objects` 拉下来和
`link.filelist` 逐条比对：**1129 个目标文件一个不缺**，说明死在链接。
`0245` 里的 `return kCEQueryCannotBeSatisfied;` 引用了 `CoreEntitlements` 的符号，
而内核根本没有链接这个库 —— 全仓库只有 `sweet_amfi.o` 在 `U` 引用它。已删除 0245。

顺带确认：那一轮在 **Xcode 16.4** 下把 1129 个对象全编出来了，说明 `0246`
（`IORPC.kernelContent`）**确实修好了 Xcode 16 的 iig 兼容**，macos-15 池可用。

**本地重链的边界**：用 CI 的 objects + `link.filelist` + 伪 alias + 给 CE 补空符号，
可以链接成功（20.9 MB），但 LLVM 18 的 `ld64.lld` 明确没有实现
`-image_base` / `-segaddr`，所有段落落在 `0x0`，而内核必须链在
`0xfffffff007004000` —— 产物不可启动，这条路只适合验证"能不能过编译/链接"。

## 2026-10-28 19:57 —— AMFI 墙过了，SpringBoard 起来了

新内核（run `40678846332`，commit `3739e4e7`：0243 preboot+AMFI 发布+重试、0244 AMFI
服务、0246 IORPC.kernelContent，0245 已删）真机启动结果：

- `[0.230] SWEET AMFI: AppleMobileFileIntegrity registered`
- `[12.135] launchd_cache_loader` **不再 abort**（上一轮就是死在这里）
- `[12.291] exec SpringBoard` / `[12.347] exec backboardd`，backboardd 正常打开
  `AppleKeyStore`（`SWEET AKS` 系列）
- `[13.902] SWEET AMFI: sel 9 unsupported` —— loader 用了 selector 9，我们返回
  unsupported 后它照样继续（不影响）
- 全程 **497 次 exec**，帧缓冲在动画：`SWEET FB: stats 600 frames in 5000 ms ...
  119.9 fps`、`14000 swaps`
- 一直是 180 s 后由 `pandora_reboot_after` 主动重启，**没有 panic、没有挂死**

日志：`out/ioslog-amfi.txt`（196 KB，上一轮只有 55 KB）。

**当前唯一卡点**：`mobileactivationd` 起来就 `SIGTRAP`（`CRASH mobileactivation[..]
sig 5 code 0x600000001 ... reason ns 2 code 0x5`），12 次后 launchd 报
"Too many corpses being created"。pc 每次都落在同一个偏移，是确定性断言而不是偶发。
下一步就是处理激活状态（或者让 mobileactivationd 认为设备已激活）。

### mobileactivationd 的 SIGTRAP（20:10 反汇编）

- 三次崩溃的 `pc` 相对 Mach-O 头的偏移完全一致：`mh + 0x1BF3BC`，
  而 `0x1BF3BC` 正是 `__text` 的末尾、紧挨 `__stubs`（`__stubs` 从 `0x1001BF778`
  开始）。那条指令是 `brk #0x1`，前面一串 `bl` 是这个二进制里共享的
  "trap 助手"（Swift `fatalError`/断言共用的收尾）。
- 所以真正的位置要看调用者：backtrace 给的返回地址 `mh + 0x50B674`。
  行为是**确定性断言**，不是随机内存问题。
- 同日整机状态：`exec` 497 次，`SpringBoard`、`backboardd`、`amfid`、`accountsd`、
  `CommCenter`、`homed` 等都在跑；帧缓冲持续在动画
  （`600 frames / 5000 ms ≈ 120 fps`、`14000 swaps`）；没有 `Setup`/`Buddy`。
- 结论：内核侧的启动链已经能一路走到用户态图形栈，剩下的问题是
  **激活状态/激活服务这层用户态逻辑**（以及后续的 setup 流程）。

### 20:30 对整机状态的判读

- `CRASH` 统计：整场只有 **mobileactivation 一个**（68 次），**SpringBoard 没崩**；
  SpringBoard 在 58.7 s 还在正常调用 `AppleKeyStore`（sel 0/35/7 都成功）。
- 也就是说：系统已经跑在一个"只有激活服务挂掉"的状态里，图形栈、KeyStore、
  sandbox、AMFI 都是通的。
- `mobileactivationd` 的断言点在 ObjC KVC 路径上（crash 前是一串
  `objc_msgSend`/`setValue:forKey:` 的调用），说明是它自己期望的某个
  "激活相关对象/状态"不存在，而不是内核少给了什么调用。

**下一步（按代价排序）**：

1. 让 `mobileactivationd` 不再致命：在 rootfs 里替换它的 launchd plist
   （`RunAtLoad=false`/改 KeepAlive），或直接替换/打补丁该二进制；
   这两件事都要**写根卷**，可以走已有的 fw-pack 安装路径（`pandora_files`），
   需要新内核。
2. 或者预置一个"已激活"状态（activation record / mad 目录），再看 SpringBoard
   是否直接进桌面。
3. 无论哪条，内核侧不再需要改动 —— 启动链已经打通。

### 20:45 重要发现：改用户态文件**不需要新内核**

`bsd/dev/pandora_files.c` 的固件包格式本来就支持把任意文件装到任意路径：
包里放一份 `files.txt`，每行 `包内名 权限 /绝对路径`（`- 权限 /路径` 表示建目录），
内核线程在根卷挂载后 2 s 把这些文件写进去（走 VFS，HFS 日志一致）。
现在的包只有一行：
`systembag.kb 0600 /private/var/keybags/systembag.kb`。

也就是说，下一步激活相关的实验（例如替换
`/System/Library/LaunchDaemons/com.apple.mobileactivationd.plist`、
预置 mad/activation 记录）**只需要重新打包 + 原地重写那个 2 MiB 的 pinned 文件**，
不用改内核、不用等 CI：

1. `python3 data-a-live/tools/mkfwpack.py pack/iosfw.img <文件...>`（包内再放一份新 `files.txt`）
2. `pinfile create` 已存在 → 直接 `rawwrite` 覆盖同一文件（extents 不变，ADT 不用重做）
3. `fastboot boot` 现有内核即可

限制：pinned 文件是 2 MiB（`PF_MAX_FILE` 也限制单文件大小），换 2.4 MB 的
`mobileactivationd` 二进制放不下 —— 要么换成小体积的 plist/记录，要么以后把
pinned 文件扩大。

### 20:55 mobileactivationd 断言点的一个线索

崩溃返回地址落在 `copyReverseProxyDictionary` 这个函数里（旁边还有
`copyReverseProxyDictionary` 的字符串字面量），这一段全是 `objc_msgSend` +
`setValue:forKey:` 的 KVC/字典拷贝，最后共享的 trait 是 `__text` 末尾的
`brk #0x1`。结合上下文（activation 服务要做网络请求、要读代理配置），
最可能是**它自己抛出的 ObjC 异常**（未识别 selector / KVC 键不存在），
而不是内核接口缺失。

下一步验证顺序（都不需要改内核）：
1. 用 fw-pack 换掉 `com.apple.mobileactivationd.plist`，让这个服务以
   `/usr/bin/true` 形式"启动即退出"，看 SpringBoard 是否继续往桌面走；
2. 给模拟的网络（`SWEET NET`）补一个可用的接口/DHCP，排除"没有网络导致
   activation 断言"；
3. 最后才是预置激活记录。

### 20:40 用固件包替换 mobileactivationd 的 plist：实验与两个结论

把 `mad_stub.plist`（`ProgramArguments = /usr/bin/true`，去掉 MachServices/LaunchEvents）
打进固件包，`files.txt` 指向
`/System/Library/LaunchDaemons/com.apple.mobileactivationd.plist`，原地重写 pinned 文件后
启动两次，结果：

- 安装本身成功：`PANDORA FILES: mad_stub.plist -> /System/Library/LaunchDaemons/... (221 bytes)`；
- **但 launchd 仍然启动了真正的 mobileactivationd**（17 次 exec / 68 次崩溃，和替换前完全一样）。

两个原因：

1. **时机太晚**：`pandora_files` 在根卷挂载后 2 s 才写文件（日志里是 2.69 s），而 launchd 在
   1 s 出头就把 `/System/Library/LaunchDaemons` 扫进缓存了；
2. **不持久**：下一次启动时同一行仍然是 `1 written`（`pf_same()` 判定内容不同），
   说明写入没有落进 HFS 日志/磁盘，重启即丢。

要真正替换系统 daemon，需要：(a) 把安装提前到 launchd 扫描之前，(b) 写完后
flush 文件与 HFS 日志。两者都是内核侧改动，属于下一轮的工作。

固件包已恢复成只有 keybag（`pack/iosfw.img` 原样写回 pinned 文件）。

### 21:15 0247（pack fsync + 提前安装）实测：没解决问题

- 内核侧改动本身编译通过、构建成功（run `40687474555`，macos-15，6 分钟就出包）；
- 真机启动：安装日志依旧在 `2.686 s`，`mobileactivationd` 依旧 **17 次 exec /
  68 次崩溃**，与替换前完全一致 —— 说明 launchd 仍然读到了旧 plist；
- 启动日志里只有挂载时的 `jnl: replay_journal ... done`（0.18–0.30 s），没有报错。

**结论**：`pf_write` 的写入既没在本次启动里被 launchd 看到，也没持久化（下次启动仍报
`1 written`）。要么 HFS 写入路径没有真正落到数据块/编目，要么 launchd 读的不是这个
文件。下一步应该先做一个最小判定实验（**不再改代码**）：同样的包连续启动两次，看第二次
是否变成 `0 written`：
- 变成 `0 written` → 写入持久了，问题在 launchd 的读取路径/缓存；
- 仍是 `1 written` → 写入根本没落盘，要修 `sweet_hfs` 的写入/日志提交。

### 今晚的最终状态（21:20）

- 内核启动链：**preboot → keybag → AMFI → SpringBoard/backboardd 全通**，
  497 次 exec、120 fps 帧缓冲、无 panic；
- 唯一用户态卡点：`mobileactivationd` 的 ObjC 断言（激活服务）；
- 所有改动已推送（最新 `ecb1ff11` 含 0247），文档即本文件。

### 21:15 判定实验结果：写入**没有落盘**

同一份包、同一内核连续启动两次，安装行都是 `1 written`（第二次没有变成
`... already the same`）→ `pf_write` 的写入没有持久化；`mobileactivationd` 两次都是
17 次 exec / 68 次崩溃，plist 覆盖完全无效。

已有的相关实现都在：`hfs_vfsops` 有 `.vfs_sync = hfs_sync`，`hfs_vnops` 有
`hfs_vnop_fsync`（vnode 表里也挂了），挂载时 `jnl: replay_journal` 正常。所以问题
不在"没实现"，更可能是：

1. `/System` 在这个镜像里不是普通目录（iOS 16 的 firmlink/卷布局），
   `vnode_open("/System/...")` 解析到的挂载点与 launchd 读的不是同一个；
2. 或者 SWEET HFS 的写入是"内存覆盖"语义，`vfs_sync`/`fsync` 没有把它推进 journal。

**下一步诊断（便宜且直接）**：在 `pandora_files` 里打印目标路径所在挂载点
（`vnode_mount(vp)` 的 `mnt_stat.f_mntonname` + `f_fstypename`），并在安装后立刻
从内核读回该文件前 16 字节；如果读回是新的、重启又变旧，就是持久化问题；
如果读回就是旧的，就是路径/挂载点问题。

### 22:45 本地构建链跑通了（不再依赖 CI 排队）

在 WSL 里照着 data-a-live 的做法把苹果链接器搬到 Linux：

1. `cctools-port` 的 configure 要求 `libdispatch`；Ubuntu 没有这个包，于是用 clang
   编译安装 `swift-corelibs-libdispatch`（`-DCMAKE_C_COMPILER=clang`，gcc 编不过它）；
2. `./configure --target=aarch64-apple-darwin --prefix=/opt/ld64 --with-libdispatch=/usr/local`
   + `make && make install` → `/opt/ld64/bin/aarch64-apple-darwin-ld`（ld64-956.6）；
3. 新脚本 `tools/relink64.py`：用 CI 的 `xnu-objects` 做底座、`--local 源文件=对象`
   替换掉本地重编的那几个，再用真 `ld64` 链接 + `strip`。

**验证**：本地链出来的内核 `__TEXT 0xfffffff007004000`、entry 正常、16.4 MB，
`fastboot boot` 后 `SWEET AMFI registered` → `MKB_INIT` → `exec SpringBoard`，
450 次 exec，与 CI 版行为一致。**一轮内核改动的验证从 30–60 分钟降到约 6 分钟。**

### 22:50 两个决定性结论（写文件 vs launchd 时序）

- 写入**确实生效**：`0248` 的校验行
  `verify /System/Library/LaunchDaemons/...: mount / type hfs n=16 read 62706c69 want 62706c69`
  —— 读回就是我们写的字节（`bpli` = 二进制 plist 头），时间 0.886 s；
- 但 **launchd 在 0.288 s 就已经 exec 了**（`load_init_program` → `exec launchd`），
  比我们任何 VFS 写入都早 → **"启动时替换 daemon plist"这条路先天赢不了**，
  与写得好不好无关；
- 顺带：`com.apple.purplebuddy.plist`（SetupDone=true）也装进去并校验通过，但日志里
  依然没有 Setup/Buddy 进程，SpringBoard 行为不变。

所以要让"替换系统文件"生效，只能走**持久化**（让文件在下次启动前就在盘上）——
这需要 HFS 日志提交真正落盘（目前每次启动仍报 `1 written`，说明没持久化）。

## 2026-10-29 凌晨 —— 卡点是窗口太短，不是卡死

### 实测：iOS 侧的启动要 ~14 分钟

同一个 `0249` 内核，只改 `pandora_reboot_after` 与 `pandora_fbdump`，三次启动的进度条
填充比例（`fbdump.py` 出的 surface PNG 逐像素测的，轨道 73..302，白色为已填充）：

| 那一帧的 uptime | 进度条 | 当时在干什么 |
|---|---|---|
| 59 s | 0% | 第一帧，logo + 空轨道 |
| 365 s | 49% | 什么都没有，只有 bluetoothd/fairplayd 每 10 s 重生 |
| 815 s | 83% | 同上 |
| **~828 s** | — | **一批服务突然启动**：`installd`、`appstored`、`assetsd`、`itunesstored`、`migrationpluginwrapper`、`coresymbolicationd`… ≈ 89 次 exec / 1 秒 |

也就是说，180 s 和 420 s 的自动重启都在"启动完成"之前把机器重置了。**之前的"卡在 logo"
是窗口太短造成的观测假象。** 之后一律用 `pandora_reboot_after=1500` 起步，帧转储放在
900 s 之后。

同一轮里 `homed`（898 s）和 `SiriTTSSynthesizerAU`（894 s）各崩了一次
（`sig 6` = SIGABRT，`Too many corpses being created`）；`com.apple.migrationpluginwrapper`
在一次启动里跑了三次（43 s、828 s、887 s），和上游"数据迁移每次开机重跑"的记载一致。

### 新工具

- `tools/run_boot.sh IMG NAME SECS`：一整轮无人值守 —— `adb reboot bootloader` →
  `fastboot boot` → 等自动重启回安卓 → `pinfile rawread` 拉 pinned 日志（前 184 字节是
  pinfile 自己打印的 extent 检查，按 `PANDORLG` magic 切掉）→ `pandora_log.py` 解码 →
  `fbdump.py` 出 surface/panel PNG。
- `tools/thumbs.py LOG OUTDIR`：把内核日志里的 ASCII 缩略图渲染成 PNG。
- `tools/restore_root.sh [IMG]`：把本地 16 GiB 根镜像写回 pinned 文件（先校验 extents
  与 ADT 记录一致）。

### 0250：屏幕缩略图时间线（无人值守的关键）

`bsd/dev/pandora_selftest.c` 里加了第二个线程：`pandora_thumbs_start` /
`pandora_thumbs_every` / `pandora_thumbs_until`，每 N 秒调用已有的 `sweet_fb_thumb()`
把 1125×2436 的屏幕采样成 60×130 的十六进制 ASCII（每个像素一个亮度 nibble）写进内核日志，
tag 是 uptime 秒数。这样一轮 25–40 分钟的启动，日志里就有整条画面时间线，
不用再赌 `pandora_fbdump` 恰好落在哪一秒。日志体积：每帧 ~130 行 × 60 字符 ≈ 8 KB，
60 s 一帧、25 分钟约 200 KB，4 MiB 环完全够。

### 新问题：HFS 在盘上的损坏会累积

日志里的 `hfs: BlockMarkFreeInternal() trying to free unallocated blocks` +
`hfs_mark_inconsistent: Runtime corruption detected on iOSRoot, fsck will be forced on next
mount`，按启动次序统计：

| 那一轮 | 内核 | `Runtime corruption` | `CRASH` |
|---|---|---|---|
| `ioslog-tweak2`（180 s） | 0249 | 0 | 0 |
| `ioslog-r420` | 0249 | 1 | 0 |
| `ioslog-r900` | 0249 | 5 | 196 |
| `ioslog-r1000` | 0249 | 327 | 412 |

`r1000` 那一轮已经起不来了：`containermanager` 从 12.7 s 起 `sig 5 code 0x600000001`
反复崩，**屏幕一次都没亮**（整个日志只有 3 行 `SWEET FB`，没有 `display on`）。
即 `/private/var` 的写入每开机一次就往盘上留一点不一致，几轮之后系统就起不来 ——
这和"写入不持久"是同一族问题（HFS 位图/日志提交路径），只是方向相反：改动有一部分
落到了盘上，但没走日志，留下不一致。

处理：**每次长跑前用 `tools/restore_root.sh` 把本地干净镜像写回**（16 GiB，push + rawwrite
约 10–15 分钟）。要根治得修 HFS 写入路径，或者让根卷以只读挂载跑（iOS 会抱怨写失败，
但可能仍能到锁屏）——留给后续验证。

### 下一步（无人值守的迭代计划）

1. 恢复干净镜像 → 用 `0250` 内核 + `pandora_reboot_after=1500` + 每 60 s 缩略图跑一轮，
   确认 828 s 之后屏幕到底变成什么（锁屏？还是继续 logo）；
2. 若到锁屏：用 `pandora_selftest` 注入上滑手势解锁（`st_swipe` 起点 562,2425 → 562,1100），
   再往桌面推；
3. 若不到：按缩略图时间线定位卡在哪个阶段，再决定改内核还是改镜像。

### 2026-10-29 01:20 恢复镜像时踩到的坑：`/data/local/tmp` 是 FBE 加密的

把 16 GiB 镜像 `adb push` 回 `/data/local/tmp/iosroot.img` 之后，用 `pinfile extents` 拿到
的新 extents 去读裸设备，第一个块的 1024 偏移处是**乱码**而不是 `HX`（HFSX 卷头），
但用 `dd if=/data/local/tmp/iosroot.img` 走 VFS 读同一个文件却是正常的 `HX`。

原因：`/data/local/tmp` 在文件级加密（FBE）的分区上。**通过 VFS 写进去的文件，裸块上是
密文**；而内核的 extent root 是直接从裸块读的。所以：

- `pinfile create` + 内核写日志的那条路（`rawwrite`）是对的 —— 裸块上是明文；
- 用 `adb push` / `dd` / `cp` 直接写 pinned 文件是**错的** —— 裸块上全是密文，内核挂载会失败。

正确的恢复流程（`tools/restore_root.sh` 已按这个改）：

1. `adb push 镜像 /data/local/tmp/iosroot-src.img`（VFS，密文没关系，只是运输）；
2. 若 pinned 文件丢了 pin（`adb push` 会换 inode，pin 会丢）：`pinfile create <目标> 16384`；
3. `pinfile rawwrite <目标> <userdata 设备> all --yes < /data/local/tmp/iosroot-src.img`
   —— 它把源文件**通过 VFS 解密读出**，再写到目标的裸块上（明文）；
4. 校验：新 extents 的第一个块 1024 处必须是 `HX`。

实测：16 GiB 的 `rawwrite` **1 分 50 秒**（写出 sha256 可回读校验），比原来"push 6 分钟
+ 回写"快得多。

另外 `tools/prepare_run.sh KERNEL OUTDIR WINDOW "额外启动参数"` 把
"读当前 extents → 生成 ADT（带 D22AP 的 /product）→ 建 boot 镜像 → 校验 cmdline"
合成一条命令；f2fs 会在文件被重写后换位置，所以每次跑之前都重建 ADT，不再复用旧镜像。

## 2026-10-29 02:00 镜像缺的东西找到了：ios-sweet 的 root tweaks

读上游 `dipa-studio/ios-sweet` 的 `tools/sweet-root-tweaks.py`（就是把他们的镜像从
"苹果 logo 永远不动"推进到桌面的那个脚本），对照我们的镜像逐条查，缺了这些：

| 项目 | 上游做法 | 我们的镜像 |
|---|---|---|
| `/private/var/containers` | 建 `Bundle`(33:33)、`Data/System`、`Shared/SystemGroup`、`Temp`（iOS 上在数据卷，不在 `mobile/` 下） | **整个目录都不存在** |
| `launchd.plist` | `_PanicOnCrash` → `_PanicOnCrasX`（崩溃的 daemon 不能把整机 panic）；删掉 `com.apple.CommCenter` 的两个 job | 7 个 `_PanicOnCrash` 原样、CommCenter 在（日志里 CommCenter 崩了 53 次） |
| 数据迁移 | `com.apple.migration` 写 `LastSystemVersion=20H392`，否则每次开机跑一小时 | 没有，日志里 migration 一次启动跑 3 次（43 s / 829 s / 887 s） |
| SpringBoard | `BKNoWatchdogs`、关掉 cloud configuration UI | 没有 |
| Setup | `purplebuddy` 的 `SetupDone` 等一整套 | 只有一个 `SetupDone` 的 plist |
| 音频 | `VirtualAudio.plugin` 移走（mediaserverd 崩）、MediaToolbox `StartRecorderServer=false` | 都还在 |

上游脚本对 CommCenter 的注释是关键线索：**"没有基带，它崩溃循环，而 Setup 会阻塞在它的
CoreTelephony XPC 上"** —— 这和我们的现象对得上：屏幕停在启动进度条、CommCenter 反复崩、
SpringBoard 不再有任何动作。

已按上游脚本逐条移植（`tools/root_tweaks.py`，输出 `out/tweaks/`，再用 guestfish 写进镜像）：

- `launchd.plist`：530 个 job（原 532），`_PanicOnCrasX` 7 个；
- `/private/var/containers/{Bundle 33:33, Data/System, Shared/SystemGroup, Temp}`；
- 5 个偏好 plist（mobile 501:501, 0600）；
- `VirtualAudio.plugin` → `HAL.disabled/`，MediaToolbox 两份 SubServerConfiguration `StartRecorderServer=false`。

没做的一条：`mobileactivationd` 的 data ark。上游是**在已有的系统容器里**写
`data_ark.plist`（`-ActivationState=Activated`），而我们的镜像里连
`containers/Data/System` 都是刚建的、没有 `com.apple.mobileactivationd` 容器，所以先跳过。

镜像写好后用 `tools/restore_root.sh` 把它 rawwrite 回手机（extents 不变，ADT 不用重建），
再跑一轮 1500 s 的启动。

## 2026-10-29 02:30 移植 root tweaks 之后：SpringBoard 真的起来了

同一套内核（`0250`）、同一份 1500 s 窗口，只把镜像换成打完 root tweaks 的版本：

| | run1（tweaks 之前） | run2（tweaks 之后） |
|---|---|---|
| SpringBoard 的 `|SpringBoard|` 日志 | **0 行** | **410 行**，其中 `SBCoverSheetPrimarySlidingViewController`（锁屏）在 835 s 被创建 |
| SpringBoard 创建 surface | 无 | `id 43 1125x2436`、`id 44 94x203`（835 s） |
| 屏幕 | 苹果 logo + 进度条一路爬 | 苹果 logo（**进度条消失**，说明启动进度走完了） |
| 提交到屏幕上 | 120 fps 连续 | **总共只有 7 次**（6 次在 53 s，第 7 次在 836 s） |

也就是说：**启动流程走完了、锁屏的控制器建出来了，但 SpringBoard 的内容没有被送进合成器**。
836 s 之后再没有 `SWEET FB: swap`，屏幕冻结在第 7 帧（logo）。

这一轮里唯一反复崩的东西是**壁纸**：

```
[854.296] exec AegirPoster
[854.296] CRASH AegirPoster[465] sig 6 code 0x0 ... pc 0x1e9ac3198   （同一 pc，88 次）
[854.383] SWEET SURF: CollectionsPoster create id 57 1271x1823 ...
[856.809] SWEET SURF: b3a8 1125x2436 plane 0 ... plane 1 ...        （10-bit 双平面 surface）
```

崩溃统计：`SiriTTSSynthesizerAU` 96、`MacinTalkUSP` 96、`KonaSynthesizer` 96（都是语音合成，
没有对应硬件）、`AegirPoster` 88、`homed` 40、`assetsd` 16。

下一步两个候选（都在 900 s 之后动手，不影响启动）：
1. 用内核的按键注入在 900 s 按一次电源键（`pandora_selftest=900`），看能不能把"画好了但没送上屏"
   的画面逼出来 —— 这一轮正在跑；
2. 若还是不动，就针对壁纸：`AegirPoster` 每次都在同一 pc 断言，且它要的是 10-bit 双平面
   surface，很可能是没有 Metal/GPU 导致；可以试着把 `PosterBoard`/海报扩展的 job 关掉，
   让锁屏退回纯色背景。

顺带：这一轮 `Runtime corruption` 是 **0 条**（run1 也是 0，run0 是 327）——
把 `/private/var/containers` 建出来之后，HFS 的 orphan 清理不再乱释放块了，卷的损坏问题自己消失了。

### 03:00 run3：注入电源键/滑动对屏幕没有任何影响

`pandora_selftest=900` 会依次注入电源键、上滑、音量键、控制中心、亮度拖动。这一轮全部执行了：

```
[900.185] PANDORA SELFTEST: display_off=0
[900.187] PANDORA SELFTEST: power press
[903.309] PANDORA SELFTEST: after power 1 display_off=0     ← 电源键没让屏幕熄灭
[906.434] PANDORA SELFTEST: swipe up 562,2425 -> 562,1100
[918.928] PANDORA SELFTEST: done
```

而屏幕缩略图在 132 s 到 1512 s 之间（包括 `start`/`power1`/`power2`/`swipeup`/`cc`/`bright`
六张自检缩略图）**逐字节完全相同**。整轮仍然只有 7 次 present（最后一次在 836.2 s）。
结论：836 s 之后 **SpringBoard 和 backboardd 都不再对输入或 UI 状态做出任何反应**。

### 03:30 run4：加了进程表自省（0251/0252）

`bsd/dev/pandora_selftest.c` 里加了 `pandora_ps=SECONDS` / `pandora_ps_every=SECONDS`，
每 N 秒打印一次 `proc_iterate(PROC_ALLPROCLIST)` 的结果。第一版只到进程级：

```
[1000.185] PS p 55 1 2 backboardd
[1000.186] PS p 25 1 2 SpringBoard
[1000.186] PS p 1 0 2 launchd
```

`p_stat=2` 是 SRUN，只能看出"可运行"，分不清是阻塞还是空转 —— 所以第二版（0252）改成遍历
`proc->p_uthlist` 里的每个 uthread，打印 `uu_arg[0..1]`（mach trap 的参数会存进这里）、
`syscall_code`、`uu_wmesg`、`uu_wchan`。编译坑：`struct uthread` 和
`TAILQ_ENTRY(uthread)` 需要 `#include <sys/user.h>`，否则是 incomplete type。

正在跑的 run5 在 300 / 650 / 1000 / 1350 s 各打一次全线程表，用来对比
"SpringBoard 起来之前/之后" 各自卡在哪个 mach 端口或内核等待上。

### 04:15 又一个"上一轮的实验污染了镜像"：mobileactivationd 一直是 `/usr/bin/true`

查 `run5` 的线程表时顺手翻了镜像里的 job 表，发现 **内嵌的
`/System/Library/xpc/launchd.plist` 里 `com.apple.mobileactivationd` 的
`ProgramArguments` 就是 `/usr/bin/true`，而且没有 `MachServices`** —— 这是更早那轮
"把 mad 换成 true 看画面变不变"的实验留下的，它被写进了镜像并一直留着。

也就是说：**从那一轮之后，这台机器上根本没有激活服务**，`com.apple.mobileactivationd`
和 `.lockdown` 两个 Mach 服务都不存在。上一轮得出的"卡点不在激活服务"的结论，
是在 180 秒的窗口下得到的 —— 而那时系统连 SpringBoard 都还没到，所以那个结论不成立。

已修（`tools/root_tweaks.py` 现在从 `ios-root.orig.img` 的原始 job 表出发）：

- 内嵌 job 表：`ProgramArguments = /usr/libexec/mobileactivationd`，
  `MachServices = {com.apple.mobileactivationd, com.apple.mobileactivationd.lockdown}`；
- `/System/Library/LaunchDaemons/com.apple.mobileactivationd.plist` 同样恢复；
- 其余 tweaks（`_PanicOnCrasX` 7 个、去掉两个 CommCenter job、530 个 job）保持一致。

ADT 里已经有 `certificate-security-mode` / `effective-security-mode-{ap,sep}`，
正是 `mkadt_pandora.py` 注释里说的、让 mobileactivationd 走 "Hactivation" 分支
（本地激活、不联系苹果服务器）的那组属性；之前只是因为服务根本没跑，这组属性没用上。

run6 就用这个镜像跑，看 SpringBoard 的锁屏会不会真的出现。

## 2026-10-29 夜间无人值守总结（00:16 → 05:30）

### 一句话

「卡在苹果 logo」是两个假象叠出来的：**窗口太短**（iOS 侧启动要 ~14 分钟）和**镜像根本不全**
（少了 ios-sweet 的整组 root tweaks）；补齐之后 **SpringBoard 真的会起来、锁屏控制器会被创建**，
现在卡在「SpringBoard 起了但画面不被合成」。

### 今晚确认的事实（按重要性）

1. **启动要 14 分钟，不是卡死**：进度条 59 s 0% → 365 s 49% → 815 s 83%；
   828 s 一批服务（installd / appstored / assetsd / migrationpluginwrapper / 海报扩展…）
   同时启动 —— 那才是"启动完成"。`pandora_reboot_after` 必须 ≥1500 s。
2. **镜像缺 ios-sweet 的 root tweaks**：`/private/var/containers` 整棵树、`launchd.plist` 的
   `_PanicOnCrasX` 重命名与 CommCenter 移除、`com.apple.migration` 的 `LastSystemVersion`、
   SpringBoard 的 `BKNoWatchdogs`、Setup 跳过、VirtualAudio 关掉。补齐后 **SpringBoard 从
   "0 行日志"变成 410 行，并在 835 s 创建 `SBCoverSheetPrimarySlidingViewController`（锁屏）**。
3. **补 containers 之后 HFS 的运行时损坏消失了**：`hfs_mark_inconsistent` 从 327 条 → 0 条。
4. **`/data/local/tmp` 是 FBE 加密的**：`adb push` 写的镜像在裸块上是密文，必须
   `pinfile rawwrite`（16 GiB 约 1 分 50 秒）。`pinfile create` 会把文件 pin 住，`adb push`
   覆盖同一路径会换 inode、丢 pin、换 extents。
5. **mobileactivationd 从 828 s 起就被我们自己的实验桩掉了**（内嵌 job 表里是 `/usr/bin/true`）。
   恢复真身之后它照旧在 13.5 s 崩（同一 pc，`brk #0x1` 断言，424 次），所以目前又桩回去了。
6. **帧缓冲只有 7 次 present**：6 次在 53.6 s（backboardd 自己的启动 UI），第 7 次在 836 s；
   之后 SpringBoard 的内容再也没被合成。注入电源键/上滑/音量键**完全没有反应**
   （`display_off` 始终 0，缩略图逐字节不变）。

### 现在手上的工具（都跑通了）

| 工具 | 用途 |
|---|---|
| `tools/run_boot.sh IMG NAME SECS` | 一轮无人值守：fastboot boot → 等自动回安卓 → 拉 pinned 日志 → 解码 → 帧转储 |
| `tools/prepare_run.sh KERNEL OUTDIR WINDOW "额外参数"` | 读当前 extents → 重建 ADT（带 D22AP /product）→ 建 boot 镜像 |
| `tools/restore_root.sh [IMG]` | push 到 scratch → `pinfile rawwrite` 写回 pinned 文件（extents 不变，ADT 不用重建） |
| `tools/root_tweaks.py out/tweaks` | 从**原始** job 表生成 tweaks：`_PanicOnCrasX`、去 CommCenter、containers、偏好、音频 |
| `tools/thumbs.py LOG OUTDIR` | 把日志里的 60×130 ASCII 屏幕缩略图渲染成 PNG |
| 内核 `0250` | `pandora_thumbs_start/_every`：每 N 秒一张屏幕缩略图进日志 |
| 内核 `0251/0252` | `pandora_ps=SECONDS` / `_every`：全进程/全线程表（pid/ppid/stat/uu_arg/wmesg） |

### 当前状态（run7 正在跑）

- 镜像：`pudding-hw/rootfs/ios-root.img`（tweaks 打满、mad 桩回去）；
- 内核：`relink/kernel-0252`（0250 缩略图 + 0251 线程表）；
- 本轮：`pandora_reboot_after=2400`，缩略图每 120 s，线程表在 1000/1900 s。

### 明早可以接着做的（按性价比）

1. **看 run7 的结果**：如果 1500 s 之后锁屏终于出现 → 就是"还是太慢"；若仍是静态 logo →
   走下面 2。
2. **SpringBoard 卡在合成**：最可能是 backboardd 在合成 SpringBoard 的 10-bit surface
   （`fmt 0x77333072` = `'w30r'`）时卡住。两个方向：
   - 让系统选 8-bit（改 iPhone X 的广色域声明 / AppleCLCD 的显示属性）；
   - 或者在内核的 present() 里打印/转码 10-bit 图层，先确认是不是格式问题。
3. **homed 反复崩**（40–600 次，`sig 6`）：SpringBoard 的首屏布局依赖它；如果能修 homed
   的断言，锁屏/桌面可能一起解决。
4. **激活**：mad 的断言在 `copyReverseProxyDictionary`（网络代理字典），可以试
   给镜像补一份 `SystemConfiguration/preferences.plist`（ios-sweet v15 的做法）。

### 05:25 run7（40 分钟窗口）：不是慢，是真停住了

`pandora_reboot_after=2400`、缩略图每 120 s、线程表在 1000/1900 s。结果：

```
presents: 16 次，最后一次在 836.7 s          ← 40 分钟里再没有第 17 帧
screen timeline: 132s .. 2400s 全部 same hash（bright=71）
SpringBoard: 1000 s 13 个线程，1900 s 12 个（少了一个，说明还有活着的线程退出了）
|SpringBoard| 日志：836 s 之后 0 行
```

836.2–836.7 s 之间是 **一串 10 帧的动画**（启动画面淡出），之后 backboardd 再没有提交过任何帧。
所以不是"还没画完"，而是 **SpringBoard 在把第一帧交给合成器之前就停住了**；backboardd 那边
没有新内容可合成，屏幕就一直停在淡出后的那一帧（logo）。

### 下一步最值得做的instrumentation：`pandora_cat`

现在的盲点是"SpringBoard 到底卡在哪个调用"。iOS 自己其实会记录：run7 里 1100 s 起了
`spindump`（系统级 stack sampler），如果它把报告写进了 `/private/var/db/spindump/` 或
`/var/log/`，我们只要能在**运行中**把文件读出来，就能拿到 SpringBoard 的用户态调用栈。

内核有完整的 VFS，加一个 boot-arg 的"定时把某个文件的内容打进内核日志"（`pandora_cat=路径:秒数`）
是很小的改动，却能让以后所有"进程不动了"的问题都有栈可看。这比继续猜 10-bit surface /
海报 / 激活都更值。

## 2026-10-29 05:40 **找到卡点：SpringBoard 在死循环重试 `com.apple.commcenter.xpc`**

### 怎么找到的：把跑完的镜像拉回来读 launchd 的日志

iOS 的 launchd 会把每个 job 的生命周期写进
`/private/var/log/com.apple.xpc.launchd/launchd.log`，而且**这个文件是持久化的**（HFS 写入这次
真的落盘了）。于是：

```
pinfile rawread /data/local/tmp/iosroot-pin.img <userdata dev> > run.img   # 16 GiB，13 分钟
# 去掉 pinfile 自己的 190 字节前言，guestfish 只读挂载，把 launchd.log 拷出来
```

拿到 **4 MB** 的 `launchd.log`，里面有每一次 spawn / exit / lookup。

### 日志说了什么

```
16:00:24  (user/501/com.apple.SpringBoard [25]) service spawned with pid 25
...
16:14:01  failed lookup: name = com.apple.commcenter.xpc, requestor = SpringBoard[25], error = 3: No such process
16:14:02  failed lookup: ... 同上
...       （每秒一次，一直到 16:39:53 最后一条，共 1538 次）
```

统计（整份日志）：

| 次数 | 服务名 | 请求者 |
|---|---|---|
| 4327 | `com.apple.commcenter.coretelephony.xpc` | vmd[405] |
| **1538** | **`com.apple.commcenter.xpc`** | **SpringBoard[25]** |
| 84 | `com.apple.mobileactivationd` | lsd[98] |
| 16 | `com.apple.wifi.manager` | SpringBoard[25] |

也就是说：**SpringBoard 起来之后卡在一个每秒重试的 XPC 查找上**，而那个服务正是我们按
ios-sweet 的 tweak 删掉的 `com.apple.CommCenter`（上游删它是因为"没有基带时它会崩、Setup 会
阻塞在它的 CoreTelephony XPC 上"——但我们的流程跳过了 Setup，反而轮到 SpringBoard 卡住）。

顺带确认：SpringBoard 其实 **24 秒就起来了**（`service spawned with pid 25`），
`|SpringBoard|` 日志到 835 秒才出现是因为它一直在等启动进度。

### 处理

`tools/root_tweaks.py` 加了 `PD_KEEP_COMMCENTER=1`：保留两个 `com.apple.CommCenter` job
（MachServices 才会注册），其余 tweaks 不变。run8 用它跑，看 SpringBoard 是否终于把第一帧交给
合成器。

## 2026-10-29 06:15 **过了锁屏这道墙：屏幕上是 Setup 的 "hello"**

run8 = run7 的镜像 + **把两个 `com.apple.CommCenter` job 加回去**（`PD_KEEP_COMMCENTER=1`）。

结果：

```
display: on 53.7s, off 1017.7s            ← 系统自己把屏幕睡掉了（说明电源管理在工作）
presents: 16（last 846.9s）
screen timeline: 132..852 = logo（不变）
                 972 = 变了！bright 71 → 5
                 1092 之后 = 全黑（屏幕已睡）
```

972 秒那一帧的缩略图和 998 秒的完整帧转储（`out/run8-surface.png`）显示的是
**iOS Setup 的 hello 界面**：右上角状态栏（电池）、底部 Home 指示条、右下角按钮，
中间是 "hello" 的笔迹动画。也就是说：

- SpringBoard 真的在渲染；
- 系统已经走完了启动 → 锁屏这一层，现在停在**首次开机设置（Setup.app）**；
- 之前"SpringBoard 起了但画面不动"就是被 `com.apple.commcenter.xpc` 的每秒重试卡住的。

顺带把固件包换回 keybag-only（`pack/iosfw.img`），不再每次开机把
`mobileactivationd` 的 plist 覆盖成 `/usr/bin/true`。

### run9（正在跑）：把真 mobileactivationd 也放回去

Setup 停在 hello 很可能是因为**设备没被"激活"**。之前 mad 一跑就崩（`copyReverseProxyDictionary`
里 `brk #0x1`），但那次崩溃时 CommCenter 是被删掉的；现在 CommCenter 的 MachServices 注册上了，
mad 的代理/网络路径可能就能过。run9 = run8 + 真 mad（`PD_KEEP_MAD=1`）。

如果 run9 的 Setup 直接跳过、进到锁屏，那"从 logo 到锁屏"这条主线就通了。

### 06:45 run9：真 mobileactivationd 放回去反而把系统拖死了

run9 = run8 + 真 mad（`PD_KEEP_MAD=1`，固件包已换成 keybag-only 不再覆盖 plist）。
结果：mad 从 13.4 s 起持续崩（`sig 5`，同一 pc），**屏幕只 present 了 6 帧（54 s 就停了）**，
Setup 都没出来。

原因很直接：mad 这次是**注册了 MachServices 的**，客户端（lsd、SpringBoard）会连上它、它又崩，
比"服务不存在"更容易把别人拖住。

所以回到 run8 的配置：**CommCenter 保留、mad 继续桩掉**。这已经是今晚最好的状态
（Setup 的 hello 界面能正常渲染）。当前 `ios-root.img` 和手机上的 pinned 镜像都是这个状态。

### 明早的下一步（按顺序）

1. **弄清 SetupDone 为什么没生效**：拉 run8 那轮的镜像（`pinfile rawread` → guestfish），看
   `/private/var/mobile/Library/Preferences/com.apple.purplebuddy.plist` 在数据迁移之后还是不是
   我们写的 `SetupDone=1`。如果被迁移重置了，就要么在迁移之后再写（内核 pack 的时机要往后挪），
   要么改由 launchd 的 job 来写。
2. **跳过 Setup 的替代路径**：用 `pandora_selftest` 注入上滑/点击走完 Setup 的前几屏
   （现在 UI 和输入链路都通了，值得试）；Setup 里没有网络可以选"稍后设置"。
3. **激活**：mad 的断言在 `copyReverseProxyDictionary`，可以给镜像补
   `/private/var/preferences/SystemConfiguration/preferences.plist`（ios-sweet v14/v15 就是这么干的），
   看看代理字典能不能不再是 NULL。

## 2026-10-29 07:45 **上游找到了：ShueiTsuki/data-a-live（同一台机器，领先很多）**

[github.com/ShueiTsuki/data-a-live](https://github.com/ShueiTsuki/data-a-live) 就是这台
小米 17 Pro（SM8850）的同一个项目，补丁到 `0293`，README 里写着：

- 锁屏、主屏、自带应用**能进能开**，触摸/电源/音量/亮度可用；
- 界面由 Adreno 840 的 GPU 合成（自己的 GPU 驱动 + Turnip + NativeMetal）；
- 电量/温度读真实传感器；ADSP 音频能起、功放卡住；
- 他们**在 2026-10-22 就第一次把锁屏显示出来了**（build #24）。

我们本地那条线停在 `0240`，之后 `0241–0251` 是我们自己加的（preboot/AMFI/pack/日志/缩略图/
进程表），和他们的 `0241+`（电量计、USB、温度、音频）是并行的两套编号。

### 最关键的一条：14 分钟是"第一次开机"的 LaunchServices 数据库重建

他们 `PLAN.md` 里早就写了：

> 苹果标志停留：…符号化后 SpringBoard 主线程 **CCSModuleRepository → LSApplicationRecord 等
> LaunchServices 数据库锁**，t1 在 `__LAUNCH_SERVICES_IS_RESEEDING_ITS_DATABASE_AND_MAY_BLOCK__`
> 同步等 lsd。即**第一次开机 lsd 重建应用数据库，约 25 分钟以上**（存储驱动慢）。

我们在真机上验证了：

| 这一轮 | 镜像状态 | 界面出现的时刻 | 最后一帧 |
|---|---|---|---|
| run10 | 刚恢复的干净镜像（第一次开机） | ~840 s | 856.8 s |
| run11 | 同一镜像，**不恢复**直接再开 | **~75 s** | 75.5 s |
| run12 | 再开第三次 | **~70 s** | 70.6 s |

**所以迭代速度可以提高一个数量级**：只要不每次恢复镜像，一轮从 25 分钟降到 4–6 分钟。
代价是镜像会累积运行期状态，需要在需要干净基线时才恢复。

他们也给了已知可用的启动参数（我们还没全用上）：
`ignition_level=1 launchd_unsecure_cache=1 wdt=-1 wdt_test=no_user_checkin sweetfb_hz=30
sweetfb_fill=1 sweetnoexec=bluetoothd,fairplayd.H2`，以及 `tools/iosroot_diff.py`
（把手机上的镜像和干净基线按 HFS 目录比对，列出运行期改过哪些文件）值得移植。

### run11/run12 的新现象：界面出来后很快黑屏并自动息屏

两轮都是 `display on` ~48 s、最后 present 70–75 s、屏幕从 132 s 起全黑、`display off` 105/196 s。
界面确实起来了（启动从 14 分钟降到 1 分钟），但**我们没有在它亮着的时候截到图**。
下一轮把窗口压到 140 s、缩略图每 10 s 一张、帧转储放在 120 s，专门抓这个瞬间。

### 09:00 现在的系统状态：能交互，但卡在 Setup 的 Wi-Fi 一步

用「不恢复镜像 + 短窗口」把一轮压到 **3–5 分钟**之后，可以直接把系统当成一台要人点的 iPhone 来操作。
新加的内核 `0255` 手势注入（`pandora_gesture="T:1:x,y;T:2:x0,y0,x1,y1;..."`，1=点击、2=滑动，
坐标是呈现出来的 1125×2436）已经能一路点下去：

| 轮次 | 注入 | 屏幕变成 |
|---|---|---|
| run13 | 无 | Setup 的 hello（"哈囉 / 向上滑动来打开"） |
| run14 | 上滑 | **Software Update Complete / Continue**（白底蓝按钮，系统真的在响应触摸注入） |
| run15 | 上滑 + 点 Continue | **Choose a Wi-Fi Network**（只有一个 "Connect to Mac or PC"） |
| run16 | `sweetnoexec=Setup` | **卡在苹果 logo**，屏 4 帧就不动了 —— 说明 SpringBoard 在等 Setup，不能简单屏蔽 |
| run17 | 上滑 + Continue + 点 "Connect to Mac or PC" | 还是 Wi-Fi 那一屏（那个按钮点不动，USB 那条路要真 USB 驱动） |

结论：**Setup 必须走完**，而它现在只有"Wi-Fi"和"连接 Mac/PC"两条路，我们两个都没有：
内核的网络栈只有 lo0/utun，没有 Wi-Fi 驱动，也没有 USB 数据功能。

### 找不到的另一个东西：`/private/var/preferences/SystemConfiguration/preferences.plist`

整个目录不存在（只有 `Logging/`）。真机上这个文件由 configd 首次开机生成，里面是网络服务
（接口、IP、代理）。两件事都指向它：

- `mobileactivationd` 一启动就崩在 `copyReverseProxyDictionary`（读代理设置的函数）——
  没有 SystemConfiguration 存储时它拿到的可能是 NULL；
- Setup 的网络/激活判断也读同一套东西。

run18 = 手工补一份最小 `preferences.plist`（一个 "USB Ethernet" 服务、192.168.7.2）+ **把真
mobileactivationd 放回去**（`PD_KEEP_MAD=1`），看 mad 会不会因此不崩、Setup 会不会跳过。

### 10:00 Setup 的 Wi-Fi 有隐藏出口：Continue without Wi-Fi

关键一步是把 `Connect to Mac or PC` 的坐标搞对（我之前按截图估错了 250 px）。按真实按钮矩形
（y 370–430 / 812）换算到呈现坐标是 **(561, 1200)**，点下去弹出了：

> **Continue without Wi-Fi?**  You need a network connection to set up iCloud and other services.
> ［Continue］［Use Wi-Fi］

也就是说 Setup **可以不走网络继续**，"Continue" 在 (378, 1383)。这条路上不需要 Wi-Fi
驱动、不需要 USB 数据、也不需要激活服务器。

另外确认了两个坑：

- `sweetnoexec=Setup` 会让 SpringBoard **永远停在苹果 logo**（它在等 Setup 启动），不能这么屏蔽；
- `sweetnoexec=mobileactivationd` 也不等价于"没有这个服务"：进程被挡住但 launchd 仍然注册着
  Mach 服务，客户端会连上去等，整机反而卡死。要"没有激活服务"，只能让 job 表里那条 **没有
  MachServices**（`/usr/bin/true` 桩）。

现在内核里的手势脚本（`0255`/`0256`）能完整走 Setup：上滑 → Continue → Connect to Mac or PC →
Continue without Wi-Fi。正在按这个顺序跑。

### 10:30 Setup 已经能一路点下去了

顺序（全部用内核手势注入，坐标是 1125×2436）：

```
90 s  上滑                     hello -> Software Update Complete
130 s 点 (561,2100)            Continue -> Choose a Wi-Fi Network
165 s 点 (561,1200)            Connect to Mac or PC -> 弹出 Continue without Wi-Fi?
210 s 点 (378,1383)            Continue -> 进入下一步（白底、左上角 Back）
之后每 25 s 点一次 (561,2100)   逐屏推进
```

踩过的坑：

- **坐标必须按像素量**：截图里 812 高的图，y 要乘 2436/812。我第一次把 y 估大了 250 px，
  结果点空了，白等了四轮。
- **帧转储（fbdump）只在有 present 的时候触发**，Setup 的静态界面几乎不 present，所以
  "按时间 dump" 抓不到想要的屏；`pandora_fbdump=1`（每次 present 都 dump）能抓到过渡帧，
  但最后一张经常停在动画中间。要精确截图得把 dump 改成由内核定时线程触发 —— 需要重编
  `SweetFramebuffer.cpp`，本地 C++ 编译链还有个 `AppleARMBacklight` 的老问题，暂时没做。
- `pandora_gesture`（0257）和触摸驱动的 `pandora_touch` 是**两个不同的启动参数**，
  最早我混用了，导致注入的同时把触摸驱动也打开了。

现在正在跑"点完 Wi-Fi 之后每 25 秒点一次底部按钮"的盲走（run29），目标是走出 Setup 进锁屏/主屏。

### 11:30 现在的真实卡点：Setup 的最后一步要网络或 USB

点掉 "Continue without Wi-Fi" 之后，Setup 进到一个**白底页面**：标题两行 + 一个空框 +
一个"手机插线"的图标，左上角有 Back。对 y=1200…2200、x=562 逐点试探点击**全都没有反应**，
Back 能退回到 Wi-Fi 屏。也就是说这是 **"Connect to Mac or PC" 的等待页面**：

- 走 Wi-Fi → 我们没有 Wi-Fi 驱动（内核网络栈只有 lo0/utun）；
- 走 USB → 我们没有 USB 数据功能（只有充电）；
- 走"继续" → 那个页面本身就在等线插上，没有可点的"跳过"。

所以 **Setup 卡在最后一步是缺硬件能力，不是缺一个设置**。要过去只有三条路：

1. **让设备"已激活"**，SpringBoard 就会跳过 Setup 直接进锁屏。激活要么让
   `mobileactivationd` 不崩（它现在在 `copyReverseProxyDictionary` 里断言，
   补 SystemConfiguration 无效），要么按 ios-sweet 的做法预置 activation data ark
   （需要先造出 `containers/Data/System/<mad>` 容器）；
2. **给 iOS 一个"已联网"的接口**：内核里造一个 en0（假的 IONetworkController），
   配上手工 IP，让 Setup 认为网络可用 —— 上游 ios-sweet 就是靠 USB 网卡做到的；
3. **打掉 Setup 的判断**：给 SpringBoard 注入一个 dylib（ios-fuxi 的 libfuxi-sb 是同一思路），
   把 `BYSetupAssistantNeedsToRun` 固定成 NO。

另外这一晚也验证了工具链：

- `pandora_gesture`（0255/0256）能完整走 Setup 前几屏；
- `pandora_cat`（0253）能读运行中的文件（用它确认了 `SetupDone=true` 确实在文件里）；
- `pandora_kill`（0257）能在指定时刻杀掉某个进程（还没用上）；
- 定时帧转储（0260 的 `pandora_fbdump_at`）本地 C++ 编译链还有 `AppleARMBacklight`
  的老问题，暂时只能靠 present 触发的 dump；
- `pandora_thumbs`（0250）每 10–20 秒一张缩略图，是现在最可靠的"看屏幕"手段。

### 12:30 交接状态

- 手机在安卓里，pinned 文件健康；镜像 = tweaks 打满、mad 桩、SystemConfiguration 已补；
- 内核 `relink/kernel-0260`（thumbs + ps + cat + kill + gesture + 定时 dump 的失败版）；
- 一轮迭代现在 **3–6 分钟**（不恢复镜像），需要干净基线时才 `restore_root.sh`（约 5 分钟 + 首次开机 14 分钟）；
- 所有结论在上面 + `git log`（仓库 `yechenan/pudding-ios`，最新 `5fac5a0`）。

### 12:00 最后一次尝试：手工预置 activation data ark —— 没成功

从热镜像里发现系统已经自己建了 12 个系统容器（`com.apple.springboard`、`lsd`、`backboardd`、
`fairplayd.H2`…），metadata plist 结构很简单。于是照着建了一个
`com.apple.mobileactivationd` 容器 + `Library/internal/data_ark.plist`（`-ActivationState=Activated`
等 6 个键），并把 job 表换回真 mad，写回手机跑了一轮（run36）：

- mad 仍然在 12.8 s 崩（37 次，同一断言），**data ark 没能改变它的启动路径**；
- 这轮镜像还因为改了 HFS 卷属性 + 脏卷写回，`hfs_mark_inconsistent` 飙到 4247 条，UI 没起来。

已经把手机上的镜像恢复成干净的 tweaked 版本（`tools/restore_root.sh`，HFSX 校验通过）。

结论：**激活这条线要动的是 mad 的崩溃本身，不是它的数据**。下一步应该在用户态层面查
`copyReverseProxyDictionary` 的断言（比如用 `pandora_cat` 读它崩溃前的日志、或按 myron 的
AEGIRPOSTER 思路做一个注入 dylib 的钩子），而不是继续喂数据。
