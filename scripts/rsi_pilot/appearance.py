"""Post-hoc optical comparison on native pixels; never an actor decision rule."""

import numpy as np
from PIL import Image, ImageDraw
from scipy.signal import find_peaks, peak_widths


def sample_profile(signal, support):
    # Bright peaks are dark strokes. For the same peak measure the mean of
    # its two 20–80% plateau-to-background transition lengths, in pixels.
    peaks, properties = find_peaks(
        signal, prominence=12, distance=3, wlen=45, plateau_size=(None, 20)
    )
    keep = support[peaks]
    peaks = peaks[keep]
    if not len(peaks):
        return []
    prominence = tuple(
        properties[key][keep] for key in ("prominences", "left_bases", "right_bases")
    )
    lower = peak_widths(signal, peaks, rel_height=0.8, prominence_data=prominence)[0]
    upper = peak_widths(signal, peaks, rel_height=0.2, prominence_data=prominence)[0]
    # Cap the support width to discard broad shadow ramps and solid blocks.
    return ((lower[lower <= 22] - upper[lower <= 22]) / 2).tolist()


def edge_bands(directory, page, glyphs):
    with Image.open(directory / "paper.png") as bg, Image.open(directory / page) as fg:
        w, h = bg.size
        paper = np.asarray(bg.convert("L"), dtype=np.int16)
        ink = np.maximum(paper - np.asarray(fg.convert("L"), dtype=np.int16), 0)
    paper = 255 - paper
    ink_mask, local_mask = (Image.new("1", (w, h)) for _ in range(2))
    inside, near = ImageDraw.Draw(ink_mask), ImageDraw.Draw(local_mask)
    for glyph in glyphs:
        quad = glyph.get("current_photo_quad", glyph.get("photo_quad"))
        if not quad:
            continue
        points = [tuple(point) for point in quad]
        inside.polygon(points, fill=1)
        x, y = zip(*points)
        pad = max(4, (max(y) - min(y)) // 2)
        near.rectangle((min(x) - pad, min(y) - pad, max(x) + pad, max(y) + pad), fill=1)
    ink_mask, local_mask = (
        np.asarray(ink_mask, dtype=bool),
        np.asarray(local_mask, dtype=bool),
    )
    bands = {}
    for n, band in enumerate(("top", "middle", "bottom")):
        lo, hi = n * h // 3, (n + 1) * h // 3
        values = {}
        for key, layer, mask in (
            ("print", paper, local_mask),
            ("writing", ink, ink_mask),
        ):
            widths = []
            for x in range(4, w, 8):
                support = mask[lo:hi, x]
                if np.any(support):
                    widths.extend(sample_profile(layer[lo:hi, x], support))
            values[key] = {
                "sampled_stroke_peaks": len(widths),
                "median_transition_px": float(np.median(widths))
                if len(widths) >= 6
                else None,
            }
        bands[band] = values
    return bands


def appearance(directory, ref, review, glyphs):
    focus = review.get("paper_focus_check", {})
    paper_widths = [
        {
            k: r[k]
            for k in (
                "role",
                "sample_point",
                "median_edge_width_px",
                "scan_direction",
                "sampled_strokes",
            )
            if k in r
        }
        for r in focus.get("regions", [])
    ]
    contrast = []
    for r in review.get("evidence", {}).get("local_paper_ink", {}).get("samples", []):
        printing, writing = r.get("paper_marks", {}), r.get("added_writing", {})
        contrast.append(
            {
                "role": r.get("role"),
                "region": r.get("writing_region"),
                "paper_median_luma_drop": printing.get("median_luma_drop"),
                "paper_p75_luma_drop": printing.get("p75_luma_drop"),
                "writing_median_glyph_p90_drop": writing.get(
                    "median_glyph_p90_luma_drop"
                ),
                "status": r.get("status"),
            }
        )
    return {
        "mcp_original_paper_focus": {
            "status": focus.get("status"),
            "regions": paper_widths,
        },
        "mcp_local_contrast": contrast,
        "posthoc_vertical_edge_bands": edge_bands(directory, ref["image"], glyphs),
    }
