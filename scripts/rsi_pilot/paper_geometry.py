"""Independent geometry references and native-raster checks for the pilot.

Real reference coordinates are evaluator-only. Candidate calibration operates on
the blank input pixels in paper_detector.py. All coordinates are native pixels.
"""

import argparse
import hashlib
import io
import json
from collections import Counter
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter


def load_labels(paper_id):
    key = Path(paper_id).stem
    if key in {"public-notes-v3", "public-slots-v3"}:
        from prospective_papers import labels_for

        return labels_for(key)
    if key == "public-depth":
        return _depth_geometry()[0]
    if key == "public-grid":
        return _grid_geometry()
    catalog = Path(__file__).with_name("paper_labels.json")
    return json.loads(catalog.read_text(encoding="utf-8"))["sources"][key]


def _grid_geometry():
    xs = [60, 360, 660]
    # The synthetic sheet is a ruled plane seen at a slight angle. Darker
    # horizontal rules are baselines, lighter columns divide it into cells.
    t = np.linspace(0, 1, 19)
    y_left = 112 + 708 * t / (1.13 - 0.13 * t)
    y_right = 80 + 720 * t / (1.13 - 0.13 * t)
    rows = [list(map(round, [l, (l + r) / 2, r])) for l, r in zip(y_left, y_right)]
    return {
        "size": [720, 900],
        "xs": xs,
        "rows": rows,
        "split": "holdout",
        "template": "public-oblique-grid",
        "kind": "grid",
    }


def generate_public_paper(path):
    labels = _grid_geometry()
    w, h = labels["size"]
    supersample = 3
    image = Image.new("RGB", (w * supersample, h * supersample), "#f4f0e6")
    draw = ImageDraw.Draw(image)

    def line(points, color, width):
        draw.line(
            [(round(x * supersample), round(y * supersample)) for x, y in points],
            fill=color,
            width=round(width * supersample),
        )

    left, _, right = labels["xs"]
    for x in range(left, right + 1, 30):
        t = (x - left) / (right - left)
        top, bottom = labels["rows"][0], labels["rows"][-1]
        line(
            [
                (x, top[0] * (1 - t) + top[-1] * t),
                (x, bottom[0] * (1 - t) + bottom[-1] * t),
            ],
            "#c4c9bb",
            0.8,
        )
    for row in labels["rows"]:
        line(zip(labels["xs"], row), "#82918a", 1.3)
    image = image.resize((w, h), Image.Resampling.LANCZOS).filter(
        ImageFilter.GaussianBlur(0.45)
    )
    image.save(path, format="PNG")
    return labels


def _depth_geometry():
    # A planar sheet projected with a common vanishing point. Near/far scale
    # ratio 1.55, so spacing and ruling width change with depth together.
    xs = [190, 420, 635]
    far = np.array([[174.0, 137.0], [647.0, 112.0]])
    near = np.array([[48.0, 979.0], [781.0, 940.0]])
    rows, ends = [], []
    for fraction in np.linspace(0, 1, 13):
        t = fraction / (1.55 - 0.55 * fraction)
        (xl, yl), (xr, yr) = far * (1 - t) + near * t
        ends.append([[float(xl), float(yl)], [float(xr), float(yr)]])
        rows.append([round(yl + (yr - yl) * (x - xl) / (xr - xl)) for x in xs])
    return {
        "size": [840, 1120],
        "xs": xs,
        "rows": rows,
        "split": "holdout",
        "kind": "ruled",
        "template": "public-full-depth",
        "generator_focus_sigma_px": {"far": 2.8, "near": 0.45},
    }, ends


def generate_depth_paper(path):
    labels, ends = _depth_geometry()
    w, h = labels["size"]
    ss = 3
    image = Image.new("RGB", (w * ss, h * ss), "#606970")
    draw = ImageDraw.Draw(image)

    def scaled(points):
        return [(round(x * ss), round(y * ss)) for x, y in points]

    draw.polygon(scaled([(154, 64), (674, 36), (834, 1014), (8, 1060)]), fill="#f3efe4")
    for i, ends_i in enumerate(ends):
        draw.line(
            scaled(ends_i), fill="#596069", width=round(ss * (1.4 + i / 12 * 0.8))
        )
    image = image.resize((w, h), Image.Resampling.LANCZOS)
    # Nine full-resolution PSF levels, blended continuously by image depth.
    # Only the paper, never the candidate handwriting, is synthesized here.
    image_array = np.asarray(image)
    result = np.empty_like(image_array)
    pos = np.clip((np.arange(h) - 125) / (960 - 125), 0, 1) * 8
    sigmas = np.linspace(2.8, 0.45, 9)
    previous = np.asarray(
        image.filter(ImageFilter.GaussianBlur(float(sigmas[0]))), dtype=float
    )
    for k, sigma in enumerate(sigmas[1:]):
        current = np.asarray(
            image.filter(ImageFilter.GaussianBlur(float(sigma))), dtype=float
        )
        take = (pos >= k) & ((pos < k + 1) if k < 7 else (pos <= 8))
        weight = (pos[take] - k)[:, None, None]
        result[take] = np.round(
            previous[take] * (1 - weight) + current[take] * weight
        ).astype(np.uint8)
        previous = current
    Image.fromarray(result).save(path, format="PNG")
    return labels


def _reference_y(labels, row, x):
    """Piecewise linear at the three checked columns, extended at page edges."""
    xs = labels["xs"]
    i = 0 if x < xs[1] else 1
    y = labels["rows"][row]
    return y[i] + (y[i + 1] - y[i]) * (x - xs[i]) / (xs[i + 1] - xs[i])


def _pitch(labels, row, x):
    rows = labels["rows"]
    lo, hi = max(row - 1, 0), min(row + 1, len(rows) - 1)
    return (_reference_y(labels, hi, x) - _reference_y(labels, lo, x)) / (hi - lo)


def _sample_baseline(g):
    base = np.array(g["photo_baseline"], dtype=float)
    if g.get("adjustment"):
        if "current_photo_quad" not in g:
            raise ValueError("Adjusted glyph lacks its current photograph quad")
        # Reproject along the two short sides using the base baseline's local
        # fraction. This is an approximation for projective per-glyph warps.
        quad = np.array(g["photo_quad"], dtype=float)
        dest = np.array(g["current_photo_quad"], dtype=float)
        for j, k in [(0, 3), (1, 2)]:
            axis = quad[k] - quad[j]
            if np.dot(axis, axis) == 0:
                raise ValueError("Degenerate base glyph rectangle")
            t = np.dot(base[j] - quad[j], axis) / np.dot(axis, axis)
            base[j] = dest[j] + t * (dest[k] - dest[j])
    return base


def _assigned_glyphs(labels, glyphs, first_row):
    """Assign source lines in layout order; never snap to the nearest ruled row."""
    row = first_row
    prev_x = None
    row_start = None
    for g in glyphs:
        if g.get("kind") or not g.get("photo_baseline"):
            continue
        start, end = np.array(g["photo_baseline"], dtype=float)
        x, y = (start + end) / 2
        if "source_row" in g:
            row = first_row + int(g["source_row"])
        elif prev_x is not None and start[0] <= prev_x + 1:
            # Compare to the start of the preceding source line. Comparing to
            # its far endpoint magnifies local curvature across the whole page.
            rx, ry, rslope = row_start
            pitch = _pitch(labels, min(row, len(labels["rows"]) - 1), x)
            if y - (ry + rslope * (x - rx)) > 0.45 * pitch:
                row += 1
                row_start = None
        if row_start is None:
            slope = (end[1] - start[1]) / max(1.0, end[0] - start[0])
            row_start = (x, y, slope)
        prev_x = x
        yield row, g


def score_layout(labels, glyphs, *, first_row=0):
    """Measure actual MCP glyph baselines against indexed physical rulings.

    A missing projection is reported as missing coverage. Horizontal bounds or
    a guessed font descent cannot establish its true baseline.
    """
    glyphs = list(glyphs)
    candidates = sum(not g.get("kind") for g in glyphs)
    errors = []
    abs_px = []
    depths = {key: [] for key in ("top", "middle", "bottom")}
    row_counts = Counter()
    overflow = 0
    extrapolated = 0
    for row, g in _assigned_glyphs(labels, glyphs, first_row):
        row_counts[row] += 1
        if row >= len(labels["rows"]):
            overflow += 1
            continue
        x, y = _sample_baseline(g).mean(axis=0)
        delta = y - _reference_y(labels, row, x)
        abs_px.append(abs(delta))
        errors.append(abs(delta) / _pitch(labels, row, x))
        depth_band = ("top", "middle", "bottom")[min(2, 3 * row // len(labels["rows"]))]
        depths[depth_band].append(errors[-1])
        extrapolated += int(x < labels["xs"][0] or x > labels["xs"][-1])
    n = len(errors)
    return {
        "glyph_count": n,
        "eligible_glyphs": candidates,
        "rows_observed": len(row_counts),
        "row_counts": dict(sorted(row_counts.items())),
        "coverage": n / candidates if candidates else 0.0,
        "depth_bands": {
            name: {
                "glyph_count": len(values),
                "p90_abs_rows": float(np.percentile(values, 90)) if values else None,
            }
            for name, values in depths.items()
        },
        "overflow_glyph_count": overflow,
        "extrapolated_glyph_count": extrapolated,
        "median_abs_px": float(np.median(abs_px)) if n else None,
        "median_abs_rows": float(np.median(errors)) if n else None,
        "p90_abs_rows": float(np.percentile(errors, 90)) if n else None,
        "within_quarter_row": float(np.count_nonzero(np.array(errors) <= 0.25))
        / candidates
        if candidates
        else None,
        "outside_writable_fraction": overflow / candidates if candidates else None,
    }


def _gray(image):
    if isinstance(image, np.ndarray):
        image = Image.fromarray(image)
    if not isinstance(image, Image.Image):
        image = Image.open(io.BytesIO(image) if isinstance(image, bytes) else image)
    return np.asarray(image.convert("L"), dtype=np.int16)


def score_ink(labels, background, rendered, glyphs, *, first_row=0):
    """Measure darkened pixels in glyph quads, using a matched blank rendering.

    Both images must have the same paper, resolution and camera finish. The
    bottom ink quantile is sensitive to font descent and glyph content. It is
    physical evidence, not a human rating of letter quality.
    """
    bg, fg = _gray(background), _gray(rendered)
    if bg.shape != fg.shape or bg.shape[::-1] != tuple(labels["size"]):
        raise ValueError("Need full native-resolution blank and final page")
    glyphs = list(glyphs)
    dark = bg - fg >= 12
    # A camera pass or JPEG mismatch can change the whole page. Report this
    # independently of the ink, excluding all known glyph and diagram bounds.
    all_quads = Image.new("1", tuple(labels["size"]))
    canvas = ImageDraw.Draw(all_quads)
    for g in glyphs:
        quad = g.get("current_photo_quad", g.get("photo_quad"))
        if quad is not None:
            canvas.polygon([tuple(p) for p in quad], fill=1)
    outside = ~np.asarray(all_quads)
    outside_change = np.mean(np.abs(bg - fg)[outside] >= 12) if outside.any() else None
    bottom = []
    crossing = []
    for row, g in _assigned_glyphs(labels, glyphs, first_row):
        if row >= len(labels["rows"]):
            continue
        quad = g.get("current_photo_quad", g.get("photo_quad"))
        if quad is None:
            continue
        q = np.asarray(quad)
        low = np.maximum(0, np.floor(q.min(axis=0)).astype(int))
        hi = np.minimum(labels["size"], np.ceil(q.max(axis=0)).astype(int) + 1)
        if np.any(hi <= low):
            continue
        mask = Image.new("1", tuple(hi - low))
        ImageDraw.Draw(mask).polygon([tuple(p) for p in q - low], fill=1)
        x0, y0 = low
        yy, xx = np.nonzero(dark[y0 : hi[1], x0 : hi[0]] & np.asarray(mask))
        if len(xx) < 3:
            continue
        xx = xx + x0
        yy = yy + y0
        xs = labels["xs"]
        heights = labels["rows"][row]
        i = (xx >= xs[1]).astype(int)
        heights = np.array(heights)
        xs = np.array(xs)
        baseline = heights[i] + (heights[i + 1] - heights[i]) * (xx - xs[i]) / (
            xs[i + 1] - xs[i]
        )
        offset = (yy - baseline) / _pitch(labels, row, float(xx.mean()))
        bottom.append(float(np.percentile(offset, 95)))
        crossing.append(float(np.mean((offset < -1) | (offset > 0.2))))
    return {
        "glyphs_with_visible_ink": len(bottom),
        "median_ink_bottom_signed_rows": float(np.median(bottom)) if bottom else None,
        "mean_ink_outside_row_fraction": float(np.mean(crossing)) if crossing else None,
        "outside_quad_changed_fraction": float(outside_change)
        if outside_change is not None
        else None,
        "darkening_threshold_8bit": 12,
    }


def detect_guides(path):
    if __package__:
        from .paper_detector import detect_guides as detect
    else:
        from paper_detector import detect_guides as detect
    return detect(path)


def _edge_crossing(side, level):
    below = np.flatnonzero(side < level)
    if len(below) == 0:
        return float("nan")
    j = int(below[0])
    return j - 1 + (side[j - 1] - level) / (side[j - 1] - side[j])


def describe_reference(labels, image):
    """Measure line shape/contrast at the independently marked locations."""
    gray = _gray(image)
    if gray.shape[::-1] != tuple(labels["size"]):
        raise ValueError("Image and native reference dimensions disagree")
    rows = labels["rows"]
    groups = np.array_split(np.arange(len(rows)), 3)
    regions = {}
    for name, ids in zip(("top", "middle", "bottom"), groups):
        widths, flanks, contrasts = [], [], []
        for row_id in ids:
            for x, y in zip(labels["xs"], rows[row_id]):
                # A narrow strip avoids smearing the line slope. The two local
                # shoulders estimate paper brightness in uneven lighting.
                pixels = gray[y - 10 : y + 11, x - 3 : x + 4].mean(axis=1)
                shoulders = np.linspace(
                    np.median(pixels[:3]), np.median(pixels[-3:]), len(pixels)
                )
                depth = shoulders - pixels
                peak = 7 + int(depth[7:14].argmax())
                if depth[peak] < 3:
                    continue
                centered = depth / depth[peak]
                crossings = []
                for side in (centered[: peak + 1][::-1], centered[peak:]):
                    crossings.append(_edge_crossing(side, 0.5))
                    flanks.append(_edge_crossing(side, 0.2) - _edge_crossing(side, 0.8))
                widths.append(sum(crossings))
                contrasts.append(depth[peak])
        regions[name] = {
            "taps": len(widths),
            "median_rule_fwhm_px": round(float(np.nanmedian(widths)), 2),
            "median_rule_flank_20_80_px": round(float(np.nanmedian(flanks)), 2),
            "median_rule_contrast_8bit": round(float(np.median(contrasts)), 2),
        }
    return {
        "rows": len(rows),
        "first_center_pitch_px": rows[1][1] - rows[0][1],
        "last_center_pitch_px": rows[-1][1] - rows[-2][1],
        "first_left_to_right_rise_px": rows[0][0] - rows[0][-1],
        "last_left_to_right_rise_px": rows[-1][0] - rows[-1][-1],
        "rule_profiles": regions,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    create = commands.add_parser(
        "generate-grid", help="Create deterministic public holdout paper"
    )
    create.add_argument("output", type=Path)
    depth = commands.add_parser(
        "generate-depth", help="Create full-depth perspective and focus holdout"
    )
    depth.add_argument("output", type=Path)
    describe = commands.add_parser(
        "describe", help="Verify source and measure checked rule profiles"
    )
    describe.add_argument("paper")
    describe.add_argument("image", type=Path)
    score = commands.add_parser(
        "score", help="Evaluate one complete native-layout page"
    )
    score.add_argument("paper")
    score.add_argument("glyphs", type=Path)
    score.add_argument("--blank", type=Path)
    score.add_argument("--rendered", type=Path)
    score.add_argument("--first-row", type=int, default=0)
    args = parser.parse_args()
    if args.command == "generate-grid":
        result = generate_public_paper(args.output)
    elif args.command == "generate-depth":
        result = generate_depth_paper(args.output)
    elif args.command == "describe":
        labels = load_labels(args.paper)
        digest = hashlib.sha256(args.image.read_bytes()).hexdigest()
        if labels.get("sha256", digest) != digest:
            parser.error("The supplied photograph does not match its reference SHA-256")
        result = describe_reference(labels, args.image)
    else:
        labels = load_labels(args.paper)
        glyphs = json.loads(args.glyphs.read_text(encoding="utf-8"))
        result = {"layout": score_layout(labels, glyphs, first_row=args.first_row)}
        if bool(args.blank) != bool(args.rendered):
            parser.error("Supply both --blank and --rendered for pixel measurements")
        if args.blank:
            result["ink"] = score_ink(
                labels, args.blank, args.rendered, glyphs, first_row=args.first_row
            )
    print(json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False))


if __name__ == "__main__":
    main()
