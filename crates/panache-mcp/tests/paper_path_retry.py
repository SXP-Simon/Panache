# /// script
# dependencies = ["mcp>=1.12,<2", "Pillow"]
# ///
"""Retry an unavailable worksheet after a local transfer."""

import base64
import io
import shutil

from PIL import Image, ImageChops
import argparse
import asyncio
from pathlib import Path
from tempfile import TemporaryDirectory

from mcp_client import call, isolated_session, open_db


async def run(binary, home):
    async with isolated_session(binary, home) as (client, info):
        path = home / "作业 纸.png"
        args = dict(markdown="观察记录", style={"seed": 31}, paper_path=str(path))
        with open_db(home) as db:
            original = list(db.iterdump())
        for unavailable in (str(path), "https://example.invalid/worksheet.png"):
            failure = await client.call_tool("save_section", {**args, "paper_path": unavailable})
            assert failure.isError and "computer running Panache" in failure.content[0].text
            with open_db(home) as db:
                assert list(db.iterdump()) == original
        shutil.copyfile(Path(__file__).parent / "fixtures/ruled.png", path)
        result = (await call(client, "save_section", **args)).structuredContent
        assert result["revision"] == 1
        preview = await call(
            client, "preview_handwriting", draft_id=result["draft_id"], view="image"
        )
        png = base64.b64decode(next(b.data for b in preview.content if b.type == "image"))
        with Image.open(io.BytesIO(png)) as page, Image.open(path) as sheet:
            assert page.size == sheet.size
            delta = ImageChops.difference(page.convert("RGB"), sheet.convert("RGB"))
            area = sheet.width * sheet.height
            unchanged = sum(n for n, rgb in delta.getcolors(area) if rgb == (0, 0, 0))
            assert area * 0.95 < unchanged < area
        print(
            f"Two unavailable inputs left the draft store unchanged; {unchanged}/{area} original pixels retained."
        )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    args = parser.parse_args()
    with TemporaryDirectory() as temp:
        asyncio.run(run(args.binary.resolve(), Path(temp)))
