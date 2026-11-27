"""Recalculate all accepted pen-width measurements from the lossless paper and output samples.

Run python verify_widths.py in this folder with numpy and Pillow installed.
The companion JSON records every trace origin, orientation, search range and measured values.
"""
import json
from pathlib import Path
from statistics import median

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent
DATA = json.loads((ROOT / "line-samples.json").read_text(encoding="utf-8"))
left, top, right, bottom = DATA["packed_luma"]["xyxy_exclusive"]
paper, first, second = np.moveaxis(np.array(Image.open(ROOT / DATA["packed_luma"]["file"]), dtype=float), 2, 0)
assert paper.shape == (bottom - top, right - left)
step = 0.125
axis = np.arange(-10, 10.001, step)


def sample_at(image, x, y):
    xi, yi = x.astype(int), y.astype(int)
    dx, dy = x - xi, y - yi
    return (
        image[yi, xi] * (1 - dx) * (1 - dy) + image[yi, xi + 1] * dx * (1 - dy)
        + image[yi + 1, xi] * (1 - dx) * dy + image[yi + 1, xi + 1] * dx * dy
    )


def trace(drop, s):
    _, _, expected_width, expected_peak, _, x, y, nx, ny, radius = s
    offsets = sample_at(drop, x - left + nx * axis, y - top + ny * axis)
    candidates = np.flatnonzero(abs(axis) <= radius)
    peak = candidates[np.argmax(offsets[candidates])]
    height = offsets[peak] / 2
    i = np.flatnonzero(offsets[:peak] < height)[-1]
    j = peak + 1 + np.flatnonzero(offsets[peak + 1:] < height)[0]
    lo = axis[i] + step * (height - offsets[i]) / (offsets[i + 1] - offsets[i])
    hi = axis[j - 1] + step * (height - offsets[j - 1]) / (offsets[j] - offsets[j - 1])
    assert abs(hi - lo - expected_width) <= 0.00051
    assert abs(offsets[peak] - expected_peak) <= 0.0051
    return round(hi - lo, 3), round(offsets[peak], 2)


if __name__ == "__main__":
    for key, output in [("first_round_edges", first), ("second_round_edges", second), ("unchanged_body_rows", first)]:
        widths, peaks, count = [], [], 0
        for group in DATA[key].values():
            profiles = [trace(paper - output, s) for s in group["samples"]]
            widths.append(round(median(w for w, _ in profiles), 3))
            peaks.append(median(p for _, p in profiles))
            count += len(profiles)
        summary = DATA["summary"][key]
        assert count == summary["profiles"]
        assert round(median(widths), 3) == summary["typical_width_px"]
        assert round(median(peaks), 2) == summary["typical_peak_drop"]
        print(f"{key}: {count} samples; {median(widths):.3f} px FWHM; peak luma drop {median(peaks):.2f}.")
