//! 2026-10-15：基底及其脚标是同一个换行单元，防止窄纸把化学价态/积分上下限单独放到下一行。
use crate::Parameters;
use crate::text::Node;
use icu_properties::{CodePointMapData, props::Script};
pub(super) fn closing_punctuation(c: char) -> bool {
    "，。；：！？、,.!?;:)]}）】〕〉》」』”’…".contains(c)
}

fn latin_word_unit(unit: &[Node]) -> bool {
    match unit {
        [Node::Char(c)] => {
            c.is_ascii_alphanumeric()
                || (c.is_alphabetic() && CodePointMapData::<Script>::new().get(*c) == Script::Latin)
        }
        [Node::Accent(base, _)] => latin_word_unit(base),
        _ => false,
    }
}

// Join an apostrophe or hyphen only between word characters.
fn word_part(units: &[&[Node]], i: usize) -> bool {
    latin_word_unit(units[i])
        || (matches!(units[i], [Node::Char('\'' | '’' | '-')])
            && i > 0
            && i + 1 < units.len()
            && latin_word_unit(units[i - 1])
            && latin_word_unit(units[i + 1]))
}

pub(super) fn starts_wrap_group(units: &[&[Node]], i: usize) -> bool {
    if matches!(units[i], [Node::Char(c)] if c.is_whitespace() || closing_punctuation(*c)) {
        return false;
    }
    i == 0 || !word_part(units, i - 1) || !word_part(units, i)
}

pub(super) fn layout_units(nodes: &[Node]) -> Vec<&[Node]> {
    let mut units = Vec::new();
    let mut index = 0;
    while index < nodes.len() {
        let start = index;
        index += 1;
        let base = matches!(&nodes[start], Node::Char(c) if !c.is_whitespace())
            || matches!(
                &nodes[start],
                Node::Fraction(..) | Node::Radical(..) | Node::Accent(..)
            );
        if base {
            while matches!(nodes.get(index), Some(Node::Scripts { .. })) {
                index += 1;
            }
        }
        units.push(&nodes[start..index]);
    }
    units
}

// 2026-10-15：汉字、假名、韩文与全角标点维持正文整格；拉丁/希腊字母、数字和公式符号自然行进。
pub(super) fn keeps_grid_cell(nodes: &[Node]) -> bool {
    matches!(nodes, [Node::Char(c)] if !super::glyph::is_circled(*c) && matches!(*c as u32,
        0x2e80..=0xa4cf | 0xac00..=0xd7af | 0xf900..=0xfaff | 0xff00..=0xffef | 0x20000..=0x323af))
}

pub(super) fn fixed_cell(nodes: &[Node], p: &Parameters) -> Option<f32> {
    if !p.monospaced {
        return None;
    }
    match nodes {
        [Node::Char(c)] if c.is_ascii() => Some((p.font_size / 2.).max(1.)),
        _ if keeps_grid_cell(nodes) => Some(p.font_size),
        _ => None,
    }
}
