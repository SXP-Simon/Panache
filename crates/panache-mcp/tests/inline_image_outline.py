# /// script
# dependencies = ["mcp>=1.12,<2", "Pillow"]
# ///
"""Check the source bytes and rendered appearance of a colored inline illustration."""

import base64
import io

from PIL import Image, ImageDraw
import argparse
import asyncio
from pathlib import Path
from tempfile import TemporaryDirectory

from mcp_client import call, isolated_session, open_db


async def run(binary, home):
    async with isolated_session(binary, home) as (client, info):
        tools = {t.name: t for t in (await client.list_tools()).tools}
        assert (
            "hand-drawn outlines"
            in tools["save_section"].inputSchema["properties"]["markdown"]["description"]
        )
        picture = Image.new("RGB", (100, 75), "white")
        ImageDraw.Draw(picture).rectangle((15, 10, 85, 65), fill="magenta", outline="navy", width=5)
        buffer = io.BytesIO()
        picture.save(buffer, format="PNG")
        image_data = base64.b64encode(buffer.getvalue()).decode()
        source = f"![示意图](data:image/png;base64,{image_data})"
        key = (
            await call(client, "save_section", markdown=source, style={"seed": 31})
        ).structuredContent["draft_id"]
        saved = (
            await call(client, "read_section", draft_id=key, view="source", section=1)
        ).structuredContent
        assert saved["markdown"] == source
        preview = await call(client, "preview_handwriting", draft_id=key, view="image")
        png = base64.b64decode(next(b.data for b in preview.content if b.type == "image"))
        with Image.open(io.BytesIO(png)) as rendered:
            colors = rendered.convert("RGB").getcolors(rendered.width * rendered.height)
            assert sum(n for n, rgb in colors if rgb == (255, 0, 255)) == 0
            assert sum(n for n, rgb in colors if max(rgb) < 100) > 0
        with open_db(home) as db:
            assert not db.execute("SELECT 1 FROM review_observations").fetchone()
        print("Original PNG preserved; outline rendered without the original magenta.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    args = parser.parse_args()
    with TemporaryDirectory() as temp:
        asyncio.run(run(args.binary.resolve(), Path(temp)))
