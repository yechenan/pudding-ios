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
（最近三次 xnu 运行都是这样挂的）。

