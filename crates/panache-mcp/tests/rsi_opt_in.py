# /// script
# requires-python = ">=3.11"
# dependencies = ["mcp>=1.12,<2"]
# ///
"""Check the RSI opt-in with native stdio, including request rejection before writes."""

import argparse
import asyncio
import json
import os
from contextlib import asynccontextmanager
from pathlib import Path
from tempfile import TemporaryDirectory

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

from mcp_client import call, open_db

NAMES = {
    "start_rsi_task", "read_rsi_task", "advance_rsi_task",
    "read_rsi_policy", "publish_rsi_policy", "validate_rsi_policy",
}
ARGS = {"rsi_task_id", "rsi_decision_id"}


@asynccontextmanager
async def session(binary, home, value=None, *, preserve=False):
    env = {**os.environ, "PANACHE_MCP_HOME": str(home)}
    env.pop("PANACHE_MCP_RSI", None)
    if value is not None:
        env["PANACHE_MCP_RSI"] = value
    env["PANACHE_MCP_PRESERVE_REVIEWS"] = "1" if preserve else "0"
    async with (
        stdio_client(StdioServerParameters(command=str(binary), env=env)) as streams,
        ClientSession(*streams) as client,
    ):
        info = await client.initialize()
        yield client, info


def snapshot(home):
    with open_db(home) as db:
        return [list(db.execute(f"SELECT * FROM {table} ORDER BY rowid"))
                for table in ("drafts", "review_observations", "rsi_tasks", "rsi_previews")]


async def catalog(client, info, *, enabled):
    tools = (await client.list_tools()).tools
    assert len(tools) == (25 if enabled else 19)
    assert {t.name for t in tools} & NAMES == (NAMES if enabled else set())
    assert ("start_rsi_task" in info.instructions) == enabled
    assert any(ARGS & t.inputSchema.get("properties", {}).keys() for t in tools) == enabled
    size = len(json.dumps([t.model_dump(by_alias=True, exclude_none=True) for t in tools],
                          separators=(",", ":"), ensure_ascii=False).encode())
    return size


async def run(binary, home):
    async with session(binary, home, "1") as (client, info):
        on = await catalog(client, info, enabled=True)
        draft = (await call(client, "save_section", markdown="两列都是时间。")).structuredContent
        key = {"draft_id": draft["draft_id"], "revision": 1}
        task = (await call(client, "start_rsi_task", **key, objective="Check a saved page",
                           policy_id="pilot-v1", decision_provider="native fixture")).structuredContent
        tid = {"task_id": task["task_id"]}
    before = snapshot(home)
    rejected = 0
    for value in (None, "0", "true"):
        async with session(binary, home, value) as (client, info):
            off = await catalog(client, info, enabled=False)
            for name in sorted(NAMES):
                error = await client.call_tool(name, {})
                assert error.isError and "PANACHE_MCP_RSI=1" in error.content[0].text
                rejected += 1
            for name in ("save_section", "adjust_glyphs", "tune_handwriting", "replace_section_text",
                         "preview_handwriting"):
                arg = "rsi_task_id" if name == "preview_handwriting" else "rsi_decision_id"
                for bad in ("explicit-id", None):
                    error = await client.call_tool(name, {**key, arg: bad})
                    assert error.isError and "PANACHE_MCP_RSI=1" in error.content[0].text
                    rejected += 1
        assert snapshot(home) == before
    async with session(binary, home) as (client, _):
        review = (await call(client, "preview_handwriting", **key, view="review")).structuredContent
        assert review["revision"] == 1 and review["review_id"]
        await call(client, "search_homework_experience", query="两列都是时间")
    async with session(binary, home, "1", preserve=True) as (client, _):
        unchanged = (await call(client, "read_rsi_task", **tid)).structuredContent
        assert unchanged["task_id"] == task["task_id"]
        response = await client.call_tool("preview_handwriting", {
            **key, "view": "image", "rsi_task_id": task["task_id"],
        })
        assert response.isError and "保留原有检查记录" in response.content[0].text
    print(json.dumps({"default_tools": 19, "enabled_tools": 25, "catalog_utf8": [off, on],
                      "raw_requests_rejected": rejected, "reopened_task": True}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    args = parser.parse_args()
    with TemporaryDirectory() as home:
        asyncio.run(run(args.binary.resolve(), Path(home)))
