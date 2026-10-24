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
- Prepare text cleans Markdown before transcribing formulas, preserves code contents, and offers Undo cleanup to restore the original. Arrays, probability tables, and augmented matrices with explicit separator rules remain editable structured text and render as two-dimensional cells using the selected handwriting font and ink. Wide tables scale as a whole and cells stay together across page breaks. Unsupported syntax preserves the source.
- This fork has no fixed 10-page truncation. Long documents remain subject to hardware and [server limits](../self-hosting/fonts-and-limits.md).

## Engineering coursework and formulas

Click Prepare text, then generate a preview. Matrices, determinants and piecewise functions use two-dimensional layouts with scalable delimiters; conditions are left-aligned. Table cells use the same font fallback and fraction layout as ordinary formulas.

Common inputs include `\mathcal{L}`, `\oiint`, `\SI{4.7}{\kilo\ohm}`, `\si{\metre\per\second\squared}` and `\num{1.2e-3}`. Unsupported options, custom macros and expressions that cannot be parsed reliably remain as source text. Check the preview before exporting.

Markdown cleanup removes code fences and backticks while preserving their contents, including pointers, underscores, comparisons and indentation. This is a text conversion: once those boundaries are removed, a subsequent cleanup or formula conversion cannot recover the original code context.

Paste a common CircuiTikZ circuit directly into the editor and generate a preview. Cleanup and formula conversion preserve its source; rendering draws the connections and handwritten labels. For example:

```tex
\begin{circuitikz}
\draw (0,0) to[V,l=$U_s$] (0,3)
  to[R,l=$R$] (4,3) to[C,l=$C$] (4,0)
  -- (0,0) node[ground]{};
\end{circuitikz}
```

Supported components include resistors, capacitors, inductors, voltage/current/sine sources, batteries, diodes, LEDs, switches, shorts and open branches, with junctions, terminals, grounds and labels. Use absolute, `+` / `++` relative or `\coordinate` named coordinates, `--` / `|-` / `-|` wires and `cycle`. `[american]` selects zigzag resistors. Use explicit annotation directions such as `i>^=$i$`; implicit `i/v` require `[RPvoltages]` so direction conventions remain unambiguous.

Circuits scale and paginate as one structure; connections never jitter separately, and labels use your selected font. Panache does not run complete TeX/TikZ: op-amps, transistors, macros, custom styles or unsupported commands preserve the entire circuit as source. Export complex diagrams as images and use **Insert image**. For legible layout checks, use LXGW WenKai and the **Neat handwriting** preset.

## Common course macros

Formula conversion accepts these common forms without a `\usepackage` preamble:

- `amsmath`: fractions, matrices, cases and multi-line `alignat` derivations.
- `siunitx`: `\SI{4.7}{\kilo\ohm}`, `\qty{9.81}{\metre\per\second\squared}` and `\unit{\volt}`.
- `mhchem`: `\ce{(NH4)2SO4 -> 2NH4+ + SO4^2-}`, reaction arrows, states and hydrates, with separate atom counts and ionic charges.
- `physics`: `\dv{x}{t}`, `\dv[2]{x}{t}`, `\pdv{f}{x}`, `\abs{x}` and `\norm{\mathbf v}`.

These are compatible command subsets, not a full TeX package runtime. Custom macros, complex chemical structures and unsupported options remain as source; inspect the preview before exporting.

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

Markdown cleanup defaults to LaTeX grid tables; the table menu retains the other text modes. Click Prepare text to clean markup and transcribe formulas, then generate the preview. Handwriting tables include an outer border and every row/column boundary, with uniform stroke widths and visually centered contents.


## Checking for updates

With automatic checks enabled, a newer version opens an update dialog with its version and key changes. Choose **Update now** or **Later**. Each version is automatically shown once per session, after any generation task finishes. Open **Appearance and settings → App updates** to check manually and show the dialog again. Desktop clients select the official package for their system, CPU architecture, and installation type. Downloads show progress, can be cancelled, and must pass verification before opening. Windows installers and macOS DMGs use the system installation flow; portable applications are replaced manually after closing the old version.

Web/PWA checks the current site's deployment and saves the draft before refreshing. Finish or cancel any generation task first. A newer desktop release on GitHub does not mean that a self-hosted website has already been upgraded. Missing packages, unsupported architectures, and network failures have separate feedback and retry or release-page actions.
