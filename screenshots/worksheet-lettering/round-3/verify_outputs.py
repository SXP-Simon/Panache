"""Recheck final PNGs, native preview crops and paper-relative field contrast.

Run with numpy, Pillow and scipy. To verify the entire sharp edit boundary against
the previous published page, optionally pass its native worksheet-round-2.png path.
"""
from pathlib import Path
import hashlib
import json
import sys

import numpy as np
from PIL import Image
from scipy.ndimage import median_filter

ROOT = Path(__file__).resolve().parent
data = json.loads((ROOT / "ramp-and-export.json").read_text(encoding="utf-8"))
ink = json.loads((ROOT / "page-ink-samples.json").read_text(encoding="utf-8"))
ox, oy, _, _ = ink["packed_lumas"]["xyxy_exclusive"]
paper, baseline, _, _ = np.moveaxis(np.array(Image.open(ROOT / ink["packed_lumas"]["file"]), dtype=float), 2, 0)
rule = median_filter(paper, size=(21, 1)) - paper
samples = np.load(ROOT / "export-field-lumas.npz", allow_pickle=False)
x, y = samples["x"].astype(int), samples["y"].astype(int)
p0, base = paper[y-oy, x-ox], baseline[y-oy, x-ox]
eligible = (p0 - base > 18) & (rule[y-oy, x-ox] < 12)
images = {}
for key, alternative in [("clear", "sharp"), ("mild", "soft")]:
    image = Image.open(ROOT / data["selected_result"][alternative]).convert("RGB")
    images[key] = image
    res = data["exports"][key]
    assert list(image.size) == res["dimensions"] and res["fresh"]
    assert hashlib.sha256(image.tobytes()).hexdigest() == res["rgb_sha256"] == res["native_preview_rgb_sha256"]
    for area in res["preview_crop_checks"]:
        assert hashlib.sha256(image.crop(tuple(area["xyxy_exclusive"])).tobytes()).hexdigest() == area["rgb_sha256"]

for area in data["comparison_scope"]["protected_regions"].values():
    digest = hashlib.sha256(images["clear"].crop(tuple(area["xyxy_exclusive"])).tobytes()).hexdigest()
    assert digest == area["identical_rgb_sha256"]

if len(sys.argv) > 1:
    prior = Image.open(sys.argv[1]).convert("RGB")
    assert hashlib.sha256(prior.tobytes()).hexdigest() == data["prior_v24_sha256"]
    changed = np.any(np.array(prior) != np.array(images["clear"]), axis=2)
    yy, xx = np.nonzero(changed)
    assert changed.sum() == data["comparison_scope"]["native_changed_pixels"]
    assert [xx.min(), yy.min(), xx.max()+1, yy.max()+1] == data["comparison_scope"]["changed_bbox_xyxy_exclusive"]

states = {
    "v24": (p0, base),
    "clear": (p0, np.asarray(images["clear"].convert("L"))[y, x]),
    "sigma_0.6": (samples["paper_06"].astype(float), np.asarray(images["mild"].convert("L"))[y, x]),
    "sigma_1.0": (samples["paper_1"].astype(float), samples["output_1"]),
}
for label, field in data["field_samples"].items():
    group = np.zeros(len(x), dtype=bool)
    for l, t, r, b in field["boxes"]:
        group |= (x >= l) & (x < r) & (y >= t) & (y < b)
    group &= eligible
    for name, (paper_luma, output_luma) in states.items():
        drop = (paper_luma - output_luma)[group]
        expect = field["states"][name]
        assert len(drop) == expect["pixels"]
        assert np.isclose(np.percentile(drop, 90), expect["p90_drop"])
        assert np.isclose(np.median(drop), expect["p50_drop"])
        ratio = float(np.median(drop / (p0 - base)[group]))
        assert abs(ratio - expect["median_darkening_ratio"]) < 0.000051
        assert np.median(output_luma[group]) == expect["p50_rendered_luma"]

print("Verified native sharp and soft PNGs, crop hashes, protected regions, and four states for 13 writing / diagram regions.")
