# FAQ

## Uploading a document says "doc文件暂不支持"

`.doc` is the old Word format and the backend does not handle it. **Save it as `.docx`** and
upload that.

The supported formats are `.docx`, `.pdf`, `.txt` and `.rtf`. `.doc` is offered by the file picker
but rejected by the server.

## I uploaded my own font but the output still uses the old one

Uploads are selected automatically. If you switched fonts afterwards, select the uploaded file's
name again in the dropdown.

The picker accepts `.ttf`, `.otf`, and `.ttc`; make sure the file is a valid font.

## Generation seems stuck

Most likely it is queued. Check two places:

- **Workspace state** — check whether the task is queued or processing.
- **Preview area** — check progress; a retry countdown appears when the queue is full.

The backend handles a limited number of jobs at a time. When a task fails, follow the message and
check that the backend is reachable.

## Output got truncated partway

First check whether you generated the default single-page preview. Enable "Preview all pages" or
export ZIP / PDF. There is no fixed ten-page truncation. Long documents still depend on available
memory, proxy timeouts, and [server limits](../self-hosting/fonts-and-limits.md).

## Width/height and background image can't both be set

They are mutually exclusive: give a width and height and you get generated paper; upload a background
image and it is used as the base. To switch, clear the other one first (the background image has an
✕ in its top-right corner).

## There are rules on the generated paper and I don't want them

Uncheck **"Ruled paper"** for plain generated paper. Lines already present in a background image
are not removed by this option.

## Characters collide, or it looks too messy

See the "Tuning tips" section of [Parameters](parameters.md). The two most common cases:

- Characters overlapping → raise **Line Spacing** (it must exceed the font size).
- Too chaotic → lower **Perturb Theta Sigma**; it affects the impression the most.

## Letter layout deleted all my blank lines

That is by design — it removes every blank line and re-indents by two spaces per line.
"Undo layout" restores the previous state. Details in
[Chinese Letter Layout](chinese-letter.md).

## Can I use this commercially?

The **code** is MIT licensed — see [LICENSE](https://github.com/SXP-Simon/Panache/blob/custom-base/LICENSE).
Retain the original authors' and contributors' licence and copyright notices when distributing it.

**Fonts are a separate matter.** The fonts bundled in the repository and any fonts you upload each
carry their own licence, and whether you may use them commercially depends on that licence. Check the
licences of the files in `ttf_files/` yourself — do not assume they are MIT along with the code.

## Where do I ask questions?

- This fork's GitHub Issues: <https://github.com/SXP-Simon/Panache/issues>. Include the version,
  reproduction steps, and relevant logs; avoid publishing private document text.
