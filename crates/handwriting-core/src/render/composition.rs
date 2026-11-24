//! Build the ink for one document unit before measuring it for the current line.
use super::{Glyph, Glyphs, fine, glyph, normal};
use crate::{Parameters, Result, text::Node};
use rand::RngExt;
use rand_chacha::ChaCha8Rng;

pub(super) struct PreparedGlyph {
    pub(super) glyph: Glyph,
    pub(super) compound: bool,
    pub(super) fine_parts: Option<fine::Parts>,
}

pub(super) struct UnitComposer<'a> {
    p: &'a Parameters,
    text: &'a str,
    source: Option<&'a [u32]>,
    page_size: (u32, u32),
    // Captured on the first simulated mistake; repeated mistakes use the same candidate order.
    candidates: Option<Vec<char>>,
}

impl<'a> UnitComposer<'a> {
    pub(super) fn new(
        p: &'a Parameters,
        text: &'a str,
        source: Option<&'a [u32]>,
        page_size: (u32, u32),
    ) -> Self {
        Self {
            p,
            text,
            source,
            page_size,
            candidates: None,
        }
    }

    pub(super) fn prepare(
        &mut self,
        glyphs: &mut Glyphs<'_>,
        rng: &mut ChaCha8Rng,
        unit: &[Node],
        index: usize,
        node_index: usize,
    ) -> Result<PreparedGlyph> {
        let p = self.p;
        let size = (p.font_size + normal(rng, p.font_size_sigma)).clamp(1., 2048.);
        let (glyph, fine_parts) = if p.fine_edit
            && unit.len() > 1
            && unit.iter().all(|node| matches!(node, Node::Char(_)))
        {
            let (advance, children) = glyphs.sequence_parts(unit, size, 0)?;
            let glyph = Glyphs::compose(advance, children.clone(), vec![])?;
            let parts = fine::Parts::new(&glyph, children, node_index, self.source);
            (glyph, Some(parts))
        } else {
            (glyphs.unit(unit, size, index)?, None)
        };
        let node = &unit[0];
        // Proportional text draws the probability for whitespace too, to preserve the seed stream.
        if !p.monospaced
            && rng.random::<f32>() < p.strikethrough_probability
            && !matches!(node, Node::Char(c) if c.is_whitespace())
            && let Some(c) = self.wrong_character(rng)
        {
            let wrong = glyphs.glyph(c, size)?;
            return Ok(PreparedGlyph {
                glyph: cross_out(wrong, glyph, p, self.page_size, rng)?,
                compound: true,
                fine_parts: None,
            });
        }
        let compound = unit.len() > 1
            || !matches!(node, Node::Char(_))
            || matches!(node, Node::Char(c) if glyph::is_circled(*c));
        Ok(PreparedGlyph {
            glyph,
            compound,
            fine_parts,
        })
    }

    fn wrong_character(&mut self, rng: &mut ChaCha8Rng) -> Option<char> {
        let candidates = self.candidates.get_or_insert_with(|| {
            self.text
                .chars()
                .filter(|c| !c.is_whitespace() && !"，。！？,.!?".contains(*c))
                .take(1024)
                .collect()
        });
        if candidates.is_empty() {
            return None;
        }
        Some(candidates[rng.random_range(0..candidates.len())])
    }
}

fn cross_out(
    wrong: Glyph,
    correct: Glyph,
    p: &Parameters,
    (w, h): (u32, u32),
    rng: &mut ChaCha8Rng,
) -> Result<Glyph> {
    let length = (p.font_size * 2f32.sqrt() + normal(rng, p.strikethrough_length_sigma))
        .clamp(0., (w as f32 + h as f32).min(16384.));
    let angle = (45. + normal(rng, p.strikethrough_angle_sigma)).to_radians();
    let width = (p.strikethrough_width + normal(rng, p.strikethrough_width_sigma))
        .clamp(1., (w.min(h) as f32).clamp(1., 256.)) as i32;
    let sy = wrong.top as f32 + length / 7.;
    let path = vec![
        ((length / 7.).round() as i32, sy.round() as i32),
        (
            (length / 7. + length * angle.cos() * 5. / 7.).round() as i32,
            (sy + length * angle.sin() * 5. / 7.).round() as i32,
        ),
    ];
    // 2026-10-15：正确字写在错字和完整删除线之后，不能让较长删除线划到正确内容。
    let stroke_right = path.iter().map(|point| point.0).max().unwrap_or(0) + width / 2 + 2;
    let shift = (wrong.advance + p.word_spacing)
        .max(wrong.right() as f32)
        .max(stroke_right as f32)
        .round() as i32;
    Glyphs::compose(
        correct.advance + shift as f32,
        vec![(wrong, 0, 0), (correct, shift, 0)],
        vec![(path, width)],
    )
}
