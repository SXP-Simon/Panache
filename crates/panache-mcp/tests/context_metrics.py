# /// script
# requires-python = ">=3.11"
# dependencies = ["mcp>=1.12,<2"]
# ///
"""Measure compact JSON result bytes with the same fixture against any local MCP build."""

import asyncio
import base64
import json
import os
import sys
from pathlib import Path
from tempfile import TemporaryDirectory

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from mcp_client import call


def size(result):
    wire = result.model_dump(mode="json", by_alias=True, exclude_unset=True)
    return len(json.dumps(wire, ensure_ascii=False, separators=(",", ":")).encode())


async def run(command):
    with TemporaryDirectory() as directory:
        params = StdioServerParameters(
            command=str(Path(command).resolve()),
            args=sys.argv[2:],
            cwd=directory,
            env={**os.environ, "PANACHE_MCP_HOME": directory},
        )
        async with stdio_client(params) as streams, ClientSession(*streams) as c:
            await c.initialize()
            tools = await c.list_tools()
            names = {t.name for t in tools.tools}
            metrics = {"tools": len(names), "tools_list_bytes": size(tools)}
            data = base64.b64encode(
                (Path(__file__).parent / "fixtures" / "ruled.png").read_bytes()
            ).decode()
            md = "排版试稿\n![纸张](data:image/png;base64," + data + ")\n复查结尾。"
            draft = (
                await call(
                    c,
                    "save_section",
                    markdown=md,
                    style={"font": "志莽行书.ttf", "seed": 42},
                )
            ).structuredContent
            key = {"draft_id": draft["draft_id"], "revision": draft["revision"]}
            excerpt = await call(c, "read_section", **key)
            metrics["read_default_bytes"] = size(excerpt)
            metrics["read_contains_image_uri"] = (
                "data:image/" in excerpt.structuredContent["markdown"]
            )
            preview = await call(c, "preview_handwriting", **key)
            metrics["image_preview_bytes"] = size(preview)
            if "adjust_glyphs" in names:
                summary = await call(c, "read_section", **key, view="summary")
                raw = await call(c, "read_section", **key, view="source")
                assert (
                    "markdown" not in summary.structuredContent
                    and raw.structuredContent["markdown"] == md[:1000]
                )
                assert (
                    excerpt.structuredContent["markdown"]
                    == "排版试稿\n![纸张](attachment)\n复查结尾。"
                )
                metrics["summary_bytes"] = size(summary)
                index = await call(c, "describe_controls")
                metrics["control_index_bytes"] = size(index)
                group = await call(c, "describe_controls", group="ink", **key)
                assert set(group.structuredContent["controls"]) == set(
                    group.structuredContent["values"]
                )
                metrics["ink_controls_with_values_bytes"] = size(group)
                layout = await call(
                    c, "preview_handwriting", view="layout", limit=2, **key
                )
                metrics["two_glyph_layout_bytes"] = size(layout)
                metrics["layout_image_blocks"] = sum(
                    b.type == "image" for b in layout.content
                )
            print(json.dumps(metrics, ensure_ascii=False))


if __name__ == "__main__":
    asyncio.run(run(sys.argv[1]))
