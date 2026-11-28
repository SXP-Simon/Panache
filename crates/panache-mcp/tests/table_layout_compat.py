# /// script
# requires-python = ">=3.11"
# dependencies = ["mcp>=1.12,<2", "Pillow"]
# ///
"""Compare saved fine edits with a pre-clearance MCP binary and a patched binary."""

import argparse
import asyncio
import base64
from io import BytesIO
from pathlib import Path
from tempfile import TemporaryDirectory
from zipfile import ZipFile

from PIL import Image

from mcp_client import call, clone_home, isolated_session

MARKDOWN = """姓名 Jack

| 时间（s） | 拉开后的软尺长度（厘米） |
|---|---|
| 1 | 2 |
| 2 | 4 |

关键字就在表格下方。

保持这行手写位置。"""

CONTROLS = {
    "line_spacing": 34,
    "variation": {"perturb_theta_sigma": 0.55, "perturb_y_sigma": 8},
    "width": 620,
    "height": 720,
    "left_margin": 45,
    "right_margin": 45,
}
TITLE, CAPTION = 0, 10
PLACEMENT = [113, 294]


async def prepare(client, tight):
    saved = (await call(
        client, "save_section", markdown=MARKDOWN,
        style={"homework": True, "font_size": 32, "seed": 3},
    )).structuredContent
    key = {"draft_id": saved["draft_id"]}
    await call(client, "tune_handwriting", **key, expected_revision=1,
               changes={**CONTROLS, **({"bottom_margin": 320} if tight else {})})
    return key


async def place(client, key, revision, page, glyph, target):
    return (await call(
        client, "adjust_glyphs", **key, section=1, page=page, ids=[glyph],
        expected_revision=revision, place_center=target,
    )).structuredContent["revision"]


async def inspect(client, key, revision):
    args = {**key, "revision": revision}
    export = (await call(client, "export_handwriting", **args, format="zip")).structuredContent
    centers = {}
    pixels = []
    with ZipFile(export["path"]) as archive:
        pngs = [name for name in archive.namelist() if name.endswith(".png")]
        assert export["revision"] == revision and export["pages"] == len(pngs)
        for page, name in enumerate(pngs, 1):
            page_args = {**args, "section": 1, "page": page}
            layout = (await call(
                client, "preview_handwriting", **page_args, view="layout", limit=32,
            )).structuredContent
            for glyph in layout["glyphs"]:
                if "current_photo_quad" in glyph:
                    quad = glyph["current_photo_quad"]
                    center = [sum(p[a] for p in quad) / 4 for a in range(2)]
                    centers[glyph["id"]] = (page, center)
            preview = await call(client, "preview_handwriting", **page_args, view="image")
            image = next(block for block in preview.content if block.type == "image")
            pixel = Image.open(BytesIO(archive.read(name))).convert("RGB").tobytes()
            assert pixel == Image.open(BytesIO(base64.b64decode(image.data))).convert("RGB").tobytes()
            pixels.append(pixel)
    return centers, pixels


async def exercise(old, current, root):
    old_home = root / "legacy"
    old_home.mkdir()
    async with isolated_session(old, old_home) as (client, _):
        saved = []
        for tight in (False, True):
            key = await prepare(client, tight)
            await place(client, key, 2, 1, TITLE, [112, 109])
            revision = await place(client, key, 3, 1, CAPTION, PLACEMENT)
            evidence = await inspect(client, key, revision)
            assert evidence[0][CAPTION] == (1, PLACEMENT) and len(evidence[1]) == 1
            saved.append((key, revision, evidence))
    patched_home = clone_home(old_home, "upgraded")
    async with isolated_session(current, patched_home) as (client, _):
        for key, revision, evidence in saved:
            # The upgrade must preserve both old geometry and pixel output.
            assert await inspect(client, key, revision) == evidence
            following_revision = await place(client, key, revision, 1, TITLE, [122, 110])
            follow = await inspect(client, key, following_revision)
            assert follow[0][TITLE] == (1, [122, 110])
            assert follow[0][CAPTION] == (1, PLACEMENT) and len(follow[1]) == 1
            assert await inspect(client, key, revision) == evidence
        # New fine edits keep the new layout, including the relocated caption.
        fresh = await prepare(client, True)
        revision = await place(client, fresh, 2, 2, CAPTION, [130, 135])
        current = await inspect(client, fresh, revision)
        assert current[0][CAPTION] == (2, [130, 135]) and len(current[1]) == 2
    print("Pre-upgrade fine edits and ZIP pixels preserved; independent new edits retain table clearance.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("legacy", type=Path, help="native MCP binary built before table clearance")
    parser.add_argument("patched", type=Path, help="native MCP binary built from this checkout")
    args = parser.parse_args()
    with TemporaryDirectory() as temp:
        asyncio.run(exercise(args.legacy.resolve(), args.patched.resolve(), Path(temp)))
