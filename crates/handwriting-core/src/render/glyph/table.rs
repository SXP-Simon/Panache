//! 2026-10-20：整表按真实手写墨迹测量列宽与基线，作为单个刚性结构缩放和分页。
use super::*;
use crate::text::{Table, TableKind, TableRule};
use rand::RngExt;
pub(super) mod matrix;

/// Every row has the same height, while columns follow the widest ink in each column.
struct TableCells {
    rows: Vec<Vec<Glyph>>,
    column_edges: Vec<i32>,
    row_height: i32,
    pad: i32,
}

impl TableCells {
    fn measure(glyphs: &mut Glyphs<'_>, table: &Table, size: f32, depth: usize) -> Result<Self> {
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

        let mut widths = vec![(size * 0.35).round() as i32; columns];
        let mut row_height = (size * 0.77).round() as i32;
        let mut rendered = Vec::new();
        let mut bytes = 0usize;
        for row in &table.rows {
            let mut cells = Vec::new();
            for (column, cell) in row.iter().enumerate() {
                let g = glyphs.sequence_at(cell, size, depth + 1)?;
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
        let mut column_edges = vec![0];
        for width in widths {
            column_edges.push(column_edges.last().unwrap() + width + pad * 2);
        }
        Ok(Self {
            rows: rendered,
            column_edges,
            row_height: row_height + pad * 2,
            pad,
        })
    }

    fn width(&self) -> i32 {
        *self.column_edges.last().unwrap()
    }

    fn height(&self) -> i32 {
        self.rows.len() as i32 * self.row_height
    }

    fn positioned(self, kind: TableKind, inset: i32, offset: i32) -> Vec<PositionedGlyph> {
        let mut children = Vec::new();
        for (row, cells) in self.rows.into_iter().enumerate() {
            for (g, edges) in cells.into_iter().zip(self.column_edges.windows(2)) {
                let x = if kind == TableKind::Cases {
                    edges[0] + self.pad
                } else {
                    (edges[0] + edges[1] - g.mask.width() as i32) / 2
                };
                let y =
                    row as i32 * self.row_height + (self.row_height - g.mask.height() as i32) / 2;
                let (left, top) = (inset + x - g.left, offset + y - g.top);
                children.push((g, left, top));
            }
        }
        children
    }

    fn rules(
        &self,
        table: &Table,
        inset: i32,
        offset: i32,
        size: f32,
        thickness: i32,
    ) -> Vec<Path> {
        let dash = (size * 0.12).round().max(3.) as i32;
        let mut paths = Vec::new();
        let mut draw = |rule, start: (i32, i32), direction: (i32, i32), length| {
            let point = |v| (start.0 + direction.0 * v, start.1 + direction.1 * v);
            match rule {
                TableRule::None if table.kind != TableKind::Grid => (),
                TableRule::Dashed => {
                    for at in (0..length).step_by((dash * 2) as usize) {
                        paths.push((vec![point(at), point((at + dash).min(length))], thickness));
                    }
                }
                _ => paths.push((vec![start, point(length)], thickness)),
            }
        };
        for (&x, &rule) in self.column_edges.iter().zip(&table.vertical) {
            draw(rule, (inset + x, offset), (0, 1), self.height());
        }
        for (row, &rule) in table.horizontal.iter().enumerate() {
            draw(
                rule,
                (inset, offset + row as i32 * self.row_height),
                (1, 0),
                self.width(),
            );
        }
        paths
    }
}

impl Glyphs<'_> {
    pub(super) fn table(&mut self, table: &Table, size: f32, depth: usize) -> Result<Glyph> {
        let cells = TableCells::measure(self, table, size, depth)?;
        let (width, height) = (cells.width(), cells.height());
        Self::check_size(width as u32 + 4, height as u32 + 4)?;
        let offset = if table.kind == TableKind::Grid {
            -height / 2
        } else {
            let x = self.glyph('x', size)?;
            (x.top + x.bottom()) / 2 - height / 2
        };
        let (inset, delimiters) = matrix::delimiters(table.kind, width, height, size);
        let thickness = (size * 0.025).round().max(1.) as i32;
        let mut paths = cells.rules(table, inset, offset, size, thickness);
        let reach = (size * 0.105).min(5.) * self.pen.naturalness;
        if table.kind == TableKind::Grid && corner_tails_fit(width, height, thickness, reach) {
            // Draw corner extensions in row order so the pen consumes the same random sequence.
            let mut rng = self.next_drawing_rng();
            let rows = [
                (0, -1, table.horizontal[0]),
                (height, 1, *table.horizontal.last().unwrap()),
            ];
            let columns = [
                (0, -1, table.vertical[0]),
                (width, 1, *table.vertical.last().unwrap()),
            ];
            for (y, dy, horizontal) in rows {
                for (x, dx, vertical) in columns {
                    if horizontal == TableRule::Dashed || vertical == TableRule::Dashed {
                        continue;
                    }
                    let tail = (rng.random_range(-1.0f32..1.) * reach).round() as i32;
                    if tail == 0 {
                        continue;
                    }
                    let corner = (inset + x, offset + y);
                    let tip = if tail > 0 {
                        (corner.0 + dx * tail, corner.1)
                    } else {
                        (corner.0, corner.1 + dy * tail.abs())
                    };
                    paths.push((vec![corner, tip], thickness));
                }
            }
        }
        paths.extend(delimiters.into_iter().map(|(points, thickness)| {
            (
                points.into_iter().map(|(x, y)| (x, y + offset)).collect(),
                thickness,
            )
        }));
        let right = if table.kind == TableKind::Cases {
            0
        } else {
            inset
        };
        let advance = (width + inset + right + cells.pad) as f32;
        let mut result =
            Self::compose(advance, cells.positioned(table.kind, inset, offset), paths)?;
        if table.kind == TableKind::Matrix {
            let axis = self.glyph('x', size)?;
            result.top += (axis.top + axis.bottom() - result.top - result.bottom()) / 2;
        }
        Ok(result)
    }
}

// 与 compose 的圆笔边界一致；接近栅格上限时保留原有表框。
fn corner_tails_fit(width: i32, height: i32, thickness: i32, reach: f32) -> bool {
    let tail = reach.round() as i32;
    let padding = 2 * (thickness / 2 + tail) + 1;
    tail > 0 && Glyphs::check_size((width + padding) as u32, (height + padding) as u32).is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn optional_tails_respect_dimension_and_area_budgets() {
        for (w, h) in [(32760, 20), (20, 8184), (3995, 3995)] {
            assert!(Glyphs::check_size(w as u32 + 4, h as u32 + 4).is_ok());
            assert!(!corner_tails_fit(w, h, 3, 5.));
        }
        assert!(corner_tails_fit(500, 300, 3, 5.));
    }
}
