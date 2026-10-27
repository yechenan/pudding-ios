# pudding-ios

在 **小米 17（pudding，骁龙 8 Elite Gen 5 / SM8850）** 上运行 iPhone X 的 **iOS 16.7.16**：
自编 xnu-8796 内核（4 KiB 页）、`fastboot boot` 临时启动、iOS 根文件系统放在安卓 userdata
的一个固定文件里，不刷写任何分区。

本仓库**只包含这个机型专属的增量**：补丁、脚本、实测数据与文档。
上游代码不在此复制，构建时按键值（commit）从下列项目拉取：

| 上游 | 用途 | 许可 |
|---|---|---|
| [ShueiTsuki/data-a-live](https://github.com/ShueiTsuki/data-a-live) | 小米 17 Pro（pandora，同 SM8850）的移植：内核补丁、驱动、工具 | APSL-2.0 / MIT |
| [dipa-studio/ios-sweet](https://github.com/dipa-studio/ios-sweet) | XNU-on-Qualcomm 的源头：shim、mkadt、payload 工具 | 见其仓库 |
| [UniXNU/UniXNU](https://github.com/UniXNU/UniXNU) | 4 KiB 页支持、NativeAdreno、NativeMetal | BSD-2-Clause-Patent |
| [blacktop/darwin-xnu-build](https://github.com/blacktop/darwin-xnu-build) | macOS 上的 xnu 构建脚本 | 见其仓库 |
| Apple 开源的 [xnu](https://github.com/apple-oss-distributions/xnu) | 内核本体 | APSL-2.0 |

## 目录

| 路径 | 内容 |
|---|---|
| `xnu/patches/` | 本机型新增/修改的内核补丁（数字接在上游之后） |
| `scripts/macos-rootfs.sh` | 在 macOS 上把 IPSW 的三个 DMG 装成 16 GiB HFSX 根镜像 |
| `scripts/fetch-upstream.sh` | 取上游补丁与工具到 `upstream/`（构建与本地实验用） |
| `tools/read_klog.py` | 从手机的固定日志文件读回内核日志（免拍照） |
| `docs/` | 实测记录：设备树对照、启动参数、UFS 验证、iOS 镜像链路 |
| `.github/workflows/` | 内核构建（xnu）、根镜像构建（rootfs）、签名取证（sigcheck） |

## 设备基线（实测）

| 项 | 值 |
|---|---|
| 型号 / 代号 | 25113PN0EC / **pudding** |
| SoC / 平台 | SM8850 / canoe |
| 屏幕 | 1220×2656，`splash_region` = `0xFC800000` / `0x2B00000`，**视频模式**面板 |
| 页大小 | 4096（`TGran16 = 0`，必须 4 KiB 页内核） |
| 关键外设 | 触摸 `synaptics_tcm@0`（SPI）、电量计 `bq27z561@55`、功放 `cs35l43@40/@42` |
| 与 pandora 的差异 | 面板是视频模式（pandora 命令模式）、无副屏、三处总线实例不同 |

详见 `docs/PUDDING_DT.md` 与 `docs/PUDDING_BOOT.md`。

## 构建

内核只能在 macOS 上编（Apple clang / ld64 / Xcode 的 iig）。CI 用 GitHub Actions：

1. `xnu` 工作流：拉上游 `data-a-live` 的补丁 → 叠加本仓库 `xnu/patches/` → 跑
   `blacktop/darwin-xnu-build` → 产出 `kernel.development.pandora`；
2. `rootfs` 工作流：下载 iPhone X 16.7.16 IPSW → `hdiutil` 挂载三个 DMG →
   建 16 GiB 区分大小写带日志的 HFSX → 压缩分卷上传。

> Apple 的系统文件（IPSW、SDK、dyld 缓存）与手机固件**永不进入本仓库**，
> 由使用者从自己的设备与苹果服务器获取。

## 许可

本仓库自己的代码与文档为 MIT；对 xnu 的补丁按上游要求为 **APSL-2.0**。
第三方组件与上游代码保留各自许可，见 `NOTICE`。

## 状态

见 `docs/PUDDING_STATUS.md`：内核已跑到 launchd，当前卡在 exec 签名校验。
