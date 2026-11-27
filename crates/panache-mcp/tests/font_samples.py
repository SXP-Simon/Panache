"""Compare MCP font sample pixels to the same photo before and after adopting a face."""

import base64
import io
from pathlib import Path

from PIL import Image

from mcp_client import call


def images(result):
    return [
        Image.open(io.BytesIO(base64.b64decode(block.data, validate=True))).convert("RGBA")
        for block in result.content if block.type == "image"
    ]


async def check(client, local_font):
    paper = Path(__file__).resolve().parent / "fixtures" / "ruled.png"
    current = "志莽行书.ttf"
    draft = (await call(
        client, "save_section", markdown="溶液 NaCl 25 mL", paper_path=str(paper),
        style={"font": current, "homework": True, "seed": 79},
    )).structuredContent
    key = {"draft_id": draft["draft_id"]}
    sample = {**key, "revision": 1, "fonts": [local_font], "crop": [12, 10, 376, 210]}
    before = images(await call(client, "preview_handwriting", **key))[0]
    result = await call(client, "list_fonts", sample=sample)
    meta = result.structuredContent
    assert meta["current_font"] == current and meta["native_size"] == [400, 500]
    assert "同一句" in meta["content_note"] and meta["content_note"] in result.content[0].text
    assert "placement_note" not in meta and "background_note" not in meta
    assert meta["sample_size"] == [376, 210]
    assert [row["font"] for row in meta["samples"]] == [current, local_font]
    assert [b.type for b in result.content] == ["text", "text", "image", "text", "image"]
    actual, candidate = images(result)
    bounds = (12, 10, 388, 220)
    assert actual.tobytes() == before.crop(bounds).tobytes()
    assert candidate.tobytes() != actual.tobytes()
    for invalid in [{"fonts": [current] * 3}, {"crop": [395, 0, 6, 1]}]:
        assert (await client.call_tool("list_fonts", {"sample": {**sample, **invalid}})).isError
    pinned = await call(client, "preview_handwriting", **key)
    assert pinned.structuredContent["revision"] == 1 and pinned.structuredContent["cached"]
    assert images(pinned)[0].tobytes() == before.tobytes()
    assert "tune_arguments" not in meta["samples"][0]
    applied = await call(client, "tune_handwriting", **meta["samples"][1]["tune_arguments"])
    assert applied.structuredContent["revision"] == 2
    after = images(await call(client, "preview_handwriting", **key))[0]
    assert after.crop(bounds).tobytes() == candidate.tobytes()

    layout = (await call(client, "preview_handwriting", **key, view="layout", limit=1)).structuredContent
    gid = layout["glyphs"][0]["id"]
    await call(client, "adjust_glyphs", **key, expected_revision=2, section=1, page=1, ids=[gid], dx=11)
    placed = images(await call(client, "preview_handwriting", **key))[0].crop(bounds)
    assert placed.tobytes() != candidate.tobytes()
    await call(client, "tune_handwriting", **key, expected_revision=3, changes={"transparent_background": True})
    resampled = await call(client, "list_fonts", sample={**sample, "revision": 4, "fonts": [current]})
    meta = resampled.structuredContent
    for note in ("placement_note", "background_note"):
        assert meta[note] in resampled.content[0].text
    sampled_current, alternate = images(resampled)
    assert sampled_current.tobytes() == placed.tobytes()
    assert alternate.tobytes() == actual.tobytes()
    protected = await client.call_tool("tune_handwriting", meta["samples"][1]["tune_arguments"])
    assert protected.isError and "local glyph adjustments" in protected.content[0].text
    regular = await call(client, "preview_handwriting", **key)
    assert regular.structuredContent["revision"] == 4
    assert images(regular)[0].getchannel("A").getextrema()[0] == 0

    await check_missing_candidate_page(client)


async def check_missing_candidate_page(client):
    draft = (await call(
        client, "save_section", markdown=" ".join(["WWW"] * 75), style={"font": "青叶手写体.ttf", "seed": 79},
    )).structuredContent
    key = {"draft_id": draft["draft_id"]}
    await call(client, "tune_handwriting", **key, expected_revision=1, changes={
        "width": 330, "height": 320, "top_margin": 20, "bottom_margin": 22, "left_margin": 20, "right_margin": 20,
    })
    missing, present = "李国夫手写体.ttf", "霞鹜文楷.ttf"
    result = await call(client, "list_fonts", sample={**key, "page": 7, "fonts": [missing, present]})
    meta = result.structuredContent
    assert len(images(result)) == 2
    assert [row["font"] for row in meta["samples"]] == ["青叶手写体.ttf", present]
    skipped, = meta["unavailable_samples"]
    assert (skipped["font"], skipped["section"], skipped["page"]) == (missing, 1, 7)
    assert skipped["reason"] == "page_missing_after_reflow"
    assert skipped["message"] in [b.text for b in result.content if b.type == "text"]
