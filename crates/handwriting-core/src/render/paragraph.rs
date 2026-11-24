//! 段首缩进、作业续行和标准排版的词组断行共享同一条行缓冲。
use super::{Glyph, Glyphs, LineUnit, PageInk, Pages, homework, units};
use crate::{LayoutStyle, Result, text::Node};
use image::RgbaImage;

pub(super) struct ParagraphLayout<'a> {
    nodes: &'a [Node],
    units: &'a [&'a [Node]],
    right: f32,
    continuation: f32,
    group_start: usize,
    section_line_start: usize,
}

impl<'a> ParagraphLayout<'a> {
    pub(super) fn new(nodes: &'a [Node], units: &'a [&'a [Node]], left: f32, right: f32) -> Self {
        Self {
            nodes,
            units,
            right,
            continuation: left,
            group_start: 0,
            section_line_start: 0,
        }
    }

    pub(super) fn usable_width(&self) -> f32 {
        self.right - self.continuation
    }

    pub(super) fn begin_unit<F>(
        &mut self,
        pages: &mut Pages<'_, F>,
        glyphs: &mut Glyphs<'_>,
        i: usize,
    ) -> Result<()>
    where
        F: FnMut(usize, RgbaImage, Option<PageInk>) -> Result<()>,
    {
        let node = &self.units[i][0];
        if matches!(node, Node::Newline | Node::Break)
            || (i > 0 && !matches!(self.units[i - 1][0], Node::Newline | Node::Break))
        {
            return Ok(());
        }
        let p = pages.p;
        let indent_first = p.first_line_indent
            && !matches!(node, Node::RightAlign | Node::Char(' ' | '\t' | '\u{3000}'));
        if p.layout_style == LayoutStyle::Standard {
            if indent_first {
                pages.x = (p.left_margin + 2. * p.font_size).min(self.right - p.font_size);
            }
        } else {
            let style = homework::paragraph(&self.units[i..], p.font_size);
            let available = self.right - p.left_margin;
            let indent = if indent_first {
                (2. * p.font_size).min(available - p.font_size)
            } else {
                style.indent.min(available * 0.15)
            };
            let prefix: Vec<_> = self.units[i..]
                .iter()
                .flat_map(|unit| unit.iter())
                .take(style.prefix_chars)
                .cloned()
                .collect();
            let hanging = if prefix.is_empty() {
                0.
            } else {
                glyphs.unit(&prefix, p.font_size, i)?.advance + p.word_spacing
            };
            self.continuation = p.left_margin + indent + hanging.min(available * 0.25);
            pages.x = p.left_margin + indent;
            if style.gap_before {
                if (style.title || pages.written_lines - self.section_line_start >= 3)
                    && pages.dirty
                    && i >= 2
                    && !matches!(self.units[i - 2][0], Node::Newline | Node::Break)
                {
                    pages.y += p.line_spacing;
                }
                self.section_line_start = pages.written_lines;
            }
        }
        Ok(())
    }

    /// An overflowing separator or a finished page prefix consumes the unit without drawing it.
    pub(super) fn position<F>(
        &mut self,
        pages: &mut Pages<'_, F>,
        i: usize,
        glyph: &Glyph,
        cell: Option<f32>,
        jitter_x: f32,
    ) -> Result<Option<f32>>
    where
        F: FnMut(usize, RgbaImage, Option<PageInk>) -> Result<()>,
    {
        let p = pages.p;
        let right = self.right;
        let origin = |cursor: f32| {
            (cursor + jitter_x)
                .round()
                .max(p.left_margin - glyph.left as f32)
        };
        let mut x = origin(pages.x);
        let footprint = cell.unwrap_or_else(|| glyph.right() as f32);

        if p.layout_style == LayoutStyle::Homework {
            if !pages.line.is_empty() && x + footprint > right {
                pages.homework_wrap(self.continuation, right)?;
                if !pages.line.is_empty() && pages.x + glyph.right() as f32 > right {
                    pages.finish_line()?;
                    pages.x = self.continuation;
                }
                x = origin(pages.x);
            }
        } else {
            if pages.line.is_empty() || units::starts_wrap_group(self.units, i) {
                self.group_start = pages.line.len();
            }
            let closing =
                matches!(self.units[i], [Node::Char(c)] if units::closing_punctuation(*c));
            // Use spare trailing whitespace before moving a closing mark to another line.
            if closing
                && x + footprint > right
                && i > 0
                && matches!(self.units[i - 1], [Node::Char(c)] if c.is_whitespace())
                && let Some(last) = pages.line.iter().rev().find(|u| u.glyph.ink)
                && (last.x + last.glyph.right()) as f32 <= right - footprint
            {
                x = right - footprint;
            }
            if !pages.line.is_empty() && x + footprint > right {
                if matches!(self.units[i], [Node::Char(' ' | '\t')]) {
                    pages.x = right;
                    return Ok(None);
                }
                let split = self.standard_split(&pages.line, p.left_margin, x + footprint, closing);
                let bearing = split.map_or(0, |at| pages.line[at].glyph.left.min(0));
                pages.wrap_at(split, p.left_margin - bearing as f32)?;
                self.group_start = 0;
                x = origin(pages.x);
            }
        }
        if pages.stopped {
            return Ok(None);
        }
        Ok(Some(
            x.min(right - glyph.right() as f32)
                .max(p.left_margin - glyph.left as f32),
        ))
    }

    fn standard_split(
        &self,
        line: &[LineUnit],
        margin: f32,
        end: f32,
        closing: bool,
    ) -> Option<usize> {
        let fits = |at: usize| {
            line.get(at).is_some_and(|first| {
                // Reclaim the indent of a first word before falling back to character boundaries.
                let bearing = first.glyph.left.min(0) as f32;
                (at > 0 || first.x as f32 > (margin - bearing).round())
                    && end - first.x as f32 - bearing <= self.usable_width()
            })
        };
        if fits(self.group_start) {
            return Some(self.group_start);
        }
        if !closing {
            return None;
        }
        line.iter()
            .rposition(|unit| {
                let node = &self.nodes[unit.id as usize];
                unit.glyph.ink && !matches!(node, Node::Char(c) if units::closing_punctuation(*c))
            })
            .filter(|&at| fits(at))
    }
}

impl<F: FnMut(usize, RgbaImage, Option<PageInk>) -> Result<()>> Pages<'_, F> {
    // 2026-10-24：将末尾短语整体移至续行，已渲染的结构化公式保持原子性。
    fn homework_wrap(&mut self, continuation: f32, right: f32) -> Result<()> {
        let cutoff = self.p.left_margin + (right - self.p.left_margin) * 0.4;
        let split = self
            .line
            .iter()
            .enumerate()
            .rev()
            .find(|(i, u)| u.break_after && *i + 1 < self.line.len() && u.x as f32 >= cutoff)
            .map(|(i, _)| i + 1);
        self.wrap_at(split, continuation)
    }
    fn wrap_at(&mut self, split: Option<usize>, continuation: f32) -> Result<()> {
        let mut tail = split.map(|at| self.line.split_off(at)).unwrap_or_default();
        let old_cursor = self.x;
        self.finish_line()?;
        if let Some(first) = tail.first() {
            let shift = continuation - first.x as f32;
            for unit in &mut tail {
                unit.x += shift.round() as i32;
            }
            self.x = old_cursor + shift;
            self.line = tail;
        } else {
            self.x = continuation;
        }
        Ok(())
    }
}
