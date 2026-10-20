# Copyright (c) 2026 Simon and Handwriting Web contributors.
"""2026-10-20：识别带明确分隔线的可读二维表格，普通矩阵保持原样."""

import itertools
import json
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


def _unquoted_tokens(text: str) -> list[tuple[int, str]] | None:
    # 2026-10-20：JSON 解码器负责转义合法性，引号内的括号和规则不参与表格语法。
    decoder = json.JSONDecoder()
    tokens: list[tuple[int, str]] = []
    index = 0
    while index < len(text):
        if text[index] == '"':
            try:
                _, index = decoder.raw_decode(text, index)
            except ValueError:
                return None
        else:
            tokens.append((index, text[index]))
            index += 1
    return tokens


def _separator_positions(text: str, separators: tuple[str, ...]) -> list[tuple[int, str]] | None:
    tokens = _unquoted_tokens(text)
    if tokens is None:
        return None
    stack: list[str] = []
    pairs = {"(": ")", "[": "]", "{": "}", "⟦": "⟧"}
    positions: list[tuple[int, str]] = []
    consumed = 0
    for index, char in tokens:
        if index < consumed:
            continue
        if char in pairs:
            stack.append(pairs[char])
        elif char in ")]}⟧":
            if not stack or stack.pop() != char:
                return None
        elif not stack:
            separator = next((item for item in separators if text.startswith(item, index)), None)
            if separator is not None:
                positions.append((index, separator))
                consumed = index + len(separator)
    return None if stack else positions


def _split(text: str, separators: tuple[str, ...]) -> tuple[list[str], list[str]] | None:
    positions = _separator_positions(text, separators)
    if positions is None:
        return None
    result: list[str] = []
    markers: list[str] = []
    start = 0
    for index, marker in positions:
        result.append(text[start:index])
        markers.append(marker)
        start = index + len(marker)
    result.append(text[start:])
    return result, markers


def _decode_cell(cell: str) -> str | None:
    if '"' not in cell:
        return cell
    try:
        decoded: object = json.loads(cell)
    except ValueError:
        return None
    if not isinstance(decoded, str) or any(char in decoded for char in "\n\r\t"):
        return None
    return decoded


def _decode_group(group: str) -> tuple[str, ...] | None:
    split = _split(group, ("  ",))
    if split is None:
        return None
    cells = tuple(_decode_cell(cell) for cell in split[0])
    if any(cell is None for cell in cells):
        return None
    return tuple(cell for cell in cells if cell is not None)


def _cells(line: str) -> tuple[tuple[str, ...], tuple[Rule, ...]] | None:
    split = _split(line, ("|", "┆"))
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
            decoded = _decode_group(group)
            if decoded is None:
                return None
            cells.extend(decoded)
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
    # 2026-10-20：协议限定单行；控制字符不能悄悄改变单元格内的排版。
    if any(char in text for char in "\n\r\t"):
        return None
    split = _split(text[2:-2], (";",))
    if split is None or len(split[0]) > _MAX_PARTS:
        return None
    return _parse_parts(split[0])


def table_spans(text: str, protected: tuple[tuple[int, int], ...] = ()) -> list[tuple[int, int]]:
    """2026-10-20：定位完整表格，JSON 字符串内的表格边界不结束当前表格."""
    spans: list[tuple[int, int]] = []
    index = 0
    while index < len(text):
        if text[index] != "⟦":
            index += 1
            continue
        protected_end = next((right for left, right in protected if left <= index < right), None)
        if protected_end is not None:
            index = protected_end
            continue
        end = _table_end(text, index)
        if end is None:
            break
        spans.append((index, end))
        index = end
    return spans


def _table_end(text: str, start: int) -> int | None:
    decoder = json.JSONDecoder()
    depth, index = 0, start
    while index < len(text):
        char = text[index]
        if char == '"':
            try:
                _, index = decoder.raw_decode(text, index)
            except ValueError:
                return None
            continue
        if char == "⟦":
            depth += 1
        elif char == "⟧":
            depth -= 1
            if not depth:
                return index + 1
        index += 1
    return None
