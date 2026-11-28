"""Prepare blind, native-pixel final review packets and score the returned ballots.

Input JSON: {"cases":[{"id", "intent", "split", "family", "arms":{
"A":{"pages":[path, ...], "decision":"deliver"|"withhold"}, "B":..., "C":...}}]}.
Paths are relative to the JSON file. All three arms must start from the same
task. Absolute paths and the private key stay in the local experiment folder.
"""

import argparse
import hashlib
import json
import random
from collections import Counter
from pathlib import Path

from PIL import Image, ImageOps


ARMS = ("A", "B", "C")
VERDICTS = {"pass", "rework", "uncertain"}
INSTRUCTIONS = """独立验收。每道题仅对照其中的用户要求和成稿。先看 overview，再打开原尺寸页或局部。
检查内容可辨、上中下贴线、原纸的透视和清晰度是否协调。说明看见的页码、位置与现象。
pass 表示按要求可交，rework 表示可以具体指出应修之处，uncertain 表示目前证据不足。
严重问题指重要内容缺失、不可读、落在错误的栏区，或持续多行严重偏离纸纹，足以要求重做。
审美偏好和少量抖动单独写进理由。只有确定需要返工时才可标 severe。请独立填写每道题。
返回 JSON 对象，以题号为键，每项含 verdict、severe (true/false)、reason。
"""


def load(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def save(path, data):
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def source_pages(base, render):
    pages = []
    for name in render["pages"]:
        with Image.open(base / name) as opened:
            rgb = ImageOps.exif_transpose(opened).convert("RGB")
            pages.append(rgb)
    if not pages:
        raise ValueError("a review requires at least one exported page")
    return pages


def pixel_id(pages):
    digest = hashlib.sha256()
    for page in pages:
        digest.update(f"{page.width}x{page.height}:".encode())
        digest.update(page.tobytes())
    return digest.hexdigest()


def write_packet(path, intent, pages):
    path.mkdir()
    (path / "task.txt").write_text(intent + "\n", encoding="utf-8")
    thumbs = []
    for i, page in enumerate(pages, 1):
        page.save(path / f"page-{i}.png")
        thumb = page.copy()
        thumb.thumbnail((560, 800))
        thumbs.append(thumb)
        # Also ship three unscaled, lossless windows from each page. Full PNGs
        # let the assessor inspect other positions regardless of these windows.
        width, height = page.size
        for location, fx, fy in (("upper", .32, .28), ("middle", .56, .53), ("lower", .62, .78)):
            cw, ch = min(500, width), min(200, height)
            x = min(max(0, int(width * fx) - cw // 2), width - cw)
            y = min(max(0, int(height * fy) - ch // 2), height - ch)
            page.crop((x, y, x + cw, y + ch)).save(path / f"page-{i}-{location}.png")
    overview = Image.new("RGB", (sum(t.width for t in thumbs), max(t.height for t in thumbs)), "white")
    left = 0
    for thumb in thumbs:
        overview.paste(thumb, (left, 0))
        left += thumb.width
    overview.save(path / "overview.png")


def prepare(manifest, out, seed):
    cases = load(manifest)["cases"]
    entries = [(case, arm) for case in cases for arm in ARMS]
    if len({case["id"] for case in cases}) != len(cases):
        raise ValueError("duplicate case ID")
    rng = random.Random(seed)
    rng.shuffle(entries)
    out.mkdir(parents=True, exist_ok=False)
    blind = out / "blind"
    blind.mkdir()
    (blind / "instructions.txt").write_text(INSTRUCTIONS, encoding="utf-8")
    keys, by_pixels = [], {}
    for case, arm in entries:
        result = case["arms"][arm]
        if result["decision"] not in {"deliver", "withhold"}:
            raise ValueError("invalid terminal decision")
        pages = source_pages(manifest.parent, result)
        fingerprint = pixel_id(pages)
        group = (case["id"], fingerprint)
        if group not in by_pixels:
            code = f"P{rng.randrange(100000, 999999)}"
            while (blind / code).exists():
                code = f"P{rng.randrange(100000, 999999)}"
            by_pixels[group] = code
            write_packet(blind / code, case["intent"], pages)
        keys.append({"case": case["id"], "split": case["split"], "family": case["family"],
                     "arm": arm, "id": by_pixels[group], "pixels": fingerprint,
                     "pages": len(pages), "decision": result["decision"]})
    save(out / "private-key.json", keys)


def score(key, ballot, out):
    entries, votes = load(key), load(ballot)
    if set(votes) != {row["id"] for row in entries}:
        raise ValueError("ballot IDs must exactly match the rendered packets")
    for vote in votes.values():
        if (vote["verdict"] not in VERDICTS or type(vote["severe"]) is not bool
                or (vote["severe"] and vote["verdict"] != "rework")
                or not vote["reason"].strip()):
            raise ValueError(f"invalid vote: {vote}")
    rows = [row | votes[row["id"]] for row in entries]
    counts = {}
    for split in sorted({row["split"] for row in rows}):
        counts[split] = {}
        for arm in ARMS:
            group = [r for r in rows if (r["split"], r["arm"]) == (split, arm)]
            counts[split][arm] = {
                "tasks": len(group), "families": len({r["family"] for r in group}),
                "pages": sum(r["pages"] for r in group),
                "verdicts": dict(Counter(r["verdict"] for r in group)),
                "delivered": sum(r["decision"] == "deliver" for r in group),
                "severe_delivered": sum(r["decision"] == "deliver" and r["severe"] for r in group),
                "usable_delivered": sum(r["decision"] == "deliver" and r["verdict"] == "pass" for r in group),
            }
    save(out, {"rows": rows, "counts": counts})


if __name__ == "__main__":
    cli = argparse.ArgumentParser(description=__doc__)
    commands = cli.add_subparsers(dest="command", required=True)
    p = commands.add_parser("prepare")
    p.add_argument("manifest", type=Path)
    p.add_argument("out", type=Path)
    p.add_argument("--seed", type=int, required=True)
    s = commands.add_parser("score")
    s.add_argument("key", type=Path)
    s.add_argument("ballot", type=Path)
    s.add_argument("out", type=Path)
    args = cli.parse_args()
    if args.command == "prepare":
        prepare(args.manifest, args.out, args.seed)
    else:
        score(args.key, args.ballot, args.out)
