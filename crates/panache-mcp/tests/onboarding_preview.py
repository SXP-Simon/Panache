# /// script
# dependencies = ["mcp>=1.12,<2", "Pillow"]
# ///
"""Replay a selected preview and compare it with the exported PDF using Poppler."""

import argparse
import asyncio
import base64
import io
import subprocess
from pathlib import Path
from tempfile import TemporaryDirectory

from PIL import Image
from mcp_client import call, isolated_session, open_db


async def run(binary, home):
    async with isolated_session(binary, home) as (client, info):
        for phrase in (
            "a printable page",
            "their own sheet",
            "ink to paste",
            "one short question",
            "Skip this choice for a clear request",
            "larger writing or lighter ink",
            "export the version the user chose",
        ):
            assert phrase in info.instructions
        saved = await call(
            client, "save_section", markdown="观察记录：树上的鸟。", style={"seed": 31}
        )
        key = {"draft_id": saved.structuredContent["draft_id"]}
        images = []
        for rev, size in ((1, None), (2, 48), (3, 24)):
            if size is not None:
                await call(
                    client,
                    "tune_handwriting",
                    **key,
                    expected_revision=rev - 1,
                    changes={"font_size": size},
                )
            result = await call(client, "preview_handwriting", **key, revision=rev, view="image")
            data = next(block.data for block in result.content if block.type == "image")
            with Image.open(io.BytesIO(base64.b64decode(data))) as image:
                images.append(image.convert("RGB").tobytes())
        exported = await call(client, "export_handwriting", **key, revision=2, format="pdf")
        assert exported.structuredContent["revision"] == 2
        subprocess.run(
            ["pdfimages", "-png", exported.structuredContent["path"], str(home / "page")],
            check=True,
        )
        with Image.open(home / "page-000.png") as image:
            pixels = image.convert("RGB").tobytes()
        assert len(set(images)) == 3 and pixels == images[1]
        with open_db(home) as db:
            assert not db.execute("SELECT 1 FROM review_observations").fetchone()
        print(
            "Handshake includes the three choices; PDF matches selected r2 only; zero review records."
        )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    args = parser.parse_args()
    with TemporaryDirectory() as temp:
        asyncio.run(run(args.binary.resolve(), Path(temp)))
