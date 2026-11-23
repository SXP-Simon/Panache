# /// script
# requires-python = ">=3.11"
# dependencies = ["mcp>=1.12,<2", "Pillow"]
# ///
"""Exercise a real MCP client over stdio. Optionally keep the poem's PNG and PDF."""

import argparse
import asyncio
import base64
import io
import json
import os
import shutil
from pathlib import Path
from tempfile import TemporaryDirectory
from zipfile import ZipFile

from PIL import Image

import review_comparison

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


async def review_workflow(client, key, guides, font_path):
    # Revise the same sheet after its source image has moved away.
    guides = [{**g, "left": [g["left"][0]+12, g["left"][1]+9],
               "right": [g["right"][0]+12, g["right"][1]+9]} for g in guides]
    revised = (await call(
        client, "tune_handwriting", **key, expected_revision=3,
        paper_guides=guides, font_path=str(font_path), note="Write inside the indicated area.",
    )).structuredContent
    imported_font = revised["controls"]["font"]
    assert imported_font.startswith("upload:")
    font_path.unlink()
    assert revised["revision"] == 4 and revised["paper"]["alignment"] == "manual_guides"
    assert (await client.call_tool("tune_handwriting", {**key, "expected_revision": 3, "paper_guides": guides})).isError
    review = await call(client, "preview_handwriting", **key, view="review")
    assert sum(c.type == "image" for c in review.content) == 3
    assert review.structuredContent["evidence"]["visibility"] == "inspect_visually"
    glyph = (await call(client, "preview_handwriting", **key, view="layout", limit=1)).structuredContent["glyphs"][0]
    selected = (await call(client, "preview_handwriting", **key, view="layout", region=glyph["photo_quad"])).structuredContent
    assert glyph["id"] in [g["id"] for g in selected["glyphs"]]
    await call(client, "adjust_glyphs", **key, expected_revision=4, section=1, page=1,
               ids=[glyph["id"]], place_center=[170, 260], note="Move the chosen word.")
    moved = (await call(client, "preview_handwriting", **key, view="layout",
                        region=[[166,256],[174,256],[174,264],[166,264]])).structuredContent
    assert glyph["id"] in [g["id"] for g in moved["glyphs"]]
    pdf = (await call(client, "export_handwriting", **key, format="pdf")).structuredContent
    await call(client, "tune_handwriting", **key, expected_revision=5, changes={"transparent_background": True})
    transparent = png(await call(client, "preview_handwriting", **key))
    archive = (await call(client, "export_handwriting", **key, format="zip")).structuredContent
    with ZipFile(archive["path"]) as z:
        assert z.read("0.png") == transparent
    same_pdf = (await call(client, "export_handwriting", **key, format="pdf")).structuredContent
    assert Path(same_pdf["path"]).read_bytes() == Path(pdf["path"]).read_bytes()
    await call(client, "tune_handwriting", **key, expected_revision=6, changes={"ink_opacity": 0})
    unreviewed = (await call(client, "export_handwriting", **key, format="zip")).structuredContent["review"]
    assert unreviewed["pages_with_evidence"] == 0 and unreviewed["global_text_ink_zero"]
    invisible = (await call(client, "preview_handwriting", **key, view="review")).structuredContent
    assert invisible["evidence"]["visibility"] == "no_visible_change"
    assert invisible["evidence"]["max_rgb_delta"] == 0
    flagged = (await call(client, "export_handwriting", **key, format="zip")).structuredContent["review"]
    assert flagged["pages_with_evidence"] == 1 and flagged["pages_with_visibility_flags"] == 1
    recent = (await call(client, "read_section", **key, view="trajectory", limit=1)).structuredContent
    assert recent["next_offset"] == 1 and recent["events"][0]["details"]["visibility"] == "no_visible_change"
    previous = (await call(client, "read_section", **key, revision=5, view="trajectory")).structuredContent
    assert previous["events"][0]["details"]["note"] == "Move the chosen word."
    assert all(e["revision"] <= 5 for e in previous["events"])
    # Fit the full four-corner mask of a single glyph and check the reported final geometry.
    ids = [glyph["id"]]
    quad = [[130, 200], [166, 195], [171, 232], [126, 235]]
    edit = dict(**key, expected_revision=7, section=1, page=1, ids=ids)
    assert (await client.call_tool("adjust_glyphs", {**edit, "target_quad": [quad[i] for i in (0,2,1,3)]})).isError
    await call(client, "adjust_glyphs", **edit, target_quad=quad)
    geometry = (await call(client, "preview_handwriting", **key, view="layout", limit=1)).structuredContent
    for actual, target in zip(geometry["glyphs"][0]["current_photo_quad"], quad, strict=True):
        assert max(abs(a-b) for a,b in zip(actual,target,strict=True)) < 1.1
    await call(client, "tune_handwriting", **key, expected_revision=8, paper_guides=[])
    restored = (await call(client, "read_section", **key, view="summary")).structuredContent["paper"]
    original = (await call(client, "read_section", **key, revision=1, view="summary")).structuredContent["paper"]
    assert restored == original
    assert (await call(client,"read_section",**key,revision=4,view="summary")).structuredContent["paper"] != original
    # Change only the font between two otherwise identical historical revisions.
    await call(client, "tune_handwriting", **key, expected_revision=9,
               changes={"ink_opacity": 100, "font": "霞鹜文楷.ttf"})
    default = png(await call(client, "preview_handwriting", **key, revision=10))
    await call(client, "tune_handwriting", **key, expected_revision=10, changes={"font": imported_font})
    uploaded = png(await call(client, "preview_handwriting", **key, revision=11))
    assert default != uploaded
    return transparent, default, uploaded


async def placement_pixels(client):
    saved = (await call(client, "save_section", markdown="字", style={"seed": 17})).structuredContent
    key = {"draft_id": saved["draft_id"]}
    await call(client, "tune_handwriting", **key, expected_revision=1, changes={"transparent_background": True})
    glyph = (await call(client, "preview_handwriting", **key, view="layout")).structuredContent["glyphs"][0]
    async def ink_box():
        with Image.open(io.BytesIO(png(await call(client, "preview_handwriting", **key)))) as im:
            return im.getchannel("A").getbbox()
    original = await ink_box()
    quad = [[140, 180], [255, 170], [250, 254], [145, 255]]
    edit = dict(**key, section=1, page=1, ids=[glyph["id"]])
    await call(client, "adjust_glyphs", **edit, expected_revision=2, target_quad=quad)
    left, top, right, bottom = await ink_box()
    assert 139 <= left < right <= 256 and 169 <= top < bottom <= 256
    assert right - left > 2 * (original[2] - original[0])
    await call(client, "adjust_glyphs", **edit, expected_revision=3, opacity=0)
    assert await ink_box() is None
    exported = await call(client, "export_handwriting", **key)
    assert exported.structuredContent["review"]["pages_without_visibility_evidence"] == 1
    assert "局部墨迹" in exported.content[0].text


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
                "annotate_review",
                "list_fonts",
                "describe_controls",
                "tune_handwriting",
                "adjust_glyphs",
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
            # Supply two writable lines directly when the client knows the photo geometry.
            guides = [
                {"row": 0, "left": [75, 100], "right": [320, 84]},
                {"row": 6, "left": [30, 395], "right": [377, 374]},
            ]
            guided = (
                await call(
                    client,
                    "save_section",
                    markdown="纸面透视",
                    paper_path=str(paper_path),
                    paper_guides=guides,
                )
            ).structuredContent
            assert guided["paper"]["alignment"] == "manual_guides"
            gkey = {"draft_id": guided["draft_id"]}
            paper_only = png(
                await call(client, "preview_handwriting", view="paper", **gkey)
            )
            base = png(await call(client, "preview_handwriting", **gkey))
            assert paper_only != base
            geom = (
                await call(
                    client, "preview_handwriting", view="layout", limit=1, **gkey
                )
            ).structuredContent["glyphs"][0]
            assert len(geom["photo_quad"]) == 4 and len(geom["photo_baseline"]) == 2
            patch = dict(**gkey, section=1, page=1, ids=[geom["id"]])
            await call(
                client,
                "adjust_glyphs",
                expected_revision=1,
                **patch,
                shape={"shear_degrees": 5, "top_width_percent": 88},
            )
            assert base != png(await call(client, "preview_handwriting", **gkey))
            await call(
                client,
                "adjust_glyphs",
                expected_revision=2,
                **patch,
                shape={"shear_degrees": 0, "top_width_percent": 100},
            )
            assert base == png(await call(client, "preview_handwriting", **gkey))
            invalid = await client.call_tool(
                "save_section",
                {
                    "markdown": "x",
                    "paper_path": str(paper_path),
                    "paper_guides": guides[::-1],
                },
            )
            assert invalid.isError
            paper_path.unlink()
            font_path = Path(temp) / "imported.ttf"
            shutil.copyfile(Path(__file__).resolve().parents[3] / "assets/font_assets/李国夫手写体.ttf", font_path)
            imported_preview, default_font_image, uploaded_font_image = await review_workflow(client, gkey, guides, font_path)
            paper_id = custom["draft_id"]
            paper_preview = png(
                await call(client, "preview_handwriting", draft_id=paper_id)
            )
            assert int.from_bytes(paper_preview[16:20], "big") == 400
            failed = await client.call_tool(
                "save_section", {"markdown": "missing", "paper_path": str(paper_path)}
            )
            assert failed.isError
            await placement_pixels(client)
            comparison_key, reviewed_id, user_quote = await review_comparison.exercise(client, Path(temp), call)
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
            retrieved = (await call(client, "read_section", **comparison_key, view="review", review_id=reviewed_id)).structuredContent
            assert retrieved["revision"] == 3 and retrieved["section"] == retrieved["page"] == 1
            assert retrieved["feedback"] == [{"origin":"user_quote","text":user_quote}]
            assert (await call(client,"read_section",**comparison_key,view="summary")).structuredContent["revision"] == 6
            events = (await call(client,"read_section",**comparison_key,view="trajectory",limit=50)).structuredContent["events"]
            assert {e["origin"] for e in events} >= {"draft_edit","measurement","user_quote","model_observation"}
            assert (await client.call_tool("read_section",{**gkey,"view":"review","review_id":reviewed_id})).isError
            assert png(await call(client, "preview_handwriting", **gkey, revision=6)) == imported_preview
            assert png(await call(client, "preview_handwriting", **gkey, revision=10)) == default_font_image
            assert png(await call(client, "preview_handwriting", **gkey, revision=11)) == uploaded_font_image
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
            assert set(groups) == {"layout", "typography", "ink", "variation", "strike", "camera"}
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
            probe = {
                "draft_id": paper_id,
                "section": 1,
                "page": 1,
                "view": "layout",
                "limit": 1,
            }
            layout = await call(client, "preview_handwriting", **probe)
            assert not any(c.type == "image" for c in layout.content)
            row = layout.structuredContent["glyphs"][0]
            assert (
                layout.structuredContent["next_offset"] == 1 and len(row["bounds"]) == 4
            )
            fine = {
                "draft_id": paper_id,
                "expected_revision": 2,
                "section": 1,
                "page": 1,
                "ids": [row["id"]],
                "dx": 11,
                "dy": -4,
                "thickness": 0.6,
                "softness": 0.2,
                "color": "#553322",
            }
            assert (
                await client.call_tool("adjust_glyphs", {**fine, "ids": [999999]})
            ).isError
            assert (
                await client.call_tool("adjust_glyphs", {**fine, "thickness": 0.25})
            ).isError
            before = png(await call(client, "preview_handwriting", draft_id=paper_id))
            assert (await call(client, "adjust_glyphs", **fine)).structuredContent[
                "revision"
            ] == 3
            adjusted = png(await call(client, "preview_handwriting", draft_id=paper_id))
            assert (
                adjusted != before
                and png(
                    await call(
                        client, "preview_handwriting", draft_id=paper_id, revision=2
                    )
                )
                == before
            )
            again = (
                await call(client, "preview_handwriting", **probe)
            ).structuredContent["glyphs"][0]
            assert (
                again["adjustment"]["thickness"] == 6
                and again["adjustment"]["softness"] == 2
            )
            assert again["adjustment"]["color"] == [85, 51, 34]
            assert again["adjustment"]["dx"] == 11 and again["adjustment"]["dy"] == -4
            exported_fine = (
                await call(
                    client, "export_handwriting", draft_id=paper_id, format="zip"
                )
            ).structuredContent
            with ZipFile(exported_fine["path"]) as pages:
                assert pages.read("0.png") == adjusted
            camera_change = await call(client, "tune_handwriting", draft_id=paper_id,
                                       expected_revision=3, changes={"camera_model": "Test Camera", "camera_iso": 200})
            assert camera_change.structuredContent["fine_layout"] == "preserved"
            tagged = png(await call(client, "preview_handwriting", draft_id=paper_id))
            assert b"eXIf" in tagged and b"Test Camera" in tagged and tagged != adjusted
            tagged_layout = (await call(client, "preview_handwriting", **probe)).structuredContent
            assert tagged_layout["glyphs"][0]["adjustment"] == again["adjustment"]
            cleared = await call(client, "tune_handwriting", draft_id=paper_id,
                                 expected_revision=4, changes={"camera_model": None, "camera_iso": None})
            assert cleared.structuredContent["revision"] == 5
            assert png(await call(client, "preview_handwriting", draft_id=paper_id)) == adjusted
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
        async with stdio_client(params) as streams, ClientSession(*streams) as client:
            await client.initialize()
            assert (
                png(
                    await call(
                        client, "preview_handwriting", draft_id=paper_id, revision=3
                    )
                )
                == adjusted
            )
            await call(
                client,
                "save_section",
                draft_id=paper_id,
                expected_revision=5,
                section=1,
                markdown="重排后的版本",
            )
            refreshed = (
                await call(client, "preview_handwriting", **probe)
            ).structuredContent
            assert all("adjustment" not in g for g in refreshed["glyphs"])
            assert (
                png(
                    await call(
                        client, "preview_handwriting", draft_id=paper_id, revision=3
                    )
                )
                == adjusted
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
