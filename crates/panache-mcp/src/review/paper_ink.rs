//! Compare added writing with the contrast of actual photographed marks in the same neighborhood.
use super::{PageSample, TextSample, contains};
use crate::paper::focus::{luma, stroke_edges};
use anyhow::Result;
use handwriting_core::Cancellation;
use image::RgbaImage;
use serde_json::{Value, json};

type Region = [[u32; 2]; 4];

fn rectangle(l: u32, t: u32, r: u32, b: u32) -> Region {
    [[l, t], [r, t], [r, b], [l, b]]
}

fn quantile<T: Copy>(sorted: &[T], percent: usize) -> Option<T> {
    sorted
        .get((sorted.len() * percent).div_ceil(100).saturating_sub(1))
        .copied()
}

#[derive(Default)]
struct PaperMarks {
    contrasts: Vec<(u8, [u32; 2])>,
    tracks: usize,
    near_writing: bool,
}

impl PaperMarks {
    fn supported(&self) -> bool {
        self.contrasts.len() >= 6 && self.tracks >= 3
    }
}

fn sample_marks(
    paper: &RgbaImage,
    region: Region,
    boxes: &[Region],
    near_limit: f32,
    cancel: &Cancellation,
) -> Result<PaperMarks> {
    let mut all = PaperMarks::default();
    let mut near = PaperMarks {
        near_writing: true,
        ..Default::default()
    };
    for horizontal in [true, false] {
        let axes = |[x, y]: [u32; 2]| if horizontal { [x, y] } else { [y, x] };
        let [l, t] = axes(region[0]);
        let [r, b] = axes(region[2]);
        if b - t < 8 || r - l < 12 {
            continue;
        }
        let tracks = 16.min(b - t - 4);
        for i in 0..tracks {
            cancel.check()?;
            let cross = t + 2 + (2 * i + 1) * (b - t - 4) / (2 * tracks);
            let profile: Vec<_> = (l..r)
                .map(|along| {
                    [cross - 2, cross, cross + 2].map(|transverse| {
                        let [x, y] = axes([along, transverse]);
                        luma(paper[(x, y)])
                    })
                })
                .collect();
            let strokes = stroke_edges(&profile, 14, 3);
            all.tracks += usize::from(!strokes.is_empty());
            let before = near.contrasts.len();
            for s in strokes {
                let point = axes([l + s.darkest_at as u32, cross]);
                all.contrasts.push((s.contrast, point));
                if boxes.iter().any(|b| {
                    let dx = point[0].abs_diff(point[0].clamp(b[0][0], b[2][0]));
                    let dy = point[1].abs_diff(point[1].clamp(b[0][1], b[2][1]));
                    (dx as f32).hypot(dy as f32) <= near_limit
                }) {
                    near.contrasts.push((s.contrast, point));
                }
            }
            near.tracks += usize::from(near.contrasts.len() > before);
        }
    }
    let mut marks = if near.supported() { near } else { all };
    marks.contrasts.sort_unstable_by_key(|p| p.0);
    Ok(marks)
}

fn glyph_core(
    glyph: Region,
    window: Region,
    paper: &RgbaImage,
    finished: &RgbaImage,
) -> (usize, Option<u8>) {
    let mut histogram = [0usize; 256];
    let mut count = 0usize;
    for y in glyph[0][1].max(window[0][1])..glyph[2][1].min(window[2][1]) {
        for x in glyph[0][0].max(window[0][0])..glyph[2][0].min(window[2][0]) {
            let drop = luma(paper[(x, y)]) - luma(finished[(x, y)]);
            if drop >= 8 {
                histogram[drop as usize] += 1;
                count += 1;
            }
        }
    }
    let mut total = 0;
    let rank = (count * 9).div_ceil(10);
    let core = histogram
        .iter()
        .position(|n| {
            total += n;
            count >= 4 && total >= rank
        })
        .map(|i| i as u8);
    (count, core)
}

fn inspect(
    candidates: &[&TextSample],
    anchor: &TextSample,
    paper: &RgbaImage,
    finished: &RgbaImage,
    role: &str,
    cancel: &Cancellation,
) -> Result<Value> {
    let size = paper.dimensions();
    let [cx, cy] = anchor.bounds.center();
    let height = anchor.bounds.height().clamp(12., 100.);
    let mut neighbors: Vec<_> = candidates
        .iter()
        .copied()
        .filter(|g| {
            let [x, y] = g.bounds.center();
            (g.baseline - anchor.baseline).abs() < height * 0.5
                && (y - cy).abs() <= height
                && (x - cx).abs() <= (5. * height).clamp(90., 155.)
        })
        .collect();
    neighbors.sort_unstable_by(|a, b| {
        (a.bounds.center()[0] - cx)
            .abs()
            .total_cmp(&(b.bounds.center()[0] - cx).abs())
    });
    let boxes: Vec<_> = neighbors
        .iter()
        .take(12)
        .filter_map(|g| g.bounds.region(0., size))
        .collect();
    let mut ink_box = boxes[0];
    for b in &boxes {
        ink_box = rectangle(
            ink_box[0][0].min(b[0][0]),
            ink_box[0][1].min(b[0][1]),
            ink_box[2][0].max(b[2][0]),
            ink_box[2][1].max(b[2][1]),
        );
    }
    let (w, h) = size;
    // Fixed limits keep all reported regions at native scale, including unusually large transformed glyphs.
    let width = (ink_box[2][0] - ink_box[0][0] + 48).clamp(150, 480).min(w);
    let window_height = (ink_box[2][1] - ink_box[0][1] + (height * 2.4).clamp(64., 132.) as u32)
        .clamp(96, 232)
        .min(h);
    let l = ((ink_box[0][0] + ink_box[2][0]) / 2)
        .saturating_sub(width / 2)
        .min(w - width);
    let t = ((ink_box[0][1] + ink_box[2][1]) / 2)
        .saturating_sub(window_height / 2)
        .min(h - window_height);
    let region = rectangle(l, t, l + width, t + window_height);
    let paper_marks = sample_marks(paper, region, &boxes, height, cancel)?;
    let mut cores = Vec::new();
    let mut pixels = 0;
    for bounds in &boxes {
        cancel.check()?;
        let (count, core) = glyph_core(*bounds, region, paper, finished);
        pixels += count;
        cores.extend(core);
    }
    cores.sort_unstable();
    let writing = quantile(&cores, 50);
    let quartile = |q| quantile(&paper_marks.contrasts, q).map(|(v, _)| v);
    let supported = paper_marks.supported();
    let (p25, p50, p75) = (quartile(25), quartile(50), quartile(75));
    let upper_difference = writing
        .zip(p75)
        .filter(|_| supported && pixels >= 12)
        .map(|(ink, paper)| i16::from(ink) - i16::from(paper));
    let above = writing
        .zip(p75)
        .zip(upper_difference)
        .map(|((ink, paper), delta)| delta >= 24 && f32::from(ink) >= f32::from(paper) * 1.35);
    let status = match (writing, p25, p75) {
        _ if pixels < 12 || writing.is_none() => "insufficient_added_ink",
        _ if !supported => "insufficient_paper_marks",
        (Some(_), Some(lo), Some(hi)) if hi - lo > 32 && f32::from(hi) > f32::from(lo) * 1.65 => {
            "mixed_paper_marks"
        }
        _ if above == Some(true) => "writing_darker_than_sampled_marks",
        _ => "inspect_local_contrast",
    };
    Ok(
        json!({"role":role,"status":status,"region":region,"writing_region":ink_box,
        "added_writing":{"sampled_glyphs":cores.len(),"changed_pixel_samples":pixels,"median_glyph_p90_luma_drop":writing},
        "paper_marks":{"sampled_profiles":paper_marks.contrasts.len(),"supported_tracks":paper_marks.tracks,"supported":supported,
            "within_one_glyph_height":paper_marks.near_writing,"p25_luma_drop":p25,"median_luma_drop":p50,"p75_luma_drop":p75,
            "median_sample_point":quantile(&paper_marks.contrasts,50).map(|(_,point)|point)},
        "writing_minus_paper_p75":upper_difference,"clearly_above_paper_p75":above,
        "writing_minus_paper_median":writing.zip(p50).filter(|_|supported).map(|(a,b)|i16::from(a)-i16::from(b))}),
    )
}

pub(super) fn measure(
    sample: &PageSample,
    paper: &RgbaImage,
    finished: &RgbaImage,
    polygon: Option<&[[i32; 2]]>,
    cancel: &Cancellation,
) -> Result<Option<Value>> {
    let mut glyphs: Vec<_> = sample
        .text
        .iter()
        .filter(|g| {
            g.bounds.on_page(paper.dimensions())
                && g.baseline.is_finite()
                && sample.drawing.is_none_or(|b| !b.intersects(g.bounds))
                && polygon.is_none_or(|p| contains(p, g.bounds.center()))
        })
        .collect();
    glyphs.sort_unstable_by(|a, b| a.bounds.center()[1].total_cmp(&b.bounds.center()[1]));
    let Some(first) = glyphs.first() else {
        return Ok(None);
    };
    let mut rows = Vec::new();
    if let Some(poly) = polygon {
        let extent = |axis: usize| {
            poly.iter().fold((i32::MAX, i32::MIN), |(l, r), p| {
                (l.min(p[axis]), r.max(p[axis]))
            })
        };
        let mid = [0, 1].map(|axis| {
            let (l, r) = extent(axis);
            (l + r) as f32 / 2.
        });
        let distance = |g: &TextSample| {
            let [x, y] = g.bounds.center();
            (x - mid[0]).hypot(y - mid[1])
        };
        let anchor = glyphs
            .iter()
            .min_by(|a, b| distance(a).total_cmp(&distance(b)))
            .unwrap();
        rows.push(inspect(
            &glyphs,
            anchor,
            paper,
            finished,
            "selected_writing",
            cancel,
        )?);
    } else {
        let last = *glyphs.last().unwrap();
        let middle = glyphs[glyphs.len() / 2];
        let separation = |g: &TextSample| g.bounds.height().clamp(12., 100.) * 0.7;
        let below = |g: &TextSample, other: &TextSample| {
            g.bounds.center()[1] - other.bounds.center()[1] > separation(other)
        };
        let next = glyphs
            .iter()
            .copied()
            .find(|g| below(g, first) && g.baseline - first.baseline > separation(first));
        let mut anchors = vec![("first_written_row", *first)];
        if let Some(g) = next
            && below(last, g)
        {
            anchors.push(("following_written_row", g));
        }
        if below(middle, anchors.last().unwrap().1) && below(last, middle) {
            anchors.push(("middle_writing", middle));
        }
        if below(last, anchors.last().unwrap().1) {
            anchors.push(("lower_writing", last));
        }
        for (role, anchor) in anchors {
            rows.push(inspect(&glyphs, anchor, paper, finished, role, cancel)?);
        }
    }
    Ok(Some(
        json!({"samples":rows,"method":"Original paper: smaller of the two local light-to-dark edge drops on paired dark strokes, supported on parallel profiles. Added writing: median of each sampled text box’s 90th percentile paper-minus-output visible luma drop (changed pixels >=8). Scale 0–255. Profiles can revisit a single printed rule. The paper sample favors marks within one local glyph height, then uses the native context crop if support is sparse. The numeric difference flag requires added writing to exceed the paper P75 by at least 24 luma levels and by a factor of 1.35. Mark type, lighting and intended pen color affect the comparison."}),
    ))
}

pub(super) fn report(
    evidence: &Value,
    draft: &str,
    revision: u32,
    section: u32,
    page: usize,
) -> Value {
    let mut data = evidence.clone();
    for sample in data["samples"].as_array_mut().unwrap() {
        sample["preview_arguments"] = json!({"draft_id":draft,"revision":revision,"section":section,"page":page,"view":"review","region":sample["region"]});
        sample["layout_arguments"] = json!({"draft_id":draft,"revision":revision,"section":section,"page":page,"view":"layout","region":sample["writing_region"],"limit":32});
    }
    data["guidance"] = json!(
        "先看最上方实际落字，再对照中、下部或用户点名区域。按 preview_arguments 在原尺寸比较底纸/成图，核对当地横线、印字与新增字迹是否适合相互参照。差值是局部参考；淡横线与较深手写字可以是有意搭配。效果确实太重时，用 layout_arguments 核对目标字形，按当地印迹分区小调 opacity；有渐变时分段过渡，保留合适区域，用同一裁区复看。印迹混杂时仍可参考新增笔迹高于纸面样本较深四分位的幅度；先核对参照笔画种类和位置。印迹不足时仅凭数字不能判断。"
    );
    data
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::review::Bounds;
    use image::Rgba;

    fn check(source: impl Fn(u32, u32) -> u8, ink: u8) -> Value {
        let paper = RgbaImage::from_fn(320, 180, |x, y| {
            let v = source(x, y);
            Rgba([v, v, v, 255])
        });
        let mut output = paper.clone();
        let mut text = vec![];
        for x in [114, 138, 162, 186] {
            text.push(TextSample {
                bounds: Bounds::from_corners([
                    [x as f32, 66.],
                    [(x + 14) as f32, 66.],
                    [(x + 14) as f32, 88.],
                    [x as f32, 88.],
                ]),
                baseline: 88.,
                stretch: 1.,
                paper_vertical_scale: 1.,
            });
            for yy in 69..85 {
                for xx in x + 3..x + 6 {
                    let v = paper[(xx, yy)][0].saturating_sub(ink);
                    output[(xx, yy)] = Rgba([v, v, v, 255]);
                }
            }
        }
        let sample = PageSample {
            baselines: vec![],
            text,
            drawing: None,
            content_sha256: String::new(),
        };
        measure(&sample, &paper, &output, None, &Cancellation::default())
            .unwrap()
            .unwrap()["samples"][0]
            .clone()
    }

    #[test]
    fn local_light_and_dark_rules_do_not_imply_the_same_ink_direction() {
        let faint = check(|_, y| if y % 14 < 2 { 186 } else { 224 }, 120);
        assert_eq!(faint["status"], "writing_darker_than_sampled_marks");
        assert_eq!(faint["paper_marks"]["median_luma_drop"], 38);
        assert_eq!(faint["added_writing"]["median_glyph_p90_luma_drop"], 120);
        let dark = check(|_, y| if y % 14 < 2 { 90 } else { 224 }, 120);
        assert_eq!(dark["status"], "inspect_local_contrast");
        assert_eq!(dark["paper_marks"]["median_luma_drop"], 134);
    }

    #[test]
    fn mixed_print_shadow_and_invisible_writing_have_explicit_limits() {
        let mixed = check(
            |_, y| {
                if y % 14 > 1 {
                    224
                } else if y % 28 < 2 {
                    191
                } else {
                    88
                }
            },
            141,
        );
        assert_eq!(mixed["status"], "mixed_paper_marks");
        assert_eq!(mixed["clearly_above_paper_p75"], false);
        let heavier = check(
            |_, y| {
                if y % 14 > 1 {
                    224
                } else if y % 28 < 2 {
                    191
                } else {
                    88
                }
            },
            205,
        );
        assert_eq!(heavier["status"], "mixed_paper_marks");
        assert_eq!(heavier["clearly_above_paper_p75"], true);
        let shadow = check(|x, _| 192 + (x / 16) as u8, 110);
        assert_eq!(shadow["status"], "insufficient_paper_marks");
        assert!(shadow["writing_minus_paper_median"].is_null());
        let empty = check(|_, y| if y % 14 < 2 { 185 } else { 215 }, 0);
        assert_eq!(empty["status"], "insufficient_added_ink");
        assert!(empty["added_writing"]["median_glyph_p90_luma_drop"].is_null());
    }
}
