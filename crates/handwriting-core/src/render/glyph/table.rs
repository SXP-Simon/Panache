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

        let mut widths = vec![(size * 0.35).round() as i32; columns];
        let mut row_height = (size * 0.77).round() as i32;
        let mut rendered = Vec::new();
        let mut bytes = 0usize;
        for row in &table.rows {
            let mut cells = Vec::new();
            for (column, cell) in row.iter().enumerate() {
                let g = self.sequence_at(cell, size, depth + 1)?;
                bytes = bytes.saturating_add(g.mask.len());
                if bytes > 16_000_000 {
                    return Err(Error::new("invalid_layout", "表格子结构超过内存预算"));
                }
                widths[column] = widths[column].max(g.mask.width() as i32);
                row_height = row_height.max(g.mask.height() as i32);
                cells.push(g);
            }

            rendered.push(cells);
        }
        let mut xs = vec![0];
        for width in widths {
            xs.push(xs.last().unwrap() + width + pad * 2);
        }
        let mut ys = vec![0];
        for _ in &table.rows {
            ys.push(ys.last().unwrap() + row_height + pad * 2);
        }
        let width = *xs.last().unwrap();
        let height = *ys.last().unwrap();
        Self::check_size(width as u32 + 4, height as u32 + 4)?;
        let offset = -height / 2;
        let mut children = Vec::new();
        for (row, cells) in rendered.into_iter().enumerate() {
            for (column, g) in cells.into_iter().enumerate() {
                let x = (xs[column] + xs[column + 1] - g.mask.width() as i32) / 2 - g.left;
                // 2026-10-20：以实际墨迹居中，避免字体基线差异让数字和分数上下漂移。
                let y = offset + (ys[row] + ys[row + 1] - g.mask.height() as i32) / 2 - g.top;
                children.push((g, x, y));
            }
        }
        let mut paths = Vec::new();
        let mut draw = |rule, start: (i32, i32), end: (i32, i32)| {
            let thickness = grid_thickness;
            let length = (end.0 - start.0).abs().max((end.1 - start.1).abs());
            if rule != TableRule::Dashed {
                // 2026-10-20：各边共用精确端点和笔宽，不对格线添加人为抖动。
                paths.push((vec![start, end], thickness));
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
