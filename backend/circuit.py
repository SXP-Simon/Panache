# Copyright (c) 2026 Simon and Panache contributors.
"""2026-10-22：严格解析作业常见 CircuiTikZ 子集，不执行任意 TeX."""

from __future__ import annotations

import math
import re
from dataclasses import dataclass

if __package__:
    from .circuit_labels import normalize_circuit_label
else:
    from circuit_labels import normalize_circuit_label

_MAX_SOURCE = 32768
_MAX_SEGMENTS = 128
_MAX_LABEL = 256
_MAX_COORD = 1000
_COORD_DIMENSIONS = 2
_COMPONENTS = {
    "R": "R",
    "resistor": "R",
    "C": "C",
    "capacitor": "C",
    "L": "L",
    "inductor": "L",
    "V": "V",
    "vsource": "V",
    "I": "I",
    "isource": "I",
    "sV": "sV",
    "sinusoidal voltage source": "sV",
    "battery": "battery1",
    "battery1": "battery1",
    "D": "D",
    "diode": "D",
    "led": "led",
    "short": "short",
    "open": "open",
    "switch": "switch",
    "closing switch": "closing switch",
    "opening switch": "opening switch",
}
_MARKS = frozenset(("*-*", "o-o", "*-", "-*", "o-", "-o", "*-o", "o-*"))
_ANCHORS = frozenset(
    ("above", "below", "left", "right", "above left", "above right", "below left", "below right")
)
_STYLES = frozenset(("thin", "semithick", "thick"))
type Point = tuple[float, float]


@dataclass(frozen=True)
class CircuitLabel:
    """2026-10-22：元件旁的原始数学标签及显示方向."""

    text: str
    role: str = "l"
    side: int = 1
    direction: int = 0


@dataclass(frozen=True)
class CircuitSegment:
    """2026-10-22：带元件、端点标志和标注的有向支路."""

    start: Point
    end: Point
    kind: str = "short"
    labels: tuple[CircuitLabel, ...] = ()
    marks: str = ""


@dataclass(frozen=True)
class CircuitNode:
    """2026-10-22：连接点、接地或独立文字节点."""

    position: Point
    kind: str
    text: str = ""
    anchor: str = "above"


@dataclass(frozen=True)
class Circuit:
    """2026-10-22：限制大小的不可变电路拓扑."""

    segments: tuple[CircuitSegment, ...]
    nodes: tuple[CircuitNode, ...]
    american: bool = False

    @property
    def bounds(self) -> tuple[float, float, float, float]:
        """2026-10-22：拓扑外接范围，供上层限制整体缩放与像素预算."""
        points = [point for segment in self.segments for point in (segment.start, segment.end)]
        points.extend(node.position for node in self.nodes)
        if not points:
            return 0.0, 0.0, 0.0, 0.0
        return (
            min(point[0] for point in points),
            min(point[1] for point in points),
            max(point[0] for point in points),
            max(point[1] for point in points),
        )


class _InvalidCircuitError(ValueError):
    pass


def _split_options(source: str) -> list[str]:
    depth = 0
    start = 0
    parts: list[str] = []
    for index, char in enumerate(source):
        if char == "{" and (index == 0 or source[index - 1] != "\\"):
            depth += 1
        elif char == "}" and (index == 0 or source[index - 1] != "\\"):
            depth -= 1
        elif char == "," and depth == 0 and (index == 0 or source[index - 1] != "\\"):
            parts.append(source[start:index].strip())
            start = index + 1
        if depth < 0:
            raise _InvalidCircuitError
    if depth:
        raise _InvalidCircuitError
    parts.append(source[start:].strip())
    return [part for part in parts if part]


def _label(source: str) -> str:
    value = source.strip()
    if value.startswith("{") and value.endswith("}"):
        value = value[1:-1].strip()
    if value.startswith("$") and value.endswith("$"):
        value = value[1:-1].strip()
    elif value.startswith(r"\(") and value.endswith(r"\)"):
        value = value[2:-2].strip()
    if not value or len(value) > _MAX_LABEL or r"\begin" in value or r"\end" in value:
        raise _InvalidCircuitError
    normalized = normalize_circuit_label(value)
    if normalized is None:
        raise _InvalidCircuitError
    return normalized


class _Parser:
    def __init__(self, source: str) -> None:
        self.source = source
        self.index = 0
        self.names: dict[str, Point] = {}
        self.segments: list[CircuitSegment] = []
        self.nodes: list[CircuitNode] = []
        self.current: Point = (0.0, 0.0)
        self.reference: Point = (0.0, 0.0)
        self.origin: Point = (0.0, 0.0)
        self.rp_voltages = False

    def skip(self) -> None:
        while self.index < len(self.source) and self.source[self.index].isspace():
            self.index += 1

    def take(self, token: str) -> bool:
        self.skip()
        if not self.source.startswith(token, self.index):
            return False
        self.index += len(token)
        return True

    def group(self, opening: str, closing: str) -> str:
        if not self.take(opening):
            raise _InvalidCircuitError
        start = self.index
        depth = 1
        while self.index < len(self.source):
            char = self.source[self.index]
            escaped = self.index > 0 and self.source[self.index - 1] == "\\"
            if char == opening and not escaped:
                depth += 1
            elif char == closing and not escaped:
                depth -= 1
                if depth == 0:
                    value = self.source[start : self.index]
                    self.index += 1
                    return value
            self.index += 1
        raise _InvalidCircuitError

    def coordinate(self) -> Point:
        relative = 0
        if self.take("++"):
            relative = 2
        elif self.take("+"):
            relative = 1
        value = self.group("(", ")").strip()
        if value in self.names:
            if relative:
                raise _InvalidCircuitError
            point = self.names[value]
        else:
            parts = value.split(",")
            if len(parts) != _COORD_DIMENSIONS:
                raise _InvalidCircuitError
            try:
                x, y = (float(part.strip()) for part in parts)
            except ValueError as exc:
                raise _InvalidCircuitError from exc
            point = (x, y)
            if relative:
                point = (x + self.reference[0], y + self.reference[1])
        if not all(math.isfinite(number) and abs(number) <= _MAX_COORD for number in point):
            raise _InvalidCircuitError
        if relative != 1:
            self.reference = point
        return point

    def component_options(self, options: str) -> tuple[str, tuple[CircuitLabel, ...], str]:
        kind = ""
        marks = ""
        labels: list[CircuitLabel] = []
        for option in _split_options(options):
            component_key, assignment, component_value = option.partition("=")
            component_key = component_key.strip()
            if component_key in _COMPONENTS:
                if kind:
                    raise _InvalidCircuitError
                kind = _COMPONENTS[component_key]
                if assignment:
                    labels.append(CircuitLabel(_label(component_value)))
            elif option in _MARKS:
                if marks:
                    raise _InvalidCircuitError
                marks = option
            elif option in _STYLES:
                continue
            else:
                labels.append(self.component_label(option))
        kind = kind or "short"
        final_labels = tuple(self.label_direction(label, kind) for label in labels)
        return kind, final_labels, marks

    def component_label(self, option: str) -> CircuitLabel:
        if "=" not in option:
            raise _InvalidCircuitError
        key, value = (item.strip() for item in option.split("=", 1))
        if not re.fullmatch(r"[la](?:[_^])?|[iv](?:[_^][<>]?|[<>][_^]?)?", key):
            raise _InvalidCircuitError
        direction = -1 if "<" in key else 1 if ">" in key else 0
        if key[0] in "iv" and direction == 0 and not self.rp_voltages:
            raise _InvalidCircuitError
        return CircuitLabel(_label(value), key[0], -1 if "_" in key else 1, direction)

    @staticmethod
    def label_direction(label: CircuitLabel, kind: str) -> CircuitLabel:
        direction = label.direction
        if label.role == "i" and not direction:
            direction = -1 if kind in ("V", "sV", "battery1") else 1
        elif label.role == "v" and not direction:
            direction = 1 if kind in ("V", "sV", "battery1") else -1
        return CircuitLabel(label.text, label.role, label.side, direction)

    def add_segment(self, end: Point, options: str = "") -> None:
        kind, labels, marks = self.component_options(options)
        if self.current == end and kind != "open":
            raise _InvalidCircuitError
        self.segments.append(CircuitSegment(self.current, end, kind, labels, marks))
        self.current = end
        if len(self.segments) > _MAX_SEGMENTS:
            raise _InvalidCircuitError

    def node(self) -> None:
        self.skip()
        options = self.group("[", "]") if self.source.startswith("[", self.index) else ""
        self.skip()
        name = self.group("(", ")").strip() if self.source.startswith("(", self.index) else ""
        text = self.group("{", "}")
        kind = "label"
        anchor = "above"
        for option in _split_options(options):
            if option in ("ground", "rground", "circ", "ocirc"):
                if kind != "label":
                    raise _InvalidCircuitError
                kind = option
            elif option in _ANCHORS:
                anchor = option
            else:
                raise _InvalidCircuitError
        if name:
            if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]{0,63}", name) or name in self.names:
                raise _InvalidCircuitError
            self.names[name] = self.current
        if kind != "label" and text.strip():
            raise _InvalidCircuitError
        if text.strip() or kind != "label":
            self.nodes.append(
                CircuitNode(self.current, kind, _label(text) if text.strip() else "", anchor)
            )
        if len(self.nodes) > _MAX_SEGMENTS:
            raise _InvalidCircuitError

    def orthogonal(self, *, vertical_first: bool) -> None:
        end = self.coordinate()
        corner = (self.current[0], end[1]) if vertical_first else (end[0], self.current[1])
        if corner != self.current:
            self.add_segment(corner)
        if end != self.current:
            self.add_segment(end)

    def draw(self) -> None:
        self.skip()
        if self.source.startswith("[", self.index) and any(
            item not in _STYLES for item in _split_options(self.group("[", "]"))
        ):
            raise _InvalidCircuitError
        self.current = self.coordinate()
        self.origin = self.current
        while not self.take(";"):
            if self.take("node"):
                self.node()
            elif self.take("to"):
                self.skip()
                options = self.group("[", "]") if self.source.startswith("[", self.index) else ""
                self.add_segment(self.coordinate(), options)
            elif self.take("--"):
                self.add_segment(self.origin if self.take("cycle") else self.coordinate())
            elif self.take("|-"):
                self.orthogonal(vertical_first=True)
            elif self.take("-|"):
                self.orthogonal(vertical_first=False)
            else:
                raise _InvalidCircuitError

    def environment_options(self) -> bool:
        american = False
        self.skip()
        if self.source.startswith("[", self.index):
            for option in _split_options(self.group("[", "]")):
                if option in ("RPvoltages", "voltage dir=RP"):
                    self.rp_voltages = True
                elif option in ("american", "european", "american resistors", "european resistors"):
                    american = option.startswith("american")
                else:
                    raise _InvalidCircuitError
        return american

    def define_coordinate(self) -> None:
        name = self.group("(", ")").strip()
        if (
            not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]{0,63}", name)
            or name in self.names
            or not self.take("at")
        ):
            raise _InvalidCircuitError
        self.names[name] = self.coordinate()
        if not self.take(";"):
            raise _InvalidCircuitError

    def parse(self) -> Circuit:
        american = self.environment_options()
        while self.index < len(self.source):
            self.skip()
            if self.index == len(self.source):
                break
            if self.take(r"\draw"):
                self.draw()
            elif self.take(r"\coordinate"):
                self.define_coordinate()
            else:
                raise _InvalidCircuitError
        if not self.segments:
            raise _InvalidCircuitError
        return Circuit(tuple(self.segments), tuple(self.nodes), american)


def parse_circuit(source: str) -> Circuit | None:
    """2026-10-22：完整支持时返回电路；未知语法、过大输入和损坏源文返回 None."""
    if len(source) > _MAX_SOURCE:
        return None
    value = source.strip()
    opening, closing = r"\begin{circuitikz}", r"\end{circuitikz}"
    if not value.startswith(opening) or not value.endswith(closing):
        return None
    body = value[len(opening) : -len(closing)]
    # 2026-10-22：仅删除未转义百分号后的 TeX 注释，标签的百分号仍然保留。
    body = re.sub(r"(?<!\\)%[^\n]*", "", body)
    try:
        return _Parser(body).parse()
    except _InvalidCircuitError:
        return None
