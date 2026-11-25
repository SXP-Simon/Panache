# /// script
# requires-python = ">=3.11"
# dependencies = ["mcp>=1.12,<2", "Pillow"]
# ///
"""Exercise a plain-paragraph edit and image preservation over real MCP stdio."""
import argparse
import asyncio
import base64
from contextlib import closing
import io
import os
from pathlib import Path
import sqlite3
from tempfile import TemporaryDirectory

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from PIL import Image, ImageDraw


def inline_picture():
    image = Image.new("RGB", (124, 68), "white")
    ImageDraw.Draw(image).rectangle((17, 14, 106, 51), fill=(20, 91, 183))
    data = io.BytesIO()
    image.save(data, format="PNG")
    return "![blue rectangle](data:image/png;base64," + base64.b64encode(data.getvalue()).decode() + ")"


def read_only(home):
    return closing(sqlite3.connect((home / "drafts.sqlite3").as_uri() + "?mode=ro", uri=True))


async def regression(binary, fonts, worker):
    with TemporaryDirectory() as temporary:
        home = Path(temporary).resolve()
        params = StdioServerParameters(
            command=str(binary.resolve()),
            cwd=str(home),
            env={
                **os.environ,
                "PANACHE_MCP_HOME": str(home),
                "PANACHE_USER_FONT_DIR": str(home / "personal"),
                "PANACHE_FONT_DIR": str(fonts.resolve()),
                "PANACHE_MARKDOWN_WORKER": str(worker.resolve()),
            },
        )
        async with stdio_client(params) as streams, ClientSession(*streams) as client:
            await client.initialize()

            async def call(name, **args):
                response = await client.call_tool(name, args)
                assert not response.isError, (name, response.content)
                return response

            async def preview(revision):
                result = await call("preview_handwriting", **key, revision=revision, page=1, view="image")
                block = next(part for part in result.content if part.type == "image")
                return Image.open(io.BytesIO(base64.b64decode(block.data))).convert("RGB")

            async def reject_unchanged(args, expected_error):
                with read_only(home) as db:
                    before = list(db.iterdump())
                result = await client.call_tool("replace_section_text", args)
                assert result.isError and expected_error in result.content[0].text, result.content
                with read_only(home) as db:
                    assert list(db.iterdump()) == before

            old, new = "AFTER COPPER 715", "AFTER SILVER 715"
            picture = inline_picture()
            source = f"BEFORE LANTERN 603\n\n{picture}\n\n{old}"
            saved = (await call("save_section", markdown=source, style={"seed": 43, "font_size": 28})).structuredContent
            key = {"draft_id": saved["draft_id"], "section": 1}
            layout = (await call("preview_handwriting", **key, revision=1, page=1, view="layout",
                                 illustrations_only=True)).structuredContent
            glyph = next(row for row in layout["glyphs"] if row["kind"] == "illustration")
            x, y, w, h = glyph["bounds"]
            box = (x, y, x + w, y + h)
            before = await preview(1)
            assert min(before.crop(box).tobytes()) < 120

            args = {**key, "expected_revision": 1, "old_text": old, "new_text": new}
            result = (await call("replace_section_text", **args)).structuredContent
            assert result["revision"] == 2 and result["section"] == 1
            after = await preview(2)
            assert before.crop(box).tobytes() == after.crop(box).tobytes()
            assert before.tobytes() != after.tobytes()
            with read_only(home) as db:
                rows = db.execute("SELECT revision,source,prepared FROM sections ORDER BY revision").fetchall()
            assert len(rows) == 2 and rows[0][:2] == (1, source) and rows[1][:2] == (2, source[:-len(old)] + new)
            assert picture in rows[0][2] and picture in rows[1][2]
            assert rows[1][2] == rows[0][2].replace(old, new, 1)

            await reject_unchanged(args, "revision")
            duplicate = (await call("save_section", markdown="WORD\n\nOTHER WORD")).structuredContent
            await reject_unchanged({"draft_id": duplicate["draft_id"], "section": 1,
                                    "expected_revision": 1, "old_text": "WORD", "new_text": "OTHER"}, "ambiguous")

            for markdown, expected_error in [
                ("踏青真好。\n\n春天", "Unsupported markup"),
                ("春天\n\n初春天气", "ambiguous"),
            ]:
                draft = (await call("save_section", markdown=markdown)).structuredContent
                await reject_unchanged(
                    {"draft_id": draft["draft_id"], "section": 1, "expected_revision": draft["revision"],
                     "old_text": "春天", "new_text": "秋天"},
                    expected_error,
                )
            print("Verified whole-line replacement, inline image preservation, and unchanged SQLite rows "
                  "after stale, ambiguous, and punctuated-section rejections.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--fonts", required=True, type=Path)
    parser.add_argument("--worker", required=True, type=Path)
    args = parser.parse_args()
    asyncio.run(regression(args.binary, args.fonts, args.worker))
