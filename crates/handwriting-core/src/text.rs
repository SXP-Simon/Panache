//! 2026-10-12：有限公式节点，避免动态私用区字符和全局注册表。
#[derive(Debug, Clone, PartialEq)]
pub enum Node {
    Char(char),
    Fraction(Vec<Node>, Vec<Node>),
    Radical(Vec<Node>, Vec<Node>),
    Scripts { upper: Vec<Node>, lower: Vec<Node> },
    Accent(Vec<Node>, char),
    Table(Table),
    Circuit(circuit::Circuit),
    Image { alt: String, data: String },
    Break,
    Newline,
    RightAlign,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TableRule {
    None,
    Solid,
    Dashed,
}
#[derive(Debug, Clone, PartialEq)]
pub struct Table {
    pub kind: TableKind,
    pub rows: Vec<Vec<Vec<Node>>>,
    pub vertical: Vec<TableRule>,
    pub horizontal: Vec<TableRule>,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TableKind {
    Grid,
    Matrix,
    Parentheses,
    Brackets,
    Braces,
    Determinant,
    Norm,
    Cases,
}
pub mod circuit;
mod math;
mod table;

pub fn normalize(text: &str, english_spacing: bool) -> String {
    normalize_for_layout(text, english_spacing, false)
}

pub(crate) fn normalize_for_layout(
    text: &str,
    english_spacing: bool,
    preserve_indent: bool,
) -> String {
    let text = text.replace("\r\n", "\n").replace('\r', "\n");
    let mut s = String::new();
    for c in text.chars() {
        match c {
            '\u{200b}' | '\u{200c}' | '\u{200d}' | '\u{feff}' => (),
            '\u{a0}' | '\u{2002}' | '\u{2003}' | '\u{2009}' | '\u{202f}' => s.push(' '),
            '\u{3000}' if !preserve_indent => s.push_str("  "),
            '∣' => s.push('|'),
            '∥' => s.push_str("||"),
            '∶' => s.push(':'),
            // 2026-10-15：部分手写字体的 U+2212 无墨迹；使用实际手写连字符保住减法语义。
            '−' => s.push('-'),
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
            // 2026-10-20：双空格是表格列边界，不能被英文词距选项再次翻倍。
            let chars: Vec<_> = line.chars().collect();
            let pairs = bracket_matches(&chars);
            let mut index = 0;
            while index < chars.len() {
                if chars[index] == '⟦'
                    && let Some(end) = pairs[index]
                {
                    if table::parse(&chars[index + 1..end], 0).is_some() {
                        return line.to_owned();
                    }
                    index = end + 1;
                } else {
                    index += 1;
                }
            }
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
    if let Some(nodes) = circuit::document(text) {
        return nodes;
    }
    let spans = crate::inline_document::image_payloads(text);
    if spans.is_empty() {
        return parse_document(text);
    }
    // 2026-10-16：先用短标记替换图片，避免 base64 进入公式字符和括号索引数组。
    let mut compact = String::new();
    let mut prefix = "data:image/handwriting-inline".to_owned();
    while text.contains(&prefix) {
        prefix.push('x');
    }
    let mut images = std::collections::HashMap::new();
    let mut previous = 0;
    for (index, span) in spans.into_iter().enumerate() {
        compact.push_str(&text[previous..span.start]);
        let key = format!("{prefix};base64,{index}");
        compact.push_str(&key);
        images.insert(key, &text[span.clone()]);
        previous = span.end;
    }
    compact.push_str(&text[previous..]);
    fn restore(nodes: &mut [Node], images: &std::collections::HashMap<String, &str>) {
        for node in nodes {
            match node {
                Node::Image { data, .. } => {
                    if let Some(original) = images.get(data) {
                        *data = (*original).to_owned();
                    }
                }
                Node::Fraction(a, b) | Node::Radical(a, b) => {
                    restore(a, images);
                    restore(b, images);
                }
                Node::Scripts { upper, lower } => {
                    restore(upper, images);
                    restore(lower, images);
                }
                Node::Accent(a, _) => restore(a, images),
                Node::Table(table) => {
                    for row in &mut table.rows {
                        for cell in row {
                            restore(cell, images);
                        }
                    }
                }
                _ => (),
            }
        }
    }
    let mut nodes = parse_document(&compact);
    restore(&mut nodes, &images);
    nodes
}
fn parse_document(text: &str) -> Vec<Node> {
    let mut out = Vec::new();
    let mut fenced: Option<(char, usize)> = None;
    for (i, line) in text.split('\n').enumerate() {
        let trimmed = line.trim();
        // 2026-10-15：代码围栏内保留字面内容，数学启发式不能改写示例源码。
        let fence = trimmed
            .chars()
            .next()
            .filter(|c| "`~".contains(*c))
            .map(|c| (c, trimmed.chars().take_while(|&v| v == c).count()))
            .filter(|&(_, count)| count >= 3);
        if fenced.is_some() || fence.is_some() {
            if i > 0 {
                out.push(Node::Newline);
            }
            out.extend(line.chars().map(Node::Char));
            if let Some(open) = fenced {
                if fence.is_some_and(|close| close.0 == open.0 && close.1 >= open.1) {
                    fenced = None;
                }
            } else {
                fenced = fence;
            }
            continue;
        }
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
    for (open, close) in [('(', ')'), ('[', ']'), ('{', '}'), ('⟦', '⟧')] {
        let mut stack = Vec::new();
        let mut quoted = false;
        let mut escaped = false;
        for (i, c) in cs.iter().enumerate() {
            if open == '⟦' && !stack.is_empty() {
                if quoted {
                    if escaped {
                        escaped = false;
                    } else if *c == '\\' {
                        escaped = true;
                    } else if *c == '"' {
                        quoted = false;
                    }
                    continue;
                }
                if *c == '"' {
                    quoted = true;
                    continue;
                }
            }
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
    c.is_alphanumeric() || ".%".contains(c) || script_char(c).is_some()
}
// 2026-10-15：脚标先还原普通字符，交给所选手写字体缩小定位，避开字体中缺失/错误的 Unicode 脚标。
pub(crate) fn script_char(c: char) -> Option<(char, bool)> {
    for (source, target, upper) in [
        ("⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾ⁿⁱˣʸᵏᵐ", "0123456789+-=()nixykm", true),
        (
            "₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎ₐₑₕᵢⱼₖₗₘₙₒₚᵣₛₜᵤᵥₓᵧ",
            "0123456789+-=()aehijklmnoprstuvxy",
            false,
        ),
    ] {
        if let Some(index) = source.chars().position(|x| x == c) {
            return Some((target.chars().nth(index)?, upper));
        }
    }
    None
}
fn accent(c: char) -> bool {
    "\u{0304}\u{0305}\u{0302}\u{20d7}\u{0307}\u{0308}\u{0303}\u{0332}\u{0306}\u{0301}\u{0300}\u{030c}".contains(c)
}
fn protected_end(cs: &[char], start: usize) -> Option<usize> {
    if cs[start] == '`' {
        let count = cs[start..].iter().take_while(|&&c| c == '`').count();
        let mut end = start + count;
        while end < cs.len() {
            if cs[end..].iter().take(count).filter(|&&c| c == '`').count() == count {
                return Some((end + count).min(cs.len()));
            }
            end += 1;
        }
        return Some(cs.len());
    }
    if start > 0 && !cs[start - 1].is_whitespace() && !"([{\"'=:：，；".contains(cs[start - 1]) {
        return None;
    }
    // 2026-10-15：普通 token 在括号处停止，避免未闭合括号长输入反复扫描整个余串。
    let direct = cs[start..].starts_with(&['h', 't', 't', 'p', ':', '/', '/'])
        || cs[start..].starts_with(&['h', 't', 't', 'p', 's', ':', '/', '/'])
        || cs[start..].starts_with(&['w', 'w', 'w', '.'])
        || cs[start] == '/'
        || cs[start] == '\\'
        || (cs.get(start + 1) == Some(&':')
            && cs.get(start + 2).is_some_and(|c| *c == '/' || *c == '\\'));
    let end = start
        + cs[start..]
            .iter()
            .take_while(|c| !c.is_whitespace() && (direct || !"()[]{}\"'=:：，；".contains(**c)))
            .count();
    let word: String = cs[start..end].iter().collect();
    let bare = word.trim_end_matches(|c: char| ")]},;。；，".contains(c));
    let date = bare
        .chars()
        .all(|c| c.is_ascii_digit() || "/-.".contains(c))
        && bare.matches('/').count() >= 2;
    let path = word.starts_with('/')
        || word.starts_with("./")
        || word.starts_with("../")
        || word.contains(":\\")
        || (word.as_bytes().get(1) == Some(&b':') && word.as_bytes().get(2) == Some(&b'/'))
        || word.starts_with("\\\\")
        || (word.contains('/')
            && (word.contains('_') || word.rsplit('/').next().is_some_and(|s| s.contains('.'))));
    (date || path || word.contains("://") || word.starts_with("www.")).then_some(end)
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
        if let Some(end) = protected_end(&cs, i) {
            out.extend(cs[i..end].iter().copied().map(Node::Char));
            i = end;
            continue;
        }
        if cs[i] == '⟦'
            && let Some(end) = pairs[i]
        {
            if let Some(table) = table::parse(&cs[i + 1..end], depth) {
                out.push(Node::Table(table));
            } else {
                out.extend(cs[i..=end].iter().copied().map(Node::Char));
            }
            i = end + 1;
            continue;
        }
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
        if let Some((radical, end)) = math::radical(&cs, &pairs, i, depth) {
            out.push(radical);
            i = end;
            continue;
        }
        if let Some(fraction) = math::vulgar_fraction(cs[i]) {
            out.push(fraction);
            i += 1;
            continue;
        }
        if cs[i] == '('
            && let Some(end) = pairs[i]
            && cs.get(end + 1).is_some_and(|&c| accent(c))
        {
            out.push(Node::Accent(nodes(&cs[i + 1..end], depth), cs[end + 1]));
            i = end + 2;
            continue;
        }
        if accent(cs[i])
            && let Some(base) = out.pop()
        {
            out.push(Node::Accent(vec![base], cs[i]));
            i += 1;
            continue;
        }
        let explicit = "^_".contains(cs[i])
            && cs.get(i + 1).is_some_and(|c| *c == '(' || *c == '{')
            && pairs.get(i + 1).copied().flatten().is_some();
        if script_char(cs[i]).is_some() || explicit {
            let (part, upper, end) = if explicit {
                let end = pairs[i + 1].unwrap();
                (nodes(&cs[i + 2..end], depth), cs[i] == '^', end + 1)
            } else {
                let upper = script_char(cs[i]).unwrap().1;
                let mut end = i;
                let mut part = Vec::new();
                while end < cs.len()
                    && let Some((normal, is_upper)) = script_char(cs[end])
                    && is_upper == upper
                {
                    part.push(Node::Char(normal));
                    end += 1;
                }
                (part, upper, end)
            };
            if let Some(Node::Scripts {
                upper: sup,
                lower: sub,
            }) = out.last_mut()
            {
                let slot = if upper { sup } else { sub };
                if slot.is_empty() {
                    *slot = part;
                    i = end;
                    continue;
                }
            }
            out.push(if upper {
                Node::Scripts {
                    upper: part,
                    lower: vec![],
                }
            } else {
                Node::Scripts {
                    upper: vec![],
                    lower: part,
                }
            });
            i = end;
            continue;
        }
        if let Some((fraction, end)) = math::slash_fraction(&cs, &pairs, i, depth) {
            out.push(fraction);
            i = end;
            continue;
        }
        out.push(Node::Char(cs[i]));
        i += 1;
    }
    out
}
