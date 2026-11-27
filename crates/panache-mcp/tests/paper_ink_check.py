"""Test local writing-versus-paper contrast on a sheet with pale and dark printed rulings."""

import argparse
import asyncio
import base64
import io
import os
from pathlib import Path
from tempfile import TemporaryDirectory

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from mcp_client import call, isolated_session, open_db
from PIL import Image, ImageDraw


async def verify(client, home):
    path = home / "two-ink-regions.png"
    sheet = Image.new("RGB", (500, 440), (230, 230, 230))
    draw = ImageDraw.Draw(sheet)
    for y in range(16, 435, 20):
        gray = 200 if y < 200 else 45
        draw.line((0, y, 499, y), fill=(gray,) * 3, width=3)
    sheet.save(path)
    saved = await call(
        client,
        "save_section",
        markdown="春夏秋冬东西南北",
        paper_path=str(path),
        paper_guides=[
            {"row": 0, "left": [32, 76], "right": [468, 76]},
            {"row": 14, "left": [32, 356], "right": [468, 356]},
        ],
        style={"font_size": 18, "seed": 35, "ink": "#303030"},
    )
    key = {"draft_id": saved.structuredContent["draft_id"], "section": 1, "page": 1}
    assert saved.structuredContent["photo_ink_preview_arguments"] == {
        **key, "revision": 1, "view": "review"
    }
    for rev, (text, y) in enumerate([("春夏秋冬", 76), ("东西南北", 296)], 1):
        layout = (
            await call(
                client,
                "preview_handwriting",
                **key,
                revision=rev,
                view="layout",
                limit=32,
            )
        ).structuredContent
        ids = [g["id"] for g in layout["glyphs"] if g["text"] in text]
        await call(
            client,
            "adjust_glyphs",
            **key,
            expected_revision=rev,
            ids=ids,
            natural_line={"start": [78, y], "end": [430, y]},
        )
    full = (
        await call(client, "preview_handwriting", **key, revision=3, view="review")
    ).structuredContent
    evidence = full["local_paper_ink_check"]
    top, bottom = evidence["samples"][0], evidence["samples"][-1]
    assert top["role"] == "first_written_row"
    assert top["paper_marks"]["median_luma_drop"] == 30
    assert bottom["paper_marks"]["median_luma_drop"] == 185
    assert (
        top["status"] == "writing_darker_than_sampled_marks"
        and bottom["status"] == "inspect_local_contrast"
    ), evidence
    assert top["clearly_above_paper_p75"] and not bottom["clearly_above_paper_p75"]
    archived = (
        await call(
            client,
            "read_section",
            draft_id=key["draft_id"],
            view="review",
            review_id=full["review_id"],
        )
    ).structuredContent
    assert (
        archived["evidence"]["local_paper_ink"] == full["evidence"]["local_paper_ink"]
    )
    assert (
        "preview_arguments" not in archived["evidence"]["local_paper_ink"]["samples"][0]
    )
    for sample in [top, bottom]:
        local = await call(client, "preview_handwriting", **sample["preview_arguments"])
        mark = local.structuredContent["local_paper_ink_check"]["samples"][0]
        assert (
            mark["paper_marks"]["median_luma_drop"]
            == sample["paper_marks"]["median_luma_drop"]
        )
        source, finished = [
            Image.open(io.BytesIO(base64.b64decode(p.data))).convert("RGB")
            for p in local.content
            if p.type == "image"
        ]
        (x0, y0), _, (x1, y1), _ = sample["region"]
        assert source.size == finished.size == (x1 - x0, y1 - y0)
        assert source.tobytes() == sheet.crop((x0, y0, x1, y1)).tobytes()
    # The local change only affects the selected upper line, leaving the darker reference and lower writing intact.
    glyphs = (
        await call(client, "preview_handwriting", **top["layout_arguments"])
    ).structuredContent["glyphs"]
    await call(
        client,
        "adjust_glyphs",
        **key,
        expected_revision=3,
        ids=[g["id"] for g in glyphs],
        opacity=28,
    )
    revised = (
        await call(client, "preview_handwriting", **key, revision=4, view="review")
    ).structuredContent
    after = revised["local_paper_ink_check"]["samples"]
    assert (
        after[0]["added_writing"]["median_glyph_p90_luma_drop"]
        < top["added_writing"]["median_glyph_p90_luma_drop"] - 35
    )
    assert after[-1]["added_writing"] == bottom["added_writing"]
    await call(
        client,
        "tune_handwriting",
        draft_id=key["draft_id"],
        expected_revision=4,
        changes={"transparent_background": True},
        preserve_local_adjustments=True,
    )
    transparent = (
        await call(client, "preview_handwriting", **key, revision=5, view="review")
    ).structuredContent
    assert transparent["evidence"]["transparent_png"]
    assert "png_finish_comparison" not in transparent
    ref = transparent["local_paper_ink_check"]["samples"][0]
    local = (
        await call(client, "preview_handwriting", **ref["preview_arguments"])
    ).structuredContent
    assert "png_finish_comparison" not in local
    assert (
        ref["paper_marks"]["median_luma_drop"]
        == local["local_paper_ink_check"]["samples"][0]["paper_marks"][
            "median_luma_drop"
        ]
    )
    assert (
        abs(
            ref["added_writing"]["median_glyph_p90_luma_drop"]
            - after[0]["added_writing"]["median_glyph_p90_luma_drop"]
        )
        <= 3
    )
    return key, evidence


async def main(binary):
    with TemporaryDirectory() as temp:
        home = Path(temp)
        async with isolated_session(binary, home) as (client, _):
            key, old = await verify(client, home)
        env = {"PANACHE_MCP_HOME": str(home), "PANACHE_MCP_PRESERVE_REVIEWS": "1"}
        for name in ("PANACHE_FONT_DIR", "PANACHE_MARKDOWN_WORKER"):
            if name in os.environ:
                env[name] = os.environ[name]
        params = StdioServerParameters(command=str(binary), cwd=str(home), env=env)
        async with stdio_client(params) as streams, ClientSession(*streams) as client:
            await client.initialize()
            readonly = (
                await call(client, "preview_handwriting", **key, revision=3)
            ).structuredContent
            assert readonly["local_paper_ink_check"] == old
            await call(
                client, "preview_handwriting", **old["samples"][0]["preview_arguments"]
            )
            with open_db(home) as db:
                assert (
                    db.execute("SELECT count(*) FROM review_observations").fetchone()[0]
                    == 3
                )
        print(
            [
                (
                    s["role"],
                    s["paper_marks"]["median_luma_drop"],
                    s["added_writing"]["median_glyph_p90_luma_drop"],
                    s["status"],
                )
                for s in old["samples"]
            ]
        )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    asyncio.run(main(parser.parse_args().binary.resolve()))
