"""Fill a synthetic coursework form through public MCP calls and check its pixels."""

import base64
import io

from PIL import Image, ImageChops, ImageDraw

from mcp_client import call


def corners(box):
    left, top, right, bottom = box
    return [[left, top], [right, top], [right, bottom], [left, bottom]]


def finished_image(result):
    block = next(b for b in result.content if b.type == "image")
    return Image.open(io.BytesIO(base64.b64decode(block.data))).convert("RGB")


def ink_mask(paper, finished):
    delta = ImageChops.difference(paper, finished).convert("L")
    return delta.point(lambda value: 255 if value >= 8 else 0)


async def exercise(client, directory):
    # Fixture annotations express the user's choices independently of detected lines.
    paper = Image.new("RGB", (420, 460), "#f8f6ed")
    draw = ImageDraw.Draw(paper)
    draw.text((80, 12), "UNIVERSITY COURSEWORK", fill="black")
    draw.rectangle((24, 48, 395, 88), outline="black")
    draw.text((34, 61), "Course", fill="black")
    draw.line((255, 48, 255, 88), fill="black")
    draw.text((265, 61), "Score:", fill="black")
    draw.rectangle((24, 104, 395, 428), outline="black")
    draw.line((73, 104, 73, 428), fill="black")
    label = Image.new("RGB", (42, 16), paper.getpixel((0, 0)))
    ImageDraw.Draw(label).text((0, 0), "Name", fill="black")
    paper.paste(label.transpose(Image.Transpose.ROTATE_90), (32, 365))
    for y in range(150, 421, 40):
        draw.line((85, y, 383, y), fill="#909aa2")
    path = directory / "coursework.png"
    paper.save(path)

    cropped_guides = [{"row": row, "left": [85, y], "right": [383, y]}
                      for row, y in [(0, 12), (6, 252)]]
    crowded = await client.call_tool("save_section", {
        "markdown": "试填", "paper_path": str(path), "paper_guides": cropped_guides,
    })
    assert crowded.isError and "12.0px" in crowded.content[0].text
    assert "40.0px" in crowded.content[0].text and "next visible ruling" in crowded.content[0].text

    body = ["观察云层", "记录风向"]
    course, name = "电磁学", "林舟"
    saved = (await call(
        client, "save_section", markdown="\n\n".join([*body, course, name]),
        paper_path=str(path), style={"font_size": 24, "seed": 29},
        paper_guides=[{"row": row, "left": [85, y], "right": [383, y]}
                      for row, y in [(0, 150), (6, 390)]],
    )).structuredContent
    key = {"draft_id": saved["draft_id"], "section": 1, "page": 1}
    revision = saved["revision"]

    layout = (await call(client, "preview_handwriting", **key, revision=revision,
                         view="layout", limit=32)).structuredContent
    assert layout["next_offset"] is None
    glyphs = {g["text"]: g for g in layout["glyphs"]}
    assert set(glyphs) == set("".join([*body, course, name]))

    async def place(text, quad):
        nonlocal revision
        revision = (await call(
            client, "adjust_glyphs", **key, expected_revision=revision,
            ids=[glyphs[c]["id"] for c in text], target_quad=quad,
        )).structuredContent["revision"]

    # Leave the two body lines on their guides. Relocate only the field values.
    header = (97, 54, 164, 80)
    await place(course, corners(header))
    horizontal = finished_image(await call(client, "preview_handwriting", **key, revision=revision))
    pts = [p for c in name for p in glyphs[c]["photo_quad"]]
    xs, ys = zip(*pts)
    source = (min(xs), min(ys), max(xs), max(ys))
    reference = ink_mask(paper.crop(source), horizontal.crop(source))
    side = (33, 342 - reference.width, 33 + reference.height, 342)
    tl, tr, br, bl = corners(side)
    await place(name, [bl, tl, tr, br])

    # Check the final raster independently of the geometry the server reports.
    final = finished_image(await call(client, "preview_handwriting", **key, revision=revision))
    ink = ink_mask(paper, final)
    observed = ink.crop(side).transpose(Image.Transpose.ROTATE_270)
    overlap = ImageChops.darker(reference, observed).histogram()[255]
    union = ImageChops.lighter(reference, observed).histogram()[255]
    assert union > 0 and overlap / union > 0.80, (overlap, union)

    rows = [(84, 120, 205, 159), (84, 160, 205, 199)]
    for field, text in [(header, course), *zip(rows, body, strict=True)]:
        selected = (await call(client, "preview_handwriting", **key, revision=revision,
                               view="layout", region=corners(field))).structuredContent
        by_x = sorted(selected["glyphs"], key=lambda g: g["selected_center"][0])
        assert "".join(g["text"] for g in by_x) == text
        for glyph in by_x:
            xs, ys = zip(*glyph.get("current_photo_quad", glyph["photo_quad"]))
            assert ink.crop((min(xs), min(ys), max(xs), max(ys))).getbbox(), glyph["text"]
    # Every pixel outside the designated fields, including the printed name,
    # title, score box and all other rules, must survive untouched.
    diff = ImageChops.difference(paper, final)
    for box in [header, side, *rows]:
        diff.paste((0, 0, 0), box)
    assert diff.getbbox() is None, diff.getbbox()
    review = (await call(client, "preview_handwriting", **key, revision=revision,
                         view="review")).structuredContent
    assert review["evidence"]["changed_pixels_outside_reference"] > 0

    # Recreate a twice-wide worksheet row and restore its original letters with one edit.
    async def layout_glyphs():
        layout = (await call(client, "preview_handwriting", **key, revision=revision,
                             view="layout", limit=32)).structuredContent
        return {g["text"]: g for g in layout["glyphs"]}

    glyphs = await layout_glyphs()
    line = [glyphs[c] for c in body[0]]
    xs, ys = zip(*(p for glyph in line for p in glyph["photo_quad"]))
    wide = corners((min(xs), min(ys), min(xs) + 2 * (max(xs) - min(xs)), max(ys)))
    targets = dict(ids=[g["id"] for g in line], expected_texts=list(body[0]))
    stretched = await call(client, "adjust_glyphs", **key, expected_revision=revision,
                           **targets, target_quad=wide)
    revision = stretched.structuredContent["revision"]
    report = stretched.structuredContent["placement"]
    assert report["mode"] == "target_quad" and 1.9 < report["max_glyph_center_axis_ratio"] < 2.1
    assert "natural_line" in stretched.content[0].text
    distorted = finished_image(await call(client, "preview_handwriting", **key, revision=revision))
    row = (78, 118, 383, 159)
    original_ink = ink.crop(row)
    wide_ink = ink_mask(paper.crop(row), distorted.crop(row))
    assert wide_ink.getbbox()[2] - wide_ink.getbbox()[0] > 1.8 * (
        original_ink.getbbox()[2] - original_ink.getbbox()[0])

    glyphs = await layout_glyphs()
    targets["ids"] = [glyphs[c]["id"] for c in body[0]]
    start = min((glyphs[c]["photo_baseline"][0] for c in body[0]), key=lambda p: p[0])
    baseline = {"start": start, "end": [383, start[1]]}
    for args, reason in [
        ({"natural_line": {**baseline, "end": [start[0] + 5, start[1]]}}, "Split the line"),
        ({"natural_line": baseline, "target_quad": wide}, "separately"),
        ({"natural_line": baseline, "ids": [line[0]["id"], glyphs[body[1][0]]["id"]],
          "expected_texts": [body[0][0], body[1][0]]}, "one original layout baseline"),
    ]:
        rejected = await client.call_tool("adjust_glyphs", {
            **key, "expected_revision": revision, **targets, **args,
        })
        assert rejected.isError and reason in rejected.content[0].text

    restored = await call(client, "adjust_glyphs", **key, expected_revision=revision,
                          **targets, natural_line=baseline)
    revision = restored.structuredContent["revision"]
    report = restored.structuredContent["placement"]
    assert report["mode"] == "natural_line" and report["scale_percent"] == 100
    assert report["available_paper_px"] > 2 * report["used_paper_px"]
    result = finished_image(await call(client, "preview_handwriting", **key, revision=revision))
    aligned = ink_mask(paper.crop(row), result.crop(row))
    intersection = ImageChops.darker(original_ink, aligned).histogram()[255]
    union = ImageChops.lighter(original_ink, aligned).histogram()[255]
    assert intersection / union > 0.85, (intersection, union)
