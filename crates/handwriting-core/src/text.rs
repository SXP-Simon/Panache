//! 2026-10-12：有限公式节点，避免动态私用区字符和全局注册表。
#[derive(Debug, Clone, PartialEq)]
pub enum Node {
    Char(char),
    Fraction(Vec<Node>, Vec<Node>),
    Radical(Vec<Node>, Vec<Node>),
    Image { alt: String, data: String },
    Break,
    Newline,
    RightAlign,
}

pub fn normalize(text: &str, english_spacing: bool) -> String {
    let text = text.replace("\r\n", "\n").replace('\r', "\n");
    let mut s = String::new();
    for c in text.chars() {
        match c {
            '\u{200b}' | '\u{200c}' | '\u{200d}' | '\u{feff}' => (),
            '\u{a0}' | '\u{2002}' | '\u{2003}' | '\u{2009}' | '\u{202f}' => s.push(' '),
            '\u{3000}' => s.push_str("  "),
            '∣' => s.push('|'),
            '∥' => s.push_str("||"),
            '∶' => s.push(':'),
            _ => s.push(c),
        }
    }
    if !english_spacing {
        return s;
    }
    fn english(s: &str) -> bool {
        !s.is_empty()
            && s.chars()
                .all(|c| c.is_ascii_alphanumeric() || ".,!?;:'\"()-_".contains(c))
    }
    s.split('\n')
        .map(|line| {
            let parts: Vec<_> = line.split(' ').collect();
            let mut out = String::new();
            for (i, part) in parts.iter().enumerate() {
                out.push_str(part);
                if i + 1 < parts.len() {
                    out.push_str(if english(part) && english(parts[i + 1]) {
                        "  "
                    } else {
                        " "
                    });
                }
            }
            out
        })
        .collect::<Vec<_>>()
        .join("\n")
}

pub fn parse(text: &str) -> Vec<Node> {
    let mut out = Vec::new();
    for (i, line) in text.split('\n').enumerate() {
        let trimmed = line.trim();
        if trimmed.len() >= 3 && trimmed.bytes().all(|b| b == b'-') {
            if !out.is_empty() && matches!(out.last(), Some(Node::Newline)) {
                out.pop();
            }
            out.push(Node::Break);
            continue;
        }
        if i > 0 && !matches!(out.last(), Some(Node::Break)) {
            out.push(Node::Newline);
        }
        if let Some(rest) = line.trim_start().strip_prefix(">>>") {
            out.push(Node::RightAlign);
            out.extend(parse_inline(
                rest.strip_prefix([' ', '\t']).unwrap_or(rest),
                0,
            ));
        } else {
            out.extend(parse_inline(line, 0));
        }
    }
    // 边界分页标记不产生空白页。
    let first = out
        .iter()
        .position(|n| !matches!(n, Node::Break))
        .unwrap_or(out.len());
    out.drain(..first);
    while matches!(out.last(), Some(Node::Break)) {
        out.pop();
    }
    out
}
// 2026-10-12：预计算各类括号配对，未闭合输入也只扫描一次。
fn bracket_matches(cs: &[char]) -> Vec<Option<usize>> {
    let mut result = vec![None; cs.len()];
    for (open, close) in [('(', ')'), ('[', ']'), ('{', '}')] {
        let mut stack = Vec::new();
        for (i, c) in cs.iter().enumerate() {
            if *c == open {
                stack.push(i);
            }
            if *c == close
                && let Some(start) = stack.pop()
            {
                result[start] = Some(i);
            }
        }
    }
    result
}
fn token(c: char) -> bool {
    c.is_ascii_alphanumeric() || ".%₀₁₂₃₄₅₆₇₈₉²³⁴ε".contains(c)
}
fn nodes(cs: &[char], depth: usize) -> Vec<Node> {
    parse_inline(&cs.iter().collect::<String>(), depth + 1)
}
fn parse_inline(s: &str, depth: usize) -> Vec<Node> {
    let cs: Vec<_> = s.chars().collect();
    if depth > 24 {
        return cs.into_iter().map(Node::Char).collect();
    }
    let pairs = bracket_matches(&cs);
    let mut next_square = vec![None; cs.len() + 1];
    let mut next_round = vec![None; cs.len() + 1];
    for j in (0..cs.len()).rev() {
        next_square[j] = if cs[j] == ']' {
            Some(j)
        } else {
            next_square[j + 1]
        };
        next_round[j] = if cs[j] == ')' {
            Some(j)
        } else {
            next_round[j + 1]
        };
    }
    let mut out = Vec::new();
    let mut i = 0;
    while i < cs.len() {
        if cs[i] == '!'
            && cs.get(i + 1) == Some(&'[')
            && let Some(end) = next_square.get(i + 2).copied().flatten()
            && cs.get(end + 1) == Some(&'(')
            && let Some(close) = next_round.get(end + 2).copied().flatten()
        {
            let data: String = cs[end + 2..close].iter().collect();
            if data.starts_with("data:image/")
                || data
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || "+/= \t".contains(c))
            {
                out.push(Node::Image {
                    alt: cs[i + 2..end].iter().collect(),
                    data,
                });
                i = close + 1;
                continue;
            }
        }
        let mut rad_start = None;
        let mut index = Vec::new();
        if cs[i] == '√' {
            rad_start = Some(i + 1);
        } else if cs[i..].starts_with(&['\\', 's', 'q', 'r', 't']) {
            let mut p = i + 5;
            if cs.get(p) == Some(&'[')
                && let Some(e) = pairs.get(p).copied().flatten()
            {
                index = nodes(&cs[p + 1..e], depth);
                p = e + 1;
            }
            while cs.get(p) == Some(&' ') {
                p += 1;
            }
            rad_start = Some(p);
        } else if "⁰¹²³⁴⁵⁶⁷⁸⁹ⁿ".contains(cs[i]) {
            let mut p = i;
            while p < cs.len() && "⁰¹²³⁴⁵⁶⁷⁸⁹ⁿ".contains(cs[p]) {
                p += 1;
            }
            if cs.get(p) == Some(&'√') {
                index = nodes(&cs[i..p], depth);
                rad_start = Some(p + 1);
            }
        }
        if let Some(mut p) = rad_start {
            while cs.get(p) == Some(&' ') {
                p += 1;
            }
            if let Some(&open) = cs.get(p)
                && (open == '(' || open == '{')
                && let Some(e) = pairs.get(p).copied().flatten()
            {
                out.push(Node::Radical(nodes(&cs[p + 1..e], depth), index));
                i = e + 1;
                continue;
            }
            let start = p;
            while p < cs.len() && (token(cs[p]) || ('α'..='ω').contains(&cs[p])) {
                p += 1;
            }
            if p > start {
                out.push(Node::Radical(nodes(&cs[start..p], depth), index));
                i = p;
                continue;
            }
        }
        let vulgar = match cs[i] {
            '½' => Some(("1", "2")),
            '⅓' => Some(("1", "3")),
            '⅔' => Some(("2", "3")),
            '¼' => Some(("1", "4")),
            '¾' => Some(("3", "4")),
            '⅕' => Some(("1", "5")),
            '⅖' => Some(("2", "5")),
            '⅗' => Some(("3", "5")),
            '⅘' => Some(("4", "5")),
            '⅙' => Some(("1", "6")),
            '⅚' => Some(("5", "6")),
            '⅛' => Some(("1", "8")),
            '⅜' => Some(("3", "8")),
            '⅝' => Some(("5", "8")),
            '⅞' => Some(("7", "8")),
            _ => None,
        };
        if let Some((n, d)) = vulgar {
            out.push(Node::Fraction(
                parse_inline(n, depth + 1),
                parse_inline(d, depth + 1),
            ));
            i += 1;
            continue;
        }
        // 括号表达式或连续 token 的分式，嵌套结构受深度上限约束。
        let mut end = i;
        let mut numerator = None;
        if cs[i] == '(' {
            if let Some(e) = pairs.get(i).copied().flatten() {
                end = e + 1;
                numerator = Some(&cs[i + 1..e]);
            }
        } else if token(cs[i]) && (i == 0 || !token(cs[i - 1])) {
            while end < cs.len() && token(cs[end]) {
                end += 1;
            }
            numerator = Some(&cs[i..end]);
        }
        let mut slash = end;
        while cs.get(slash) == Some(&' ') {
            slash += 1;
        }
        if let Some(num) = numerator
            && cs.get(slash) == Some(&'/')
        {
            let mut start = slash + 1;
            while cs.get(start) == Some(&' ') {
                start += 1;
            }
            let mut den_end = start;
            let mut denominator = None;
            if cs.get(start) == Some(&'(') {
                if let Some(e) = pairs.get(start).copied().flatten() {
                    den_end = e + 1;
                    denominator = Some(&cs[start + 1..e]);
                }
            } else {
                while den_end < cs.len() && token(cs[den_end]) {
                    den_end += 1;
                }
                if den_end > start {
                    if cs.get(den_end) == Some(&'(')
                        && let Some(e) = pairs.get(den_end).copied().flatten()
                    {
                        den_end = e + 1;
                    }
                    denominator = Some(&cs[start..den_end]);
                }
            }
            if let Some(den) = denominator {
                out.push(Node::Fraction(nodes(num, depth), nodes(den, depth)));
                i = den_end;
                continue;
            }
        }
        out.push(Node::Char(cs[i]));
        i += 1;
    }
    out
}
