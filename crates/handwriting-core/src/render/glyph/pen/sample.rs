//! Sample the primary font once to choose the geometry of the mathematical pen.
use super::super::radical::RootShape;
use super::{Glyph, Glyphs, GrayImage, MathPen};
use fontdue::Font;

const SAMPLE_SIZE: f32 = 96.;

impl MathPen {
    pub fn sample(font: &Font) -> Self {
        let mut widths: Vec<_> = ['n', 'x', '1', '十', '口']
            .into_iter()
            .filter_map(|c| stroke_width(font, c))
            .collect();
        widths.sort_by(f32::total_cmp);
        let width = widths
            .get(widths.len() / 2)
            .copied()
            .unwrap_or(0.025)
            .clamp(0.009, 0.065);
        let (x, _) = font.rasterize('x', SAMPLE_SIZE);
        let (height, axis) = if x.height > 0 {
            (
                (x.height as f32 / SAMPLE_SIZE).clamp(0.30, 0.70),
                -(x.height as f32 / 2. + x.ymin as f32) / SAMPLE_SIZE,
            )
        } else {
            (0.48, -0.27)
        };
        Self {
            width,
            axis: axis.clamp(-0.4, -0.16),
            height,
            slant: slant(font),
            chevrons: ['<', '>'].map(|c| sample_chevron(font, c)),
            root: RootShape::sample(font),
            naturalness: 0.,
            seed: 0,
        }
    }
}

fn stroke_width(font: &Font, c: char) -> Option<f32> {
    if font.lookup_glyph_index(c) == 0 {
        return None;
    }
    let (m, data) = font.rasterize(c, SAMPLE_SIZE);
    let mut area = 0.;
    let mut perimeter = 0.;
    for y in 0..m.height {
        for x in 0..m.width {
            if data[y * m.width + x] < 96 {
                continue;
            }
            area += 1.;
            for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                let (xx, yy) = (x as i32 + dx, y as i32 + dy);
                if xx < 0
                    || yy < 0
                    || xx >= m.width as i32
                    || yy >= m.height as i32
                    || data[yy as usize * m.width + xx as usize] < 96
                {
                    perimeter += 1.;
                }
            }
        }
    }

    (perimeter > 0.).then(|| 2. * area / perimeter / SAMPLE_SIZE)
}

fn slant(font: &Font) -> f32 {
    let (m, data) = font.rasterize('1', SAMPLE_SIZE);
    // The first and last occupied scan lines determine the slope of the digit's middle third.
    let mut centers = (m.height / 3..m.height * 2 / 3).filter_map(|y| {
        let row = &data[y * m.width..(y + 1) * m.width];
        let mut sum = 0;
        let mut count: usize = 0;
        for (x, &alpha) in row.iter().enumerate() {
            if alpha >= 128 {
                sum += x;
                count += 1;
            }
        }
        (count > 0).then(|| (y as f32, sum as f32 / count as f32))
    });
    let Some(first) = centers.next() else {
        return 0.;
    };
    let last = centers.next_back().unwrap_or(first);
    ((first.1 - last.1) / (last.0 - first.0).max(1.)).clamp(-0.12, 0.12)
}

fn sample_chevron(font: &Font, c: char) -> Option<GrayImage> {
    if font.lookup_glyph_index(c) == 0 {
        return None;
    }
    let (m, data) = font.rasterize(c, SAMPLE_SIZE);
    if m.width < 3 || m.height < 3 {
        return None;
    }
    let g = Glyphs::trim(Glyph {
        mask: GrayImage::from_raw(m.width as u32, m.height as u32, data)?,
        advance: m.advance_width,
        left: 0,
        top: 0,
        ink: true,
    });
    let mask = g.mask;
    let mut bands = [(0., 0.); 3];
    for (x, y, p) in mask.enumerate_pixels() {
        if p[0] >= 96 {
            let band = (y * 3 / mask.height()).min(2) as usize;
            bands[band].0 += x as f32;
            bands[band].1 += 1.;
        }
    }
    if bands.iter().any(|b| b.1 == 0.) {
        return None;
    }
    let outer = (bands[0].0 / bands[0].1 + bands[2].0 / bands[2].1) / 2.;
    let middle = bands[1].0 / bands[1].1;
    let direction = if c == '<' {
        outer - middle
    } else {
        middle - outer
    };
    (direction > mask.width() as f32 * 0.12).then_some(mask)
}
