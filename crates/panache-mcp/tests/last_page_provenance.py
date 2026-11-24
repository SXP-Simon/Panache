# /// script
# requires-python = ">=3.11"
# dependencies = ["mcp>=1.12,<2", "fonttools"]
# ///
"""Repaginate old text after an external font replacement, then check saved receipts."""

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


def font(advance, tip=0):
    builder = FontBuilder(1000, isTTF=True)
    names = [".notdef", "space", "letter"]
    builder.setupGlyphOrder(names)
    builder.setupCharacterMap({32: "space", 65: "letter"})
    glyphs = {}
    for name in names:
        pen = TTGlyphPen(None)
        if name != "space":
            pen.moveTo((50, 20))
            pen.lineTo((advance // 4, 700))
            pen.lineTo((advance, 700 - tip))
            pen.closePath()
        glyphs[name] = pen.glyph()
    builder.setupGlyf(glyphs)
    builder.setupHorizontalMetrics({name: (advance, 0) for name in names})
    builder.setupHorizontalHeader(ascent=800, descent=-200)
    builder.setupNameTable({"familyName": "Synthetic", "styleName": "Regular"})
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
            "review_observations", "review_feedback",
        )]


def old_database_rows(home, draft):
    # Model an old database at migration, not a proposed archive-write workflow.
    with closing(sqlite3.connect(home / "drafts.sqlite3")) as db, db:
        db.execute("CREATE TABLE page_reviews(draft TEXT NOT NULL,revision INTEGER NOT NULL,"
                   "section INTEGER NOT NULL,page INTEGER NOT NULL,evidence TEXT NOT NULL,"
                   "PRIMARY KEY(draft,revision,section,page))")
        db.executemany("INSERT INTO page_reviews VALUES(?,?,?,?,?)", [
            (draft, 2, 1, 4, '{"visibility":"inspect_visually"}'),
            (draft, 2, 2, 1, '{"visibility":"inspect_visually"}'),
        ])


async def read(client, **params):
    result = await call(client, "read_section", view="review", **params)
    assert all(c.type == "text" for c in result.content)
    return result


def repaginated(result, numeric):
    actual, direct = result.structuredContent, numeric.structuredContent
    assert actual["page_resolution"] == {
        "source": "repaginated_current_environment",
        "historical_last_page_confirmed": False,
    }
    assert "当前环境重新分页" in actual["receipt_summary"]
    assert "不能证明这是当时的末页" in actual["receipt_summary"]
    assert actual["receipt_summary"].endswith(direct["receipt_summary"])
    assert result.content[0].text.startswith(actual["receipt_summary"])
    assert {k: v for k, v in actual.items()
            if k not in {"page_resolution", "other_recorded_reviews", "receipt_summary"}} == {
                k: v for k, v in direct.items() if k != "receipt_summary"
            }
    return actual


async def main(args, home):
    baseline = args.baseline or args.binary
    path = home / "fonts" / "霞鹜文楷.ttf"
    path.parent.mkdir()
    narrow, wide = font(500), font(1700)
    path.write_bytes(narrow)
    body = " ".join(["AAAA"] * 680)
    text = "实验补记唯一标志"
    async with server(baseline, args.worker, home) as client:
        save = (await call(client, "save_section", markdown=body,
                           style={"seed": 31, "font_size": 33})).structuredContent
        key = dict(draft_id=save["draft_id"])
        slot = dict(key, section=1)
        await call(client, "save_section", **key, expected_revision=1, markdown="AAAA")
        last = dict(slot, revision=2, page="last")

    before = stored(home)
    async with server(args.binary, args.worker, home, preserve=True) as client:
        empty = await read(client, **last)
        old_page = empty.structuredContent["page"]
        assert old_page >= 5
        e = repaginated(empty, await read(client, **{**last, "page": old_page}))
        assert e["status"] == "no_recorded_review"
        assert e["other_recorded_reviews"] == {"entries": [], "truncated": False}
    assert stored(home) == before

    anchored = dict(slot, before_text=text, page="last")
    async with server(baseline, args.worker, home) as client:
        a = (await call(client, "preview_handwriting", **slot, view="review",
                        revision=2, page=old_page)).structuredContent
        assert a["filed_at_revision"] == 2
        await call(client, "save_section", **key, expected_revision=2, section=2, markdown=text)
    old_database_rows(home, key["draft_id"])

    async with server(baseline, args.worker, home, preserve=True) as client:
        direct_old = await read(client, **{**anchored, "page": old_page})
        pinned_old = await read(client, **key, review_id=a["review_id"])
        legacy_numeric = await read(client, **key, revision=2, section=2, page=1)
        assert legacy_numeric.structuredContent["filed_at_revision"] is None
    before = stored(home)
    async with server(args.binary, args.worker, home, preserve=True) as client:
        match = repaginated(await read(client, **anchored), direct_old)
        assert match["before_text_match"] == {"introduced_revision": 3, "section": 2}
        assert match["review_id"] == a["review_id"] and "other_recorded_reviews" not in match
        legacy = repaginated(await read(client, **{**last, "section": 2}), legacy_numeric)
        assert "旧单" in legacy["receipt_summary"] and "可能是事后补验" in legacy["receipt_summary"]
    assert stored(home) == before

    path.write_bytes(wide)
    async with server(baseline, args.worker, home, preserve=True) as client:
        old_behavior = await read(client, **anchored)
        new_page = old_behavior.structuredContent["page"]
        assert new_page > old_page and new_page > 11
        missing_new = await read(client, **{**anchored, "page": new_page})
        if args.baseline:
            assert old_behavior == missing_new
    async with server(args.binary, args.worker, home, preserve=True) as client:
        miss = repaginated(await read(client, **anchored), missing_new)
        assert miss["revision"] == 2 and miss["section"] == 1 and miss["page"] == new_page
        assert miss["review_id"] is None and "没有已存" in miss["receipt_summary"]
        hints = miss["other_recorded_reviews"]
        assert not hints["truncated"] and [h["page"] for h in hints["entries"]] == [old_page, 4]
        assert hints["entries"][0]["review_id"] == a["review_id"]
        assert hints["entries"][0]["filed_at_revision"] == 2
        assert hints["entries"][1]["filed_at_revision"] is None
        assert await read(client, **key, review_id=hints["entries"][0]["review_id"]) == pinned_old
        assert await read(client, **{**anchored, "page": old_page}) == direct_old
        assert "不代表当时的末页" in (await read(client, **anchored)).content[0].text
        by_revision = (await read(client, **last)).structuredContent
        assert {k: v for k, v in miss.items() if k != "before_text_match"} == by_revision
    assert stored(home) == before

    # Add real competing checks outside the exact scope, and six real pages inside it.
    async with server(baseline, args.worker, home) as client:
        await call(client, "preview_handwriting", **slot, revision=3, view="review", page=18)
        foreign = (await call(client, "save_section", markdown=body,
                              style={"seed": 31, "font_size": 33})).structuredContent["draft_id"]
        await call(client, "save_section", draft_id=foreign, expected_revision=1, markdown="AAAA")
        await call(client, "preview_handwriting", draft_id=foreign, revision=2, view="review", page=17)
        expected = {}
        for page in (10, 9, 8, 7, 6, 3):
            entry = (await call(client, "preview_handwriting", **slot, revision=2,
                                view="review", page=page)).structuredContent
            expected[page] = entry["review_id"]
    path.write_bytes(font(1700, 300))
    async with server(baseline, args.worker, home) as client:
        newer = (await call(client, "preview_handwriting", **slot, revision=2,
                            view="review", page=10)).structuredContent
        assert newer["review_id"] != expected[10]
        expected[10] = newer["review_id"]
    before = stored(home)
    async with server(args.binary, args.worker, home, preserve=True) as client:
        capped = repaginated(await read(client, **anchored), missing_new)["other_recorded_reviews"]
        assert capped["truncated"]
        assert [(e["page"], e["review_id"]) for e in capped["entries"]] == list(expected.items())[:5]
        assert await read(client, **key, review_id=a["review_id"]) == pinned_old
    assert stored(home) == before

    # A subsequently filed receipt at the new page must not retroactively prove the old last.
    async with server(baseline, args.worker, home) as client:
        late = (await call(client, "preview_handwriting", **slot, view="review",
                           revision=2, page=new_page)).structuredContent
    before = stored(home)
    async with server(args.binary, args.worker, home, preserve=True) as client:
        hit = repaginated(await read(client, **anchored),
                          await read(client, **{**anchored, "page": new_page}))
        assert hit["review_id"] == late["review_id"] != a["review_id"]
        assert hit["filed_at_revision"] == 3 and "事后补验" in hit["receipt_summary"]
        assert "other_recorded_reviews" not in hit
    assert stored(home) == before

    path.write_bytes(narrow)
    async with server(args.binary, args.worker, home, preserve=True) as client:
        again = repaginated(await read(client, **anchored), direct_old)
        assert again["page"] == old_page and again["review_id"] == a["review_id"]
    assert stored(home) == before
    print(json.dumps({
        "original_page": old_page, "repaginated_page": new_page,
        "original_receipt": a["review_id"], "late_receipt": late["review_id"],
        "distinct_hints": [e["page"] for e in capped["entries"]],
        "no_record_empty_hint": True, "legacy_filing_revision_null": True,
        "all_selected_reads_leave_rows_unchanged": True,
    }))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("worker", type=Path)
    parser.add_argument("--baseline", type=Path)
    args = parser.parse_args()
    args.binary, args.worker = args.binary.resolve(), args.worker.resolve()
    if args.baseline:
        args.baseline = args.baseline.resolve()
    with TemporaryDirectory(prefix="panache-last-page-") as tmp:
        asyncio.run(main(args, Path(tmp)))
