# Copyright (c) 2026 Simon and Panache contributors.
"""2026-10-24：作业笔记的原文完整性、正文版心与真实分页回归."""

import base64
import io
from itertools import pairwise
from pathlib import Path

import app
import math_page_layout
import numpy as np
import pytest
from generation_cancellation import GenerationCancelledError
from handright import Template
from homework_layout import inset_homework_body, paragraph_style, preferred_break
from math_page_layout import HomeworkTemplate
from PIL import Image, ImageFont
from pydantic import ValidationError
from test_generation_parameters import parameters
from test_math_page_layout import Font, draft, occupied_runs, synthetic_core
from test_paper_alignment import measure, ruled_paper


def homework_template(size=(400, 580), **options):
    settings = {
        "background": Image.new("RGB", size, "white"),
        "font": Font(),
        "line_spacing": 34,
        "left_margin": 10,
        "right_margin": 10,
        "top_margin": 12,
        "bottom_margin": 12,
        "word_spacing": 0,
        "font_size_sigma": 0,
        "word_spacing_sigma": 0,
        "line_spacing_sigma": 0,
        "perturb_x_sigma": 0,
        "perturb_y_sigma": 0,
        "perturb_theta_sigma": 0,
        "strikethrough_probability": 0,
    }
    settings.update(options)
    template = HomeworkTemplate(**settings)
    template.ruled_origin = settings["top_margin"]
    inset_homework_body(template)
    return template


def test_homework_style_is_explicit_and_standard_remains_default():
    assert parameters().layout_style == "standard"
    assert parameters(layout_style="homework").layout_style == "homework"
    with pytest.raises(ValidationError):
        parameters(layout_style="unknown")


@pytest.mark.parametrize("size", [(1200, 1697), (200, 280), (72, 100)])
def test_body_padding_preserves_paper_pixels_and_safe_writing_area(size):
    template = homework_template(size)
    assert template.get_background().getextrema() == ((255, 255),) * 3
    assert template.ruled_origin == 12
    assert template.get_left_margin() >= 10
    assert template.get_right_margin() >= 10
    assert size[0] - template.get_left_margin() - template.get_right_margin() > 0
    assert size[1] - template.get_top_margin() - template.get_bottom_margin() > 0
    assert (template.get_top_margin() - template.ruled_origin) % 34 == 0


@pytest.mark.parametrize("marker", ["1. ", "1、", "一、", "(1) ", "（一）", "a) ", "• "])
def test_wrapped_items_hang_after_the_marker(marker):
    text = marker + "正文内容需要自然续行"
    first = paragraph_style(text, 0, 500, 30, lambda value: len(value) * 12)
    second = paragraph_style(text, len(marker) + 3, 500, 30, lambda value: len(value) * 12)
    assert second.indent == first.indent + len(marker) * 12


def test_explicit_continuation_keeps_indent_but_new_heading_and_blank_line_reset_it():
    text = "(1) 条目\n接续解释\n第二题：数值积分\n独立正文\n\n另一段"

    def measure_width(value):
        return len(value) * 12

    assert paragraph_style(text, text.index("接续"), 500, 30, measure_width).indent == 78
    assert paragraph_style(text, text.index("第二题"), 500, 30, measure_width).indent == 0
    assert paragraph_style(text, text.index("独立"), 500, 30, measure_width).indent == 0
    assert paragraph_style(text, text.index("另一段"), 500, 30, measure_width).indent == 0


@pytest.mark.parametrize(
    "source", ["3.5 m/s", "0.25 = 1/4", "(x) = x²", "(1) + (2) = 3", "（A） ⇒ B"]
)
def test_decimal_values_and_parenthesized_equations_are_not_item_markers(source):
    style = paragraph_style(source, 0, 500, 30, lambda value: len(value) * 12)
    assert style.indent == 0
    assert not style.separate


def test_short_numbered_items_do_not_add_a_blank_between_every_row():
    template = homework_template()
    pages, consumed = draft(synthetic_core(), "1. A\n2. B\n3. C\n4. D", template)
    rows = occupied_runs(pages[0], "y")
    assert len(rows) == 4
    assert [row[0] - rows[0][0] for row in rows] == [0, 34, 68, 102]
    assert consumed[-1][1] == len("1. A\n2. B\n3. C\n4. D")


def test_extended_question_separates_next_question_by_one_grid_row():
    template = homework_template()
    text = "1. A\nB\nC\n2. D"
    pages, _ = draft(synthetic_core(), text, template)
    rows = occupied_runs(pages[0], "y")
    assert [row[0] - rows[0][0] for row in rows] == [0, 34, 68, 136]


@pytest.mark.parametrize(
    "source",
    [
        "1. ABCDEF，GHIJKL，MNOPQRSTUV" * 15,
        "第二题\n(1) AAAAA(BBBBB+CCCCC)=DDDDD+EEEEE\n" * 12,
        "A" * 300,
        "1. § = AAAA + §\n2. BBBB §\n" * 20,
        "\n\n1. A\n\n\n(1) B\n第二题\nC\n",
    ],
)
def test_long_documents_paginate_without_losing_characters_or_grid_phase(source):
    template = homework_template(size=(180, 240))
    pages, consumed = draft(synthetic_core(), source, template)
    assert consumed[0][0] == 0
    assert consumed[-1][1] == len(source)
    assert all(previous[1] == following[0] for previous, following in pairwise(consumed))
    for page in pages:
        if page.getbbox() is None:
            continue
        left, top, right, bottom = page.getbbox()
        assert left >= template.get_left_margin()
        assert right <= page.width - template.get_right_margin()
        assert top >= template.get_top_margin()
        assert bottom <= page.height - template.get_bottom_margin()


def test_wrap_chooses_sentence_or_relation_boundary_before_full_width():
    template = homework_template(size=(220, 300))
    source = "AAAA，BBBBBBBB=CCCCCC"
    pages, consumed = draft(synthetic_core(), source, template)
    rows = occupied_runs(pages[0], "y")
    assert len(rows) >= 2
    first = pages[0].crop((0, rows[0][0], pages[0].width, rows[0][-1] + 1))
    assert first.getbbox()[2] - first.getbbox()[0] == 5 * 14 - 2
    assert consumed[-1][1] == len(source)


def test_relation_keeps_its_right_hand_group_when_wrapping():
    source = "AAAAAA ⇒ (BBBBB)"
    assert preferred_break(source, source.index("⇒"), 0)
    assert not preferred_break(source, source.index("⇒") + 1, 0)
    assert not preferred_break(source, source.index("("), 0)
    pages, _ = draft(synthetic_core(), source, homework_template(size=(220, 300)))
    rows = occupied_runs(pages[0], "y")
    first = pages[0].crop((0, rows[0][0], pages[0].width, rows[0][-1] + 1))
    assert first.getbbox()[2] - first.getbbox()[0] == 6 * 14 - 2


def test_default_template_type_and_margins_are_unchanged():
    values = parameters().model_dump(exclude_none=True)
    font = ImageFont.truetype(
        str(Path(__file__).resolve().parents[1] / "font_assets/云烟体.ttf"), 32
    )
    template = app._template_for(values, Image.new("RGB", (240, 240)), font)
    assert type(template) is Template
    assert template.get_top_margin() == 20
    assert template.get_left_margin() == 20


def test_homework_layout_stops_inside_a_long_paragraph(monkeypatch):
    checks = 0

    def cancel():
        nonlocal checks
        checks += 1
        if checks == 10:
            raise GenerationCancelledError

    monkeypatch.setattr(math_page_layout, "check_cancelled", cancel)
    with pytest.raises(GenerationCancelledError):
        draft(synthetic_core(), "长段落" * 1000, homework_template())
    assert checks == 10


def test_real_homework_on_deskewed_background_keeps_first_and_later_pages_on_grid(tmp_path):
    geometry = measure(ruled_paper(angle=4, thickness=3), tmp_path)
    paper = Image.open(io.BytesIO(base64.b64decode(geometry.corrected))).convert("RGB")
    margins = geometry.response()
    font_path = Path(__file__).resolve().parents[1] / "font_assets/云烟体.ttf"
    font = ImageFont.truetype(str(font_path), 40)
    values = parameters(
        layout_style="homework",
        background_ruled="true",
        font_size="40",
        line_spacing=str(geometry.spacing),
        top_margin=str(margins["layoutTopMargin"]),
        bottom_margin=str(margins["layoutBottomMargin"]),
        left_margin=str(geometry.left),
        right_margin=str(geometry.right),
        fill="(20, 60, 160, 255)",
    ).model_dump(exclude={"width", "height"}, exclude_none=True)
    template = app._template_for(values, paper, font)
    original = paper.tobytes()
    pages = list(
        app.handwrite_with_page_breaks(
            "\n".join([r"田 \frac{1}{2}"] * 30), template, str(font_path)
        )
    )
    assert len(pages) >= 3
    assert paper.tobytes() == original
    first_top = geometry.first_baseline + geometry.spacing - font.size + font.getbbox("田")[1]
    for page in pages:
        rgb = np.asarray(page.convert("RGB"))
        ink = (rgb[:, :, 2] > rgb[:, :, 0] + 40) & (rgb[:, :, 0] < 80)
        column = ink[:, template.get_left_margin() : template.get_left_margin() + 40]
        ys = np.flatnonzero(np.any(column, axis=1))
        groups = np.split(ys, np.flatnonzero(np.diff(ys) > 1) + 1)
        assert groups[0][0] == first_top
        assert all((int(group[0]) - first_top) % geometry.spacing == 0 for group in groups)


@pytest.mark.parametrize(
    "source",
    [
        r"\begin{array}{|c|c|} A&B\\1&2\end{array}",
        r"\begin{circuitikz}\draw (0,0) to[R,l=$R$] (3,0);\end{circuitikz}",
        "image",
    ],
)
def test_structured_content_and_following_text_stay_inside_homework_body(source):
    font_path = Path(__file__).resolve().parents[1] / "font_assets/云烟体.ttf"
    font = ImageFont.truetype(str(font_path), 28)
    values = parameters(
        layout_style="homework", font_size="28", line_spacing="46", isUnderlined="true"
    ).model_dump(exclude_none=True)
    paper = Image.new("RGB", (460, 640), "white")
    template = app._template_for(values, paper, font)
    if source == "image":
        stream = io.BytesIO()
        Image.new("RGB", (80, 50), (20, 60, 160)).save(stream, format="PNG")
        source = (
            "![图](data:image/png;base64,"
            + base64.b64encode(stream.getvalue()).decode("ascii")
            + ")"
        )
    text = "第一题\n正文\n" + source + "\n后续文字保持横线相位\n第二题\n结论"
    pages = list(app.handwrite_with_page_breaks(text, template, str(font_path)))
    assert pages
    for page in pages:
        rgb = np.asarray(page.convert("RGB"))
        ink = np.any(rgb < 180, axis=2)
        ys, xs = np.nonzero(ink)
        assert xs.min() >= template.get_left_margin()
        assert xs.max() < page.width - template.get_right_margin()
        assert ys.min() >= template.get_top_margin()
        assert ys.max() < page.height - template.get_bottom_margin()
