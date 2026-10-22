# Copyright (c) 2026 Simon and Panache contributors.
"""2026-10-22：连贯细笔画电路几何；所有拓扑坐标共享同一变换，避免接线错位."""

from __future__ import annotations

import math
from dataclasses import dataclass
from itertools import pairwise
from typing import TYPE_CHECKING, Protocol

if TYPE_CHECKING:
    if __package__:
        from .circuit import Circuit, CircuitNode, CircuitSegment, Point
    else:
        from circuit import Circuit, CircuitNode, CircuitSegment, Point


class _Transform(Protocol):
    def __call__(self, x: float, y: float = 0) -> Point: ...


_MIN_PATH_POINTS = 2
_JOIN_TOLERANCE = 1e-9


@dataclass(frozen=True)
class CircuitStroke:
    """2026-10-22：等粗细连贯折线或采样曲线."""

    points: tuple[Point, ...]
    width: float


@dataclass(frozen=True)
class CircuitDisc:
    """2026-10-22：实心接点或空心端子."""

    center: Point
    radius: float
    filled: bool


@dataclass(frozen=True)
class PositionedLabel:
    """2026-10-22：数学标注的对齐锚点，父布局负责字体测量与最终外边界."""

    text: str
    position: Point
    anchor: str = "center"


@dataclass(frozen=True)
class CircuitLayout:
    """2026-10-22：左上为原点、纵轴向下的独立电路图元."""

    strokes: tuple[CircuitStroke, ...]
    discs: tuple[CircuitDisc, ...]
    labels: tuple[PositionedLabel, ...]
    width: float
    height: float


class _Geometry:
    def __init__(self) -> None:
        self.paths: list[tuple[Point, ...]] = []
        self.discs: list[CircuitDisc] = []
        self.labels: list[PositionedLabel] = []

    def line(self, *points: Point) -> None:
        if len(points) >= _MIN_PATH_POINTS:
            self.paths.append(tuple(points))

    def circle(self, center: Point, radius: float) -> None:
        self.paths.append(
            tuple(
                (
                    center[0] + radius * math.cos(step * math.tau / 48),
                    center[1] + radius * math.sin(step * math.tau / 48),
                )
                for step in range(49)
            )
        )

    def arrow(self, start: Point, end: Point) -> None:
        dx, dy = end[0] - start[0], end[1] - start[1]
        length = math.hypot(dx, dy)
        if length == 0:
            return
        ux, uy = dx / length, dy / length
        head = min(0.11, length * 0.35)
        self.line(start, end)
        self.line(
            (end[0] - ux * head - uy * head * 0.5, end[1] - uy * head + ux * head * 0.5),
            end,
            (end[0] - ux * head + uy * head * 0.5, end[1] - uy * head - ux * head * 0.5),
        )

    def node(self, node: CircuitNode) -> None:
        x, y = node.position
        if node.kind in ("circ", "ocirc"):
            self.discs.append(CircuitDisc(node.position, 0.055, node.kind == "circ"))
        elif node.kind in ("ground", "rground"):
            self.line((x, y), (x, y - 0.18))
            if node.kind == "ground":
                for index in range(3):
                    half = 0.21 - 0.065 * index
                    level = y - 0.18 - 0.09 * index
                    self.line((x - half, level), (x + half, level))
            else:
                self.line(
                    (x - 0.22, y - 0.18), (x, y - 0.43), (x + 0.22, y - 0.18), (x - 0.22, y - 0.18)
                )
        else:
            horizontal = -0.23 if "left" in node.anchor else 0.23 if "right" in node.anchor else 0
            vertical = -0.3 if "below" in node.anchor else 0.3 if "above" in node.anchor else 0
            anchor = (
                "right" if "left" in node.anchor else "left" if "right" in node.anchor else "center"
            )
            self.labels.append(PositionedLabel(node.text, (x + horizontal, y + vertical), anchor))


def _local(segment: CircuitSegment) -> tuple[float, _Transform]:
    dx = segment.end[0] - segment.start[0]
    dy = segment.end[1] - segment.start[1]
    length = math.hypot(dx, dy)
    ux, uy = (dx / length, dy / length) if length else (1.0, 0.0)
    center = ((segment.start[0] + segment.end[0]) / 2, (segment.start[1] + segment.end[1]) / 2)

    def point(x: float, y: float = 0) -> Point:
        return center[0] + ux * x - uy * y, center[1] + uy * x + ux * y

    return length, point


def _passive(
    geometry: _Geometry, kind: str, half: float, point: _Transform, *, american: bool
) -> None:
    if kind == "R":
        if american:
            geometry.line(
                *(
                    point(
                        -half + 2 * half * index / 8, 0 if index in (0, 8) else 0.16 * (-1) ** index
                    )
                    for index in range(9)
                )
            )
        else:
            geometry.line(
                point(-half, -0.16),
                point(half, -0.16),
                point(half, 0.16),
                point(-half, 0.16),
                point(-half, -0.16),
            )
    elif kind == "C":
        geometry.line(point(-half), point(-0.055))
        geometry.line(point(0.055), point(half))
        geometry.line(point(-0.055, -0.25), point(-0.055, 0.25))
        geometry.line(point(0.055, -0.25), point(0.055, 0.25))
    elif kind == "L":
        geometry.line(
            *(
                point(-half + 2 * half * step / 80, 0.22 * abs(math.sin(step / 80 * math.pi * 4)))
                for step in range(81)
            )
        )
    elif kind in ("D", "led"):
        geometry.line(point(-half), point(-0.16))
        geometry.line(point(0.16), point(half))
        geometry.line(point(-0.16, -0.22), point(0.16), point(-0.16, 0.22), point(-0.16, -0.22))
        geometry.line(point(0.16, -0.22), point(0.16, 0.22))
        if kind == "led":
            geometry.arrow(point(-0.02, 0.32), point(0.19, 0.53))
            geometry.arrow(point(0.15, 0.28), point(0.36, 0.49))


def _source(geometry: _Geometry, kind: str, half: float, point: _Transform) -> None:
    if kind == "battery1":
        geometry.line(point(-half), point(-0.07))
        geometry.line(point(0.07), point(half))
        geometry.line(point(-0.07, -0.13), point(-0.07, 0.13))
        geometry.line(point(0.07, -0.27), point(0.07, 0.27))
        return
    radius = min(0.32, half)
    geometry.line(point(-half), point(-radius))
    geometry.line(point(radius), point(half))
    geometry.circle(point(0), radius)
    if kind == "I":
        geometry.arrow(point(-radius * 0.58), point(radius * 0.58))
    elif kind == "sV":
        # 2026-10-22：正弦源内的交流记号保持水平，导线方向不应把波形转成竖直字母。
        center_x, center_y = point(0)
        geometry.line(
            *(
                (
                    center_x + radius * (-0.7 + 1.4 * step / 32),
                    center_y + radius * 0.34 * math.sin(step / 32 * math.tau),
                )
                for step in range(33)
            )
        )
    else:
        minus_x, minus_y = point(-radius * 0.45)
        plus_x, plus_y = point(radius * 0.45)
        arm = radius * 0.18
        geometry.line((minus_x - arm, minus_y), (minus_x + arm, minus_y))
        geometry.line((plus_x - arm, plus_y), (plus_x + arm, plus_y))
        geometry.line((plus_x, plus_y - arm), (plus_x, plus_y + arm))


def _switch(geometry: _Geometry, kind: str, half: float, point: _Transform) -> None:
    geometry.discs.extend(
        (
            CircuitDisc(point(-half, 0), 0.045, filled=False),
            CircuitDisc(point(half, 0), 0.045, filled=False),
        )
    )
    geometry.line(point(-half), point(half * 0.8, 0.25))
    if kind == "closing switch":
        geometry.arrow(point(0.05, 0.43), point(0.17, 0.24))
    elif kind == "opening switch":
        geometry.arrow(point(0.17, 0.24), point(0.05, 0.43))


def _segment(geometry: _Geometry, segment: CircuitSegment, *, american: bool) -> None:
    length, point = _local(segment)
    half = min(0.44, length * 0.3)
    if segment.kind == "short":
        geometry.line(segment.start, segment.end)
    elif segment.kind != "open":
        geometry.line(segment.start, point(-half))
        geometry.line(point(half), segment.end)
        if segment.kind in ("R", "C", "L", "D", "led"):
            _passive(geometry, segment.kind, half, point, american=american)
        elif segment.kind in ("V", "I", "sV", "battery1"):
            _source(geometry, segment.kind, half, point)
        else:
            _switch(geometry, segment.kind, half, point)
    if segment.marks:
        start_mark, end_mark = segment.marks.split("-", 1)
        for mark, position in ((start_mark, segment.start), (end_mark, segment.end)):
            if mark:
                geometry.discs.append(CircuitDisc(position, 0.055, mark == "*"))
    _labels(geometry, segment, length, half, point)


def _branch_anchor(segment: CircuitSegment, side: int) -> str:
    # 2026-10-22：非水平支路将文字向外对齐，避免长标注向元件内部伸展。
    vertical = segment.end[1] - segment.start[1]
    if abs(vertical) <= _JOIN_TOLERANCE:
        return "center"
    return "right" if vertical * side > 0 else "left"


def _labels(
    geometry: _Geometry, segment: CircuitSegment, length: float, half: float, point: _Transform
) -> None:
    lanes: dict[int, int] = {}
    for label in segment.labels:
        side = label.side if label.role != "a" else -label.side
        occupied = lanes.get(side, 0)
        anchor = _branch_anchor(segment, side)
        symbol_clearance = (
            0.85
            if side > 0 and segment.kind in ("led", "closing switch", "opening switch")
            else 0.48
        )
        offset = symbol_clearance + occupied * 0.55
        if label.role != "i":
            lanes[side] = occupied + 1
        if label.role == "i":
            direction = label.direction
            geometry.arrow(
                point(-length * 0.28 - direction * length * 0.1, side * 0.13),
                point(-length * 0.28 + direction * length * 0.1, side * 0.13),
            )
            geometry.labels.append(
                PositionedLabel(label.text, point(-length * 0.28, side * 0.43), anchor)
            )
        elif label.role == "v":
            geometry.arrow(
                point(-half * label.direction, side * (offset + 0.05)),
                point(half * label.direction, side * (offset + 0.05)),
            )
            geometry.labels.append(
                PositionedLabel(label.text, point(0, side * (offset + 0.34)), anchor)
            )
        else:
            geometry.labels.append(PositionedLabel(label.text, point(0, side * offset), anchor))


def _outside_intervals(start: Point, end: Point, disc: CircuitDisc) -> list[tuple[float, float]]:
    # 2026-10-22：解析线段与空心端子的交点，保留圆周之外的区段；不靠白色覆盖背景。
    dx, dy = end[0] - start[0], end[1] - start[1]
    ox, oy = start[0] - disc.center[0], start[1] - disc.center[1]
    square_length = dx * dx + dy * dy
    if square_length == 0:
        return []
    projection = ox * dx + oy * dy
    distance = ox * ox + oy * oy - disc.radius * disc.radius
    discriminant = projection * projection - square_length * distance
    if discriminant <= 0:
        return [(0.0, 1.0)] if distance >= 0 else []
    root = math.sqrt(discriminant)
    low = max(0.0, (-projection - root) / square_length)
    high = min(1.0, (-projection + root) / square_length)
    if high <= low:
        return [(0.0, 1.0)]
    intervals: list[tuple[float, float]] = []
    if low > 0:
        intervals.append((0.0, low))
    if high < 1:
        intervals.append((high, 1.0))
    return intervals


def _clip_path(path: tuple[Point, ...], disc: CircuitDisc) -> list[tuple[Point, ...]]:
    result: list[tuple[Point, ...]] = []
    current: list[Point] = []
    for start, end in pairwise(path):
        for low, high in _outside_intervals(start, end, disc):
            left = (start[0] + (end[0] - start[0]) * low, start[1] + (end[1] - start[1]) * low)
            right = (start[0] + (end[0] - start[0]) * high, start[1] + (end[1] - start[1]) * high)
            if current and math.dist(current[-1], left) > _JOIN_TOLERANCE:
                if len(current) >= _MIN_PATH_POINTS:
                    result.append(tuple(current))
                current = []
            if not current:
                current.append(left)
            current.append(right)
    if len(current) >= _MIN_PATH_POINTS:
        result.append(tuple(current))
    return result


def _clear_hollow_contacts(geometry: _Geometry) -> None:
    for disc in geometry.discs:
        if not disc.filled:
            geometry.paths = [part for path in geometry.paths for part in _clip_path(path, disc)]


_CIRCLE_POINTS = 49
_MIN_WOBBLE_DIST = 16.0


def handdrawn_stroke(points: tuple[Point, ...], unit: float) -> tuple[Point, ...]:
    """2026-10-22：在端点绝对重合的前提下引入自然的微小手绘起伏，保持粗细统一与接点精确."""
    if len(points) == _CIRCLE_POINTS:
        # 闭合圆形：保留中心与半径，以谐波正弦波产生圆润的手绘闭合圆
        segment_count = _CIRCLE_POINTS - 1
        cx = sum(p[0] for p in points[:-1]) / segment_count
        cy = sum(p[1] for p in points[:-1]) / segment_count
        r = math.hypot(points[0][0] - cx, points[0][1] - cy)
        seed = int((round(r, 2) * 89.0) * 10.0) & 0xFFFFFFFF
        p1 = ((seed % 1000) / 1000.0) * math.tau
        p2 = (((seed // 1000) % 1000) / 1000.0) * math.tau
        w_dev = max(0.4, min(1.2, r * 0.022))
        c_pts: list[Point] = []
        for i in range(segment_count):
            ang = i * math.tau / segment_count
            dr = (0.7 * math.sin(ang * 2.0 + p1) + 0.3 * math.sin(ang * 3.0 + p2)) * w_dev
            c_pts.append((cx + (r + dr) * math.cos(ang), cy + (r + dr) * math.sin(ang)))
        c_pts.append(c_pts[0])
        return tuple(c_pts)

    res: list[Point] = []
    max_dev = max(0.6, min(1.7, unit * 0.015))
    for idx in range(len(points) - 1):
        p1 = points[idx]
        p2 = points[idx + 1]
        dx = p2[0] - p1[0]
        dy = p2[1] - p1[1]
        dist = math.hypot(dx, dy)
        if dist < _MIN_WOBBLE_DIST:
            if not res:
                res.append(p1)
            res.append(p2)
            continue
        nx = -dy / dist
        ny = dx / dist
        seed_raw = (round(dist, 2) * 137.0 + round(dx, 2) * 31.0 + round(dy, 2) * 73.0) * 10.0
        seed = int(seed_raw) & 0xFFFFFFFF
        phase1 = ((seed % 1000) / 1000.0) * math.tau
        phase2 = (((seed // 1000) % 1000) / 1000.0) * math.tau
        dev = min(max_dev, dist * 0.015)
        steps = max(3, int(dist / 9.0))
        if not res:
            res.append(p1)
        for i in range(1, steps):
            t = i / steps
            envelope = math.sin(t * math.pi)
            wobble = (
                (
                    0.75 * math.sin(t * math.pi * 2.0 + phase1)
                    + 0.25 * math.sin(t * math.pi * 3.0 + phase2)
                )
                * envelope
                * dev
            )
            x = p1[0] + dx * t + nx * wobble
            y = p1[1] + dy * t + ny * wobble
            res.append((x, y))
        res.append(p2)
    return tuple(res)


def layout_circuit(circuit: Circuit, unit: float = 100.0) -> CircuitLayout:
    """2026-10-22：将电路整体缩放为像素图元，连线和端点始终共享精确坐标."""
    if not math.isfinite(unit) or unit <= 0:
        message = "unit must be positive and finite"
        raise ValueError(message)
    geometry = _Geometry()
    for segment in circuit.segments:
        _segment(geometry, segment, american=circuit.american)
    for node in circuit.nodes:
        geometry.node(node)
    _clear_hollow_contacts(geometry)
    points = [point for path in geometry.paths for point in path]
    points.extend(label.position for label in geometry.labels)
    points.extend(
        (disc.center[0] + sx * disc.radius, disc.center[1] + sy * disc.radius)
        for disc in geometry.discs
        for sx, sy in ((-1, -1), (1, 1))
    )
    if not points:
        points = [(0.0, 0.0)]
    left = min(point[0] for point in points) - 0.2
    top = max(point[1] for point in points) + 0.2
    width = (max(point[0] for point in points) - left + 0.2) * unit
    height = (top - min(point[1] for point in points) + 0.2) * unit

    def transform(point: Point) -> Point:
        return (point[0] - left) * unit, (top - point[1]) * unit

    return CircuitLayout(
        tuple(
            CircuitStroke(
                handdrawn_stroke(tuple(transform(point) for point in path), unit),
                max(1.0, unit * 0.019),
            )
            for path in geometry.paths
        ),
        tuple(
            CircuitDisc(transform(disc.center), disc.radius * unit, disc.filled)
            for disc in geometry.discs
        ),
        tuple(
            PositionedLabel(label.text, transform(label.position), label.anchor)
            for label in geometry.labels
        ),
        width,
        height,
    )
