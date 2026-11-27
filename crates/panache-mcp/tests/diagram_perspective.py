# /// script
# requires-python = ">=3.11"
# dependencies = ["mcp>=1.12,<2", "Pillow"]
# ///
"""Exercise whole-drawing geometry and visible label placement through MCP stdio."""

import argparse
import asyncio
import base64
import io
import math
from pathlib import Path
from tempfile import TemporaryDirectory
from zipfile import ZipFile

from PIL import Image, ImageChops, ImageDraw

from mcp_client import call, isolated_session


def ruled_photo(path):
    paper = Image.new("RGB", (480, 560), "#f7f5ef")
    draw = ImageDraw.Draw(paper)
    guides = []
    for row in range(11):
        left = [55 - 2 * row, 90 + 34 * row]
        right = [420 + 2 * row, 70 + 41 * row]
        draw.line([tuple(left), tuple(right)], fill="#77899c", width=2)
        guides.append({"row": row, "left": left, "right": right})
    paper.save(path)
    return guides


def labeled_raster():
    art = Image.new("RGB", (140, 70), "white")
    draw = ImageDraw.Draw(art)
    draw.rectangle((10, 10, 130, 60), outline="black", width=3)
    # A disconnected letter inside the frame gets a separately selectable layout ID.
    draw.line([(49, 29), (49, 40), (56, 40)], fill="black", width=3)
    stream = io.BytesIO()
    art.save(stream, format="PNG")
    return "![labeled frame](data:image/png;base64," + base64.b64encode(stream.getvalue()).decode() + ")"


NATIVE = r"""\begin{circuitikz}[flowchart]
\draw (0,0) node[rectangle]{B1};
\draw (2,0) node[rectangle]{B2};
\draw[->] (0,0) -- (2,0);
\end{circuitikz}"""


def gap(a, b):
    return max(math.dist(p, q) for p, q in zip(a, b, strict=True))


def slope(quad):
    (x0, y0), (x1, y1) = quad[:2]
    return (y1 - y0) / (x1 - x0)


async def verify(client, home):
    photo = home / "drawing-perspective.png"
    guides = ruled_photo(photo)
    source = "测量\n\n" + NATIVE + "\n\n" + labeled_raster()
    style = {"font_size": 20, "seed": 27}
    for markdown, paper in [(NATIVE, {}), ("普通文字", {"paper_path": str(photo), "paper_guides": guides})]:
        saved = await call(client, "save_section", markdown=markdown, style=style, **paper)
        reviewed = await call(client, "preview_handwriting", draft_id=saved.structuredContent["draft_id"], view="review")
        assert "diagram_perspective_check" not in reviewed.structuredContent

    saved = await call(client, "save_section", markdown=source, paper_path=str(photo), paper_guides=guides, style=style)
    key = {"draft_id": saved.structuredContent["draft_id"], "section": 1, "page": 1}

    async def preview(revision, view, **extra):
        return (await call(client, "preview_handwriting", **key, revision=revision, view=view, **extra)).structuredContent

    async def edit(rev, glyph_id, **changes):
        return (await call(client, "adjust_glyphs", **key, expected_revision=rev, ids=[glyph_id], **changes)).structuredContent

    filtered = await preview(1, "layout", drawings_only=True, limit=1)
    second = await preview(1, "layout", drawings_only=True, offset=filtered["next_offset"])
    assert filtered["total"] == 2 and second["next_offset"] is None
    rows = filtered["glyphs"] + second["glyphs"]
    assert [g["kind"] for g in rows] == ["native_diagram", "illustration"], rows
    native, raster = [g["id"] for g in rows]
    parts = (await preview(1, "layout", illustrations_only=True))["glyphs"]
    label, = [g["id"] for g in parts if g["kind"] == "illustration_detail" and g["illustration_id"] == raster]

    async def items(rev, **options):
        return (await preview(rev, "review", **options))["diagram_perspective_check"]["items"]

    aligned = await items(1)
    assert [(i["id"], i["kind"]) for i in aligned] == [(g["id"], g["kind"]) for g in rows]
    for item in aligned:
        assert gap(item["current_photo_quad"], item["paper_aligned_photo_quad"]) < 1.5
        assert max(abs(a) for a in item["axis_difference_deg_top_bottom_left_right"]) < 1
        tl, tr, br, bl = item["current_photo_quad"]
        ratio = math.dist(bl, br) / math.dist(tl, tr)
        assert math.isclose(item["bottom_to_top_width_ratio"], ratio, rel_tol=1e-5)
        assert math.isclose(item["paper_bottom_to_top_width_ratio"], ratio, rel_tol=1e-5)
        native_preview = await call(client, "preview_handwriting", **item["native_image_arguments"])
        assert native_preview.structuredContent["export_blur_px"] == 0
        for field, view in [("preview_arguments", "review"), ("layout_arguments", "layout")]:
            args = item[field]
            assert all(args[k] == v for k, v in key.items()) and args["revision"] == 1 and args["view"] == view
            result = await call(client, "preview_handwriting", **args)
            if view == "layout":
                assert args["drawings_only"] and item["id"] in [g["id"] for g in result.structuredContent["glyphs"]]
            else:
                assert len([p for p in result.content if p.type == "image"]) == 2
                assert item["id"] in [i["id"] for i in result.structuredContent["diagram_perspective_check"]["items"]]

    # Move down the photo, where the rulings slope the other way.
    await edit(1, native, whole_drawing=True, place_center=[190, 385])
    moved = next(i for i in await items(2) if i["id"] == native)
    assert gap(moved["current_photo_quad"], moved["paper_aligned_photo_quad"]) < 1.5
    assert max(abs(a) for a in moved["axis_difference_deg_top_bottom_left_right"]) < 1
    assert slope(moved["paper_aligned_photo_quad"]) > slope(aligned[0]["paper_aligned_photo_quad"]) + 0.07
    await edit(2, native, angle=20)
    rotated = next(i for i in await items(3) if i["id"] == native)
    assert gap(rotated["current_photo_quad"], rotated["paper_aligned_photo_quad"]) > 5
    assert slope(rotated["current_photo_quad"]) > slope(rotated["paper_aligned_photo_quad"]) + 0.15
    assert abs(rotated["axis_difference_deg_top_bottom_left_right"][0]) > 10

    # Color only the letter. Warping the full drawing must keep that letter inside the frame.
    await edit(3, label, color="#ce2020")
    target = [[210, 183], [406, 192], [394, 267], [235, 271]]
    updated = await edit(4, raster, whole_drawing=True, target_quad=target)
    assert updated["count"] == len(parts) == 2
    corner_region = [[208, 182], [219, 182], [219, 194], [208, 194]]
    warped, = await items(5, region=corner_region)
    assert warped["id"] == raster and gap(warped["current_photo_quad"], target) < 1.5
    assert gap(warped["current_photo_quad"], warped["paper_aligned_photo_quad"]) > 5
    assert max(abs(a) for a in warped["axis_difference_deg_top_bottom_left_right"][2:]) > 7
    blank = await preview(5, "review", region=[[440, 510], [470, 510], [470, 530], [440, 530]])
    assert "diagram_perspective_check" not in blank

    async def label_center(revision):
        frame = await call(client, "preview_handwriting", **key, revision=revision, view="image")
        png = base64.b64decode(next(p.data for p in frame.content if p.type == "image"))
        image = Image.open(io.BytesIO(png)).convert("RGB")
        r, g, b = image.split()
        red = ImageChops.subtract(r, ImageChops.lighter(g, b)).point(lambda v: 255 if v > 50 else 0)
        box = red.getbbox()
        assert box
        left, top, right, bottom = box
        return [(left + right) / 2, (top + bottom) / 2], png

    before, _ = await label_center(5)
    assert 245 < before[0] < 330 and 200 < before[1] < 253, before
    translated = await edit(5, raster, whole_drawing=True, place_center=[145, 300])
    assert translated["count"] == 2
    after, png = await label_center(6)
    assert after[0] < before[0] - 130 and after[1] > before[1] + 45, (before, after)
    region = [[115, 285], [135, 285], [135, 310], [115, 310]]
    moved_raster, = await items(6, region=region)
    assert moved_raster["id"] == raster
    assert moved_raster["separate_detail_alignment"]["visible_parts"] == 1
    assert moved_raster["separate_detail_alignment"]["max_corner_offset_from_parent_px"] < 1.5
    frame_shift = [sum(q[n] - p[n] for p, q in zip(target, moved_raster["current_photo_quad"])) / 4 for n in (0, 1)]
    assert math.dist(frame_shift, [b - a for a, b in zip(before, after)]) < 8, (frame_shift, before, after)
    export = await call(client, "export_handwriting", draft_id=key["draft_id"], revision=6, format="zip")
    with ZipFile(export.structuredContent["path"]) as archive:
        assert archive.read("0.png") == png

    # A nudge of the parent ID alone still leaves the individually selected letter in place.
    legacy = await edit(6, raster, dx=25)
    assert legacy["count"] == 1
    unchanged_label, _ = await label_center(7)
    assert math.dist(after, unchanged_label) < 1
    detached = next(d for d in await items(7) if d["id"] == raster)
    assert detached["separate_detail_alignment"]["max_corner_offset_from_parent_px"] > 10

    plain = home / "uncalibrated-drawing.png"
    Image.new("RGB", (480, 560), "#f7f5ef").save(plain)
    saved = await call(client, "save_section", markdown=NATIVE, paper_path=str(plain), style=style)
    result = await call(client, "preview_handwriting", draft_id=saved.structuredContent["draft_id"], view="review")
    uncalibrated, = result.structuredContent["diagram_perspective_check"]["items"]
    assert uncalibrated["kind"] == "native_diagram" and len(uncalibrated["current_photo_quad"]) == 4
    assert uncalibrated["paper_aligned_photo_quad"] is None
    assert uncalibrated["axis_difference_deg_top_bottom_left_right"] is None


async def main(binary):
    with TemporaryDirectory() as temp:
        home = Path(temp)
        async with isolated_session(binary, home) as (client, _):
            await verify(client, home)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    asyncio.run(main(parser.parse_args().binary.resolve()))
