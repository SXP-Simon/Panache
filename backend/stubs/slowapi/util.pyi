# Copyright (c) 2026 Simon and Handwriting Web contributors.
from starlette.requests import Request

def get_remote_address(request: Request) -> str: ...
