# /// script
# requires-python = ">=3.11"
# dependencies = ["mcp>=1.12,<2"]
# ///
"""Exercise list_drafts over stdio. Optionally compare each offset call with a baseline binary."""

import argparse
import asyncio
import os
from contextlib import AsyncExitStack, asynccontextmanager
from pathlib import Path
from tempfile import TemporaryDirectory

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

from mcp_client import call


@asynccontextmanager
async def session(binary, home):
    params = StdioServerParameters(
        command=str(binary.resolve()),
        env={**os.environ, "PANACHE_MCP_HOME": home},
    )
    async with stdio_client(params) as streams, ClientSession(*streams) as client:
        await client.initialize()
        yield client


async def run(binary, baseline):
    with TemporaryDirectory(prefix="panache-list-") as home:
        async with AsyncExitStack() as stack:
            reader = await stack.enter_async_context(session(binary, home))
            writer = await stack.enter_async_context(session(binary, home))
            old = await stack.enter_async_context(session(baseline, home)) if baseline else None
            rows = []

            async def save():
                result = await call(writer, "save_section", title="同名", markdown=f"正文 {len(rows) + 1}")
                rows.insert(0, {
                    "draft_id": result.structuredContent["draft_id"], "title": "同名",
                    "revision": 1, "sections": 1,
                })

            async def page(expected, **arguments):
                result = await call(reader, "list_drafts", **arguments)
                data = result.structuredContent
                offset = arguments.get("offset") or 0
                legacy = {"offset": offset, "drafts": expected[:20]}
                more = len(expected) > 20
                next_id = expected[19]["draft_id"] if more else None
                assert data == ({**legacy, "next_before_draft_id": next_id} if more else legacy)
                lines = result.content[0].text.splitlines()
                if not expected and offset == 0 and "before_draft_id" not in arguments:
                    assert "style.homework=true" in lines.pop()
                if more:
                    assert lines[-1] == f'下一页：`before_draft_id="{next_id}"`'
                else:
                    assert len(lines) == len(expected) + 1
                if old and "before_draft_id" not in arguments:
                    previous = await call(old, "list_drafts", **arguments)
                    assert previous.structuredContent == legacy
                    assert previous.content[0].text.splitlines() == (lines[:-1] if more else lines)
                return data

            await page([])
            for count in range(1, 41):
                await save()
                if count in (19, 20, 21, 40):
                    first = await page(rows)
                    await page(rows[20:], offset=20)
                    if count > 20:
                        await page(rows[20:], before_draft_id=first["next_before_draft_id"])

            await page(rows, offset=None)
            await page(rows, offset=0)
            middle = await page(rows[7:], offset=7)
            await page(rows[27:], before_draft_id=middle["next_before_draft_id"])
            await page([], offset=40)
            await page([], offset=2**32 - 1)
            first = await page(rows)
            original_ids = [r["draft_id"] for r in rows]
            anchor = first["next_before_draft_id"]
            await save()
            for row in (rows[21], rows[-1]):  # The anchor itself, and the oldest unread draft.
                await call(writer, "save_section", draft_id=row["draft_id"],
                           expected_revision=1, section=1, markdown="已修订")
                row["revision"] = 2
            older = await page(rows[21:], before_draft_id=anchor)
            await page(rows[21:], before_draft_id=anchor, offset=None)
            scanned = [r["draft_id"] for r in first["drafts"] + older["drafts"]]
            assert scanned == original_ids
            shifted = await page(rows[20:], offset=20)
            assert shifted["drafts"][0]["draft_id"] == anchor
            assert len(set(original_ids[:20] + [r["draft_id"] for r in shifted["drafts"]])) == 39

            fresh = await page(rows)
            older = await page(rows[20:], before_draft_id=fresh["next_before_draft_id"])
            await page(rows[40:], before_draft_id=older["next_before_draft_id"])

            for arguments, message in [
                ({"before_draft_id": "unknown"}, "Unknown before_draft_id"),
                ({"before_draft_id": ""}, "Unknown before_draft_id"),
                ({"before_draft_id": anchor, "offset": 0}, "Omit offset"),
                ({"before_draft_id": anchor, "offset": 20}, "Omit offset"),
            ]:
                result = await reader.call_tool("list_drafts", arguments)
                assert result.isError and message in result.content[0].text and not result.structuredContent

    print("Passed 0/19/20/21/40 boundaries, legacy offsets, insertion/edits, 41-row scan and invalid anchors.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--baseline", type=Path)
    args = parser.parse_args()
    asyncio.run(run(args.binary, args.baseline))
