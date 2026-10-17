# FPGA 200Hpro：CNN 加速器与 RISC-V CPU

`CNN_FPGA/` 保留仓库已有的神经网络工程。本次新增两个独立 CPU 工程：

| 目录 | 用途 |
| --- | --- |
| [riscv32-performance](riscv32-performance/) | 优化后的五级单发射 RV32I CPU、原版对照、回归测试和纯核时序报告 |
| [riscv32-boardtest-200pro](riscv32-boardtest-200pro/) | 200Pro+ 独立 CPU SoC、PLL、UART、RAM/ROM、CoreMark 固件及已验证上板位流 |

当前 CPU 尚未与 CNN 组成异构系统，也尚未加入硬件乘法。CPU 最终选择版本为 rev3；rev4 报告仅作为对照保留。

## 已确认的性能

200Pro+ 实板串口结果，CoreMark 官方校验通过，运行时间超过 10 秒。

| 项目 | 结果 |
| --- | --- |
| CPU 时钟 | 120 MHz，由板载 27 MHz 经 PLL 产生 |
| ISA / 编译器 | RV32I / ILP32，GCC 15.2.0，`-O2` |
| CoreMark 迭代 | 3000 |
| 硬件计时周期 | 2,500,779,626 |
| 运行时间 | 20.839830 秒 |
| CoreMark | 143.955108 |
| CoreMark/MHz | 1.199626 |

原始输出：[board_result_user.txt](riscv32-boardtest-200pro/build/coremark120_board_v2/board_result_user.txt)。该记录由用户提供，并非脚本自动采集。

完整板级布局布线通过 120 MHz 时序：setup +0.169 ns、slow hold +0.147 ns、fast hold +0.100 ns。[验证汇总](riscv32-boardtest-200pro/build/coremark120_board_v2/validation_summary.json)。纯核的 150 MHz 时序结果不等于本上板位流运行在 150 MHz。

## 直接上板

1. 接好电源、JTAG 和板载 USB 转串口；串口设置为 **115200、8N1、无流控**。
2. PDS Fabric Configuration 扫描到 **PG2L200H** 后，用 JTAG/SRAM 临时下载 [board_top.sbit](riscv32-boardtest-200pro/build/coremark120_board_v2/generate_bitstream/board_top.sbit)。CoreMark 程序已包含在位流内。
3. **只按底板 KEY0（C22）再松开，重启 CPU。** 硬件 RESET 经配置复位链路连接 FPGA，可能重新加载 Flash 中的原工程；如果按过 RESET，应重新下载测试位流。
4. 串口出现 `CPU BOARD TEST`、`SMOKE PASS`、`COREMARK ITERATIONS=3000` 后，等待约 21 秒。有效结果应有 `Correct operation validated`、运行时间不少于 10 秒且无错误或计数器溢出。

[完整上板说明](riscv32-boardtest-200pro/上板测试说明.txt)。位流 SHA256：

```text
DFEF9BBA402D7A42A7EA7021F7833E2FD2E64E2592975071D44B568698DDD6E0
```

## 构建与复现

使用 Windows PowerShell。脚本保留了本机 PDS 2022.2-SP6.1、ModelSim、RISC-V GCC 路径；其他电脑需按脚本参数或安装路径调整。进入相应工程目录再执行。

```powershell
# riscv32-boardtest-200pro：构建固件，随后生成新的板级实现目录
.\scripts\build_firmware.ps1 -Iterations 3000 -CpuHz 120000000
.\scripts\build_board.ps1 -FirmwareDir .\firmware\build_coremark_i3000_hz120000000 -Label coremark120_rebuild

# 五组板级功能仿真：MMIO、UART、复位、启动测试、CoreMark 单迭代
.\tests\run_board_tests.ps1 -Test All

# 串口采集；COM7 替换为实际端口，监听后按 KEY0
.\scripts\capture_uart.ps1 -Port COM7
```

纯核优化说明及回归命令：[VALIDATION.txt](riscv32-performance/VALIDATION.txt)。已有 30/30 回归通过，原版与优化版架构执行轨迹一致。板级五组测试均通过，PLL 也经过厂商模型验证。

## 软件乘法与 O3 对照

相同 RTL、算法和 RV32I 编译参数的单迭代仿真：O2 为 835,295 周期，O3 为 839,082 周期。软件乘法调用 9396 次，其内部指令及分支恢复约占 O2 总周期的 60.43%。O3 没有消除软件乘法。

按其余开销不变、每次硬件乘法 1～3 周期推算，可能达到约 2.79～2.95 CoreMark/MHz；这只是后续改进的估算，当前工程没有实现该乘法器，也没有对应板测成绩。

[剖析说明](riscv32-boardtest-200pro/tests/profile_coremark/PROFILE_COMPARISON.txt) · [详细数据](riscv32-boardtest-200pro/tests/profile_coremark/o2_o3_comparison.json)。单迭代仅用于正确性和周期分析，保留官方不足 10 秒的成绩无效提示，不能作为正式成绩。

## 提交内容与来源

本次保留源码、固件及 ELF/HEX、验证脚本、最终报告、位流和必要的原版对照。PDS 中间数据库、ModelSim 工作库、巨大的逐指令 trace 及失败的 v1 构建未纳入快照，均可通过脚本重新生成。历史报告中的绝对路径用于记录原始构建环境。

CoreMark 源码及许可随工程保留。`CPU_SNAPSHOT_SHA256.json` 记录此次发布文件的 SHA256；Git 属性禁用这两个工程的自动换行转换，保持与已验证本地文件相同的字节。
