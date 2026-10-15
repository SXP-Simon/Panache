# Copyright (c) 2026 Simon and Handwriting Web contributors.
from starlette.exceptions import HTTPException

class RateLimitExceeded(HTTPException): ...
