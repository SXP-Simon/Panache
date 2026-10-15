# Copyright (c) 2026 HandwritingWeb contributors
"""任务持久化和表单字段别名的边界回归."""

import asyncio
import json
from pathlib import Path
from typing import Annotated
from urllib.parse import urlencode

import pytest
import task_store
from fastapi import Depends, FastAPI
from starlette.types import Message, Scope
from task_types import GenerateHandwritingParams, form_dependency_from_model


@pytest.fixture
def isolated_store(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """2026-10-15：任务与响应文件均限定在测试的临时目录."""
    monkeypatch.setattr(task_store, "_DB_PATH", tmp_path / "tasks.db")
    monkeypatch.setattr(task_store, "_RESULT_DIR", tmp_path / "results")
    task_store.init()


@pytest.mark.usefixtures("isolated_store")
def test_partial_updates_preserve_existing_fields_and_can_clear_nullable_response() -> None:
    """部分更新不会重置历史字段，显式 None 仍能清空响应元数据."""
    first = task_store.set_task(
        "typed-task",
        status="pending",
        message="keep",
        response_status_code=200,
        response_headers={"Content-Type": "image/png"},
    )
    updated = task_store.set_task("typed-task", status="processing", response_status_code=None)
    assert updated["message"] == "keep"
    assert updated["response_headers"] == {"Content-Type": "image/png"}
    assert updated["response_status_code"] is None
    assert updated["status"] == "processing"
    assert updated["created_at"] == first["created_at"]


@pytest.mark.usefixtures("isolated_store")
def test_result_file_round_trip_and_pop_cleanup() -> None:
    """响应体落盘、读取、删除后均遵守可空路径契约."""
    task = task_store.set_task("binary-task", status="completed", response_body=b"png-bytes")
    result_path = task["result_file_path"]
    assert result_path is not None
    assert task_store.read_result_file(result_path) == b"png-bytes"
    assert task_store.pop_task("binary-task") == task
    assert task_store.get_task("binary-task") is None
    assert task_store.read_result_file(result_path) is None


@pytest.mark.usefixtures("isolated_store")
def test_queue_metrics_keep_timestamp_and_task_id_order() -> None:
    """固定创建时间时，任务 ID 继续提供稳定的排队次序."""
    task_store.set_task("a", status="pending", created_at=1)
    task_store.set_task("b", status="pending", created_at=1)
    task_store.set_task("c", status="processing", created_at=1)
    assert task_store.get_queue_metrics("b") == {
        "queue_pending_count": 2,
        "queue_ahead_count": 1,
        "processing_count": 1,
        "active_task_count": 3,
    }
    assert task_store.get_active_task_count() == 3


async def _post_form(app: FastAPI, data: dict[str, str]) -> tuple[int, bytes]:
    body = urlencode(data).encode()
    scope: Scope = {
        "type": "http",
        "asgi": {"version": "3.0"},
        "http_version": "1.1",
        "method": "POST",
        "scheme": "http",
        "path": "/form",
        "raw_path": b"/form",
        "root_path": "",
        "query_string": b"",
        "server": ("localhost", 80),
        "client": ("localhost", 0),
        "headers": [
            (b"content-type", b"application/x-www-form-urlencoded"),
            (b"content-length", str(len(body)).encode()),
        ],
    }
    messages: list[Message] = []

    async def receive() -> Message:
        return {"type": "http.request", "body": body, "more_body": False}

    async def send(message: Message) -> None:
        messages.append(message)

    await app(scope, receive, send)
    status, result = 0, bytearray()
    for message in messages:
        response_status: object = message.get("status")
        response_body: object = message.get("body")
        if isinstance(response_status, int):
            status = response_status
        if isinstance(response_body, bytes):
            result.extend(response_body)
    return status, bytes(result)


def test_generic_form_dependency_keeps_legacy_aliases_and_defaults() -> None:
    """FastAPI 仍接收旧 camelCase 字段，模型内部使用明确的 snake_case 属性."""
    app = FastAPI()
    dependency = form_dependency_from_model(GenerateHandwritingParams)

    @app.post("/form")
    def form(params: Annotated[GenerateHandwritingParams, Depends(dependency)]) -> dict[str, str]:
        return {
            "isUnderlined": params.is_underlined,
            "enableEnglishSpacing": params.enable_english_spacing,
        }

    required = {
        name: "1"
        for name, field in GenerateHandwritingParams.model_fields.items()
        if field.is_required()
    }
    status, body = asyncio.run(_post_form(app, {**required, "isUnderlined": "true"}))
    assert status == 200
    assert json.loads(body) == {"isUnderlined": "true", "enableEnglishSpacing": "false"}
    assert asyncio.run(_post_form(app, {"isUnderlined": "true"}))[0] == 422
    model = dependency(**required, isUnderlined="true")
    assert model.model_dump()["isUnderlined"] == "true"
    assert "is_underlined" not in model.model_dump()
