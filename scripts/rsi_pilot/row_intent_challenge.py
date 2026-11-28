"""Run a validator-only paired instruction challenge; optionally audit a saved grid run."""

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from paper_geometry import load_labels, score_layout
from PIL import Image, ImageDraw, ImageFont
from ruling_fit import diagnose_page, page_sequence


def challenge_sheet():
    """A new six-ruling sheet. Both instructions receive exactly the same ink."""
    width, height = 328, 234
    xs = [15, 164, 313]
    rows = [[41 + 31 * i, 38 + 31 * i, 35 + 31 * i] for i in range(6)]
    labels = {"size": [width, height], "xs": xs, "rows": rows}
    blank = Image.new("RGB", (width, height), (246, 243, 234))
    marks = ImageDraw.Draw(blank)
    for row in rows:
        marks.line(list(zip(xs, row)), fill=(149, 156, 146))
    final = blank.copy()
    ink = ImageDraw.Draw(final)
    font = ImageFont.load_default(size=20)
    glyphs = []
    for source, (physical, text) in enumerate([(0, "Peak 12V"), (2, "Peak 16V")]):
        for i, character in enumerate(text):
            if character.isspace():
                continue
            x = 30 + i * 19
            y = round(float(np.interp(x, xs, rows[physical])))
            ink.text((x, y), character, font=font, anchor="ls", fill=(44, 48, 52))
            left, top, right, bottom = ink.textbbox(
                (x, y), character, font=font, anchor="ls"
            )
            right += 1
            bottom += 1

            left_y = round(float(np.interp(left, xs, rows[physical])))
            right_y = round(float(np.interp(right, xs, rows[physical])))

            glyphs.append(
                {
                    "id": len(glyphs),
                    "source_row": source,
                    "bounds": [left, top, right - left, bottom - top],
                    "photo_quad": [
                        [left, top],
                        [right, top],
                        [right, bottom],
                        [left, bottom],
                    ],
                    "photo_baseline": [[left, left_y], [right, right_y]],
                }
            )
    return labels, blank, final, glyphs


def intent_flag(result, limit):
    if (
        not result["measured_glyphs"]
        or result["measured_glyphs"] < result["eligible_glyphs"]
        or result["nearest_raster"]["glyphs_with_visible_ink"]
        < result["eligible_glyphs"]
    ):
        return "insufficient"
    targets = result["required_assignments"]
    if (
        result["nearest_p90_abs_rows"] > limit
        or result["nonincreasing_line_transitions"] > 0
    ):
        return "review"
    if any(t["p90_abs_rows"] is None or t["p90_abs_rows"] > limit for t in targets):
        return "review"
    return "pass"


def paired_challenge():
    labels, blank, final, glyphs = challenge_sheet()
    limit = 0.25
    indexed = score_layout(labels, glyphs)
    items = []
    for key, instructions, targets, expected in [
        (
            "paragraph_gap",
            "Write two readings on the sheet. A blank line between readings is allowed.",
            {},
            "pass",
        ),
        (
            "named_row",
            "Write the first reading on the first ruling and the second on the second ruling.",
            {0: 0, 1: 1},
            "review",
        ),
    ]:
        measured = diagnose_page(
            labels, glyphs, background=blank, rendered=final, required_rows=targets
        )
        items.append(
            {
                "case": key,
                "instruction": instructions,
                "expected": expected,
                "indexed_p90_abs_rows": indexed["p90_abs_rows"],
                "nearest_p90_abs_rows": measured["nearest_p90_abs_rows"],
                "unused_interior_rows": measured["interior_unused_rows"],
                "required_assignments": measured["required_assignments"],
                "visible_glyphs": measured["nearest_raster"]["glyphs_with_visible_ink"],
                "indexed_rule": "review" if indexed["p90_abs_rows"] > limit else "pass",
                "intent_aware_rule": intent_flag(measured, limit),
            }
        )
    return {
        "scope": "Post-run evaluator regression, designed after the grid ambiguity. The actor never sees this sheet. The pair demonstrates a distinction, not a performance estimate.",
        "threshold_abs_p90_rows": limit,
        "shared_blank_rgb_sha256": hashlib.sha256(blank.tobytes()).hexdigest(),
        "shared_final_rgb_sha256": hashlib.sha256(final.tobytes()).hexdigest(),
        "paired_cases": items,
    }


def archived_grid(folder):
    arm = folder / "public-grid" / "A"
    state = json.loads((arm / "state.json").read_text(encoding="utf-8"))
    revision = str(state["selected_revision"])
    pages = state["snapshots"][revision]
    directory = arm / f"r{revision}"
    result = []
    for p in pages:
        prefix = f"s{p['section']}p{p['page']}"
        glyphs = json.loads(
            (directory / f"{prefix}-glyphs.json").read_text(encoding="utf-8")
        )
        frozen = json.loads(
            (directory / f"{prefix}-score.json").read_text(encoding="utf-8")
        )
        measured = diagnose_page(
            load_labels("public-grid"),
            glyphs,
            background=directory / "paper.png",
            rendered=directory / p["image"],
        )
        result.append(
            {
                "section": p["section"],
                "page": p["page"],
                "png_sha256": p["sha256"],
                "archived_indexed_p90_abs_rows": frozen["layout"]["p90_abs_rows"],
                "matched_physical_rulings": measured,
            }
        )
    return {
        "snapshot_revision": revision,
        "page_sequence": page_sequence(pages),
        "pages": result,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--run-root", type=Path, help="Read the local archived native A grid revision"
    )
    parser.add_argument(
        "--write-images", type=Path, help="Save the two public synthetic images here"
    )
    args = parser.parse_args()
    report = paired_challenge()
    if args.run_root:
        report["native_grid_diagnostic"] = archived_grid(args.run_root)
    if args.write_images:
        args.write_images.mkdir(exist_ok=True, parents=True)
        _, blank, final, _ = challenge_sheet()
        blank.save(args.write_images / "blank.png")
        final.save(args.write_images / "pair-shared.png")
    print(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False))


if __name__ == "__main__":
    main()
