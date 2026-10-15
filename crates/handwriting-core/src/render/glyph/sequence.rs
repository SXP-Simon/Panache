//! 2026-10-15：公式自然字距与基于实际墨迹的上下标贴合，独立于正文整格布局。
use super::*;
impl Glyphs<'_> {
    pub(super) fn sequence(&mut self, nodes: &[Node], size: f32) -> Result<Glyph> {
        self.sequence_at(nodes, size, 0)
    }
    pub(super) fn sequence_at(&mut self, nodes: &[Node], size: f32, depth: usize) -> Result<Glyph> {
        let mut x: f32 = 0.;
        let mut children: Vec<(Glyph, i32, i32)> = Vec::new();
        let mut child_bytes = 0usize;
        for node in nodes {
            let (glyph, at) = if let (Node::Scripts { upper, lower }, Some((base, base_x, _))) =
                (node, children.last())
            {
                let glyph = self.scripts(upper, lower, size, base, depth + 1)?;
                let at = base_x + base.right() + (size * 0.035).round().max(1.) as i32 - glyph.left;
                (glyph, at)
            } else {
                let mut glyph = self.node_at(node, size, depth + 1)?;
                if matches!(node, Node::Char(_))
                    && !super::super::units::keeps_grid_cell(std::slice::from_ref(node))
                {
                    glyph = glyph.compact(size);
                }
                (glyph, x.round() as i32)
            };
            child_bytes = child_bytes.saturating_add(glyph.mask.len());
            if child_bytes > 16_000_000 {
                return Err(Error::new("invalid_layout", "数学子结构超过内存预算"));
            }
            x = at as f32 + glyph.advance;
            children.push((glyph, at, 0));
            if x > 32768. {
                return Err(Error::new("invalid_layout", "数学结构过宽"));
            }
        }
        Self::compose(x, children, vec![])
    }
    pub(super) fn scripts(
        &mut self,
        upper: &[Node],
        lower: &[Node],
        size: f32,
        base: &Glyph,
        depth: usize,
    ) -> Result<Glyph> {
        let mut advance: f32 = 0.;
        let mut children = Vec::new();
        for (nodes, is_upper) in [(upper, true), (lower, false)] {
            if nodes.is_empty() {
                continue;
            }
            let glyph =
                self.sequence_at(nodes, (size * 0.65).round().max(8.).min(size), depth + 1)?;
            let dy = if is_upper {
                base.top + (base.mask.height() as f32 * 0.40).round() as i32 - glyph.bottom()
            } else {
                base.bottom() - (base.mask.height() as f32 * 0.12).round() as i32 - glyph.top
            };
            advance = advance.max(glyph.advance + (size * 0.025).round().max(1.));
            children.push((glyph, 0, dy));
        }
        Self::compose(advance, children, vec![])
    }
}
