# Getting Started

## The whole flow

1. **Enter text** — type in "Text & formulas", or import a document. Use "Convert LaTeX" before rendering formulas.
2. **Pick a font** — choose a server font or upload one in "Handwriting & paper". Interface typography does not affect the paper font.
3. **Set the paper** — either give a width and height (the app generates ruled paper), or upload a background image.
4. **Tune parameters** — the defaults are fine to start with; see [Parameters](parameters.md) to fine-tune.
5. **Click "Generate preview"** — inspect the result in "Preview"; enable "Preview all pages" to check multiple pages.
6. **Export** — use "ZIP" for full-page PNGs or "PDF" for a merged document.

!!! tip "Preview before you export"
    Preview renders only the first page by default. Enable "Preview all pages" to check the full
    document. ZIP and PDF exports always process every page.

## The interface is three columns

The wide-screen workspace has three areas, which rearrange on narrower screens:

- **Text & formulas** — text, document import, LaTeX / Markdown conversion, letter layout, and images.
- **Preview** — rendered pages, navigation, zoom, and export.
- **Handwriting & paper** — fonts, dimensions, margins, natural variation, cross-out effects, and presets.

Detailed settings are grouped into collapsible sections.

## Interface appearance

Open "Appearance & settings" to select a theme preset, use the color picker, or enter a six-digit HEX color. You can also restore the default green. The choice is saved on this device and survives reloads. It changes only the interface, leaving paper fonts, ink colors, and exported images unchanged.

Phones omit the top brand header. The compact workspace action row provides the settings entry, where language, light/dark mode, help, and the source link remain available. Desktop keeps its top navigation.

## Entering text

!!! warning "`.doc` is not supported"
    The supported upload formats are `.docx`, `.pdf`, `.txt` and `.rtf`. The old `.doc`
    format appears in the file picker, but the server rejects it with
    "doc文件暂不支持" (`.doc` files are not supported yet). Re-save as `.docx` first.

- Text, settings, and uploaded assets are saved on this device. Check the save status; clearing site data or storage failures can affect recovery.
- Uploading a document only **fills the text box** — you can keep editing afterwards.
- Markdown cleanup preserves formula source; use the LaTeX conversion button to transcribe it. Arrays, probability tables, and augmented matrices with explicit separator rules remain editable structured text and render as two-dimensional cells using the selected handwriting font and ink. Wide tables scale as a whole and cells stay together across page breaks. Unsupported syntax preserves the source.
- This fork has no fixed 10-page truncation. Long documents remain subject to hardware and [server limits](../self-hosting/fonts-and-limits.md).

## Choosing a font

Two options, pick one:

- **Use a server font** — select it from the dropdown. These are the fonts placed in `ttf_files/` at deploy time.
- **Upload your own** — use "Upload font" for `.ttf`, `.otf`, or `.ttc`. The upload is selected automatically; selecting a server font switches rendering to that font.

## Setting the paper

Width/height and background image are **mutually exclusive**:

- Width + height given → the backend generates ruled paper (ruled or plain depends on "Add underline").
- Background image uploaded → your image is used, and width/height are disabled.

After uploading a background image you are asked whether to auto-detect margins. Answering yes
analyses the lines in the image and fills in all four margins and the line spacing — very handy
with your own ruled paper.

## Remembering your parameters

The settings panel manages parameter snapshots stored on this device:

- **Save Settings** — store the current parameters.
- **Load Settings** — bring them back.
- **Reset defaults** — restore the defaults.

Built-in choices include "Small ruled · Yunyan", "Natural handwriting", and "Neat handwriting".
Remove the background before applying paper presets; the Yunyan preset uses its font when installed
and otherwise keeps the current selection.
See [Architecture](../architecture.md) for draft and preset storage boundaries.

## Queueing and waiting

The backend only renders a limited number of jobs at a time. When it is busy you will see:

- Task state in the workspace and progress in the preview area.
- A retry countdown and temporarily disabled submit buttons when the queue is full.

Progress is pushed over a WebSocket; if that connection cannot be established the client
falls back to polling, and the interface looks the same either way.

Markdown cleanup defaults to LaTeX grid tables; the table menu retains the other text modes. Click LaTeX conversion, then generate the preview. Handwriting tables include an outer border and every row/column boundary, with uniform stroke widths and visually centered contents.


## Checking for updates

Open **Appearance and settings → App updates** to check manually or enable startup checks. Desktop clients select the official package for their system, CPU architecture, and installation type. Downloads show progress, can be cancelled, and must pass verification before opening. Windows installers and macOS DMGs use the system installation flow; portable applications are replaced manually after closing the old version.

Web/PWA checks the current site's deployment and saves the draft before refreshing. Finish or cancel any generation task first. A newer desktop release on GitHub does not mean that a self-hosted website has already been upgraded. Missing packages, unsupported architectures, and network failures have separate feedback and retry or release-page actions.
