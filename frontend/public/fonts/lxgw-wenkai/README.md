# LXGW WenKai UI webfonts

Source: [LXGW WenKai v1.522](https://github.com/lxgw/LxgwWenKai/releases/tag/v1.522),
official [Regular TTF](https://github.com/lxgw/LxgwWenKai/releases/download/v1.522/LXGWWenKai-Regular.ttf).
The bundled [OFL.txt](./OFL.txt) is the unmodified license from that release.

These files are only used by the application interface. They do not select or replace
fonts used to render handwriting on paper.

`fonts.css` defines one family, `LXGW WenKai`, at its original Regular weight (400).
The browser can synthesize the interface's heavier weights. Both Latin and Chinese
glyphs come from this family.

- `lxgw-wenkai-ui-v1.522.woff2` contains the interface's characters, Latin letters,
  digits, punctuation and bundled handwriting font filenames. Its Unicode ranges
  take priority, keeping ordinary interface font requests small.
- `lxgw-wenkai-regular-v1.522.woff2` preserves all 46,490 Unicode mappings of the
  original Regular font. Characters outside the UI subset, including arbitrary
  editor text and uploaded filenames, use this complete face under the same family.

FontTools performed WOFF2 conversion without changing outlines. The complete face
uses Brotli quality 6 with untransformed tables; the UI face is a web-only subset.
The service worker includes both faces, their stylesheet and license in its shell
cache so they remain available after an offline restart.

SHA-256:

```text
Original Regular TTF: 39ad71264b588165b469e35e6afb162a378dacd1f95348160240ba9038ac3009
Complete WOFF2: c7724e623415bfac526256f28611fac61f91f020f1469bfcdddcd79d6ef05232
UI WOFF2: d921caa664b13cf2bb8242e2c0df55eb50b92816d573d65181176aa31ffc169f
```
