# Copyright (c) 2026 Simon and Panache contributors.
"""2026-11-18：局部修改的身份、纸面与导出回归."""

import asyncio
import base64
import io
import json
from unittest.mock import patch
from zipfile import ZipFile

import app
import fitz
import requests
from fine_edit import MAX_FINE_EDITS_BYTES, parse_edits
from PIL import Image
from test_generation_cancellation import request
from test_generation_parameters import parameters


def render(**values):
    with patch("app.psutil.cpu_percent", return_value=0):
        response = asyncio.run(
            app.generate_handwriting_impl(
                parameters(
                    **{
                        "fine_edit": "true",
                        "ink_layers": "true",
                        "text": "墨墨墨\n---\n墨墨",
                        **values,
                    }
                )
            )
        )
    assert response.status_code == 200, response.body
    return bytes(response.body)


def unzip(data):
    with ZipFile(io.BytesIO(data)) as archive:
        return [
            Image.open(io.BytesIO(archive.read(name))).convert("RGB") for name in archive.namelist()
        ]


def test_repeated_glyphs_are_independent_and_pdf_contains_the_zip_pixels():
    preview = json.loads(render(isUnderlined="true"))
    fine = preview["fine_edit"]
    first, second = [page["glyphs"] for page in fine["pages"]]
    assert [item[0] for item in first] == [0, 1, 2]
    assert [item[0] for item in second] == [8, 9]
    assert fine["pages"][1]["source_ranges"] == [[8, 9], [9, 10]]
    first_id, x, y, w, h, *_ = first[0]
    edit = json.dumps(
        {
            "key": fine["key"],
            "glyphs": [
                {
                    "id": first_id,
                    "dx": 120,
                    "dy": 90,
                    "scale": 150,
                    "angle": 22,
                    "opacity": 70,
                    "color": "#be2020",
                    "thickness": 7,
                    "softness": 4,
                }
            ],
        }
    )
    original = unzip(render(preview="false", isUnderlined="true"))
    edited = unzip(render(preview="false", fine_edits=edit, isUnderlined="true"))
    with Image.open(io.BytesIO(base64.b64decode(preview["images"][0]))) as paper:
        assert (
            original[0].crop((x, y, x + w, y + h)).tobytes()
            != paper.crop((x, y, x + w, y + h)).tobytes()
        )
        assert (
            edited[0].crop((x, y, x + w, y + h)).tobytes()
            == paper.crop((x, y, x + w, y + h)).tobytes()
        )
        assert (
            edited[0].crop((100, 0, 220, 30)).tobytes() == paper.crop((100, 0, 220, 30)).tobytes()
        )
    assert original[1].tobytes() == edited[1].tobytes()
    assert any(red > green and red > blue for red, green, blue in edited[0].getdata())
    with fitz.open(
        stream=render(preview="false", pdf_save="true", fine_edits=edit, isUnderlined="true"),
        filetype="pdf",
    ) as pdf:
        for index, page in enumerate(pdf):
            ref = page.get_images()[0][0]
            embedded = pdf.extract_image(ref)["image"]
            with Image.open(io.BytesIO(embedded)) as image:
                assert image.convert("RGB").tobytes() == edited[index].tobytes()


def test_stale_adjustments_cannot_apply_to_new_text_and_formula_is_one_item():
    source = r"左 \frac{1}{2} 右"
    fine = json.loads(render(text=source))["fine_edit"]
    assert len(fine["pages"][0]["glyphs"]) == 3
    assert "source_ranges" not in fine["pages"][0]
    edits = json.dumps({"key": fine["key"], "glyphs": [{"id": 0, "color": "#ff0000"}]})
    changed = unzip(render(text="新", preview="false", fine_edits=edits))[0]
    unedited = unzip(render(text="新", preview="false"))[0]
    assert changed.tobytes() == unedited.tobytes()


def test_inline_image_preserves_glyphs_on_both_sides_without_id_collisions():
    diagram = Image.new("RGB", (40, 16), "white")
    diagram.paste((0, 0, 0), (3, 4, 33, 9))
    with io.BytesIO() as buffer:
        diagram.save(buffer, format="PNG")
        encoded = base64.b64encode(buffer.getvalue()).decode()
    source = f"甲\n![line](data:image/png;base64,{encoded})\n乙"
    preview = json.loads(render(text=source, height="440"))
    [page] = preview["fine_edit"]["pages"]
    assert [item[0] for item in page["glyphs"]] == [0, len(source) - 1]
    assert page["glyphs"][1][2] > page["glyphs"][0][2]


def test_multipart_export_accepts_large_perspective_edits():
    # 2026-11-19：跨页字迹调整大小超过默认的 1 MiB 文本字段限制。
    warp = [
        1.00123456789,
        0.0123456789,
        0.1,
        0.0123456789,
        1,
        0.1,
        0.0000123456789,
        0.0000123456789,
    ]
    count = 10_000
    edits = json.dumps({"key": "0" * 64, "glyphs": [{"id": i, "warp": warp} for i in range(count)]})
    assert 1024 * 1024 < len(edits) <= MAX_FINE_EDITS_BYTES
    fields = parameters(fine_edit="true", preview="false").model_dump(exclude_none=True)

    async def submit(data: bytes):
        path = "/api/generate_handwriting"
        form = requests.Request(
            "POST",
            f"http://localhost{path}",
            data=fields,
            files={"fine_edits_file": ("fine-edits.json", data, "application/json")},
        ).prepare()
        headers = [(key.lower().encode(), value.encode()) for key, value in form.headers.items()]
        return await request("POST", path, body=form.body, headers=headers)

    with (
        patch("app.cleanup_expired_generation_tasks"),
        patch("app.get_generation_active_task_count", return_value=0),
        patch("app.create_generation_task", return_value=True),
        patch("app.run_generation_task") as run,
    ):
        status, response = asyncio.run(submit(edits.encode()))
        too_large, _ = asyncio.run(submit(b"x" * (MAX_FINE_EDITS_BYTES + 1)))
    assert status == 200, response
    assert too_large == 413
    run.assert_called_once()
    parsed = parse_edits(run.call_args.args[1]["params"].fine_edits)
    assert parsed is not None
    assert len(parsed.glyphs) == count


def test_plain_source_offsets_use_browser_utf16_units():
    assert app._fine_source_positions("甲𠀀乙", "甲𠀀乙") == [(0, 1), (1, 3), (3, 4)]
