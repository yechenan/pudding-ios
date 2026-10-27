# pudding 上的第一次启动：hello（2026-10-27）

镜像：`pudding-hello-boot.img`（20 KB，boot header v4，kernel 16124 B，ramdisk 0）
命令：`fastboot boot pudding-hello-boot.img`
结果：`Sending ... OKAY / Booting OKAY`，屏幕上出现完整自检页，116 秒后自动重启回安卓。
**全程未写任何分区。**

## 屏幕读数（照片转录）

| 项 | 值 | 说明 |
|---|---|---|
| LEVEL | **EL1** | 我们在 EL1 拿到了控制权 |
| LOADED | `0x00000000C7800000` | ABL 装载地址；**与 pandora 完全相同** |
| DTB | `0x0000D5BF9000`，`FDT ok` | 设备树指针有效，可直接用于生成 ADT |
| MIDR | `0x00000000512F0021` | implementer 0x51（高通 Oryon），part 0x2F0 |
| MPIDR | `0x00000000B0000000` | 当前跑在某个大核上 |
| MMFR0 | `0x0210012210001024` | — |
| **PAGES** | **16K NO / 4K YES / 64K YES**，PA 44 bits | **确认 16K 页不支持**，必须 4K 页内核 |
| CNTFRQ | 19200000 Hz | 与 DT 一致 |
| SCTLR_EL1 | `0x0000000030D00988` | MMU 关闭、cache 关闭（符合预期） |
| **FB** | `0x00FC800000`，**1220×2656**，**stride 4880** | 与 pandora 的 splash_region 完全一致；4880 = 1220×4，ARGB8888 |
| VIG0–3 / DMA0–5 | 见下 | 寄存器读到了，但值不像活跃管道 |
| BARS | 红绿蓝白 | **屏幕上真的出现了四个色条** |
| TIMER | 116 s 后重启 | 自动回到安卓 |

## 最重要的三条结论

1. **`fastboot boot` 可用** —— ABL 接受我们的镜像并跳转执行。
2. **显示通路是活的**：往 `0xFC800000` 写像素，屏幕上能看到（红绿蓝白条 + 文字全部正确显示）。
   这回答了版块 1 最大的疑问——**视频模式面板在 ABL 交接后仍然被扫描**，不需要先把 MDP 重新初始化。
   这一条比 pandora 当年更省事（它是命令模式，需要额外的推进逻辑）。
3. **16K 页不支持**（`TGran16 = 0`），4K 页内核是唯一选择——与 pandora 同一结论，补丁可复用。

## 待解释的地方

VIG/DMA 管道寄存器读出来是 `00000000 / 000001F / 00000004 / 0000FF00`（DMA 是 `0000F000`），
不像正在工作的管道应有的源地址/步长。但显示明明是好的，说明：
- 要么这些 SSPP 当时确实没被使用（ABL 用了别的通路，或者已经交给 DSI 直通）；
- 要么寄存器偏移与 SM8850 上实际排布有差异（pandora 也遇到过"10 个 SSPP 读出来全是 0"）。

不影响版块 1 的结论（画面能用），留到版块 4 处理图层时再深究。

## 复现步骤

```bash
# WSL Ubuntu 24.04 里编译（clang 18 + lld）
cd data-a-live/shim/hello
clang --target=aarch64-none-elf -O2 -ffreestanding -fno-builtin -nostdlib \
      -fno-pic -fno-stack-protector -mgeneral-regs-only -mstrict-align \
      -Wall -Wextra -Werror -c start.S -o out/start.o
# 同上编 hello.c，然后：
ld.lld -T hello.ld --build-id=none out/start.o out/hello.o -o out/hello.elf
llvm-objcopy -O binary out/hello.elf out/Image

# Windows 侧打包 + 启动
python data-a-live/tools/mkbootimg_v4.py out/Image pudding-hello-boot.img
fastboot boot pudding-hello-boot.img
```
