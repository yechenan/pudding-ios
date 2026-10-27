# 小米 17（pudding）设备事实：从真机采到的数据

采集时间：2026-10-27 10:16（Asia/Shanghai）
采集方式：adb（platform-tools 37.0.1）+ KernelSU root（`u:r:ksu:s0`）
原始文件：`pudding.fdt`（1.3 MiB，magic `d00dfeed`）、`iomem.txt`、`partitions.txt`、`by-name.txt`

---

## 1. 设备身份

| 项 | 值 |
|---|---|
| 型号 | 25113PN0EC（Xiaomi 17 国行） |
| 代号 | **pudding**（`ro.product.device` / `ro.boot.hardware.sku`） |
| SoC | **SM8850**，平台代号 **canoe / canoep** |
| DT model | `Qualcomm Technologies, Inc. Pudding based on SM8850` |
| DT compatible | `qcom,canoe-mtp, qcom,canoe, qcom,canoep-mtp, qcom,canoep, qcom,mtp` |
| Android | 17（`ro.build.version.release`），`swinfo.fingerprint=pudding:16/OS4.0.5.0.XPCCN:user` |
| 引导状态 | `flash.locked=0`、`verifiedbootstate=orange`、`vbmeta.device_state=unlocked` ✅ 已解锁 |
| Root | KernelSU（`/system/bin/su`，`su -c id` → uid=0） |
| 页大小 | `ro.boot.hardware.cpu.pagesize=4096` ✅ 4K 页 |
| 屏幕 | `wm size` → **1220×2656**，density 520 |
| userdata | `sda34` = **244321 MiB**（≈256 GB 机型），`dm-62` 映射其上 |

## 2. CPU

- 8 核：`cpu@0…500`（6 个，capacity **1792**）+ `cpu@10000`、`cpu@10100`（2 个超大核，capacity **1894**）
  —— 与 pandora 的 0x700 / 0x766 **完全一致**。
- `/proc/cpuinfo` Features：`paca pacg`（**指针签名有**）、`bti`、`sve/sve2`、`sme`、`lrcpc3`、`i8mm`、`bf16`
  —— 与 pandora 同款，ARMv9 级别。
- **有 PAC 意味着 arm64e 用户态可直接执行**（见计划书 §4/§7）。

## 3. 与 pandora（小米 17 Pro）逐项对照

| 项目 | pudding | pandora | 结论 |
|---|---|---|---|
| SoC / 平台 | SM8850 / canoe | SM8850 / canoe | **同** |
| `splash_region` | `0xFC800000`, `0x2B00000` | `0xFC800000`, `0x2B00000` | **同** |
| 屏幕分辨率 | 1220×2656 | 1220×2656 | **同** |
| 面板 | `qcom,mdss_dsi_p3_42_02_0a_mp_dsc_vhm`，**视频模式**（drm modes: `1220x2656x120vid` / `x90vid`），DSC | `qcom,mdss_dsi_q200_42_02_0a_p20_prim_dsc_cmd`，**命令模式**，DSC | **不同**（命令模式→视频模式） |
| 背屏 | `qcom,dsi-display-secondary` **status=disabled** | 572×904 副屏（在用） | **pudding 没有，更简单** |
| MDP | `mdss_mdp@9800000`，SSPP VIG `0x2c000/0x35000/0x3e000/0x47000`、DMA `0x98000…`、CTL `0x20000`、INTF `0x18e000`、DSC `0x182000` | 完全相同 | **同** |
| DSI 控制器 | `dsi_ctrl0@9ac0000`、`ctrl1@9ac3000`；PHY `0x9ac1000/0x9ac4000` | 同 | **同** |
| GPU | `kgsl-3d0@3d00000`、`gmu@3d37000`、`kgsl-smmu@3da0000` | 同 | **同**（Adreno 840） |
| APPS SMMU | `apps-smmu@15000000` | 同 | **同** |
| GIC | GICD `0x17000000`，GICR `0x17080000`（stride 0x40000），ITS `0x17040000` | 同 | **同** |
| 计时器 | 19.2 MHz，PPI 13/14/11/10 | 同 | **同** |
| UFS | `ufshc@1d84000`：mem `0x1d84000`、ice `0x1d88000`、mcq_sqd `0x1da5000`、mcq_vs `0x1da4000`，SPI 265 | 同 | **同** |
| SPMI / PMIC | `arbiter@c400000`，`spmi@c426000`（pmk8850）、`spmi@c437000`（pmih010x） | 同 | **同** |
| 电源键 | `pmk8850@0 / pon_hlos@1300`（`pmic_pwrkey`） | 同 | **同** |
| 音量+ | `gpio_keys/vol_up`：TLMM **GPIO 101**，低有效 | 同 | **同** |
| 音量− | `pon_hlos/resin` | 同 | **同** |
| **触摸** | `synaptics_tcm@0` @ `spi@1a80000`（`qupv3_4_geni_se@1ac0000`），compatible `synaptics,tcm-spi`；另有 `/soc/xiaomi_touch` | Synaptics TCM（SPI） | **同厂家同协议**，仅总线实例/GPIO 待核 |
| **电量计** | `bq27z561_standlone@55` @ `i2c@a94000`（`qupv3_1_geni_se@ac0000`） | bq27z561（GPI DMA I2C） | **同芯片** |
| **功放** | `cs35l43@40` + `cs35l43@42` @ `i2c@1980000`（`qupv3_3_geni_se@19c0000`） | CS35L43 ×2（I2C 0x40/0x42） | **同款同地址** |
| 充电/电池管理 | `pmih010x`、`remoteproc-soccp@a3380000`（canoe-soccp-pas）、`smp2p-soccp`、`mca_*` 系列节点 | SOCCP 同架构 | **同架构** |
| 无线充 | `sc96281@33` | — | 新增，暂不关心 |
| 内存可用区 | `0x8c0000000` 起 `0x140000000`（5 GiB） | 同 | **同** |
| 保留区 | `gunyah_hyp_region@80000000`、`mpss_region@8aa00000`、`trust_ui_vm_region@f3800000`、`oem_vm_region@f8800000` 等 | 同族 | **同族** |

## 4. 实际差异清单（这才是要干的活）

1. **面板从"命令模式"变"视频模式"**（`..._dsc_vhm` vs `..._dsc_cmd`）。
   - 影响：pandora 的 `0217-scanout` 与"命令模式自动刷新"的假设要重新验证；视频模式下控制器持续扫描，
     写帧缓冲是否能直接显示，要在第 1 步用 SSPP 寄存器实测。
2. **没有副屏** → 删掉 pandora 里所有 secondary display 的分支。
3. 触摸/电量计/功放的**总线实例与 GPIO** 要重新取值（芯片与协议相同，`synaptics_tcm@0`、`bq27z561@55`、`cs35l43@40/42`）。
4. `demura_region_0/1`（OLED 均匀性补偿）、`lcp_dare_region`、`sc96281` 无线充：pudding 独有，先不管。
5. 分区表以 `partitions.txt` 为准（`sda34` userdata 244 GB，足够放 16 GiB 钉住文件）。

## 5. 结论

**pudding 与 pandora 的 SoC 级配置是逐项对上的**：屏幕缓冲区地址、分辨率、MDP/SSPP 偏移、GPU/GMU/SMMU、
GIC、计时器、UFS、SPMI、按键 GPIO、触摸芯片、功放、电量计，全部同款。
真正要重做的只有 **面板工作模式（视频模式）+ 无副屏 + 几处总线实例/GPIO 取值**。

这意味着：**pandora 的 242 个补丁里，绝大多数可以原样搬过来**，比上一版评估的"周级"还要乐观。
