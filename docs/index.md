# Panache

Simon 自用 fork 的 `custom-base` 分支：React / TypeScript 工作台、Python / FastAPI
渲染服务与 Electron 桌面版。输入文字、转换 LaTeX、调整笔迹，导出 PNG 打包或 PDF。

本站是[项目文档](https://heliannuits.me/Panache/)，不提供生成 API。
使用应用请[本地启动](development.md)、[自行部署](self-hosting/docker.md)或使用[桌面版](desktop.md)。
`main` 同步上游，Flutter / Rust 迁移版由独立的 `flutter` 分支维护。

## 能做什么

<div class="grid cards" markdown>

- **自定义字体**

    上传自己的字体，或者从服务器已安装的字体里选一个；界面字体与纸张手写字体独立。

- **数学与文本转换**

    LaTeX 转写、Markdown 清理、分式、根式与上下标排版。模块职责见[架构与技术栈](architecture.md)。

- **背景图片**

    上传自己的背景图；不带背景时，只要给出宽高就会自动生成一张带横线的稿纸。

- **参数可调**

    字号、行距、四边边距、下划线，加上字距/字号/行距的浮动、笔画的横向与纵向偏移、
    旋转角度、墨迹深度、涂改痕迹 —— 都可以逐个调。

- **排版标记**

    正文里用 `---` 强制分页，行首的 `>>>` 把这一行靠右（署名、日期用得上）。

- **中文书信排版**

    一键把文字整理成紧凑的中文书信：段落空两格、去掉段间空行、落款自动靠右。

- **导入文档**

    直接上传 `.docx` / `.pdf` / `.txt` / `.rtf`，自动提取正文，不用手打。

- **预览与导出**

    先预览，满意后再导出整页 PNG（打包成 zip）或合并成 PDF。

- **内置预设**

    选择内置笔迹预设，或保存并载入自己的设置。

</div>

## 从这里开始

- 第一次用 → [快速上手](guide/getting-started.md)
- 想调出特定效果 → [参数详解](guide/parameters.md)
- 要用分页和右对齐 → [排版标记](guide/layout-markers.md)
- 想自己搭一个 → [Docker 部署](self-hosting/docker.md)
- 想改代码 → [本地开发](development.md)

## 来源

本项目基于 [14790897/handwriting-web](https://github.com/14790897/handwriting-web)。
代码授权见 [LICENSE](https://github.com/SXP-Simon/Panache/blob/custom-base/LICENSE)，字体使用各自授权。
