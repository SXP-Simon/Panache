# 内置字体许可记录

本记录于 2026-10-12 核对。九款字体均保留；项目根目录 MIT License 仅针对项目软件，不能替代字体作者的授权。下列 OFL 正文来自字体项目或 Google Fonts 官方仓库，随字体一起分发，不修改原字体文件。

| 字体 | TTF 内的许可或版权依据 | 随附许可及来源 |
| --- | --- | --- |
| 霞鹜文楷.ttf | LXGW / The Klee Project Authors；SIL OFL 1.1 | [lxgw-wenkai-OFL.txt](lxgw-wenkai-OFL.txt)；[来源](https://github.com/lxgw/LxgwWenKai/blob/main/OFL.txt) |
| 霞鹜漫黑.ttf | The LXGW Marker Gothic Project Authors；SIL OFL 1.1 | [lxgw-marker-gothic-OFL.txt](lxgw-marker-gothic-OFL.txt)；[来源](https://github.com/lxgw/LxgwMarkerGothic/blob/main/OFL.txt) |
| 悠哉手写体.ttf | LXGW / Y.OzVox；SIL OFL 1.1 | [yozai-OFL.txt](yozai-OFL.txt)；[来源](https://github.com/lxgw/yozai-font/blob/master/OFL.txt) |
| 志莽行书.ttf | The ZhiMangXing Project Authors；SIL OFL 1.1 | [zhimangxing-OFL.txt](zhimangxing-OFL.txt)；[来源](https://github.com/google/fonts/blob/main/ofl/zhimangxing/OFL.txt) |

OFL 允许将字体与软件一起分发和销售，但不能单独销售字体。分发时保留各字体的版权声明和完整许可；修改字体时还需遵守 Reserved Font Name 等条件。生成的文档不因使用 OFL 字体而必须采用 OFL。

## 待补充的授权依据

以下字体目前仅能从文件确认有限的版权信息，仓库尚无证明商用或随软件再分发权限的完整许可或授权书。不能以“上游仓库已包含”“免费字体”或项目采用 MIT 作为授权依据，也不能仅凭缺少材料断定作者不允许使用。

| 字体 | TTF 中发现的信息 | 发布前需确认 |
| --- | --- | --- |
| 神韵英子楷书.ttf | Charm Font Design Co., Ltd. / 神韵字库；许可字段明确商业使用需要授权 | 商用及字体嵌入、随软件再分发授权 |
| 青叶手写体.ttf | Shenzhen YiPin Information Technology Co., Ltd | 使用、商用及字体再分发许可 |
| 云烟体.ttf | 文道字库 / 深圳文道信息科技有限公司 | 使用、商用及字体再分发许可 |
| 华阳手写体.ttf | 未发现可据以确认授权的标准版权或许可字段 | 作者、来源及完整使用与再分发许可 |
| 李国夫手写体.ttf | 版权字段为 TAKEZOU | 作者、来源及完整使用与再分发许可 |

如另有授权书，应核对授权对象、用途、平台、期限及是否允许向用户提供字体文件，再将可公开的许可材料加入本目录；私有授权书应单独留档。本记录不授予任何新增权利。

## 许可文件维护

内部数学备用字体 `HandwritingMathSymbols.ttf` 来自 `flutter_math_fork` 随附的 KaTeX AMS 字体，保留其 [MIT 许可](katex-fonts-MIT.txt)。它经过大写黑板粗体的 Unicode 重映射与子集化，名称已改为 Handwriting Math Symbols；仅用于缺字回退，不作为用户可选手写字体。可用 `scripts/build-math-symbol-font.py` 从原始 KaTeX AMS 字体重建。

`project-MIT.txt` 是根目录 `LICENSE` 的完整副本；`handright-BSD-3-Clause.txt` 和 `handright-NOTICE.txt` 是 `crates/handwriting-core/` 对应文件的完整副本，供 Flutter 各平台作为资产读取。更新原文件时同步更新副本；测试检查二者一致。
