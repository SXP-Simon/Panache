//! 2026-10-15：字体校验、按需备用链与字形选择；不会替换用户选定的主字体。
use crate::{
    Error, Result,
    text::{self, Node},
};
use fontdue::{Font, FontSettings};
use std::{
    collections::HashMap,
    sync::{Arc, OnceLock},
};

pub const FALLBACK_FONT_NAMES: [&str; 4] = [
    "霞鹜文楷.ttf",
    "霞鹜漫黑.ttf",
    "李国夫手写体.ttf",
    "悠哉手写体.ttf",
];
const CALLIGRAPHIC_CAPITALS: &str = "𝒜ℬ𝒞𝒟ℰℱ𝒢ℋℐ𝒥𝒦ℒℳ𝒩𝒪𝒫𝒬ℛ𝒮𝒯𝒰𝒱𝒲𝒳𝒴𝒵";

#[derive(Clone)]
pub struct FontBook {
    fonts: Vec<Arc<Font>>,
    coverage: HashMap<char, usize>,
}

// 2026-10-15：部分手写字体把数学符号映射到空白轮廓；cmap 存在不等于实际可写。
fn visible_glyph(font: &Font, c: char) -> bool {
    font.lookup_glyph_index(c) != 0
        && (c.is_whitespace() || font.rasterize(c, 36.).1.iter().any(|alpha| *alpha >= 128))
}

// 2026-10-15：根号、分数线和重音由路径绘制，Unicode 脚标已还原；不能为这些结构预载大字体。
fn rendered_characters(source: &str) -> Vec<char> {
    fn collect(nodes: &[Node], chars: &mut Vec<char>) {
        for node in nodes {
            match node {
                Node::Char(c) if !c.is_control() => chars.push(*c),
                Node::Fraction(a, b) | Node::Radical(a, b) => {
                    chars.push('x');
                    collect(a, chars);
                    collect(b, chars);
                }
                Node::Scripts { upper, lower } => {
                    chars.push('x');
                    collect(upper, chars);
                    collect(lower, chars);
                }
                Node::Accent(body, _) => collect(body, chars),
                // 2026-10-22：表格也可能独占某个希腊字母或工程符号，递归收集嵌套公式。
                Node::Table(table) => {
                    for row in &table.rows {
                        for cell in row {
                            collect(cell, chars);
                        }
                    }
                }
                _ => {}
            }
        }
    }
    let mut chars = Vec::new();
    collect(&text::parse(&text::normalize(source, false)), &mut chars);
    chars.sort_unstable();
    chars.dedup();
    chars
}
impl FontBook {
    pub fn new(primary: &[u8], fallbacks: &[Vec<u8>]) -> Result<Self> {
        let mut fonts = vec![Self::load(primary)?];
        for bytes in fallbacks {
            fonts.push(Self::load(bytes)?);
        }
        Ok(Self {
            fonts,
            coverage: HashMap::new(),
        })
    }
    pub fn load(bytes: &[u8]) -> Result<Arc<Font>> {
        ttf_parser::Face::parse(bytes, 0).map_err(|e| Error::new("invalid_font", e.to_string()))?;
        Font::from_bytes(bytes, FontSettings::default())
            .map(Arc::new)
            .map_err(|e| Error::new("invalid_font", e))
    }
    // 2026-10-15：服务端与移动端共享同一缺字链；所选字体保留优先级，只为未覆盖字符读取备用。
    pub fn with_text_fallbacks(
        primary: Arc<Font>,
        text: &str,
        mut load: impl FnMut(&str) -> Result<Option<Arc<Font>>>,
    ) -> Result<Self> {
        let mut missing = rendered_characters(text);
        let mut coverage = HashMap::new();
        missing.retain(|c| {
            if visible_glyph(&primary, *c) {
                coverage.insert(*c, 0);
                false
            } else {
                true
            }
        });
        let mut fallbacks = Vec::new();
        if missing.iter().any(|c| CALLIGRAPHIC_CAPITALS.contains(*c)) {
            // 2026-10-22：随包字库只覆盖八个花体字母；内部 OFL 子集补全而不依赖系统字体。
            static SCRIPT: OnceLock<std::result::Result<Arc<Font>, String>> = OnceLock::new();
            let font = SCRIPT
                .get_or_init(|| {
                    Self::load(include_bytes!("../assets/PanacheMathScript.ttf"))
                        .map_err(|error| error.to_string())
                })
                .as_ref()
                .map(Arc::clone)
                .map_err(|message| Error::new("invalid_font", message.clone()))?;
            missing.retain(|c| {
                if CALLIGRAPHIC_CAPITALS.contains(*c) && visible_glyph(&font, *c) {
                    coverage.insert(*c, fallbacks.len() + 1);
                    false
                } else {
                    true
                }
            });
            fallbacks.push(font);
        }
        if missing
            .iter()
            .any(|c| ('\u{1d538}'..='\u{1d551}').contains(c))
        {
            // 2026-10-15：此区段的黑板大写使用内部 AMS 子集，避免冷加载多个无此字形的大字体。
            static MATH: OnceLock<std::result::Result<Arc<Font>, String>> = OnceLock::new();
            let font = MATH
                .get_or_init(|| {
                    Self::load(include_bytes!("../assets/HandwritingMathSymbols.ttf"))
                        .map_err(|error| error.to_string())
                })
                .as_ref()
                .map(Arc::clone)
                .map_err(|message| Error::new("invalid_font", message.clone()))?;
            missing.retain(|c| {
                if ('\u{1d538}'..='\u{1d551}').contains(c) && visible_glyph(&font, *c) {
                    coverage.insert(*c, fallbacks.len() + 1);
                    false
                } else {
                    true
                }
            });
            fallbacks.push(font);
        }
        for name in FALLBACK_FONT_NAMES {
            if missing.is_empty() {
                break;
            }
            if let Some(font) = load(name)? {
                missing.retain(|c| {
                    if visible_glyph(&font, *c) {
                        coverage.insert(*c, fallbacks.len() + 1);
                        false
                    } else {
                        true
                    }
                });
                fallbacks.push(font);
            }
        }
        let mut book = Self::from_fonts(primary, fallbacks);
        book.coverage = coverage;
        Ok(book)
    }
    pub fn from_fonts(primary: Arc<Font>, fallbacks: Vec<Arc<Font>>) -> Self {
        let mut fonts = vec![primary];
        fonts.extend(fallbacks);
        Self {
            fonts,
            coverage: HashMap::new(),
        }
    }
    pub(crate) fn for_char(&self, c: char) -> &Font {
        if let Some(index) = self.coverage.get(&c) {
            return &self.fonts[*index];
        }
        self.fonts
            .iter()
            .find(|f| visible_glyph(f, c))
            .unwrap_or(&self.fonts[0])
    }
}

#[cfg(test)]
mod tests;
