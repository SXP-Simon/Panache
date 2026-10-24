# Copyright (c) 2026 Simon and Panache contributors.
"""Verify detected geometry against physical ruling pixels and real handwriting."""

import base64
import io
import json
from pathlib import Path

import app
import numpy as np
import pytest
from identify import ImageIdentificationError, identify_paper
from PIL import Image, ImageDraw, ImageFont
from test_generation_parameters import parameters


def ruled_paper(*, thickness=2, ink=180, angle=0, shade=False, **layout):
    first = layout.get("first", 90)
    spacing = layout.get("spacing", 65)
    size = layout.get("size", (760, 980))
    width, height = size
    image = Image.new("RGB", size, (245, 245, 240))
    draw = ImageDraw.Draw(image)
    if shade:
        for x in range(width):
            level = 205 + round(40 * x / width)
            draw.line((x, 0, x, height), fill=(level, level, level))
    for y in range(first, height - 60, spacing):
        draw.line((55, y, width - 55, y), fill=(ink, ink, ink), width=thickness)
    # 2026-10-24：红色装订竖线不能参与倾角或间距估算。
    draw.line((40, 25, 40, height - 25), fill=(185, 80, 80), width=2)
    return image.rotate(angle, resample=Image.Resampling.BICUBIC, expand=True, fillcolor="white")


def measure(image, tmp_path, name="paper.png"):
    path = tmp_path / name
    image.save(path)
    return identify_paper(str(path))


@pytest.mark.parametrize("thickness", [1, 2, 9, 17])
@pytest.mark.parametrize("ink", [20, 180, 232])
def test_line_centres_ignore_thickness_and_lightness(tmp_path, thickness, ink):
    result = measure(ruled_paper(thickness=thickness, ink=ink), tmp_path)
    assert result.spacing == 65
    assert abs(result.top - 90) <= 1
    assert result.first_baseline == result.top
    assert result.response()["layoutTopMargin"] + result.spacing == result.first_baseline
    assert result.corrected is None
    assert result.width == 760
    assert result.height == 980


@pytest.mark.parametrize("angle", [-8, -3, -0.5, 0.5, 3, 8])
@pytest.mark.parametrize("thickness", [2, 9])
def test_deskew_returns_the_actual_aligned_background_and_is_idempotent(tmp_path, angle, thickness):
    result = measure(ruled_paper(angle=angle, thickness=thickness), tmp_path)
    assert abs(result.angle + angle) < 0.15
    assert result.spacing == 65
    assert result.corrected is not None
    corrected = Image.open(io.BytesIO(base64.b64decode(result.corrected))).convert("RGB")
    assert corrected.size == (result.width, result.height)
    again = measure(corrected, tmp_path, "corrected.png")
    assert again.corrected is None
    assert again.spacing == result.spacing
    assert abs(again.top - result.top) <= 1
    pixels = np.asarray(corrected)
    # 2026-10-24：在实际PNG的左中右三处找横线墨迹，证明返回坐标不是只针对隐藏分析图。
    for x in (result.left + 20, result.width // 2, result.width - result.right - 20):
        column = pixels[result.top - 3 : result.top + 4, x, :3].mean(axis=1)
        assert float(column.min()) < 210
        assert abs(int(np.argmin(column)) - 3) <= thickness // 2 + 1


def test_side_shadow_does_not_become_a_ruling(tmp_path):
    result = measure(ruled_paper(shade=True, ink=185, thickness=3), tmp_path)
    assert result.spacing == 65
    assert abs(result.top - 90) <= 1


def test_first_line_too_close_to_edge_uses_next_baseline(tmp_path):
    result = measure(ruled_paper(first=20), tmp_path)
    assert result.top == 20
    assert result.first_baseline == 85
    assert result.response()["layoutTopMargin"] == 20


def test_small_notebook_uses_scaled_detection_lengths(tmp_path):
    result = measure(ruled_paper(size=(200, 320), first=45, spacing=30), tmp_path)
    assert result.spacing == 30
    assert abs(result.top - 45) <= 1


@pytest.mark.parametrize("kind", ["blank", "gradient", "vertical", "single", "irregular", "tiny"])
def test_non_notebooks_are_rejected_without_guessed_settings(tmp_path, kind):
    image = Image.new("RGB", (760, 980), "white")
    draw = ImageDraw.Draw(image)
    if kind == "gradient":
        image = Image.linear_gradient("L").resize(image.size).convert("RGB")
    elif kind == "vertical":
        for x in range(50, 700, 60):
            draw.line((x, 30, x, 940), fill="gray", width=3)
    elif kind == "single":
        draw.line((50, 200, 700, 200), fill="black", width=20)
    elif kind == "irregular":
        for y in (70, 110, 230, 280, 440, 600, 650, 830):
            draw.line((50, y, 700, y), fill="gray", width=2)
    elif kind == "tiny":
        image = image.resize((20, 20))
    with pytest.raises(ImageIdentificationError):
        measure(image, tmp_path)


def test_upload_response_uses_corrected_dimensions_and_keeps_last_baseline_writable(
    tmp_path, monkeypatch
):
    monkeypatch.chdir(tmp_path)
    (tmp_path / "imagefileprocess").mkdir()
    stream = io.BytesIO()
    ruled_paper(angle=4, thickness=9).save(stream, format="PNG")
    response = app._process_image_upload("paper.png", stream.getvalue())
    assert response.status_code == 200
    data = json.loads(response.body)
    assert data["layoutTopMargin"] + data["lineSpacing"] == data["firstBaseline"]
    assert data["layoutBottomMargin"] < data["marginBottom"]
    assert (
        data["imageHeight"] - data["layoutBottomMargin"]
        > data["imageHeight"] - data["marginBottom"]
    )
    assert base64.b64decode(data["correctedBackground"]).startswith(b"\x89PNG")
    assert list((tmp_path / "imagefileprocess").iterdir()) == []


@pytest.mark.parametrize("source", ["田", r"田 \frac{1}{2}"])
def test_real_render_uses_first_and_last_detected_ruling_on_every_page(tmp_path, source):
    original = ruled_paper(angle=3, thickness=9)
    geometry = measure(original, tmp_path)
    paper = Image.open(io.BytesIO(base64.b64decode(geometry.corrected))).convert("RGB")
    response = geometry.response()
    font_path = Path(__file__).resolve().parents[1] / "font_assets/云烟体.ttf"
    font = ImageFont.truetype(str(font_path), 40)
    values = parameters(
        font_size="40",
        line_spacing=str(geometry.spacing),
        top_margin=str(response["layoutTopMargin"]),
        bottom_margin=str(response["layoutBottomMargin"]),
        left_margin=str(geometry.left),
        right_margin=str(geometry.right),
        background_ruled="true",
        fill="(20, 60, 160, 255)",
    ).model_dump(exclude={"width", "height"}, exclude_none=True)
    template = app._template_for(values, paper, font)
    assert template.ruled_origin == response["layoutTopMargin"]
    count = (geometry.height - geometry.bottom - geometry.first_baseline) // geometry.spacing + 1
    pages = list(
        app.handwrite_with_page_breaks("\n".join([source] * (count + 2)), template, str(font_path))
    )
    assert len(pages) == 2
    bbox = font.getbbox("田")
    expected_top = geometry.first_baseline - font.size + bbox[1]
    for page in pages:
        rgb = np.asarray(page.convert("RGB"))
        # 2026-10-24：只取蓝色手写墨迹，独立于灰色横线验证真实生成页而非模拟排版器。
        ink = (rgb[:, :, 2] > rgb[:, :, 0] + 40) & (rgb[:, :, 0] < 80)
        ink = ink[:, geometry.left : geometry.left + 40]
        ys = np.flatnonzero(np.any(ink, axis=1))
        groups = np.split(ys, np.flatnonzero(np.diff(ys) > 1) + 1)
        assert groups[0][0] == expected_top
        for row in groups:
            assert (int(row[0]) - expected_top) % geometry.spacing == 0
    last = np.asarray(pages[0].convert("RGB"))
    ink = (last[:, :, 2] > last[:, :, 0] + 40) & (last[:, :, 0] < 80)
    rows = np.flatnonzero(np.any(ink[:, geometry.left : geometry.left + 40], axis=1))
    expected_last = expected_top + (count - 1) * geometry.spacing + bbox[3] - bbox[1] - 1
    assert int(rows[-1]) == expected_last


def test_unicode_filename_and_empty_file_are_handled(tmp_path):
    result = measure(ruled_paper(), tmp_path, "作业本背景.png")
    assert result.spacing == 65
    empty = tmp_path / "empty.png"
    empty.write_bytes(b"")
    with pytest.raises(ImageIdentificationError):
        identify_paper(str(empty))
    with pytest.raises(ImageIdentificationError):
        identify_paper(str(tmp_path / "missing.png"))
