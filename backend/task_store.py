# Copyright (c) 2026 HandwritingWeb contributors
"""SQLite 跨进程任务状态存储，响应文件落盘以限制数据库体积."""

import json
import os
import shutil
import sqlite3
import time
from pathlib import Path
from threading import Lock
from typing import Unpack

from pydantic import TypeAdapter
from task_types import GenerationTask

if __package__:
    from .logging_setup import get_logger
else:
    from logging_setup import get_logger

logger = get_logger(__name__)

# 2026-10-15：桌面可写目录由启动器传入；包内 __file__ 只作为 Web 部署的兜底。
_BASE_DIR = Path(os.environ.get("HANDWRITING_DATA_DIR", Path(__file__).resolve().parent))
_DB_PATH = _BASE_DIR / "tasks.db"
_RESULT_DIR = _BASE_DIR / "temp" / "task_results"
_DB_TIMEOUT = 10
_TTL_SECONDS = 60 * 30
_WRITE_LOCK = Lock()
_TASK_ADAPTER = TypeAdapter(GenerationTask)
type SqlValue = str | int | float | bytes | None

_COLUMNS = (
    "status",
    "stage",
    "message",
    "progress",
    "created_at",
    "updated_at",
    "response_status_code",
    "response_content_type",
    "response_headers",
    "result_file_path",
    "error_message",
)
_CREATE_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS generation_tasks (
    task_id TEXT PRIMARY KEY,
    status TEXT NOT NULL DEFAULT 'pending',
    stage TEXT DEFAULT '', message TEXT DEFAULT '', progress INTEGER DEFAULT 0,
    created_at REAL, updated_at REAL, response_status_code INTEGER,
    response_content_type TEXT, response_headers TEXT, result_file_path TEXT,
    error_message TEXT DEFAULT ''
)
"""
_INSERT_SQL = """
INSERT INTO generation_tasks (
    task_id, status, stage, message, progress, created_at, updated_at,
    response_status_code, response_content_type, response_headers, result_file_path, error_message
) VALUES (
    :task_id, :status, :stage, :message, :progress, :created_at, :updated_at,
    :response_status_code, :response_content_type, :response_headers,
    :result_file_path, :error_message
)
"""
_UPDATE_SQL = """
UPDATE generation_tasks SET
    status = CASE WHEN :has_status THEN :status ELSE status END,
    stage = CASE WHEN :has_stage THEN :stage ELSE stage END,
    message = CASE WHEN :has_message THEN :message ELSE message END,
    progress = CASE WHEN :has_progress THEN :progress ELSE progress END,
    created_at = CASE WHEN :has_created_at THEN :created_at ELSE created_at END,
    updated_at = CASE WHEN :has_updated_at THEN :updated_at ELSE updated_at END,
    response_status_code = CASE WHEN :has_response_status_code THEN :response_status_code
        ELSE response_status_code END,
    response_content_type = CASE WHEN :has_response_content_type THEN :response_content_type
        ELSE response_content_type END,
    response_headers = CASE WHEN :has_response_headers THEN :response_headers
        ELSE response_headers END,
    result_file_path = CASE WHEN :has_result_file_path THEN :result_file_path
        ELSE result_file_path END,
    error_message = CASE WHEN :has_error_message THEN :error_message ELSE error_message END
WHERE task_id = :task_id
"""


def _connect() -> sqlite3.Connection:
    connection = sqlite3.connect(str(_DB_PATH), timeout=_DB_TIMEOUT)
    connection.execute("PRAGMA journal_mode=WAL")
    connection.execute("PRAGMA synchronous=NORMAL")
    connection.row_factory = sqlite3.Row
    return connection


def init() -> None:
    """应用启动时创建数据目录、表与索引."""
    _RESULT_DIR.mkdir(parents=True, exist_ok=True)
    connection = _connect()
    try:
        connection.execute(_CREATE_TABLE_SQL)
        connection.execute(
            "CREATE INDEX IF NOT EXISTS idx_tasks_status ON generation_tasks(status)"
        )
        connection.execute(
            "CREATE INDEX IF NOT EXISTS idx_tasks_updated_at ON generation_tasks(updated_at)",
        )
        connection.commit()
    finally:
        connection.close()


def _row_to_task(row: object) -> GenerationTask | None:
    # 2026-10-15：SQLite 与 JSON 的动态返回值在此验证，路由层只收到确定的任务字段类型。
    if row is None:
        return None
    if not isinstance(row, sqlite3.Row):
        error = "Task query did not return a SQLite row"
        raise TypeError(error)
    data: dict[str, object] = {name: row[name] for name in _COLUMNS}
    headers = data["response_headers"]
    data["response_headers"] = json.loads(headers) if isinstance(headers, str) else (headers or {})
    return _TASK_ADAPTER.validate_python(data)


def _serialize_updates(updates: GenerationTask) -> dict[str, SqlValue]:
    result: dict[str, SqlValue] = {}
    for name, value in updates.items():
        if name == "response_body":
            continue
        if name not in _COLUMNS:
            error = "Unsupported task update field"
            raise ValueError(error)
        if name == "response_headers":
            result[name] = json.dumps(value)
        elif isinstance(value, str | int | float | bytes) or value is None:
            result[name] = value
        else:
            error = "Task update is not a supported SQLite value"
            raise TypeError(error)
    return result


def _write_result_file(task_id: str, data: bytes | bytearray) -> str:
    task_dir = _RESULT_DIR / task_id
    task_dir.mkdir(parents=True, exist_ok=True)
    path = task_dir / "result.bin"
    path.write_bytes(data)
    return str(path)


def _read_result_file(file_path: str) -> bytes | None:
    try:
        return Path(file_path).read_bytes()
    except OSError as error:
        logger.warning("Failed to read result file %s: %s", file_path, error, exc_info=True)
        return None


def _remove_result_dir(task_id: str) -> None:
    shutil.rmtree(_RESULT_DIR / task_id, ignore_errors=True)


def set_task(task_id: str, **updates: Unpack[GenerationTask]) -> GenerationTask:
    """写入任务字段，响应字节单独落盘，并返回已验证的持久化快照."""
    response_body = updates.pop("response_body", None)
    if response_body is not None:
        updates["result_file_path"] = _write_result_file(task_id, response_body)
    updates["updated_at"] = updates.get("updated_at") or time.time()
    stored = _serialize_updates(updates)
    params: dict[str, SqlValue] = {
        "task_id": task_id,
        "status": "pending",
        "stage": "",
        "message": "",
        "progress": 0,
        "created_at": stored["updated_at"],
        "updated_at": stored["updated_at"],
        "response_status_code": None,
        "response_content_type": None,
        "response_headers": "{}",
        "result_file_path": None,
        "error_message": "",
    }
    params.update(stored)
    params.update({f"has_{name}": int(name in stored) for name in _COLUMNS})
    with _WRITE_LOCK:
        connection = _connect()
        try:
            existing: object = connection.execute(
                "SELECT task_id FROM generation_tasks WHERE task_id = ?",
                (task_id,),
            ).fetchone()
            connection.execute(_UPDATE_SQL if existing is not None else _INSERT_SQL, params)
            connection.commit()
            task = _row_to_task(
                connection.execute(
                    "SELECT * FROM generation_tasks WHERE task_id = ?",
                    (task_id,),
                ).fetchone()
            )
            if task is None:
                error = "Task disappeared after a successful update"
                raise RuntimeError(error)
            return task
        finally:
            connection.close()


def get_task(task_id: str) -> GenerationTask | None:
    """读取任务，查询不存在的 ID 时返回 None."""
    connection = _connect()
    try:
        return _row_to_task(
            connection.execute(
                "SELECT * FROM generation_tasks WHERE task_id = ?",
                (task_id,),
            ).fetchone()
        )
    finally:
        connection.close()


def pop_task(task_id: str) -> GenerationTask | None:
    """读取并删除任务，同时清理响应文件."""
    with _WRITE_LOCK:
        connection = _connect()
        try:
            task = _row_to_task(
                connection.execute(
                    "SELECT * FROM generation_tasks WHERE task_id = ?",
                    (task_id,),
                ).fetchone()
            )
            if task is not None:
                connection.execute("DELETE FROM generation_tasks WHERE task_id = ?", (task_id,))
                connection.commit()
                _remove_result_dir(task_id)
            return task
        finally:
            connection.close()


def _row_task_id(row: object) -> str:
    if not isinstance(row, sqlite3.Row):
        error = "Expected a task ID row"
        raise TypeError(error)
    task_id: object = row["task_id"]
    if not isinstance(task_id, str):
        error = "Task ID must be text"
        raise TypeError(error)
    return task_id


def cleanup_expired() -> None:
    """清理超过 TTL 的任务与响应文件."""
    cutoff = time.time() - _TTL_SECONDS
    with _WRITE_LOCK:
        connection = _connect()
        try:
            for row in connection.execute(
                "SELECT task_id FROM generation_tasks WHERE updated_at < ?",
                (cutoff,),
            ):
                _remove_result_dir(_row_task_id(row))
            connection.execute("DELETE FROM generation_tasks WHERE updated_at < ?", (cutoff,))
            connection.commit()
        finally:
            connection.close()


def _count(row: object) -> int:
    if not isinstance(row, sqlite3.Row):
        error = "Count query did not return a SQLite row"
        raise TypeError(error)
    value: object = row[0]
    if not isinstance(value, int):
        error = "Count query did not return an integer"
        raise TypeError(error)
    return value


def get_queue_metrics(task_id: str) -> dict[str, int]:
    """获取排队位置与处理任务数."""
    connection = _connect()
    try:
        task = _row_to_task(
            connection.execute(
                "SELECT * FROM generation_tasks WHERE task_id = ?",
                (task_id,),
            ).fetchone()
        )
        if task is None:
            return dict.fromkeys(
                (
                    "queue_pending_count",
                    "queue_ahead_count",
                    "processing_count",
                    "active_task_count",
                ),
                0,
            )
        pending = _count(
            connection.execute(
                "SELECT COUNT(*) FROM generation_tasks WHERE status = 'pending'",
            ).fetchone()
        )
        processing = _count(
            connection.execute(
                "SELECT COUNT(*) FROM generation_tasks WHERE status = 'processing'",
            ).fetchone()
        )
        ahead = 0
        if task.get("status") == "pending":
            created = task.get("created_at") or 0
            ahead = _count(
                connection.execute(
                    """SELECT COUNT(*) FROM generation_tasks WHERE status = 'pending'
                   AND (created_at < ? OR (created_at = ? AND task_id < ?))""",
                    (created, created, task_id),
                ).fetchone()
            )
        return {
            "queue_pending_count": pending,
            "queue_ahead_count": ahead,
            "processing_count": processing,
            "active_task_count": pending + processing,
        }
    finally:
        connection.close()


def get_active_task_count() -> int:
    """返回 pending 与 processing 的任务总数."""
    connection = _connect()
    try:
        return _count(
            connection.execute(
                "SELECT COUNT(*) FROM generation_tasks WHERE status IN ('pending', 'processing')",
            ).fetchone()
        )
    finally:
        connection.close()


def read_result_file(file_path: str) -> bytes | None:
    """从响应文件读取结果，文件不可用时返回 None."""
    return _read_result_file(file_path)


init()
generation_task_ttl_seconds = _TTL_SECONDS
