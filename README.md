# Panache

[简体中文](README.zh-CN.md)

| Light | Dark |
| --- | --- |
| [![The Iris, Celadon and Coral Rose workbenches in light mode](docs/assets/images/panache-themes-light-d13d5ad454b9.webp)](docs/assets/images/panache-themes-light-d13d5ad454b9.webp) | [![The same three themes and manuscript in dark mode](docs/assets/images/panache-themes-dark-138a044cb61a.webp)](docs/assets/images/panache-themes-dark-138a044cb61a.webp) |

## Demo video

[▶ Watch the Panache demo (72 seconds, in Chinese)](https://heliannuits.me/Panache/assets/panache-promo-6757a4fb253766.mp4)

[![Play the Panache demo](website/static/panache-promo-f7d5275f09afde.webp)](https://heliannuits.me/Panache/assets/panache-promo-6757a4fb253766.mp4)

## The workbench

Panache turns text, equations, tables, and circuit diagrams into handwritten pages. Import a document, choose a handwriting font, and lay it out on a paper template or a photo of your own stationery. Export a single page as PNG or the whole document as a PDF or ZIP of images.

Import TXT, DOCX, PDF, or RTF, or paste text directly. Preview the document, then select handwriting to move it, adjust the ink, or align it with the lines on the paper.

[Download Panache](https://github.com/SXP-Simon/Panache/releases/latest) · [Write your first page](https://heliannuits.me/Panache/en/guide/getting-started/) · [Self-host the web app](https://heliannuits.me/Panache/en/self-hosting/docker/)

Offline downloads are available for Windows x64, macOS on Apple silicon, Linux x64, and Android (arm64-v8a and x86_64). The iOS client currently requires a source build.

## Local MCP for AI clients

The Windows, macOS, and Linux desktop packages include a local MCP server. Open **App settings → Connect AI client** and copy the configuration into a client that supports stdio MCP. Try asking:

> Write my notes and the process diagram on this photo of my stationery. Show me the first page, then export the whole draft as a PDF.

The client can list fonts, save Markdown in sections, revisit earlier revisions, preview individual pages, and adjust a diagram or table against the paper’s rulings. [MCP tools and configuration](crates/panache-mcp/README.md)

| Process state diagram | Resource allocation table | Handwritten poem |
| --- | --- | --- |
| [![Process state diagram](assets/examples/process-states-32471b116f51.webp)](assets/examples/process-states-32471b116f51.webp) | [![Resource allocation table](assets/examples/bankers-algorithm-34116f1eda06.webp)](assets/examples/bankers-algorithm-34116f1eda06.webp) | [![Handwritten poem](assets/examples/spring-at-qiantang-lake-6806782d66f9.webp)](assets/examples/spring-at-qiantang-lake-6806782d66f9.webp) |

## Contributing

Report bugs in [GitHub Issues](https://github.com/SXP-Simon/Panache/issues). For local setup, tests, and pull requests, see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[AGPL-3.0-only](LICENSE)

## Acknowledgments

- Thanks to [14790897/handwriting-web](https://github.com/14790897/handwriting-web) for the original project that inspired Panache.
- Thanks to [AnxForever’s StyleKit](https://github.com/AnxForever/stylekit) for the [Art Nouveau guide](https://www.stylekit.top/zh/styles/art-nouveau) that inspired the workbench’s floral motifs and curves.
- Thanks to [HakimYu](https://github.com/HakimYu) for the Flutter and Rust migration, and to everyone who has [contributed to Panache](https://github.com/SXP-Simon/Panache/graphs/contributors).

Friendship links: [LINUX DO](https://linux.do/)
