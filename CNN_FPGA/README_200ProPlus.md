# 盘古 200Pro+ YOLO 工程适配

## 2026-10-15：原始工程 + 固定区域水果分类实验分支

分支：`feature/roi-fruit-cnn`。基线是本仓库最初的 200Hpro 板级适配提交 `4706536`，保留其 YOLO/LPRNet、车牌权重、HDMI/DDR 和引脚。这个分支没有包含 `main` 后续的车牌识别链路修改；它是在原始适配工程上独立增加功能，便于单独上板比较。

**当前完成：RTL 合并、训练/定点权重导出、软件整数对照及四组 Verilator 仿真。尚未运行本分支的 PDS Compile、综合、布局布线、时序验证或板上测试，没有生成新 `.sbit`。** 下文较早的 Compile 记录不适用于这个新分支。

### 第一版功能

- HDMI 输入仍要求 **1280×720、60 Hz**。新功能没有增加 1080p 支持。
- 屏幕中心显示 **224×224** 的固定绿框，左上角坐标 `(528,248)`。将一个物体放入框内，显示 `APPLE`（苹果）、`BANANA`（香蕉）、`ORANGE`（橙子）或 `OTHER`（其他/背景）；等待结果时显示 `WAIT`。
- 这是固定区域内的单物体分类。它没有在全画面搜索水果，也不能同时给多个水果分别画框。
- 原车牌 YOLO/LPRNet 分支继续运行。新分类输入取自原始 RGB，位于画框、写字之前，避免把 OSD 图案送入模型。
- 新 CNN 的采样、卷积、池化、全连接和类别选择都在 FPGA 中完成；电脑只在开发时训练和验证模型，演示时可直接由 HDMI 摄像头输入。
- `hdmi_loop.sv` 参数 `ROI_CNN_ENABLE=1` 默认开启。改为 `0` 并重新编译可旁路新增功能。没有增加顶层引脚。

### 下载与上板

建议在一个新目录取得此分支，避免与当前车牌修改混用：

```powershell
git clone --branch feature/roi-fruit-cnn --single-branch https://github.com/seek685/-FPGA-200Hpro-.git FPGA_200Hpro_ROI
```

1. 在 PDS 打开 `FPGA_200Hpro_ROI/CNN_FPGA/prj_pds/hdmi_loop.pds`，确认器件 `PG2L200H-6FBB676`、顶层 `hdmi_loop`。源文件列表已加入三个新 RTL 和模型头文件，旧 Compile 完成状态已清除。工程沿用原综合器安装路径；若本机 PDS 安装目录不同，在工具设置中选择本机的 Synplify。
2. 依次运行 **Compile → Synthesize → Device Map → Place & Route → Report Timing → Generate Bitstream**。先确认 Compile 没有错误且八个 `roi_cnn` 权重/偏置 ROM 均成功加载，再继续。检查新增存储的实际 DRM 映射及像素时钟域时序。
3. 下载本轮新生成、时间戳正确的 `prj_pds/generate_bitstream/hdmi_loop.sbit`。
4. 首次使用电脑 HDMI，活动信号设为 1280×720、60 Hz。打开 `CNN_FPGA/demo/roi_fruit.html`，移动到 FPGA 对应的扩展显示屏，按 Enter 或 F11 全屏。按左右键切图，W 切换空白，每张保持至少两秒。页面提供八张确定的测试输入，绿框与黄色分类文字由 FPGA 生成。
5. 电脑测试通过后接 HDMI 摄像头，先用浅色、简单背景，单个苹果/香蕉/橙子放在框内，保证对焦清楚并占据框的大部分。之后再增加复杂背景和姿态变化。已有摄像头清晰度问题不由本次增加分类功能自动解决。

反馈时记录：输入模式、显示类别、原车牌功能是否受影响；编译失败时提供第一条错误。若图像正常但分类异常，区分长期 `WAIT`、总是 `OTHER`、固定错类及来回跳类。

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
python3 CNN_FPGA/tests/run_roi_tests.py
```

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

不要打开原目录中的工程。这个副本包含原 YOLO、LPRNet、模型 ROM、DDR 帧缓存和 OSD；仅做板级接口适配。

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
2. 依次运行 Compile → Synthesize → Device Map → Place & Route → Report Timing → Generate Bitstream。Compile 已验证，重新运行也可以。检查各步骤成功并检查时序报告。
3. 下载本副本新生成的文件：

   `D:\0-contest\yolo_200h_proplus\CNN_FPGA\prj_pds\generate_bitstream\hdmi_loop.sbit`

   目前该文件尚未生成。不要选择原仓库中的 `dcmi_loop.sbit` 或其它旧码流。

4. 接线：电脑 HDMI OUT → 板卡 HDMI IN；板卡 HDMI OUT → 显示器 HDMI IN；板卡和显示器各自正常供电。
5. 将电脑给 FPGA 的那一路**活动信号**设为 1280×720、60 Hz。Windows 使用扩展显示，打开 `D:\0-contest\hdmi_test\send_image.html`，移动到 FPGA 对应显示区域并全屏显示测试图片。
6. 若下载后初始化没有正常启动，可按 KEY0（C22）复位，不要按重新配置/PROGRAM 键。下载到 SRAM 后保持供电。

如仍无信号，先使用上一级 `baseline_hdmi/hdmi_loop.sbit` 验证本板官方 HDMI 直通；该基线不含 YOLO 或 DDR。

原仓库授权信息保留在 `LICENSE` 和 `THIRD_PARTY_NOTICES.md`。原工程 `D:\0-resource\YOLO_CPU\CNN_FPGA` 与此前的 50H 实验均未改动。
