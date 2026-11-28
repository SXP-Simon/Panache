"""Blinded native-size comparisons of the real photograph with known ink-only defects.

The native revision is retained verbatim. The three digital controls are
postprocessing of its recovered dark-ink layer; they are not engine revisions.
The published crops exclude the institutional header, page edges and keyboard.
"""

import argparse
import hashlib
import json
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import cv2
import numpy as np
from appearance import sample_profile
from codex_judge import run as judge
from paper_geometry import _reference_y, load_labels
from PIL import Image, ImageDraw, ImageFont

CATEGORIES = {
    "text": ((280, 305, 706, 389), [0, 12]),
    "fraction": ((230, 641, 519, 716), [72, 80]),
    "table": ((241, 430, 648, 616), [42, 42]),
    "flow": ((145, 816, 385, 1187), [108, 108]),
    "raster": ((520, 1328, 934, 1489), [135, 135]),
}
POSITIONS = {
    "text": (12, 82),
    "fraction": (12, 211),
    "table": (12, 332),
    "flow": (460, 82),
    "raster": (456, 503),
}
SIZE = (884, 678)
PUBLIC_LABELS = {
    "text": "Body text",
    "fraction": "Fraction",
    "table": "Data table",
    "flow": "Flowchart",
    "raster": "Inserted wave sketch",
}
PROMPT = """四张匿名图都来自同一张真实练习纸。每张标为不同字母，图内五个局部均为相同原纸坐标的原始像素。独立核查各图的笔迹是否与纸面视角、局部清晰度及明暗相称。比较正文、分式、表格、流程图和波形在各区域的表现。允许平局或无法判断，不要预设有几张图有问题。只返回 JSON 对象：preferred 为整体最自然的字母或 tie，cards 为逐图对象数组，每项含 label、alignment、focus、contrast（各为 natural、mismatch 或 uncertain），observation 为中文、说明具体区域和证据。不要调用工具或读取文件。"""


def read(path):
    return json.loads(path.read_text(encoding="utf-8"))


def save(path, data):
    path.write_text(
        json.dumps(data, indent=2, ensure_ascii=False, allow_nan=False) + "\n",
        encoding="utf-8",
    )


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def pixel_pair(paper, native):
    bg = np.asarray(paper, dtype=np.float32)
    fg = np.asarray(native, dtype=np.float32)
    density = np.clip((bg - fg) / np.maximum(bg, 1), 0, 1)
    restored = np.rint(bg * (1 - density)).astype(np.uint8)
    return bg, density, int(np.max(np.abs(restored.astype(float) - fg)))


def quad(g):
    return np.asarray(g.get("current_photo_quad", g["photo_quad"]), dtype=np.float32)


def rectangle(g):
    x, y, w, h = g["bounds"]
    return np.asarray(
        [[x, y], [x + w, y], [x + w, y + h], [x, y + h]], dtype=np.float32
    )


def clusters(glyphs):
    groups = []
    previous = None
    for g in glyphs:
        rect = rectangle(g)
        x, y = rect.mean(axis=0)
        unit = g["id"] in [42, 108, 135] or bool(g.get("kind"))
        if (
            previous is None
            or unit
            or previous[2]
            or (x < previous[0] and abs(y - previous[1]) > 15)
        ):
            groups.append([])
        groups[-1].append(g)
        previous = (x, y, unit)
    return groups


def flatten(density, glyphs):
    """Use each source box's paper-space size and direction around its line center."""
    h, w, _ = density.shape
    rebuilt = np.zeros_like(density)
    for group in clusters(glyphs):
        a = np.concatenate([quad(g) for g in group])
        b = np.concatenate([rectangle(g) for g in group])
        shift = (a.min(axis=0) + a.max(axis=0) - b.min(axis=0) - b.max(axis=0)) / 2
        for g in group:
            q = quad(g)
            target = rectangle(g) + shift
            x0, y0 = np.maximum(0, np.floor(q.min(axis=0)).astype(int) - 2)
            x1, y1 = np.minimum([w, h], np.ceil(q.max(axis=0)).astype(int) + 3)
            u0, v0 = np.maximum(0, np.floor(target.min(axis=0)).astype(int) - 2)
            u1, v1 = np.minimum([w, h], np.ceil(target.max(axis=0)).astype(int) + 3)
            if min(x1 - x0, y1 - y0, u1 - u0, v1 - v0) <= 0:
                continue
            local = (q - [x0, y0]).astype(np.float32)
            mask = np.zeros((y1 - y0, x1 - x0), np.uint8)
            cv2.fillConvexPoly(mask, np.rint(local).astype(np.int32), 1)
            dst = (target - [u0, v0]).astype(np.float32)
            matrix = cv2.getPerspectiveTransform(local, dst)
            warped = cv2.warpPerspective(
                density[y0:y1, x0:x1] * mask[:, :, None],
                matrix,
                (u1 - u0, v1 - v0),
                flags=cv2.INTER_LINEAR,
            )
            rebuilt[v0:v1, u0:u1] = np.maximum(rebuilt[v0:v1, u0:u1], warped)
    return rebuilt


def card(page, label):
    out = Image.new("RGB", SIZE, "#f8f7f2")
    draw = ImageDraw.Draw(out)
    large = ImageFont.load_default(size=24)
    small = ImageFont.load_default(size=15)
    draw.text((12, 8), label, fill="#162c2b", font=large)
    for key, (window, _) in CATEGORIES.items():
        x, y = POSITIONS[key]
        draw.text((x, y - 22), PUBLIC_LABELS[key], fill="#263d3a", font=small)
        out.paste(page.crop(window), (x, y))
    return out


def scan_width(signal):
    values = []
    for direction in (signal, signal.T):
        for line in direction[::4]:
            values.extend(sample_profile(line, line > 0))
    return {
        "stroke_peaks": len(values),
        "median_20_80_px": round(float(np.median(values)), 3)
        if len(values) >= 6
        else None,
    }


def inspect_types(bg, pages, glyphs):
    labels = load_labels("image-1")
    stats = {}
    gray_bg = bg @ [0.299, 0.587, 0.114]
    for kind, (window, ids) in CATEGORIES.items():
        selected = [g for g in glyphs if ids[0] <= g["id"] <= ids[1]]
        if not selected:
            raise ValueError(f"Missing required rendered {kind}")
        angle = []
        paper_axis = []
        hscale = []
        vscale = []
        for g in selected:
            q = quad(g)
            _, _, w, h = g["bounds"]
            axis = (q[1] - q[0] + q[2] - q[3]) / 2
            height = (q[3] - q[0] + q[2] - q[1]) / 2
            x, y = q.mean(axis=0)
            row = min(
                range(len(labels["rows"])),
                key=lambda i: abs(_reference_y(labels, i, x) - y),
            )
            dy = _reference_y(labels, row, x + 20) - _reference_y(labels, row, x - 20)
            paper_axis.append(np.degrees(np.arctan2(dy, 40)))
            hscale.append(np.linalg.norm(axis) / w)
            vscale.append(np.linalg.norm(height) / h)
            angle.append(np.degrees(np.arctan2(axis[1], axis[0])))
        left, top, right, bottom = window
        data = {
            "window_xyxy": window,
            "native_ids": [g["id"] for g in selected],
            "local_paper_axis_deg_approx": round(float(np.median(paper_axis)), 3),
            "median_abs_axis_difference_deg": round(
                float(np.median(np.abs(np.subtract(angle, paper_axis)))), 3
            ),
            "median_top_axis_deg": round(float(np.median(angle)), 3),
            "median_horizontal_scale": round(float(np.median(hscale)), 3),
            "median_vertical_scale": round(float(np.median(vscale)), 3),
            "conditions": {},
        }
        # Same fixed physical window for all conditions, with same neighboring paper/ink.
        for cond, page in pages.items():
            pic = np.asarray(page.crop(window), dtype=np.float64)
            layer = np.maximum(
                gray_bg[top:bottom, left:right] - pic @ [0.299, 0.587, 0.114], 0
            )
            ink = layer[layer > 10]
            data["conditions"][cond] = {
                "visible_pixels_gt10": len(ink),
                "ink_drop_p90": round(float(np.percentile(ink, 90)), 2)
                if len(ink)
                else None,
                **scan_width(layer),
            }
        stats[kind] = data
    return stats


def blind_pass(out, number, mapping, pages):
    directory = out / f"ballot-{number}"
    directory.mkdir(exist_ok=True)
    files = []
    for label, condition in mapping.items():
        path = directory / f"{label}.png"
        card(pages[condition], label).save(path)
        files.append(path)
    prompt = directory / "question.txt"
    prompt.write_text(PROMPT, encoding="utf-8")
    answer = directory / "answer"
    if not (answer / "receipt.json").exists():
        judge(prompt, files, "gpt-6.1-terra", answer)
    decision = read(answer / "decision.json")
    receipt = read(answer / "receipt.json")
    if receipt["image_sha256"] != [sha(path) for path in files] or receipt[
        "prompt_sha256"
    ] != sha(prompt):
        raise ValueError("Frozen blind ballot inputs differ")
    return {"label_key": mapping, "decision": decision, "receipt": receipt}


def original_paper_panel(paper, folder):
    refs = load_labels("image-1")
    out = Image.new("RGB", (672, 276), "#f8f7f2")
    draw = ImageDraw.Draw(out)
    for j, row in enumerate([1, 9, 18]):
        for i, (x, y) in enumerate(zip(refs["xs"], refs["rows"][row])):
            pic = paper.crop((x - 100, y - 27, x + 100, y + 27))
            p = (10 + 220 * i, 25 + 90 * j)
            out.paste(pic, p)
            draw.text((p[0], p[1] - 17), f"row {row + 1}   x={x}", fill="#253c3a")
    out.save(folder / "paper-regions-native.png")


def comparison_panel(pages, target):
    # Identical 210 x 96 native samples preserve the print/ink relation. Only
    # authored academic work and paper lines enter the public comparison.
    windows = [(276, 310), (248, 457), (235, 649), (177, 873), (587, 1348)]
    row_names = ["Body", "Table", "Fraction", "Flowchart", "Waveform"]
    labels = {
        "native": "MCP render",
        "flat": "Flattened geometry",
        "soft": "Ink blur 2.8 px",
        "local_fade": "Local contrast fade",
    }
    out = Image.new("RGB", (945, 554), "#f8f7f2")
    draw = ImageDraw.Draw(out)
    font = ImageFont.load_default(size=14)
    for i, (key, title) in enumerate(labels.items()):
        x = 80 + i * 215
        draw.text((x, 8), title, font=font, fill="#253c3a")
        for j, ((left, top), name) in enumerate(zip(windows, row_names)):
            y = 36 + j * 102
            if i == 0:
                draw.text((6, y + 39), name, font=font, fill="#253c3a")
            out.paste(pages[key].crop((left, top, left + 210, top + 96)), (x, y))
    out.save(target)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stage", required=True, type=Path)
    parser.add_argument("--original", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--result", required=True, type=Path)
    args = parser.parse_args()
    out = args.out
    out.mkdir(parents=True, exist_ok=True)
    if sha(args.original) != load_labels("image-1")["sha256"]:
        raise ValueError("Incorrect original")
    stage = args.stage
    paper = Image.open(stage / "paper.png").convert("RGB")
    native = Image.open(stage / "page-1.png").convert("RGB")
    orig = Image.open(args.original).convert("RGB")
    blank_error = int(
        np.abs(np.asarray(paper, dtype=int) - np.asarray(orig, dtype=int)).max()
    )
    glyphs = read(stage / "glyphs-1.json")
    bg, density, rebuild_error = pixel_pair(paper, native)
    h, w = bg.shape[:2]
    yy, xx = np.ogrid[:h, :w]
    fade = 1 - 0.72 * np.exp(
        -0.5 * ((xx - 420) / 255) ** 2 - 0.5 * ((yy - 715) / 384) ** 2
    )
    conditions = {
        "flat": flatten(density, glyphs),
        "soft": cv2.GaussianBlur(density, (0, 0), 2.8),
        "local_fade": density * fade[:, :, None],
    }
    pages = {"native": native}
    pages.update(
        {
            k: Image.fromarray(np.rint(bg * (1 - v)).clip(0, 255).astype(np.uint8))
            for k, v in conditions.items()
        }
    )
    public = out / "pr-assets"
    public.mkdir(exist_ok=True)
    original_paper_panel(orig, public)
    comparison_panel(pages, public / "four-conditions-native.png")
    for key, page in pages.items():
        card(
            page,
            {
                "native": "MCP render",
                "flat": "Flat ink control",
                "soft": "Blurred ink control",
                "local_fade": "Local contrast control",
            }[key],
        ).save(public / f"{key}-native-crops.png")
    details = inspect_types(bg, pages, glyphs)
    # Fixed, counterbalanced permutations. Every identity appears at different slots.
    keys = [
        dict(zip("ABCD", order))
        for order in [
            ("soft", "local_fade", "native", "flat"),
            ("native", "flat", "soft", "local_fade"),
        ]
    ]
    with ThreadPoolExecutor(max_workers=2) as pool:
        ballots = list(
            pool.map(
                lambda item: blind_pass(out, item[0], item[1], pages),
                enumerate(keys, 1),
            )
        )
    res = {
        "photo_sha256": sha(args.original),
        "examined_page_sha256": sha(stage / "page-1.png"),
        "native_blank_max_channel_error_vs_original_decode": blank_error,
        "density_reconstruction_max_channel_error": rebuild_error,
        "scope": "First native page of the two-page mixed homework. Five fixed 1:1 crops. Cell/table, body text, fraction row, native flowchart and raster wave have separate native bounds. Text near the fraction and handwritten strokes crossing original rules can enter window statistics.",
        "source_mapping": "Fraction uses the whole visible expression (layout IDs 72–80, compound wide glyph 73); AST fraction node 74 is not assumed to equal a glyph ID.",
        "known_injections": {
            "flat": "Replace each photo glyph quad with its axis-aligned native paper box, center each source line or composite object at its original photographed center. Paper background unchanged.",
            "soft": "Gaussian sigma 2.8 native pixels on added dark-ink density only.",
            "local_fade": "Density multiplied by 1−0.72 exp(−0.5((x−420)/255)^2−0.5((y−715)/384)^2). This mimics a local ink/exposure mismatch, without changing the actual paper exposure.",
            "native": "Unmodified native MCP image. Its role as unaltered comparator is not proof of optimal realism.",
        },
        "strata": details,
        "blind_ballots": ballots,
        "public_files": [p.name for p in sorted(public.glob("*.png"))],
    }
    save(args.result, res)


if __name__ == "__main__":
    main()
