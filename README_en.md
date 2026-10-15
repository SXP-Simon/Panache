# Handwriting Web (Simon's Enhanced Edition)

This fork turns text and mathematics into handwritten images using custom fonts and layout settings.
Run the application locally, self-host it, or download a [desktop build](https://github.com/SXP-Simon/handwriting-web/releases).

On `custom-base`, the React workspace combines the document editor, preview, and handwriting settings with a responsive layout.
The screenshots below show the original upstream application:

![New interface](image-new-ui.png)

An alternative layout from the original upstream application:

![Old interface](image.png)

📖 **[Documentation: user guide, self-hosting, and development](https://heliannuits.me/handwriting-web/en/)**

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

## Function

### Custom Fonts

You can upload your own fonts to generate a unique handwriting style that suits your needs.

### Background picture

Upload your desired background image to add a personal touch to your handwriting. If you don't have a background image, don't worry! Just specify the width and height of the picture, and my website will automatically generate a background picture with horizontal lines for you.

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

My site can extract text content from various file types, allowing you to upload text easily.

### Preview function

I added a preview feature to the right side of the website. This allows you to conveniently review how your handwritten text image will look before finalizing it.

### Complete image generation

Once you're happy with the preview, you can generate a full set of images. The images will be conveniently packaged into a zip file for easy download.

## How to build it yourself

Run `docker compose up -d --build` from the `custom-base` checkout, then open port 2345.

To add fonts, font files are placed in ttf_files in the project root directory

## Conclusion

I hope you enjoy using my handwriting generator site to create your personalized handwriting pictures!

## Star History

<a href="https://www.star-history.com/?repos=SXP-Simon%2Fhandwriting-web&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=SXP-Simon/handwriting-web&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=SXP-Simon/handwriting-web&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=SXP-Simon/handwriting-web&type=date&legend=top-left" />
 </picture>
</a>
