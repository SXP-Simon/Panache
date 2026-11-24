# /// script
# requires-python = ">=3.11"
# dependencies = ["mcp>=1.12,<2"]
# ///
r"""Replay explicit page-review actions on two copies of one synthetic draft.

From the repository root, with the normal local Worker and fonts installed:
  uv run crates/panache-mcp/tests/trajectory_check.py target/debug/panache-mcp \
      read_section preview_handwriting read_section > trajectory.json

stdout is evidence. Exit 0 means both arms matched their expected outcomes.
Each proposed action consumes a slot, including an action stopped by the host.
Fixture creation, initialize, tools/list and SQLite inspection are outside that budget.
"""

import argparse
import asyncio
import hashlib
import json
import os
import platform
import sqlite3
from contextlib import asynccontextmanager, closing
from copy import deepcopy
from importlib.metadata import version
from pathlib import Path
from tempfile import TemporaryDirectory

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from mcp_client import call

READ_ONLY = {"list_drafts", "read_section"}
FIXTURE = {"markdown": "一页合成试稿。", "style": {"seed": 42, "font": "志莽行书.ttf"}}
DB = "drafts.sqlite3"


@asynccontextmanager
async def session(binary, home):
    assets = {k: str(Path(os.environ[k]).resolve()) for k in
              ("PANACHE_MARKDOWN_WORKER", "PANACHE_FONT_DIR") if k in os.environ}
    env = dict.fromkeys(("HOME", "USERPROFILE", "APPDATA", "LOCALAPPDATA", "XDG_DATA_HOME"), str(home))
    env.update(assets, PANACHE_MCP_HOME=str(home), PANACHE_USER_FONT_DIR=str(home / "fonts"))
    params = StdioServerParameters(command=str(binary), cwd=str(home), env=env)
    async with stdio_client(params) as streams, ClientSession(*streams) as client:
        yield client, await client.initialize()


def catalog(listing):
    raw = listing.model_dump(mode="json", by_alias=True, exclude_unset=True)
    stable = deepcopy(raw)
    ignored = {}
    for index, tool in enumerate(stable["tools"]):
        if tool["name"] != "save_section":
            continue
        seed = tool["inputSchema"]
        for key in ("$defs", "Style", "properties", "seed"):
            seed = seed.get(key, {})
        value = seed.get("default")
        if type(value) is int and 0 <= value < 2**32:
            path = f"/tools/{index}/inputSchema/$defs/Style/properties/seed/default"
            ignored[path] = value
            seed["default"] = "<random u32>"

    def digest(value):
        data = json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
        return hashlib.sha256(data.encode()).hexdigest()

    return {"raw": raw, "raw_sha256": digest(raw), "stable_sha256": digest(stable),
            "ignored_defaults": ignored}


def open_db(home):
    return closing(sqlite3.connect((home / DB).as_uri() + "?mode=ro", uri=True))


def snapshot(home):
    with open_db(home) as db:
        db.execute("BEGIN")
        full, other = hashlib.sha256(), hashlib.sha256()
        for statement in db.iterdump():
            line = (statement + "\n").encode()
            full.update(line)
            if not statement.startswith('INSERT INTO "review_observations" '):
                other.update(line)
        db.row_factory = sqlite3.Row
        return {
            "logical_sha256": full.hexdigest(), "except_review_rows_sha256": other.hexdigest(),
            "drafts": [dict(r) for r in db.execute("SELECT id,revision FROM drafts ORDER BY id")],
            "reviews": [dict(r) for r in db.execute(
                "SELECT draft,revision,section,page,review_id,filed_at_revision "
                "FROM review_observations ORDER BY seq")],
        }


async def replay(binary, home, key, actions, gated):
    events = []
    async with session(binary, home) as (client, info):
        listing = await client.list_tools()
        if listing.nextCursor:
            raise ValueError("Expected the single-page Panache tools/list")
        schema = catalog(listing)
        visible = {tool.name for tool in listing.tools}
        if gated:
            visible &= READ_ONLY
        before = snapshot(home)
        for name in actions:
            event = {"name": name, "arguments": {**key, "view": "review"}}
            events.append(event)
            if name not in visible:
                event["outcome"] = "host_blocked"
                continue
            response = await client.call_tool(name, event["arguments"])
            if response.isError:
                error = [block.model_dump(mode="json", exclude_none=True) for block in response.content]
                event.update(outcome="tool_error", error=error)
            else:
                result = response.structuredContent or {}
                event.update(outcome="ok", result={k: result[k] for k in
                             (*key, "status", "review_id") if k in result})
    after = snapshot(home)
    forwarded = [e for e in events if e["outcome"] != "host_blocked"]
    forbidden = [i for i, e in enumerate(events, 1)
                 if e["outcome"] != "host_blocked" and e["name"] not in READ_ONLY]
    expected_preview = not gated and "preview_handwriting" in actions
    rows = after["reviews"]
    expected_row = {"draft": key["draft_id"], "revision": key["revision"],
                    "section": key["section"], "page": key["page"], "filed_at_revision": key["revision"]}
    seen_id = None
    receipts_match = True
    for event in forwarded:
        result = event.get("result", {})
        if event["name"] == "preview_handwriting":
            seen_id = rows[0]["review_id"] if rows else None
            receipts_match &= bool(seen_id)
        elif seen_id is None:
            receipts_match &= result.get("status") == "no_recorded_review"
        receipts_match &= (result.get("review_id") == seen_id
                           and all(result.get(k) == v for k, v in key.items()))
    checks = {
        "fixture": before["drafts"] == [{"id": key["draft_id"], "revision": 1}] and not before["reviews"],
        "dispatch": all((e["outcome"] == "host_blocked") == (gated and e["name"] not in READ_ONLY)
                        for e in events),
        "tools_succeeded": all(e["outcome"] == "ok" for e in forwarded),
        "receipts_match_sqlite": receipts_match,
        "review_rows": len(rows) == int(expected_preview)
                       and all(all(r[k] == v for k, v in expected_row.items()) for r in rows),
        "other_state_unchanged": before["except_review_rows_sha256"] == after["except_review_rows_sha256"],
    }
    return {
        "server": info.serverInfo.model_dump(exclude_none=True), "protocol": info.protocolVersion,
        "schema": schema, "visible_tools": sorted(visible), "events": events,
        "budget": {"slots": len(actions), "attempted": len(events), "forwarded": len(forwarded),
                   "host_blocked": len(events) - len(forwarded),
                   "tool_errors": sum(e["outcome"] == "tool_error" for e in forwarded)},
        "before": before, "after": after, "checks": checks,
        "read_only_violations": {"forwarded_slots": forbidden,
                                 "sqlite_changed": before["logical_sha256"] != after["logical_sha256"]},
    }


async def run(binary, actions):
    binary = binary.resolve(strict=True)
    with TemporaryDirectory() as tmp:
        root = Path(tmp).resolve()
        async with session(binary, root) as (client, _):
            saved = (await call(client, "save_section", **FIXTURE)).structuredContent
        key = {"draft_id": saved["draft_id"], "revision": saved["revision"], "section": 1, "page": 1}
        arms = {}
        for arm in ("gated", "open"):
            home = root / arm
            home.mkdir()
            with open_db(root) as source, closing(sqlite3.connect(home / DB)) as target:
                source.backup(target)
            arms[arm] = await replay(binary, home, key, actions, gated=arm == "gated")
    gated, control = arms["gated"], arms["open"]
    checks = {
        "identical_start": gated["before"] == control["before"],
        "matching_schema": gated["schema"]["stable_sha256"] == control["schema"]["stable_sha256"],
        "gated_read_only": gated["before"] == gated["after"] and not gated["read_only_violations"]["forwarded_slots"],
    }
    with binary.open("rb") as stream:
        binary_hash = hashlib.file_digest(stream, "sha256").hexdigest()
    passed = all(checks.values()) and all(all(a["checks"].values()) for a in arms.values())
    print(json.dumps({"kind": "fixed_action_replay", "mcp_sdk": version("mcp"), "binary_sha256": binary_hash,
                      "python": platform.python_version(), "sqlite": sqlite3.sqlite_version,
                      "fixture": FIXTURE, "actions": actions, "arms": arms, "checks": checks, "pass": passed},
                     ensure_ascii=False, indent=2))
    return passed


if __name__ == "__main__":
    cli = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    cli.add_argument("binary", type=Path)
    cli.add_argument("actions", nargs="+", choices=("read_section", "preview_handwriting"))
    args = cli.parse_args()
    raise SystemExit(0 if asyncio.run(run(args.binary, args.actions)) else 1)
