# pudding 上的 UFS 只读验证（2026-10-27）

目标：证明 iOS 可以住在安卓 userdata 里（不清数据、不改分区表）。

## 1. 分区表（`pandora_ufs_probe=2`）

```
PANDORA UFS: 34 partitions on LUN 0
PANDORA UFS: GPT read done (0), nothing written.
```

`userdata`（#34）：起始块 `0x35f200`，长度 `0x77c1ff6` 个 4 KiB 块 = **244,321 MiB**，
与安卓侧 `/proc/partitions` 导出的 `device/pudding-partitions.txt` 一致。

## 2. 钉住文件（免清数据方案）

```
pinfile create /data/local/tmp/iotest.img 64
→ pinned, 67108864 bytes, 11 extents
```

安卓侧验证（绕过文件系统写、按文件系统读）：

```
pinfile rawwrite … 1 block        → through the filesystem: 1 of 16384 blocks are not zero (blocks 0..0)
pinfile rawtest  … all --yes      → wrote 16384 blocks; read back: 16384 carry the pattern, 0 do not
```

## 3. 内核读同一个文件（`pandora_ufs_probe=4` + ADT `--root-extents`）

```
FUXI UFS: root file in userdata: 11 extents, 16384 blocks
PANDORA UFS: driver init (userdata extent file): 0, 11 extents, 16384 blocks
PANDORA UFS: block 0 says: PUDDING RAWTEST v1 from-host-2026-10-27
```

第 3 行就是结论：**内核绕过安卓的文件系统与加密层，按物理块读到了那个文件**。

图案校验（写入全部 16384 块后）：

```
PANDORA UFS: extent test done (0), WRITABLE.
```

## 4. 安全边界

- 只读阶段只发 TEST UNIT READY / ACTIVATE / 读命令；
- `ufsrw=1` 时写入被 `fx_write_allowed` 限制在**钉住文件自己的块**内；
- 日志文件（patch 0129）走同一套白名单。
