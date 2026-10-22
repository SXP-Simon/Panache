//! 2026-10-22：共享作业电路语料及有界解析回归，不执行外部 TeX。
use handwriting_core::text::{self, Node, circuit};
fn env(body: &str) -> String {
    format!("{}{}{}", circuit::BEGIN, body, circuit::END)
}
#[test]
fn shared_circuit_fixtures_are_atomic() {
    let cases: serde_json::Value =
        serde_json::from_str(include_str!("fixtures/circuitikz.json")).unwrap();
    for case in cases.as_array().unwrap() {
        let source = case["source"].as_str().unwrap();
        let valid = case["valid"].as_bool().unwrap();
        assert_eq!(circuit::parse(source).is_some(), valid, "{}", case["id"]);
        if valid {
            let expected: &[&str] = match case["id"].as_str().unwrap() {
                "rc-lowpass" | "named-relative" | "component-shorthand" => &["C", "R", "V"],
                "rlc-ac" => &["C", "L", "R", "sV"],
                "parallel-current" => &["C", "I", "R"],
                "switch-capacitor" => &["C", "R", "battery1", "switch"],
                "diode-bridge" => &["D", "D", "D", "D", "R"],
                "orthogonal-ports" | "unit-labels" => &["C", "R"],
                "reverse-led" => &["R", "led"],
                "node-labels" => &["R"],
                _ => panic!("new fixture requires semantic assertion"),
            };
            let circuit = circuit::parse(source).unwrap();
            let mut actual: Vec<_> = circuit
                .segments
                .iter()
                .filter(|s| s.kind != "short")
                .map(|s| s.kind.as_str())
                .collect();
            actual.sort_unstable();
            assert_eq!(actual, expected, "{} topology", case["id"]);
        }
        let nodes = text::parse(source);
        assert_eq!(
            matches!(nodes.as_slice(), [Node::Circuit(_)]),
            valid,
            "{}",
            case["id"]
        );
        if !valid {
            let literal: String = nodes
                .iter()
                .map(|n| match n {
                    Node::Char(c) => *c,
                    Node::Newline => '\n',
                    _ => panic!("partial parsed circuit"),
                })
                .collect();
            assert_eq!(literal, source);
        }
    }
}
#[test]
fn relative_coordinates_reference_and_named_coordinates_remain_exact() {
    let source =
        env(r"\coordinate (a) at (1,2);\draw (a) -- +(2,0) -- +(0,2) -- ++(3,0) -- ++(0,3);");
    let circuit = circuit::parse(&source).unwrap();
    let ends: Vec<_> = circuit.segments.iter().map(|s| s.end).collect();
    assert_eq!(
        ends,
        vec![
            circuit::Point(3., 2.),
            circuit::Point(1., 4.),
            circuit::Point(4., 2.),
            circuit::Point(4., 5.)
        ]
    );
}
#[test]
fn unknown_topology_and_budgets_preserve_the_whole_environment() {
    for body in [
        r"\draw (0,0) to[R] (2,0);\foreach \x in{1}{x}",
        r"\draw (0,0) to[R,mirror] (2,0);",
        r"\draw (NaN,0) -- (2,0);",
        r"\draw (1001,0) -- (2,0);",
        r"\draw (0,0) to[R,l=$\unknown{a}$] (2,0);",
        r"\draw (0,0) -- (0,0);",
    ] {
        assert!(circuit::parse(&env(body)).is_none(), "{body}");
    }
    let segments = (0..129)
        .map(|i| format!("\\draw ({i},0) -- ({},0);", i + 1))
        .collect::<String>();
    assert!(circuit::parse(&env(&segments)).is_none());
    assert!(circuit::parse(&env(&" ".repeat(32768))).is_none());
}
#[test]
fn circuit_is_not_interpreted_inside_code_fences() {
    let source = format!("```tex\n{}\n```", env(r"\draw (0,0) to[R] (2,0);"));
    assert!(
        !text::parse(&source)
            .iter()
            .any(|n| matches!(n, Node::Circuit(_)))
    );
}
#[test]
fn comments_do_not_end_a_diagram_and_text_remains_around_it() {
    let source = format!(
        "Before\n{}\nAfter",
        env("% fake \\end{circuitikz}\n\\draw (0,0) to[R] (2,0);")
    );
    let nodes = text::parse(&source);
    assert_eq!(
        nodes
            .iter()
            .filter(|n| matches!(n, Node::Circuit(_)))
            .count(),
        1
    );
    assert!(matches!(nodes.first(), Some(Node::Char('B'))));
    assert!(matches!(nodes.last(), Some(Node::Char('r'))));
}
#[test]
fn source_and_label_directions_are_explicit_and_math_labels_normalize() {
    assert!(circuit::parse(&env(r"\draw (0,0) to[R,i=$i$,v=$u$] (4,0);")).is_none());
    let c = circuit::parse(&env(
        r"[RPvoltages]\draw (0,0) to[R,l=$R_{in}=\frac{1}{\omega C}$,i=$i$,v=$u$] (4,0);",
    ))
    .unwrap();
    assert_eq!(c.segments[0].labels[0].text, "R_(in)=(1)/(ω C)");
    assert_eq!(c.segments[0].labels[1].direction, 1.);
    assert_eq!(c.segments[0].labels[2].direction, -1.);
    let c = circuit::parse(&env(r"\draw (0,0) to[V,i^<=$i$,v_>=$u$] (4,0);")).unwrap();
    assert_eq!(c.segments[0].labels[0].direction, -1.);
    assert_eq!(c.segments[0].labels[1].direction, 1.);
}

#[test]
fn labels_support_bounded_units_degree_and_fraction_without_guessing() {
    for (raw, want) in [
        (r"\SI{4.7}{\kilo\ohm}", "4.7 kΩ"),
        (r"\si{\micro\farad}", "μF"),
        (r"45^\circ", "45°"),
        (r"\sqrt{R^2+X^2}", "√(R^(2)+X^(2))"),
        (r"R_{in}=\frac1{\omega C}", "R_(in)=(1)/(ω C)"),
    ] {
        let c = circuit::parse(&env(&format!(r"\draw (0,0) to[R,l=${raw}$] (4,0);"))).unwrap();
        assert_eq!(c.segments[0].labels[0].text, want, "{raw}");
    }
    for raw in [
        r"\SI{NaN}{\ohm}",
        r"\SI{inf}{\ohm}",
        r"\SI{1e3}{\ohm}",
        r"\si{\unknown}",
        r"\sqrt[3]{x}",
        r"\begin{array}{c}x\end{array}",
    ] {
        assert!(
            circuit::parse(&env(&format!(r"\draw (0,0) to[R,l=${raw}$] (4,0);"))).is_none(),
            "{raw}"
        );
    }
}

#[test]
fn component_equals_label_shorthand_keeps_values_and_rejects_conflicting_components() {
    let source = env(r"\draw (0,0) to[R=$R_1$] (3,0) to[C={$100\,\mathrm{nF}$}] (6,0);");
    let c = circuit::parse(&source).unwrap();
    assert_eq!(c.segments[0].kind, "R");
    assert_eq!(c.segments[0].labels[0].text, "R_(1)");
    assert_eq!(c.segments[1].kind, "C");
    assert_eq!(c.segments[1].labels[0].text, "100 nF");
    assert!(circuit::parse(&env(r"\draw (0,0) to[R=$R$,C] (3,0);")).is_none());
}

#[test]
fn greek_variants_remain_distinct_physics_variables() {
    let source = env(
        r"\draw (0,0) to[R,l=$\phi,\varphi,\epsilon,\varepsilon,\theta,\vartheta,\rho,\varrho$] (4,0);",
    );
    let c = circuit::parse(&source).unwrap();
    assert_eq!(c.segments[0].labels[0].text, "ϕ,φ,ϵ,ε,θ,ϑ,ρ,ϱ");
    let source = env(r"\draw (0,0) to[L,l=$\Phi_{m}+\Psi+\Theta+\Sigma+\psi+\eta$] (4,0);");
    let c = circuit::parse(&source).unwrap();
    assert_eq!(c.segments[0].labels[0].text, "Φ_(m)+Ψ+Θ+Σ+ψ+η");
}
