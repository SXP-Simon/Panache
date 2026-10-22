# Copyright (c) 2026 Simon and Handwriting Web contributors.
"""2026-10-22：在正文中完整隔离电路源码，代码围栏和注释不启动电路解析."""

import re
from collections.abc import Callable, Iterator

_OPEN = r"\begin{circuitikz}"
_CLOSE = r"\end{circuitikz}"
_FENCE = re.compile(r" {0,3}(`{3,}|~{3,})(.*)")


def _environment_end(text: str, start: int) -> int:
    # 2026-10-22：标签中的括号和注释内的假结束标记不能截断接线源码。
    cursor, braces, environments = start + len(_OPEN), 0, 1
    while cursor < len(text):
        if text[cursor] == "%":
            end = text.find("\n", cursor)
            cursor = len(text) if end < 0 else end + 1
        elif text[cursor] == "\\":
            if not braces and text.startswith(_CLOSE, cursor):
                environments -= 1
                cursor += len(_CLOSE)
                if not environments:
                    return cursor
            elif not braces and text.startswith(_OPEN, cursor):
                environments += 1
                cursor += len(_OPEN)
            else:
                cursor += 2
        else:
            if text[cursor] == "{":
                braces += 1
            elif text[cursor] == "}":
                braces = max(0, braces - 1)
            cursor += 1
    return len(text)


def _fence_line(line: str, fence: str | None) -> tuple[bool, str | None]:
    match = _FENCE.fullmatch(line)
    marker = match[1] if match else ""
    if fence:
        closing = (
            marker
            and marker[0] == fence[0]
            and len(marker) >= len(fence)
            and match is not None
            and not match[2].strip()
        )
        return True, None if closing else fence
    if marker and not (marker[0] == "`" and match is not None and "`" in match[2]):
        return True, marker
    return False, None


def circuit_spans(text: str) -> Iterator[tuple[int, int]]:
    """2026-10-22：返回完整或未闭合电路的范围，不消费代码中的示例."""
    cursor = 0
    fence: str | None = None
    while cursor < len(text):
        if cursor == 0 or text[cursor - 1] == "\n":
            end = text.find("\n", cursor)
            end = len(text) if end < 0 else end
            skip, fence = _fence_line(text[cursor:end], fence)
            if skip:
                cursor = end + 1
                continue
        if text[cursor] == "`":
            count = 1
            while cursor + count < len(text) and text[cursor + count] == "`":
                count += 1
            end = text.find("`" * count, cursor + count)
            if end < 0:
                end = text.find("\n", cursor + count)
                cursor = len(text) if end < 0 else end + 1
            else:
                cursor = end + count
        elif text.startswith(_OPEN, cursor):
            end = _environment_end(text, cursor)
            yield cursor, end
            cursor = end
        elif text[cursor] == "\\":
            cursor += 2
        else:
            cursor += 1


def map_circuit_document(
    text: str, regular: Callable[[str], str], circuit: Callable[[str], str]
) -> str:
    """2026-10-22：未知电路也整体保护，避免公式转换只改写其中一部分."""
    result: list[str] = []
    cursor = 0
    for start, end in circuit_spans(text):
        result.extend((regular(text[cursor:start]), circuit(text[start:end])))
        cursor = end
    result.append(regular(text[cursor:]))
    return "".join(result)
