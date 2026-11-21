# 自托管字体与资源

独立服务默认从程序旁的 `font_assets/` 读取字体；开发时使用 `assets/font_assets/`。用 `HANDWRITING_FONT_DIR` 指定服务字体目录，用 `HANDWRITING_DATA_DIR` 指定可写数据目录。

图片与文档处理会消耗内存。服务对输入大小、图片像素和 DOCX 解压设有预算；公开部署时也应限制容器资源和并发。重新分发字体前，核对每款字体的[授权记录](https://github.com/SXP-Simon/Panache/blob/main/assets/licenses/FONT-LICENSES.md)。
