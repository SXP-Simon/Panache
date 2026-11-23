# Preview, refine and export

Use first-page preview while choosing the font. Live preview refreshes after edits. Enable all-page preview before exporting and check margins and line endings. After zooming in, choose Fit page to see the full sheet.

In the fine editor, select a character or lasso a group to move it, adjust its ink or transform its corners. Phones can use the full-screen editor.

Save the current image to share a single page. Export a PDF for a multi-page document, or an image ZIP for a PNG of each page.

### Paper camera information

When a photograph supplies the background, each PNG, including each page in a ZIP, retains available EXIF values for the manufacturer, camera and lens models, ISO, focal length, aperture and exposure time. PDF exports list the same details in the document subject. Location, capture time, serial numbers and thumbnails are excluded.

Under **Paper → Paper camera**, enter any missing manufacturer, model, lens model or ISO. Use printable ASCII for the names and 1–65535 for ISO. Values in the photograph take precedence. The EXIF description and PDF subject identify fields supplied by the user. With neither source nor manual values, the export has no camera record.

In MCP, inspect the `camera` group with `describe_controls`, then send the desired fields through `tune_handwriting`, for example `changes={"camera_model":"Pixel 8","camera_iso":200}`. Set a field to `null` to clear it. Camera-only changes preserve glyph adjustments.
