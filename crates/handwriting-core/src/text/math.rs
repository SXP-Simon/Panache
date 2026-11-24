//! 行内根式与分式。识别失败时由调用方按原位置继续匹配。
use super::{Node, nodes, script_char, token};

pub(super) fn radical(
    chars: &[char],
    pairs: &[Option<usize>],
    start: usize,
    depth: usize,
) -> Option<(Node, usize)> {
    let (index, after_sign) = radical_prefix(chars, pairs, start, depth)?;
    let body = skip_spaces(chars, after_sign);
    if matches!(chars.get(body), Some('(' | '{'))
        && let Some(close) = pairs[body]
    {
        return Some((
            Node::Radical(nodes(&chars[body + 1..close], depth), index),
            close + 1,
        ));
    }
    let count = chars[body..]
        .iter()
        .take_while(|&&c| token(c) || ('α'..='ω').contains(&c))
        .count();
    if count == 0 {
        return None;
    }
    let end = body + count;
    Some((Node::Radical(nodes(&chars[body..end], depth), index), end))
}

fn radical_prefix(
    chars: &[char],
    pairs: &[Option<usize>],
    start: usize,
    depth: usize,
) -> Option<(Vec<Node>, usize)> {
    const ROOT_DIGITS: &str = "⁰¹²³⁴⁵⁶⁷⁸⁹ⁿ";
    match chars[start] {
        '√' => Some((vec![], start + 1)),
        '∛' => Some((vec![Node::Char('3')], start + 1)),
        '∜' => Some((vec![Node::Char('4')], start + 1)),
        '\\' if chars[start..].starts_with(&['\\', 's', 'q', 'r', 't'])
            && chars
                .get(start + 5)
                .is_none_or(|c| !c.is_ascii_alphabetic()) =>
        {
            let index_start = skip_spaces(chars, start + 5);
            if chars.get(index_start) == Some(&'[')
                && let Some(close) = pairs[index_start]
            {
                return Some((nodes(&chars[index_start + 1..close], depth), close + 1));
            }
            Some((vec![], index_start))
        }
        c if ROOT_DIGITS.contains(c) => {
            let end = start
                + chars[start..]
                    .iter()
                    .take_while(|&&c| ROOT_DIGITS.contains(c))
                    .count();
            if chars.get(end) != Some(&'√') {
                return None;
            }
            let index = chars[start..end]
                .iter()
                .map(|&c| Node::Char(script_char(c).map_or(c, |(v, _)| v)))
                .collect();
            Some((index, end + 1))
        }
        _ => None,
    }
}

fn skip_spaces(chars: &[char], start: usize) -> usize {
    start + chars[start..].iter().take_while(|&&c| c == ' ').count()
}

pub(super) fn vulgar_fraction(ch: char) -> Option<Node> {
    let (numerator, denominator) = match ch {
        '½' => ('1', '2'),
        '⅓' => ('1', '3'),
        '⅔' => ('2', '3'),
        '¼' => ('1', '4'),
        '¾' => ('3', '4'),
        '⅕' => ('1', '5'),
        '⅖' => ('2', '5'),
        '⅗' => ('3', '5'),
        '⅘' => ('4', '5'),
        '⅙' => ('1', '6'),
        '⅚' => ('5', '6'),
        '⅛' => ('1', '8'),
        '⅜' => ('3', '8'),
        '⅝' => ('5', '8'),
        '⅞' => ('7', '8'),
        _ => return None,
    };
    Some(Node::Fraction(
        vec![Node::Char(numerator)],
        vec![Node::Char(denominator)],
    ))
}

/// 斜线必须紧邻两侧操作数，分母可以是函数调用，例如 a/f(x)。
pub(super) fn slash_fraction(
    chars: &[char],
    pairs: &[Option<usize>],
    start: usize,
    depth: usize,
) -> Option<(Node, usize)> {
    if token(chars[start]) && start > 0 && token(chars[start - 1]) {
        return None;
    }
    let (numerator, slash) = operand(chars, pairs, start)?;
    if chars.get(slash) != Some(&'/') {
        return None;
    }
    let denominator_start = slash + 1;
    let (mut denominator, mut end) = operand(chars, pairs, denominator_start)?;
    if chars[denominator_start] != '('
        && chars.get(end) == Some(&'(')
        && let Some(close) = pairs[end]
    {
        end = close + 1;
        denominator = &chars[denominator_start..end];
    }
    Some((
        Node::Fraction(nodes(numerator, depth), nodes(denominator, depth)),
        end,
    ))
}

fn operand<'a>(
    chars: &'a [char],
    pairs: &[Option<usize>],
    start: usize,
) -> Option<(&'a [char], usize)> {
    if chars.get(start) == Some(&'(') {
        let close = pairs[start]?;
        return Some((&chars[start + 1..close], close + 1));
    }
    let count = chars[start..].iter().take_while(|&&c| token(c)).count();
    (count > 0).then_some((&chars[start..start + count], start + count))
}
