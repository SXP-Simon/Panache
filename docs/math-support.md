# 数学转写与验证

Flutter 使用 `flutter_math_fork` 的语法树把受支持的 LaTeX 转为手写结构文本，
Rust 引擎负责分式、根式、上下标、重音和纸张布局。界面的公式预览与最终手写图片
经过不同的渲染路径，因此转写测试和真实引擎测试需要同时运行。

## 语义边界

- 转写保留分组、积分与求和上下限、矩阵行列、向量重音和离子电荷。
- 直立元素符号与标签不额外添加括号；表达式的必要分组仍保留。
- Unicode 没有对应字形的上下标使用显式 `^(...)` / `_(...)` 结构交给引擎排版。
- 手写引擎优先使用所选字体；缺字时按需使用随包备用字体，界面字体不覆盖纸张字体。
- 黑板粗体大写使用可显示的 Unicode 字形，必要时由内部 AMS 子集补字；无对应字形的小写与数字样式保留源文。
- 公式内按实际墨迹宽度排字，上下标参考实际基底定位；复合结构作为整体换行与扰动，正文汉字仍保留原书写节奏。
- 未识别的命令、不能安全转换的结构和超出解析预算的公式保留原文。
  `mhchem`、`siunitx`、TikZ 或电路绘图不是完整 TeX 扩展支持；保留源文不等于已生成相应图形。
- 矩阵和多行环境转为文本化结构，不保证复现 TeX 的所有对齐、字号和装饰效果。
- `array` 分布律的单条横竖分隔线转为可见标记，省略花括号的分数和外层 `boxed` 一并转写。重复分隔线若被第三方解析器合并则保留整段源码，避免改变增广列等含义。Markdown 清洗本身不执行 LaTeX 转换。

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
