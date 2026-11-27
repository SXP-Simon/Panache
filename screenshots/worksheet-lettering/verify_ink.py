"""Check the code/diagram rows in measurements.json from the native grayscale crops."""
import json
from pathlib import Path
from statistics import median

from PIL import Image


def verify():
    root = Path(__file__).resolve().parent
    sheet = Image.open(root / "ink-pixels.png")
    assert sheet.mode == "L" and sheet.size == (965, 4 * 345)
    metrics = json.loads((root / "measurements.json").read_text(encoding="utf-8"))
    for stage_index, stage in enumerate(("before", "geometry", "after"), start=1):
        result = {}
        for region in ("code", "diagram"):
            expected = metrics["pixel_contrast"][stage][region]
            x, y, right, bottom = expected["box"]
            box = (x - 205, y - 365, right - 205, bottom - 365)
            paper = sheet.crop(box)
            target = sheet.crop((box[0], box[1] + 345 * stage_index,
                                 box[2], box[3] + 345 * stage_index))
            drops = sorted(blank - mark for blank, mark in zip(paper.tobytes(), target.tobytes())
                           if blank > 125 and blank - mark > 20)
            assert len(drops) == expected["pixels"] and median(drops) == expected["p50"]
            index, remainder = divmod((len(drops) - 1) * 9, 10)
            p90 = (drops[index] * (10 - remainder) + drops[min(index + 1, len(drops) - 1)] * remainder) / 10
            assert p90 == expected["p90"]
            result[region] = median(drops)
        print(stage, result)


if __name__ == "__main__":
    verify()
