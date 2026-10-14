# 盘古 200Pro+ YOLO 工程适配

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
