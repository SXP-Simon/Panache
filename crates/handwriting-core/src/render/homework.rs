//! 2026-10-24：作业笔记只派生正文版心和断行单元，不改原文或纸张背景。
use super::units::layout_units;
use crate::{Parameters, text::Node};

pub(super) fn parameters(source: &Parameters, width: u32, height: u32) -> Parameters {
    let mut p = source.clone();
    let available = width as f32 - p.left_margin - p.effective_right_margin();
    let inset = (available * 0.06).min(((available - p.font_size * 4.) / 2.).max(0.));
    p.left_margin += inset;
    p.right_margin += inset;
    if height as f32 - p.top_margin - p.bottom_margin >= p.line_spacing * 6. {
        p.top_margin += p.line_spacing;
        p.bottom_margin += p.line_spacing;
    }
    p
}

fn structural(node: &Node) -> bool {
    matches!(
        node,
        Node::Break | Node::Newline | Node::Image { .. } | Node::Table(_) | Node::Circuit(_)
    )
}

/// Count base units, keeping scripts attached to their base throughout the bounded lookahead.
fn cluster_len(units: &[&[Node]]) -> usize {
    let ascii_word = |unit: &[Node]| matches!(unit[0], Node::Char(c) if c.is_ascii_alphanumeric());
    if ascii_word(units[0]) {
        return units.iter().take(24).take_while(|u| ascii_word(u)).count();
    }
    let Node::Char(open @ ('(' | '[' | '（')) = units[0][0] else {
        return 1;
    };
    let close = match open {
        '(' => ')',
        '[' => ']',
        _ => '）',
    };
    let mut depth = 1;
    for (i, unit) in units.iter().enumerate().skip(1).take(24) {
        match &unit[0] {
            node if structural(node) => break,
            Node::Char(c) if *c == open => depth += 1,
            Node::Char(c) if *c == close => {
                depth -= 1;
                if depth == 0 {
                    return i + 1;
                }
            }
            _ => (),
        }
    }
    1
}

fn word_groups(mut units: &[&[Node]]) -> impl Iterator<Item = std::ops::Range<usize>> {
    let mut end = 0;
    std::iter::from_fn(move || {
        let first = units.first()?;
        let start = end;
        let (group, remaining) = units.split_at(cluster_len(units));
        end += group.iter().map(|unit| unit.len()).sum::<usize>();
        units = remaining;
        // Closing punctuation attaches to the preceding group, up to 64 source nodes.
        if !structural(&first[0]) {
            while end - start < 64
                && matches!(units.first(), Some(&[Node::Char(c)]) if "，。；：！？、,.!?;:)]）】".contains(*c))
            {
                end += 1;
                units = &units[1..];
            }
        }
        Some(start..end)
    })
}

pub(super) fn units(nodes: &[Node]) -> Vec<&[Node]> {
    let bases = layout_units(nodes);
    let mut groups = word_groups(&bases).peekable();
    let mut joined = Vec::new();
    while let Some(mut span) = groups.next() {
        if break_before(&nodes[span.clone()]) {
            // The relation, any spaces, and its first right-hand group wrap together.
            while let Some(space) = groups.next_if(|r| {
                nodes[r.clone()]
                    .iter()
                    .all(|n| matches!(n,Node::Char(c) if c.is_whitespace()))
            }) {
                span.end = space.end;
            }
            if let Some(rhs) = groups.next_if(|r| !structural(&nodes[r.start])) {
                span.end = rhs.end;
            }
        }
        joined.push(&nodes[span]);
    }
    joined
}
#[derive(Debug, Default)]
pub(super) struct Paragraph {
    pub indent: f32,
    pub prefix_chars: usize,
    pub gap_before: bool,
    pub title: bool,
}
pub(super) fn paragraph(units: &[&[Node]], font_size: f32) -> Paragraph {
    let chars: Vec<char> = units
        .iter()
        .flat_map(|u| u.iter())
        .take_while(|n| matches!(n, Node::Char(_)))
        .take(80)
        .filter_map(|n| {
            if let Node::Char(c) = n {
                Some(*c)
            } else {
                None
            }
        })
        .collect();
    let leading = chars.iter().take_while(|c| c.is_whitespace()).count();
    let text = &chars[leading..];
    let numeric = |c: &char| c.is_ascii_digit() || "一二三四五六七八九十百".contains(*c);
    let digits = text.iter().take_while(|c| numeric(c)).count();
    let decimal = matches!(text.get(digits), Some('.' | '．'))
        && text.get(digits + 1).is_some_and(char::is_ascii_digit);
    let top = digits > 0 && matches!(text.get(digits), Some('.' | '、' | '．')) && !decimal;
    let title = text.first() == Some(&'第') && text.iter().take(12).any(|c| *c == '题');
    let marker_end = text.iter().take(8).position(|c| matches!(c, ')' | '）'));
    let parenthesized = matches!(text.first(), Some('(' | '（'))
        && marker_end.is_some_and(|end| {
            end > 1
                && (text[1..end].iter().all(numeric) || (end == 2 && text[1].is_ascii_alphabetic()))
                && !text
                    .iter()
                    .skip(end + 1)
                    .find(|c| !c.is_whitespace())
                    .is_some_and(|c| "=＝+-*/∈≤≥≠≈⇒→↔⇔∧∨".contains(*c))
        });
    let bullet = matches!(text.first(), Some('•' | '·' | '*' | '-'))
        && text.get(1).is_some_and(|c| c.is_whitespace());
    let letter = text.first().is_some_and(|c| c.is_ascii_alphabetic()) && text.get(1) == Some(&')');
    let prefix = if top {
        digits + 1
    } else if parenthesized {
        text.iter().position(|c| matches!(c, ')' | '）')).unwrap() + 1
    } else if bullet {
        1
    } else if letter {
        2
    } else {
        0
    };
    let trailing = text
        .iter()
        .skip(prefix)
        .take_while(|c| c.is_whitespace())
        .count();
    Paragraph {
        indent: if (parenthesized || bullet || letter) && leading == 0 {
            font_size
        } else {
            0.
        },
        prefix_chars: if prefix > 0 {
            leading + prefix + trailing
        } else {
            0
        },
        gap_before: top || title,
        title,
    }
}
pub(super) fn break_before(unit: &[Node]) -> bool {
    matches!(unit.first(),Some(Node::Char(c)) if "=＝≤≥≠≈∈⇒→+".contains(*c))
}
pub(super) fn break_after(unit: &[Node]) -> bool {
    matches!(unit.last(),Some(Node::Char(c)) if c.is_whitespace() || "，。；：！？、,.!?;:".contains(*c))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::text;
    #[test]
    fn grouping_preserves_every_node_and_scripts_stay_attached() {
        for source in [
            "1. 测试 abcXYZ + x₁² = (a+b)/(c+d)，结束。",
            "(1) 条目及内容。",
            "⟦a | b; c | d⟧\n---\n最后一页",
            "((((((x)))))) = y + z",
            "value",
        ] {
            let nodes = text::parse(source);
            let grouped = units(&nodes);
            let flattened: Vec<_> = grouped.iter().flat_map(|u| u.iter().cloned()).collect();
            assert_eq!(flattened, nodes);
            assert!(
                grouped
                    .iter()
                    .all(|u| !matches!(u[0], Node::Scripts { .. }))
            );
        }
    }
    #[test]
    fn word_and_punctuation_limits_apply_before_joining_relations() {
        let source = format!("{}{}⇒  a，b\n。", "x".repeat(25), "，".repeat(64));
        let nodes = text::parse(&source);
        let groups = units(&nodes);
        assert_eq!(
            groups.iter().map(|g| g.len()).collect::<Vec<_>>(),
            [24, 64, 1, 5, 1, 1, 1]
        );
        assert_eq!(groups[3], text::parse("⇒  a，"));
    }
    #[test]
    fn paragraphs_identify_questions_and_subitems_without_guessing_equations() {
        for (source, sub, heading) in [
            ("1. 邻域", false, true),
            ("一、图论", false, true),
            ("第7题 DFA", false, true),
            ("(1) 共同近邻", true, false),
            ("a) 解答", true, false),
            ("- 步骤", true, false),
            ("x=1.5", false, false),
            ("(a+b)=c", false, false),
            ("3.5 m/s", false, false),
            ("0.25 = 1/4", false, false),
            ("(x) = 2", false, false),
            ("(1) + (2)", false, false),
            ("（A） ⇒ B", false, false),
        ] {
            let nodes = text::parse(source);
            let grouped = units(&nodes);
            let style = paragraph(&grouped, 30.);
            assert_eq!(style.indent > 0., sub, "{source}");
            assert_eq!(style.gap_before, heading, "{source}");
        }
    }
    #[test]
    fn relation_signs_and_spaced_right_hand_expressions_are_one_wrap_unit() {
        let nodes = text::parse("(8) (A→B)∧(C→D)∧(A∨C) ⇒ (B∨D)");
        let grouped = units(&nodes);
        let arrow = grouped
            .iter()
            .find(|u| matches!(u.first(), Some(Node::Char('⇒'))))
            .unwrap();
        assert!(arrow.iter().any(|n| matches!(n, Node::Char('B'))));
        assert!(arrow.iter().any(|n| matches!(n, Node::Char('D'))));
        let flat: Vec<_> = grouped.iter().flat_map(|u| u.iter().cloned()).collect();
        assert_eq!(flat, nodes);
    }
    #[test]
    fn body_insets_keep_rule_phase_and_leave_tiny_pages_usable() {
        let original = Parameters {
            font_size: 30.,
            line_spacing: 60.,
            left_margin: 50.,
            right_margin: 50.,
            top_margin: 40.,
            bottom_margin: 40.,
            ..Parameters::default()
        };
        let adjusted = parameters(&original, 800, 1000);
        assert!(adjusted.left_margin > original.left_margin);
        assert_eq!(adjusted.top_margin - original.top_margin, 60.);
        assert_eq!(adjusted.bottom_margin - original.bottom_margin, 60.);
        let tiny = parameters(&original, 160, 180);
        assert_eq!(tiny.left_margin, original.left_margin);
        assert_eq!(tiny.top_margin, original.top_margin);
    }
}
