# Panache

The `custom-base` branch of Simon's fork combines a React / TypeScript workspace, a Python /
FastAPI rendering service, and an Electron desktop app. Enter text, convert LaTeX, tune the
handwriting, then export a zip of PNGs or a PDF.

This [documentation site](https://heliannuits.me/Panache/) does not provide a generation
API. To use the app, [run it locally](development.md), [self-host](self-hosting/docker.md), or use the
[desktop app](desktop.md). `main` mirrors upstream; the separate `flutter` branch maintains the
Flutter / Rust migration.

## What it does

<div class="grid cards" markdown>

- **Custom fonts**

    Upload your own font, or select a server font. Interface typography is independent of the handwriting font.

- **Math and text conversion**

    Convert LaTeX, clean Markdown, and lay out fractions, radicals, and scripts.
    See [Architecture and Technology Stack](architecture.md) for module responsibilities.

- **Background image**

    Upload your own background. Without one, just give a width and height and the app
    generates ruled paper for you.

- **Tunable parameters**

    Font size, line spacing, all four margins, underlines — plus jitter for character
    spacing, size, line spacing, stroke offset, rotation, ink depth and strikethroughs.

- **Layout markers**

    `---` on its own line forces a page break; a leading `>>>` right-aligns a line
    (handy for signatures and dates).

- **Chinese letter layout**

    One click tidies the text into a compact Chinese letter: two-space paragraph indent,
    no blank lines between paragraphs, signature and date pushed to the right.

- **Import documents**

    Upload `.docx` / `.pdf` / `.txt` / `.rtf` and have the text extracted for you.

- **Preview and export**

    Preview the result, then export every page as PNGs (zipped) or as a single PDF.

- **Built-in preset**

    Apply built-in handwriting presets, or save and load your own settings.

</div>

## Start here

- First time? → [Getting Started](guide/getting-started.md)
- Chasing a particular look → [Parameters](guide/parameters.md)
- Need page breaks and right alignment → [Layout Markers](guide/layout-markers.md)
- Want to run your own instance → [Docker Deployment](self-hosting/docker.md)
- Want to change the code → [Local Development](development.md)

## Credits

This project is based on [14790897/handwriting-web](https://github.com/14790897/handwriting-web).
See [LICENSE](https://github.com/SXP-Simon/Panache/blob/custom-base/LICENSE) for the code license.
Fonts carry their own licenses.
