# Copyright (c) 2026 Simon and Handwriting Web contributors.
__all__ = ["Limiter", "_rate_limit_exceeded_handler"]
from collections.abc import Callable

from starlette.requests import Request
from starlette.responses import Response

from .errors import RateLimitExceeded

class Limiter:
    def __init__(
        self, key_func: Callable[[Request], str], default_limits: list[str] = ...
    ) -> None: ...
    def limit[F: Callable[..., object]](self, limit_value: str) -> Callable[[F], F]: ...

def _rate_limit_exceeded_handler(request: Request, exc: RateLimitExceeded) -> Response: ...
