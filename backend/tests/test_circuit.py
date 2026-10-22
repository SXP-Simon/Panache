# Copyright (c) 2026 Simon and Panache contributors.
"""2026-10-22：电路子集的跨端样例、语义、拓扑和边界回归."""

import json
import math
from pathlib import Path

import pytest
from circuit import Circuit, parse_circuit
from circuit_labels import normalize_circuit_label
from circuit_layout import layout_circuit

_FIXTURES = json.loads(
    (Path(__file__).parents[2] / "e2e/fixtures/circuitikz.json").read_text(encoding="utf-8")
)
_COMPONENTS = (
    "R",
    "C",
    "L",
    "V",
    "I",
    "sV",
    "battery1",
    "D",
    "led",
    "short",
    "open",
    "switch",
    "closing switch",
    "opening switch",
)


def _parse(body, options="") -> Circuit:
    result = parse_circuit(r"\begin{circuitikz}" + options + body + r"\end{circuitikz}")
    assert result is not None
    return result


def test_variant_labels_remain_distinct_and_match_course_formula_conventions():
    source = r"\phi+\varphi+\epsilon+\varepsilon+\theta+\vartheta+\rho+\varrho"
    assert normalize_circuit_label(source) == "\u03d5+φ+\u03f5+ε+θ+\u03d1+\u03c1+\u03f1"
    assert normalize_circuit_label(r"\Phi+\Psi+\Theta+\Sigma+\eta+\nu+\psi") == (
        "\u03a6+\u03a8+\u0398+\u03a3+\u03b7+\u03bd+\u03c8"
    )


@pytest.mark.parametrize("case", _FIXTURES, ids=lambda case: case["id"])
def test_shared_cross_platform_conformance(case):
    circuit = parse_circuit(case["source"])
    assert (circuit is not None) is case["valid"]
    if circuit is not None:
        layout = layout_circuit(circuit)
        assert layout.width > 0
        assert layout.height > 0
        assert layout.strokes or layout.discs


@pytest.mark.parametrize("kind", _COMPONENTS)
@pytest.mark.parametrize(
    ("start", "end"), [((0, 0), (4, 0)), ((4, 0), (0, 0)), ((0, 0), (0, 4)), ((0, 0), (3, 4))]
)
def test_all_components_geometry_is_finite_and_bounded(kind, start, end):
    circuit = _parse(f"\\draw {start} to[{kind},l=$X_1$,*-o] {end};")
    layout = layout_circuit(circuit, 80)
    assert all(
        math.isfinite(number)
        for stroke in layout.strokes
        for point in stroke.points
        for number in point
    )
    assert len({stroke.width for stroke in layout.strokes}) <= 1
    assert [disc.filled for disc in layout.discs[-2:]] == [True, False]
    assert layout.labels[0].text == "X_(1)"
    for stroke in layout.strokes:
        assert all(
            0 <= point[0] <= layout.width and 0 <= point[1] <= layout.height
            for point in stroke.points
        )


def test_coordinate_reference_and_relative_semantics():
    circuit = _parse(r"\draw (1,2) -- +(2,0) -- +(0,2) -- ++(1,0) -- ++(0,1);")
    assert [part.end for part in circuit.segments] == [(3, 2), (1, 4), (2, 2), (2, 3)]
    assert all(
        a.end == b.start for a, b in zip(circuit.segments, circuit.segments[1:], strict=False)
    )


def test_orthogonal_and_closed_paths_keep_exact_connections():
    circuit = _parse(r"\coordinate (a) at (0,0); \draw (a) |- (2,3) -| (4,0) -- cycle;")
    assert [part.end for part in circuit.segments] == [(0, 3), (2, 3), (4, 3), (4, 0), (0, 0)]
    assert circuit.segments[-1].end == circuit.segments[0].start


def test_ground_and_named_node_do_not_break_next_path():
    circuit = _parse(
        r"\draw (0,0) node[ground]{} to[R] (0,3) node[circ] (a) {}; \draw (a) to[C] (4,3);"
    )
    assert circuit.segments[1].start == (0, 3)
    assert [node.kind for node in circuit.nodes] == ["ground", "circ"]


@pytest.mark.parametrize(
    ("key", "direction"), [("i>", 1), ("i<", -1), ("i^>", 1), ("i_<", -1), ("v^<", -1), ("v_>", 1)]
)
def test_explicit_arrow_directions_are_path_relative(key, direction):
    circuit = _parse(f"\\draw (4,0) to[R,{key}=$x$] (0,0);")
    assert circuit.segments[0].labels[0].direction == direction


@pytest.mark.parametrize(
    ("kind", "i_direction", "v_direction"),
    [("R", 1, -1), ("C", 1, -1), ("V", -1, 1), ("battery1", -1, 1), ("I", 1, -1)],
)
def test_rising_potential_convention(kind, i_direction, v_direction):
    circuit = _parse(f"\\draw (0,0) to[{kind},i=$i$,v=$u$] (4,0);", "[RPvoltages]")
    assert [label.direction for label in circuit.segments[0].labels] == [i_direction, v_direction]


@pytest.mark.parametrize("key", ["i", "i_", "v", "v^"])
def test_implicit_arrow_without_declared_convention_preserves_source(key):
    assert (
        parse_circuit(
            r"\begin{circuitikz}\draw (0,0) to[R," + key + r"=$x$] (4,0);\end{circuitikz}"
        )
        is None
    )


@pytest.mark.parametrize(
    ("source", "expected"),
    [
        (r"R_1", "R_(1)"),
        (r"V_{out}", "V_(out)"),
        (r"x^{n+1}", "x^(n+1)"),
        (r"\frac1{j\omega C}", "(1)/(jω C)"),
        (r"\sqrt{LC}", "√(LC)"),
        (r"4.7\,\mathrm{k\Omega}", "4.7 kΩ"),
        (r"\SI{4.7}{\kilo\ohm}", "4.7 kΩ"),
        (r"\si{\micro\farad}", "μF"),
        (r"30^\circ", "30°"),
        (r"\text{in}", "in"),
        (r"\frac{V_{in}}{R_1}", "(V_(in))/(R_(1))"),
    ],
)
def test_supported_label_normalization(source, expected):
    assert normalize_circuit_label(source) == expected


@pytest.mark.parametrize(
    "source",
    [
        r"\custom{R}",
        r"\begin{array}x\end{array}",
        r"\SI{4.7}{\customunit}",
        r"x_{",
        r"x^",
        r"\sqrt[3]{x}",
        r"\text{" * 20 + "x" + "}" * 20,
    ],
)
def test_unknown_or_malformed_labels_do_not_silently_drop_semantics(source):
    assert normalize_circuit_label(source) is None


@pytest.mark.parametrize(
    "body",
    [
        r"\draw (NaN,0)--(1,0);",
        r"\draw (inf,0)--(1,0);",
        r"\draw (1001,0)--(1,0);",
        r"\draw (0,0) to[R] (0,0);",
        r"\draw (0,0) to[R,C] (2,0);",
        r"\draw (0,0) to[R,mirror] (2,0);",
        r"\draw (0,0) to[R,l=$\unknown$] (2,0);",
        r"\draw (0,0) to[R] (2,0)",
        r"\draw (0,0) to[R] (2,0); evil",
        r"\coordinate (a) at (0,0);\coordinate (a) at (1,1);\draw(a)--(2,0);",
    ],
)
def test_malformed_or_unsupported_entire_environment_is_rejected(body):
    assert parse_circuit(r"\begin{circuitikz}" + body + r"\end{circuitikz}") is None


def test_budget_limits_and_escaped_label_percent():
    assert parse_circuit(r"\begin{circuitikz}" + " " * 32768 + r"\end{circuitikz}") is None
    assert (
        parse_circuit(r"\begin{circuitikz}\draw (0,0)" + "-- ++(1,0)" * 129 + r";\end{circuitikz}")
        is None
    )
    circuit = _parse("% hello\n" + r"\draw (0,0) to[R,l=$10\%$] (3,0); % trailing" + "\n")
    assert circuit.segments[0].labels[0].text == "10%"


def test_normalized_geometry_is_translation_invariant_and_scales_uniformly():
    first = _parse(r"\draw (0,0) to[R,*-o,l=$R$] (4,0);")
    moved = _parse(r"\draw (100,200) to[R,*-o,l=$R$] (104,200);")
    a, b = layout_circuit(first, 80), layout_circuit(moved, 80)
    assert a.width == pytest.approx(b.width)
    assert a.height == pytest.approx(b.height)
    for one, two in zip(a.strokes, b.strokes, strict=True):
        for point_a, point_b in zip(one.points, two.points, strict=True):
            assert point_a == pytest.approx(point_b)
    doubled = layout_circuit(first, 160)
    assert doubled.width == pytest.approx(a.width * 2)
    assert doubled.height == pytest.approx(a.height * 2)
    assert doubled.labels[0].position == pytest.approx(
        tuple(value * 2 for value in a.labels[0].position)
    )


def test_voltage_source_polarity_rotates_location_but_signs_remain_upright():
    for start, end in (((0, 0), (4, 0)), ((4, 0), (0, 0)), ((0, 0), (0, 4))):
        layout = layout_circuit(_parse(f"\\draw {start} to[V] {end};"), 100)
        minus, plus_h, plus_v = layout.strokes[-3:]
        assert minus.points[0][1] == minus.points[1][1]
        assert plus_h.points[0][1] == plus_h.points[1][1]
        assert plus_v.points[0][0] == plus_v.points[1][0]
        minus_center = tuple(sum(point[index] for point in minus.points) / 2 for index in (0, 1))
        plus_center = tuple(sum(point[index] for point in plus_h.points) / 2 for index in (0, 1))
        path_dx, path_dy = end[0] - start[0], -(end[1] - start[1])
        assert (plus_center[0] - minus_center[0]) * path_dx + (
            plus_center[1] - minus_center[1]
        ) * path_dy > 0


@pytest.mark.parametrize("unit", [0, -1, math.inf, math.nan])
def test_invalid_layout_unit_is_rejected(unit):
    with pytest.raises(ValueError, match="positive and finite"):
        layout_circuit(_parse(r"\draw (0,0) to[R] (4,0);"), unit)


def test_hollow_terminals_and_switch_contacts_have_no_wire_through_center():
    circuit = _parse(
        r"\draw (0,0) to[short,o-o] (2,0) to[switch] (5,0); \draw (7,0) -- (9,0) node[ocirc]{};"
    )
    layout = layout_circuit(circuit, 100)
    assert len(layout.discs) == 5
    for disc in layout.discs:
        assert not disc.filled
        for stroke in layout.strokes:
            for point in stroke.points:
                assert math.dist(point, disc.center) >= disc.radius - 1e-7


def test_multiple_label_roles_get_distinct_lanes():
    circuit = _parse(r"\draw (0,0) to[R,l=$R$,v^>=$u$] (4,0);")
    layout = layout_circuit(circuit, 100)
    resistor, voltage = layout.labels
    assert resistor.text == "R"
    assert voltage.text == "u"
    assert abs(resistor.position[1] - voltage.position[1]) > 50


def test_bounds_include_named_node_and_reversed_branches():
    circuit = _parse(r"\draw (5,7) to[R] (-2,-3) node[above]{$A$};")
    assert circuit.bounds == (-2, -3, 5, 7)


@pytest.mark.parametrize("kind", ["led", "closing switch", "opening switch"])
def test_ornamented_symbols_leave_clearance_for_component_labels(kind):
    circuit = _parse(f"\\draw (0,0) to[{kind},l=$X$] (4,0);")
    layout = layout_circuit(circuit, 100)
    label_y = layout.labels[0].position[1]
    assert all(point[1] > label_y + 20 for stroke in layout.strokes for point in stroke.points)


@pytest.mark.parametrize(
    ("start", "end", "key", "expected_anchor"),
    [
        ((0, 0), (0, 4), "l", "right"),
        ((0, 4), (0, 0), "l", "left"),
        ((0, 0), (0, 4), "l_", "left"),
        ((0, 4), (0, 0), "l_", "right"),
        ((0, 0), (3, 4), "l", "right"),
        ((3, 4), (0, 0), "l", "left"),
        ((0, 0), (4, 0), "l", "center"),
        ((4, 0), (0, 0), "l_", "center"),
    ],
)
@pytest.mark.parametrize("text", [r"u_{in}(t)", r"100\,\mathrm{k\Omega}"])
def test_long_labels_align_outward_for_vertical_and_diagonal_branches(
    start, end, key, expected_anchor, text
):
    circuit = _parse(f"\\draw {start} to[V,{key}=${text}$] {end};")
    layout = layout_circuit(circuit, 100)
    label = layout.labels[0]
    assert label.anchor == expected_anchor
    if expected_anchor != "center":
        # 2026-10-22：圆形源的中心由闭合圆路径得到，标注靠近电路的一侧不随文字长度变化。
        circle = next(stroke for stroke in layout.strokes if len(stroke.points) == 49)
        center_x = sum(point[0] for point in circle.points[:-1]) / 48
        if expected_anchor == "right":
            assert label.position[0] < center_x
        else:
            assert label.position[0] > center_x


@pytest.mark.parametrize("key", ["i^>", "v^>", "a_"])
def test_all_annotation_roles_use_outward_anchor_on_vertical_paths(key):
    circuit = _parse(r"\draw (0,0) to[R," + key + r"=$long_{label}$] (0,4);")
    assert layout_circuit(circuit).labels[0].anchor == "right"


@pytest.mark.parametrize(
    ("alias", "kind"),
    [
        ("R", "R"),
        ("resistor", "R"),
        ("C", "C"),
        ("L", "L"),
        ("V", "V"),
        ("I", "I"),
        ("sV", "sV"),
        ("battery1", "battery1"),
        ("battery", "battery1"),
        ("diode", "D"),
        ("led", "led"),
        ("closing switch", "closing switch"),
    ],
)
@pytest.mark.parametrize("reverse", [False, True])
def test_component_value_shorthand_preserves_kind_value_and_direction(alias, kind, reverse):
    start, end = ((4, 0), (0, 0)) if reverse else ((0, 0), (4, 0))
    circuit = _parse(f"\\draw {start} to[{alias}=$R_1$,*-o] {end};")
    segment = circuit.segments[0]
    assert segment.kind == kind
    assert segment.start == start
    assert segment.end == end
    assert segment.labels[0].text == "R_(1)"
    assert segment.labels[0].role == "l"
    assert segment.labels[0].direction == 0


def test_component_value_shorthand_balances_nested_comma_label():
    circuit = _parse(r"\draw (0,0) to[R={$\frac{R_{a,b}}{2}$}] (4,0) to[C=100 nF] (8,0);")
    assert circuit.segments[0].labels[0].text == "(R_(a,b))/(2)"
    assert circuit.segments[1].labels[0].text == "100 nF"


@pytest.mark.parametrize(
    "options",
    ["R,C=100 nF", "R=$R$,R", "R=10,R=20", "unknown=4", "C=", r"R=$\unknown$"],
)
def test_component_value_shorthand_rejects_conflict_or_unknown_value(options):
    source = r"\begin{circuitikz}\draw (0,0) to[" + options + r"] (4,0);\end{circuitikz}"
    assert parse_circuit(source) is None
