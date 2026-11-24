"""Page comparison through actual MCP calls, using a synthetic sloping ruled sheet."""

import base64
import io
import sqlite3
import struct
import zlib
from contextlib import closing
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageStat


def slanted_sheet(path):
    width, height = 400, 500
    left, right = 40, 360
    rows = [88 + 38 * i for i in range(9)]
    pixels = bytearray()
    for y in range(height):
        pixels.append(0)
        for x in range(width):
            on_rule = left <= x <= right and y + (x - left) // 20 in rows
            pixels.append(75 if on_rule else 235)

    def chunk(tag, data):
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data))
        )

    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(pixels))
        + chunk(b"IEND", b"")
    )
    return [
        {"row": i, "left": [left, rows[i]], "right": [right, rows[i] - 16]}
        for i in (0, 8)
    ]


async def unruled_artwork(client, directory, call):
    path = directory / "unruled.png"
    paper = Image.new("RGB", (1100, 640), "#eee5d8")
    ImageDraw.Draw(paper).ellipse((830, 150, 1020, 480), fill="#ada7ba")
    paper.save(path)
    saved = await call(client, "save_section", markdown="春风又绿江南岸。", paper_path=str(path),
                       style={"font_size": 34, "seed": 27})
    key = {"draft_id": saved.structuredContent["draft_id"]}
    assert saved.structuredContent["paper"]["alignment"] == "unverified"
    assert "哪一侧" in saved.structuredContent["placement_guidance"]
    assert "已委托选位" in saved.content[0].text
    path.unlink()
    # The user picks the left side, leaving the drawing on the right clear.
    await call(client, "tune_handwriting", **key, expected_revision=1, paper_guides=[
        {"row": 0, "left": [100, 180], "right": [650, 170]},
        {"row": 5, "left": [70, 450], "right": [700, 440]},
    ])
    whole = (await call(client, "preview_handwriting", **key, view="review")).structuredContent
    appearance = whole["photo_appearance"]
    args = appearance["preview_arguments"]
    assert args["revision"] == 2 and args["draft_id"] == key["draft_id"]
    assert "ink_softness" in appearance["controls"]
    archived = await call(client, "read_section", **key, view="review", review_id=whole["review_id"])
    assert "photo_appearance" not in archived.structuredContent["evidence"]
    crop = await call(client, "preview_handwriting", **args)
    x, y, w, h = crop.structuredContent["crop_bounds"]
    assert crop.structuredContent["crop_image_size"] == [w, h] and max(w, h) <= 900
    assert crop.structuredContent["after"]["region"]["ink_pixels"] > 0

    def images(result):
        return [Image.open(io.BytesIO(base64.b64decode(item.data))).convert("RGB")
                for item in result.content if item.type == "image"]

    base, finished = images(crop)
    full = images(await call(client, "preview_handwriting", **key, revision=2))[0]
    bounds = (x, y, x + w, y + h)
    assert base.tobytes() == paper.crop(bounds).tobytes()
    assert finished.tobytes() == full.crop(bounds).tobytes()
    assert full.crop((800, 0, 1100, 640)).tobytes() == paper.crop((800, 0, 1100, 640)).tobytes()
    for rev, change in [(2, {"ink_softness": 0.8}), (3, {"ink": "#843522"}), (4, {"ink_opacity": 70})]:
        await call(client, "tune_handwriting", **key, expected_revision=rev, changes=change)
        paired = await call(client, "preview_handwriting", **{**args, "revision": rev + 1},
                            compare_revision=rev)
        assert paired.structuredContent["difference"]["region_changed_pixels"] > 0, change
        paper_crop, before, after = images(paired)
        assert paper_crop.tobytes() == base.tobytes() and before.tobytes() == finished.tobytes()
        old_delta = ImageChops.difference(base, before).convert("L")
        new_delta = ImageChops.difference(base, after).convert("L")
        if "ink_softness" in change:
            # Feathered strokes reach more of the surrounding paper.
            assert new_delta.histogram()[0] < old_delta.histogram()[0]
        elif "ink" in change:
            # Moving the pen toward brick red leaves more red in the finished crop.
            assert ImageStat.Stat(after).sum[0] > ImageStat.Stat(before).sum[0]
        else:
            assert ImageStat.Stat(new_delta).sum[0] < ImageStat.Stat(old_delta).sum[0]
        finished = after


async def check_filtered_history(client, call, draft_id):
    key = {"draft_id": draft_id}
    await call(client, "save_section", **key, expected_revision=3, markdown="第二节")
    for revision, section, origin, note in [
        (3, 1, "user_quote", "第一节的墨色保留。"),
        (4, 2, "user_quote", "第二节用淡墨。"),
        (4, 1, "model_observation", "我觉得第一节也可以调淡。"),
        (4, 1, "user_quote", "第一节维持原样。"),
    ]:
        review = await call(client, "preview_handwriting", **key, revision=revision,
                            section=section, view="review")
        await call(client, "annotate_review", **key, review_id=review.structuredContent["review_id"],
                   origin=origin, text=note)

    async def history(**args):
        result = await call(client, "read_section", **key, view="trajectory", **args)
        return result.structuredContent

    all_events = (await history(limit=50))["events"]
    section_events = [e for e in all_events if e["section"] == 1]
    assert (await history(section=1))["events"] == section_events
    quotes = [e for e in section_events if e["origin"] == "user_quote"]
    assert [e["details"]["text"] for e in quotes] == ["第一节维持原样。", "第一节的墨色保留。"]
    query = dict(section=1, feedback_origin="user_quote", limit=1)
    first = await history(**query)
    assert first["events"] == quotes[:1] and first["next_offset"] == 1
    second = await history(**query, offset=first["next_offset"])
    assert second["events"] == quotes[1:] and second["next_offset"] is None
    assert (await history(**query, revision=3))["events"] == quotes[1:]
    empty = await history(section=2, feedback_origin="model_observation")
    assert empty["events"] == [] and empty["next_offset"] is None
    models = (await history(feedback_origin="model_observation"))["events"]
    assert [e["details"]["text"] for e in models] == ["我觉得第一节也可以调淡。"]
    # Continue both snapshots after a newer edit, a backfilled review and two
    # annotations on old reviews (including one that sorts before page one).
    full_first = await history(limit=1)
    await call(client, "save_section", **key, expected_revision=4, markdown="第三节")
    await call(client, "preview_handwriting", **key, revision=2, section=1, view="review")
    for quote in quotes:
        await call(client, "annotate_review", **key, review_id=quote["review_id"],
                   origin="user_quote", text="翻页期间补录。")
    for start, expected in [(first, quotes), (full_first, all_events)]:
        result = start
        actual = list(start["events"])
        while cursor := result.get("next_cursor"):
            result = await history(cursor=cursor, limit=2)
            assert result["revision"] == 4
            actual.extend(result["events"])
            assert len(actual) <= len(expected)
        assert actual == expected
    assert (await history(limit=50))["revision"] == 5
    fresh = (await history(section=1, feedback_origin="user_quote"))["events"]
    assert sum(event["details"]["text"] == "翻页期间补录。" for event in fresh) == 2

    token = first["next_cursor"]
    for invalid in [dict(view="summary", cursor=token), dict(view="trajectory", cursor="???"),
                    dict(view="trajectory", cursor=token, section=2),
                    dict(view="trajectory", cursor=token, offset=1),
                    dict(view="trajectory", cursor=token, revision=5),
                    dict(view="trajectory", cursor=token, feedback_origin="model_observation"),
                    dict(view="summary", feedback_origin="user_quote"),
                    dict(view="trajectory", section=0)]:
        assert (await client.call_tool("read_section", {**key, **invalid})).isError


async def exercise(client, directory, call):
    await unruled_artwork(client, directory, call)
    path = directory / "slanted.png"
    guides = slanted_sheet(path)
    shifted = [
        {
            **g,
            "left": [g["left"][0], g["left"][1] + 7],
            "right": [g["right"][0], g["right"][1] + 7],
        }
        for g in guides
    ]
    saved = await call(
        client,
        "save_section",
        markdown="逐字检查书写的基线方向。\n\n观察第二行字的位置。\n\n保留用户喜欢的墨色。",
        paper_path=str(path),
        paper_guides=shifted,
        style={"font_size": 22, "seed": 31},
    )
    key = {"draft_id": saved.structuredContent["draft_id"]}

    async def tune(rev, **args):
        await call(client, "tune_handwriting", **key, expected_revision=rev, **args)

    async def review(rev):
        return (
            await call(
                client, "preview_handwriting", **key, revision=rev, view="review"
            )
        ).structuredContent

    async def compare(before, after):
        response = await call(
            client,
            "preview_handwriting",
            **key,
            revision=after,
            view="review",
            compare_revision=before,
        )
        assert all(part.type != "image" for part in response.content)
        return response.structuredContent

    def assets():
        with closing(sqlite3.connect(directory / "drafts.sqlite3")) as db:
            counts = [
                db.execute(
                    f"SELECT count(*),coalesce(sum(length({col})),0) FROM {table}"
                ).fetchone()
                for table, col in (("papers", "image"), ("draft_fonts", "bytes"))
            ]
        return counts, sorted(
            p.name
            for p in directory.rglob("*")
            if p.is_file() and not p.name.startswith("drafts.sqlite3")
        )

    await tune(1, changes={"ink": "#363840"})
    await tune(2, changes={"ink_opacity": 87})
    old = await review(3)
    await tune(3, paper_guides=guides, note="Align to the printed lines.")
    new = await review(4)
    quote = "保留 v3 的墨色，采用 v4 的位置。"
    await call(
        client,
        "annotate_review",
        **key,
        review_id=old["review_id"],
        origin="user_quote",
        text=quote,
    )
    await call(
        client,
        "annotate_review",
        **key,
        review_id=new["review_id"],
        origin="model_observation",
        text="上部基线更贴近横线。",
    )
    inventory = assets()
    result = await compare(3, 4)
    usage = (await call(client, "storage_usage", **key)).structuredContent
    for _ in range(10):
        assert await compare(3, 4) == result
    repeated = (await call(client, "storage_usage", **key)).structuredContent
    assert repeated["logical_payload"] == usage["logical_payload"]
    assert repeated["export_directory_bytes"] == usage["export_directory_bytes"]
    assert assets() == inventory
    exported = (await call(client, "export_handwriting", **key, format="zip")).structuredContent
    size = Path(exported["path"]).stat().st_size
    after = (await call(client, "storage_usage", **key)).structuredContent
    assert after["export_directory_bytes"] == repeated["export_directory_bytes"] + size
    assert after["delivered_bytes"] == size and after["eligible_temp_bytes"] == 0
    planned = (await call(client, "plan_cleanup", **key)).structuredContent
    assert planned["plan_id"] is None
    assert [entry["class"] for entry in planned["entries"]] == ["delivered_report_only"]
    assert [a["revision"] for a in result["actions"]] == [4]
    assert result["actions"][0]["details"]["paper_guides"] == guides
    assert result["before"]["feedback"] == [{"origin": "user_quote", "text": quote}]
    assert result["after"]["review_id"] == new["review_id"]
    delta = result["comparison"]["delta"]
    assert delta["global_ink_settings_equal"]
    top, _, bottom = delta["by_image_third"]
    assert min(top["supported_before_after"]) >= 3 and top["median_abs_dy_px"] < 0, (
        result
    )
    assert (
        bottom["median_abs_dy_px"] is None
        and bottom["limitation"] == "insufficient_ridge_support"
    )
    await tune(4, changes={"ink_opacity": 0})
    inventory = assets()
    for _ in range(2):
        empty = await call(client, "read_section", **key, view="review", section=1, page=1)
        assert empty.structuredContent["status"] == "no_recorded_review"
        assert empty.structuredContent["revision"] == empty.structuredContent["latest_draft_revision"] == 5
        assert empty.structuredContent["review_id"] is None
        assert all(block.type == "text" for block in empty.content)
    assert assets() == inventory
    assert "missing_after_review" in (await compare(4, 5))["comparison"]["limitations"]
    assert "photo_appearance" in await review(5)
    invisible = (await compare(4, 5))["comparison"]["delta"]
    assert (
        invisible["visibility_after"] == "no_visible_change"
        and invisible["by_image_third"][0]["median_abs_dy_px"] == 0
    )
    await tune(5, changes={"right_margin": 318})
    await review(6)
    reflow = (await compare(4, 6))["comparison"]
    assert (
        reflow["delta"] is None
        and "page_content_changed_or_repaginated" in reflow["limitations"]
    )

    async def incompatible(draft_id, before, after, reason):
        result = await client.call_tool("preview_handwriting", {
            "draft_id": draft_id, "view": "review", "revision": after,
            "compare_revision": before, "region": [[0, 0], [30, 0], [30, 30]],
        })
        assert result.isError and reason in result.content[0].text, result.content[0]
        assert all(part.type != "image" for part in result.content)

    await incompatible(key["draft_id"], 4, 6, "page_content_changed_or_repaginated")
    preset = (await call(client, "save_section", markdown="字", style={"seed": 13})).structuredContent
    preset_id = preset["draft_id"]
    plain = await call(client, "preview_handwriting", draft_id=preset_id, view="review")
    assert "photo_appearance" not in plain.structuredContent
    await call(client, "tune_handwriting", draft_id=preset_id, expected_revision=1, changes={"paper": "grid"})
    await incompatible(preset_id, 1, 2, "different_reference_paper")
    await call(client, "tune_handwriting", draft_id=preset_id, expected_revision=2, changes={"width": 800})
    await incompatible(preset_id, 2, 3, "different_image_dimensions")
    await check_filtered_history(client, call, preset_id)
    return key, old["review_id"], quote
