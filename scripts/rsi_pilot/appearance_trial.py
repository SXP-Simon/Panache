"""Run a bounded, post-hoc local-softness trial on the public depth sheet only.

Usage: python appearance_trial.py prepare|render|assess --run ORIGINAL_RUN --out NEW_DIRECTORY
The prepare stage regenerates only the public draft in a fresh home, verifies both
starting PNGs and asks Terra for one proposal. No private database is copied.
"""

import argparse
import json
import random
import sqlite3
from contextlib import closing
from pathlib import Path

import numpy as np
from appearance import appearance
from benchmark import (
    Server,
    create_draft,
    digest,
    read,
    save_image,
    sections_for,
    write,
)
from codex_judge import run as ask_model
from paper_detector import detect_guides
from paper_geometry import generate_depth_paper
from PIL import Image, ImageDraw, ImageFont

# Two matched native-size windows on each sheet. Their pixels are never resized.
BOXES = [(52, 88, 610, 348), (52, 784, 610, 1044)]


def package(folder):
    pages = [Image.open(folder / f"p{s}.png").convert("RGB") for s in (1, 2)]
    details = Image.new("RGB", (1116, 520), "white")
    overview = Image.new("RGB", (840, 560), "white")
    for n, page in enumerate(pages):
        overview.paste(page.resize((420, 560), Image.Resampling.LANCZOS), (420 * n, 0))
        for row, box in enumerate(BOXES):
            details.paste(page.crop(box), (558 * n, 260 * row))
    details.save(folder / "details.png")
    overview.save(folder / "overview.png")


def model_prompt(folder, name, prompt, images):
    path = folder / f"{name}-prompt.txt"
    path.write_text(prompt, encoding="utf-8")
    ask_model(path, images, "gpt-6.1-terra", folder / name)
    return read(folder / name / "decision.json")


def capture(server, folder, draft, rev):
    with_pages = {}
    save_image(
        server.call("preview_handwriting", draft_id=draft, revision=rev, view="paper"),
        folder / "paper.png",
    )
    for section in (1, 2):
        key = {"draft_id": draft, "revision": rev, "section": section, "page": 1}
        last = server.call(
            "read_section",
            draft_id=draft,
            revision=rev,
            section=section,
            view="review",
            page="last",
        )["structuredContent"]
        if last["page"] != 1:
            raise ValueError("Unexpected page count")
        info = server.call(
            "read_section",
            draft_id=draft,
            revision=rev,
            section=section,
            view="source",
            limit=4000,
        )["structuredContent"]
        assert info["markdown"] == sections_for("public-depth")[section - 1]
        file = f"p{section}.png"
        save_image(
            server.call("preview_handwriting", **key, view="image"), folder / file
        )
        review = server.call("preview_handwriting", **key, view="review")[
            "structuredContent"
        ]
        glyphs = []
        offset = 0
        while offset is not None:
            layout = server.call(
                "preview_handwriting", **key, view="layout", offset=offset, limit=32
            )["structuredContent"]
            glyphs.extend(layout["glyphs"])
            offset = layout["next_offset"]
        write(folder / f"glyphs-{section}.json", glyphs)
        with_pages[str(section)] = {
            "sha256": digest((folder / file).read_bytes()),
            "glyphs": len(glyphs),
            "review_id": review["review_id"],
            "source_unchanged": True,
            "appearance": appearance(folder, {"image": file}, review, glyphs),
        }
    write(folder / "pages.json", with_pages)
    package(folder)
    return with_pages


def prepare(original, out):
    out.mkdir(parents=True, exist_ok=False)
    init = out / "baseline"
    init.mkdir()
    info = read(original / "public-depth/B/state.json")
    cfg = info["runtime"].copy()
    # Same native build as the main experiment; start only with a new generated paper.
    paper = out / "paper.png"
    generate_depth_paper(paper)
    assert digest(paper.read_bytes()) == info["sha256"]
    with Server(cfg, init, "rebuild_public_candidate") as s:
        seed = create_draft(s, paper, sections_for("public-depth"))
        result = s.call(
            "tune_handwriting",
            draft_id=seed["draft_id"],
            expected_revision=seed["revision"],
            paper_guides=detect_guides(paper),
            changes={},
        )["structuredContent"]
        rev = result["revision"]
        draft = seed["draft_id"]
        assert rev == 3
        pages = capture(s, init, draft, rev)
    assert [pages[str(n)]["sha256"] for n in (1, 2)] == [
        p["sha256"] for p in info["snapshots"]["3"]
    ]
    write(out / "run.json", {"runtime": cfg, "draft": draft, "revision": rev})
    readings = {
        s: {
            k: v
            for k, v in page["appearance"].items()
            if k != "mcp_original_paper_focus"
        }
        for s, page in pages.items()
    }
    prompt = (
        """独立处理一次有限的照片笔迹试验。两页作业使用同张模拟纸，必须保留内容、排版和近处可读性。附件1为两页整图，附件2上排为两页远处的原尺寸裁剪、下排为两页近处裁剪。比较笔画和附近的纸印。数值是近似，不必使墨色与印刷一致。请决定是保持当前稿，还是试验仅柔化远处笔画。你只决定一次，不能在看到反馈后调参。用 JSON 回复，action 取 keep 或 try_local；后者给 softness (0.1 至 2.0，0.1 步长，纸面像素增量)、max_center_y (整页高度比例，0.10 至 0.50)，reason, expected。局部作用于两个页面选区内每个字的中心，另外会评价同等强度的全局对照。不要调用工具。\n"""
        + str(readings)
    )
    decision = model_prompt(
        out, "proposal", prompt, [init / "overview.png", init / "details.png"]
    )
    print(decision["action"])


def branch(out, name):
    folder = out / name
    folder.mkdir()
    source = out / "baseline" / "drafts.sqlite3"
    with (
        closing(sqlite3.connect(source.as_uri() + "?mode=ro", uri=True)) as src,
        closing(sqlite3.connect(folder / "drafts.sqlite3")) as dst,
    ):
        src.backup(dst)
    return folder


def selected(glyph, max_y):
    quad = glyph.get("current_photo_quad", glyph.get("photo_quad"))
    return bool(quad) and sum(p[1] for p in quad) / len(quad) <= max_y


def candidate(out, name, settings, proposal):
    folder = branch(out, name)
    draft, rev = settings["draft"], settings["revision"]
    sigma = proposal["softness"]
    ceiling = proposal["max_center_y"] * 1120
    applied = []
    with Server(settings["runtime"], folder, "appearance_edit") as server:
        if name == "local":
            for section in (1, 2):
                original = read(out / "baseline" / f"glyphs-{section}.json")
                for offset in range(0, len(original), 32):
                    expected = [
                        g["id"]
                        for g in original[offset : offset + 32]
                        if selected(g, ceiling)
                    ]
                    if not expected:
                        continue
                    current = server.call(
                        "preview_handwriting",
                        draft_id=draft,
                        section=section,
                        page=1,
                        revision=rev,
                        view="layout",
                        offset=offset,
                        limit=32,
                    )["structuredContent"]["glyphs"]
                    ids = [g["id"] for g in current if selected(g, ceiling)]
                    if ids != expected:
                        raise ValueError(
                            "Appearance-only edits changed selected membership"
                        )
                    result = server.call(
                        "adjust_glyphs",
                        draft_id=draft,
                        expected_revision=rev,
                        section=section,
                        page=1,
                        ids=ids,
                        softness=sigma,
                        note="远端笔画与原纸清晰度的局部比较。",
                    )["structuredContent"]
                    rev = result["revision"]
                    applied.append(
                        {"section": section, "glyph_ids": ids, "revision": rev}
                    )
        else:
            control = server.call(
                "describe_controls", draft_id=draft, revision=rev, group="ink"
            )["structuredContent"]["values"]
            strength = round(control["ink_softness"] + sigma, 1)
            if strength > 2:
                raise ValueError(
                    "Global matched-strength comparison exceeds supported range"
                )
            rev = server.call(
                "tune_handwriting",
                draft_id=draft,
                expected_revision=rev,
                changes={"ink_softness": strength},
                preserve_local_adjustments=True,
            )["structuredContent"]["revision"]
            applied.append(
                {
                    "global_before": control["ink_softness"],
                    "global_after": strength,
                    "revision": rev,
                }
            )
        write(folder / "edits.json", applied)
        capture(server, folder, draft, rev)
        export = server.call(
            "export_handwriting", draft_id=draft, revision=rev, format="pdf"
        )["structuredContent"]
        assert export["pages"] == 2
        write(
            folder / "export.json",
            {
                "pages": export["pages"],
                "revision": rev,
                "pdf_sha256": digest(Path(export["path"]).read_bytes()),
            },
        )


def render(out):
    proposal = read(out / "proposal/decision.json")
    if proposal["action"] == "keep":
        return
    if (
        proposal["action"] != "try_local"
        or not 0.10 <= proposal["max_center_y"] <= 0.50
        or not 0.1 <= proposal["softness"] <= 2
        or abs(proposal["softness"] * 10 - round(proposal["softness"] * 10)) > 1e-6
    ):
        raise ValueError("Proposal outside trial contract")
    from concurrent.futures import ThreadPoolExecutor

    settings = read(out / "run.json")
    with ThreadPoolExecutor(max_workers=2) as pool:
        for future in [
            pool.submit(candidate, out, name, settings, proposal)
            for name in ("local", "global")
        ]:
            future.result()


def collateral(out, name, section):
    baseline = out / "baseline"
    with (
        Image.open(baseline / f"p{section}.png") as before,
        Image.open(out / name / f"p{section}.png") as after,
    ):
        a = np.asarray(before.convert("RGB"))
        b = np.asarray(after.convert("RGB"))
    changed = np.any(a != b, axis=2)
    original = read(baseline / f"glyphs-{section}.json")
    revised = read(out / name / f"glyphs-{section}.json")
    assert [g["id"] for g in original] == [g["id"] for g in revised]

    def quad(g):
        return np.asarray(g.get("current_photo_quad", g["photo_quad"]))

    max_shift = max(
        float(np.linalg.norm(quad(x) - quad(y), axis=1).max())
        for x, y in zip(original, revised, strict=True)
    )
    # Count exact pixel changes in protected lower regions including the writing.
    return {
        "changed_pixels": int(changed.sum()),
        "bottom_third_changed_pixels": int(changed[2 * len(changed) // 3 :].sum()),
        "max_glyph_corner_displacement_px": max_shift,
    }


def compare_panel(out, names):
    # One section at full native magnification. All arms use the same windows.
    boxes = [(105, 132, 475, 278), (90, 802, 460, 948)]
    header, gutter = 34, 8
    canvas = Image.new(
        "RGB",
        (len(names) * (370 + gutter) - gutter, 2 * (146 + header) + gutter),
        "white",
    )
    draw = ImageDraw.Draw(canvas)
    font = ImageFont.load_default(size=18)
    proposal = read(out / "proposal/decision.json")
    labels = {"baseline": "Original"}
    if proposal["action"] == "try_local":
        for kind in ("local", "global"):
            labels[kind] = f"{kind.title()} +{proposal['softness']} px"
    for col, name in enumerate(names):
        with Image.open(out / name / "p1.png") as page:
            for row, box in enumerate(boxes):
                x = col * (370 + gutter)
                y = row * (146 + header + gutter)
                draw.text(
                    (x + 2, y + 6),
                    ("Far" if row == 0 else "Near") + "  /  " + labels[name],
                    font=font,
                    fill="#283029",
                )
                canvas.paste(page.crop(box), (x, y + header))
    canvas.save(out / "appearance-comparison.png")


def assess(out):
    settings = read(out / "run.json")
    proposal = read(out / "proposal/decision.json")
    names = (
        ["baseline"]
        if proposal["action"] == "keep"
        else ["baseline", "local", "global"]
    )
    compare_panel(out, names)
    model_images = []
    codes = ["Q7", "H2", "M8"][: len(names)]
    order = names.copy()
    random.Random(19043).shuffle(order)
    for code, name in zip(codes, order, strict=True):
        # Opaque paths and identical packet layout. The reviewer sees no rules, scores or treatment labels.
        import shutil

        blind = out / "blind" / code
        blind.mkdir(parents=True)
        for file in ("overview.png", "details.png"):
            shutil.copy2(out / name / file, blind / file)
            model_images.append(blind / file)
    prompt = (
        "你是独立照片作业验收员。只看附件。版本依次为 "
        + ", ".join(codes)
        + "，每个版本的第一张是两页概览，第二张为原尺寸远端（上排）和近端（下排）各两页。核查数字、公式是否可读，远近笔迹是否顺着纸张清晰度变化，近端是否被过度柔化。允许并列或看不出差别。不必偏好更模糊的稿。回复 JSON {verdicts:{代码:{readability,far_fit,near_fit,deliverable}},preferred:[代码],reason}。不要使用任何工具。"
    )
    verdict = model_prompt(out, "assessor", prompt, model_images)
    from collections import Counter

    report = {
        "source": "public-depth",
        "public_paper_sha256": digest((out / "paper.png").read_bytes()),
        "binary_sha256": settings["runtime"]["binary_sha256"],
        "proposal": proposal,
        "proposal_receipt": read(out / "proposal/receipt.json"),
        "assessor": verdict,
        "assessor_receipt": read(out / "assessor/receipt.json"),
        "blind_key": dict(zip(codes, order, strict=True)),
        "candidates": {},
    }
    for name in names:
        folder = out / name
        calls = [
            json.loads(line)
            for line in (folder / "calls.jsonl").read_text(encoding="utf8").splitlines()
        ]
        pages = read(folder / "pages.json")
        report["candidates"][name] = {
            "edits": read(folder / "edits.json") if name != "baseline" else [],
            "pages": {
                section: {
                    "sha256": p["sha256"],
                    "glyphs": p["glyphs"],
                    "source_unchanged": p["source_unchanged"],
                    "edge_bands": p["appearance"]["posthoc_vertical_edge_bands"],
                    "printed_and_written_contrast": p["appearance"][
                        "mcp_local_contrast"
                    ],
                    **collateral(out, name, int(section)),
                }
                for section, p in pages.items()
            },
            "mcp_calls": dict(Counter(c.get("name", c["method"]) for c in calls)),
            "pdf": read(folder / "export.json")
            if (folder / "export.json").exists()
            else None,
        }
    write(out / "trial.json", report)
    print(report["blind_key"], verdict)


if __name__ == "__main__":
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("stage", choices=["prepare", "render", "assess"])
    cli.add_argument("--run", required=True, type=Path)
    cli.add_argument("--out", required=True, type=Path)
    args = cli.parse_args()
    if args.stage == "prepare":
        prepare(args.run.resolve(), args.out.resolve())
    elif args.stage == "render":
        render(args.out.resolve())
    elif args.stage == "assess":
        assess(args.out.resolve())
