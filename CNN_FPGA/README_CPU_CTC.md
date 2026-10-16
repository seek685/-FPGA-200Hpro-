# 五级流水线 CPU 与车牌加速器协同实验

本分支 `feature/cpu-lpr-ctc` 基于 `main@55d904d`，接入用户提供的 `12-pipeline-cpu-branch-predictor-original-irom` CPU。已经完成 RTL 仿真，尚未运行 PDS 综合、布局布线、生成新 bit 或上板。水果、cache 和 CSR 指令不在本轮范围内。

CPU 保留五级流水线、4096 项 PHT、512 项 BTB、转发和 load-use 检测。原始目录未改动；移植副本位于 `rtl_pds/cpu/core`，源文件 SHA256 与改动说明见 [cpu_import.json](rtl_pds/cpu/cpu_import.json)。移植新增访存请求有效信号与流水线整体暂停，使用时钟使能逻辑保持流水级、寄存器写回、预测历史与训练的一致性，没有生成门控时钟。原 Vivado PLL/IROM/BRAM 和开发板外设未搬入 Pango 工程。

## PDS Compile 兼容性补丁

Windows PDS Compile 报告 `max_pool2d.sv` 的 `gen_tree.value` / `gen_final_tree.value` 层级名无法解析（Verilog-4123）。现已将树节点移到模块作用域的一维数组，用常量索引连接，消除对 generate 实例层级的引用；比较树结构、两拍使能周期、无符号比较和异步复位保持原语义。

补丁通过 `tb_max_pool2d` 的 7 种窗口/位宽配置回归，覆盖每个输入成为最大值、最高位、相等值、时钟停顿及拍间复位。Linux 环境没有 PDS，本补丁的 PDS Compile 结果仍需 Windows 更新后重跑确认：

```bash
python3 CNN_FPGA/tests/run_rtl_tests.py --test tb_max_pool2d
```

后续 Windows 日志中的新错误是 `lwc_branch_predictor.sv` 的 `Verilog-4092: Loop limit 2000 exceeded`：原 PHT 初始化循环执行 4096 次，超过当前 ADS 解析设置。现改为每次初始化相邻 4 项，默认只循环 1024 次；仍使用完整的 4096 项 PHT，每项初始值仍为 `2'b01`，BTB 初始化与热复位保留训练结果的行为不变。没有缩减预测表或修改工程的循环限制。

补丁已通过原 CPU 和移植 CPU 的 489 项自测（各执行两遍），新增逐项检查全部 4096 项 PHT、512 项 BTB 的初始状态、热复位保留训练表及清空 GHR；CPU CTC 协同与计算中复位测试也通过。Windows PDS Compile 仍需更新后重跑，不能用 Verilator 结果代替 PDS 综合验证。

```bash
python3 CNN_FPGA/tests/run_cpu_tests.py --test core
python3 CNN_FPGA/tests/run_cpu_tests.py --test soc
```

## 本轮实现的协同路径

```text
HDMI / DDR → YOLO、候选框抑制、裁剪 → LPRNet 卷积
                                               ↓
                                  硬件空间归约 + 76 类 argmax
                                               ↓ 每块裁剪 20 个 token（含 blank）
                               带 task_id / 坐标的有界任务队列
                                               ↕ APB4
                                 用户 RV32I CPU 执行 C 固件
                                     CTC 去重 / 删除 blank
                                               ↓ 整包提交
                                  原 OSD 确认、跟踪与 VS 更新
```

这条路径中 CTC 计算由 CPU 执行。固件从硬件读取实际 token，按输入生成输出；没有固定车牌字符串，也没有让电脑替 CPU 计算。相同字符被 blank 隔开时保留两次；全 blank 结果仍会完成任务。`firmware/lpr_ctc/main.c` 在本环境编译后为 **116 字节 RV32I 代码**，使用轮询，不依赖中断或 CSR。

候选框抑制、裁剪调度、DDR 读写和 OSD 稳定确认仍在硬件。CPU 不访问视频 DDR、不搬运像素；没有改动图像帧所有权。这里的 `task_id` 是按裁剪输入递增的编号，不是 DDR `frame_id`。后续迁移 NMS / 裁剪决策时仍需单独设计帧保持、多缓冲、任务与帧绑定；本轮接口不能直接替代该设计。

## 总线与存储

采用单主机、单笔未完成事务的 32 位 APB4 数据总线，具备 SETUP、ACCESS、PREADY 等待、PSTRB 字节写使能和 PSLVERR。读数据在事务完成时锁存，与 CPU 原有 EX 发请求、MEM 取数据的语义对齐。等待期间整个 CPU 流水线保持，加速器与邮箱继续运行。设计参考 [Arm APB 规范 IHI0024E](https://documentation-service.arm.com/static/63fe2c1356ea36189d4e79f3)。这不是 AXI 系统总线，也未实现突发传输、cache 或多主仲裁。

| 地址 | 内容 |
| --- | --- |
| `0x80000000–0x80000fff` | 4 KiB 异步指令 ROM，仅供取指；入口 `0x80000000` |
| `0x80100000–0x80100fff` | 4 KiB 同步数据 RAM，支持 byte / halfword / word；栈顶 `0x80101000` |
| `0x40000000–0x40000fff` | 车牌任务邮箱；只接受对齐的 32 位寄存器访问 |

没有异常/CSR：总线报错、非对齐访问或不支持的访存大小会锁存 `cpu_fault` / `fault_addr` 并停止 CPU，复位恢复。未实现完整非法指令检测、特权异常、`FENCE.I` 自修改代码、M/C 扩展或指令缓存。基本 CPU 测试不能称完整 RISC-V 一致性认证。预测表沿用原 CPU 的初始化方式，热复位保留训练表、清空 GHR；热复位功能已测试。

邮箱偏移如下；读取队首数据不会出队。

| 偏移 | 方向 | 含义 |
| --- | --- | --- |
| `0x00` | 读 | bit 0：任务非空；bit 1：输入协议/坐标关联故障 |
| `0x04` | 读 | 队首 task_id |
| `0x08` | 读 | 队首 `{x[15:0], y[15:0]}` |
| `0x0c` | 读 | 已完成输入的排队任务数，包含 CPU 正处理的队首 |
| `0x10` | 写 | 待提交字符数，0–20 |
| `0x14` | 写 | 写入队首 task_id 原子提交结果并出队 |
| `0x1c` | 读 | 输入任务队列满而整单丢弃的计数 |
| `0x20` | 读 | 同域自由运行周期计数 |
| `0x24` / `0x28` | 读 | 已入队 / 已发送完结果的计数 |
| `0x40–0x8c` | 读 | 20 个输入 token，每个 32 位地址中的低 7 位 |
| `0x100–0x14c` | 写 | 20 个输出字符暂存位置，每个值 0–74 |

默认输入任务队列深度为 8，另有 32 项裁剪坐标队列。坐标在任务准入前就与 token 包配对；任务队列满则整包丢弃，下一任务不会借用它的坐标。在包开始时判定准入，同拍出队不会使已判满的新包重新准入。坐标溢出/缺失或 token 包格式错误时置协议故障，停止接收新的可发布结果，需复位恢复；此前完整入队的任务可继续完成。

COMMIT 检查 task_id、输出字符合法性和已写字符覆盖。错误访问返回 PSLVERR 且不出队；忙于发送上一个结果时通过 PREADY 等待。提交时快照整串和坐标，再按“坐标 → 开始 → 字符 → 结束”送给 OSD。CPU 路径的 OSD 使用 `CROP_HEIGHT=1`，只在结果抵达时消费这份坐标。空结果也有完整边界。原 OSD 的整包 FIFO 满时丢弃、7/8 字筛选、连续两次确认和过期机制保持不变。

## 可复现验证

Linux 需要 Verilator、C++ 编译器、Python 3、`riscv64-unknown-elf-gcc/objcopy/objdump`。本轮 GCC 为 10.2.0，参数为 `-march=rv32i -mabi=ilp32 -Os`。现成 ROM 已提交，Windows PDS 构建无需安装交叉编译器。

```bash
python3 CNN_FPGA/tests/run_cpu_tests.py
python3 CNN_FPGA/tests/lint_cpu_top.py
python3 CNN_FPGA/tests/run_rtl_tests.py
python3 CNN_FPGA/tests/run_reset_integration_test.py
python3 CNN_FPGA/tests/run_reset_integration_test.py --cpu
python3 CNN_FPGA/tests/run_roi_tests.py --check-only
```

本机还对上传的原始 CPU 运行相同自测：

```bash
python3 CNN_FPGA/tests/run_cpu_tests.py --test core \
  --original-dir /home/guillotine/LWC/12-pipeline-cpu-branch-predictor-original-irom
```

本轮结果见 [结构化报告](reports/cpu_lpr_ctc_20261016_summary.json)：

- 原 CPU 与 APB 移植版均通过 **489 个生成检查**，各跑两遍并覆盖热复位。包含算术/逻辑/移位、比较、转发、load-use、小端字节位置、符号扩展、六类分支、预测命中/误预测、JAL/JALR。移植版承受 0–7 拍 APB 等待，两遍累计暂停 1980 拍。没有发现本组测试中的原核功能错误。
- APB 独立测试覆盖建立/访问/等待、字节写使能、读偏移、错误停止、非对齐拦截和复位取消。邮箱测试覆盖同拍入出队、只读窥视、错误 task_id、缺字/非法字提交、整包溢出与恢复、输出反压、坏包和坐标溢出。
- CPU CTC：48 个逐个任务加 32 个过载突发任务，共 58 个接收、22 个整包丢弃；接收任务全部按序完成，字符与坐标正确。额外检查计算中/半包复位后的取消与恢复。
- 逐个任务从最后一个输入 token 到结果结束为 **210–357 个 PE 时钟周期**。这是所测序列的延迟范围，不是所有输入的形式化最坏上界，也不是推理 FPS；突发排队延迟另计。
- 真实 `lprnet_spatial_sum`、`extrema_finder`、CPU 和 `char_overlay` 联合仿真：7 个裁剪、140 个 token；CPU 与原硬件 CTC 的完整字符序列一致。覆盖补齐类别屏蔽、全 blank、重复字符、最后时间步、20 字输出、时钟使能停顿，以及 OSD 的两次确认、坐标绑定、VS 原子更新。
- 原有 6 项基础 RTL 回归通过；顶层/DDR 复位测试分别在 CPU 关闭和开启时通过，开启时实际执行固件轮询，并验证 PE 停钟时复位取消总线。CPU 开启/水果关闭、CPU 关闭/水果关闭、CPU 关闭/水果开启三个顶层配置通过接口 lint。模型、PDS 元数据与输入路径检查通过。

联合仿真的输入是构造的最后一层张量，**没有执行整网卷积或测试真实图片识别精度**。顶层 lint 与复位测试对卷积/厂商 IP 使用明确列出的接口桩；不能称完整综合、DDR 协议、布局布线或上板验证。水果分类仿真本轮未重跑。

修改固件后显式重建 ROM，并重新测试：

```bash
python3 CNN_FPGA/tools/cpu/build_firmware.py --write
python3 CNN_FPGA/tests/run_cpu_tests.py
```

默认构建验证会比较新编译 ROM 与已提交 ROM。不同 GCC 版本可能产生不同机器码；应检查差异后更新 ROM，不能绕过源文件/ROM 一致性检查。启动代码目前要求无 `.data` / `.bss`，链接脚本会拒绝未受支持的初始化数据。

## PDS 与上板下一步

实验分支默认 `CPU_CTC_ENABLE=1`、`ROI_CNN_ENABLE=0`。设 `CPU_CTC_ENABLE=0` 可恢复硬件 CTC；原 `main@55d904d` 保留原功能。17 个 CPU RTL 文件及 ROM 搜索路径已加入 `prj_pds/hdmi_loop.pds`，ROM 为 `rtl_pds/cpu/lpr_ctc.mem`。未修改 FDC、引脚、HDMI、DDR 时钟或网络权重。

实验分支已发布到远端。使用新的 Windows 目录保留旧构建：

```powershell
cd D:\0-contest
git clone --single-branch --branch feature/cpu-lpr-ctc https://github.com/seek685/-FPGA-200Hpro-.git FPGA_200Hpro_CPU_CTC
```

已有该分支副本时，关闭 PDS 后在副本目录运行 `git pull --ff-only origin feature/cpu-lpr-ctc`。早先交付的增量包只是初版快照，后续兼容性补丁以远端分支为准。

打开 `CNN_FPGA/prj_pds/hdmi_loop.pds`，从 Compile 重新运行到 Report Timing；检查 `lpr_ctc.mem` 确实加载、CPU 被实例化，以及完整资源报告。CPU 与邮箱首版直接使用 `clk_pe` 和 `rst_n_app_pe`，没有引入新的时钟域或放宽 `clk_pe=6.500ns` 约束。**该 CPU、预测器、异步取指 ROM 的 Pango 资源映射和频率尚未测得**，不能用本轮仿真或此前旧分支的 LUT 余量承诺可布通/达频。若不达频，应依据实际路径选择流水调整或独立 CPU 时钟及 CDC。

通过时序后再生成新 bit，检查真实摄像头的框、字符和切图恢复。建议观测层级 `gen_cpu_ctc.u_soc` 中的 `cpu_fault`、`protocol_fault`、`accepted_jobs`、`dropped_jobs`、`completed_jobs`、`debug_pc`；零丢包与稳定吞吐必须在真实输入下确认。本轮不提供新的 bit 文件。
