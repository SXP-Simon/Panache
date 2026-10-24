# Copyright (c) 2026 Simon and Panache contributors.
"""2026-10-24：不重写原文的可选作业笔记排版规则."""

import re
from collections.abc import Callable
from dataclasses import dataclass

from handright import Template

_TOP_ITEM = re.compile(
    r"^(?:第[\d一二三四五六七八九十百]+[题章节]|(?:\d{1,3}[.、\uff0e](?!\d)|[一二三四五六七八九十]+、))\s*"
)
_SUB_ITEM = re.compile(
    r"^(?:[（(][\da-zA-Z一二三四五六七八九十]+[)）]|[a-zA-Z][.)、]|[•●·*-]\s+)\s*"
)
_OPEN = "(（[【{"
_CLOSE = ")）]】}"
_RELATIONS = "=\uff1d≠≈≡≤≥<>\uff1c\uff1e→⇒⇔"
_SENTENCE_END = "，,。；;：:！？!?、"
_MIN_BODY_LINES = 6
_PREVIOUS_LINES = 8


def inset_homework_body(template: Template) -> None:
    """2026-10-24：只收正文版心，保留背景原图与横线长度."""
    width, height = template.get_size()
    left, right = template.get_left_margin(), template.get_right_margin()
    top, bottom = template.get_top_margin(), template.get_bottom_margin()
    font_size = int(getattr(template.get_font(), "size", 30))
    available = width - left - right
    inset = min(round(available * 0.06), max(0, (available - 4 * font_size) // 2))
    template.set_left_margin(left + inset)
    template.set_right_margin(right + inset)
    spacing = template.get_line_spacing()
    if height - top - bottom >= spacing * _MIN_BODY_LINES:
        template.set_top_margin(top + spacing)
        template.set_bottom_margin(bottom + spacing)


@dataclass(frozen=True)
class ParagraphStyle:
    """2026-10-24：原始段落的视觉行缩进与题间分隔."""

    indent: int = 0
    separate: bool = False


def _marker(line: str) -> tuple[str, bool, bool, bool]:
    leading = line[: len(line) - len(line.lstrip())]
    content = line[len(leading) :]
    top = _TOP_ITEM.match(content)
    sub = _SUB_ITEM.match(content)
    # 2026-10-24：括号后的运算符表明这是表达式，不能把 (x) = 1 误认为条目。
    if sub and content.startswith(("(", "（")):
        remainder = content[sub.end() :].lstrip()
        if remainder.startswith(tuple("=+-*/∈≤≥≠≈⇒→↔⇔")):
            sub = None
    match = top or sub
    return (
        leading + match.group() if match else "",
        top is not None,
        sub is not None,
        top is not None and content.startswith("第"),
    )


def paragraph_style(
    text: str, start: int, width: int, font_size: int, measure: Callable[[str], float]
) -> ParagraphStyle:
    """2026-10-24：依据邻近条目标号推导适量悬挂缩进."""
    line_start = text.rfind("\n", 0, start) + 1
    prefix, top, sub, heading = _marker(text[line_start : line_start + 256].split("\n", 1)[0])
    cap = max(0, min(width // 4, width - 3 * font_size))
    base = font_size if sub else 0
    if prefix:
        indent = base + (measure(prefix) if start > line_start and not heading else 0)
        previous_start = text.rfind("\n", 0, max(0, line_start - 1)) + 1
        previous_blank = line_start == 0 or not text[previous_start : line_start - 1].strip()
        return ParagraphStyle(
            min(cap, round(indent)), top and start == line_start and not previous_blank
        )
    # 2026-10-24：明确空行终止条目续写；只检查邻近少量段落，长文分页不反复扫描全文。
    previous = line_start - 1
    for _ in range(_PREVIOUS_LINES):
        if previous < 0:
            break
        begin = text.rfind("\n", 0, previous) + 1
        line = text[begin:previous]
        if not line.strip():
            break
        prior, _, nested, heading = _marker(line[:256])
        if heading:
            break
        if prior:
            return ParagraphStyle(min(cap, round(measure(prior) + (font_size if nested else 0))))
        previous = begin - 1
    return ParagraphStyle()


def preferred_break(text: str, index: int, depth: int) -> bool:
    """2026-10-24：优先在短括号组外的句读和数学关系前换行."""
    if depth or index <= 0:
        return False
    previous, current = text[index - 1], text[index]
    lookback = index - 1
    while lookback >= 0 and text[lookback].isspace():
        lookback -= 1
    # 2026-10-24：关系符必须带着右侧结果换行，空格或左括号不能覆盖符号前的候选点。
    if lookback >= 0 and text[lookback] in _RELATIONS:
        return False
    return previous.isspace() or previous in _SENTENCE_END or current in _RELATIONS + _OPEN


def bracket_depth(char: str, depth: int) -> int:
    """2026-10-24：追踪普通括号，结构化公式本身已是不可拆字形."""
    if char in _OPEN:
        return depth + 1
    return max(0, depth - 1) if char in _CLOSE else depth
