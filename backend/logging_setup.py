# Copyright (c) 2026 Simon and Handwriting Web contributors.
"""2026-10-15：统一终端诊断与按进程隔离的 UTF-8 轮转日志."""

import copy
import logging
import os
import re
import sys
from logging.handlers import RotatingFileHandler
from pathlib import Path
from threading import RLock
from typing import TextIO

_ANSI = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\)|[@-_])")
_COLORS = {
    logging.DEBUG: "\x1b[36m",
    logging.INFO: "\x1b[32m",
    logging.WARNING: "\x1b[33m",
    logging.ERROR: "\x1b[31m",
    logging.CRITICAL: "\x1b[1;35m",
}
_FORMAT = (
    "%(asctime)s.%(msecs)03d | [%(levelname)-8s] | "
    "%(name)s | %(pathname)s:%(lineno)d | %(funcName)s() | %(message)s"
)
_PROJECT_ROOT = Path(__file__).resolve().parent.parent
_LOCK = RLock()
_SERVER_LOGGERS = (
    "uvicorn",
    "uvicorn.error",
    "uvicorn.access",
    "gunicorn.error",
    "gunicorn.access",
)


class DiagnosticFormatter(logging.Formatter):
    """2026-10-15：仅给交互终端的级别着色，不污染共享 LogRecord."""

    def __init__(self, *, color: bool = False) -> None:
        """2026-10-15：创建包含毫秒、来源位置和函数名的格式."""
        super().__init__(_FORMAT, datefmt="%Y-%m-%d %H:%M:%S")
        self.color = color

    def format(self, record: logging.LogRecord) -> str:
        """2026-10-15：清除消息与异常中的 ANSI，再按需标记级别."""
        local = copy.copy(record)
        local.exc_text = None
        local.pathname = _source_path(record)
        rendered = _ANSI.sub("", super().format(local)).replace("\n", "\n    ")
        if self.color and (color := _COLORS.get(record.levelno)):
            label = f"[{record.levelname:<8}]"
            rendered = rendered.replace(label, f"{color}{label}\x1b[0m", 1)
        return rendered


def _source_path(record: logging.LogRecord) -> str:
    pathname = Path(record.pathname)
    if not pathname.is_absolute():
        # 2026-10-15：冻结的 co_filename 相对源码根，不能按桌面的可写 cwd 解析。
        module = sys.modules.get(record.name)
        module_file: object = getattr(module, "__file__", None)
        if (
            len(pathname.parts) == 1
            and isinstance(module_file, str)
            and Path(module_file).parent == Path(__file__).parent
        ):
            return f"backend/{pathname.as_posix()}"
        return pathname.as_posix()
    return (
        pathname.relative_to(_PROJECT_ROOT).as_posix()
        if pathname.is_relative_to(_PROJECT_ROOT)
        else pathname.as_posix()
    )


class ProcessRotatingFileHandler(RotatingFileHandler):
    """2026-10-15：每个 PID 独立轮转，避免 Gunicorn fork 后并发改名同一文件."""

    def __init__(
        self, directory: Path, *, max_bytes: int = 10 * 1024 * 1024, backup_count: int = 5
    ) -> None:
        """2026-10-15：延迟打开 UTF-8 文件，每个进程最多保留五份归档."""
        directory.mkdir(parents=True, exist_ok=True)
        self.directory = directory.resolve()
        self.process_id = os.getpid()
        super().__init__(
            self.directory / f"app-{self.process_id}.log",
            maxBytes=max_bytes,
            backupCount=backup_count,
            encoding="utf-8",
            errors="backslashreplace",
            delay=True,
        )
        self.setFormatter(DiagnosticFormatter())

    def emit(self, record: logging.LogRecord) -> None:
        """2026-10-15：在子进程首次输出时关闭继承句柄并切换到自己的文件."""
        process_id = os.getpid()
        if process_id != self.process_id:
            if self.stream is not None:
                self.stream.close()
                self.stream = None
            self.process_id = process_id
            self.baseFilename = str(self.directory / f"app-{process_id}.log")
        super().emit(record)


class DiagnosticStreamHandler(logging.StreamHandler[TextIO]):
    """2026-10-15：仅向 stderr 输出，TTY 支持颜色，管道保持纯文本."""

    def __init__(self, stream: TextIO | None = None) -> None:
        """2026-10-15：创建独立于桌面 stdout 握手协议的诊断通道."""
        destination = stream if stream is not None else sys.stderr
        super().__init__(destination)
        self.setFormatter(
            DiagnosticFormatter(color=destination.isatty() and "NO_COLOR" not in os.environ)
        )


def get_logger(name: str) -> logging.Logger:
    """2026-10-15：直接返回标准 Logger，保留调用者原始文件、行号和函数名."""
    return logging.getLogger(name)


def _log_level() -> int:
    value = os.environ.get("LOG_LEVEL", "INFO").upper()
    return {
        "DEBUG": logging.DEBUG,
        "INFO": logging.INFO,
        "WARNING": logging.WARNING,
        "ERROR": logging.ERROR,
        "CRITICAL": logging.CRITICAL,
    }.get(value, logging.INFO)


def configure_logging() -> None:
    """2026-10-15：幂等配置共享处理器，同时保留宿主或测试安装的诊断处理器."""
    with _LOCK:
        root = logging.getLogger()
        root.setLevel(_log_level())
        directory = Path(os.environ.get("LOG_DIR", "logs")).resolve()
        for handler in list(root.handlers):
            if isinstance(handler, (DiagnosticStreamHandler, ProcessRotatingFileHandler)):
                root.removeHandler(handler)
                handler.close()
        root.addHandler(DiagnosticStreamHandler())
        root.addHandler(ProcessRotatingFileHandler(directory))
        for name in _SERVER_LOGGERS:
            logger = logging.getLogger(name)
            logger.handlers.clear()
            logger.propagate = True
            logger.disabled = False
            logger.setLevel(logging.NOTSET)


def server_logging_config() -> dict[str, object]:
    """2026-10-15：供 Gunicorn 在主进程启动前安装相同处理器与传播规则."""
    return {
        "version": 1,
        "disable_existing_loggers": False,
        "root": {"level": _log_level(), "handlers": ["diagnostic", "rotating"]},
        "handlers": {
            "diagnostic": {"()": DiagnosticStreamHandler},
            "rotating": {
                "()": ProcessRotatingFileHandler,
                "directory": Path(os.environ.get("LOG_DIR", "logs")),
            },
        },
        "loggers": {
            name: {"handlers": [], "level": "NOTSET", "propagate": True} for name in _SERVER_LOGGERS
        },
    }
