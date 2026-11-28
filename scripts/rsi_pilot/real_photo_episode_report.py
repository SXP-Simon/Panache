"""Assemble shareable native interior crops and anonymous hash-linked receipts from this episode."""

import argparse
import json
import shutil
import subprocess
from pathlib import Path

import numpy as np
from benchmark import digest, read, write
from PIL import Image, ImageDraw
from real_photo_episode import WINDOWS


def panel(dest, items):
    width = max(im.width for _, im in items)
    height = sum(im.height + 24 for _, im in items)
    canvas = Image.new("RGB", (width, height), "white")
    draw = ImageDraw.Draw(canvas)
    top = 0
    for label, img in items:
        draw.text((3, top + 3), label, fill="black")
        canvas.paste(img, (0, top + 24))
        top += img.height + 24
    canvas.save(dest)


def collect(out, results):
    stage = out / "homework"
    assets = out / "public-assets"
    assets.mkdir(exist_ok=True)
    manifest = read(out / "manifest.json")
    selection = read(out / "selection-summary.json")
    chosen = selection["selected_revision"]
    if not chosen:
        raise ValueError("No selected artifact to summarize")
    d = stage / f"r{chosen}"
    tiles = []
    for name, (page, box) in WINDOWS.items():
        with Image.open(d / f"page-{page}.png") as img:
            tiles.append((name, img.convert("RGB").crop(box)))
    panel(assets / "selected-homework-interior.png", tiles)
    controls = read(out / "equation-controls/report.json")
    extra = read(out / "equation-controls/U8A/outcome.json")
    controls["additional_real_math_command"] = extra
    control_images = []
    for condition in [*controls["results"], extra]:
        path = assets / ("formula-" + condition["condition"] + ".png")
        shutil.copyfile(
            out / "equation-controls" / condition["opaque_id"] / "region.png", path
        )
        with Image.open(path) as img:
            control_images.append(
                (
                    condition["condition"] + "   " + condition["vote"]["decision"],
                    img.convert("RGB"),
                )
            )
    panel(assets / "five-formula-controls.png", control_images)
    repair = read(out / "equation-repair/outcome.json")
    items = []
    for name, path in [
        ("Missing denominator (rejected)", out / "equation-repair/before.png"),
        ("Restored denominator (accepted)", out / "equation-repair/after.png"),
        (
            "Unsupported command in display math (rejected)",
            out / "equation-controls/U8A/region.png",
        ),
    ]:
        with Image.open(path) as img:
            items.append((name, img.convert("RGB")))
    panel(assets / "formula-interception.png", items)
    scores = {}
    for rev in (1, 2, 3):
        snapshot = stage / f"r{rev}"
        page_stats = []
        for p in (1, 2):
            with (
                Image.open(snapshot / f"page-{p}.png") as now,
                Image.open(stage / "r1" / f"page-{p}.png") as base,
            ):
                a = np.asarray(now.convert("RGB"))
                b = np.asarray(base.convert("RGB"))
                changed = np.any(a != b, axis=2)
                page_stats.append(
                    {
                        "page": p,
                        "changed_rgb_pixels_vs_r1": int(changed.sum()),
                        "header_rows_0_210_changed": int(changed[:210].sum()),
                        "paper_only_page_two_below_y500_changed": int(
                            changed[500:].sum()
                        )
                        if p == 2
                        else None,
                    }
                )
        scores[str(rev)] = {
            "native_pages": read(snapshot / "pages.json"),
            "export": read(
                stage / ("initial.json" if rev == 1 else f"candidate-{rev}.json")
            ),
            "rendered_change": page_stats,
            "native_roi_measurements": read(snapshot / "optical-evidence.json")[
                "native_windows"
            ],
        }
    raw = read(stage / "r1/nodes.json")["components"]
    objects = []
    for n in raw:
        summary = {
            k: v
            for k, v in n.items()
            if k
            in {
                "id",
                "kind",
                "rows",
                "numerator",
                "denominator",
                "flowchart",
                "width",
                "height",
            }
        }
        if "marks" in n:
            summary["mark_count"] = len(n["marks"])
        objects.append(summary)
    probe = Path(manifest["runtime"]["probe"])
    frozen = out / ("frozen-content-probe" + probe.suffix)
    if frozen.is_file():
        probe = frozen
    verified = []
    for area in ("homework", "local-refinement", "equation-repair"):
        for snapshot in sorted((out / area).glob("r[0-9]*")):
            if not (snapshot / "nodes.json").exists():
                continue
            prepared = (snapshot / "prepared.txt").read_text(encoding="utf8")
            checked = json.loads(
                subprocess.check_output([str(probe)], input=prepared.encode())
            )
            if checked != read(snapshot / "nodes.json"):
                raise ValueError("AST differs on recheck")
            verified.append(f"{area}/{snapshot.name}")
    doc = {
        "scope": "One byte-identical development photograph from the earlier pilot. A short host-authored reproducible Markdown fixture, independently judged by real Codex CLI Terra requests. No claim of human authenticity or generalization.",
        "brief": manifest["brief"],
        "provenance": {
            k: v for k, v in manifest["runtime"].items() if k.endswith("_sha256")
        },
        "source_sha256": manifest["source_sha256"],
        "probe_recheck": {
            "binary_sha256": digest(probe.read_bytes()),
            "matching_snapshots": verified,
            "note": "The initial manifest recorded the original probe hash. The shared build directory was rebuilt during this run. The listed AST snapshots match this separately hashed probe on retained worker output. It is an inspection tool external to the MCP renderer.",
        },
        "native_components": objects,
        "design": {
            "seed": 64019,
            "homework": True,
            "font_size": 34,
            "font": "李国夫手写体.ttf",
            "physical_pages": 2,
            "pagination": "Second page has only the concluding sentence.",
        },
        "unprompted": {
            "vote": {
                "decision": read(stage / "unprompted/decision.json")["decision"],
                "observations": [
                    *read(stage / "unprompted/decision.json")["observations"][:-1],
                    "[Institution name withheld] The draft was rendered on the supplied ruled stationery.",
                ],
                "redaction": "The last observation is paraphrased to remove the printed institution. The receipt hashes the original unredacted model response.",
            },
            "receipt": read(stage / "unprompted/receipt.json"),
            "omissions": "Confirmed the visible arithmetic and named all content types. Did not mention regional exposure, focus, geometric fit, or the sparse second page.",
        },
        "guided": {
            "vote": read(stage / "guided/decision.json"),
            "receipt": read(stage / "guided/receipt.json"),
            "guide_version": read(stage / "guidance.json")["version"],
            "guide_sha256": read(stage / "guidance.json")["guide_sha256"],
            "task_id": read(stage / "guided-native-outcome.json")["task_id"],
            "selected_revision": 1,
        },
        "native_challenge": {
            "initiator": "Operator after guided keep. An independent blinded model made the actual terminal choice.",
            "mapping": read(stage / "challenges.json")["mapping"],
            "settings": read(stage / "challenges.json")["settings"],
            "fresh_baseline_byte_equivalent": True,
            "comparisons": scores,
            "selection": selection,
            "limitation": "Separate optical-only assessments of r1/r2 in both positions preferred r1. Assessors disagree. The three-way choice is the observed delivery choice, not evidence of a consistent optical gain.",
        },
        "equation_controls": controls,
        "formula_repair": repair,
        "scope_note": "The supplemental genuine display-math unsupported command was added after the four seeded single-region evaluations; its prompt and native crop were the same. Each case has a separate fresh model context. Exact positive images repeat across repair and clean control. These are controls, not an estimate of population accuracy.",
        "public_interior_assets": {
            p.name: digest(p.read_bytes())
            for p in [
                assets / "selected-homework-interior.png",
                assets / "formula-interception.png",
                assets / "five-formula-controls.png",
                *[
                    assets / ("formula-" + c["condition"] + ".png")
                    for c in [*controls["results"], extra]
                ],
            ]
        },
    }
    results.mkdir(parents=True, exist_ok=True)
    write(results / "real-photo-episode.json", doc)
    write(out / "real-photo-episode.json", doc)
    write(
        out / "equation-control-protocol-note.json",
        {
            "original_manifest_sha256": digest((out / "manifest.json").read_bytes()),
            "clarification": "The original manifest contained a preliminary prose-escaped literal-command condition. The actual four conditions were frozen in equation-controls/design.json before rendering. A fifth real display-math command was evaluated later and reported separately.",
            "executed_design_sha256": digest(
                (out / "equation-controls/design.json").read_bytes()
            ),
        },
    )


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--results", type=Path, required=True)
    a = p.parse_args()
    collect(a.out.resolve(), a.results.resolve())
