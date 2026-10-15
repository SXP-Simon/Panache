# Preview & Export

## Preview

Click **"Generate preview"** and inspect the result in the preview area.

- **Preview renders only the first page by default**. Enable "Preview all pages" for a full preview.
- When the text runs to several pages, page controls appear below the preview: "Previous",
  "Next", and "Page x / y".
- After changing any parameter you must **click preview again**. The preview does not re-render
  on its own.

## Exporting images (zip)

Click **"ZIP"** in the preview area and the backend renders every page to PNG and packages
them as `images.zip`.

- The archive contains one PNG per page, in order.
- This is the most direct way to get all the pages — useful if you want to lay them out yourself
  or drop them into another document.

## Exporting a PDF

Click **"PDF"** and the backend merges every page into a single `images.pdf`. No more
pasting images into a document by hand.

!!! tip "Which one?"
    Inserting into Word, or controlling page order yourself → **zip**.
    A file you can print or send as-is → **PDF**.

## Page count and limits

- The page controls count the pages rendered for this preview. A default single-page preview does
  not mean that the full document has only one page.
- The 10-page limit mentioned for `handwrite.14790897.xyz` in older documentation described an
  upstream instance. This fork does not truncate at a fixed ten pages, but long documents remain
  subject to [resource and request limits](../self-hosting/fonts-and-limits.md).

## Queueing, cooldowns and failures

- **Queueing** — the backend handles a limited number of jobs at once. When the queue is full a
  wait countdown appears, telling you roughly how long.
- **Progress** — generation state is pushed over a WebSocket; if that fails the client falls back
  to polling, and the interface looks the same.
- **Failures** — if rendering errors out, the task ends as failed with an error message.
  On a self-hosted instance the details are in the container logs:

  ```shell
  docker compose logs backend
  ```
