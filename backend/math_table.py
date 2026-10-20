# Copyright (c) 2026 Simon and Handwriting Web contributors.
"""2026-10-20：识别带明确分隔线的可读二维表格，普通矩阵保持原样."""

import itertools
from dataclasses import dataclass

_MAX_SOURCE = 16384
_MAX_PARTS = 65
_MAX_COLUMNS = 32
_MIN_ROWS = 2


@dataclass(frozen=True)
class Rule:
    """2026-10-20：记录实线或虚线所在的行列边界."""

    position: int
    dashed: bool = False


@dataclass(frozen=True)
class Table:
    """2026-10-20：不可变单元格及分隔线位置."""

    rows: tuple[tuple[str, ...], ...]
    vertical: tuple[Rule, ...]
    horizontal: tuple[Rule, ...]


def _split(text: str, separators: str) -> tuple[list[str], list[str]] | None:
    stack: list[str] = []
    pairs = {"(": ")", "[": "]", "{": "}", "⟦": "⟧"}
    result: list[str] = []
    markers: list[str] = []
    start = 0
    for index, char in enumerate(text):
        if char in pairs:
            stack.append(pairs[char])
        elif char in ")]}⟧":
            if not stack or stack.pop() != char:
                return None
        elif char in separators and not stack:
            result.append(text[start:index])
            markers.append(char)
            start = index + 1
    if stack:
        return None
    result.append(text[start:])
    return result, markers


def _cells(line: str) -> tuple[tuple[str, ...], tuple[Rule, ...]] | None:
    split = _split(line, "|┆")
    if split is None:
        return None
    groups, markers = split
    if any(
        not (
            (left.endswith(" ") or (index == 0 and not left))
            and (right.startswith(" ") or (index == len(markers) - 1 and not right))
        )
        for index, (left, right) in enumerate(itertools.pairwise(groups))
    ):
        return None
    cells: list[str] = []
    rules: list[Rule] = []
    for index, raw_group in enumerate(groups):
        # 2026-10-20：紧贴边缘的规则是外框，带一个空格的空组则是空单元格。
        edge = raw_group == "" and index in (0, len(groups) - 1) and bool(markers)
        group = raw_group.removeprefix(" ") if index else raw_group
        if index < len(groups) - 1:
            group = group.removesuffix(" ")
        if index:
            rules.append(Rule(len(cells), markers[index - 1] == "┆"))
        if not edge:
            cells.extend(group.split("  "))
    if not cells or len(cells) > _MAX_COLUMNS:
        return None
    return tuple(cells), tuple(rules)


def _parse_parts(parts: list[str]) -> Table | None:
    rows: list[tuple[str, ...]] = []
    horizontal: list[Rule] = []
    vertical: tuple[Rule, ...] | None = None
    for index, part in enumerate(parts):
        line = part.removeprefix(" ") if index else part
        if index < len(parts) - 1:
            line = line.removesuffix(" ")
        if line in ("──", "╌╌"):
            horizontal.append(Rule(len(rows), line == "╌╌"))
            continue
        parsed = _cells(line)
        if parsed is None:
            return None
        cells, rules = parsed
        if (rows and len(cells) != len(rows[0])) or (vertical is not None and rules != vertical):
            return None
        vertical = rules
        rows.append(cells)
    if len({rule.position for rule in horizontal}) != len(horizontal):
        return None
    if len(rows) < _MIN_ROWS or not (horizontal or vertical):
        return None
    return Table(tuple(rows), vertical or (), tuple(horizontal))


def parse_table(text: str) -> Table | None:
    """2026-10-20：限定完整括号、规则及一致列宽；保留双空格表示的空单元格."""
    if not text.startswith("⟦ ") or not text.endswith(" ⟧") or len(text) > _MAX_SOURCE:
        return None
    # 2026-10-20：双线尚无明确间距协议，不把它误读为新的空列。
    if "||" in text or any(char in text for char in "\n\r\t"):
        return None
    split = _split(text[2:-2], ";")
    if split is None or len(split[0]) > _MAX_PARTS:
        return None
    return _parse_parts(split[0])
