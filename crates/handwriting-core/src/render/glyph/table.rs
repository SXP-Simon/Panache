//! 2026-10-20：整表按真实手写墨迹测量列宽与基线，作为单个刚性结构缩放和分页。
use super::*;
use crate::text::{Table, TableRule};

impl Glyphs<'_> {
    pub(super) fn table(&mut self, table: &Table, size: f32, depth: usize) -> Result<Glyph> {
        let columns = table.vertical.len().saturating_sub(1);
        if !(1..=32).contains(&columns)
            || table.rows.is_empty()
            || table.rows.len() > 32
            || table.horizontal.len() != table.rows.len() + 1
            || table.rows.iter().any(|row| row.len() != columns)
        {
            return Err(Error::new("invalid_layout", "表格行列结构无效"));
        }
        let pad = (size * 0.26).round().max(3.) as i32;
        let grid_thickness = (size * 0.025).round().max(1.) as i32;
        let thickness = ((size * 0.04).round() as i32).max(grid_thickness + 1);
        let mut widths = vec![(size * 0.35).round() as i32; columns];
        let mut heights = Vec::new();
        let mut rendered = Vec::new();
        let mut bytes = 0usize;
        for row in &table.rows {
            let mut ascent = (size * 0.65).round() as i32;
            let mut descent = (size * 0.12).round() as i32;
            let mut cells = Vec::new();
            for (column, cell) in row.iter().enumerate() {
                let g = self.sequence_at(cell, size, depth + 1)?;
                bytes = bytes.saturating_add(g.mask.len());
                if bytes > 16_000_000 {
                    return Err(Error::new("invalid_layout", "表格子结构超过内存预算"));
                }
                widths[column] = widths[column].max(g.mask.width() as i32);
                ascent = ascent.max(-g.top);
                descent = descent.max(g.bottom());
                cells.push(g);
            }
            heights.push((ascent, descent));
            rendered.push(cells);
        }
        let mut xs = vec![0];
        for width in widths {
            xs.push(xs.last().unwrap() + width + pad * 2);
        }
        let mut ys = vec![0];
        for (ascent, descent) in &heights {
            ys.push(ys.last().unwrap() + ascent + descent + pad * 2);
        }
        let width = *xs.last().unwrap();
        let height = *ys.last().unwrap();
        Self::check_size(width as u32 + 4, height as u32 + 4)?;
        let offset = -height / 2;
        let mut children = Vec::new();
        for (row, cells) in rendered.into_iter().enumerate() {
            for (column, g) in cells.into_iter().enumerate() {
                let x = (xs[column] + xs[column + 1] - g.mask.width() as i32) / 2 - g.left;
                let y = offset + ys[row] + pad + heights[row].0;
                children.push((g, x, y));
            }
        }
        let mut paths = Vec::new();
        let mut draw = |rule, start: (i32, i32), end: (i32, i32)| {
            let thickness = if rule == TableRule::None {
                grid_thickness
            } else {
                thickness
            };
            let length = (end.0 - start.0).abs().max((end.1 - start.1).abs());
            if rule != TableRule::Dashed {
                // 轻微的中段偏移模拟手写直尺线，不引入逐格随机错位。
                let mid = ((start.0 + end.0) / 2, (start.1 + end.1) / 2);
                paths.push((vec![start, (mid.0, mid.1 + 1), end], thickness));
            } else {
                let dash = (size * 0.12).round().max(3.) as i32;
                for at in (0..length).step_by((dash * 2) as usize) {
                    let to = (at + dash).min(length);
                    let p = |v| {
                        if start.0 == end.0 {
                            (start.0, start.1 + v)
                        } else {
                            (start.0 + v, start.1)
                        }
                    };
                    paths.push((vec![p(at), p(to)], thickness));
                }
            }
        };
        for (index, rule) in table.vertical.iter().enumerate() {
            draw(*rule, (xs[index], offset), (xs[index], offset + height));
        }
        for (index, rule) in table.horizontal.iter().enumerate() {
            draw(*rule, (0, offset + ys[index]), (width, offset + ys[index]));
        }
        Self::compose((width + pad) as f32, children, paths)
    }
}
