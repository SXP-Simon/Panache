use hayro::kurbo::Rect;

// 2026-11-23：按绘制次序检查每行的背景色和后续遮挡；空间分桶避免逐字遍历整张纸。
const ROW: f64 = 32.0;

#[derive(Clone, Copy)]
struct Mark {
    bounds: Rect,
    solid: Option<[u8; 3]>,
    text: Option<usize>,
}

pub(super) struct Visibility {
    rows: Vec<Vec<Mark>>,
    budget: usize,
}

impl Visibility {
    pub fn new(height: f64) -> Self {
        Self {
            rows: vec![Vec::new(); (height / ROW).ceil() as usize],
            budget: 4_000_000,
        }
    }
    fn rows_for(&self, bounds: Rect) -> std::ops::Range<usize> {
        ((bounds.y0 / ROW).floor() as usize).min(self.rows.len())
            ..((bounds.y1 / ROW).ceil() as usize).min(self.rows.len())
    }
    pub fn exhausted(&self) -> bool {
        self.budget == 0
    }
    pub fn visible(&mut self, bounds: Rect, ink: [u8; 3], candidate: usize) -> bool {
        for idx in self.rows_for(bounds) {
            let slice = Rect::new(
                bounds.x0,
                bounds.y0.max(idx as f64 * ROW),
                bounds.x1,
                bounds.y1.min((idx + 1) as f64 * ROW),
            );
            let mut paper = [255; 3];
            for mark in self.rows[idx].iter().rev() {
                self.budget = self.budget.saturating_sub(1);
                if self.budget == 0 {
                    return false;
                }
                if mark.text == Some(candidate) || mark.bounds.intersect(slice).area() <= 0.0 {
                    continue;
                }
                let Some(color) = mark.solid.filter(|_| mark.bounds.contains_rect(slice)) else {
                    return false;
                };
                paper = color;
                break;
            }
            if ink.iter().zip(paper).all(|(i, b)| i.abs_diff(b) < 24) {
                return false;
            }
        }
        true
    }
    pub fn paint(
        &mut self,
        bounds: Rect,
        solid: Option<[u8; 3]>,
        text: Option<usize>,
        mut cover: impl FnMut(usize),
    ) {
        if bounds.area() <= 0.0 || !bounds.is_finite() {
            return;
        }
        for row in self.rows_for(bounds) {
            if self.budget == 0 {
                return;
            }
            let marks = &mut self.rows[row];
            for mark in marks.iter() {
                self.budget = self.budget.saturating_sub(1);
                if self.budget == 0 {
                    return;
                }
                if let Some(id) = mark.text
                    && Some(id) != text
                    && mark.bounds.intersect(bounds).area() > 0.0
                {
                    cover(id);
                }
            }
            marks.push(Mark {
                bounds,
                solid,
                text,
            });
        }
    }
}
