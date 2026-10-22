# 内部数学备用字体

`PanacheMathScript.ttf` 将 KaTeX Caligraphic 的 26 个大写字形映射到 Unicode 数学花体区，只用于缺字回退，不作为用户可选手写字体。

原始文件为已锁定的前端 KaTeX 依赖中的 `dist/fonts/KaTeX_Caligraphic-Regular.ttf`。字体内部声明 SIL OFL 1.1；本目录保留完整 [OFL 与版权](OFL.txt)，派生字体使用新的家族名称，不覆盖原字体。重建入口：

```sh
uv run --extra dev python scripts/build-math-script-font.py --source frontend/node_modules/katex/dist/fonts/KaTeX_Caligraphic-Regular.ttf --output backend/font_assets/math/PanacheMathScript.ttf
```

字体资源目录整体随桌面后端打包。内部字库不替换所选字体已有的中文字形或普通英文字母。
