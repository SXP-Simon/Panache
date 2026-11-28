"""Optical-only blinded comparison of two actual MCP revisions on the same photo."""

import argparse
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
from codex_judge import run as judge
from PIL import Image, ImageDraw, ImageFont
from real_photo_audit_trial import CATEGORIES, card, read, save, scan_width, sha

PAIR_PROMPT = """这两张图标记为 A 和 B，分别是同一真实练习纸上的两份手写稿，五个局部都裁自相同的原图坐标并保持原比例。只评价笔画深浅、边缘清晰度与当地纸上印线是否协调。请指出哪几个局部的变化能够直接看出，哪些局部没有可辨差异；若内容或位置改动妨碍对照则写明。在证据不足或变化无关紧要时可选 tie。不要推断哪个版本更晚。只返回 JSON：preferred 为 A、B 或 tie，reason 为具体可见证据，regions 为各局部的观察。不要使用工具或读取文件。"""


def widths_and_darkness(background, image):
    layer = np.maximum(
        np.asarray(background.convert("L"), dtype=float)
        - np.asarray(image.convert("L"), dtype=float),
        0,
    )
    mask = layer > 10
    return {
        **scan_width(layer),
        "ink_pixels_gt10": int(mask.sum()),
        "p90_ink_drop": round(float(np.percentile(layer[mask], 90)), 2)
        if mask.any()
        else None,
    }


def differences(before, after, blank):
    a = np.asarray(before.convert("RGB"), dtype=int)
    b = np.asarray(after.convert("RGB"), dtype=int)
    delta = np.max(np.abs(a - b), axis=2)
    ya = np.asarray(before.convert("L"), dtype=int)
    yb = np.asarray(after.convert("L"), dtype=int)
    paper = np.asarray(blank.convert("L"), dtype=int)
    ink = (paper - ya > 10) | (paper - yb > 10)
    changed = delta >= 3
    return {
        "all_rgb_pixels": int(delta.size),
        "changed_ge_3": int(changed.sum()),
        "changed_ge_12": int((delta >= 12).sum()),
        "brightened_ge_3": int(((yb - ya) >= 3).sum()),
        "darkened_ge_3": int(((ya - yb) >= 3).sum()),
        "paper_background_changed_ge_12_without_detected_ink": int(
            ((delta >= 12) & ~ink).sum()
        ),
        "before": widths_and_darkness(blank, before),
        "after": widths_and_darkness(blank, after),
    }


def ballot(out, n, mapping, pages):
    directory = out / f"ballot-{n}"
    directory.mkdir(exist_ok=True, parents=True)
    files = []
    for label, key in mapping.items():
        path = directory / f"{label}.png"
        card(pages[key], label).save(path)
        files.append(path)
    prompt = directory / "question.txt"
    prompt.write_text(PAIR_PROMPT, encoding="utf-8")
    target = directory / "answer"
    if not (target / "receipt.json").exists():
        judge(prompt, files, "gpt-6.1-terra", target)
    receipt = read(target / "receipt.json")
    if receipt["image_sha256"] != [sha(f) for f in files] or receipt[
        "prompt_sha256"
    ] != sha(prompt):
        raise ValueError("Existing optical pair ballot belongs to different inputs")
    return {
        "labels": mapping,
        "decision": read(target / "decision.json"),
        "receipt": receipt,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before", required=True, type=Path)
    parser.add_argument("--after", required=True, type=Path)
    parser.add_argument("--blank", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--result", required=True, type=Path)
    args = parser.parse_args()
    blank = Image.open(args.blank).convert("RGB")
    pages = {
        key: Image.open(path).convert("RGB")
        for key, path in [("before", args.before), ("after", args.after)]
    }
    if any(im.size != blank.size for im in pages.values()) or blank.size != (
        1440,
        1920,
    ):
        raise ValueError("Full-page images must match the native photograph dimensions")
    source_hashes = {
        k: sha(p)
        for k, p in [
            ("before", args.before),
            ("after", args.after),
            ("paper", args.blank),
        ]
    }
    if source_hashes["before"] == source_hashes["after"]:
        raise ValueError("No distinct current native candidate to compare")
    stats = {}
    for kind, (window, _) in CATEGORIES.items():
        stats[kind] = differences(
            pages["before"].crop(window),
            pages["after"].crop(window),
            blank.crop(window),
        )
    orders = [{"A": "before", "B": "after"}, {"A": "after", "B": "before"}]
    with ThreadPoolExecutor(max_workers=2) as pool:
        votes = list(
            pool.map(lambda kv: ballot(args.out, *kv, pages), enumerate(orders, 1))
        )
    assets = args.out / "pr-assets"
    assets.mkdir(exist_ok=True)
    # Both review columns share native coordinates and retain the same pixels.
    figure = Image.new("RGB", (900, 670), "#f8f7f2")
    draw = ImageDraw.Draw(figure)
    strips = [
        ("Body", (280, 305, 706, 389)),
        ("Table", (241, 435, 648, 533)),
        ("Fraction", (230, 641, 519, 716)),
        ("Flowchart", (170, 868, 375, 982)),
        ("Waveform", (520, 1356, 934, 1452)),
    ]
    for col, key in enumerate(("before", "after")):
        x = 10 + col * 448
        draw.text(
            (x, 8), key.title(), fill="#253c3a", font=ImageFont.load_default(size=20)
        )
        y = 35
        for text, box in strips:
            draw.text(
                (x, y), text, fill="#253c3a", font=ImageFont.load_default(size=14)
            )
            figure.paste(pages[key].crop(box), (x, y + 19))
            y += box[3] - box[1] + 27
    figure.save(assets / "native-before-after.png")
    result = {
        "scope": "Blinded two-position optical-only comparison of actual native MCP pages. Each optical grade is model evidence, not human approval.",
        "page_sha256": source_hashes,
        "windows": stats,
        "blind_ballots": votes,
        "asset": "native-before-after.png",
    }
    save(args.result, result)


if __name__ == "__main__":
    main()
