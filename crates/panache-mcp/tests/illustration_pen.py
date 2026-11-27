"""Verify pen inheritance against the exported diagram pixels, including old revisions."""

import base64
import io
from pathlib import Path
from tempfile import TemporaryDirectory
from zipfile import ZipFile

from PIL import Image, ImageDraw

from mcp_client import call


async def verify(client):
    drawing = Image.new("RGB", (110, 60), "white")
    draw = ImageDraw.Draw(drawing)
    draw.rectangle((6, 6, 70, 50), outline="black", width=4)
    draw.line((70, 29, 105, 29), fill="black", width=3)
    buffer = io.BytesIO()
    drawing.save(buffer, "PNG")
    markdown = "![CFG](data:image/png;base64," + base64.b64encode(buffer.getvalue()).decode() + ")"
    saved = await call(client, "save_section", markdown=markdown,
                       style={"homework": True, "ink": "#943020", "seed": 13})
    key = {"draft_id": saved.structuredContent["draft_id"]}

    async def preview(revision):
        result = await call(client, "preview_handwriting", revision=revision, **key)
        return base64.b64decode(next(item.data for item in result.content if item.type == "image"))

    original = await preview(1)
    red = Image.open(io.BytesIO(original)).convert("RGB")
    assert any(r > g + 35 and r > b + 35 for r, g, b in red.getdata())
    for rev, changes in [(1, {"illustration_uses_pen": False}),
                         (2, {"illustration_uses_pen": True, "ink_opacity": 0})]:
        applied = await call(client, "tune_handwriting", expected_revision=rev, changes=changes, **key)
        assert applied.structuredContent["fine_layout"] == "preserved"
    legacy = Image.open(io.BytesIO(await preview(2))).convert("RGB")
    assert not any(r > g + 35 for r, g, _ in legacy.getdata())
    assert min(legacy.getextrema()[0]) < 150
    clear = Image.open(io.BytesIO(await preview(3))).convert("RGB")
    assert clear.getextrema() == ((255, 255),) * 3
    assert await preview(1) == original
    exported = await call(client, "export_handwriting", revision=1, format="zip", **key)
    with ZipFile(Path(exported.structuredContent["path"])) as archive:
        assert archive.read("0.png") == original

    # A real Markdown worker passes the opt-in graph, including conditions, to Rust as one drawing.
    chart = r"""\begin{circuitikz}[flowchart]
\draw (0,0) node[rectangle]{B2};
\draw (3,-1) node[diamond]{B3};
\draw[->] (0,0) -- (3,-1) node[midway,above]{i ≤ 10};
\draw[->] (3,-1) -- (3,-2.6) -- (-1.4,-2.6) |- (0,0);
\end{circuitikz}"""
    saved = await call(client, "save_section", markdown="图\n\n" + chart,
                       style={"font": "华阳手写体.ttf", "font_size": 24, "seed": 17})
    key = {"draft_id": saved.structuredContent["draft_id"]}

    async def chart_crop(revision):
        layout = (await call(client, "preview_handwriting", **key, revision=revision,
                             view="layout")).structuredContent
        assert layout["total"] == 2
        x, y, w, h = layout["glyphs"][1]["bounds"]
        image = Image.open(io.BytesIO(await preview(revision))).convert("L")
        return image.crop((x, y, x + w, y + h))

    before = await chart_crop(1)
    await call(client, "tune_handwriting", **key, expected_revision=1,
               changes={"font": "李国夫手写体.ttf"})
    restyled = await chart_crop(2)
    assert before.size != restyled.size or before.tobytes() != restyled.tobytes()
    await call(client, "tune_handwriting", **key, expected_revision=2, changes={"font_size": 40})
    enlarged = await chart_crop(3)
    assert enlarged.width > 1.3 * restyled.width and enlarged.height > 1.3 * restyled.height

    layout = (await call(client, "preview_handwriting", **key, revision=3, view="layout")).structuredContent
    chart_id = layout["glyphs"][1]["id"]
    target = dict(**key, section=1, page=1, ids=[chart_id])
    # Use the same fine layout on both sides so the only changing property is the ink ramp.
    await call(client, "adjust_glyphs", **target, expected_revision=3, opacity=100)
    fixed = await chart_crop(4)
    bad = await client.call_tool("adjust_glyphs", {**target, "expected_revision":4, "opacity_ramp":[[60,70],[20,100]]})
    assert bad.isError
    await call(client, "adjust_glyphs", **target, expected_revision=4, opacity_ramp=[[0,40],[50,100]])
    faded = await chart_crop(5)
    upper = (0, 0, fixed.width, fixed.height // 3)
    lower = (0, fixed.height * 2 // 3, fixed.width, fixed.height)
    assert sum(faded.crop(upper).getdata()) > sum(fixed.crop(upper).getdata())
    assert faded.crop(lower).tobytes() == fixed.crop(lower).tobytes()
    await call(client, "adjust_glyphs", **target, expected_revision=5, opacity_ramp=[[0,100],[100,100]])
    assert (await chart_crop(6)).tobytes() == fixed.tobytes()
    assert (await chart_crop(5)).tobytes() == faded.tobytes()
    with TemporaryDirectory() as temp:
        await whole_drawing_on_photo(client, Path(temp), chart)


async def whole_drawing_on_photo(client, directory, chart):
    photo = directory / "worksheet.png"
    sheet = Image.new("RGB", (440, 560), "white")
    guides = [{"row": 0, "left": [55, 79], "right": [370, 57]},
              {"row": 10, "left": [26, 513], "right": [414, 485]}]
    for guide in guides:
        ImageDraw.Draw(sheet).line((tuple(guide["left"]), tuple(guide["right"])), fill="gray")
    sheet.save(photo)
    art = Image.new("RGB", (140, 70), "white")
    drawing = ImageDraw.Draw(art)
    drawing.rectangle((10, 8, 129, 60), outline="black", width=3)
    drawing.rectangle((40, 25, 48, 36), fill="black")
    stream = io.BytesIO()
    art.save(stream, "PNG")
    markdown = "字\n\n![CFG](data:image/png;base64," + base64.b64encode(stream.getvalue()).decode() + ")"
    saved = await call(client, "save_section", markdown=markdown + "\n\n" + chart,
                       paper_path=str(photo), paper_guides=guides, style={"seed": 13, "font_size": 20})
    key = {"draft_id": saved.structuredContent["draft_id"], "section": 1, "page": 1}

    async def layout(revision):
        return (await call(client, "preview_handwriting", **key, revision=revision,
                           view="layout", limit=32)).structuredContent["glyphs"]

    async def pixels(revision):
        response = await call(client, "preview_handwriting", **key, revision=revision)
        png = base64.b64decode(next(i.data for i in response.content if i.type == "image"))
        return Image.open(io.BytesIO(png)).convert("RGB")

    def red_pixels(image):
        return {(i % image.width, i // image.width) for i, (r, g, b) in enumerate(image.getdata())
                if r > max(g, b) + 30}

    items = await layout(1)
    frame, label = [g["id"] for g in items if g.get("illustration_id") is not None]
    text, native = [g["id"] for g in items if g.get("illustration_id") is None]
    for g in items:
        if g["id"] in (native, frame):
            tl, tr, br, bl = g["photo_quad"]
            assert tl[1] > tr[1] and br[0] - bl[0] > tr[0] - tl[0]
    target = {"ids": [frame], "whole_drawing": True}
    for invalid in ({"ids": [text]}, {"ids": [label]}, {"ids": [frame, label]},
                    {"shape": {"shear_degrees": 7, "top_width_percent": 95}}, {"scale": 110}):
        response = await client.call_tool("adjust_glyphs", {
            **key, "expected_revision": 1, **target, "place_center": [205, 230], **invalid})
        assert response.isError

    await call(client, "adjust_glyphs", **key, expected_revision=1, ids=[label], dx=5, angle=8,
               shape={"shear_degrees": 9, "top_width_percent": 95}, color="#db1020")
    before = next(g["adjustment"] for g in await layout(2) if g["id"] == label)
    moved = await call(client, "adjust_glyphs", **key, expected_revision=2, **target, place_center=[190, 240])
    assert moved.structuredContent["count"] == 2
    group = {g["id"]: g for g in await layout(3)}
    after = group[label]["adjustment"]
    delta = group[frame]["adjustment"]
    assert (after["dx"] - before["dx"], after["dy"] - before["dy"]) == (delta["dx"], delta["dy"])
    assert all(after[k] == before[k] for k in ("angle", "warp", "scale", "color"))
    assert "adjustment" not in group[native] and "adjustment" not in group[text]

    quad = [[100, 326], [277, 297], [294, 397], [92, 421]]
    await call(client, "adjust_glyphs", **key, expected_revision=3, ids=[frame], target_quad=quad)
    old_label = red_pixels(await pixels(4))
    assert old_label and old_label == red_pixels(await pixels(3))
    await call(client, "adjust_glyphs", **key, expected_revision=4, **target, target_quad=quad)
    group = {g["id"]: g for g in await layout(5)}
    assert all(abs(a - b) < 0.1 for point, goal in zip(group[frame]["current_photo_quad"], quad)
               for a, b in zip(point, goal))
    whole = await pixels(5)
    new_label = red_pixels(whole)
    assert new_label and new_label.isdisjoint(old_label)
    mask = Image.new("1", whole.size)
    ImageDraw.Draw(mask).polygon([tuple(p) for p in group[label]["current_photo_quad"]], fill=1)
    assert all(mask.getpixel(p) for p in new_label)
    await call(client, "adjust_glyphs", **key, expected_revision=5, ids=[frame, label], target_quad=quad)
    assert (await pixels(6)).tobytes() == whole.tobytes()
    moved = await call(client, "adjust_glyphs", **key, expected_revision=6, whole_drawing=True,
                       ids=[native], target_quad=[[91, 92], [301, 76], [305, 154], [93, 173]])
    assert moved.structuredContent["count"] == 1
    native_after = await pixels(7)
    assert native_after.tobytes() != whole.tobytes() and red_pixels(native_after) == new_label
