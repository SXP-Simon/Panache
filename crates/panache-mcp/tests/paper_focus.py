"""Verify native paper/ink focus crops through the public tools, including a read-only connection."""

import argparse
import asyncio
import base64
import io
import json
import os
from pathlib import Path
from tempfile import TemporaryDirectory

from mcp_client import call, isolated_session, open_db
from PIL import Image, ImageChops, ImageDraw, ImageFilter


def graded_paper(path):
    paper = Image.new("RGB", (640, 480), "#f2f0e9")
    draw = ImageDraw.Draw(paper)
    for y in range(20, 470, 26):
        draw.line((0, y, 639, y), fill="#626260", width=6)
    # The blur radius changes gradually across the sheet. No gradient in the base ink color.
    soft = paper.filter(ImageFilter.GaussianBlur(2.8))
    mask = Image.new("L", paper.size)
    mask.putdata(
        [
            max(0, min(255, (x - 140) * 255 // 360))
            for _ in range(480)
            for x in range(640)
        ]
    )
    paper = Image.composite(soft, paper, mask)
    paper.save(path)
    return paper


async def verify(client, home):
    path = home / "graded-focus.png"
    paper = graded_paper(path)
    saved = (
        await call(
            client,
            "save_section",
            markdown="局部作业复核。\n\n比较笔迹和底纸。",
            paper_path=str(path),
            style={"seed": 41},
        )
    ).structuredContent
    key = {"draft_id": saved["draft_id"], "revision": 1}
    assert "png_finish_comparison" not in saved
    check = saved["paper_focus_check"]
    assert check["status"] == "spatial_variation", check
    assert [p["role"] for p in check["regions"][:2]] == [
        "narrower_edges",
        "broader_edges",
    ]
    clear, soft = check["regions"][:2]
    assert soft["median_edge_width_px"] > clear["median_edge_width_px"] + 1
    assert (
        clear["preview_arguments"]["region"][0][0]
        < soft["preview_arguments"]["region"][0][0]
    )
    assert len(check["regions"]) == 3
    image = await call(client, "preview_handwriting", **key)
    assert "png_finish_comparison" not in image.structuredContent
    assert image.structuredContent["paper_focus_check"] == check
    with open_db(home) as db:

        def count():
            return db.execute(
                "SELECT count(*) FROM review_observations WHERE draft=?",
                (key["draft_id"],),
            ).fetchone()[0]

        assert count() == 0
        pairs = None
        for sample in check["regions"]:
            args = sample["preview_arguments"]
            assert args["draft_id"] == key["draft_id"] and args["revision"] == 1
            assert (args["section"], args["page"], args["view"]) == (1, 1, "review")
            local = await call(client, "preview_handwriting", **args)
            if pairs is None:
                pairs = local.structuredContent["png_finish_comparison"]
            assert local.structuredContent["png_finish_comparison"] == pairs
            assert json.loads(local.content[0].text)["png_finish_comparison"] == pairs
            assert "png_finish_comparison" in local.structuredContent["next_step"]
            imgs = [
                Image.open(io.BytesIO(base64.b64decode(p.data))).convert("RGB")
                for p in local.content
                if p.type == "image"
            ]
            (x0, y0), _, (x1, y1), _ = args["region"]
            assert len(imgs) == 2 and imgs[0].size == imgs[1].size == (x1 - x0, y1 - y0)
            assert (
                ImageChops.difference(imgs[0], paper.crop((x0, y0, x1, y1))).getbbox()
                is None
            )
        assert count() == 0
        result = await call(client, "preview_handwriting", **key, view="review")
        fresh = result.structuredContent
        first, _ = json.JSONDecoder().raw_decode(result.content[0].text)
        assert first["png_finish_comparison"] == pairs
        assert "png_finish_comparison" in first["photo_appearance"]["png_finish_guidance"]
        assert "png_finish_comparison" in first["next_step"]
        assert fresh["paper_focus_check"] == check and count() == 1
        assert fresh["png_finish_comparison"] == pairs
        gradient = pairs["softer_area"]["gradient"]["export_blur_gradient"]
        for area, sample, endpoint, strength in [
            ("softer_area", soft, "from", 0.8), ("sharper_area", clear, "to", 0)
        ]:
            x, y = sample["sample_point"]
            assert gradient[endpoint] == {
                "x": x / (paper.width - 1), "y": y / (paper.height - 1), "sigma_px": strength
            }
            baseline = pairs[area]["clear"]
            assert baseline == {**sample["preview_arguments"], "view": "image", "export_blur_px": 0}
            assert pairs[area]["gradient"] == {
                **sample["preview_arguments"], "view": "image", "export_blur_gradient": gradient
            }
            for mode in ["clear", "gradient"]:
                preview = await call(client, "preview_handwriting", **pairs[area][mode])
                assert "png_finish_comparison" not in preview.structuredContent
                assert preview.structuredContent["image_size"] == [240, 160]
        assert count() == 1
        archived = (
            await call(
                client,
                "read_section",
                draft_id=key["draft_id"],
                view="review",
                review_id=fresh["review_id"],
            )
        ).structuredContent
        assert (
            "paper_focus_check" not in archived
            and "paper_focus_check" not in archived["evidence"]
        )
    return key, check


async def main(exe):
    with TemporaryDirectory() as temp:
        home = Path(temp)
        async with isolated_session(exe, home) as (client, _):
            key, check = await verify(client, home)
        # The immutable photo supplies the same result on a new server without a stored focus report.
        from mcp import ClientSession, StdioServerParameters
        from mcp.client.stdio import stdio_client

        env = {"PANACHE_MCP_HOME": str(home), "PANACHE_MCP_PRESERVE_REVIEWS": "1"}
        for name in ("PANACHE_FONT_DIR", "PANACHE_MARKDOWN_WORKER"):
            if name in os.environ:
                env[name] = os.environ[name]
        params = StdioServerParameters(command=str(exe), cwd=str(home), env=env)
        async with stdio_client(params) as streams, ClientSession(*streams) as client:
            await client.initialize()
            img = await call(client, "preview_handwriting", **key)
            assert img.structuredContent["paper_focus_check"] == check
            for ref in check["regions"]:
                await call(client, "preview_handwriting", **ref["preview_arguments"])
            with open_db(home) as db:
                assert (
                    db.execute("SELECT count(*) FROM review_observations").fetchone()[0]
                    == 1
                )
        print([(s["role"], s.get("median_edge_width_px")) for s in check["regions"]])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    asyncio.run(main(parser.parse_args().binary.resolve()))
