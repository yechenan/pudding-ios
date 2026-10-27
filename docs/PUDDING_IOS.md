# iOS 16.7.16 系统镜像：从 IPSW 到手机（2026-10-27）

## 1. 为什么在 macOS runner 上做

iOS 16 的 `087-86698-044.dmg` 不是普通 DMG，而是**分块 LZFSE 容器**
（块头 `bvxn`/`bvx2`、块尾 `bvx$`）。本机试过四条路都不行：

| 工具 | 结果 |
|---|---|
| apfs-fuse / libfsapfs | 不认这个容器 |
| dmg2img | 无 UDIF 尾块 |
| blacktop `ipsw`（win/linux） | 只把 DMG 原样拷出，挂载仍交给 apfs-fuse |
| 自写块解码器 | 解到 86 MB 后失步（伪 `bvx$`） |

macOS 的 `hdiutil` 原生支持，所以在 GitHub Actions 的 macOS runner 上做：
`.github/workflows/rootfs.yml` + `scripts/macos-rootfs.sh`。

## 2. CI 里踩的坑（都已修）

1. `newfs_hfs` 不接受文件路径，要先 `hdiutil attach -nomount` 拿到 `/dev/diskN`；
2. macOS 自带 rsync **2.6.9**，没有 `--info=progress2`；
3. 脚本曾以 CRLF 进仓库 → `set: pipefail: invalid option name`（`*.sh` 必须 LF）；
4. cryptex 不在 `/System/Cryptexes`（那是软链接），真实路径是
   **`/private/preboot/Cryptexes/{OS,App}`**（ios-fuxi 的布局）；
5. macOS 没有 `sha256sum`，要用 `shasum -a 256`。

## 3. 产物

16 GiB HFSX（区分大小写 + 日志）：

```
HX   block size 4096   total blocks 4194304
sha256 44a4278c15658a65859b21df2be1b424b01a743d36bb0f908f26d89d0256c607
```

## 4. 写进手机（免清数据）

```
pinfile create /data/local/tmp/iosroot.img 16384     → pinned, 2040 extents
adb push ios-root.img /data/local/tmp/iosroot.src    → 16 GiB, 188 s, 87 MB/s
pinfile rawwrite … all --yes < /data/local/tmp/iosroot.src
                                                    → wrote 4194304 blocks
                                                    → sha256 与镜像一致
```

写完后 `rm /data/local/tmp/iosroot.src`。

## 5. 启动参数

```
debug=0xc serial=3 cpus=8 bootcpu=7 keepsyms=1 -v \
rd=ufsroot0 ufsrw=1 rootrw=1 pandora_touch=0 pandora_keys=0 \
pandora_reboot_after=150
```

ADT 里带 root extents（2040 段 / 4194304 块）和 log extents（8 MiB 日志文件）。

## 6. 第一次启动的情况（2026-10-27 14:31）

`fastboot boot` 接受镜像并跳转（`Booting OKAY`），但 **150 秒后没有自动回到安卓**：
手机既不在 adb 也不在 fastboot 里，说明内核在"自动重启"线程起作用之前就停住了
（`debug=0xc` 下 panic 会等待调试器）。

待用户回来断电重启后，从 `/data/local/tmp/ioslog.img` 读日志确认停在哪一步。
下一版已备好：`loader-ios3`（`debug=0x0`，panic 不等待，配合 `pandora_reboot_after=120`
可无人值守自动回安卓）。
