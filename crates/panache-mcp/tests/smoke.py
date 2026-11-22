# /// script
# requires-python = ">=3.11"
# dependencies = ["mcp>=1.12,<2"]
# ///
"""Exercise a real MCP client over stdio. Optionally keep the poem's PNG and PDF."""

import argparse
import asyncio
import base64
import json
import os
import shutil
from pathlib import Path
from tempfile import TemporaryDirectory
from zipfile import ZipFile

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

POEM = """# 钱塘湖春行
唐 · 白居易
孤山寺北贾亭西，水面初平云脚低。
几处早莺争暖树，谁家新燕啄春泥。
乱花渐欲迷人眼，浅草才能没马蹄。
最爱湖东行不足，绿杨阴里白沙堤。"""


async def call(client, name, **args):
    result = await client.call_tool(name, args)
    assert not result.isError, (name, result.content[0])
    return result


def png(result):
    return base64.b64decode(
        next(item.data for item in result.content if item.type == "image"),
        validate=True,
    )


async def smoke(command, arguments, out):
    with TemporaryDirectory() as temp:
        params = StdioServerParameters(
            command=command,
            args=arguments,
            cwd=temp,
            env={**os.environ, "PANACHE_MCP_HOME": temp, "PATH": ""},
        )
        async with stdio_client(params) as streams, ClientSession(*streams) as client:
            info = await client.initialize()
            assert info.serverInfo.name == "panache-mcp"
            tools = await client.list_tools()
            assert {t.name for t in tools.tools} == {
                "list_fonts",
                "describe_controls",
                "tune_handwriting",
                "list_drafts",
                "save_section",
                "read_section",
                "preview_handwriting",
                "export_handwriting",
            }
            fonts = (await call(client, "list_fonts")).structuredContent["fonts"]
            assert "志莽行书.ttf" in fonts
            paper_path = Path(temp) / "我的 横线纸.png"
            shutil.copyfile(
                Path(__file__).parent / "fixtures" / "ruled.png", paper_path
            )
            custom = (
                await call(
                    client,
                    "save_section",
                    markdown="保留原稿",
                    paper_path=str(paper_path),
                    style={"font_size": 44},
                )
            ).structuredContent
            layout = custom["paper"]
            assert (
                layout["ruled"],
                layout["width"],
                layout["height"],
                layout["line_spacing"],
            ) == (True, 400, 500, 40)
            paper_path.unlink()
            paper_id = custom["draft_id"]
            paper_preview = png(
                await call(client, "preview_handwriting", draft_id=paper_id)
            )
            assert int.from_bytes(paper_preview[16:20], "big") == 400
            failed = await client.call_tool(
                "save_section", {"markdown": "missing", "paper_path": str(paper_path)}
            )
            assert failed.isError
            # Keep the traditional eight verse lines for a single folio.
            poem = POEM.replace("，", "，\n")
            saved = (
                await call(
                    client,
                    "save_section",
                    title="钱塘湖春行",
                    markdown=poem,
                    style={
                        "font": "志莽行书.ttf",
                        "font_size": 44,
                        "ink": "#292d32",
                        "seed": 42,
                    },
                )
            ).structuredContent
            doc = saved["draft_id"]
            first = await call(client, "preview_handwriting", draft_id=doc)
            original = png(first)
            assert (
                original.startswith(b"\x89PNG")
                and not first.structuredContent["cached"]
            )
            exported = (
                await call(client, "export_handwriting", draft_id=doc)
            ).structuredContent
            assert exported["pages"] == 1
            if out:
                out.mkdir(exist_ok=True, parents=True)
                (out / "钱塘湖春行.png").write_bytes(original)
                shutil.copyfile(exported["path"], out / "钱塘湖春行.pdf")
            # A second section exercises pagination, math and Markdown tables.
            homework = "## 数学作业\n| 项 | 值 |\n| --- | --- |\n| 长度 | 2 |\n" + (
                "\n1. 求解 $\\frac{1}{2} + \\sqrt{9}$。\n" * 42
            )
            change = await call(
                client,
                "save_section",
                draft_id=doc,
                expected_revision=1,
                markdown=homework,
            )
            assert change.structuredContent["section"] == 2
            again = await call(client, "preview_handwriting", draft_id=doc)
            assert again.structuredContent["cached"] and png(again) == original
            later = await call(
                client, "preview_handwriting", draft_id=doc, section=2, page=2
            )
            middle = png(later)
            notifications = []

            async def progress(value, total, message=None):
                notifications.append(value)

            export = await client.call_tool(
                "export_handwriting",
                {"draft_id": doc, "format": "zip"},
                progress_callback=progress,
            )
            assert not export.isError
            archive = export.structuredContent
            assert notifications == list(range(1, archive["pages"] + 1))
            with ZipFile(archive["path"]) as z:
                assert archive["pages"] == len(z.namelist()) >= 3
                assert z.read("0.png") == original and z.read("2.png") == middle
            conflict = await client.call_tool(
                "save_section",
                {"draft_id": doc, "expected_revision": 1, "markdown": "迟到的编辑"},
            )
            assert conflict.isError
            missing = await client.call_tool(
                "preview_handwriting", {"draft_id": doc, "section": 1, "page": 2}
            )
            assert missing.isError
            edited = await call(
                client,
                "save_section",
                draft_id=doc,
                section=1,
                expected_revision=2,
                markdown="修订稿",
            )
            assert edited.structuredContent["revision"] == 3
            assert (
                png(await call(client, "preview_handwriting", draft_id=doc)) != original
            )
        async with stdio_client(params) as streams, ClientSession(*streams) as client:
            await client.initialize()
            assert (await call(client, "list_drafts")).structuredContent["drafts"][0][
                "draft_id"
            ] == doc
            prior = (
                await call(
                    client,
                    "read_section",
                    draft_id=doc,
                    section=1,
                    revision=1,
                    offset=2,
                    limit=5,
                )
            ).structuredContent
            assert prior["markdown"] == poem[2:7] and prior["next_offset"] == 7
            assert (
                png(await call(client, "preview_handwriting", draft_id=paper_id))
                == paper_preview
            )
            paper_zip = (
                await call(
                    client, "export_handwriting", draft_id=paper_id, format="zip"
                )
            ).structuredContent
            with ZipFile(paper_zip["path"]) as pages:
                assert pages.read("0.png") == paper_preview
            assert (
                png(await call(client, "preview_handwriting", draft_id=doc, revision=1))
                == original
            )
            assert (await call(client, "read_section", draft_id=doc)).structuredContent[
                "markdown"
            ] == "修订稿"
            groups = (await call(client, "describe_controls")).structuredContent[
                "groups"
            ]
            assert len(groups) == 5
            ink = (
                await call(client, "describe_controls", group="ink")
            ).structuredContent["controls"]
            assert "ink_opacity" in ink and "left_margin" not in ink
            tuning = {
                "draft_id": paper_id,
                "expected_revision": 1,
                "changes": {"ink_opacity": 55, "ink": "#665577", "word_spacing": 2},
            }
            tuned = (await call(client, "tune_handwriting", **tuning)).structuredContent
            assert tuned["revision"] == 2
            assert (await client.call_tool("tune_handwriting", tuning)).isError
            assert (
                png(await call(client, "preview_handwriting", draft_id=paper_id))
                != paper_preview
            )
            assert (
                png(
                    await call(
                        client, "preview_handwriting", draft_id=paper_id, revision=1
                    )
                )
                == paper_preview
            )
            invalid = {
                **tuning,
                "expected_revision": 2,
                "changes": {"ink_opacity": 101},
            }
            assert (await client.call_tool("tune_handwriting", invalid)).isError
            # Exercise a long draft without ever exporting or rendering its tail.
            repeated = "逐题列出已知条件，检查解题步骤。\n" * 600
            large = (
                await call(
                    client,
                    "save_section",
                    title="长作业",
                    markdown="第一题",
                    style={"homework": True, "seed": 17},
                )
            ).structuredContent
            for _ in range(6):
                large = (
                    await call(
                        client,
                        "save_section",
                        draft_id=large["draft_id"],
                        expected_revision=large["revision"],
                        markdown=repeated,
                    )
                ).structuredContent
            cover = await call(
                client, "preview_handwriting", draft_id=large["draft_id"]
            )
            assert (
                cover.structuredContent["section"] == 1
                and not cover.structuredContent["cached"]
            )
            selected = await call(
                client,
                "preview_handwriting",
                draft_id=large["draft_id"],
                section=7,
                page=2,
            )
            assert selected.structuredContent["page_in_section"] == 2
            print(
                f"Long draft: {large['prepared_chars']} prepared characters across {large['sections']} sections; read section 7, page 2."
            )
        print(
            f"Poem: 1 page. Extended draft: {archive['pages']} pages. Cache, selected page, old revision, restart and conflicts verified."
        )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("binary", nargs="?", type=Path)
    source.add_argument("--config", type=Path, help="JSON copied from Panache settings")
    parser.add_argument(
        "--server-arg", action="append", default=[], help="Argument for the executable"
    )
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    entry = (
        json.loads(args.config.read_text(encoding="utf-8-sig"))["mcpServers"]["panache"]
        if args.config
        else {"command": str(args.binary.resolve()), "args": args.server_arg}
    )
    asyncio.run(smoke(entry["command"], entry.get("args", []), args.out))
