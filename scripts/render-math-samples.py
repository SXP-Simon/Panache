#!/usr/bin/env python3
"""Render repeatable handwriting math samples and record pixel geometry.

Run from the repository root with .venv/Scripts/python.exe
scripts/render-math-samples.py --output preview_outputs/math-samples.
The formulas use the production symbol fallback renderer, not a TeX renderer.
"""

import argparse
import json
from pathlib import Path
import random
import sys
import time

from PIL import Image, ImageDraw, ImageFont, ImageOps

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))
import symbol_fallback as symbols  # noqa: E402
from handright import Template, handwrite  # noqa: E402


CASES = [
    ("simple_fraction", r"a = \frac{1}{2} + b"),
    ("polynomial_fraction", r"f(x) = \frac{x² + 2x + 1}{x − 1}"),
    ("nested_fraction", r"y = \frac{1}{\frac{2}{3} + 4}"),
    ("fraction_both_nested", r"z = \frac{\frac{a}{b}}{\frac{c}{d}}"),
    ("simple_root", r"y = \sqrt{x² + 1} + z"),
    ("root_fraction", r"y = \sqrt{\frac{x + 1}{x − 1}}"),
    ("fraction_root", r"y = \frac{\sqrt{x + 1}}{\sqrt{x − 1}}"),
    ("nested_roots", r"y = \sqrt{1 + \sqrt{1 + \sqrt{x}}}"),
    ("root_index", r"y = \sqrt[3]{8x³} + \sqrt[12]{a}"),
    ("root_coefficient", r"y = 2\sqrt{x} + 3\sqrt[3]{x²}"),
    ("scripts", r"aₙ₊₁ = x² + y³ + eⁿ"),
    ("wide_root", r"y = \sqrt{a² + b² + c² + 2ab + 2bc + 2ca}"),
    ("wide_fraction", r"y = \frac{a + b + c + d + e + f}{x² + 2xy + y²}"),
    ("quadratic", r"x = \frac{−b ± \sqrt{b² − 4ac}}{2a}"),
    ("continued_fraction", r"x = \frac{1}{1 + \frac{1}{1 + \frac{1}{2}}}"),
    ("adjacent_structures", r"\sqrt{x}\sqrt{y} + \frac{1}{2}\frac{3}{4} = z"),
]


def find_font(name):
    for directory in (ROOT / "backend/font_assets", ROOT / "font_assets"):
        path = directory / name
        if path.is_file():
            return path
    raise FileNotFoundError(name)


def label_font(size=20):
    for path in (Path("C:/Windows/Fonts/msyh.ttc"), Path("C:/Windows/Fonts/arial.ttf"), Path("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf")):
        if path.is_file():
            return ImageFont.truetype(str(path), size)
    return ImageFont.load_default()


def outside(actual, declared):
    return bool(actual and (actual[0] < declared[0] or actual[1] < declared[1]
                           or actual[2] > declared[2] or actual[3] > declared[3]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "preview_outputs/math-samples")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    records, sheets = [], []
    label = label_font()
    for font_name in ("云烟体.ttf", "李国夫手写体.ttf"):
        font_path = find_font(font_name)
        for size in (24, 40, 64):
            font = ImageFont.truetype(str(font_path), size)
            tiles = []
            for name, source in CASES:
                begin = time.perf_counter()
                converted = symbols.normalize_text_for_font(source, str(font_path))
                declared = symbols._get_rendered_text_bbox(converted, font, str(font_path))
                measured = symbols._measure_text_or_fraction(converted, font, str(font_path))
                origin = (256, 256)
                # 2026-10-15：handright 的白色常量是 1，使用其原生二值蒙版避免 L 模式墨迹仅为 1/255。
                mask = Image.new("1", (8192, 2048), 0)
                advance, height = symbols._draw_text_or_fraction(
                    ImageDraw.Draw(mask), converted, origin, font, str(font_path))
                actual_canvas = mask.getbbox()
                actual = (tuple(actual_canvas[i] - origin[i % 2] for i in range(4))
                          if actual_canvas else None)
                elapsed = (time.perf_counter() - begin) * 1000
                filename = f"{font_path.stem}-{size}-{name}.png"
                crop_box = (max(0, actual_canvas[0] - 24), max(0, actual_canvas[1] - 24),
                            min(mask.width, actual_canvas[2] + 24), min(mask.height, actual_canvas[3] + 24))
                formula = ImageOps.invert(mask.crop(crop_box).convert("L")).convert("RGB")
                image = Image.new("RGB", (max(720, formula.width), formula.height + 72), "white")
                draw = ImageDraw.Draw(image)
                draw.text((12, 5), f"{name} | {font_path.stem} | {size}px", fill="black", font=label)
                draw.text((12, 30), source, fill="black", font=label)
                image.paste(formula, (0, 72))
                image.save(output / filename)
                records.append({"case": name, "source": source, "font": font_path.name, "size": size,
                                "image": filename, "declared_bbox": declared,
                                "actual_pixel_bbox": actual, "measured_size": measured,
                                "advance": advance, "returned_height": height,
                                "render_ms": round(elapsed, 3), "outside_declared_bbox": outside(actual, declared),
                                "canvas_clipped": bool(actual_canvas and (actual_canvas[0] == 0 or actual_canvas[1] == 0
                                                                           or actual_canvas[2] == mask.width or actual_canvas[3] == mask.height))})
                tile = Image.new("RGB", (1100, 240), "white")
                image.thumbnail((1080, 225))
                tile.paste(image, (10, 5))
                tiles.append(tile)
            sheet = Image.new("RGB", (2200, 240 * ((len(tiles) + 1) // 2)), "white")
            for index, tile in enumerate(tiles):
                sheet.paste(tile, ((index % 2) * 1100, (index // 2) * 240))
            sheet_name = f"contact-{font_path.stem}-{size}.jpg"
            sheet.save(output / sheet_name, quality=95)
            sheets.append(sheet_name)
    # 2026-10-15：真实 handright 分页验证保留固定随机种子，便于比较行距影响。
    pages = []
    page_font_path = find_font("云烟体.ttf")
    for layout, spacing in (("roomy", 116), ("compact", 48)):
        random.seed(20261015)
        font = ImageFont.truetype(str(page_font_path), 40)
        template = Template(background=Image.new("RGB", (1400, 2200), "white"), font=font,
                            line_spacing=spacing, fill=(0, 0, 0), left_margin=80, right_margin=80,
                            top_margin=120, bottom_margin=120, word_spacing=0, line_spacing_sigma=0,
                            font_size_sigma=0, word_spacing_sigma=0, end_chars="",
                            perturb_x_sigma=0, perturb_y_sigma=0, perturb_theta_sigma=0)
        text = "\n".join(f"{index + 1}. {source}" for index, (_, source) in enumerate(CASES))
        text = symbols.normalize_text_for_font(text, str(page_font_path))
        begin = time.perf_counter()
        rendered = list(handwrite(text, template, seed=20261015))
        for index, page in enumerate(rendered):
            filename = f"handright-{layout}-{index + 1}.png"
            page.save(output / filename)
            pages.append({"image": filename, "layout": layout, "line_spacing": spacing,
                          "pixel_bbox": ImageOps.invert(page.convert("L")).getbbox(),
                          "render_ms_all_pages": round((time.perf_counter() - begin) * 1000, 3)})
    summary = {"sample_count": len(records), "outside_declared_bbox_count": sum(r["outside_declared_bbox"] for r in records),
               "canvas_clipped_count": sum(r["canvas_clipped"] for r in records), "contact_sheets": sheets,
               "pages": pages, "samples": records}
    (output / "metrics.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({k: v for k, v in summary.items() if k != "samples"}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
