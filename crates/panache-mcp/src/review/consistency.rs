//! Same-page review in native output pixels.
use super::{PageSample, REVIEW_MAX_EDGE};
use anyhow::Result;
use handwriting_core::{Cancellation, Parameters};
use image::{Pixel, Rgba, RgbaImage};
use serde_json::{Value, json};

type Region = [[u32; 2]; 4];

#[derive(Clone, Copy)]
pub(crate) struct Bounds {
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,
}

impl Bounds {
    pub fn from_corners(corners: [[f32; 2]; 4]) -> Self {
        let [x, y] = corners[0];
        let mut b = Self {
            left: x,
            top: y,
            right: x,
            bottom: y,
        };
        for [x, y] in corners {
            b.left = b.left.min(x);
            b.top = b.top.min(y);
            b.right = b.right.max(x);
            b.bottom = b.bottom.max(y);
        }
        b
    }

    fn union(self, b: Self) -> Self {
        Self {
            left: self.left.min(b.left),
            top: self.top.min(b.top),
            right: self.right.max(b.right),
            bottom: self.bottom.max(b.bottom),
        }
    }

    pub(super) fn center(self) -> [f32; 2] {
        [(self.left + self.right) / 2., (self.top + self.bottom) / 2.]
    }

    fn gap(self, other: Self) -> f32 {
        let x = (self.left.max(other.left) - self.right.min(other.right)).max(0.);
        let y = (self.top.max(other.top) - self.bottom.min(other.bottom)).max(0.);
        x.hypot(y)
    }

    pub(super) fn intersects(self, other: Self) -> bool {
        self.left < other.right
            && self.right > other.left
            && self.top < other.bottom
            && self.bottom > other.top
    }

    fn width(self) -> f32 {
        self.right - self.left
    }

    pub(super) fn height(self) -> f32 {
        self.bottom - self.top
    }

    pub(super) fn on_page(self, (w, h): (u32, u32)) -> bool {
        self.width() > 0.
            && self.height() > 0.
            && self.left >= 0.
            && self.top >= 0.
            && self.right <= w as f32
            && self.bottom <= h as f32
    }

    pub(super) fn region(self, padding: f32, (w, h): (u32, u32)) -> Option<Region> {
        let l = (self.left - padding).floor().clamp(0., w as f32) as u32;
        let t = (self.top - padding).floor().clamp(0., h as f32) as u32;
        let r = (self.right + padding).ceil().clamp(0., w as f32) as u32;
        let b = (self.bottom + padding).ceil().clamp(0., h as f32) as u32;
        (l < r && t < b).then_some([[l, t], [r, t], [r, b], [l, b]])
    }
}

pub(crate) struct TextSample {
    pub bounds: Bounds,
    pub baseline: f32,
    // Ratio of the two projected tile edge lengths normalized to the original tile aspect.
    pub stretch: f32,
    // Edited vertical centerline length in paper space, relative to the original tile height.
    pub paper_vertical_scale: f32,
}

pub(super) struct Check {
    pub metrics: Value,
    regions: Vec<Region>,
}

impl Check {
    pub fn guidance(&self, arguments: &impl Fn(Region) -> Value, inspect: &str) -> Value {
        let mut check = json!({"inspect":inspect});
        if let [region] = self.regions.as_slice() {
            check["preview_arguments"] = arguments(*region);
        } else {
            check["separate_preview_arguments"] = json!(
                self.regions
                    .iter()
                    .copied()
                    .map(arguments)
                    .collect::<Vec<_>>()
            );
        }
        check
    }
}

fn crops(pair: [Bounds; 2], anchors: [[f32; 2]; 2], size: (u32, u32), padding: f32) -> Vec<Region> {
    if let Some(r) = pair[0].union(pair[1]).region(padding, size)
        && r[2][0] - r[0][0] <= REVIEW_MAX_EDGE
        && r[2][1] - r[0][1] <= REVIEW_MAX_EDGE
    {
        return vec![r];
    }
    // At a distance, keep both samples at native resolution, centered on visible ink when available.
    anchors
        .iter()
        .filter_map(|&p| Bounds::from_corners([p; 4]).region(padding.clamp(64., 240.), size))
        .collect()
}

fn median(numbers: &mut [f32]) -> f32 {
    numbers.sort_unstable_by(f32::total_cmp);
    (numbers[numbers.len() / 2] + numbers[(numbers.len() - 1) / 2]) / 2.
}

fn adjacent_rows(text: &[&TextSample], size: (u32, u32), params: &Parameters) -> Option<Check> {
    let mut sorted = text.to_vec();
    sorted.sort_unstable_by(|a, b| a.baseline.total_cmp(&b.baseline));
    let spacing = params.line_spacing.max(1.);
    let mut rows: Vec<Vec<&TextSample>> = Vec::new();
    for glyph in sorted {
        if let Some(row) = rows.last_mut()
            && glyph.baseline - row[0].baseline <= spacing * 0.35
        {
            row.push(glyph);
        } else {
            rows.push(vec![glyph]);
        }
    }
    // Fields on the same baseline can belong to separate columns. Compare contiguous runs only.
    let rows: Vec<_> = rows
        .into_iter()
        .map(|mut row| {
            row.sort_unstable_by(|a, b| a.bounds.left.total_cmp(&b.bounds.left));
            let mut spans: Vec<Vec<&TextSample>> = Vec::new();
            let mut right = f32::NEG_INFINITY;
            for g in row {
                if g.bounds.left - right > 2.5 * g.bounds.height().max(g.bounds.width()) {
                    spans.push(Vec::new());
                    right = g.bounds.right;
                }
                right = right.max(g.bounds.right);
                spans.last_mut().unwrap().push(g);
            }
            spans
        })
        .collect();
    let mut best = None;
    for pair in rows.windows(2) {
        for upper in &pair[0] {
            for lower in &pair[1] {
                if lower[0].baseline - upper[0].baseline <= spacing * 2.5
                    && let Some((factor, check)) =
                        compare_spans(upper, lower, size, params.font_size)
                    && best.as_ref().is_none_or(|(prior, _)| factor > *prior)
                {
                    best = Some((factor, check));
                }
            }
        }
    }
    best.map(|(_, check)| check)
}

fn compare_spans(
    upper: &[&TextSample],
    lower: &[&TextSample],
    size: (u32, u32),
    font_size: f32,
) -> Option<(f32, Check)> {
    let extents = |row: &[&TextSample]| row.iter().map(|s| s.bounds).reduce(Bounds::union).unwrap();
    let a = extents(upper);
    let b = extents(lower);
    let left = a.left.max(b.left);
    let right = a.right.min(b.right);
    if left >= right {
        return None;
    }
    let mid = (left + right) / 2.;
    let radius = (font_size * 7.).clamp(80., 320.);
    let measure = |row: &[&TextSample]| {
        let samples = row.iter().filter(|g| {
            let x = g.bounds.center()[0];
            x >= left.max(mid - radius) && x <= right.min(mid + radius)
        });
        let mut stretches: Vec<_> = samples.clone().map(|g| g.stretch).collect();
        if stretches.len() < 3 {
            return None;
        }
        let mut scales: Vec<_> = samples.clone().map(|g| g.paper_vertical_scale).collect();
        let bounds = samples.map(|g| g.bounds).reduce(Bounds::union)?;
        Some((
            bounds,
            median(&mut stretches),
            median(&mut scales),
            stretches.len(),
        ))
    };
    let (first, a, upper_scale, n) = measure(upper)?;
    let (second, b, lower_scale, m) = measure(lower)?;
    if first.center()[1] >= second.center()[1] {
        return None;
    }
    let aspect_ratio = (a / b).max(b / a);
    let scale_ratio = (upper_scale / lower_scale).max(lower_scale / upper_scale);
    Some((
        aspect_ratio.max(scale_ratio),
        Check {
            metrics: json!({"sampled_glyphs":[n,m],"median_horizontal_to_vertical_stretch":[a,b],
            "larger_to_smaller_ratio":aspect_ratio,"median_paper_vertical_scale":[upper_scale,lower_scale],
            "larger_to_smaller_scale_ratio":scale_ratio,"photo_regions":[first.region(0.,size),second.region(0.,size)],
            "selection":"Largest change in median aspect or median vertical scale between adjacent text rows in a shared horizontal span, at least three glyphs per row. Stretch includes photo projection. Vertical scale measures the edited height in paper space relative to each tile’s own original height."}),
            regions: crops(
                [first, second],
                [first.center(), second.center()],
                size,
                font_size * 0.6,
            ),
        },
    ))
}

fn light(pixel: Rgba<u8>) -> u8 {
    let y = u16::from(pixel.to_luma()[0]);
    (255 - ((255 - y) * u16::from(pixel[3])).div_ceil(255)) as u8
}

fn darkness(
    region: Region,
    paper: &RgbaImage,
    finished: &RgbaImage,
    toward: [f32; 2],
    exclusions: &[Bounds],
    cancel: &Cancellation,
) -> Result<(Value, [f32; 2])> {
    let [l, t] = region[0];
    let [r, b] = region[2];
    let mut hist = [0u32; 256];
    let mut nearest = [(r + l) as f32 / 2., (b + t) as f32 / 2.];
    let mut min_distance = f32::INFINITY;
    // Only boxes crossing this scan line can obscure ownership. Merge by marking the row spans.
    let mut excluded = vec![false; (r - l) as usize];
    // Count runs through the added ink in four directions for a Crofton perimeter estimate.
    // A one-pixel empty border also closes runs touching an edge of the sample.
    let mut previous = vec![false; excluded.len() + 2];
    let mut current = previous.clone();
    let mut axial_runs = 0u64;
    let mut diagonal_runs = 0u64;
    let mut width_pixels = 0u64;
    let mut excluded_pixels = 0u32;
    for y in t..b {
        excluded.fill(false);
        for other in exclusions
            .iter()
            .filter(|g| (y as f32 + 0.5) >= g.top && (y as f32 + 0.5) < g.bottom)
        {
            let start = ((other.left - 0.5).ceil() as u32).clamp(l, r) - l;
            let end = ((other.right - 0.5).ceil() as u32).clamp(l, r) - l;
            excluded[start as usize..end as usize].fill(true);
        }
        cancel.check()?;
        for x in l..r {
            let i = (x - l) as usize + 1;
            current[i] = false;
            if excluded[(x - l) as usize] {
                excluded_pixels += 1;
                continue;
            }
            let delta = light(paper[(x, y)]).saturating_sub(light(finished[(x, y)]));
            if delta >= 32 {
                current[i] = true;
                width_pixels += 1;
                axial_runs += u64::from(!current[i - 1]) + u64::from(!previous[i]);
                diagonal_runs += u64::from(!previous[i - 1]) + u64::from(!previous[i + 1]);
            }
            if delta >= 8 {
                hist[usize::from(delta)] += 1;
                let dx = x as f32 - toward[0];
                let dy = y as f32 - toward[1];
                let distance = dx * dx + dy * dy;
                if distance < min_distance {
                    min_distance = distance;
                    nearest = [x as f32, y as f32];
                }
            }
        }
        std::mem::swap(&mut current, &mut previous);
    }
    let perimeter = std::f64::consts::FRAC_PI_4
        * (axial_runs as f64 + diagonal_runs as f64 * std::f64::consts::FRAC_1_SQRT_2);
    let width = (width_pixels >= 24).then(|| 2.0 * width_pixels as f64 / perimeter);
    let count = hist.iter().sum::<u32>();
    let percentile = |percent: u64| {
        let rank = (u64::from(count) * percent).div_ceil(100) as u32;
        let mut total = 0;
        hist.iter().position(|&n| {
            total += n;
            rank > 0 && total >= rank
        })
    };
    Ok((
        json!({"region":region, "darkened_pixels":count, "overlap_pixels_excluded":excluded_pixels, "median_luma_drop":percentile(50),"p90_luma_drop":percentile(90),
            "ink_footprint_width_px":width,"width_sample_pixels":width_pixels}),
        nearest,
    ))
}

pub(super) struct Checks {
    pub rows: Option<Check>,
    pub ink: Option<Check>,
}

pub(super) fn checks(
    sample: &PageSample,
    paper: &RgbaImage,
    finished: &RgbaImage,
    params: &Parameters,
    photo: bool,
    cancel: &Cancellation,
) -> Result<Checks> {
    let size = paper.dimensions();
    let text: Vec<_> = sample
        .text
        .iter()
        .filter(|g| {
            g.bounds.on_page(size)
                && g.stretch.is_finite()
                && g.stretch > 0.
                && g.paper_vertical_scale.is_finite()
                && g.paper_vertical_scale > 0.
        })
        .collect();
    let rows = if photo {
        adjacent_rows(&text, size, params)
    } else {
        None
    };
    let mut ink = None;
    if let Some(drawing) = sample.drawing
        && let Some(diagram_region) = drawing.region(0., size)
        && let Some(nearest) = text.iter().min_by(|a, b| {
            // A short line beside the diagram is usually a closer body-writing reference than a title above it.
            // Use simple geometric priorities and retain the actual separation in the receipt.
            let rank = |g: &TextSample| {
                let b = g.bounds;
                let side = (drawing.top..=drawing.bottom).contains(&b.center()[1])
                    && drawing.gap(b) <= b.height().max(16.) * 4.;
                (drawing.intersects(b), !side)
            };
            rank(a)
                .cmp(&rank(b))
                .then_with(|| drawing.gap(a.bounds).total_cmp(&drawing.gap(b.bounds)))
        })
    {
        let mut neighbors: Vec<_> = text
            .iter()
            .filter(|g| {
                let on_same_side = (g.bounds.center()[0] < drawing.center()[0])
                    == (nearest.bounds.center()[0] < drawing.center()[0]);
                on_same_side
                    && (g.baseline - nearest.baseline).abs() <= params.line_spacing * 0.25
                    && g.bounds.gap(nearest.bounds) <= nearest.bounds.height().max(16.) * 3.
                    && !drawing.intersects(g.bounds)
            })
            .collect();
        neighbors.sort_unstable_by(|a, b| {
            a.bounds
                .gap(nearest.bounds)
                .total_cmp(&b.bounds.gap(nearest.bounds))
        });
        let writing_box = neighbors
            .into_iter()
            .take(4)
            .fold(nearest.bounds, |b, g| b.union(g.bounds));
        let text_region = writing_box.region(0., size).unwrap();
        let overlaps: Vec<_> = text
            .iter()
            .map(|g| g.bounds)
            .filter(|b| b.intersects(drawing))
            .collect();
        let (diagram, stroke) = darkness(
            diagram_region,
            paper,
            finished,
            nearest.bounds.center(),
            &overlaps,
            cancel,
        )?;
        let (writing, letter) = darkness(text_region, paper, finished, stroke, &[drawing], cancel)?;
        let gap = drawing.gap(writing_box);
        ink = Some(Check {
            metrics: json!({"illustration":diagram,"nearby_text":writing,"minimum_luma_drop":8,"region_gap_px":gap, "distant_reference":gap > nearest.bounds.height().max(16.) * 6.,
                "width_method":"Width in native pixels estimated as twice the area divided by the four-direction Crofton perimeter of added ink with a luma drop of at least 32 (at least 24 pixels). Short strokes, joins, glyph shapes, softness and opacity affect this estimate. Compare the actual stems, lines and arrows in the crops.",
                "sampling":"Saved-paper luma minus output luma (0–255) among darkened pixels in each layout box. Text boxes overlapping the diagram are masked from its sample, and diagram pixels are excluded from the writing sample. A distant reference or too little sampled ink needs visual confirmation."}),
            regions: crops(
                [drawing, writing_box],
                [stroke, letter],
                size,
                params.font_size,
            ),
        });
    }
    Ok(Checks { rows, ink })
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::Rgba;

    fn bounds(left: f32, top: f32, right: f32, bottom: f32) -> Bounds {
        Bounds::from_corners([[left, top], [right, top], [right, bottom], [left, bottom]])
    }

    #[test]
    fn equally_dark_lines_have_distinct_footprint_widths() {
        let paper = RgbaImage::from_pixel(112, 18, Rgba([255; 4]));
        let mut finished = paper.clone();
        for (y, height) in [(1, 2), (9, 5)] {
            for row in y..y + height {
                for x in 5..105 {
                    finished[(x, row)] = Rgba([40, 40, 40, 255]);
                }
            }
        }
        let measure = |y, end| {
            darkness(
                [[0, y], [112, y], [112, end], [0, end]],
                &paper,
                &finished,
                [0., 0.],
                &[],
                &Cancellation::default(),
            )
            .unwrap()
            .0
        };
        let thin = measure(0, 7);
        let thick = measure(8, 18);
        assert_eq!(thin["median_luma_drop"], thick["median_luma_drop"]);
        assert!((1.8..2.3).contains(&thin["ink_footprint_width_px"].as_f64().unwrap()));
        assert!((4.6..5.4).contains(&thick["ink_footprint_width_px"].as_f64().unwrap()));
    }

    #[test]
    fn shared_pixels_do_not_count_as_diagram_or_body_ink() {
        let paper = RgbaImage::from_pixel(80, 60, Rgba([255; 4]));
        let mut finished = paper.clone();
        for y in 15..20 {
            for x in 15..20 {
                finished[(x, y)] = Rgba([0, 0, 0, 255]);
            }
        }
        let sample = PageSample {
            baselines: vec![],
            content_sha256: String::new(),
            drawing: Some(bounds(5., 5., 40., 40.)),
            text: vec![TextSample {
                bounds: bounds(15., 15., 20., 20.),
                baseline: 22.,
                stretch: 1.,
                paper_vertical_scale: 1.,
            }],
        };
        let check = checks(
            &sample,
            &paper,
            &finished,
            &Parameters::default(),
            true,
            &Cancellation::default(),
        )
        .unwrap()
        .ink
        .unwrap();
        for name in ["illustration", "nearby_text"] {
            let m = &check.metrics[name];
            assert_eq!(m["overlap_pixels_excluded"], 25);
            assert_eq!(m["darkened_pixels"], 0);
            assert!(m["p90_luma_drop"].is_null());
            assert!(m["ink_footprint_width_px"].is_null());
        }
    }

    #[test]
    fn distant_chart_and_writing_have_two_native_crops() {
        let paper = RgbaImage::from_pixel(1300, 100, Rgba([255; 4]));
        let mut finished = paper.clone();
        finished[(5, 5)] = Rgba([0, 0, 0, 255]);
        finished[(1105, 5)] = Rgba([127, 127, 127, 255]);
        let sample = PageSample {
            baselines: vec![],
            content_sha256: String::new(),
            drawing: Some(bounds(0., 0., 100., 80.)),
            text: vec![TextSample {
                bounds: bounds(1100., 0., 1150., 40.),
                baseline: 40.,
                stretch: 1.,
                paper_vertical_scale: 1.,
            }],
        };
        let check = checks(
            &sample,
            &paper,
            &finished,
            &Parameters::default(),
            true,
            &Cancellation::default(),
        )
        .unwrap()
        .ink
        .unwrap();
        assert_eq!(check.metrics["distant_reference"], true);
        assert_eq!(check.metrics["illustration"]["p90_luma_drop"], 255);
        assert_eq!(check.metrics["nearby_text"]["median_luma_drop"], 128);
        assert_eq!(check.regions.len(), 2);
        for (x, r) in [5, 1105].into_iter().zip(check.regions) {
            assert!(r[0][0] <= x && x < r[2][0]);
            assert!(r[2][0] - r[0][0] <= REVIEW_MAX_EDGE);
        }
    }

    #[test]
    fn larger_size_jump_is_selected_even_with_equal_letter_proportions() {
        let text: Vec<_> = [(28., 1.1, 1.), (58., 1., 1.), (88., 1., 1.5)]
            .into_iter()
            .flat_map(|(baseline, stretch, paper_vertical_scale)| {
                (0..5).map(move |i| {
                    let x = 20. + i as f32 * 18.;
                    TextSample {
                        bounds: bounds(x, baseline - 16. * paper_vertical_scale, x + 14., baseline),
                        baseline,
                        stretch,
                        paper_vertical_scale,
                    }
                })
            })
            .collect();
        let refs: Vec<_> = text.iter().collect();
        let check = adjacent_rows(
            &refs,
            (160, 120),
            &Parameters {
                line_spacing: 30.,
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(check.metrics["larger_to_smaller_ratio"], 1.);
        assert_eq!(
            check.metrics["median_paper_vertical_scale"],
            json!([1., 1.5])
        );
        assert_eq!(check.metrics["larger_to_smaller_scale_ratio"], 1.5);
    }

    #[test]
    fn separate_columns_do_not_form_a_comparable_row_pair() {
        let text: Vec<_> = [(0., 20., 1.), (200., 20., 1.), (80., 60., 2.)]
            .into_iter()
            .flat_map(|(x, y, stretch)| {
                (0..4).map(move |i| {
                    let l = x + i as f32 * 12.;
                    TextSample {
                        bounds: bounds(l, y - 15., l + 10., y),
                        baseline: y,
                        stretch,
                        paper_vertical_scale: 1.,
                    }
                })
            })
            .collect();
        let refs: Vec<_> = text.iter().collect();
        assert!(adjacent_rows(&refs, (400, 200), &Parameters::default()).is_none());
    }
}
