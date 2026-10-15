# Copyright (c) 2026 Simon and Handwriting Web contributors.
"""2026-10-15：日志定位、颜色隔离、轮转和桌面协议回归."""

import asyncio
import inspect
import io
import logging
import logging.config
import os
import re
from collections.abc import Iterator
from pathlib import Path

import app
import desktop_main
import gunicorn_config
import logging_setup as logs
import pytest
from fastapi.responses import Response
from task_types import GenerateHandwritingParams


class _Terminal(io.StringIO):
    def isatty(self) -> bool:
        return True


@pytest.fixture
def isolated_logging(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    root = logging.getLogger()
    handlers = root.handlers[:]
    level = root.level
    names = (*logs._SERVER_LOGGERS, "logging-test")
    snapshots = {
        name: (logger.handlers[:], logger.level, logger.propagate, logger.disabled)
        for name in names
        for logger in [logging.getLogger(name)]
    }
    root.handlers = []
    monkeypatch.setenv("LOG_DIR", str(tmp_path))
    monkeypatch.setenv("LOG_LEVEL", "DEBUG")
    monkeypatch.delenv("NO_COLOR", raising=False)
    try:
        yield
    finally:
        for handler in root.handlers:
            handler.close()
        root.handlers = handlers
        root.setLevel(level)
        for name, (saved_handlers, saved_level, propagate, disabled) in snapshots.items():
            logger = logging.getLogger(name)
            logger.handlers = saved_handlers
            logger.setLevel(saved_level)
            logger.propagate = propagate
            logger.disabled = disabled


@pytest.mark.usefixtures("isolated_logging")
def test_real_callsite_and_chinese_message_survive_console_and_file(tmp_path, monkeypatch):
    stream = _Terminal()
    monkeypatch.setattr(logs.sys, "stderr", stream)
    logs.configure_logging()
    frame = inspect.currentframe()
    assert frame is not None
    line = frame.f_lineno + 1
    logs.get_logger("logging-test").warning("中文消息 %s", "位置")
    output = stream.getvalue()
    assert f"backend/tests/test_logging_setup.py:{line}" in output
    assert "test_real_callsite_and_chinese_message_survive_console_and_file()" in output
    assert "中文消息 位置" in output
    assert re.search(r"\d{2}:\d{2}:\d{2}\.\d{3} \|", output)
    assert "\x1b[33m[WARNING ]\x1b[0m" in output
    file_output = next(tmp_path.glob("app-*.log")).read_text(encoding="utf-8")
    assert "中文消息 位置" in file_output
    assert "\x1b" not in file_output


@pytest.mark.usefixtures("isolated_logging")
@pytest.mark.parametrize("terminal", [False, True])
def test_pipe_and_no_color_strip_message_and_exception_ansi(monkeypatch, terminal):
    stream = _Terminal() if terminal else io.StringIO()
    monkeypatch.setattr(logs.sys, "stderr", stream)
    if terminal:
        monkeypatch.setenv("NO_COLOR", "1")
    logs.configure_logging()

    def fail() -> None:
        message = "\x1b[31m中文异常\x1b[0m"
        raise ValueError(message)

    try:
        fail()
    except ValueError:
        logs.get_logger("logging-test").exception("\x1b[32m失败\x1b[0m")
    output = stream.getvalue()
    assert "\x1b" not in output
    assert "失败\n    Traceback (most recent call last):" in output
    assert "ValueError: 中文异常" in output
    assert "test_pipe_and_no_color_strip_message_and_exception_ansi" in output


@pytest.mark.usefixtures("isolated_logging")
def test_reconfiguration_and_third_party_logs_emit_once_without_stdout(monkeypatch, tmp_path):
    stdout, stderr = io.StringIO(), io.StringIO()
    monkeypatch.setattr(logs.sys, "stdout", stdout)
    monkeypatch.setattr(logs.sys, "stderr", stderr)
    for name in logs._SERVER_LOGGERS:
        logging.getLogger(name).addHandler(logging.StreamHandler(stderr))
    logs.configure_logging()
    logs.configure_logging()
    for name in logs._SERVER_LOGGERS:
        logs.get_logger(name).info("event-from-%s", name)
    desktop_main.emit_ready(57610)
    assert stdout.getvalue() == 'HANDWRITING_BACKEND {"type": "ready", "port": 57610}\n'
    console = stderr.getvalue()
    file_output = next(tmp_path.glob("app-*.log")).read_text(encoding="utf-8")
    for name in logs._SERVER_LOGGERS:
        token = f"event-from-{name}\n"
        assert console.count(token) == 1
        assert file_output.count(token) == 1
    assert "\x1b" not in console


@pytest.mark.usefixtures("isolated_logging")
def test_gunicorn_configuration_and_worker_hook_restore_uvicorn_propagation(monkeypatch):
    stderr = io.StringIO()
    monkeypatch.setattr(logs.sys, "stderr", stderr)
    # dictConfig normally closes every registered handler, including pytest's host capture.
    monkeypatch.setattr(logging.config, "_clearExistingHandlers", lambda: None)
    logging.config.dictConfig(logs.server_logging_config())
    logs.get_logger("gunicorn.error").info("master started")
    uvicorn_logger = logs.get_logger("uvicorn.error")
    uvicorn_logger.handlers = []
    uvicorn_logger.propagate = False
    gunicorn_config.post_fork(object(), object())
    uvicorn_logger.info("worker started")
    assert stderr.getvalue().count("master started") == 1
    assert stderr.getvalue().count("worker started") == 1


@pytest.mark.usefixtures("isolated_logging")
def test_rotation_is_utf8_bounded_and_switches_files_after_fork(tmp_path, monkeypatch):
    pid = os.getpid()
    handler = logs.ProcessRotatingFileHandler(tmp_path, max_bytes=400, backup_count=2)
    logger = logs.get_logger("logging-test")
    logger.setLevel(logging.DEBUG)
    logger.addHandler(handler)
    try:
        for number in range(20):
            logger.info("轮转消息 %s %s", number, "x" * 80)
        files = list(tmp_path.glob(f"app-{pid}.log*"))
        assert len(files) == 3
        for path in files:
            assert "轮转消息" in path.read_text(encoding="utf-8")
        monkeypatch.setattr(logs.os, "getpid", lambda: pid + 1)
        logger.warning("child process")
        assert "child process" in (tmp_path / f"app-{pid + 1}.log").read_text(encoding="utf-8")
        assert "child process" not in (tmp_path / f"app-{pid}.log").read_text(encoding="utf-8")
    finally:
        logger.removeHandler(handler)
        handler.close()


@pytest.mark.parametrize(
    "level", [logging.DEBUG, logging.INFO, logging.WARNING, logging.ERROR, logging.CRITICAL]
)
def test_color_formatter_does_not_mutate_shared_record(level):
    record = logging.LogRecord("sample", level, __file__, 123, "message", (), None, "caller")
    original = record.__dict__.copy()
    colored = logs.DiagnosticFormatter(color=True).format(record)
    plain = logs.DiagnosticFormatter().format(record)
    assert "\x1b" in colored
    assert "\x1b" not in plain
    assert record.__dict__ == original


def test_frozen_relative_source_paths_do_not_resolve_against_user_data(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(logs.sys, "frozen", True, raising=False)
    local = logging.LogRecord("app", logging.INFO, "app.py", 123, "ready", (), None, "main")
    external = logging.LogRecord(
        "uvicorn.error", logging.INFO, "uvicorn/server.py", 456, "ready", (), None, "serve"
    )
    formatter = logs.DiagnosticFormatter()
    assert "backend/app.py:123" in formatter.format(local)
    assert "uvicorn/server.py:456" in formatter.format(external)
    assert str(tmp_path) not in formatter.format(local)


@pytest.mark.usefixtures("isolated_logging")
@pytest.mark.parametrize("fail", [False, True])
def test_generation_lifecycle_logs_task_and_duration_without_payload(monkeypatch, fail):
    stderr = io.StringIO()
    monkeypatch.setattr(logs.sys, "stderr", stderr)
    logs.configure_logging()
    monkeypatch.setattr(app, "set_generation_task", lambda *_args, **_kwargs: None)
    monkeypatch.setattr(app, "_generation_semaphore", asyncio.Semaphore(1))

    async def notify(_task_id: str) -> None:
        return

    async def generate(**_kwargs: object) -> Response:
        if fail:
            message = "render failed"
            raise RuntimeError(message)
        return Response(b"image", media_type="image/png")

    monkeypatch.setattr(app, "push_task_status_update", notify)
    monkeypatch.setattr(app, "generate_handwriting_impl", generate)
    asyncio.run(
        app.run_generation_task(
            "logged-task",
            "http://localhost/",
            {
                "params": GenerateHandwritingParams.model_construct(text="PRIVATE正文"),
                "background_image": b"PRIVATEbase64",
                "font_file": None,
            },
        )
    )
    output = stderr.getvalue()
    assert "Generation task started, task_id=logged-task elapsed=0.000s" in output
    final_state = "failed" if fail else "completed"
    assert re.search(
        rf"Generation task {final_state}, task_id=logged-task elapsed=\d+\.\d{{3}}s", output
    )
    assert "PRIVATE" not in output
    if fail:
        assert "RuntimeError: render failed" in output
        assert "Traceback (most recent call last):" in output
