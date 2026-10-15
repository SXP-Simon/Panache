# Copyright (c) 2026 Simon and Handwriting Web contributors.
"""2026-10-15：Gunicorn 主进程与应用 worker 共用日志配置."""

from app_environment import get_environment_value
from logging_setup import configure_logging, server_logging_config

# 2026-10-15：先加载同一份 .env，再由 Gunicorn 的 dictConfig 接管处理器生命周期。
loglevel = get_environment_value("LOG_LEVEL", "info").lower()
if loglevel not in {"debug", "info", "warning", "error", "critical"}:
    loglevel = "info"
logconfig_dict = server_logging_config()


def post_fork(_server: object, _worker: object) -> None:
    """2026-10-15：恢复 UvicornWorker 构造期间替换的 logger 传播规则."""
    configure_logging()
