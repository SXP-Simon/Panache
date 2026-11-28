"""Supplementary evaluator for physical fit and externally specified row assignments.

The pilot's preregistered contiguous-index score and actor inputs remain in
paper_geometry.py. Physical row numbers here are zero-based.
"""

from collections import Counter, defaultdict
from itertools import pairwise

import numpy as np
from paper_geometry import (
    _assigned_glyphs,
    _pitch,
    _reference_y,
    _sample_baseline,
    score_ink,
)


def diagnose_page(
    labels, glyphs, *, background=None, rendered=None, required_rows=None
):
    """Measure nearest ruling and intentional row slots separately, one page at a time.

    required_rows maps occupied source-line index to a user-specified physical row.
    With no such instruction, report skipped/reused rows without interpreting them
    as failures. Pagination and source completeness need the enclosing artifact.
    """
    if (background is None) != (rendered is None):
        raise ValueError("Supply both the blank paper and the final rendering")
    glyphs = list(glyphs)
    nrows = len(labels["rows"])
    targets = dict(required_rows or {})
    if any(source < 0 or not 0 <= target < nrows for source, target in targets.items()):
        raise ValueError("Invalid source or required physical row")
    fit = []
    required_errors = defaultdict(list)
    votes = defaultdict(Counter)
    annotated = {}
    for source, glyph in _assigned_glyphs(labels, glyphs, first_row=0):
        x, y = _sample_baseline(glyph).mean(axis=0)
        distances = [abs(y - _reference_y(labels, row, x)) for row in range(nrows)]
        row = min(range(nrows), key=distances.__getitem__)
        fit.append(float(distances[row] / _pitch(labels, row, x)))
        votes[source][row] += 1
        annotated[id(glyph)] = dict(glyph, source_row=row)
        if source in targets:
            target = targets[source]
            required_errors[source].append(
                float(distances[target] / _pitch(labels, target, x))
            )

    assignments = []
    for source, counts in sorted(votes.items()):
        row, count = counts.most_common(1)[0]
        assignments.append(
            {
                "source_line": source,
                "dominant_physical_row": row,
                "agreeing_glyphs": count,
                "measured_glyphs": sum(counts.values()),
            }
        )
    ordered = [item["dominant_physical_row"] for item in assignments]
    # Count even minority glyphs as evidence of a physically occupied row.
    occupied = sorted({row for counts in votes.values() for row in counts})
    interior = (
        sorted(set(range(occupied[0], occupied[-1] + 1)).difference(occupied))
        if occupied
        else []
    )
    required = [
        {
            "source_line": source,
            "required_physical_row": row,
            "p90_abs_rows": float(np.percentile(required_errors[source], 90))
            if required_errors[source]
            else None,
            "glyphs_on_requested_ruling": votes[source][row],
            "measured_glyphs": len(required_errors[source]),
        }
        for source, row in sorted(targets.items())
    ]
    raster = None
    if background is not None:
        raster = score_ink(
            labels, background, rendered, [annotated.get(id(g), g) for g in glyphs]
        )
    return {
        "eligible_glyphs": sum(not g.get("kind") for g in glyphs),
        "measured_glyphs": len(fit),
        "nearest_median_abs_rows": float(np.median(fit)) if fit else None,
        "nearest_p90_abs_rows": float(np.percentile(fit, 90)) if fit else None,
        "occupied_physical_rows": occupied,
        "interior_unused_rows": interior,
        "unoccupied_leading_rows": occupied[0] if occupied else None,
        "unoccupied_trailing_rows": nrows - 1 - occupied[-1] if occupied else None,
        "nonincreasing_line_transitions": sum(b <= a for a, b in pairwise(ordered)),
        "source_row_assignments": assignments,
        "required_assignments": required,
        "nearest_raster": raster,
    }


def page_sequence(pages):
    """List observed page numbers by section; use source/PDF checks for completeness."""
    sections = defaultdict(list)
    for page in pages:
        sections[page["section"]].append(page["page"])
    return [
        {
            "section": section,
            "observed_pages": sorted(numbers),
            "missing_page_numbers": sorted(
                set(range(1, max(numbers) + 1)).difference(numbers)
            ),
            "duplicate_page_numbers": sorted(
                p for p, n in Counter(numbers).items() if n > 1
            ),
        }
        for section, numbers in sorted(sections.items())
    ]
