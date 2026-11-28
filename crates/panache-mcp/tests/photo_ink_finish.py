"""Verify that all five native content paths use the photographed ink finish in preview and ZIP."""

import asyncio
import base64
import io
import json
import sys
from pathlib import Path
from tempfile import TemporaryDirectory
from zipfile import ZipFile

from mcp_client import call, isolated_session
from paper_focus import graded_paper
from PIL import Image, ImageChops, ImageDraw


async def picture(client, key, section):
    result = await call(
        client, "preview_handwriting", **key, section=section, page=1, view="image"
    )
    data = next(b.data for b in result.content if b.type == "image")
    return Image.open(io.BytesIO(base64.b64decode(data))).convert("RGB")


def source_sections():
    diagram = Image.new("RGB", (60, 42), "white")
    ImageDraw.Draw(diagram).line([(8, 26), (25, 8), (45, 29)], fill="black", width=3)
    buf = io.BytesIO()
    diagram.save(buf, "PNG")
    data = base64.b64encode(buf.getvalue()).decode()
    return [
        "文字",
        "$$\\frac{3}{7}$$",
        "| 量 | 值 |\n|---|---|\n| R | 7 |",
        r"""\begin{circuitikz}[flowchart]
\draw (0,0) node[rectangle]{A};
\draw (0,-2) node[diamond]{B};
\draw[->] (0,0) -- (0,-2);
\end{circuitikz}""",
        f"![图](data:image/png;base64,{data})",
    ]


async def verify_review_guidance(client, home):
    path = home / "photo-ink-review-graded.png"
    graded_paper(path)
    source = {
        "markdown": "核对底纸和新增笔迹。 Compare the same marks before changing ink.",
        "paper_path": str(path),
        "style": {"font_size": 19, "ink": "#634854", "seed": 141},
    }
    guided = (
        await call(
            client,
            "save_section",
            **source,
            paper_mode="photo",
            paper_guides=[
                {"row": 0, "left": [20, 46], "right": [620, 46]},
                {"row": 15, "left": [20, 436], "right": [620, 436]},
            ],
        )
    ).structuredContent
    key = {"draft_id": guided["draft_id"], "revision": guided["revision"]}
    assert guided["paper"]["alignment"] == "manual_guides"
    assert "photo_ink_adjustment" not in guided
    before = await call(client, "preview_handwriting", **key, view="image")
    assert "photo_ink_adjustment" not in before.structuredContent

    review = await call(client, "preview_handwriting", **key, view="review")
    data = review.structuredContent
    assert data["paper_focus_check"]["status"] == "spatial_variation"
    hint = data["photo_ink_adjustment"]
    assert hint["describe_arguments"] == {**key, "group": "ink"}
    assert "photo_ink_focus" in hint["focus"] and "export_blur_gradient" in hint["focus"]
    assert "photo_ink_light" in hint["light"]
    assert "leave it unchanged" in hint["guidance"]
    assert json.JSONDecoder().raw_decode(review.content[0].text)[0]["photo_ink_adjustment"] == hint
    assert {"photo_ink_focus", "photo_ink_light"} <= (
        await call(client, "describe_controls", **hint["describe_arguments"])
    ).structuredContent["controls"].keys()
    after = await call(client, "preview_handwriting", draft_id=key["draft_id"], view="image")
    assert after.structuredContent["revision"] == key["revision"]
    assert next(x.data for x in before.content if x.type == "image") == next(
        x.data for x in after.content if x.type == "image"
    )

    # A visible imported paper and the same useful focus profile do not imply a projection.
    flat = (await call(client, "save_section", **source, paper_mode="flatten")).structuredContent
    assert flat["paper"]["alignment"] == "stored_canvas"
    key = {"draft_id": flat["draft_id"], "revision": flat["revision"]}
    review = (await call(client, "preview_handwriting", **key, view="review")).structuredContent
    assert review["paper_focus_check"]["status"] == "spatial_variation"
    assert "photo_ink_adjustment" not in review
    rejected = await client.call_tool(
        "tune_handwriting",
        {"draft_id": key["draft_id"], "expected_revision": key["revision"], "changes": {"photo_ink_light": 35}},
    )
    assert rejected.isError
    error = rejected.content[0].text
    for detail in ("paper projection", "stored_canvas", "paper_guides"):
        assert detail in error
    unchanged = (
        await call(client, "read_section", draft_id=key["draft_id"], view="source")
    ).structuredContent
    assert unchanged["revision"] == key["revision"]


async def verify(client, home):
    await verify_review_guidance(client, home)
    paper = Image.new("RGB", (480, 640), (199, 217, 224))
    pen = ImageDraw.Draw(paper)
    for y in range(60, 610, 38):
        pen.line((36, y, 442, y - 10), fill=(140, 161, 165), width=2)
    # The untouched printed mark must retain its sharp corners throughout.
    pen.rectangle((420, 530, 431, 547), fill="black")
    paper_path = home / "photo-ink-finish.png"
    paper.save(paper_path)
    sections = source_sections()
    saved = (
        await call(
            client,
            "save_section",
            markdown=sections[0],
            paper_path=str(paper_path),
            paper_guides=[
                {"row": 0, "left": [36, 60], "right": [442, 50]},
                {"row": 14, "left": [36, 592], "right": [442, 582]},
            ],
            style={"homework": True, "font_size": 26, "seed": 84, "ink": "#6a4754"},
        )
    ).structuredContent
    draft_id = saved["draft_id"]
    for i, source in enumerate(sections[1:], 1):
        await call(
            client,
            "save_section",
            draft_id=draft_id,
            expected_revision=i,
            markdown=source,
        )

    def key(revision):
        return {"draft_id": draft_id, "revision": revision}

    n = len(sections)

    async def leading_glyph(revision):
        result = await call(
            client,
            "preview_handwriting",
            **key(revision),
            view="layout",
            section=1,
            page=1,
            limit=1,
        )
        return result.structuredContent["glyphs"][0]

    glyph = await leading_glyph(n)
    edit = await call(
        client,
        "adjust_glyphs",
        draft_id=draft_id,
        section=1,
        page=1,
        expected_revision=n,
        ids=[glyph["id"]],
        dx=6,
    )
    base = edit.structuredContent["revision"]
    placed = await leading_glyph(base)
    old = [await picture(client, key(base), i + 1) for i in range(n)]
    gradient = {
        "from": {"x": 0.5, "y": 0.3, "sigma_px": 1.2},
        "to": {"x": 0.5, "y": 0.75, "sigma_px": 0},
    }
    await call(
        client,
        "tune_handwriting",
        draft_id=draft_id,
        expected_revision=base,
        preserve_local_adjustments=True,
        changes={"photo_ink_light": 75, "photo_ink_focus": gradient},
    )
    applied = base + 1
    assert (await leading_glyph(applied))["current_photo_quad"] == placed[
        "current_photo_quad"
    ]
    spec = (
        await call(client, "describe_controls", **key(applied), group="ink")
    ).structuredContent["values"]
    assert spec["photo_ink_light"] == 75 and spec["photo_ink_focus"] == gradient
    new = [await picture(client, key(applied), i + 1) for i in range(n)]
    for a, b in zip(old, new, strict=True):
        assert ImageChops.difference(a, b).getbbox()
        assert (
            b.crop((406, 510, 460, 560)).tobytes()
            == paper.crop((406, 510, 460, 560)).tobytes()
        )
        assert not ImageChops.subtract(b, paper).getbbox()
    archive = (
        await call(client, "export_handwriting", **key(applied), format="zip")
    ).structuredContent
    assert archive["pages"] == n
    with ZipFile(archive["path"]) as zipfile:
        for member, page in zip(zipfile.namelist(), new, strict=True):
            png = Image.open(io.BytesIO(zipfile.read(member))).convert("RGB")
            assert png.tobytes() == page.tobytes()
    await call(
        client,
        "tune_handwriting",
        draft_id=draft_id,
        expected_revision=applied,
        changes={"photo_ink_light": None, "photo_ink_focus": None},
    )
    for i, page in enumerate(old, 1):
        assert (await picture(client, key(applied + 1), i)).tobytes() == page.tobytes()
    plain = (await call(client, "save_section", markdown="plain")).structuredContent
    fail = await client.call_tool(
        "tune_handwriting",
        {
            "draft_id": plain["draft_id"],
            "expected_revision": 1,
            "changes": {"photo_ink_focus": gradient},
        },
    )
    assert fail.isError


async def main(binary):
    with TemporaryDirectory() as temporary:
        home = Path(temporary)
        async with isolated_session(binary, home) as (client, _):
            await verify(client, home)


if __name__ == "__main__":
    asyncio.run(main(Path(sys.argv[1]).resolve()))
