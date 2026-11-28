"""Image-only, anonymous equation controls rendered onto the identical photographic background."""

import argparse
import random
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from benchmark import Server, digest, read, save_image, write
from content_matrix import opinion
from PIL import Image
from real_photo_episode import BRIEF, FORMULA, source

CONTROLS = {
    "valid_delta": FORMULA,
    "valid_simplified": r"$$T=\frac{2.0}{4}=0.5\,\mathrm{s}$$",
    "missing_denominator": r"$$T=(2.5-0.5)=0.5\,\mathrm{s}$$",
    "literal_command": r"`T = \badfrac{2.5-0.5}{4} = 0.5 s`",
}
BOX = (120, 615, 1240, 738)


def run_one(out, spec):
    key, formula, code = spec
    cfg = read(out / "manifest.json")["runtime"]
    folder = out / "equation-controls" / code
    folder.mkdir(parents=True, exist_ok=True)
    if key == "valid_delta":
        im = Image.open(out / "homework/r1/page-1.png")
    elif (folder / "private-page.png").exists():
        im = Image.open(folder / "private-page.png")
    else:
        with Server(
            cfg, folder / "db", "blinded_equation_control", log_dir=folder
        ) as server:
            created = server.call(
                "save_section",
                markdown=source(formula),
                paper_path=cfg["photo"],
                title="传感器周期测量",
                style={
                    "homework": True,
                    "seed": 64019,
                    "font_size": 34,
                    "font": "李国夫手写体.ttf",
                },
            )["structuredContent"]
            draft = created["draft_id"]
            response = server.call(
                "preview_handwriting",
                draft_id=draft,
                revision=1,
                section=1,
                page=1,
                view="image",
            )
            save_image(response, folder / "private-page.png")
            rendered = server.call(
                "read_section",
                draft_id=draft,
                revision=1,
                section=1,
                view="source",
                limit=4000,
            )["structuredContent"]
            assert rendered["markdown"] == source(formula)
        im = Image.open(folder / "private-page.png")
    im.convert("RGB").crop(BOX).save(folder / "region.png")
    prompt = (
        BRIEF
        + "\n你独立检查本题的周期计算式。附件仅为同尺度、未加标记的原尺寸公式区域，而非完整作业。请转录你看到的运算式，然后判断该算式是否可交。看不清用 uncertain。只输出 JSON {transcription,decision:accept或repair或uncertain,reason}，不要调用工具。"
    )
    vote = opinion(folder / "vote", prompt, [folder / "region.png"])
    return {
        "opaque_id": code,
        "condition": key,
        "expected": "accept" if key.startswith("valid") else "repair",
        "equation_source": formula,
        "image_sha256": digest((folder / "region.png").read_bytes()),
        "source_sha256": digest(source(formula).encode()),
        "vote": vote,
        "receipt": read(folder / "vote/receipt.json"),
    }


def run(out):
    conditions = list(CONTROLS.items())
    random.Random(641992).shuffle(conditions)
    rows = [
        (*v, code)
        for v, code in zip(conditions, ("J4R", "M8D", "N2V", "K9T"), strict=True)
    ]
    write(
        out / "equation-controls" / "design.json",
        {"crop": BOX, "conditions": rows, "brief": BRIEF},
    )
    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(lambda row: run_one(out, row), rows))
    write(
        out / "equation-controls" / "report.json",
        {
            "scope": "Image-only formula row, four independent Terra contexts; omitted denominator and literal control are engineered, not natural renderer failure rates.",
            "native_crop": BOX,
            "results": results,
        },
    )
    print([(r["condition"], r["vote"].get("decision")) for r in results])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    run(parser.parse_args().out.resolve())
