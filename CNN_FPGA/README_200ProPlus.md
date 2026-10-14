# 盘古 200Pro+ YOLO 工程适配

适用板卡：MES2L676-200HP，CORE/BASE V1.2。器件：PG2L200H-6FBB676。

在 PDS 中打开本副本的工程：

`D:\0-contest\yolo_200h_proplus\CNN_FPGA\prj_pds\hdmi_loop.pds`

不要打开原目录中的工程。这个副本包含 YOLO、LPRNet、模型 ROM、DDR 帧缓存和 OSD。2026-10-09 完成板级接口适配；2026-10-14 的识别链路修复与上板说明见下文。

## 修改内容

- `prj_pds/hdmi_loop.fdc`：纠正 15 个 HDMI 输入/I²C 引脚；移除旧 TMDS 输出约束；添加官方 MS7210 的 28 个并行视频输出引脚及电气属性；补上 27 MHz 系统时钟约束。原像素、CNN 和 DDR 时钟约束保留。
- `rtl_pds/hdmi_loop.sv`：将原 FPGA TMDS 串行输出改为送往 MS7210 的并行 RGB、PCLK、HS、VS、DE；RGB 和控制信号同步寄存，输出仍取自最终 OSD 视频流。初始化计数等待配置 PLL 锁定，并保留 KEY0 复位。
- `prj_pds/hdmi_loop.pds`：清除原工程的旧构建状态、旧调试配置与生成的布局约束引用；修正为本机 SP6.1 的综合工具路径。顶层仍为 `hdmi_loop`。

DDR 引脚和 IP、模型权重、网络参数保持不变。MS7200、MS7210 和联合初始化控制源码与本板官方 HDMI 直通例程相同。

## 验证结果（2026-10-09）

- PDS 2022.2-SP6.1 的 `Compile` 实际执行通过，进程退出码 0，用时 1 分 35 秒，编译日志无 `E:` 错误；模型 ROM/字库载入正常。
- 136 个顶层信号位都有引脚及方向约束，136 个引脚无重复占用。HDMI 引脚、电平标准和电压已与本板官方例程核对。73 个 DDR/参考时钟引脚与官方 DDR 例程一致。
- 原工程已有的宽度不匹配、部分寄存器复位及常量探测等警告仍存在；新旧日志的警告类别一致。前端编译通过不代表板级功能或时序已通过。
- **本次没有运行新副本的综合、布局布线或生成 YOLO 码流，也没有板上实测。**

编译日志：`prj_pds/compile/run.log`。

## 接下来在 PDS 中操作

1. 打开上面的 `hdmi_loop.pds`，确认器件为 `PG2L200H-6FBB676`，顶层为 `hdmi_loop`。
2. 依次运行 Compile → Synthesize → Device Map → Place & Route → Report Timing → Generate Bitstream。本轮 RTL 修改后必须从 Compile 重新运行；2026-10-09 的通过记录只适用于当时的源码。检查各步骤成功并检查时序报告。
3. 下载本副本新生成的文件：

   `D:\0-contest\yolo_200h_proplus\CNN_FPGA\prj_pds\generate_bitstream\hdmi_loop.sbit`

   目前该文件尚未生成。不要选择原仓库中的 `dcmi_loop.sbit` 或其它旧码流。

4. 接线：电脑 HDMI OUT → 板卡 HDMI IN；板卡 HDMI OUT → 显示器 HDMI IN；板卡和显示器各自正常供电。
5. 将电脑给 FPGA 的那一路**活动信号**设为 1280×720、60 Hz。Windows 使用扩展显示，打开 `D:\0-contest\hdmi_test\send_image.html`，移动到 FPGA 对应显示区域并全屏显示测试图片。
6. 若下载后初始化没有正常启动，可按 KEY0（C22）复位，不要按重新配置/PROGRAM 键。下载到 SRAM 后保持供电。

如仍无信号，先使用上一级 `baseline_hdmi/hdmi_loop.sbit` 验证本板官方 HDMI 直通；该基线不含 YOLO 或 DDR。

原仓库授权信息保留在 `LICENSE` 和 `THIRD_PARTY_NOTICES.md`。原工程 `D:\0-resource\YOLO_CPU\CNN_FPGA` 与此前的 50H 实验均未改动。

## 2026-10-14：识别链路修复，待上板验证

本轮针对 `now_problem` 中的重叠框、字符刷新和识别异常修改 RTL。电脑 HDMI 输入先验证，之后再用已确认兼容的 HDMI 摄像头；HDMI 驱动、引脚、时钟 IP、DDR 模块和模型权重未改动。

### 已修改的行为

- `box_overlay_sync.sv`：统一零起点行坐标，修复裁剪首行向下偏移两个源图像像素；画框命中、RGB、HS/VS/DE 统一经过两级寄存。
- 候选框在裁剪前进行流式 IoU 抑制，默认重叠阈值 0.5，不区分车牌颜色类别；开始裁剪前保留较高置信度候选。已经开始裁剪的框固定坐标，后续重叠候选被丢弃，防止改动正在采样的子图。
- 检测的 5 个串行 word 先在 PE 域组成一个完整 FIFO 记录。FIFO 满时整框丢弃；槽位用完后仍继续消费候选，避免积压后将半包误解为坐标。无效几何、屏幕外和补齐类别的候选不参与裁剪。
- `lprnet_post_process.sv` / `top_lprnet.sv`：每块子图都有开始、结束脉冲，包括全 blank 结果。`frame_end_out` 晚于最后一个可能输出的字符一拍。补齐通道在 argmax 之前屏蔽，CTC 仍正确保留被 blank 隔开的重复字符。
- `char_overlay.sv`：每个结果消耗一份坐标；黑色排空子图的坐标仍被消耗，但不显示。字符先组装为整串，再用单条 FIFO 记录跨时钟域传输，只在视频 VS 上升沿更新显示。
- 同一位置的完整字符串连续两次一致才更新；默认只接受 7 或 8 字结果。无效长度不补字、不截成合法车牌，也不刷新旧文字的保留时间。未重新确认的旧文字最多显示 6 个视频帧，之后清除，避免切图或车辆离开后长期残留。

该显示筛选可以减少错误字符串闪现，但不代表模型已正确识别。6 字漏识别或 9 字多识别会表现为有检测框、没有新文字；原来已经确认的文字短暂保留后消失。稳定的“苏→浙”等同长度误识别仍需要裁剪图与模型输出对照。

### 顶层可调参数

参数集中在 `rtl_pds/hdmi_loop.sv` 的模块声明中，每次改动均需重新综合并生成码流。

| 参数 | 本轮默认值 | 用途 |
| --- | --- | --- |
| `YOLO_CONF_THRESH` | `8'h60`（96，约 0.38） | 原值 `8'h40`；本轮先提高门槛减少背景候选，尚未做数据集标定。若明显漏检，可单独回调到 `8'h40` 对比。 |
| `NMS_IOU_THRESH` | `128` | 单位为 1/256，即 IoU ≥ 0.5 的候选按上述规则抑制。 |
| `OSD_MIN_CHARS` / `OSD_MAX_CHARS` | `7` / `8` | 完整结果的显示长度范围。 |
| `OSD_CONFIRM_RESULTS` | `2` | 同一位置连续一致的识别结果次数，不是视频帧数；须 ≥ 1。 |
| `OSD_HOLD_FRAMES` | `6` | 已确认文字的保留帧数；60 Hz 下约 100 ms，须 ≥ 1。 |

需要观察原始漏字/多字时，可另编诊断码流：`OSD_MIN_CHARS=1`、`OSD_MAX_CHARS=20`、`OSD_CONFIRM_RESULTS=1`。这只放宽显示筛选，不改变模型或 CTC。不要把诊断码流与本轮默认码流混用作准确率对比。

### 本地验证与限制

在有 Verilator 和 C++ 编译器的环境，从仓库根目录运行：

```bash
python3 CNN_FPGA/tests/run_rtl_tests.py
```

本轮三组 Verilator 回归全部通过。覆盖：全 blank 的开始/结束边界、CTC 重复字符、最后一个时间步、补齐通道掩码、时钟暂停、坐标与空结果配对、整串双次确认、VS 原子更新、8 字换 7 字不残留尾字、无效长度/排空子图、旧字过期、文字边界、实际字模像素与背景/DE 对齐、20 字诊断模式、重叠框和不同目标、采样锁定、1:1 与双线性缩放的全部 1600 个像素、右下边界、画框视频延迟，以及满槽/FIFO 溢出时的包边界。

顶层接口 lint 也通过，但 DDR、PLL、HDMI 配置控制器和 CNN 卷积层使用了按现有端口生成的接口桩；该检查只验证接线和参数展开。完整源代码的 Verilator lint 遇到原有 HDL 兼容性问题（HDMI 控制器的重复 net 声明、CNN 算子的阻塞/非阻塞混合赋值）；本轮未改动这些模块，不能把接口检查当成完整工程编译通过。

测试使用合成像素和合成网络输出，**不是原始车牌图片的端到端准确率测试**。本环境不具备 PDS 实现工具，本轮尚未运行 PDS 综合、布局布线和时序报告，也没有生成新 `.sbit` 或进行上板测试。新增逻辑的资源占用与时序需要由 PDS 实现结果确认。

### PDS ADS 解析报错的语法补丁（2026-10-14）

本地 PDS 日志在 `char_overlay.sv`、`box_overlay_sync.sv`、`extrema_finder.sv` 和 `lprnet_post_process.sv` 中报告 `Verilog-4005`。报错位置对应本轮新增的 `for (integer k=...)`、`int'(...)` 和 `WIDTH'(...)` 写法；后面的 `Identifier k is not declared`、`near else` 是解析失败后的连带报错。Compile 未成功生成 ADF，因此后续 Synthesize 还会报告 `Flow-0002`。

已将循环变量移到模块声明区，各个过程使用独立变量；类型和位宽转换改为显式扩展、位截取及定宽常量。边框负坐标保留有符号 32 位运算后再限幅，字模行列偏移取低 4 位。补丁保持原有识别、裁剪、显示流程和接口。

修改后重新运行三组 Verilator 回归，全部通过；裁剪测试增加了左上角负坐标框，检查限幅后的坐标及全部 1600 个输出像素。四个修改模块已检查没有残留上述报错写法。**这仍不等于 PDS 编译或综合已通过，须在本地 PDS 再运行 Compile 验证。**

随后 PDS 在 `text_pe[length_pe]` 报告 `Indexes for multiplier packed range must be constant`。第二版补丁将 `text_pe`、`pending_text` 和 `display_text` 改为一维字符位向量：第 0 个字符固定占最低 7 位。输入字符用 generate 展开的固定 7 位切片写入，运行时索引只控制写使能；显示端从一维位向量取定宽字符切片。复位、整串跨时钟传输及显示流水拍数保持原样。第二版修改后，OSD 回归重新通过，包括实际字模像素、7/8 字切换、20 字诊断模式的逐字符顺序检查；静态复核未发现重叠驱动。第二版仍待实际 PDS Compile 验证。

已下载首次工程包或第一版补丁时，使用累计补丁 `FPGA_200Hpro_PDS_fix_v2_20261014.zip`：关闭 PDS，将补丁解压到包含 `CNN_FPGA` 的目录（例如 `D:\0-contest\change`）并覆盖对应文件，再打开 `CNN_FPGA\prj_pds\hdmi_loop.pds`，从 Compile 开始执行。补丁包含上述四个 RTL 文件、仿真测试及说明，不替换本机 `.pds` 设置。完整工程 ZIP 也已同步更新。

### 本轮上板操作与反馈

2026-10-14 的首次 ZIP 打包遗漏了对 `.pds` 构建状态的清理：包中没有旧 `compile` 缓存，但工程仍记录 Compile 已完成及 `compile/hdmi_loop_comp.adf` 等输出。直接进入综合时可能报 `Flow-0002`，提示该文件不存在。当前工程及重新打包的 ZIP 已将 Compile 状态重置为未运行，并移除旧输出记录；源码、器件和约束配置不受影响。已下载旧包的用户可先在 PDS 中单独重新运行 Compile，确认本地生成 `prj_pds/compile/hdmi_loop_comp.adf` 后再运行 Synthesize。若 Compile 失败，应先处理其日志里的第一条 `E:`，缺少 ADF 只是后续综合无法读取编译结果的表现。

1. 打开当前目录的 `prj_pds/hdmi_loop.pds`，重新运行 Compile → Synthesize → Device Map → Place & Route → Report Timing → Generate Bitstream。没有新增综合源文件；`tests` 目录只用于仿真，不要加入 PDS 综合文件列表。
2. 下载本次生成的 `prj_pds/generate_bitstream/hdmi_loop.sbit`，核对文件时间；输入继续使用已验证的 1280×720、60 Hz HDMI 信号。
3. 先全屏显示同一张测试图并保持数秒，记录：实际车牌、框数、是否漏框、显示字符串、是否跳字/闪烁。重点重测重叠黄牌、漏“3”、多“A”和“苏→浙”的图片。
4. 再测多车牌图片，以及从有车牌切到无车牌画面：检查不同车牌的文字是否错位，旧文字是否短暂保留后清除。保留网页 UI 的测试单独进行，以比较背景误检。
5. 若有框但没有文字，反馈时与“完全没有检测框”区分；前者可能由长度或两次一致筛选触发。最好附同一画面保持 5～10 秒的视频，以区分稳定错字和刷新闪烁。
6. 若 PDS 编译、综合或时序失败，保留第一条错误及相应日志反馈，暂不把该轮当作板上识别结果比较。

可供后续逻辑分析仪观察的内部状态：`u_box_overlay_sync.dbg_box_packets_dropped`、`u_char_overlay.dbg_coord_error`、`u_char_overlay.dbg_result_dropped`、`lprnet_frame_start`、`lprnet_frame_end`、`lprnet_out_valid` 和 `lprnet_out_char`。`dbg_coord_error` 为黏性标志：发生坐标队列溢出/欠读后停止发布新文字，复位后恢复，防止持续显示错配结果。
