//! 2026-10-20：仅识别带一致分隔规则的可读矩阵协议，普通括号与歧义输入保留原文。
use super::{Table, TableRule, parse_inline};

fn split_top(source: &[char], delimiter: char) -> Option<Vec<String>> {
    let mut stack = Vec::new();
    let mut parts = Vec::new();
    let mut start = 0;
    let mut quoted = false;
    let mut escaped = false;
    for (index, &c) in source.iter().enumerate() {
        if quoted {
            if escaped {
                escaped = false;
            } else if c == '\\' {
                escaped = true;
            } else if c == '"' {
                quoted = false;
            }
            continue;
        }
        if c == '"' {
            quoted = true;
            continue;
        }
        match c {
            '(' => stack.push(')'),
            '[' => stack.push(']'),
            '⟦' => stack.push('⟧'),
            '{' => stack.push('}'),
            ')' | ']' | '}' | '⟧' if stack.pop() != Some(c) => return None,
            _ => (),
        }
        if c == delimiter && stack.is_empty() {
            parts.push(source[start..index].iter().collect());
            start = index + 1;
        }
    }
    if !stack.is_empty() || quoted {
        return None;
    }
    parts.push(source[start..].iter().collect());
    Some(parts)
}

fn cells(row: &str) -> Option<(Vec<String>, Vec<TableRule>)> {
    let chars: Vec<_> = row.chars().collect();
    let mut values = Vec::new();
    let mut boundaries = vec![TableRule::None];
    let mut stack = Vec::new();
    let mut current = String::new();
    let mut i = 0;
    let mut after_rule = false;
    let mut trailing_cell = false;
    let mut quoted = false;
    let mut escaped = false;
    while i < chars.len() {
        let c = chars[i];
        if quoted || c == '"' {
            current.push(c);
            if quoted {
                if escaped {
                    escaped = false;
                } else if c == '\\' {
                    escaped = true;
                } else if c == '"' {
                    quoted = false;
                }
            } else {
                quoted = true;
            }
            after_rule = false;
            i += 1;
            continue;
        }
        if stack.is_empty() && (c == '|' || c == '┆') {
            let left_padding = current.ends_with(' ');
            if !current.is_empty() && !left_padding {
                return None;
            }
            if chars.get(i + 1).is_some_and(|c| *c != ' ') {
                return None;
            }
            if current.ends_with(' ') {
                current.pop();
            }
            if !current.is_empty() || !values.is_empty() || left_padding {
                values.push(current.trim().to_owned());
                boundaries.push(TableRule::None);
            } else if after_rule {
                return None;
            }
            let last = boundaries.last_mut()?;
            if *last != TableRule::None {
                return None;
            }
            *last = if c == '|' {
                TableRule::Solid
            } else {
                TableRule::Dashed
            };
            current.clear();
            after_rule = true;
            i += 1;
            trailing_cell = chars.get(i) == Some(&' ');
            if chars.get(i) == Some(&' ') {
                i += 1;
            }
            continue;
        }
        if stack.is_empty() && c == ' ' && chars.get(i + 1) == Some(&' ') {
            values.push(current.trim().to_owned());
            boundaries.push(TableRule::None);
            current.clear();
            after_rule = false;
            i += 2;
            continue;
        }
        match c {
            '(' => stack.push(')'),
            '[' => stack.push(']'),
            '⟦' => stack.push('⟧'),
            '{' => stack.push('}'),
            ')' | ']' | '}' | '⟧' if stack.pop() != Some(c) => return None,
            _ => (),
        }
        if !c.is_whitespace() {
            after_rule = false;
        }
        current.push(c);
        i += 1;
    }
    if !stack.is_empty() || quoted {
        return None;
    }
    if !after_rule || trailing_cell {
        values.push(current.trim().to_owned());
        boundaries.push(TableRule::None);
    }
    let values = values
        .into_iter()
        .map(|value| {
            if value.starts_with('"') {
                serde_json::from_str::<String>(&value).ok()
            } else if value.contains('"') {
                None
            } else {
                Some(value)
            }
        })
        .collect::<Option<Vec<_>>>()?;
    Some((values, boundaries))
}

pub(super) fn parse(source: &[char], depth: usize) -> Option<Table> {
    if source.len() > 16_000 || depth > 20 {
        return None;
    }
    let pieces = split_top(source, ';')?;
    let mut rows = Vec::new();
    let mut vertical = None;
    let mut horizontal = vec![TableRule::None];
    let mut has_rule = false;
    for piece in pieces {
        let rule = match piece.trim() {
            "──" => TableRule::Solid,
            "╌╌" => TableRule::Dashed,
            _ => TableRule::None,
        };
        if rule != TableRule::None {
            let last = horizontal.last_mut()?;
            if *last != TableRule::None {
                return None;
            }
            *last = rule;
            has_rule = true;
            continue;
        }
        let piece = piece.strip_prefix(' ').unwrap_or(&piece);
        let piece = piece.strip_suffix(' ').unwrap_or(piece);
        let (values, rules) = cells(piece)?;
        if !(1..=32).contains(&values.len()) || rows.len() >= 32 {
            return None;
        }
        has_rule |= rules.iter().any(|r| *r != TableRule::None);
        if let Some(previous) = &vertical {
            if previous != &rules {
                return None;
            }
        } else {
            vertical = Some(rules);
        }
        let row: Vec<_> = values.iter().map(|s| parse_inline(s, depth + 1)).collect();
        if row
            .iter()
            .flatten()
            .any(|node| matches!(node, super::Node::Image { .. }))
        {
            return None;
        }
        rows.push(row);
        horizontal.push(TableRule::None);
    }
    if rows.len() < 2 || !has_rule {
        return None;
    }
    Some(Table {
        rows,
        vertical: vertical?,
        horizontal,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::text::{self, Node};

    #[test]
    fn distribution_rows_cells_rules_and_english_spacing_are_structural() {
        for source in [
            "⟦ X | 0  1  2  3 ; ── ; P | (8)/(15)  (4)/(15)  (2)/(15)  (1)/(15) ⟧",
            "⟦ Y | 1  2  3 ; ── ; P | ⅓  ⅓  ⅓ ⟧",
        ] {
            for english in [false, true] {
                let parsed = text::parse(&text::normalize(source, english));
                let [Node::Table(table)] = parsed.as_slice() else {
                    panic!("{parsed:?}");
                };
                assert_eq!(table.rows.len(), 2);
                assert_eq!(
                    table.rows[0].len(),
                    if source.contains('X') { 5 } else { 4 }
                );
                assert_eq!(
                    table.horizontal,
                    [TableRule::None, TableRule::Solid, TableRule::None]
                );
                assert_eq!(table.vertical[1], TableRule::Solid);
                assert!(matches!(table.rows[1][1][0], Node::Fraction(..)));
            }
        }
    }
    #[test]
    fn empty_cells_outer_rules_and_nested_delimiters_are_preserved() {
        for source in [
            "⟦  | c  d ; ── ; a | b  c ⟧",
            "⟦ a  b |  ; ── ; c  d | e ⟧",
            "⟦ | a  b | ; ── ; | c  d | ⟧",
            "⟦ a    b | c ; ── ; d  e  f | g ⟧",
            "⟦ ((a;b)/(c)) | (|x|) ; ── ; (1)/(2) | ⅓ ⟧",
            "⟦ ── ; | 标题 | ; ── ; | 内容 | ; ── ⟧",
        ] {
            let parsed = text::parse(source);
            assert!(
                matches!(parsed.as_slice(), [Node::Table(_)]),
                "{source}: {parsed:?}"
            );
        }
        let parsed = text::parse("⟦  | c  d ; ── ; a | b  c ⟧");
        let [Node::Table(table)] = parsed.as_slice() else {
            panic!("{parsed:?}");
        };
        assert!(table.rows[0][0].is_empty());
    }
    #[test]
    fn ordinary_or_ambiguous_brackets_do_not_become_tables() {
        for source in [
            "⟦ a  b ; c  d ⟧",
            "[ a | b ; ── ; c | d ]",
            "⟦ a | b ; ── ; c  d ⟧",
            "⟦ a |x| b ; ── ; c |y| d ⟧",
            "⟦ a | b ; ── ; c | d",
            "⟦ a | b ; ── ; ── ; c | d ⟧",
            "`⟦ a | b ; c | d ⟧`",
            "https://example.test/[a|b;c|d]",
        ] {
            assert!(
                !text::parse(source)
                    .iter()
                    .any(|n| matches!(n, Node::Table(_))),
                "{source}"
            );
        }
    }
    #[test]
    fn quoted_cells_keep_pipes_semicolons_brackets_and_json_escapes() {
        let source = r#"⟦ "a|b" | "c ; d" ; ── ; "[ ] { } ⟧" | "say \"hi\" \\ end" ⟧"#;
        let parsed = text::parse(source);
        let [Node::Table(table)] = parsed.as_slice() else {
            panic!("{parsed:?}");
        };
        assert_eq!(table.rows[0].len(), 2);
        assert_eq!(
            table.rows[0][0],
            "a|b".chars().map(Node::Char).collect::<Vec<_>>()
        );
        assert_eq!(
            table.rows[0][1],
            "c ; d".chars().map(Node::Char).collect::<Vec<_>>()
        );
        assert!(table.rows[1][0].contains(&Node::Char('⟧')));
        for invalid in [
            r#"⟦ "a | b ; ── ; c | d ⟧"#,
            r#"⟦ "a"junk | b ; ── ; c | d ⟧"#,
            r#"⟦ "bad\q" | b ; ── ; c | d ⟧"#,
        ] {
            assert!(
                !text::parse(invalid)
                    .iter()
                    .any(|n| matches!(n, Node::Table(_)))
            );
        }
    }
}
