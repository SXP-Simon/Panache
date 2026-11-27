"""Run with Pillow to check paired tool calls and published full-resolution RGB outputs."""
import hashlib
import json
from pathlib import Path

from PIL import Image

root = Path(__file__).resolve().parent
record = json.loads((root / "blind-trials.json").read_text(encoding="utf-8"))
for trial, data in record["trials"].items():
    revision = data["final_revision"]
    modes = {}
    for event in data["events"]:
        args = event["arguments"]
        if (event["tool"] != "preview_handwriting" or args.get("view", "image") != "image"
                or args.get("revision") != revision or "region" not in args):
            continue
        identity = (args["draft_id"], args.get("section", 1), args.get("page", 1),
                    tuple(map(tuple, args["region"])))
        seen = modes.setdefault(identity, set())
        if args.get("export_blur_px") == 0:
            seen.add("clear")
        if "export_blur_gradient" in args:
            seen.add("gradient")
    pairs = sum(len(seen) == 2 for seen in modes.values())
    assert pairs == data["final_revision_paired_crops"]
    if trial in ("c1", "c2"):
        with Image.open(root / f"worksheet-{trial[1]}.png") as png:
            assert png.size == (1440, 1920)
            assert hashlib.sha256(png.convert("RGB").tobytes()).hexdigest() == data["delivered_rgb_sha256"]
    print(f"{trial}: {pairs} distinct paired regions on revision {revision}")
