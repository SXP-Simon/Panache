# Copyright (c) 2026 Simon and Panache contributors.
"""2026-10-23：真实多支路作业的拓扑、节点解与功率校验."""

import json
from collections import Counter
from fractions import Fraction
from pathlib import Path

import pytest
from circuit import parse_circuit
from circuit_layout import layout_circuit

CASES = json.loads(
    (Path(__file__).resolve().parents[2] / "e2e/fixtures/realistic-circuits.json").read_text(
        encoding="utf-8"
    )
)


@pytest.mark.parametrize("case", CASES, ids=lambda case: case["id"])
def test_realistic_networks_keep_every_physical_component(case):
    circuit = parse_circuit(case["source"])
    assert circuit is not None
    assert Counter(s.kind for s in circuit.segments if s.kind != "short") == case["components"]
    layout = layout_circuit(circuit, 40)
    assert layout.width > 0
    assert layout.height > 0
    assert len(layout.labels) >= sum(case["components"].values())


def test_dc_homework_solution_satisfies_both_kcl_and_power():
    va, vb = Fraction(27, 5), Fraction(24, 5)
    i1, i2, i3, i4 = (12 - va) / 2, va / 2, va - vb, vb / 3
    assert i1 == i2 + i3
    assert i3 + 1 == i4
    assert (
        12 * i1 + vb
        == sum(
            current * current * resistance
            for current, resistance in [(i1, 2), (i2, 2), (i3, 1), (i4, 3)]
        )
        == Fraction(222, 5)
    )


def test_loaded_bridge_solution_does_not_assume_independent_dividers():
    va, vb = Fraction(40, 7), Fraction(30, 7)
    i1, i2, i3, i4, i5 = 10 - va, va / 2, (10 - vb) / 2, vb, va - vb
    assert i1 == i2 + i5
    assert i3 + i5 == i4
    assert 10 * (i1 + i3) == sum(
        current * current * resistance
        for current, resistance in [(i1, 1), (i2, 2), (i3, 2), (i4, 1), (i5, 1)]
    )


def test_loaded_rc_response_obeys_both_frequency_domain_node_equations():
    st = 1j
    h = 1 / (st * st + 3 * st + 1)
    u1 = (1 + st) * h
    assert abs((2 + st) * u1 - h - 1) < 1e-12
    assert abs(-u1 + (1 + st) * h) < 1e-12
    assert abs(h + 1j / 3) < 1e-12
