# Copyright (c) 2026 HandwritingWeb contributors
"""生成参数、线程调度与实际墨色的回归."""

import asyncio
import base64
import inspect
import io
import json
import threading
import time
from functools import partial
from pathlib import Path
from unittest.mock import patch
from zipfile import ZipFile

import app
import fitz
import pytest
import task_store
from fastapi import BackgroundTasks, Request
from fastapi.responses import Response
from handright import Template
from ink_effects import InkEffects, composite
from PIL import Image, ImageDraw
from task_types import GenerateHandwritingParams


def parameters(**overrides: str) -> GenerateHandwritingParams:
    """构建足够渲染短文本的确定性参数."""
    values = {
        "text": "墨 x²",
        "font_size": "32",
        "line_spacing": "50",
        "fill": "(12, 34, 56, 255)",
        "left_margin": "20",
        "right_margin": "20",
        "top_margin": "20",
        "bottom_margin": "20",
        "word_spacing": "0",
        "line_spacing_sigma": "0",
        "font_size_sigma": "0",
        "word_spacing_sigma": "0",
        "perturb_x_sigma": "0",
        "perturb_y_sigma": "0",
        "perturb_theta_sigma": "0",
        "preview": "true",
        "width": "240",
        "height": "240",
        "font_option": app.font_file_names[0],
    }
    values.update(overrides)
    return GenerateHandwritingParams.model_validate(values)


def test_real_png_uses_requested_ink_rgb() -> None:
    """实际 PNG 的非白色像素使用用户选择的颜色，而不是引擎默认黑色."""
    with patch("app.psutil.cpu_percent", return_value=0):
        response = asyncio.run(app.generate_handwriting_impl(parameters()))
    assert response.status_code == 200
    data = json.loads(bytes(response.body))
    with Image.open(io.BytesIO(base64.b64decode(data["images"][0]))) as image:
        colors = set(image.convert("RGB").getdata()) - {(255, 255, 255)}
    assert colors == {(12, 34, 56)}


def test_uploaded_font_preserves_handwriting_in_prose_and_inline_math() -> None:
    name = "华阳手写体.ttf"
    alternate = "霞鹜文楷.ttf"
    assets = Path(__file__).resolve().parents[1] / "font_assets"
    font = (assets / name).read_bytes()
    settings = parameters(
        font_option=name,
        full_preview="true",
        font_size_sigma="2",
        text="简答题：数据预处理（Data Cleaning）\nID3 取值 aᵢ 与 Dᵢ，复杂度 O(n²) 或 O(n³)\n"
        r"根式 \sqrt[3]{x}，分式 \frac{a}{b}，划分聚类 K-means",
        width="900",
        height="480",
    )
    with (
        patch("app.psutil.cpu_percent", return_value=0),
        patch.object(app, "font_assets_dir", str(assets)),
        patch.object(app, "font_file_names", [name, alternate]),
        patch.object(app, "handwrite", partial(app.handwrite, seed=20261116)),
    ):
        built_in = asyncio.run(app.generate_handwriting_impl(settings))
        uploaded = asyncio.run(
            app.generate_handwriting_impl(
                settings.model_copy(update={"font_option": "课堂手写.ttf"}), font_file=font
            )
        )
        different = asyncio.run(
            app.generate_handwriting_impl(settings.model_copy(update={"font_option": alternate}))
        )
    assert built_in.status_code == uploaded.status_code == different.status_code == 200
    expected = json.loads(bytes(built_in.body))["images"]
    assert expected
    assert json.loads(bytes(uploaded.body))["images"] == expected
    assert json.loads(bytes(different.body))["images"] != expected


def test_layered_preview_matches_zip_and_pdf_without_filtering_paper() -> None:
    paper = Image.new("RGB", (240, 240), (235, 222, 197))
    draw = ImageDraw.Draw(paper)
    draw.rectangle((4, 7, 30, 13), fill=(35, 50, 80))
    draw.line((0, 69, 239, 69), fill=(90, 75, 61), width=2)
    source = io.BytesIO()
    paper.save(source, format="PNG")
    raw = source.getvalue()
    settings = parameters(
        ink_layers="true",
        ink_opacity="48",
        ink_thickness="1.4",
        ink_softness="0.3",
        first_line_indent="true",
        monospaced="true",
        latin_font_option="kalam",
        latin_font_scale="115",
        paper_pattern="dots",
        text=r"墨 x² \frac{a}{b}",
        full_preview="false",
        ink_depth_sigma="12",
        perturb_x_sigma="2",
        perturb_y_sigma="2",
    ).model_copy(update={"width": None, "height": None})
    with patch("app.psutil.cpu_percent", return_value=0):
        preview = asyncio.run(app.generate_handwriting_impl(settings, raw))
        zipped = asyncio.run(
            app.generate_handwriting_impl(settings.model_copy(update={"preview": "false"}), raw)
        )
        pdf = asyncio.run(
            app.generate_handwriting_impl(
                settings.model_copy(update={"preview": "false", "pdf_save": "true"}), raw
            )
        )
    assert preview.status_code == zipped.status_code == pdf.status_code == 200
    result = json.loads(bytes(preview.body))
    assert len(result["images"]) == len(result["ink_layers"]) == 1
    with Image.open(io.BytesIO(base64.b64decode(result["images"][0]))) as decoded:
        assert decoded.tobytes() == paper.tobytes()
    with Image.open(io.BytesIO(base64.b64decode(result["ink_layers"][0]))) as mask:
        alpha = mask.getchannel("A")
    assert alpha.getbbox() is not None
    expected = composite(paper, alpha, (12, 34, 56), InkEffects(48, 1.4, 0.3))
    assert expected.tobytes() != paper.tobytes()
    assert expected.getpixel((10, 10)) == paper.getpixel((10, 10))
    with (
        ZipFile(io.BytesIO(bytes(zipped.body))) as archive,
        Image.open(io.BytesIO(archive.read("0.png"))) as png,
    ):
        assert png.convert("RGB").tobytes() == expected.tobytes()
    with fitz.open(stream=bytes(pdf.body), filetype="pdf") as document:
        rendered = document[0].get_pixmap(alpha=False)
        assert rendered.samples == expected.tobytes()


def test_full_preview_reuses_paper_encoding_and_single_preview_matches_first_page() -> None:
    """2026-11-18：四页预览只编码一次复用纸面，单页预览只编码首张纸与墨迹."""
    settings = parameters(ink_layers="true", text="甲\n---\n乙\n---\n丙\n---\n丁")
    with (
        patch("app.psutil.cpu_percent", return_value=0),
        patch.object(app, "_png_bytes", wraps=app._png_bytes) as encode,
    ):
        full = asyncio.run(app.generate_handwriting_impl(settings))
        assert encode.call_count == 5
        encode.reset_mock()
        first = asyncio.run(
            app.generate_handwriting_impl(settings.model_copy(update={"full_preview": "false"}))
        )
        assert encode.call_count == 2
    assert full.status_code == first.status_code == 200
    pages = json.loads(bytes(full.body))
    first_page = json.loads(bytes(first.body))
    assert len(pages["images"]) == len(pages["ink_layers"]) == 4
    assert first_page["images"] == pages["images"][:1]
    assert first_page["ink_layers"] == pages["ink_layers"][:1]


def test_single_page_preview_setting_does_not_truncate_exports() -> None:
    """2026-11-18：预览首页时，PDF 和 ZIP 仍导出全部四页."""
    settings = parameters(
        ink_layers="true",
        text="甲\n---\n乙\n---\n丙\n---\n丁",
        full_preview="false",
        preview="false",
    )
    with patch("app.psutil.cpu_percent", return_value=0):
        zipped = asyncio.run(app.generate_handwriting_impl(settings))
        pdf = asyncio.run(
            app.generate_handwriting_impl(settings.model_copy(update={"pdf_save": "true"}))
        )
    assert zipped.status_code == pdf.status_code == 200
    with ZipFile(io.BytesIO(bytes(zipped.body))) as archive:
        assert archive.namelist() == ["0.png", "1.png", "2.png", "3.png"]
    with fitz.open(stream=bytes(pdf.body), filetype="pdf") as document:
        assert len(document) == 4


@pytest.mark.parametrize(
    "latin_font", ["handlee", "patrick_hand", "indie_flower", "kalam", "shadows_into_light"]
)
def test_independent_latin_font_changes_only_english_line(
    monkeypatch: pytest.MonkeyPatch, latin_font: str
) -> None:
    """2026-11-18：实际渲染验证英文字体独立，且两项并发任务不共享选择."""
    assets = Path(__file__).resolve().parents[1] / "font_assets"
    monkeypatch.setattr(app, "font_assets_bundled_dir", str(assets))
    settings = parameters(
        ink_layers="true",
        font_option="云烟体.ttf",
        text="墨\nCosine Similarity Cosine Similarity\ncos(x,y)=(x·y)/(||x||₂||y||₂)",
        width="1000",
        height="320",
    )

    async def render_both() -> tuple[Response, Response]:
        default = app.generate_handwriting_impl(settings)
        changed = app.generate_handwriting_impl(
            settings.model_copy(update={"latin_font_option": latin_font})
        )
        first, second = await asyncio.gather(default, changed)
        return first, second

    with patch("app.psutil.cpu_percent", return_value=0):
        primary, separate = asyncio.run(render_both())
    assert primary.status_code == separate.status_code == 200
    left = json.loads(bytes(primary.body))["ink_layers"][0]
    right = json.loads(bytes(separate.body))["ink_layers"][0]
    with (
        Image.open(io.BytesIO(base64.b64decode(left))) as before,
        Image.open(io.BytesIO(base64.b64decode(right))) as after,
    ):
        assert before.crop((0, 0, 1000, 75)).tobytes() == after.crop((0, 0, 1000, 75)).tobytes()
        assert before.crop((0, 75, 1000, 130)).tobytes() != after.crop((0, 75, 1000, 130)).tobytes()
        assert (
            before.crop((0, 130, 1000, 320)).tobytes() != after.crop((0, 130, 1000, 320)).tobytes()
        )


def _ink_mask(encoded: str) -> Image.Image:
    with Image.open(io.BytesIO(base64.b64decode(encoded))) as image:
        return image.getchannel("A")


def test_digit_font_switch_changes_digits_without_changing_letters() -> None:
    """2026-11-18：切换数字字体不会让英文字母或中文跟着换字形."""
    settings = parameters(
        ink_layers="true", latin_font_option="kalam", text="墨\n123456\nKalam", width="400"
    )
    with patch("app.psutil.cpu_percent", return_value=0):
        primary = asyncio.run(app.generate_handwriting_impl(settings))
        latin = asyncio.run(
            app.generate_handwriting_impl(settings.model_copy(update={"digit_font": "latin"}))
        )
    assert primary.status_code == latin.status_code == 200
    before = _ink_mask(json.loads(bytes(primary.body))["ink_layers"][0])
    after = _ink_mask(json.loads(bytes(latin.body))["ink_layers"][0])
    assert before.crop((0, 0, 400, 75)).tobytes() == after.crop((0, 0, 400, 75)).tobytes()
    assert before.crop((0, 75, 400, 130)).tobytes() != after.crop((0, 75, 400, 130)).tobytes()
    assert before.crop((0, 130, 400, 240)).tobytes() == after.crop((0, 130, 400, 240)).tobytes()


@pytest.mark.parametrize("digit_font", ["primary", "latin"])
@pytest.mark.parametrize("latin_font", [None, "kalam"])
def test_latin_size_scales_letters_and_only_digits_assigned_to_latin(
    digit_font: str, latin_font: str | None
) -> None:
    """2026-11-18：比例对中文无影响，可缩放主字体的英文及公式内字形."""
    settings = parameters(
        ink_layers="true",
        separate_latin_ink="true",
        digit_font=digit_font,
        text="墨\n1234\nWWW\n(1)/(x)",
        width="400",
        height="360",
        line_spacing="70",
    ).model_copy(update={"latin_font_option": latin_font})

    def render(scale: str) -> tuple[Image.Image, Image.Image]:
        result = asyncio.run(
            app.generate_handwriting_impl(settings.model_copy(update={"latin_font_scale": scale}))
        )
        assert result.status_code == 200
        payload = json.loads(bytes(result.body))
        return _ink_mask(payload["ink_layers"][0]), _ink_mask(payload["latin_ink_layers"][0])

    with patch("app.psutil.cpu_percent", return_value=0):
        primary, latin = render("100")
        resized_primary, resized_latin = render("135")
    assert (
        primary.crop((0, 0, 400, 90)).tobytes() == resized_primary.crop((0, 0, 400, 90)).tobytes()
    )
    digit_row = (0, 90, 400, 160)
    if digit_font == "latin":
        assert latin.crop(digit_row).tobytes() != resized_latin.crop(digit_row).tobytes()
    else:
        assert primary.crop(digit_row).tobytes() == resized_primary.crop(digit_row).tobytes()
    english_row = (0, 160, 400, 230)
    original = latin.crop(english_row).getbbox()
    enlarged = resized_latin.crop(english_row).getbbox()
    assert original is not None
    assert enlarged is not None
    assert enlarged[2] - enlarged[0] > original[2] - original[0]
    assert abs(enlarged[3] - original[3]) <= 2
    formula = (0, 230, 400, 360)
    assert latin.crop(formula).tobytes() != resized_latin.crop(formula).tobytes()


@pytest.mark.parametrize("scale", ["49", "151", "nan", "100.5"])
def test_latin_size_rejects_values_outside_slider_contract(scale: str) -> None:
    """2026-11-18：生成前拒绝越界及非整数比例."""
    with patch("app.psutil.cpu_percent", return_value=0):
        result = asyncio.run(app.generate_handwriting_impl(parameters(latin_font_scale=scale)))
    assert result.status_code == 400


@pytest.mark.parametrize("pattern", ["grid", "dots"])
def test_paper_pattern_respects_margins_and_matches_exports(pattern: str) -> None:
    """2026-11-18：方格和点阵遵循纸张尺寸，预览、ZIP、PDF 复用生成的纸面."""
    settings = parameters(ink_layers="true", paper_pattern=pattern, text="墨 ABC")
    with patch("app.psutil.cpu_percent", return_value=0):
        preview = asyncio.run(app.generate_handwriting_impl(settings))
        zipped = asyncio.run(
            app.generate_handwriting_impl(settings.model_copy(update={"preview": "false"}))
        )
        pdf = asyncio.run(
            app.generate_handwriting_impl(
                settings.model_copy(update={"preview": "false", "pdf_save": "true"})
            )
        )
    assert preview.status_code == zipped.status_code == pdf.status_code == 200
    payload = json.loads(bytes(preview.body))
    blank = (255, 255, 255)
    with Image.open(io.BytesIO(base64.b64decode(payload["images"][0]))) as paper:
        assert paper.size == (240, 240)
        assert paper.getpixel((70, 70)) != blank
        assert paper.getpixel((70, 120)) != blank
        assert (paper.getpixel((45, 70)) != blank) == (pattern == "grid")
        assert (paper.getpixel((70, 95)) != blank) == (pattern == "grid")
        for xy in ((10, 70), (231, 70), (70, 10), (70, 230), (45, 95)):
            assert paper.getpixel(xy) == blank
        mask = _ink_mask(payload["ink_layers"][0])
        expected = composite(paper, mask, (12, 34, 56), InkEffects(100, 0, 0))
    with (
        ZipFile(io.BytesIO(bytes(zipped.body))) as archive,
        Image.open(io.BytesIO(archive.read("0.png"))) as png,
    ):
        assert png.convert("RGB").tobytes() == expected.tobytes()
    with fitz.open(stream=bytes(pdf.body), filetype="pdf") as document:
        assert document[0].get_pixmap(alpha=False).samples == expected.tobytes()


def test_split_ink_layers_keep_paper_and_match_pdf_and_zip() -> None:
    """2026-11-18：普通字与公式中的两种字迹独立合成，三种输出共用滤镜参数."""
    settings = parameters(
        text="墨\n123456\nWWWW\n(1)/(x)",
        width="400",
        height="320",
        ink_layers="true",
        separate_latin_ink="true",
        latin_font_option="kalam",
        digit_font="latin",
        ink_opacity="70",
        ink_thickness="0.5",
        latin_fill="(150, 30, 12, 255)",
        latin_ink_opacity="50",
        latin_ink_thickness="1.2",
        latin_ink_softness="0.7",
    )
    with patch("app.psutil.cpu_percent", return_value=0):
        preview = asyncio.run(app.generate_handwriting_impl(settings))
        exports = settings.model_copy(update={"preview": "false"})
        zipped = asyncio.run(app.generate_handwriting_impl(exports))
        pdf = asyncio.run(
            app.generate_handwriting_impl(exports.model_copy(update={"pdf_save": "true"}))
        )
    assert preview.status_code == zipped.status_code == pdf.status_code == 200
    result = json.loads(bytes(preview.body))
    main = _ink_mask(result["ink_layers"][0])
    latin = _ink_mask(result["latin_ink_layers"][0])
    assert main.crop((0, 0, 400, 90)).getbbox()
    assert latin.crop((0, 0, 400, 90)).getbbox() is None
    assert main.crop((0, 90, 400, 180)).getbbox() is None
    assert latin.crop((0, 90, 400, 180)).getbbox()
    assert main.crop((0, 180, 400, 320)).getbbox()
    assert latin.crop((0, 180, 400, 320)).getbbox()

    with Image.open(io.BytesIO(base64.b64decode(result["images"][0]))) as paper:
        primary = composite(paper, main, (12, 34, 56), InkEffects(70, 0.5, 0))
        expected = composite(primary, latin, (150, 30, 12), InkEffects(50, 1.2, 0.7))
        assert expected.getpixel((3, 3)) == paper.getpixel((3, 3))
    with (
        ZipFile(io.BytesIO(bytes(zipped.body))) as archive,
        Image.open(io.BytesIO(archive.read("0.png"))) as png,
    ):
        assert png.tobytes() == expected.tobytes()
    with fitz.open(stream=bytes(pdf.body), filetype="pdf") as document:
        assert document[0].get_pixmap(alpha=False).samples == expected.tobytes()


@pytest.mark.parametrize(
    "overrides",
    [
        {"line_spacing": "0"},
        {"font_size": "0"},
        {"fill": "not-a-color"},
        {"fill": "(256, 0, 0, 255)"},
        {"line_spacing_sigma": "nan"},
        {"perturb_x_sigma": "-1"},
    ],
)
def test_invalid_generation_parameters_return_400(overrides: dict[str, str]) -> None:
    """非法数值、颜色和零行距不能进入渲染或辅助线循环."""
    with patch("app.psutil.cpu_percent", return_value=0):
        response = asyncio.run(
            app.generate_handwriting_impl(
                parameters(**overrides),
            )
        )
    assert response.status_code == 400


def test_cpu_guard_rejects_before_loading_font(monkeypatch: pytest.MonkeyPatch) -> None:
    """2026-10-15：移除站点专属限制后仍在加载字体前执行部署的 CPU 守卫."""
    monkeypatch.setenv("CPU_USAGE_LIMIT", "95")
    with (
        patch("app.psutil.cpu_percent", return_value=96),
        patch("app._font_for") as load_font,
    ):
        response = asyncio.run(app.generate_handwriting_impl(parameters()))
    assert response.status_code == 429
    assert json.loads(bytes(response.body))["status"] == "waiting"
    load_font.assert_not_called()


@pytest.mark.parametrize(
    ("host", "scheme"),
    [
        ("example.invalid", "https"),
        ("custom.example.invalid", "https"),
        ("local.example.invalid", "http"),
    ],
)
def test_long_text_reaches_renderer_independently_of_request_host(host: str, scheme: str) -> None:
    """2026-10-15：请求域名不参与渲染策略，长文本经实际入队入口完整传到引擎."""
    params = parameters(text="长文本 x²\n" * 2000)
    request = Request(
        {
            "type": "http",
            "method": "POST",
            "path": "/api/generate_handwriting",
            "scheme": scheme,
            "server": (host, 443 if scheme == "https" else 80),
            "headers": [(b"host", host.encode("ascii"))],
            "query_string": b"",
        }
    )
    background = BackgroundTasks()
    rendered: list[Response] = []

    async def execute(_task_id: str, payload: app.GenerationPayload) -> None:
        rendered.append(await app.generate_handwriting_impl(**payload))

    async def scenario() -> Response:
        endpoint = inspect.unwrap(app.generate_handwriting)
        response = await endpoint(
            request=request,
            background_tasks=background,
            params=params,
            background_image=None,
            font_file=None,
        )
        await background()
        return response

    with (
        patch("app.cleanup_expired_generation_tasks"),
        patch("app.get_generation_active_task_count", return_value=0),
        patch("app.set_generation_task"),
        patch("app.create_generation_task", return_value=True),
        patch("app.run_generation_task", side_effect=execute),
        patch("app.psutil.cpu_percent", return_value=0),
        patch(
            "app.handwrite_with_page_breaks",
            return_value=[Image.new("RGB", (240, 240), "white")],
        ) as handwrite,
    ):
        response = asyncio.run(scenario())
    assert response.status_code == 200
    assert json.loads(bytes(response.body))["task_id"]
    assert len(rendered) == 1
    assert rendered[0].status_code == 200
    assert handwrite.call_args.args[0] == params.text


def test_fractional_sigmas_reach_template_without_integer_truncation() -> None:
    """小数扰动值完整传递给手写模板."""
    captured: list[Template] = []

    class TemplateCapturedError(RuntimeError):
        pass

    def capture(*args: object, **kwargs: object) -> Template:
        template = Template(*args, **kwargs)
        captured.append(template)
        raise TemplateCapturedError

    params = parameters(
        line_spacing_sigma="0.25",
        font_size_sigma="0.5",
        word_spacing_sigma="0.75",
        perturb_x_sigma="0.125",
    )
    with (
        patch("app.psutil.cpu_percent", return_value=0),
        patch("app.Template", side_effect=capture),
        pytest.raises(TemplateCapturedError),
    ):
        asyncio.run(app.generate_handwriting_impl(params))
    assert captured[0].get_line_spacing_sigma() == 0.25
    assert captured[0].get_font_size_sigma() == 0.5
    assert captured[0].get_word_spacing_sigma() == 0.75
    assert captured[0].get_perturb_x_sigma() == 0.125


def test_rendering_does_not_block_event_loop() -> None:
    """阻塞渲染期间事件循环仍能响应其他协程."""
    events: list[str] = []
    threads: list[int] = []

    def slow_render(*_args: object) -> Response:
        threads.append(threading.get_ident())
        events.append("render-start")
        time.sleep(0.15)
        events.append("render-end")
        return Response(b"png", media_type="image/png")

    async def heartbeat() -> None:
        await asyncio.sleep(0.03)
        events.append("heartbeat")

    async def scenario() -> None:
        with patch("app._render_handwriting", side_effect=slow_render):
            await asyncio.gather(app.generate_handwriting_impl(parameters()), heartbeat())

    loop_thread = threading.get_ident()
    asyncio.run(scenario())
    assert threads != [loop_thread]
    assert events == ["render-start", "heartbeat", "render-end"]


def test_worker_progress_notifications_are_scheduled_on_event_loop(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """工作线程报告进度时，WebSocket 推送仍在原事件循环中创建任务."""
    monkeypatch.setattr(task_store, "_DB_PATH", tmp_path / "tasks.db")
    monkeypatch.setattr(task_store, "_RESULT_DIR", tmp_path / "results")
    task_store.init()
    notification_threads: list[int] = []
    worker_threads: list[int] = []

    async def notify(_task_id: str) -> None:
        notification_threads.append(threading.get_ident())

    def render(
        _params: GenerateHandwritingParams,
        _background: bytes | None,
        _font: bytes | None,
        hook: app.ProgressHook | None,
    ) -> Response:
        worker_threads.append(threading.get_ident())
        assert hook is not None
        hook(stage="rendering", message="working", progress=45)
        return Response(b"png", media_type="image/png")

    async def scenario() -> None:
        with (
            patch("app._render_handwriting", side_effect=render),
            patch("app.push_task_status_update", side_effect=notify),
        ):
            await app.run_generation_task(
                "worker-task",
                {
                    "params": parameters(),
                    "background_image": None,
                    "font_file": None,
                },
            )
            await asyncio.sleep(0)
            if app._notification_tasks:
                await asyncio.gather(*app._notification_tasks)

    loop_thread = threading.get_ident()
    asyncio.run(scenario())
    assert worker_threads != [loop_thread]
    assert notification_threads
    assert set(notification_threads) == {loop_thread}
    task = task_store.get_task("worker-task")
    assert task is not None
    assert task["status"] == "completed"
