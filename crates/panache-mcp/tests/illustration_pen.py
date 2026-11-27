"""Verify pen inheritance against the exported diagram pixels, including old revisions."""

import base64
import io
from pathlib import Path
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
