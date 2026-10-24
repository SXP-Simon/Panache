# Copyright (c) 2026 Simon and Panache contributors.
"""2026-10-24：业务错误响应、成功落盘与取消竞争的回归."""

import asyncio
from uuid import uuid4

import app
import pytest
import task_store
from fastapi.responses import JSONResponse, Response
from generation_cancellation import GenerationCancelledError


@pytest.fixture(autouse=True)
def isolated_tasks(tmp_path, monkeypatch):
    monkeypatch.setattr(task_store, "_DB_PATH", tmp_path / "tasks.db")
    monkeypatch.setattr(task_store, "_RESULT_DIR", tmp_path / "results")
    task_store.init()
    monkeypatch.setattr(app, "_generation_semaphore", asyncio.Semaphore(1))


@pytest.mark.parametrize(
    ("response", "reason"),
    [
        (JSONResponse({"message": "Missing background"}, status_code=400), "Missing background"),
        (JSONResponse({"error": "CPU busy"}, status_code=429), "CPU busy"),
        (
            JSONResponse({"message": " ", "detail": " Invalid image "}, status_code=422),
            "Invalid image",
        ),
        (JSONResponse({"unexpected": True}, status_code=500), "HTTP 500"),
        (JSONResponse(["unexpected"], status_code=500), "HTTP 500"),
        (Response(b"not JSON", status_code=502), "HTTP 502"),
        (Response(b"\xff", status_code=503), "HTTP 503"),
    ],
)
def test_business_error_marks_task_failed(response, reason, monkeypatch):
    async def fake_impl(**_kwargs):
        return response

    monkeypatch.setattr(app, "generate_handwriting_impl", fake_impl)
    task_id = str(uuid4())
    asyncio.run(app.run_generation_task(task_id, {}))
    task = task_store.get_task(task_id)
    assert task["status"] == "failed"
    assert reason in task["error_message"]
    assert task["response_status_code"] == response.status_code
    assert task["result_file_path"] is None
    assert not list(task_store._RESULT_DIR.glob("*.bin"))


def test_successful_response_still_completes(monkeypatch):
    async def fake_impl(**_kwargs):
        return Response(b"image content", media_type="image/png")

    monkeypatch.setattr(app, "generate_handwriting_impl", fake_impl)
    task_id = str(uuid4())
    asyncio.run(app.run_generation_task(task_id, {}))
    task = task_store.get_task(task_id)
    assert task["status"] == "completed"
    assert task["response_status_code"] == 200
    assert task["result_file_path"] is not None


@pytest.mark.parametrize("status_code", [200, 400, 429, 500])
def test_response_cannot_overwrite_cancellation(status_code):
    task_id = str(uuid4())
    task_store.create_task(task_id)
    task_store.set_task(task_id, status="processing")
    task_store.request_cancellation(task_id)
    with pytest.raises(GenerationCancelledError):
        app._complete_generation(
            task_id, JSONResponse({"error": "rejected"}, status_code=status_code)
        )
    task = task_store.get_task(task_id)
    assert task["status"] == "cancelling"
    assert task["result_file_path"] is None
