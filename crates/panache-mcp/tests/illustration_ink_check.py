"""Inspect a raster diagram alongside writing in real MCP review pixels."""

import argparse
import asyncio
import base64
import io
from pathlib import Path
from tempfile import TemporaryDirectory

from PIL import Image, ImageDraw

from mcp_client import call, isolated_session, open_db
from review_comparison import slanted_sheet


async def moved_rows(client, paper, guides):
    # Both groups start on a single source baseline; each will occupy a different photo row.
    saved = await call(client, "save_section", markdown="春夏秋冬东南西北天地山水",
                       paper_path=str(paper), paper_guides=guides, style={"font_size": 20, "seed": 27})
    key = {"draft_id": saved.structuredContent["draft_id"], "section": 1, "page": 1}
    for rev, (word, width, top) in enumerate([("春夏秋冬东南", 220, 125), ("西北天地山水", 140, 165)], 1):
        layout = (await call(client, "preview_handwriting", **key, revision=rev,
                             view="layout", limit=32)).structuredContent["glyphs"]
        if rev == 1:
            # The guides slope 16 px over 320 px. Compare original baselines at a common x.
            levels = [y + x * 16 / 320 for g in layout for x, y in g["photo_baseline"][:1]]
            assert max(levels) - min(levels) < 2, levels
        selected = [g for g in layout if g["text"] in word]
        assert len(selected) == len(word)
        await call(client, "adjust_glyphs", **key, expected_revision=rev,
                   ids=[g["id"] for g in selected],
                   target_quad=[[65, top], [65 + width, top], [65 + width, top + 28], [65, top + 28]])
    full = (await call(client, "preview_handwriting", **key, revision=3, view="review")).structuredContent
    metrics = full["evidence"]["adjacent_rows"]
    assert min(metrics["sampled_glyphs"]) >= 3
    a, b = metrics["median_horizontal_to_vertical_stretch"]
    assert a / b > 1.3, metrics
    args = full["adjacent_row_check"]["preview_arguments"]
    assert args["revision"] == 3 and "compare_revision" not in args
    local = (await call(client, "preview_handwriting", **args)).structuredContent
    assert local["crop_bounds"][2:] == local["crop_image_size"]
    for region in metrics["photo_regions"]:
        assert all(args["region"][0][0] <= x <= args["region"][2][0] and
                   args["region"][0][1] <= y <= args["region"][2][1] for x, y in region)
    # Reset both placements with proportional lettering. Only the lower row grows.
    for rev, (word, scale, y) in enumerate([("春夏秋冬东南", 100, 130), ("西北天地山水", 150, 175)], 3):
        layout = (await call(client, "preview_handwriting", **key, revision=rev,
                             view="layout", limit=32)).structuredContent["glyphs"]
        ids = [g["id"] for g in layout if g["text"] in word]
        await call(client, "adjust_glyphs", **key, expected_revision=rev, ids=ids,
                   natural_line={"start": [60, y], "end": [350, y], "scale_percent": scale})
    resized = (await call(client, "preview_handwriting", **key, revision=5, view="review")).structuredContent
    scale_check = resized["evidence"]["adjacent_rows"]
    upper, lower = scale_check["median_paper_vertical_scale"]
    assert abs(upper - 1) < 0.01 and abs(lower - 1.5) < 0.01, scale_check
    assert 1.49 < scale_check["larger_to_smaller_scale_ratio"] < 1.51
    assert scale_check["larger_to_smaller_ratio"] < 1.02, scale_check
    return metrics["larger_to_smaller_ratio"], scale_check["larger_to_smaller_scale_ratio"]


async def verify(client, home):
    paper = home / "ruled.png"
    guides = slanted_sheet(paper)
    art = Image.new("RGB", (100, 55), "white")
    draw = ImageDraw.Draw(art)
    draw.rectangle((6, 8, 45, 45), outline="black", width=4)
    draw.line((45, 24, 94, 24), fill="black", width=4)
    stream = io.BytesIO()
    art.save(stream, format="PNG")
    diagram = "![diagram](data:image/png;base64," + base64.b64encode(stream.getvalue()).decode() + ")"
    arrow = "\\begin{circuitikz}\n\\draw[->] (0,0) -- (2,0);\n\\end{circuitikz}"
    drawings = f"{diagram}\n\n{arrow}"
    cases = [
        ("drawings_only", drawings, False),
        ("drawings_then_text", drawings + "\n\n字", True),
        ("native", arrow + "\n\n字", True),
        ("mixed", "循环 i = 10\n" + diagram, True),
        ("text", "循环 i = 10", False),
        ("image", diagram, False),
    ]
    result = {}
    with open_db(home) as db:
        initial = db.execute("SELECT count(*) FROM review_observations").fetchone()[0]
    for name, markdown, expect_crop in cases:
        saved = await call(client, "save_section", markdown=markdown, paper_path=str(paper),
                           paper_guides=guides, style={"seed": 27, "illustration_uses_pen": False})
        key = {"draft_id": saved.structuredContent["draft_id"], "revision": 1}
        image = await call(client, "preview_handwriting", **key, view="image")
        assert ("illustration_inspection" in image.structuredContent) == (diagram in markdown or arrow in markdown)
        if name == "mixed":
            await call(client, "tune_handwriting", draft_id=key["draft_id"], expected_revision=1,
                       changes={"ink_opacity": 20})
            key["revision"] = 2
        full = await call(client, "preview_handwriting", **key, view="review")
        check = full.structuredContent.get("illustration_ink_check")
        assert bool(check) == expect_crop, name
        if check:
            evidence = full.structuredContent["evidence"]["illustration_contrast"]
            chart, text = evidence["illustration"], evidence["nearby_text"]
            assert min(chart["darkened_pixels"], text["darkened_pixels"]) > 0
            if name == "mixed":
                assert chart["p90_luma_drop"] > text["p90_luma_drop"] + 30, evidence
            args = check["preview_arguments"]
            assert all(args[k] == v for k, v in key.items())
            local = await call(client, "preview_handwriting", **args)
            meta = local.structuredContent
            assert meta["crop_bounds"][2:] == meta["crop_image_size"]
            layout = await call(client, "preview_handwriting", **{**args, "view": "layout"}, limit=32)
            items = layout.structuredContent["glyphs"]
            if name != "native":
                assert any(i.get("kind") == "illustration" for i in items)
            else:
                assert len(items) >= 2
            assert any("kind" not in i for i in items)
            if name == "drawings_then_text":
                page = await call(client, "preview_handwriting", **key, view="layout", limit=32)
                # The fixture ends with a single character after the native arrow.
                arrow_item, character = [i for i in page.structuredContent["glyphs"]
                                         if i.get("kind") in (None, "native_diagram")]
                assert arrow_item["id"] < character["id"]
                assert character["id"] in {i["id"] for i in items}
            assert len([p for p in local.content if p.type == "image"]) == 2
            result[name + "_crop_size"] = meta["crop_image_size"]
        result[name] = bool(check)
    result["moved_row_ratio"], result["uniform_scale_ratio"] = await moved_rows(client, paper, guides)
    with open_db(home) as db:
        assert db.execute("SELECT count(*) FROM review_observations").fetchone()[0] == initial + len(cases) + 2
    return result


async def main(binary):
    with TemporaryDirectory() as temp:
        home = Path(temp)
        async with isolated_session(binary, home) as (client, _):
            print(await verify(client, home))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    asyncio.run(main(parser.parse_args().binary.resolve()))
