# /// script
# requires-python = ">=3.11"
# dependencies = ["mcp>=1.12,<2", "Pillow"]
# ///
"""Generate counterbalanced visual review packets and verify their source pixels over stdio."""

import argparse
import asyncio
import base64
import io
import json
import os
import random
from functools import partial
from pathlib import Path
from tempfile import TemporaryDirectory

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from PIL import Image, ImageChops, ImageDraw

from mcp_client import call as call_tool

TEXT = """雨落山川春意深。

松间清泉入晚云。

白鹭低飞穿绿野。

几点疏星照远村。

轻舟已过柳荫岸。

昨日题诗寄故人。

青石桥边闻短笛。

小窗闲坐读新书。"""

# Each task states the user's intent independently of the synthetic edit.
CASES = [
    (
        "keep",
        "山",
        "Keep 山 in the first line clearly legible and leave the nearby writing alone.",
        "revise",
    ),
    (
        "remove",
        "川",
        "Remove 川 from the first line, leaving the other writing alone.",
        "accept",
    ),
    (
        "move",
        "春",
        "Move 春 from the first line into the blank area directly below its original column.",
        "accept",
    ),
    (
        "collateral",
        "意",
        "Move 意 from the first line into the blank area directly below its original column and preserve 松 on the second line.",
        "revise",
    ),
    (
        "overlap",
        "深",
        "Two glyphs were deliberately stacked in the same box. Can the remaining ink prove that 深 is still independently visible?",
        "uncertain",
    ),
    (
        "keep",
        "泉",
        "Make 泉 in the second line slightly lighter but keep it clearly legible.",
        "accept",
    ),
    (
        "remove",
        "间",
        "Remove 间 from the second line, leaving the other writing alone.",
        "revise",
    ),
    (
        "collateral",
        "云",
        "Lighten 云 in the second line, keeping it legible and preserving 山 in the first line.",
        "accept",
    ),
]


def pixels(response):
    return [
        Image.open(io.BytesIO(base64.b64decode(item.data))).convert("RGB")
        for item in response.content
        if item.type == "image"
    ]


def rectangle(glyph):
    x, y, w, h = glyph["bounds"]
    return (x, y, x + w, y + h)


def polygon(box):
    left, top, right, bottom = box
    return [[left, top], [right, top], [right, bottom], [left, bottom]]


def union(*boxes):
    return (
        min(b[0] for b in boxes),
        min(b[1] for b in boxes),
        max(b[2] for b in boxes),
        max(b[3] for b in boxes),
    )


def shifted(b, dy):
    return (b[0], b[1] + dy, b[2], b[3] + dy)


def context_bounds(size, box):
    left, top, right, bottom = box
    return (
        max(0, left - 24),
        max(0, top - 18),
        min(size[0], right + 24),
        min(size[1], bottom + 18),
    )


def crop_with_context(image, box):
    return image.crop(context_bounds(image.size, box))


def save_pair(path, left, right, names):
    def scale(image):
        ratio = min(480 / image.width, 660 / image.height, 3)
        size = (round(image.width * ratio), round(image.height * ratio))
        return image.resize(size, Image.Resampling.LANCZOS)

    left, right = map(scale, (left, right))
    image = Image.new(
        "RGB",
        (left.width + right.width + 18, max(left.height, right.height) + 24),
        "white",
    )
    draw = ImageDraw.Draw(image)
    for x, panel, label in [(0, left, names[0]), (left.width + 18, right, names[1])]:
        draw.text((x + 2, 3), label, fill="black")
        image.paste(panel, (x, 22))
    image.save(path)


async def fixture(call, case):
    kind, char, _, _ = CASES[case]
    saved = (
        await call(
            "save_section",
            markdown=TEXT,
            style={
                "seed": 222 + case,
                "font_size": 32,
                "paper": "ruled",
            },
        )
    ).structuredContent
    key = {"draft_id": saved["draft_id"]}
    rows = (
        await call("preview_handwriting", **key, view="layout", limit=32)
    ).structuredContent["glyphs"]
    glyphs = {g.get("text"): g for g in rows}
    target = glyphs[char]
    source = rectangle(target)
    protected = glyphs["松" if case == 3 else "山"]
    revision = 1

    async def edit(glyph, **change):
        nonlocal revision
        revision = (
            await call(
                "adjust_glyphs",
                **key,
                section=1,
                page=1,
                expected_revision=revision,
                ids=[glyph["id"]],
                **change,
            )
        ).structuredContent["revision"]

    if kind == "overlap":
        await edit(glyphs["春"], target_quad=polygon(source))
    before = revision
    dest = source
    if case in (0, 1, 4):
        await edit(target, opacity=0)
    elif case in (2, 3):
        # A full line lands on written text. Use the blank rows below all eight lines.
        dy = 535
        await edit(target, dy=dy)
        dest = shifted(source, dy)
        if case == 3:
            await edit(protected, opacity=0)
    elif case == 6:
        await edit(glyphs["清"], opacity=0)
    else:
        await edit(target, opacity=72)
    return key, before, revision, source, dest, rectangle(protected), target["id"]


def dump(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")


def threshold_difference(first, second):
    red, green, blue = ImageChops.difference(first, second).split()
    peak = ImageChops.lighter(ImageChops.lighter(red, green), blue)
    return peak.point(lambda p: 255 if p >= 8 else 0)


async def verify_region(
    call, key, before, after, source, dest, protected, target_id, case, raw, full
):
    async def compare(box, old=None):
        extra = {"previous_region": polygon(old)} if old and old != box else {}
        return await call(
            "preview_handwriting",
            **key,
            view="review",
            revision=after,
            compare_revision=before,
            region=polygon(box),
            **extra,
        )

    def wire_bytes(result):
        return len(result.model_dump_json(by_alias=True, exclude_none=True).encode())

    def check_crops(response, bounds):
        data = response.structuredContent
        x, y, r, b = bounds
        assert data["crop_bounds"] == [x, y, r - x, b - y]
        paper, old, new = pixels(response)
        for frame, image in zip([old, new], raw, strict=True):
            assert ImageChops.difference(frame, image.crop(bounds)).getbbox() is None
        return paper, old, new

    def changed(image):
        return image.histogram()[255]

    expected = threshold_difference(*raw)
    tight = await compare(dest, source)
    bounds = union(source, dest)
    paper, old, new = check_crops(tight, bounds)
    measured = tight.structuredContent
    for name, box in [("region", dest), ("previous_region", source)]:
        if name == "previous_region" and source == dest:
            continue
        local_box = tuple(v - bounds[i % 2] for i, v in enumerate(box))
        for revision, img in [("before", old), ("after", new)]:
            counts = measured[revision][name]
            assert counts["sampled_pixels"] == (box[2] - box[0]) * (box[3] - box[1])
            assert counts["ink_pixels"] == changed(
                threshold_difference(img, paper).crop(local_box)
            )
        assert measured["difference"][name + "_changed_pixels"] == changed(
            expected.crop(box)
        )
    mask = Image.new("L", expected.size)
    for box in [source, dest]:
        mask.paste(255, box)
    inside = changed(ImageChops.multiply(expected, mask))
    delta = measured["difference"]
    assert delta["inside_union_changed_pixels"] == inside
    assert delta["outside_union_changed_pixels"] == changed(expected) - inside
    a, b = (
        measured["before"]["region"]["ink_pixels"],
        measured["after"]["region"]["ink_pixels"],
    )
    if case in (0, 1):
        # A neighboring glyph can enter a selected rectangle after the target is hidden.
        assert a > b
        if case == 0:
            assert b == 0
        assert full[1].structuredContent["evidence"]["visibility"] == "inspect_visually"
    if case in (2, 3):
        assert (
            b > a
            and measured["before"]["previous_region"]["ink_pixels"]
            > measured["after"]["previous_region"]["ink_pixels"]
        )
    if case == 4:
        assert (
            b > 0
        )  # The surviving, deliberately superimposed glyph still has strokes.
    if case == 6:
        assert b > 0 and delta["outside_union_changed_pixels"] > 0

    # The packets show the exact native pixels returned by a request with neighboring context.
    dst, src = [context_bounds(raw[0].size, box) for box in (dest, source)]
    primary = await compare(dst, src)
    check_crops(primary, union(src, dst))
    displayed = [primary]
    protected_metrics = None
    if case in (3, 7):
        box = context_bounds(raw[0].size, protected)
        companion = await compare(box)
        check_crops(companion, box)
        protected_tight = await compare(protected)
        check_crops(protected_tight, protected)
        tight_change = protected_tight.structuredContent["difference"][
            "region_changed_pixels"
        ]
        context_change = companion.structuredContent["difference"][
            "region_changed_pixels"
        ]
        assert tight_change == changed(expected.crop(protected))
        assert context_change == changed(expected.crop(box))
        protected_metrics = {
            "tight_changed_pixels": tight_change,
            "context_changed_pixels": context_change,
        }
        if case == 3:
            assert tight_change > 0
        else:
            # Isolate the opacity change after the first fine edit has activated glyph rendering.
            # Both blind frames remain the original before/after images.
            restored = await call(
                "adjust_glyphs",
                **key,
                section=1,
                page=1,
                expected_revision=after,
                ids=[target_id],
                opacity=100,
            )
            control = await call(
                "preview_handwriting",
                **key,
                view="review",
                revision=restored.structuredContent["revision"],
                compare_revision=after,
                region=polygon(dest),
            )
            matched = control.structuredContent["difference"]
            assert (
                matched["inside_union_changed_pixels"] > 0
                and matched["outside_union_changed_pixels"] == 0
            )
            assert not (
                dest[0] < protected[2]
                and protected[0] < dest[2]
                and dest[1] < protected[3]
                and protected[1] < dest[3]
            )
            protected_metrics["matched_restore_inside_target_changed_pixels"] = matched[
                "inside_union_changed_pixels"
            ]
            protected_metrics["matched_restore_outside_target_changed_pixels"] = (
                matched["outside_union_changed_pixels"]
            )
        displayed.append(companion)
    return {
        "case": case + 1,
        "page_calls": len(full),
        "local_calls": len(displayed),
        "page_bytes": sum(map(wire_bytes, full)),
        "local_bytes": sum(map(wire_bytes, displayed)),
        "tight_region_before_ink": a,
        "tight_region_after_ink": b,
        "difference": delta,
        "protected": protected_metrics,
        "page_visibility": full[1].structuredContent["evidence"]["visibility"],
    }


async def generate(client, out, verify):
    call = partial(call_tool, client)

    layouts = {}
    rng = random.Random(1729)
    local = list(range(8))
    rng.shuffle(local)
    for group in "AB":
        order = list(range(10))
        rng.shuffle(order)
        folder = out / group
        folder.mkdir(parents=True, exist_ok=True)
        layouts[group] = (folder, order)
    private = out / "private"
    private.mkdir(exist_ok=True)
    keys, results = {}, []
    prompts = {group: {} for group in layouts}
    for case, (_, char, question, answer) in enumerate(CASES):
        print(f"Rendering case {case + 1}/{len(CASES)}", flush=True)
        key, before, after, source, dest, protected, target_id = await fixture(
            call, case
        )
        area = union(source, dest)

        async def preview(view, revision):
            return await call(
                "preview_handwriting", **key, revision=revision, view=view
            )

        whole, raw = [], []
        full_wire = []
        for revision in (before, after):
            response = await preview("review", revision)
            full_wire.append(response)
            whole.append(pixels(response)[1])
            raw.append(pixels(await preview("image", revision))[0])
        if verify:
            results.append(
                await verify_region(
                    call,
                    key,
                    before,
                    after,
                    source,
                    dest,
                    protected,
                    target_id,
                    case,
                    raw,
                    full_wire,
                )
            )
            dump(private / "metrics.json", results)
        local_images = [crop_with_context(im, area) for im in raw]
        # Give both readers the requested protected field. Its ROI costs another call.
        for group, (folder, order) in layouts.items():
            task = f"T{order.index(case) + 1:02d}"
            use_local = (case in local[:4]) == (group == "A")
            panels = local_images if use_local else whole
            save_pair(folder / f"{task}.png", *panels, ["Before", "After"])
            if use_local and case in (3, 7):
                save_pair(
                    folder / f"{task}-protected.png",
                    *(crop_with_context(im, protected) for im in raw),
                    ["Protected before", "Protected after"],
                )
            prompts[group][task] = question
            keys[f"{group}/{task}"] = {
                "case": case + 1,
                "mode": "local" if use_local else "page",
                "answer": answer,
            }
        if case in (2, 3):
            # Restore the same row's text with a small local change in rhythm and tilt.
            style_case = case + 6
            rows = (await preview("layout", before)).structuredContent["glyphs"]
            glyph = next(g for g in rows if g.get("text") == char)
            styled = await call(
                "adjust_glyphs",
                **key,
                section=1,
                page=1,
                expected_revision=after,
                ids=[glyph["id"]],
                dx=5 if case == 2 else -4,
                dy=-5 if case == 2 else 4,
                angle=9 if case == 2 else -8,
            )
            version = styled.structuredContent["revision"]
            xs = (0, max(10, min(source[1], dest[1]) - 35), 450, source[3] + 25)
            natural = [
                im.crop(xs)
                for im in (raw[0], pixels(await preview("image", version))[0])
            ]
            for group, (folder, order) in layouts.items():
                task = f"T{order.index(style_case) + 1:02d}"
                swap = (group == "A") == (case == 3)
                pair = natural[::-1] if swap else natural
                save_pair(folder / f"{task}.png", *pair, ["A", "B"])
                prompts[group][task] = (
                    "Appearance only. Which version of the handwriting has more natural spacing "
                    "and flow? Answer A, B, tie, or uncertain, with a visible reason."
                )
                keys[f"{group}/{task}"] = {
                    "case": style_case + 1,
                    "candidate_before": "B" if swap else "A",
                }
    for group, (folder, _) in layouts.items():
        prompt = (
            "Read each image at its provided size. Each T-number is independent. "
            "The panels show two rendered snapshots. Some views show the full page, "
            "others show a local crop; a supplementary image shows a named protected field. "
            "For an edit request, answer accept / revise / uncertain with one concrete visual "
            "observation. Use uncertain if the requested conclusion cannot be justified from "
            "the displayed pixels. For appearance questions use the specified A/B scale. "
            "Return one line per T-number. Do not inspect source, neighboring folders, or image "
            "metadata.\n\n"
        )
        (folder / "TASKS.txt").write_text(
            prompt
            + "\n".join(
                f"{task}  {prompts[group][task]}" for task in sorted(prompts[group])
            ),
            encoding="utf-8",
        )
    dump(private / "key.json", keys)


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument(
        "--packet-only",
        action="store_true",
        help="Generate visuals on a build without local review.",
    )
    args = parser.parse_args()
    with TemporaryDirectory() as directory:
        env = {**os.environ, "PANACHE_MCP_HOME": directory}
        params = StdioServerParameters(command=str(args.binary.resolve()), env=env)
        async with stdio_client(params) as streams, ClientSession(*streams) as client:
            await client.initialize()
            await generate(client, args.out, not args.packet_only)


if __name__ == "__main__":
    asyncio.run(main())
