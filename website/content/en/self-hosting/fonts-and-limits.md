# Fonts and server resources

The standalone service reads fonts from `font_assets/` beside its executable, or from `assets/font_assets/` during development. Override the font and writable data directories with `HANDWRITING_FONT_DIR` and `HANDWRITING_DATA_DIR`.

Image decoding and document imports consume memory. The service budgets input size, pixels and DOCX decompression. Set container resource and concurrency limits for public deployments. Check the [font licence records](https://github.com/SXP-Simon/Panache/blob/main/assets/licenses/FONT-LICENSES.md) before redistributing fonts.
