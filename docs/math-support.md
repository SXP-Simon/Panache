# 数学转写与验证

Flutter 使用 `flutter_math_fork` 的语法树把受支持的 LaTeX 转为手写结构文本，
Rust 引擎负责分式、根式、上下标、重音、二维手写表格和纸张布局。界面的公式预览与最终手写图片
经过不同的渲染路径，因此转写测试和真实引擎测试需要同时运行。

## 语义边界

- 转写保留分组、积分与求和上下限、矩阵行列、向量重音和离子电荷。
- 直立元素符号与标签不额外添加括号；表达式的必要分组仍保留。
- Unicode 没有对应字形的上下标使用显式 `^(...)` / `_(...)` 结构交给引擎排版。
- 手写引擎优先使用所选字体；缺字时按需使用随包备用字体，界面字体不覆盖纸张字体。
- 黑板粗体大写使用可显示的 Unicode 字形，必要时由内部 AMS 子集补字；无对应字形的小写与数字样式保留源文。
- 公式内按实际墨迹宽度排字，上下标参考实际基底定位；复合结构作为整体换行与扰动，正文汉字仍保留原书写节奏。
- 未识别的命令、不能安全转换的结构和超出解析预算的公式保留原文。
  常用工程单位与有限 CircuiTikZ 电路有专门处理；`mhchem`、任意 `siunitx` 选项和完整 TikZ/TeX 扩展仍不在支持范围。
- 普通矩阵和多行环境转为文本化结构，不保证复现 TeX 的所有对齐、字号和装饰效果。
- 带明确分隔线的独立 `array`、分布律转为可编辑表格结构，生成时按真实字形测量共同列宽及行基线，绘制二维手写单元格与分隔线。省略花括号的分数和外层 `boxed` 一并转写；过宽表格整体缩小、换页时不拆散单元格。表格结构标记与矩阵本来的方括号区分，生成时不绘制结构标记。
- 重复分隔线若被第三方解析器合并则保留整段源码，避免改变增广列等含义。Markdown 清洗本身不执行 LaTeX 转换。

## 可重复验证

课程例子在 `app/test/support/latex_curriculum_cases.dart` 集中维护；字符串期望由语义
编写，不从转换器当前输出自动生成。覆盖数学、物理、化学、材料、控制、信号和信息论等课程。

```bash
cd app
flutter test test/latex_symbols_test.dart test/latex_curriculum_test.dart \
  test/latex_compatibility_test.dart test/math_segments_test.dart
cd ..
cargo test --locked -p handwriting-core
cargo build --locked -p handwriting-server
cd app
# 使用本机服务可执行文件的绝对路径；Windows 文件名有 .exe 后缀。
flutter test test/curriculum_live_engine_test.dart test/math_live_engine_test.dart \
  --dart-define=DESKTOP_BACKEND_EXECUTABLE=/absolute/path/handwriting-server
```

真实课程测试对同一批 LaTeX 执行转写、服务任务、PNG 解码，以及 PDF/ZIP 导出，
并覆盖不同字号、窄纸和方格。Rust 测试另核对墨迹边界、符号缺字回退、脚标与基底
共同换行、PNG/ZIP 像素一致性和 PDF 页面尺寸。

需要人工检查实际字形、分组与可读性时，可在仓库根目录生成固定参数的图集：

```bash
cargo run --locked -p handwriting-core --example curriculum_gallery -- \
  assets/font_assets target/curriculum-gallery
# 使用移动作业本默认值检查中文与公式的混排。
cargo run --locked -p handwriting-core --example notebook_preview -- \
  target/notebook-preview
```

输出包含 PNG、PDF、ZIP 和逐页几何指标。自动检查通过不能代替对数学含义和最终
视觉效果的检查，尤其是新增符号、长脚标、多层分式与极窄纸张。

Markdown 清洗默认将表格转换为 LaTeX 方格表；表格菜单仍可选择原有文本模式。随后点击 LaTeX 转换并生成预览。手写表格包含完整外框与各行列格线，格线统一粗细，单元格内容按墨迹居中。

## 常见 CircuiTikZ 电路

把完整的 `\begin{circuitikz} ... \end{circuitikz}` 环境直接粘贴到正文，点击生成预览。
Markdown 清洗和 LaTeX 转换保留整段电路源码，由 Rust 引擎直接绘制；“文本与公式预览”用于查看文字和数学公式，不代替生成电路预览。
例如串联 RLC 电路：

```tex
\begin{circuitikz}[american]
\draw (0,0) to[V,l=$U_s$] (0,3)
  to[R,l=$R$] (3,3) to[L,l=$L$] (6,3)
  to[C,l=$C$] (6,0) -- (0,0);
\end{circuitikz}
```

支持常见电阻、电容、电感、电压源、电流源、正弦源、电池、二极管、LED、开关与短路、开路支路。
线路可使用普通直线、`|-` / `-|` 正交折线、`cycle` 闭合路径，绝对坐标、`+` / `++` 相对坐标及 `\coordinate` 命名坐标。
可标注元件名称、电流、电压，添加接点、开口端子与接地符号。符号和连线按电路共同布局，标签使用所选手写字体。
方向标注可用显式 `i>^=$i$` 等形式；省略方向的 `i/v` 需在环境里明确 `[RPvoltages]`（或 `[voltage dir=RP]），避免不同隐含约定改变电路含义。

这不是完整 TeX 编译器：运放、任意 TikZ 图形、宏定义、自定义样式或未知结构选项会使整段电路保留为源码，避免少画一个元件后改变电路含义。
过大、未闭合和解析预算以外的电路也保留原文。复杂图形可继续用插图功能加入已有图片。

完整源码保留测试位于 `app/test/circuit_source_test.dart`，引擎的解析、几何和实际绘图用例位于 `crates/handwriting-core/`；新元件需同时验证源文边界、拓扑和最终墨迹。
