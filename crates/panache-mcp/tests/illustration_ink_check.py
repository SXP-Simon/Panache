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
        ("mixed", "循环 i = 10\n" + diagram, True),
        ("text", "循环 i = 10", False),
        ("image", diagram, False),
    ]
    result = {}
    for name, markdown, expect_crop in cases:
        saved = await call(client, "save_section", markdown=markdown, paper_path=str(paper),
                           paper_guides=guides, style={"seed": 27})
        key = {"draft_id": saved.structuredContent["draft_id"], "revision": 1}
        image = await call(client, "preview_handwriting", **key, view="image")
        assert ("illustration_inspection" in image.structuredContent) == (name != "text")
        full = await call(client, "preview_handwriting", **key, view="review")
        check = full.structuredContent.get("illustration_ink_check")
        assert bool(check) == expect_crop, name
        if check:
            args = check["preview_arguments"]
            assert all(args[k] == v for k, v in key.items())
            local = await call(client, "preview_handwriting", **args)
            meta = local.structuredContent
            assert meta["crop_bounds"][2:] == meta["crop_image_size"]
            layout = await call(client, "preview_handwriting", **{**args, "view": "layout"}, limit=32)
            items = layout.structuredContent["glyphs"]
            assert any(i.get("kind") == "illustration" for i in items)
            assert any("kind" not in i for i in items)
            if name == "drawings_then_text":
                page = await call(client, "preview_handwriting", **key, view="layout", limit=32)
                # The fixture ends with a single character after the native arrow.
                arrow_item, character = [i for i in page.structuredContent["glyphs"] if "kind" not in i]
                assert arrow_item["id"] < character["id"]
                assert character["id"] in {i["id"] for i in items}
            assert len([p for p in local.content if p.type == "image"]) == 2
            result[name + "_crop_size"] = meta["crop_image_size"]
        result[name] = bool(check)
    with open_db(home) as db:
        assert db.execute("SELECT count(*) FROM review_observations").fetchone()[0] == len(cases)
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
