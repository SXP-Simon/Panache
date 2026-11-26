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

import coursework_form
import review_comparison
from mcp_client import call

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

POEM = """# 钱塘湖春行
唐 · 白居易
孤山寺北贾亭西，水面初平云脚低。
几处早莺争暖树，谁家新燕啄春泥。
乱花渐欲迷人眼，浅草才能没马蹄。
最爱湖东行不足，绿杨阴里白沙堤。"""


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
    assert unreviewed["unreviewed_pages"] == [{"section": 1, "page": 1}]
    assert unreviewed["pages_with_evidence"] == 0 and unreviewed["global_text_ink_zero"]
    invisible = (await call(client, "preview_handwriting", **key, view="review")).structuredContent
    assert invisible["evidence"]["visibility"] == "no_visible_change"
    assert invisible["evidence"]["max_rgb_delta"] == 0
    flagged = (await call(client, "export_handwriting", **key, format="zip")).structuredContent["review"]
    assert flagged["unreviewed_pages"] == []
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
    # Keeping the numeric layout cannot carry hand-placed glyphs across a guide reset.
    controls = (await call(client, "describe_controls", **key, group="layout")).structuredContent["values"]
    reset = dict(**key, expected_revision=8, paper_guides=[])
    protected = await client.call_tool("tune_handwriting", {
        **reset, "preserve_local_adjustments": True,
        "changes": {name: controls[name] for name in ("line_spacing", "left_margin")},
    })
    assert protected.isError and "section 1 of revision 8" in protected.content[0].text
    current = (await call(client, "preview_handwriting", **key, view="layout", limit=1)).structuredContent
    assert current["glyphs"][0]["current_photo_quad"] == geometry["glyphs"][0]["current_photo_quad"]
    await call(client, "tune_handwriting", **reset)
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


async def mixed_script_sample(client):
    saved = (await call(client, "save_section", markdown="样品 A 的质量为 12.5 g。",
                        style={"font": "李国夫手写体.ttf", "seed": 17})).structuredContent
    key = {"draft_id": saved["draft_id"]}
    inherited = {"latin_font": None, "latin_digits": False, "latin_font_scale": 100}
    initial = (await call(client, "describe_controls", **key, group="typography")).structuredContent
    assert {k: initial["controls"][k]["default"] for k in inherited} == inherited
    assert {k: initial["values"][k] for k in inherited} == inherited
    assert None in initial["controls"]["latin_font"]["values"]
    primary = png(await call(client, "preview_handwriting", **key))
    override = {"latin_font": "kalam", "latin_digits": True, "latin_font_scale": 120}
    await call(client, "tune_handwriting", **key, expected_revision=1, changes=override)
    assert png(await call(client, "preview_handwriting", **key)) != primary
    await call(client, "tune_handwriting", **key, expected_revision=2, changes={"ink_opacity": 90})
    current = (await call(client, "describe_controls", **key, group="typography")).structuredContent
    assert {k: current["values"][k] for k in override} == override
    await call(client, "tune_handwriting", **key, expected_revision=3,
               changes={**inherited, "ink_opacity": None})
    spec = (await call(client, "describe_controls", **key, group="typography")).structuredContent
    assert {name: spec["values"][name] for name in inherited} == inherited
    assert png(await call(client, "preview_handwriting", **key)) == primary


async def handwriting_variation_sample(client):
    markdown = "样品 A 的质量为 12.5 g。"
    saved = (await call(client, "save_section", markdown=markdown, style={"seed": 17})).structuredContent
    key = {"draft_id": saved["draft_id"]}
    base = png(await call(client, "preview_handwriting", **key))
    for invalid in ({"variation": {"perturb_theta_sigma": 0.07}, "perturb_theta_sigma": 0.08},
                    {"variation": {"strikethrough_probability": 0.1}}, {"variation": {}}):
        rejected = await client.call_tool("tune_handwriting", {**key, "expected_revision": 1, "changes": invalid})
        assert rejected.isError
    tuned = await call(client, "tune_handwriting", **key, expected_revision=1,
                       preserve_local_adjustments=True, changes={"variation": {"perturb_theta_sigma": 0.07}})
    assert tuned.structuredContent["controls"]["perturb_theta_sigma"] == 0.07
    loose = png(await call(client, "preview_handwriting", **key))
    assert loose != base
    strike = (await call(client, "describe_controls", **key, group="strike")).structuredContent
    assert strike["values"]["strikethrough_probability"] == 0
    assert strike["controls"]["strikethrough_angle_sigma"]["unit"] == "deg"
    # Force the optional effect for a deterministic positive control on a short line.
    await call(client, "tune_handwriting", **key, expected_revision=2, changes={"strikethrough_probability": 1})
    assert png(await call(client, "preview_handwriting", **key)) != loose
    assert png(await call(client, "preview_handwriting", **key, revision=2)) == loose
    source = (await call(client, "read_section", **key, view="source")).structuredContent
    assert source["markdown"] == markdown


async def glyph_target_text(client):
    saved = (await call(client, "save_section", markdown="春 雨", style={"seed": 42})).structuredContent
    key = {"draft_id": saved["draft_id"], "section": 1, "page": 1}

    async def layout():
        return (await call(client, "preview_handwriting", **key, view="layout")).structuredContent

    before = await layout()
    old_spring = next(g["id"] for g in before["glyphs"] if g["text"] == "春")
    await call(client, "save_section", draft_id=key["draft_id"], section=1,
               expected_revision=before["revision"], markdown="明 日 春 雨")
    current = await layout()
    ids = {g["text"]: g["id"] for g in current["glyphs"]}
    assert ids["明"] == old_spring and ids["春"] != old_spring

    for revision, targets, words, reason in (
        (before["revision"], [old_spring], ["春"], "Revision conflict"),
        (current["revision"], [ids["雨"], old_spring], ["雨", "春"], "Glyph text mismatch"),
        (current["revision"], [ids["春"], ids["雨"]], ["春"], "one nonempty expected text"),
        (current["revision"], [ids["春"]], [""], "one nonempty expected text"),
    ):
        failed = await client.call_tool("adjust_glyphs", {
            **key, "expected_revision": revision, "ids": targets,
            "expected_texts": words, "color": "#cc1833",
        })
        assert failed.isError and reason in failed.content[0].text, failed.content
    unchanged = await layout()
    assert unchanged["revision"] == current["revision"] and unchanged["glyphs"] == current["glyphs"]

    # Request order differs from page order. Each string must match its own ID.
    await call(client, "adjust_glyphs", **key, expected_revision=current["revision"],
               ids=[ids["雨"], ids["春"]], expected_texts=["雨", "春"], color="#cc1833")
    after = await layout()
    assert after["revision"] == current["revision"] + 1
    assert [g["text"] for g in after["glyphs"]
            if g.get("adjustment", {}).get("color") == [204, 24, 51]] == ["春", "雨"]


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
    region = [[130,160],[265,160],[265,265],[130,265]]
    changed = await call(client, "preview_handwriting", **key, revision=3, view="review",
                         compare_revision=2, region=region)
    mode = changed.structuredContent["render_mode_change"]
    assert (mode["before"], mode["after"]) == ("standard", "fine_edit")
    await call(client, "adjust_glyphs", **edit, expected_revision=3, opacity=0)
    assert await ink_box() is None
    local = await call(client, "preview_handwriting", **key, revision=4, view="review",
                       compare_revision=3, region=region)
    assert len([item for item in local.content if item.type == "image"]) == 3
    measured = local.structuredContent
    assert "render_mode_change" not in measured
    assert measured["crop_bounds"] == [130, 160, 135, 105]
    assert measured["before"]["region"]["ink_pixels"] > 0
    assert measured["after"]["region"]["ink_pixels"] == 0
    assert measured["difference"]["outside_union_changed_pixels"] == 0
    exported = await call(client, "export_handwriting", **key)
    assert exported.structuredContent["review"]["pages_without_visibility_evidence"] == 1
    assert exported.structuredContent["review"]["unreviewed_pages"] == [{"section": 1, "page": 1}]
    assert "局部墨迹" in exported.content[0].text


async def smoke(command, arguments, out):
    with TemporaryDirectory() as temp:
        personal = Path(temp) / "my-fonts"
        personal.mkdir()
        custom_font = personal / "LocalSample.ttf"
        latin = Path(__file__).resolve().parents[2] / "handwriting-core/assets/latin"
        shutil.copyfile(latin / "Handlee-Regular.ttf", custom_font)
        second_font = personal / "SecondSample.ttf"
        shutil.copyfile(latin / "IndieFlower-Regular.ttf", second_font)
        params = StdioServerParameters(
            command=command,
            args=arguments,
            cwd=temp,
            env={**os.environ, "PANACHE_MCP_HOME": temp, "PANACHE_USER_FONT_DIR": str(personal), "PATH": ""},
        )
        async with stdio_client(params) as streams, ClientSession(*streams) as client:
            info = await client.initialize()
            assert info.serverInfo.name == "panache-mcp"
            # These branches guide the client before a draft exists, including on ruled paper.
            before_save, _, _ = info.instructions.partition("save_section(")
            assert "outside the frame" in before_save and "wait before saving" in before_save
            assert "partial work was requested" in before_save
            assert "ask which field" in info.instructions
            assert "group=variation" in info.instructions and "group=strike" in info.instructions
            tools = await client.list_tools()
            assert {t.name for t in tools.tools} == {
                "annotate_review",
                "storage_usage",
                "plan_cleanup",
                "apply_cleanup",
                "list_fonts",
                "describe_controls",
                "tune_handwriting",
                "adjust_glyphs",
                "list_drafts",
                "save_section",
                "read_section",
                "replace_section_text",
                "preview_handwriting",
                "export_handwriting",
            }
            listed = await call(client, "list_fonts")
            guidance = listed.structuredContent["sample_guidance"]
            assert guidance in listed.content[0].text
            for group, name in [("variation", "perturb_theta_sigma"), ("strike", "strikethrough_probability")]:
                assert f"group={group}" in guidance
                spec = (await call(client, "describe_controls", group=group)).structuredContent
                assert spec["controls"][name]["description"]
            assert "志莽行书.ttf" in listed.structuredContent["fonts"]
            results = (await call(client, "list_fonts", source="user", query="localsample", limit=1)).structuredContent
            assert results["total"] == 1 and results["next_offset"] is None
            entry = results["entries"][0]
            assert entry["source"] == "user" and entry["filename"] == custom_font.name
            saved_font = (await call(client, "save_section", markdown="ABC 123", style={"font": entry["id"]})).structuredContent
            font_key = {"draft_id": saved_font["draft_id"]}
            second = (await call(client, "list_fonts", source="user", query="secondsample")).structuredContent["entries"][0]
            await call(client, "tune_handwriting", **font_key, expected_revision=1, changes={"font": second["id"]})
            font_previews = [png(await call(client, "preview_handwriting", **font_key, revision=r)) for r in (1, 2)]
            assert font_previews[0] != font_previews[1]
            custom_font.unlink()
            second_font.unlink()
            assert (await call(client, "list_fonts", source="user", refresh=True)).structuredContent["total"] == 0
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
            await mixed_script_sample(client)
            await handwriting_variation_sample(client)
            await placement_pixels(client)
            await glyph_target_text(client)
            await coursework_form.exercise(client, Path(temp))
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
            # Review a later sheet first. Earlier-revision and local evidence cannot fill gaps.
            await call(client, "preview_handwriting", draft_id=doc, revision=1, view="review")
            await call(client, "preview_handwriting", draft_id=doc, section=2, page=2, view="review")
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
                remaining = [{"section": 1, "page": 1}] + [
                    {"section": 2, "page": page} for page in range(1, len(z.namelist())) if page != 2
                ]
                assert archive["review"]["unreviewed_pages"] == remaining
                assert archive["review"]["pages_without_visibility_evidence"] == len(remaining)
                assert archive["review"]["pages_with_evidence"] == 1
                assert z.read("0.png") == original and z.read("2.png") == middle
            # An export gap is a coordinate at the exported revision, even when the
            # same section and page have a stored receipt on an earlier revision.
            receipt_args = {"draft_id": doc, "view": "review", **remaining[0]}
            gap = await call(client, "read_section", **receipt_args, revision=archive["revision"])
            assert gap.structuredContent["status"] == "no_recorded_review"
            assert "档案无法判断" in gap.content[0].text
            prior = await call(client, "read_section", draft_id=doc, view="review",
                               section=1, page="last", before_text="数学作业")
            assert prior.structuredContent["revision"] == 1 and prior.structuredContent["review_id"]
            wrong_section = await client.call_tool("read_section", {
                "draft_id": doc, "view": "review", "section": 2, "page": "last", "before_text": "数学作业",
            })
            assert wrong_section.isError and "section=1" in wrong_section.content[0].text
            by_page = await call(client, "read_section", **receipt_args, revision=1)
            assert by_page.structuredContent["review_id"] == prior.structuredContent["review_id"]
            assert "事后补验" in by_page.content[0].text
            appearance = await call(client, "preview_handwriting", draft_id=doc,
                                    revision=archive["revision"], view="image", **remaining[0])
            assert png(appearance) == original
            repeated = await call(client, "export_handwriting", draft_id=doc,
                                  revision=archive["revision"], format="zip")
            assert repeated.structuredContent["review"] == archive["review"]
            conflict = await client.call_tool(
                "save_section",
                {"draft_id": doc, "expected_revision": 1, "markdown": "迟到的编辑"},
            )
            assert conflict.isError
            missing = await client.call_tool(
                "preview_handwriting", {"draft_id": doc, "section": 1, "page": 2}
            )
            assert missing.isError and "section=2, page=1" in missing.content[0].text
            for view in ("layout", "review"):
                missing = await client.call_tool("preview_handwriting", {
                    "draft_id": doc, "section": 1, "page": 2, "view": view,
                })
                assert missing.isError
                assert "available page count: 1" in missing.content[0].text
                assert "section=2, page=1" in missing.content[0].text
            historical = await client.call_tool("preview_handwriting", {
                "draft_id": doc, "revision": 1, "page": 2, "view": "review",
            })
            assert historical.isError and "last section" in historical.content[0].text
            assert "section=2" not in historical.content[0].text
            zero = await client.call_tool("preview_handwriting", {
                "draft_id": doc, "section": 2, "page": 0, "view": "layout",
            })
            assert zero.isError and "start at 1" in zero.content[0].text
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
            lookup = dict(**comparison_key, view="review", page=1)
            receipt = await call(client, "read_section", **lookup, revision=3)
            summary = receipt.structuredContent["receipt_summary"]
            assert receipt.structuredContent == {**retrieved, "latest_draft_revision": 6, "receipt_summary": summary}
            assert retrieved["filed_at_revision"] == 3 and "仍为第 3 版" in summary
            older = await call(client, "read_section", **comparison_key, view="review", review_id=reviewed_id)
            assert json.loads(older.content[0].text) == retrieved == older.structuredContent
            assert older.content[1].text == summary and len(older.content) == 2
            explicit = await call(client, "read_section", **comparison_key, view="review", review_id=reviewed_id, revision=6)
            assert "revision=6, section=1, page=1" in explicit.content[2].text
            assert f"检查单号 {reviewed_id}" in receipt.content[0].text
            for args in (dict(**lookup, revision=3, section=2), dict(**gkey, view="review", page=1, revision=1)):
                missing = (await call(client, "read_section", **args)).structuredContent
                assert missing["status"] == "no_recorded_review" and missing["review_id"] is None
                assert missing["draft_id"] == args["draft_id"] and missing["revision"] == args["revision"]
            for args in ({**lookup, "review_id": reviewed_id}, {**lookup, "view": "trajectory"},
                         {**lookup, "page": 0}, {**lookup, "section": 0}, {**lookup, "limit": 1}):
                assert (await client.call_tool("read_section", args)).isError
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
            assert tuned["revision"] == 2 and tuned["changed"] is True
            equal = {**tuning, "expected_revision": 2, "changes": {"word_spacing": 2.0}}
            same = (await call(client, "tune_handwriting", **equal)).structuredContent
            assert same["revision"] == 2 and same["changed"] is False
            assert same["controls"] == tuned["controls"] and same["fine_layout"] == "preserved"
            assert (await client.call_tool("tune_handwriting", {**equal, "changes": {}})).isError
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
            stale_noop = await client.call_tool("tune_handwriting", equal)
            assert stale_noop.isError and "Revision conflict" in stale_noop.content[0].text
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
            blocked = await client.call_tool("tune_handwriting", {
                "draft_id": paper_id, "expected_revision": 3, "preserve_local_adjustments": True,
                "changes": {"variation": {"perturb_theta_sigma": 0.07}},
            })
            assert blocked.isError
            assert blocked.content[0].text == (
                "Reflow would stop applying local glyph adjustments in section 1 of revision 3. "
                "This request saved no new revision. Keep preserve_local_adjustments=true. "
                "Only if the user explicitly agrees to lose those adjustments in the new layout "
                "may you use preserve_local_adjustments=false."
            )
            camera_change = await call(client, "tune_handwriting", draft_id=paper_id,
                                       expected_revision=3, preserve_local_adjustments=True,
                                       changes={"camera_model": "Test Camera", "camera_iso": 200})
            assert camera_change.structuredContent["fine_layout"] == "preserved"
            tagged = png(await call(client, "preview_handwriting", draft_id=paper_id))
            assert b"eXIf" in tagged and b"Test Camera" in tagged and tagged != adjusted
            with Image.open(io.BytesIO(adjusted)) as untagged, Image.open(io.BytesIO(tagged)) as with_exif:
                assert untagged.size == with_exif.size
                assert untagged.convert("RGBA").tobytes() == with_exif.convert("RGBA").tobytes()
            tagged_layout = (await call(client, "preview_handwriting", **probe)).structuredContent
            assert tagged_layout["glyphs"][0]["adjustment"] == again["adjustment"]
            cleared = await call(client, "tune_handwriting", draft_id=paper_id,
                                 expected_revision=4, changes={"camera_model": None, "camera_iso": None})
            assert cleared.structuredContent["revision"] == 5
            assert png(await call(client, "preview_handwriting", draft_id=paper_id)) == adjusted
            ink_settings = {"ink": "#36363b", "ink_alpha": 247, "ink_opacity": 88,
                            "ink_softness": 0.8, "ink_thickness": 0.2}
            prior_ink = {key: tuned["controls"].get(key) for key in ink_settings}
            for rev, patch in [(5, ink_settings), (6, prior_ink)]:
                ink_change = await call(client, "tune_handwriting", draft_id=paper_id,
                                        expected_revision=rev, changes=patch, preserve_local_adjustments=True)
                assert ink_change.structuredContent["fine_layout"] == "preserved"
                glyph = (await call(client, "preview_handwriting", **probe)).structuredContent["glyphs"][0]
                assert glyph["current_photo_quad"] == again["current_photo_quad"]
                assert glyph["adjustment"] == again["adjustment"]
                rendered = png(await call(client, "preview_handwriting", draft_id=paper_id))
                if rev == 5:
                    assert rendered != adjusted
                else:
                    assert rendered == adjusted
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
            assert [png(await call(client, "preview_handwriting", **font_key, revision=r)) for r in (1, 2)] == font_previews
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
                expected_revision=7,
                section=1,
                markdown="重排后的版本",
            )
            refreshed = (
                await call(client, "preview_handwriting", **probe)
            ).structuredContent
            assert all("adjustment" not in g for g in refreshed["glyphs"])
            reflow = await call(client, "tune_handwriting", draft_id=paper_id, expected_revision=8,
                                changes={"perturb_theta_sigma": 0.07}, preserve_local_adjustments=True)
            assert reflow.structuredContent["revision"] == 9
            assert (
                png(
                    await call(
                        client, "preview_handwriting", draft_id=paper_id, revision=3
                    )
                )
                == adjusted
            )
        protected = params.model_copy(update={"env": {**params.env, "PANACHE_MCP_PRESERVE_REVIEWS": "1"}})
        async with stdio_client(protected) as streams, ClientSession(*streams) as client:
            assert "preserves stored reviews" in (await client.initialize()).instructions
            key = {"draft_id": doc, "revision": archive["revision"]}
            for name, arguments in [
                ("preview_handwriting", {**key, **remaining[0], "view": "review"}),
                ("annotate_review", {**comparison_key, "review_id": reviewed_id,
                                     "origin": "model_observation", "text": "must not be stored"}),
            ]:
                blocked = await client.call_tool(name, arguments)
                assert blocked.isError and "保留原有检查记录" in blocked.content[0].text
            assert png(await call(client, "preview_handwriting", **key, **remaining[0], view="image")) == original
            assert (await call(client, "export_handwriting", **key)).structuredContent["review"] == archive["review"]
            assert (await call(client, "read_section", **key, **remaining[0], view="review")).structuredContent["review_id"] is None
        limited = params.model_copy(update={"env": {**params.env, "PANACHE_MCP_MAX_HOME_BYTES": "1"}})
        async with stdio_client(limited) as streams, ClientSession(*streams) as client:
            await client.initialize()
            usage = (await call(client, "storage_usage", **comparison_key)).structuredContent
            assert usage["warning"] and usage["policy"]["max_home_bytes"] == 1
            for name, args in [
                ("save_section", {"markdown": "不可导入", "paper_path": str(Path(__file__).parent.resolve() / "fixtures/ruled.png")}),
                ("tune_handwriting", {**comparison_key, "expected_revision": 6, "font_path": str(Path(__file__).resolve().parents[3] / "assets/font_assets/李国夫手写体.ttf")}),
                ("export_handwriting", {**comparison_key, "format": "zip"}),
            ]:
                failure = await client.call_tool(name, args)
                assert failure.isError and "Storage limit" in failure.content[0].text
            after = (await call(client, "storage_usage", **comparison_key)).structuredContent
            assert after["logical_payload"] == usage["logical_payload"]
            assert after["export_directory_bytes"] == usage["export_directory_bytes"]
            stored = (await call(client, "read_section", **comparison_key, view="review", review_id=reviewed_id)).structuredContent
            assert stored["feedback"][0]["text"] == user_quote
            assert png(await call(client, "preview_handwriting", draft_id=paper_id, revision=3)) == adjusted
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
