# /// script
# requires-python = ">=3.11"
# dependencies = ["mcp>=1.12,<2"]
# ///
"""Run a test-only glyph layout witness against a real stdio MCP server.

Set PANACHE_FONT_DIR (including 青叶手写体.ttf) and PANACHE_MARKDOWN_WORKER,
then run: uv run crates/panache-mcp/tests/layout_witness_check.py <binary>
stdout is a JSON report. Exit zero means the frozen fixture and every arm matched.

This example tracks what one connection actually saw, not what its user meant.
It is not authentication, a server policy, or a replacement for revision checks.
"""
import argparse
import asyncio
import hashlib
import json
from importlib.metadata import version
from pathlib import Path
from tempfile import TemporaryDirectory

from mcp_client import clone_home, isolated_session, open_db

OLD, NEW = "春 雨 Z", "明 日 春 雨 Z"
STYLE = {"seed": 42, "font": "青叶手写体.ttf"}
INK = [204, 24, 51]
OLD_IDS = [[0, "春"], [2, "雨"], [4, "Z"]]
NEW_IDS = [[0, "明"], [2, "日"], [4, "春"], [6, "雨"], [8, "Z"]]


def ok(result):
    if result.isError or not isinstance(result.structuredContent, dict):
        raise ValueError(f"Expected structured success: {result.content!r}")
    return result.structuredContent


def positions(layout):
    return [[g["id"], g["text"], g["bounds"]] for g in layout["glyphs"]]


def snapshot(home):
    # Logical DB contents, not SQLite/WAL file bytes. One read transaction.
    with open_db(home) as db:
        db.execute("BEGIN")
        digest = hashlib.sha256()
        for line in db.iterdump():
            digest.update((line + "\n").encode())
        return {"logical_sha256": digest.hexdigest(),
                "revision": db.execute("SELECT revision FROM drafts").fetchone()[0],
                "sources": db.execute("SELECT revision,source FROM sections ORDER BY revision").fetchall(),
                "edits": db.execute("SELECT revision FROM glyph_edits ORDER BY revision").fetchall(),
                "reviews": db.execute("SELECT count(*) FROM review_observations").fetchone()[0]}


class Witness:
    """Only actor-side successful preview(layout) calls feed this instance."""

    def __init__(self):
        self.seen = {}

    def observe(self, args, response):
        data = response.structuredContent
        if args.get("view") != "layout" or response.isError or not isinstance(data, dict):
            return
        keys = ("draft_id", "revision", "section", "page")
        if not isinstance(data.get("draft_id"), str) or any(
            type(data.get(k)) is not int or data[k] < 1 for k in keys[1:]
        ):
            return
        if any(data[k] != args.get(k) for k in ("draft_id", "section", "page")):
            return
        if "revision" in args and args["revision"] != data["revision"]:
            return
        rows = data.get("glyphs")
        if not isinstance(rows, list):
            return
        key = tuple(data[k] for k in keys)
        self.seen.setdefault(key, set()).update(
            g["id"] for g in rows if isinstance(g, dict) and type(g.get("id")) is int and g["id"] >= 0
        )

    def admits(self, args):
        numbers = [args.get(k) for k in ("expected_revision", "section", "page")]
        if not isinstance(args.get("draft_id"), str) or any(type(i) is not int or i < 1 for i in numbers):
            return False
        ids = args.get("ids")
        if not isinstance(ids, list) or not 1 <= len(ids) <= 32 or any(type(i) is not int or i < 0 for i in ids):
            return False
        return len(set(ids)) == len(ids) and set(ids) <= self.seen.get((args["draft_id"], *numbers), set())


async def seed(binary, home):
    async with isolated_session(binary, home) as (c, _):
        async def call(tool, **args):
            return ok(await c.call_tool(tool, args))

        saved = await call("save_section", title="合成试稿", markdown=OLD, style=STYLE)
        key = {"draft_id": saved["draft_id"], "section": 1, "page": 1}
        old = await call("preview_handwriting", **key, view="layout", revision=1, limit=32)
        replaced = await call("save_section", draft_id=key["draft_id"], section=1, expected_revision=1, markdown=NEW)
        new = await call("preview_handwriting", **key, view="layout", revision=2, limit=32)
        if ([r[:2] for r in positions(old)] != OLD_IDS or [r[:2] for r in positions(new)] != NEW_IDS):
            raise ValueError(f"Fixture glyphs changed: {positions(old)}, {positions(new)}")
        seeded = await call("adjust_glyphs", **key, expected_revision=2, ids=[8], dx=1)
        if [r["revision"] for r in (saved, old, replaced, new, seeded)] != [1, 1, 2, 2, 3]:
            raise ValueError("Unexpected setup revisions")
        current = await call("preview_handwriting", **key, view="layout", limit=32)
        if current["revision"] != 3 or [r[:2] for r in positions(current)] != NEW_IDS:
            raise ValueError("Independent edit changed glyph identity")
        return key, {"style": STYLE, "sources": [OLD, NEW], "old_positions": positions(old),
                     "prepended_positions": positions(new), "current_positions": positions(current),
                     "seed_edit": {"revision": 3, "id": 8, "dx": 1}}


# Layouts are (revision, offset, limit); expected color rows are (glyph id, text).
OLD_READ = [(1, 0, 3)]
FIRST = [(None, 0, 3)]                 # sees 0,2,4
BOTH = FIRST + [(3, 3, 2)]           # next slice sees 6,8; neither alone covers 4,6
CASES = [
    ("unguarded", OLD_READ, [0], {}, "ok", [[0, "明"]]),
    ("old_only", OLD_READ, [0], {}, "blocked", []),
    ("partial_batch", FIRST, [4, 6], {}, "blocked", []),
    ("combined_slices", BOTH, [4, 6], {}, "ok", [[4, "春"], [6, "雨"]]),
    ("different_page", BOTH, [4], {"page": 2}, "blocked", []),
    ("different_section", BOTH, [4], {"section": 2}, "blocked", []),
    ("different_draft", BOTH, [4], {"draft_id": "other"}, "blocked", []),
    ("stale_expected", [(2, 0, 3)], [4], {"expected_revision": 2}, "revision_conflict", []),
    ("wrong_observed_intent", BOTH, [0], {}, "ok", [[0, "明"]]),
]


async def replay(binary, home, key, case, frozen, fixture):
    name, slices, ids, overrides, want, colors = case
    witness, calls = Witness(), []
    async with isolated_session(binary, home) as (c, _):
        before = snapshot(home)
        for revision, offset, limit in slices:
            args = dict(key, view="layout", offset=offset, limit=limit)
            if revision is not None:
                args["revision"] = revision
            res = await c.call_tool("preview_handwriting", args)
            witness.observe(args, res)
            layout = ok(res)
            calls.append({"tool": "preview_handwriting", "args": args, "revision": layout["revision"],
                          "positions": positions(layout), "next_offset": layout["next_offset"]})

        args = dict(key, expected_revision=3, ids=ids, color="#cc1833") | overrides
        outcome, detail = "blocked", None
        if name == "unguarded" or witness.admits(args):
            res = await c.call_tool("adjust_glyphs", args)
            if res.isError:
                detail = " ".join(b.text for b in res.content if b.type == "text")
                outcome = "revision_conflict" if "Revision conflict" in detail else "tool_error"
            else:
                detail, outcome = ok(res), "ok"
        calls.append({"tool": "adjust_glyphs", "args": args, "outcome": outcome, "result": detail})

        # Independent current-layout oracle: never supplied to the actor's witness.
        layout = ok(await c.call_tool("preview_handwriting", dict(key, view="layout", limit=32)))
        actual = [[g["id"], g["text"]] for g in layout["glyphs"] if g.get("adjustment", {}).get("color") == INK]
        z_dx = next(g for g in layout["glyphs"] if g["id"] == 8).get("adjustment", {}).get("dx")
    after = snapshot(home)
    written = want == "ok"
    expected = {"outcome": want, "colored": colors, "revision": 3 + written, "logical_state_same": not written}
    observed = {"outcome": outcome, "colored": actual, "revision": after["revision"],
                "logical_state_same": before == after}
    by_revision = {1: fixture["old_positions"], 2: fixture["prepended_positions"], 3: fixture["current_positions"]}
    checks = {"same_start": before == frozen, "outcome": observed == expected,
              "source_history": after["sources"] == [(1, OLD), (2, NEW)],
              "edit_versions": after["edits"] == ([(3,), (4,)] if written else [(3,)]),
              "edit_receipt": not written or (detail == {"draft_id": key["draft_id"], "revision": 4, "count": len(ids)}),
              "no_reviews": after["reviews"] == 0, "seed_dx_preserved": z_dx == 1,
              "oracle_scope": all(layout[k] == v for k, v in key.items()) and layout["revision"] == after["revision"],
              "layout_slices": all(
                  e["revision"] == (rev or 3) and e["positions"] == by_revision[rev or 3][off:off + lim]
                  for e, (rev, off, lim) in zip(calls, slices))}
    return {"case": name, "calls": calls, "expected": expected, "observed": observed, "checks": checks,
            "after_sha256": after["logical_sha256"], "pass": all(checks.values())}


async def run(binary):
    binary = binary.resolve(strict=True)
    with binary.open("rb") as f:
        digest = hashlib.file_digest(f, "sha256").hexdigest()
    with TemporaryDirectory() as tmp:
        root = Path(tmp).resolve()
        key, fixture = await seed(binary, root)
        frozen = snapshot(root)
        arms = []
        for i, case in enumerate(CASES):
            home = clone_home(root, str(i))
            arms.append(await replay(binary, home, key, case, frozen, fixture))
    passed = frozen["revision"] == 3 and all(a["pass"] for a in arms)
    print(json.dumps({"kind": "glyph_layout_witness", "binary_sha256": digest, "mcp_sdk": version("mcp"),
                      "fixture": fixture | key, "frozen_sql": frozen, "arms": arms, "pass": passed}, ensure_ascii=False))
    return 0 if passed else 1


if __name__ == "__main__":
    cli = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    cli.add_argument("binary", type=Path)
    raise SystemExit(asyncio.run(run(cli.parse_args().binary)))
