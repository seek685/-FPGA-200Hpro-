# Third-Party Notices

本文件只说明本仓库中已知的第三方内容来源，不向这些第三方内容授予新的许可。使用者应同时遵守各自的原始许可、版权声明、工具许可和硬件厂商条款。

## 固定 ROI 分类实验分支（2026-10-15）

- 小 CNN 结构和 Python 模型定义参考 [SweiryDev/MicroCNN-TangNano20k](https://github.com/SweiryDev/MicroCNN-TangNano20k)，固定提交 `2711cddd568ac4e061b114f3fa2809a63b94ed9b`，MIT，Copyright (c) 2026 SweiryDev。许可证保存在 `third_party/microcnn/LICENSE`。本分支重新实现了紫光可移植的顺序 MAC RTL，没有移植 Gowin 原语，也没有使用原项目的 BloodMNIST 权重。
- 训练和测试图片子集来自 Mihai Oltean 的 [Fruits-360 100×100](https://github.com/fruits-360/fruits-360-100x100)，固定提交 `cd2921eed66223cc1e5dc6a6cc089b8e9cd4ab21`，CC BY-SA 4.0，Copyright (c) 2017-, Mihai Oltean。许可证摘要保存在 `models/roi_fruit/DATASET_LICENSE.txt`，完整条款见 <https://creativecommons.org/licenses/by-sa/4.0/>。
- 修改包括选择苹果/香蕉/橙子及其他水果子集、缩小到 28×28、训练时旋转/缩放/亮度增强、增加程序生成的背景负样本，以及训练和量化新模型。原始图片不打包；`tests/fixtures/roi_cnn/*.png` 与 `test_images_rgb.mem` 是所选测试图的缩小版本，来源逐项记录在 `models/roi_fruit/model_report.json`。
- 本分支新增的模型参数（`models/roi_fruit` 中的 NPZ、`rtl_pds/data_process/mem_data/roi_cnn` 中的权重）及上述派生测试图片以 CC BY-SA 4.0 分发。新增 RTL 和脚本遵循本仓库 MIT 许可；第三方许可范围与原有厂商 IP 范围分别保留。

## 小眼睛半导体官方 Demo

以下内容来自小眼睛半导体官方 demo，经过本项目的整合、接口适配或工程迁移：

- `rtl_pds/ddr`
- `rtl_pds/ddr/ipcore/ddr3_test`
- `rtl_pds/drive_hdmi`

涉及的功能包括 DDR3 控制器及 PHY、DDR 读写控制、HDMI 收发、TMDS 编码/串化、MS7200/MS7210 配置和 I2C 驱动。请保留源文件中的原始版权和许可信息，并向小眼睛半导体确认这些文件、IP 和生成文件是否允许公开再分发或商用。

## PDS/FPGA 厂商 IP 和工具生成文件

`prj_pds/ipcore` 及 DDR3 相关自动生成文件可能受紫光同创/PDS 工具及 IP 许可约束。MIT License 仅适用于本项目拥有版权且有权授权的自研部分，不覆盖这些厂商 IP、原语、工具生成文件或受限模型。


## 本项目自研部分

除上述第三方内容以及其他明确标注为第三方的文件外，本项目作者拥有版权并选择以仓库根目录 `LICENSE` 中的 MIT License 授权自研代码、脚本和文档。文件中的第三方版权声明优先于本项目的通用说明。
