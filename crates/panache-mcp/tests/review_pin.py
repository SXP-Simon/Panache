# /// script
# requires-python = ">=3.11"
# dependencies = ["mcp>=1.12,<2", "fonttools"]
# ///
"""Exercise metadata-only review pinning over stdio across bundled-font changes."""

import argparse
import asyncio
import io
import json
import os
import sqlite3
from contextlib import asynccontextmanager, closing
from pathlib import Path
from tempfile import TemporaryDirectory

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

from mcp_client import call


def font(alternate=False):
    """Two equal-sized fonts with different outlines for the same mapped glyph."""
    builder = FontBuilder(1000, isTTF=True)
    names = [".notdef", "space", "letter"]
    builder.setupGlyphOrder(names)
    builder.setupCharacterMap({32: "space", 65: "letter"})
    glyphs = {}
    for name in names:
        pen = TTGlyphPen(None)
        if name != "space":
            pen.moveTo((50, 20))
            pen.lineTo((700, 250) if alternate else (250, 700))
            pen.lineTo((700, 700))
            pen.closePath()
        glyphs[name] = pen.glyph()
    builder.setupGlyf(glyphs)
    builder.setupHorizontalMetrics({name: (850, 0) for name in names})
    builder.setupHorizontalHeader(ascent=800, descent=-200)
    builder.setupNameTable({"familyName": "Review Pin Fixture", "styleName": "Regular"})
    builder.setupOS2(sTypoAscender=800, sTypoDescender=-200, usWinAscent=800, usWinDescent=200)
    builder.setupPost()
    builder.setupMaxp()
    builder.font["head"].created = builder.font["head"].modified = 3800000000
    data = io.BytesIO()
    builder.save(data)
    return data.getvalue()


@asynccontextmanager
async def server(executable, worker, home, preserve=False):
    env = {
        **os.environ,
        "PANACHE_MCP_HOME": str(home),
        "PANACHE_FONT_DIR": str(home / "fonts"),
        "PANACHE_USER_FONT_DIR": str(home / "user"),
        "PANACHE_MARKDOWN_WORKER": str(worker),
        "PANACHE_MCP_PRESERVE_REVIEWS": str(int(preserve)),
    }
    params = StdioServerParameters(command=str(executable), cwd=home, env=env)
    async with stdio_client(params) as streams, ClientSession(*streams) as client:
        await client.initialize()
        yield client


def stored(home):
    with closing(sqlite3.connect(f"file:{home / 'drafts.sqlite3'}?mode=ro", uri=True)) as db:
        return [db.execute(f"SELECT * FROM {table} ORDER BY rowid").fetchall() for table in (
            "drafts", "sections", "settings", "glyph_edits", "edit_notes",
            "camera_revisions", "draft_fonts", "paper_layouts", "papers",
            "review_observations", "review_feedback",
        )]


def deltas(before, after):
    a, b = before["evidence"], after["evidence"]
    return (
        b["changed_pixels_by_image_third"][0] - a["changed_pixels_by_image_third"][0],
        b["max_rgb_delta"] - a["max_rgb_delta"],
    )


def snapshot(result):
    assert all(x.type == "text" for x in result.content)
    return result.structuredContent, [x.text for x in result.content]


async def main(args, home):
    baseline = args.baseline or args.binary
    path = home / "fonts" / "霞鹜文楷.ttf"
    path.parent.mkdir()
    first, second = font(), font(True)
    assert first != second and len(first) == len(second)
    path.write_bytes(first)
    async with server(baseline, args.worker, home) as client:
        saved = await call(client, "save_section", markdown="AAAAAA", style={"seed": 31})
        key = {"draft_id": saved.structuredContent["draft_id"]}
        slot = dict(key, view="review", section=1, page=1)
        a = (await call(client, "preview_handwriting", **slot, revision=1)).structuredContent
        await call(client, "annotate_review", **key, review_id=a["review_id"],
                   origin="user_quote", text="用这一张检查单作基准。")
        await call(client, "tune_handwriting", **key, expected_revision=1,
                   changes={"ink_opacity": 60})

    # A new process renders both revision numbers with the replacement on the same path.
    path.write_bytes(second)
    async with server(baseline, args.worker, home) as client:
        b = (await call(client, "preview_handwriting", **slot, revision=1)).structuredContent
        after = (await call(client, "preview_handwriting", **slot, revision=2)).structuredContent
        await call(client, "annotate_review", **key, review_id=b["review_id"],
                   origin="model_observation", text="这张是后归档的另一张检查单。")
        await call(client, "tune_handwriting", **key, expected_revision=2,
                   changes={"ink_opacity": 80})
        other = (await call(client, "save_section", markdown="AAAAAA")).structuredContent
        foreign = (await call(client, "preview_handwriting", view="review",
                              draft_id=other["draft_id"])).structuredContent["review_id"]
    assert a["pixel_sha256"] != b["pixel_sha256"]
    assert a["page_content_sha256"] == b["page_content_sha256"] == after["page_content_sha256"]
    assert a["review_id"] != b["review_id"] and deltas(a, after) != deltas(b, after)

    # Rereviewing A deduplicates; it does not move A after B in the saved ordering.
    path.write_bytes(first)
    request = dict(slot, revision=2, compare_revision=1)
    polygon = [[10, 10], [240, 10], [10, 180]]
    async with server(baseline, args.worker, home) as client:
        rereview = await call(client, "preview_handwriting", **slot, revision=1)
        assert rereview.structuredContent["review_id"] == a["review_id"]
        for review in (a, b, after):
            rec = await call(client, "read_section", **key, view="review", review_id=review["review_id"])
            assert rec.structuredContent["pixel_sha256"] == review["pixel_sha256"]
        baseline_regions = await call(client, "preview_handwriting", **request, region=polygon)
    assert len([c for c in baseline_regions.content if c.type == "image"]) == 3
    async with server(args.binary, args.worker, home) as client:
        candidate_regions = await call(client, "preview_handwriting", **request, region=polygon)
        assert candidate_regions == baseline_regions

    # Both binaries read exactly the same saved rows with rendering made impossible.
    path.write_bytes(b"not a font")
    before = stored(home)
    async with server(baseline, args.worker, home, preserve=True) as client:
        legacy = snapshot(await call(client, "preview_handwriting", **request))
        assert legacy[0]["before"]["review_id"] == b["review_id"]
        if args.baseline:
            schema = next(t.inputSchema for t in (await client.list_tools()).tools
                          if t.name == "preview_handwriting")
            assert "before_review_id" not in schema["properties"]
            legacy_schema = schema

    async with server(args.binary, args.worker, home, preserve=True) as client:
        schema = next(t.inputSchema for t in (await client.list_tools()).tools
                      if t.name == "preview_handwriting")
        assert "before_review_id" in schema["properties"]
        assert "before_review_id" not in schema.get("required", [])
        if args.baseline:
            assert schema["properties"].pop("before_review_id") == {
                "description": "Pin the earlier stored full-page check by ID. Requires view=review and "
                               "compare_revision, without a region. The check must belong to that "
                               "earlier revision, draft, section and page.",
                "type": ["string", "null"],
            }
            assert json.dumps(schema, sort_keys=True) == json.dumps(legacy_schema, sort_keys=True)
        default = snapshot(await call(client, "preview_handwriting", **request))
        assert default == legacy == snapshot(await call(
            client, "preview_handwriting", **request, before_review_id=None
        ))
        assert legacy == snapshot(await call(
            client, "preview_handwriting", **request, before_review_id=b["review_id"]
        ))

        pin = dict(request, before_review_id=a["review_id"])
        pinned, _ = snapshot(await call(client, "preview_handwriting", **pin))
        assert pinned["before"]["review_id"] == a["review_id"]
        assert pinned["before"]["pixel_sha256"] == a["pixel_sha256"]
        assert pinned["before"]["feedback"] == [
            {"origin": "user_quote", "text": "用这一张检查单作基准。"}
        ]
        assert pinned["after"] == default[0]["after"]
        assert pinned["actions"] == default[0]["actions"]
        assert pinned["comparison"]["limitations"] == []
        observed = []
        for result, old in [(default[0], b), (pinned, a)]:
            delta = result["comparison"]["delta"]
            got = delta["by_image_third"][0]["changed_pixels"], delta["max_rgb_delta"]
            assert got == deltas(old, after)
            observed.append(got)

        paged = dict(pin, revision=3, limit=1)
        page1 = (await call(client, "preview_handwriting", **paged)).structuredContent
        page2 = (await call(client, "preview_handwriting", **paged, offset=1)).structuredContent
        assert page1["before"] == page2["before"] == pinned["before"]
        assert page1["after"] is None and page2["after"] is None
        assert page1["comparison"]["limitations"] == ["missing_after_review"]
        assert [q["actions"][0]["revision"] for q in (page1, page2)] == [2, 3]
        assert page1["next_offset"] == 1 and page2["next_offset"] is None

        bad = [
            ({"fresh": True}, "fresh=true requires view=image"),
            ({"region": polygon}, "unfiltered"),
            ({"previous_region": polygon}, "unfiltered"),
            ({"view": "image"}, "unfiltered"),
            ({"view": "layout"}, "unfiltered"),
            ({"view": "paper"}, "unfiltered"),
            ({"view": None}, "unfiltered"),
            ({"illustrations_only": False}, "unfiltered"),
            ({"compare_revision": None}, "unfiltered"),
            ({"compare_revision": 2}, "earlier revision"),
            ({"section": 2}, "must match"),
            ({"page": 2}, "must match"),
            ({"before_review_id": after["review_id"]}, "must match"),
            ({"before_review_id": foreign}, "Cannot resolve"),
            ({"before_review_id": "unknown"}, "Cannot resolve"),
            ({"before_review_id": ""}, "Cannot resolve"),
        ]
        for changed, error in bad:
            res = await client.call_tool("preview_handwriting", {**pin, **changed})
            assert res.isError and error in res.content[0].text, (changed, res.content)
        image = await client.call_tool("preview_handwriting", {**key, "revision": 1})
        assert image.isError and "invalid_font" in image.content[0].text
    assert stored(home) == before
    print(json.dumps({
        "omitted_before": b["review_id"],
        "pinned_before": a["review_id"],
        "unchanged_after": after["review_id"],
        "delta_fields": ["top_third_changed_pixels", "max_rgb_delta"],
        "omitted_delta": observed[0],
        "pinned_delta": observed[1],
        "unchanged_region_comparison": True,
        "invalid_cases": len(bad),
        "all_draft_and_review_rows_unchanged": True,
    }))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("worker", type=Path)
    parser.add_argument("--baseline", type=Path, help="Compare omitted output on the exact same records.")
    args = parser.parse_args()
    args.binary, args.worker = args.binary.resolve(), args.worker.resolve()
    if args.baseline:
        args.baseline = args.baseline.resolve()
    with TemporaryDirectory(prefix="panache-review-pin-") as tmp:
        asyncio.run(main(args, Path(tmp)))
