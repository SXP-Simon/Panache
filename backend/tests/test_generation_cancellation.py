# Copyright (c) 2026 Simon and Panache contributors.
"""2026-10-24：真实渲染、导出清理与取消/完成竞争的回归。."""

import asyncio
import json
import os
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.parse import urlencode
from uuid import uuid4

import app
import circuit_layout
import generation_cancellation as cancellation
import pdf
import pytest
import symbol_fallback
import task_store
from fastapi.responses import Response
from PIL import Image
from test_generation_parameters import parameters


@pytest.fixture(autouse=True)
def isolated_tasks(tmp_path, monkeypatch):
    monkeypatch.setattr(task_store, "_DB_PATH", tmp_path / "tasks.db")
    monkeypatch.setattr(task_store, "_RESULT_DIR", tmp_path / "results")
    task_store.init()
    monkeypatch.setattr(app, "_generation_semaphore", asyncio.Semaphore(1))
    monkeypatch.setattr(app.psutil, "cpu_percent", lambda **_kwargs: 0)


def payload(**changes):
    return {"params": parameters(**changes), "background_image": None, "font_file": None}


def status(task_id):
    result = task_store.get_task(task_id)
    assert result is not None
    return result["status"]


async def wait_until(event):
    assert await asyncio.to_thread(event.wait, 5)


async def request(method, path, *, body=b"", headers=()):
    messages = []
    delivered = False
    never = asyncio.Event()

    async def receive():
        nonlocal delivered
        if delivered:
            await never.wait()
        delivered = True
        return {"type": "http.request", "body": body, "more_body": False}

    async def send(message):
        messages.append(message)

    scope = {
        "type": "http",
        "asgi": {"version": "3.0"},
        "http_version": "1.1",
        "method": method,
        "scheme": "http",
        "path": path,
        "raw_path": path.encode(),
        "root_path": "",
        "query_string": b"",
        "server": ("localhost", 80),
        "client": ("localhost", 0),
        "headers": list(headers),
    }
    await app.app(scope, receive, send)
    status_code = next(
        message["status"] for message in messages if message["type"] == "http.response.start"
    )
    body = b"".join(message.get("body", b"") for message in messages)
    return status_code, body


def test_http_cancel_is_idempotent_and_does_not_destroy_completed_results():
    task_store.set_task("queued", status="pending")
    task_store.set_task("running", status="processing")
    task_store.set_task("done", status="completed", response_body=b"png")

    async def scenario():
        _, body = await request("GET", "/api/version")
        assert json.loads(body)["capabilities"]["task_cancellation"] is True
        code, _ = await request("POST", "/api/generate_handwriting/task/missing/cancel")
        assert code == 404
        for task_id, expected in (
            ("queued", "cancelled"),
            ("running", "cancelling"),
            ("done", "completed"),
        ):
            for _ in range(2):
                code, body = await request(
                    "POST", f"/api/generate_handwriting/task/{task_id}/cancel"
                )
                assert code == 200
                assert json.loads(body)["task_status"] == expected
        for task_id in ("queued", "running"):
            code, body = await request("GET", f"/api/generate_handwriting/task/{task_id}/result")
            assert code == 409
            assert json.loads(body)["status"] == status(task_id)
        _, body = await request("GET", "/api/generate_handwriting/task/done/result")
        assert body == b"png"

    asyncio.run(scenario())
    assert task_store.get_active_task_count() == 1
    assert task_store.get_queue_metrics("running")["processing_count"] == 1


def test_queued_cancel_never_starts_worker_and_next_task_can_run(monkeypatch):
    rendered = []

    def render(params, *_args):
        rendered.append(params.text)
        return Response(b"png")

    monkeypatch.setattr(app, "_render_handwriting", render)

    async def scenario():
        await app._generation_semaphore.acquire()
        task_store.set_task("queued", status="pending")
        job = asyncio.create_task(app.run_generation_task("queued", payload()))
        await asyncio.sleep(0.02)
        assert status("queued") == "pending"
        task_store.request_cancellation("queued")
        await asyncio.wait_for(job, 1)
        assert status("queued") == "cancelled"
        assert rendered == []
        app._generation_semaphore.release()
        await app.run_generation_task("next", payload(text="second"))
        assert status("next") == "completed"
        assert rendered == ["second"]

    asyncio.run(scenario())


@pytest.mark.parametrize("cancel_coroutine", [False, True])
def test_running_cancel_waits_for_thread_exit_before_releasing_slot(monkeypatch, cancel_coroutine):
    entered, release, exited = threading.Event(), threading.Event(), threading.Event()
    renders = []

    def render(params, *_args):
        renders.append(params.text)
        if params.text == "first":
            entered.set()
            assert release.wait(3)
            try:
                cancellation.check_cancelled(force=True)
            finally:
                exited.set()
        return Response(params.text.encode())

    monkeypatch.setattr(app, "_render_handwriting", render)

    async def scenario():
        first = asyncio.create_task(app.run_generation_task("first", payload(text="first")))
        await wait_until(entered)
        if cancel_coroutine:
            first.cancel()
            await asyncio.sleep(0.02)
        else:
            task_store.request_cancellation("first")
        assert status("first") == "cancelling"
        task_store.set_task("second", status="pending")
        second = asyncio.create_task(app.run_generation_task("second", payload(text="second")))
        await asyncio.sleep(0.03)
        assert not first.done()
        assert not exited.is_set()
        assert status("second") == "pending"
        assert task_store.get_active_task_count() == 2
        release.set()
        await asyncio.gather(first, second)
        assert exited.is_set()
        assert status("first") == "cancelled"
        assert status("second") == "completed"
        assert renders == ["first", "second"]
        assert not (task_store._RESULT_DIR / "first").exists()

    try:
        asyncio.run(scenario())
    finally:
        release.set()


@pytest.mark.parametrize("stage", ["rendering", "png", "zip", "pdf"])
def test_real_pipeline_cancel_stops_work_and_removes_temporary_exports(
    stage, monkeypatch, tmp_path
):
    original_png = app._png_bytes
    original_zip = app._zip_response
    original_pdf = app._pdf_response
    original_font = app.get_cached_image_font
    check_count = 0
    triggered = threading.Event()
    old_check = cancellation.CancellationProbe.check

    def check(self, *, force=False):
        nonlocal check_count
        check_count += 1
        if stage == "rendering" and check_count == 300:
            task_store.request_cancellation(self.task_id)
            triggered.set()
            force = True
        return old_check(self, force=force)

    def stop_then(callback, *args, **kwargs):
        task_store.request_cancellation("actual")
        triggered.set()
        return callback(*args, **kwargs)

    monkeypatch.setattr(cancellation.CancellationProbe, "check", check)
    monkeypatch.setattr(
        app,
        "_png_bytes",
        lambda image: stop_then(original_png, image) if stage == "png" else original_png(image),
    )
    monkeypatch.setattr(
        app,
        "_zip_response",
        lambda *args: stop_then(original_zip, *args) if stage == "zip" else original_zip(*args),
    )
    monkeypatch.setattr(
        app,
        "_pdf_response",
        lambda *args: stop_then(original_pdf, *args) if stage == "pdf" else original_pdf(*args),
    )
    # 2026-10-24：字体路径在切换临时工作目录前固定，导出文件只留在测试目录内。
    font_path = str(Path(app.font_assets_dir, app.font_file_names[0]).resolve())
    monkeypatch.setattr(
        app, "get_cached_image_font", lambda _path, size: original_font(font_path, size)
    )
    monkeypatch.chdir(tmp_path)
    options = {"text": "真实取消测试和公式 x² " * 200}
    if stage == "zip":
        options["preview"] = "false"
    if stage == "pdf":
        options["pdf_save"] = "true"
    asyncio.run(app.run_generation_task("actual", payload(**options)))
    assert triggered.is_set()
    assert status("actual") == "cancelled"
    assert not list((tmp_path / "temp").rglob("*"))
    assert not (task_store._RESULT_DIR / "actual").exists()
    assert task_store.get_active_task_count() == 0


def test_pdf_cancellation_during_final_save_removes_partial_pdf(monkeypatch, tmp_path):
    monkeypatch.chdir(tmp_path)
    task_store.set_task("pdf", status="processing")
    token = cancellation.active_probe.set(cancellation.CancellationProbe("pdf"))
    original_save = pdf.fitz.Document.save

    def save(document, *args, **kwargs):
        result = original_save(document, *args, **kwargs)
        task_store.request_cancellation("pdf")
        return result

    monkeypatch.setattr(pdf.fitz.Document, "save", save)
    try:
        with pytest.raises(cancellation.GenerationCancelledError):
            pdf.generate_pdf([Image.new("RGB", (32, 32), "white")])
    finally:
        cancellation.active_probe.reset(token)
    assert list((tmp_path / "temp").iterdir()) == []


def test_cancel_wins_atomic_completion_and_rejects_late_progress():
    task_store.set_task("race", status="processing")
    task_store.request_cancellation("race")
    unchanged = task_store.set_task(
        "race", expected_status=("processing",), stage="rendering", progress=99
    )
    assert unchanged["stage"] == "cancelling"
    task_store.set_task(
        "race", expected_status=("processing",), status="completed", response_body=b"late"
    )
    assert status("race") == "cancelling"
    assert not (task_store._RESULT_DIR / "race").exists()


def test_completion_and_cancellation_race_has_one_consistent_winner():
    def finish(task_id):
        return task_store.set_task(
            task_id, expected_status=("processing",), status="completed", response_body=b"finished"
        )

    with ThreadPoolExecutor(2) as pool:
        for index in range(20):
            task_id = f"race-{index}"
            task_store.set_task(task_id, status="processing")
            futures = [
                pool.submit(finish, task_id),
                pool.submit(task_store.request_cancellation, task_id),
            ]
            for future in futures:
                future.result()
            final = status(task_id)
            assert final in ("completed", "cancelling")
            assert (task_store._RESULT_DIR / task_id / "result.bin").exists() == (
                final == "completed"
            )


def test_worker_heartbeat_preserves_active_tasks_but_ttl_reclaims_abandoned_work():
    for state in ("pending", "processing", "cancelling", "cancelled", "completed"):
        task_store.set_task(state, status=state, updated_at=time.time() - 3600)
    cancellation.CancellationProbe("processing").check()
    cancellation.CancellationProbe("pending").check()
    task_store.cleanup_expired()
    for state in ("pending", "processing"):
        assert task_store.get_task(state) is not None
    for state in ("cancelling", "cancelled", "completed"):
        assert task_store.get_task(state) is None


@pytest.mark.parametrize("location", ["pixels", "table", "circuit"])
def test_real_rendering_checks_inside_final_ink_and_compound_layout(location, monkeypatch):
    calls = 0
    triggered = False

    def cancel():
        nonlocal calls, triggered
        calls += 1
        if calls == 2:
            task_store.request_cancellation("geometry")
            probe = cancellation.active_probe.get()
            assert probe is not None
            probe.next_read = 0
            triggered = True

    original_pixel = cancellation._CheckedBitmap.__getitem__
    original_math = symbol_fallback._paint_math_box
    original_circuit = circuit_layout.check_cancelled

    def pixel(instance, position):
        cancel()
        return original_pixel(instance, position)

    def math_box(*args):
        cancel()
        return original_math(*args)

    def circuit_check():
        cancel()
        return original_circuit()

    if location == "pixels":
        monkeypatch.setattr(cancellation._CheckedBitmap, "__getitem__", pixel)
        source = "真实墨迹取消检查" * 30
    elif location == "table":
        monkeypatch.setattr(symbol_fallback, "_paint_math_box", math_box)
        source = "⟦ A | B ; ── ; (1)/(2) | √(3) ⟧"
    else:
        monkeypatch.setattr(circuit_layout, "check_cancelled", circuit_check)
        source = r"\begin{circuitikz}\draw (0,0) to[R,l=$R_1$] (3,0) to[C] (3,2);\end{circuitikz}"
    asyncio.run(app.run_generation_task("geometry", payload(text=source)))
    assert triggered
    assert status("geometry") == "cancelled"
    assert calls <= 4100
    assert not (task_store._RESULT_DIR / "geometry").exists()


def test_zip_cancel_during_compression_removes_pages_and_partial_archive(monkeypatch, tmp_path):
    original = app.ZipFile.open
    monkeypatch.chdir(tmp_path)
    task_store.set_task("zip", status="processing")
    token = cancellation.active_probe.set(cancellation.CancellationProbe("zip"))

    def open_member(archive, name, mode="r", **kwargs):
        result = original(archive, name, mode, **kwargs)
        if mode == "w":
            task_store.request_cancellation("zip")
            cancellation.active_probe.get().next_read = 0
        return result

    monkeypatch.setattr(app.ZipFile, "open", open_member)
    try:
        with pytest.raises(cancellation.GenerationCancelledError):
            app._zip_response([Image.new("RGB", (100, 100), "white")], lambda *_args: None)
    finally:
        cancellation.active_probe.reset(token)
    assert list((tmp_path / "temp").iterdir()) == []


async def submit(task_id):
    data = {key: value for key, value in parameters().model_dump().items() if value is not None}
    return await request(
        "POST",
        "/api/generate_handwriting",
        body=urlencode(data).encode(),
        headers=(
            (b"content-type", b"application/x-www-form-urlencoded"),
            (b"x-panache-task-id", task_id.encode()),
        ),
    )


def test_cancel_before_registration_and_late_duplicate_submit_never_render(monkeypatch):
    task_id = str(uuid4())
    rendered = []
    monkeypatch.setattr(app, "_render_handwriting", lambda *_args: rendered.append(True))

    async def scenario():
        code, body = await request("POST", f"/api/generate_handwriting/task/{task_id}/cancel")
        assert code == 200
        assert json.loads(body)["task_status"] == "cancelled"
        for _ in range(2):
            code, body = await submit(task_id)
            assert code == 200
            assert json.loads(body)["task_id"] == task_id
        assert status(task_id) == "cancelled"
        assert task_store.get_active_task_count() == 0

    asyncio.run(scenario())
    assert rendered == []


def test_simultaneous_duplicate_submissions_start_only_one_worker(monkeypatch):
    task_id = str(uuid4())
    rendered = []

    def render(*_args):
        rendered.append(True)
        time.sleep(0.03)
        return Response(b"result")

    monkeypatch.setattr(app, "_render_handwriting", render)

    async def scenario():
        results = await asyncio.gather(submit(task_id), submit(task_id))
        for code, body in results:
            assert code == 200
            assert json.loads(body)["task_id"] == task_id
        assert status(task_id) == "completed"
        await submit(task_id)

    asyncio.run(scenario())
    assert rendered == [True]


@pytest.mark.parametrize("task_id", ["../../unsafe", "not-a-uuid", "x" * 128])
def test_submit_rejects_noncanonical_or_unsafe_client_task_ids(task_id):
    code, _ = asyncio.run(submit(task_id))
    assert code == 400
    assert task_store.get_active_task_count() == 0


def test_cancellation_from_another_process_reaches_running_thread(monkeypatch, tmp_path):
    started = threading.Event()
    exited = threading.Event()

    def render(*_args):
        started.set()
        try:
            while True:
                cancellation.check_cancelled()
                time.sleep(0.005)
        finally:
            exited.set()

    monkeypatch.setattr(app, "_render_handwriting", render)
    environment = {
        **os.environ,
        "HANDWRITING_DATA_DIR": str(tmp_path),
        "PYTHONPATH": str(Path(app.__file__).parent),
    }

    async def scenario():
        job = asyncio.create_task(app.run_generation_task("cross-process", payload()))
        await wait_until(started)
        try:
            process = await asyncio.to_thread(
                subprocess.run,
                [
                    sys.executable,
                    "-c",
                    (
                        "from task_store import request_cancellation; "
                        "request_cancellation('cross-process')"
                    ),
                ],
                env=environment,
                check=True,
                capture_output=True,
                timeout=5,
            )
            assert process.returncode == 0
            await asyncio.wait_for(job, 2)
        finally:
            task_store.request_cancellation("cross-process")
            await asyncio.wait_for(job, 2)
        assert exited.is_set()
        assert status("cross-process") == "cancelled"

    asyncio.run(scenario())


@pytest.mark.parametrize("source", [" ", "，，。！？", "  ，， 。 "])
def test_excluded_strikethrough_candidates_cannot_trap_the_worker(source, tmp_path):
    # 2026-10-24：独立进程带超时，回归旧无限循环时也不会留下不可终止的测试线程。
    subprocess.run(
        [
            sys.executable,
            "-c",
            (
                "import asyncio, app, os; from test_generation_parameters import parameters; "
                "app.psutil.cpu_percent=lambda **kwargs: 0; "
                "response=asyncio.run(app.generate_handwriting_impl("
                "parameters(text=os.environ['CASE'], "
                "strikethrough_probability='1'))); assert response.status_code == 200"
            ),
        ],
        env={
            **os.environ,
            "HANDWRITING_DATA_DIR": str(tmp_path),
            "CASE": source,
            "PYTHONPATH": os.pathsep.join(
                (str(Path(app.__file__).parent), str(Path(__file__).parent))
            ),
        },
        check=True,
        capture_output=True,
        timeout=10,
    )
