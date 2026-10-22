# Copyright (c) 2026 Simon and Panache contributors.
"""2026-10-22：真实纸张中的电路边界、整体缩放与字形回归."""

import json
from collections import Counter
from pathlib import Path

import pytest
import symbol_fallback as symbols
from circuit_document import circuit_spans
from handright import Template, handwrite
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = json.loads((ROOT / "e2e/fixtures/circuitikz.json").read_text(encoding="utf-8"))
FONT = str(ROOT / "backend/font_assets/霞鹜文楷.ttf")
RC = FIXTURES[0]["source"]
COMPONENTS = {
    "rc-lowpass": {"V": 1, "R": 1, "C": 1},
    "rlc-ac": {"sV": 1, "R": 1, "L": 1, "C": 1},
    "parallel-current": {"I": 1, "R": 1, "C": 1},
    "switch-capacitor": {"battery1": 1, "switch": 1, "R": 1, "C": 1},
    "diode-bridge": {"D": 4, "R": 1},
    "named-relative": {"V": 1, "R": 1, "C": 1},
    "orthogonal-ports": {"R": 1, "C": 1},
    "unit-labels": {"R": 1, "C": 1},
    "reverse-led": {"led": 1, "R": 1},
    "node-labels": {"R": 1},
    "component-shorthand": {"V": 1, "R": 1, "C": 1},
}


@pytest.mark.parametrize("case", FIXTURES, ids=lambda case: case["id"])
def test_circuit_source_is_rigid_or_wholly_literal(case):
    result = symbols.normalize_text_for_font(case["source"], FONT)
    if not case["valid"]:
        assert result == case["source"]
        return
    assert len(result) == 1
    assert result in symbols._CIRCUIT_MAP
    assert (
        Counter(
            segment.kind
            for segment in symbols._CIRCUIT_MAP[result].segments
            if segment.kind != "short"
        )
        == COMPONENTS[case["id"]]
    )
    assert symbols.is_math_glyph(result)
    assert symbols.normalize_text_for_font(result, FONT) == result
    font = ImageFont.truetype(FONT, 52)
    box = symbols._layout_math_text(result, font, FONT)
    left, top, right, bottom = box.bbox
    assert 0 < right - left < 2000
    assert 0 < bottom - top < 2000
    image = Image.new("1", (right - left + 20, bottom - top + 20))
    symbols._paint_math_box(ImageDraw.Draw(image), box, (10 - left, 10 - top))
    ink = image.getbbox()
    assert ink is not None
    assert 0 < ink[0] < ink[2] < image.width
    assert 0 < ink[1] < ink[3] < image.height


@pytest.mark.parametrize(("width", "height"), [(300, 400), (1000, 1200)])
@pytest.mark.parametrize("size", [36, 70])
def test_real_pages_fit_whole_circuit_and_keep_surrounding_text(width, height, size):
    template = Template(
        background=Image.new("RGB", (width, height), "white"),
        font=ImageFont.truetype(FONT, size),
        line_spacing=size * 2,
        left_margin=20,
        right_margin=20,
        top_margin=20,
        bottom_margin=20,
        fill=(0, 0, 0),
        word_spacing=0,
        line_spacing_sigma=0,
        font_size_sigma=0,
        word_spacing_sigma=0,
        perturb_x_sigma=0,
        perturb_y_sigma=0,
        perturb_theta_sigma=0,
    )
    text = symbols.normalize_text_for_font("电路如下\n" + RC + "\n解：Z=R+(1)/(jωC)", FONT)
    assert text.startswith("电路如下\n")
    assert "解：Z=R+" in text
    pages = list(handwrite(text, template))
    assert pages
    for page in pages:
        assert page.size == (width, height)
        assert page.convert("L").point(lambda value: 255 - value).getbbox()


def test_environment_boundaries_ignore_comments_and_code_examples():
    comment = RC.replace("\\draw", "% \\end{circuitikz}\n\\draw", 1)
    normalized = symbols.normalize_text_for_font(comment, FONT)
    assert normalized in symbols._CIRCUIT_MAP
    assert list(circuit_spans("```latex\n" + RC + "\n```")) == []
    assert list(circuit_spans("````latex\n```\n" + RC + "\n````")) == []
    assert list(circuit_spans("`" + RC.replace("\n", " ") + "`")) == []
    assert symbols.normalize_text_for_font("```\n" + RC + "\n```") == "```\n" + RC + "\n```"
    assert list(circuit_spans("\\" + RC)) == []


def test_unknown_topology_never_partially_converts_label_fractions():
    source = RC.replace("to[R", r"to[unknown", 1).replace("$R_1$", r"$\frac{1}{2}$")
    assert symbols.normalize_text_for_font(source, FONT) == source


def test_circuit_registry_budget_keeps_original_source(monkeypatch):
    monkeypatch.setattr(symbols, "_MAX_CIRCUITS", 0)
    source = RC.replace("R_1", "R_{budget}")
    assert symbols.normalize_text_for_font(source, FONT) == source
