"""Check the published PNGs and both replay receipts. Requires Pillow and NumPy."""

import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image

root = Path(__file__).resolve().parent


def read_json(name):
    return json.loads((root / name).read_text(encoding="utf-8"))


def rgb(name):
    with Image.open(root / name) as image:
        assert image.size == (1440, 1920)
        return np.asarray(image.convert("RGB"))


before = rgb("original-v15.png")
fault = rgb("deliberate-tilt-v16-full.png")
restored = rgb("restored-v17-full.png")
assert np.array_equal(before, restored)
checks = read_json("three-state-checks.json")
assert (
    np.any(before != fault, axis=2).sum() == checks["original_vs_fault_changed_pixels"]
)
body = rgb("body-reference.png")
body_ink = np.any(body != rgb("mcp-paper.png"), axis=2)
assert body_ink.sum() == checks["body_non_background_pixels"]

for filename in ("control-final-replay.json", "independent-final-replay.json"):
    for receipt in read_json(filename):
        if "published_png" not in receipt:
            continue
        page = rgb(receipt["published_png"])
        assert (
            hashlib.sha256(page.tobytes()).hexdigest() == receipt["render_sha256_rgb"]
        )
        assert np.array_equal(page[body_ink], body[body_ink])
        (item,) = receipt["diagram_perspective_check"]["items"]
        print(
            receipt["published_png"],
            item["kind"],
            item["axis_difference_deg_top_bottom_left_right"],
        )
