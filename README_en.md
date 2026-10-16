# Panache

This fork turns text and mathematics into handwritten images using custom fonts and layout settings.
Run the application locally, self-host it, or download a [desktop build](https://github.com/SXP-Simon/Panache/releases).

On `custom-base`, the React workspace combines the document editor, preview, and handwriting settings with a responsive layout.
The handwriting renderer supports nested fractions, radicals, scripts, and fallback glyphs:

![Handwritten mathematics preview](docs/assets/images/math_formula_preview.png)

📖 **[Documentation: user guide, self-hosting, and development](https://heliannuits.me/Panache/en/)**

## Fork branches and upstream synchronization

- **`custom-base`** is Simon's default development branch for the React/Python/Electron application and personal mathematics, formatting, and performance improvements.
- **`main`** mirrors [`upstream/main`](https://github.com/14790897/handwriting-web), including its release history. Personal features belong on `custom-base`.
- **`flutter`** started from the personal baseline and received [HakimYu's Flutter/Rust migration](https://github.com/HakimYu/handwriting/tree/refactor/flutter-rust) through `cherry-pick -x`. It is maintained separately; do not merge its removal of the legacy application back into `custom-base`. Mathematics improvements need a separate port.
- Useful upstream fixes are reviewed and selectively cherry-picked into `custom-base`; release-only version and changelog commits normally remain on `main`. See [AGENTS.md](./AGENTS.md#项目与分支) for the branch workflow.

## Current architecture and technology stack

| Layer | Technology and responsibility |
|---|---|
| Frontend | React, TypeScript, Vite; project styles, Tailwind CSS, Motion, Lucide |
| State and requests | Zustand for client business state; TanStack Query for server data, Fetch + Valibot for transport and validation |
| Local persistence | Web: localStorage + IndexedDB; desktop: restricted Electron IPC and application data files |
| Backend and rendering | FastAPI, SQLite task queue, handrightbeta, Pillow, math layout modules, PyMuPDF |
| Desktop and validation | Electron + PyInstaller; Playwright, Node tests, pytest; Oxlint / Oxfmt, Ruff / Pyright |

UI, business state, cross-domain actions, API contracts, and persistence have separate responsibilities.
See [Architecture and Technology Stack](docs/en/architecture.md) for ownership, generation flow, and
storage boundaries, and [Local Development](docs/en/development.md) for setup and validation.
The toolchain requires Node.js 24+, pnpm 10.13.1, Python 3.12+, and uv; manifests and lockfiles specify
the exact dependency versions.

Lefthook and CI select checks from actual Git paths: the staged changes before a commit and all
outgoing refs before a push. Missing comparison history falls back to full validation. Commit scopes
use `fe/...` for `frontend/...` and `be/...` for `backend/...`; they do not control which checks run.
See [Local Development](docs/en/development.md#selective-checks-and-ci) for the manual full checks and CI gate.

## Features

### Custom Fonts

You can upload your own fonts to generate a unique handwriting style that suits your needs.

### Background images

Upload a background image or set the paper dimensions. Generated paper can include ruled lines;
the background detector can estimate margins and line spacing from an uploaded image.

### Tunable parameters

You have full control over various parameters such as margins (top, bottom, left, right) and random perturbation between characters. This allows you to fine-tune the look of your handwritten text.

### Text layout markers

Use standalone markers in the text input to control layout:

- `---` (three or more dashes) forces the following content onto a new page.
- Prefix a line with `>>>` to right-align it, which is useful for signatures and dates.

For example:

```text
First page
---
Second page
>>>Signature
>>>July 27, 2026
```

The markers control layout and are not printed in the generated handwriting.

### Extract text from various file types

Import `.docx`, `.pdf`, `.txt`, or `.rtf` documents to fill the editor. Convert older `.doc` files
to `.docx` before importing them.

### Preview function

Preview the first page by default, or enable a full-document preview. After changing text or settings,
generate a new preview to see the result.

### Complete image generation

Export all pages as a ZIP of PNG images or as one PDF.

## How to build it yourself

Run `docker compose up -d --build` from the `custom-base` checkout, then open
<http://127.0.0.1:2345>. Compose builds the current source; place additional fonts in `ttf_files/`.
See [Docker deployment](docs/en/self-hosting/docker.md) for configuration and optional image updates.

For local development, install Node.js 24+, pnpm, Python 3.12+, and uv, then follow
[Local Development](docs/en/development.md). Desktop build instructions are in
[Desktop App](docs/en/desktop.md).

## Credits and licensing

Based on [14790897/handwriting-web](https://github.com/14790897/handwriting-web).
See [LICENSE](LICENSE) for the code license; bundled fonts carry their own licenses.
