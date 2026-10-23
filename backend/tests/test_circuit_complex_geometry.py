# Copyright (c) 2026 Simon and Panache contributors.
"""2026-10-23：复杂作业电路的手绘起伏不能破坏连接、源引脚与空心端子."""

from __future__ import annotations

import math
from itertools import pairwise

import pytest
from circuit import Circuit, CircuitNode, CircuitSegment
from circuit_layout import handdrawn_stroke, layout_circuit


def _segment_distance(point, start, end):
    dx, dy = end[0] - start[0], end[1] - start[1]
    denominator = dx * dx + dy * dy
    parameter = (
        max(0, min(1, ((point[0] - start[0]) * dx + (point[1] - start[1]) * dy) / denominator))
        if denominator
        else 0
    )
    return math.dist(point, (start[0] + parameter * dx, start[1] + parameter * dy))


@pytest.mark.parametrize("kind", ["V", "I", "sV"])
@pytest.mark.parametrize("angle", [0, 0.37, math.pi / 2, 2.1, math.pi, 5.6])
@pytest.mark.parametrize("unit", [6, 40, 100, 180])
def test_circular_sources_preserve_both_rotated_lead_contacts(kind, angle, unit):
    end = (4 * math.cos(angle), 4 * math.sin(angle))
    layout = layout_circuit(Circuit((CircuitSegment((0, 0), end, kind),), ()), unit)
    ring = next(stroke for stroke in layout.strokes if len(stroke.points) == 49)
    for lead in layout.strokes[2:4]:
        assert (
            min(
                math.dist(endpoint, point)
                for endpoint in (lead.points[0], lead.points[-1])
                for point in ring.points
            )
            < 1e-7
        )
    assert ring.points[0] == ring.points[-1]
    assert all(math.isfinite(value) for point in ring.points for value in point)


def test_49_point_open_path_remains_polyline_and_preserves_every_vertex():
    points = tuple((index * 20.0, 50 * math.sin(index / 4)) for index in range(49))
    result = handdrawn_stroke(points, 100)
    assert result[0] == points[0]
    assert result[-1] == points[-1]
    assert all(point in result for point in points)


def test_49_point_closed_non_circle_keeps_original_corners():
    points = tuple((index * 20.0, (index % 3) * 25.0) for index in range(48))
    points += (points[0],)
    result = handdrawn_stroke(points, 100)
    assert all(point in result for point in points)


@pytest.mark.parametrize("angle", [0, 0.37, 1.2, 2.5])
def test_handdrawn_circle_keeps_orientation_cardinal_contacts_and_natural_ink(angle):
    center = (120.0, 170.0)
    points = tuple(
        (
            center[0] + 40 * math.cos(angle + index * math.tau / 48),
            center[1] + 40 * math.sin(angle + index * math.tau / 48),
        )
        for index in range(49)
    )
    result = handdrawn_stroke(points, 100)
    assert result[0] == result[-1]
    assert all(result[index] == points[index] for index in (0, 12, 24, 36))
    assert any(math.dist(result[index], points[index]) > 0.01 for index in range(48))
    assert max(math.dist(a, b) for a, b in zip(points, result, strict=True)) <= 0.9


@pytest.mark.parametrize("unit", [0.1, 6, 24, 70, 100, 180])
@pytest.mark.parametrize("offset", [0, 0.02, 0.045, 0.0551, 0.056, 0.06])
def test_final_wavy_crossing_wires_never_enter_hollow_terminal(unit, offset):
    circuit = Circuit(
        (
            CircuitSegment((-3, offset), (3, offset)),
            CircuitSegment((offset, -3), (offset, 3)),
            CircuitSegment((-3, -3 + offset), (3, 3 + offset)),
            CircuitSegment((3, -3 + offset), (-3, 3 + offset)),
        ),
        (CircuitNode((0, 0), "ocirc"),),
    )
    layout = layout_circuit(circuit, unit)
    terminal = layout.discs[0]
    for stroke in layout.strokes:
        for start, end in pairwise(stroke.points):
            assert _segment_distance(terminal.center, start, end) >= terminal.radius - 1e-7


@pytest.mark.parametrize("unit", [0.1, 6, 70, 100, 180])
def test_switch_clipping_keeps_hinge_hollow_for_diagonal_and_reversed_branches(unit):
    circuit = Circuit(
        (
            CircuitSegment((0, 0), (4, 3), "switch"),
            CircuitSegment((4, 6), (0, 3), "closing switch"),
        ),
        (),
    )
    layout = layout_circuit(circuit, unit)
    for disc in layout.discs:
        for stroke in layout.strokes:
            for start, end in pairwise(stroke.points):
                assert _segment_distance(disc.center, start, end) >= disc.radius - 1e-7


def test_junctions_and_inductor_vertices_keep_exact_connection_under_wobble():
    circuit = Circuit(
        (
            CircuitSegment((0, 0), (0, 4), "L"),
            CircuitSegment((0, 4), (4, 4), "R"),
            CircuitSegment((4, 4), (0, 0)),
            CircuitSegment((0, 4), (-3, 5)),
        ),
        (CircuitNode((0, 4), "circ"),),
    )
    layout = layout_circuit(circuit, 100)
    junction = layout.discs[0].center
    assert sum(junction in stroke.points for stroke in layout.strokes) == 3
    assert len({stroke.width for stroke in layout.strokes}) == 1
    assert all(
        0 <= x <= layout.width and 0 <= y <= layout.height
        for stroke in layout.strokes
        for x, y in stroke.points
    )


def test_natural_geometry_is_deterministic_and_translation_invariant():
    points = ((0.0, 0.0), (230.0, 160.0), (100.0, 300.0))
    first = handdrawn_stroke(points, 100)
    assert first == handdrawn_stroke(points, 100)
    shifted = handdrawn_stroke(tuple((x + 300, y - 200) for x, y in points), 100)
    for actual, expected in zip(shifted, first, strict=True):
        assert actual == pytest.approx((expected[0] + 300, expected[1] - 200))


@pytest.mark.parametrize("unit", [24, 70, 100, 180])
@pytest.mark.parametrize("position", [0.31, 1.17, 2.23])
@pytest.mark.parametrize("diagonal", [False, True])
def test_unmarked_interior_t_junction_stays_exactly_connected(unit, position, diagonal):
    junction = (position, position if diagonal else 0)
    circuit = Circuit(
        (
            CircuitSegment((0, 0), (4, 4 if diagonal else 0)),
            CircuitSegment(junction, (position, 5)),
            CircuitSegment((4, 4 if diagonal else 0), (0, 0)),
        ),
        (),
    )
    layout = layout_circuit(circuit, unit)
    stem = layout.strokes[1].points[0]
    assert stem in layout.strokes[0].points
    assert stem in layout.strokes[2].points


@pytest.mark.parametrize("unit", [24, 70, 100, 180])
@pytest.mark.parametrize("side", [-1, 1])
def test_wobble_near_tangent_wire_does_not_fill_off_center_port(unit, side):
    circuit = Circuit(
        (CircuitSegment((-0.5, side * 0.055), (0.5, side * 0.055)),),
        (CircuitNode((0.3, 0), "ocirc"),),
    )
    layout = layout_circuit(circuit, unit)
    disc = layout.discs[0]
    for stroke in layout.strokes:
        for start, end in pairwise(stroke.points):
            assert _segment_distance(disc.center, start, end) >= disc.radius - 1e-7
