"""Optical/geometry audit of one byte-identified native photograph.

The marked heights in paper_labels.json were visually checked on the original.
All measurements are in decoded image space; this is not a camera calibration.
"""

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image

from paper_geometry import _pitch, _reference_y, load_labels
from paper_detector import detect_guides


def summarize(values):
    values = np.asarray(values, dtype=float)
    return {
        "median": round(float(np.median(values)), 3),
        "p10": round(float(np.percentile(values, 10)), 3),
        "p90": round(float(np.percentile(values, 90)), 3),
    }


def edge_cross(side, level):
    below = np.flatnonzero(side < level)
    if not len(below) or below[0] == 0:
        return None
    j = int(below[0])
    return j - 1 + (side[j - 1] - level) / (side[j - 1] - side[j])


def measure_tap(gray, rgb, x, y0, pitch):
    guess = round(y0)
    values = gray[guess - 14 : guess + 15, x - 2 : x + 3].mean(axis=1)
    shoulders = np.linspace(np.median(values[:4]), np.median(values[-4:]), len(values))
    depth = shoulders - values
    peak = 10 + int(np.argmax(depth[10:19]))
    if depth[peak] < 5:
        return None
    y = guess - 14 + peak
    paper = (
        rgb[round(y - 0.40 * pitch) : round(y - 0.19 * pitch), x - 7 : x + 8] / 255.0
    )
    mid = paper.reshape(-1, 3)
    linear = np.where(mid <= 0.04045, mid / 12.92, ((mid + 0.055) / 1.055) ** 2.4)
    widths = []
    for side in (depth[: peak + 1][::-1], depth[peak:]):
        side = side / depth[peak]
        lo, hi = edge_cross(side, 0.2), edge_cross(side, 0.8)
        if lo is not None and hi is not None:
            widths.append(float(lo - hi))
    if len(widths) != 2:
        return None
    return {
        "edge_px": float(np.mean(widths)),
        "contrast": float(depth[peak]),
        "y": y,
        "paper_Y_linear": float(np.median(linear @ [0.2126, 0.7152, 0.0722])),
        "paper_luma8": float(np.median(mid @ [0.299, 0.587, 0.114]) * 255),
        "near_white_channel_fraction": float(np.mean(np.max(mid, axis=1) >= 253 / 255)),
        "near_black_channel_fraction": float(np.mean(np.min(mid, axis=1) <= 2 / 255)),
    }


def audit(path):
    labels = load_labels("image-1")
    checksum = hashlib.sha256(path.read_bytes()).hexdigest()
    if checksum != labels["sha256"]:
        raise ValueError("Image SHA-256 does not match the checked ruling references")
    rgb = np.asarray(Image.open(path).convert("RGB"), dtype=float)
    gray = rgb @ [0.299, 0.587, 0.114]
    xs = labels["xs"]
    grid = {}
    rng = np.random.default_rng(27019)
    for name, ids in zip(
        ("top", "middle", "bottom"), np.array_split(np.arange(len(labels["rows"])), 3)
    ):
        for lane, xc in zip(("left", "center", "right"), xs):
            observations = []
            row_medians = []
            for row in ids:
                row_taps = []
                for x in range(xc - 36, xc + 37, 6):
                    tap = measure_tap(
                        gray,
                        rgb,
                        x,
                        _reference_y(labels, row, x),
                        _pitch(labels, row, x),
                    )
                    if tap:
                        observations.append(tap)
                        row_taps.append(tap["edge_px"])
                if row_taps:
                    row_medians.append(np.median(row_taps))
            cluster = np.median(
                rng.choice(row_medians, size=(2000, len(row_medians)), replace=True),
                axis=1,
            )
            data = {
                field: summarize([t[field] for t in observations])
                for field in ("edge_px", "contrast", "paper_luma8", "paper_Y_linear")
            }
            data.update(
                rows=len(row_medians),
                requested_taps=len(ids) * 13,
                valid_taps=len(observations),
                median_row_edge_px=round(float(np.median(row_medians)), 3),
                row_bootstrap_95_px=np.percentile(cluster, [2.5, 97.5])
                .round(3)
                .tolist(),
                max_near_white_channel_fraction=max(
                    t["near_white_channel_fraction"] for t in observations
                ),
                max_near_black_channel_fraction=max(
                    t["near_black_channel_fraction"] for t in observations
                ),
            )
            grid[f"{name}_{lane}"] = data
    rows = np.asarray(labels["rows"])
    pitch = np.diff(rows, axis=0)
    tilt = np.degrees(np.arctan2(rows[:, 2] - rows[:, 0], xs[2] - xs[0]))
    curve = rows[:, 1] - (
        rows[:, 0] + (rows[:, 2] - rows[:, 0]) * (xs[1] - xs[0]) / (xs[2] - xs[0])
    )
    guides = detect_guides(path)
    measured_width = [g["right"][0] - g["left"][0] for g in guides]
    luminance = [v["paper_Y_linear"]["median"] for v in grid.values()]
    return {
        "photo_sha256": checksum,
        "size": labels["size"],
        "source_identity": "byte-identical to pilot image-1",
        "labels": "20 thin writable rulings, three checked x columns. Header and footer bars excluded.",
        "geometry": {
            "xs": xs,
            "pitch_first_left_center_right_px": pitch[0].tolist(),
            "pitch_last_left_center_right_px": pitch[-1].tolist(),
            "line_tilt_deg_first_middle_last": tilt[[0, len(tilt) // 2, -1]]
            .round(3)
            .tolist(),
            "center_minus_end_chord_px": summarize(curve),
            "max_abs_chord_error_px": float(np.max(np.abs(curve))),
            "detector_span_first_middle_last_px": [
                measured_width[i] for i in [0, len(guides) // 2, -1]
            ],
            "span_limit": "Traced native pixel spans only. Foreground right edge is cropped; the last span is a lower bound.",
        },
        "paper_max_min_median_Y_ratio": round(max(luminance) / min(luminance), 3),
        "paper_max_min_median_EV": round(
            float(np.log2(max(luminance) / min(luminance))), 3
        ),
        "sampling": "3 x 3 strata. 13 neighborhoods per row around each checked column. Edge spread is the mean of both 20–80% flanks of a printed ruling measured vertically; local shoulder subtraction and >=5 luminance-unit depth required. Blank-paper luminance is measured 19–40% of a local pitch above each ruling. Percentiles cover valid sample taps. Bootstrap resamples marked rows within each stratum (2000 draws, fixed seed).",
        "limits": "One processed JPEG. Relative linear-light Y assumes sRGB; absolute illuminance, shutter exposure, ISO, PSF, pen reflectance and independent scene-level uncertainty are unidentifiable. Printed line thickness, curvature, compression and resampling affect measured edges. Bootstrap intervals quantify row-sample variability on this photograph alone.",
        "strata": grid,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("photo", type=Path)
    parser.add_argument("result", type=Path)
    args = parser.parse_args()
    result = audit(args.photo)
    args.result.parent.mkdir(exist_ok=True, parents=True)
    args.result.write_text(
        json.dumps(result, indent=2, ensure_ascii=False, allow_nan=False) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
