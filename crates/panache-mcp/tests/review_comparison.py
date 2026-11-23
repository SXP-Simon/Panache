"""Page comparison through actual MCP calls, using a synthetic sloping ruled sheet."""

import sqlite3
import struct
import zlib
from contextlib import closing
from pathlib import Path


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


async def exercise(client, directory, call):
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
    assert "missing_after_review" in (await compare(4, 5))["comparison"]["limitations"]
    await review(5)
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
    return key, old["review_id"], quote
