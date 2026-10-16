# 盘古 200Pro+ YOLO 工程适配

## 2026-10-16：五级流水线 CPU 协同实验分支

`feature/cpu-lpr-ctc` 已接入用户提供的五级流水线/分支预测 RV32I CPU，通过 APB 总线执行车牌 CTC 解码，并把结果交给原 OSD。本分支默认 `CPU_CTC_ENABLE=1`、`ROI_CNN_ENABLE=0`，暂不涉及 cache、CSR 或水果识别；原 CPU 上传目录保留不动。仿真与顶层接口检查已完成，PDS 综合、资源/时序和上板尚未验证。

架构、测试证据、寄存器表、固件重建和 Windows 新目录构建步骤见 [CPU 协同实验说明](README_CPU_CTC.md)。下文较早的默认值和验证记录对应各自历史版本，不是本实验分支的 PDS 结果。

## 2026-10-16：报告分析、复位同步与池化时序修复

已收到并校验 [PDS 报告附件](https://github.com/seek685/-FPGA-200Hpro-/releases/tag/pds-debug-20261016)，ZIP 为 133,810,194 字节，SHA256 与 GitHub 一致、全部 CRC 通过。包内 371 个 RTL 文件在统一换行后与 **`feature/roi-fruit-cnn@dc4e6ee`** 一致；本次实现时间为 10 月 15 日晚，工具为 PDS 2022.2-SP6.1 build 138931。这是旧水果分支的实际构建，不能当成合并后 `main` 的实现结果。结构化证据与路径见 [报告摘要](reports/pds_20261016_summary.json)。

主要发现：

- 慢角 Setup WNS 为 **−6.136 ns**，TNS 为 **−449.055 ns**，127 个失败端点。其中 90 个来自配置时钟域的 `rstn_out` 直接进入 PE/视频域；异步复位 Recovery 另有 6,792 个失败端点，最差 **−9.233 ns**。
- `clk_pe` 内部有 37 个 Setup 失败端点，最差 **−0.292 ns**。报告中该组最差路径位于 LPRNet 第 28 层池化，原代码把五个值串行比较，单拍经过四级比较/选择。
- 视频域同域 Setup 仅余 **+0.128 ns**，最差路径在旧版字符叠加；两个角的 Hold 均无违例。报告另有 60 个输入、104 个输出的未约束端口警告，包含 HDMI、DDR 和 I2C，板级 I/O 时序覆盖还需结合接口规范核查。
- 旧分支虽成功生成 `.sbit`，其时序并未收敛。

本轮在 `main` 修复配置完成信号的组合译码复位，增加视频、PE 和 DDR 用户逻辑各自的三级复位释放同步；HDMI `init_over` 经过两级同步后再控制视频输出。按已核对的复位/状态跨域连接加入 `cfg_async` 配置时钟组，目标时钟域内部的复位路径仍参与时序分析。池化改为平衡比较树，3×3 窗口每级最多两级比较，保持原有两拍延迟、时钟使能及控制对齐。

**验证：六项基础 RTL 回归、四项 ROI 回归、顶层/DDR 复位连接仿真通过。** 池化覆盖七种窗口/位宽组合、停顿及异步复位；复位连接仿真覆盖时钟迟到/停钟、首个 VS 和 HDMI 配置使能同步。ROI 开/关顶层 lint 通过，包含真实 DDR 包装及控制 RTL；卷积层和厂商 IP 使用接口桩。上述验证不能替代 PDS 实现、DDR 实物验证或摄像头测试。本轮尚未运行 PDS、生成新 bit 或测得修改后的资源用量。

```bash
python3 CNN_FPGA/tests/run_rtl_tests.py
python3 CNN_FPGA/tests/run_roi_tests.py
python3 CNN_FPGA/tests/run_reset_integration_test.py
```

### 资源基线与 CPU 余量

以下数字均来自上传包内旧分支的 **Place & Route** 报告：

| 资源 | 已用 | 总量 | 剩余 |
| --- | ---: | ---: | ---: |
| LUT | 94,405 | 159,800 | 65,395 |
| FF | 102,259 | 319,600 | 217,341 |
| DRM | 267.5 | 415 | 147.5 |
| APM | 280 | 740 | 460 |

布局布线后的 LUT 为 CLMA 的 72,015 加 CLMS 的 22,390，约 59.1%；较早 Device Map 的 83,600/53% 是另一阶段数据。CLMA/CLMS 逻辑块占用分别约 74.6%/69.5%，所以 LUT 的账面余量不能直接视为全部可用于 CPU 的空间。DRM 半块计数沿用 PDS 口径。CPU 的乱序窗口、物理寄存器、缓存、互联和频率尚未给出，不能承诺乱序双发射 RV32 核一定容纳得下，还需预留后续检测及布局布线空间。

后续面积优化的一个明确候选是 LPRNet：参数展开有 293 个卷积 PE，当前全部采用 LUT 移位加法乘法；实际 APM 映射为 YOLO 207、框/裁剪模块 72、ROI 分类器 1，LPRNet 为 0。可评估把部分 LPR 乘法改用 APM，以减轻 LUT 压力，但收益必须通过逐拍整数对齐及 PDS 对照确认，本轮尚未切换。接入水果检测时优先评估共享水果/车牌检测网络，并由新功能替换固定 ROI 分类支路，保留 LPR。

### 本地验证此修复

原 Windows 副本仍在旧分支，且有 PDS 构建修改；用新目录取得 `main` 可以保留本次证据：

```powershell
cd D:\0-contest
git clone --depth 1 --branch main https://github.com/seek685/-FPGA-200Hpro-.git FPGA_200Hpro_main_20261016
```

关闭旧工程，在 PDS 打开新目录下的 `CNN_FPGA/prj_pds/hdmi_loop.pds`，从 Compile 依次运行到 Report Timing。检查新源文件 `reset_release_sync.sv` 已加载，`cfg_async` 组包含 `sys_clk` 及其推导的 10 MHz 配置时钟，且没有未匹配时钟警告；重新核对所有 Setup/Hold/Recovery/Removal 失败组和资源用量。`clk_pe=6.500 ns`、`pixclk_in=13.000 ns` 保持原值。实际时序结果以本次重跑为准。

## 2026-10-16：后续 PDS 报告收集方法

保留发生问题的构建及对应源文件，在该工程运行布局布线后的 Report Timing，保存报告并关闭 PDS，再执行打包。

`tools/collect_pds_debug.ps1` 会复制本地实际使用的整个 `prj_pds`、`rtl_pds`，连同 Git 提交号、未提交差异、文件时间清单生成 ZIP；不会修改原工程，也不会替你运行 PDS。包内包含构建数据库，可能较大。若尚未更新到包含脚本的提交，可以只下载脚本后打包，避免改变失败构建对应的源码：

```powershell
cd D:\0-contest\FPGA_200Hpro_RO
Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/seek685/-FPGA-200Hpro-/main/CNN_FPGA/tools/collect_pds_debug.ps1" -OutFile "$env:TEMP\collect_pds_debug.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\collect_pds_debug.ps1" -ProjectDir ".\CNN_FPGA" -OutputDir "$HOME\Downloads"
```

需要报告能覆盖：布局布线后的 Setup/Hold 汇总及最差路径（起点、终点、时钟、slack、逻辑/布线延迟）、时钟与未约束路径、LUT/FF/DRM/APM 资源、工具版本及完整警告。若报告只在界面中显示，请导出到 `prj_pds` 后再打包。

下一阶段目标为摄像头拍摄“十种常见水果的打印图片 + 打印车牌”，目标可在画面不同位置，并保留车牌字符识别。首版水果类别选为苹果、香蕉、橙子、梨、桃、葡萄、草莓、西瓜、菠萝、芒果。现有水果模型只支持固定区域四类分类，不具备目标坐标预测。全画面检测需要带边界框的训练数据、检测模型、定点导出、类别分流及实测验证；目前尚未实现或验证十类水果检测。先确认修复后的时序和资源，再结合 CPU 预算确定检测改造方案。

## 2026-10-15：主分支合并车牌修复与固定区域水果分类

当前使用 `main`。水果分类最初在 `feature/roi-fruit-cnn` 上基于板级适配提交 `4706536` 开发；现已将该功能及 PDS 文件条目修复 `dc4e6ee` 合入主分支，同时保留主线 `20678cd`、`1034ac8` 的车牌裁剪、候选框抑制、CTC、字符稳定显示、16 目标文字容量和 PDS 语法兼容修复。YOLO/LPRNet 权重、HDMI/DDR 和引脚继续沿用原工程。

**当前完成：RTL 合并、训练/定点权重导出、软件整数对照；合并后四组车牌回归和四组水果回归全部通过。PDS Compile、综合、布局布线、时序验证和板上测试仍待本地执行，没有生成本次合并的新 `.sbit`。** 下文较早的 Compile 记录不适用于本次合并后的源码。

### 第一版功能

- HDMI 输入仍要求 **1280×720、60 Hz**。新功能没有增加 1080p 支持。
- 屏幕中心显示 **224×224** 的固定绿框，左上角坐标 `(528,248)`。将一个物体放入框内，显示 `APPLE`（苹果）、`BANANA`（香蕉）、`ORANGE`（橙子）或 `OTHER`（其他/背景）；等待结果时显示 `WAIT`。
- 这是固定区域内的单物体分类。它没有在全画面搜索水果，也不能同时给多个水果分别画框。
- 原车牌 YOLO/LPRNet 分支继续运行。新分类输入取自原始 RGB，位于画框、写字之前，避免把 OSD 图案送入模型。
- 新 CNN 的采样、卷积、池化、全连接和类别选择都在 FPGA 中完成；电脑只在开发时训练和验证模型，演示时可直接由 HDMI 摄像头输入。
- `hdmi_loop.sv` 参数 `ROI_CNN_ENABLE=1` 默认开启。改为 `0` 并重新编译可旁路新增功能。没有增加顶层引脚。

### 下载与上板

首次下载时取得主分支：

```powershell
git clone --branch main https://github.com/seek685/-FPGA-200Hpro-.git FPGA_200Hpro_ROI
```

如果此前通过 `--single-branch` 下载了水果分支，先关闭 PDS，在已有仓库目录执行以下命令。第一条让此副本也能获取主分支；有未提交修改时先保留自己的修改，不要强制覆盖。

```powershell
git remote set-branches origin "*"
git fetch origin
git switch main
git pull --ff-only origin main
```

1. 在 PDS 打开 `FPGA_200Hpro_ROI/CNN_FPGA/prj_pds/hdmi_loop.pds`，确认器件 `PG2L200H-6FBB676`、顶层 `hdmi_loop`。源文件列表已加入三个新 RTL 和模型头文件，旧 Compile 完成状态已清除。工程沿用原综合器安装路径；若本机 PDS 安装目录不同，在工具设置中选择本机的 Synplify。
2. 依次运行 **Compile → Synthesize → Device Map → Place & Route → Report Timing → Generate Bitstream**。先确认 Compile 没有错误且八个 `roi_cnn` 权重/偏置 ROM 均成功加载，再继续。检查新增存储的实际 DRM 映射及像素时钟域时序。
3. 下载本轮新生成、时间戳正确的 `prj_pds/generate_bitstream/hdmi_loop.sbit`。
4. 首次使用电脑 HDMI，活动信号设为 1280×720、60 Hz。打开 `CNN_FPGA/demo/roi_fruit.html`，移动到 FPGA 对应的扩展显示屏，按 Enter 或 F11 全屏。按左右键切图，W 切换空白，每张保持至少两秒。页面提供八张确定的测试输入，绿框与黄色分类文字由 FPGA 生成。
5. 电脑测试通过后接 HDMI 摄像头，先用浅色、简单背景，单个苹果/香蕉/橙子放在框内，保证对焦清楚并占据框的大部分。之后再增加复杂背景和姿态变化。已有摄像头清晰度问题不由本次增加分类功能自动解决。

反馈时记录：输入模式、显示类别、原车牌功能是否受影响；编译失败时提供第一条错误。若图像正常但分类异常，区分长期 `WAIT`、总是 `OTHER`、固定错类及来回跳类。

若打开早期水果分支时出现 `Flow-0130`，指向 `hdmi_loop.pds` 第 24 行：四个新增源文件条目曾遗漏 `_timespec`，现已按原工程格式补齐并随功能合入 `main`。按上面的命令更新，再重新打开工程。可运行 `python3 CNN_FPGA/tests/run_roi_tests.py --check-only` 检查文件条目和模型文件；此检查不能代替 PDS Compile。

### 模型与验证结果

模型结构参考 MIT 项目 [MicroCNN-TangNano20k](https://github.com/SweiryDev/MicroCNN-TangNano20k)，重新训练水果权重并新写可移植 RTL。没有复制其 Gowin 原语或 BloodMNIST 权重。

`RGB 28×28 → Conv3×3(3→8) → ReLU/Pool2 → Conv3×3(8→16) → ReLU/Pool2 → FC400→32 → ReLU → FC32→4`

- RGB 输入为 uint8，软件训练使用 `RGB/256`；权重 int8、偏置/累加 int32。三个隐藏层的定点右移为 **10、8、10**，右移截断后饱和到 0～255。卷积权重 OIHW、特征 CHW，与导出和 RTL 一致。
- 14,296 个权重、60 个偏置；核心逻辑存储约 **25.41 KiB**，不含存储块取整和外围逻辑。单个共享乘法数据通路。实际 LUT/APM/DRM 用量以 PDS 报告为准。
- 仿真每次推理 **634,580 个时钟周期**，在 74.25 MHz 下约 **8.55 ms**，不含视频采集。当前在帧开始时遇到 busy 会跳过整帧，标准 720p60 下仿真每两帧采一次。此为仿真/时序推算，不是实板帧率。
- 模型训练集 2,176 张、验证集 543 张、测试集 940 张，含合成背景；真实水果来自固定版本 Fruits-360 子集。验证集选训练轮次，测试集未用于选择模型。浮点测试准确率 **93.72%**，整数模型 **93.83%（882/940）**。
- 四类测试分别为：苹果 **232/240**、香蕉 **120/120**、橙子 **120/120**、其他 **410/460**。这些是此数据子集上的分类结果，**不是摄像头、复杂场景或所有苹果品种的准确率**。`OTHER` 仅见过部分其他水果与合成背景，不保证拒绝所有未知物体。
- Fruits-360 图片主要为白背景，训练/验证含相关的旋转视角，未完成跨实物、跨摄像头泛化评估。训练中增加旋转、缩放、亮度/颜色变化和噪声；相同物体实拍仍可能需要进一步微调。

验证覆盖：ROI 的全部 8×8 像素均值、地址顺序、忙帧/异常 VS/截断帧；核心全部隐藏层的合成整数参考、8 张真实图片共 32 个 logits 逐位一致、复位/忙时写入/done 协议；OSD 两次确认、VS 更新、过期、字体/边界及视频对齐；六帧标准 720p 的采集→真实 CNN→OSD 集成检查。启用/旁路两种顶层接口 lint 也通过，但旧模块/IP 使用接口桩，不能等同完整工程编译。

在安装 Verilator 和 C++ 编译器的 Linux 上运行：

```bash
python3 CNN_FPGA/tests/run_rtl_tests.py
python3 CNN_FPGA/tests/run_roi_tests.py
```

第一条运行四组车牌链路回归，第二条运行四组水果分类回归。合并保留 `YOLO_CONF_THRESH=8'h60`、`NMS_IOU_THRESH=128`、`OSD_MAX_PLATES=16` 等主线设置；`ROI_CNN_ENABLE=1` 默认启用新增分类。此版本的车牌显示筛选与早期水果独立分支有所不同，参数说明见下方 2026-10-14 修复记录。

本次合并后八组回归全部通过，模型校验及 PDS 文件条目/路径检查通过。重新运行的顶层接口 lint 在 ROI 开启和旁路时均通过：使用真实 ROI、车牌画框/裁剪/字符叠加、网络顶层及后处理，卷积计算体、DDR、PLL、HDMI 配置等使用按当前接口生成的桩。存在旧模块及接口桩警告；此检查不能代替完整 PDS 编译或板上验证。

软件模型及详细结果位于 `models/roi_fruit`；采样测试图位于 `tests/fixtures/roi_cnn`；训练、下载和整数参考代码位于 `tools/roi_cnn`。Python 依赖为 PyTorch 2.5.1 CPU、NumPy 2.1.3、Pillow 11.0.0。完整训练图片不在 Git 中，下载脚本锁定源提交、校验每张图片的 Git blob SHA 和 SHA256：

```bash
python3 CNN_FPGA/tools/roi_cnn/download_fruit_subset.py /tmp/fruit_subset
python3 CNN_FPGA/tools/roi_cnn/train_export.py /tmp/fruit_subset --output /tmp/fruit_model --epochs 45 --threads 4
```

再训练时必须一起更新八个 ROM、`roi_cnn_model.vh`、NPZ 模型、测试向量和 `artifact_sha256.json` 校验清单，并重新运行上述仿真；不能只换 `.mem` 而保留旧的移位参数。数据、模型及参考项目的来源和许可见 `THIRD_PARTY_NOTICES.md`。

---

以下为原始 200Hpro 适配记录。

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
| `OSD_MAX_PLATES` | `16` | 整帧文字跟踪容量，独立于可按行回收的 6 个并行裁剪槽；避免 7～8 个目标轮流挤掉待确认文字。 |
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

## 2026-10-14：new_problem_1 的缩放与多目标问题

新反馈包含缩放后漏框、有框无字、字符闪烁，以及用户补充的“甘”在小图时识别为“皖”、放大后识别正确。这几种现象不能当成同一原因。

### 已复现并修复：多目标文字缓存互相覆盖

原顶层把 `char_overlay.MAX_PLATES` 与 `MAX_BOX_NUM=6` 绑定。但裁剪槽在视频扫描越过车牌后可以回收，一帧实际可能输出超过 6 个不同车牌的识别结果；新照片 `af23fc4d7602ec7e6019e72d857d251a.jpg` 就可见 7 个框而无文字。

仿真重复输入 8 个不同位置、完全稳定且长度合法的字符串时，旧 6 槽配置会在第二次确认前逐出前一轮记录，连续多轮仍无文字。顶层现增加独立参数 `OSD_MAX_PLATES=16`，不增加裁剪 FIFO 数量；仍要求同一位置的完整结果连续两次一致，再于 VS 更新显示。新增 `tb_char_overlay_multitarget` 保留旧配置作为负对照，并检查 16 槽配置的确认、连续显示、帧边界更新和停止输入后的过期。

### 已定位的限制，本次未修改

- **小车牌并未被真正放大到 LPRNet 输入尺寸。** `layer20.vh` 固定输入为 80×20。`box_overlay_sync` 先左右各加 10 像素、上下各加 5 像素，再将不足 80×20 的区域主要向右、向下扩展。比如原检测区域宽 40，左右补边后为 60，仍会扩到 80；车牌本体只占输入宽度的一半。缩小照片中框内右侧大块背景与此行为吻合。现有流式双线性采样只支持缩小，不能直接删除最小尺寸限制，否则不能保证完整输出 1600 个像素。要改善这里，需要实现原 ROI 的上采样并验证采样时序、缓存和 PDS 资源。
- **省份错字属于识别准确率问题。** 当前修复只处理结果存储和显示；不能把稳定的“皖”改回“甘”。缩放后同一车牌能显示不同省份，不符合单一字库映射错误的表现，但仅凭实拍图还不能区分裁剪背景、源图细节损失和模型本身的影响。需要对照实际送入 LPRNet 的 80×20 像素及原始字符输出。
- **无框需单独检查检测阶段。** 当前置信度门槛为 `0x60`，该值未做数据集标定；降低门槛可能增加候选和误检，不能从照片判断未出现的框究竟是低分过滤、满槽、NMS 还是网络未检出。本轮不同时更改门槛，避免混淆对比结果。
- **缩放过程会破坏文字确认。** 坐标匹配范围为每轴 24 像素，字符串要求两次完全一致，旧确认结果保留 6 个视频帧。缩放改变坐标或识别字符串时可能触发重新确认。仅延长保留时间会延长旧错误文字的显示，不会提高识别准确率，因此本次保留这些参数。

本轮多目标回归使用合成识别结果，并非运行 YOLO/LPRNet 权重得到的图片准确率测试。远程 Linux 无 PDS，本轮仍需 Windows 从 Compile 开始重新构建、检查时序并上板；没有生成新 bit 文件。同步请在本地原 Git 工作目录执行 `git pull`，旧 ZIP 不包含本节新增修改。
