# Copyright (c) 2026 HandwritingWeb contributors
"""生成参数、线程调度与实际墨色的回归."""

import asyncio
import base64
import io
import json
import threading
import time
from pathlib import Path
from unittest.mock import patch

import app
import pytest
import task_store
from fastapi.responses import Response
from handright import Template
from PIL import Image
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
        response = asyncio.run(app.generate_handwriting_impl("http://localhost/", parameters()))
    assert response.status_code == 200
    data = json.loads(bytes(response.body))
    with Image.open(io.BytesIO(base64.b64decode(data["images"][0]))) as image:
        colors = set(image.convert("RGB").getdata()) - {(255, 255, 255)}
    assert colors == {(12, 34, 56)}


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
                "http://localhost/",
                parameters(**overrides),
            )
        )
    assert response.status_code == 400


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
        asyncio.run(app.generate_handwriting_impl("http://localhost/", params))
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
            await asyncio.gather(
                app.generate_handwriting_impl("http://localhost/", parameters()), heartbeat()
            )

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
        _base: str,
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
                "http://localhost/",
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
