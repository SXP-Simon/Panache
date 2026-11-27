//! Sample the spread of repeatable dark printed edges on the untouched paper.
use crate::drafts::Snapshot;
use anyhow::Result;
use handwriting_core::{Limits, imaging};
use image::{GenericImageView, Pixel, Rgba};
use serde_json::{Value, json};
use std::{collections::VecDeque, sync::Mutex};

const GRID: u32 = 4;
const TRACKS: u32 = 9;
const WINDOW: u32 = 240;

#[derive(Clone, Copy)]
struct Edge {
    at: usize,
    contrast: i16,
    width: f32,
}

fn luma(pixel: Rgba<u8>) -> i16 {
    let opacity = u16::from(pixel[3]);
    (255 - ((255 - u16::from(pixel.to_luma()[0])) * opacity).div_ceil(255)) as i16
}

// Track the 20% and 80% crossings of a monotone edge relative to its own local contrast.
// Parallel profiles 2 px to either side reject isolated grain. Give diagonal edges to their
// stronger scan direction and correct the width of that projection.
fn stroke_edges(profile: &[[i16; 3]]) -> Vec<(usize, f32)> {
    let mut out = Vec::new();
    let mut descending: Option<Edge> = None;
    let mut i = 0;
    while i + 1 < profile.len() {
        let sign = (profile[i + 1][1] - profile[i][1]).signum();
        if sign == 0 {
            i += 1;
            continue;
        }
        let start = i;
        let mut peak = i;
        let mut slope = 0;
        while i + 1 < profile.len() {
            let d = sign * (profile[i + 1][1] - profile[i][1]);
            if d <= 0 {
                break;
            }
            if d > slope {
                peak = i;
                slope = d;
            }
            i += 1;
        }
        let contrast = sign * (profile[i][1] - profile[start][1]);
        if contrast < 22 || slope < 4 || i - start > 22 || start < 2 || i + 2 >= profile.len() {
            continue;
        }
        let transverse = (profile[peak][2] + profile[peak + 1][2]
            - profile[peak][0]
            - profile[peak + 1][0]) as f32
            / 8.;
        if transverse.abs() > f32::from(slope) {
            continue;
        }
        let coherent = [0, 2].into_iter().all(|j| {
            (-2isize..=2).any(|shift| {
                let a = (start as isize + shift) as usize;
                let b = (i as isize + shift) as usize;
                let d = sign * (profile[b][j] - profile[a][j]);
                d * 2 >= contrast && d <= contrast * 2
            })
        });
        if !coherent {
            continue;
        }
        let crossing = |fraction: f32| {
            let level = f32::from(contrast) * fraction;
            let mut k = start;
            while k + 1 < i && f32::from(sign * (profile[k + 1][1] - profile[start][1])) < level {
                k += 1;
            }
            k as f32
                + (level - f32::from(sign * (profile[k][1] - profile[start][1])))
                    / f32::from(sign * (profile[k + 1][1] - profile[k][1]))
        };
        let width =
            (crossing(0.8) - crossing(0.2)) * f32::from(slope) / f32::from(slope).hypot(transverse);
        let edge = Edge {
            at: peak,
            contrast,
            width,
        };
        if sign < 0 {
            descending = Some(edge);
        } else if let Some(other) = descending.take()
            && edge.at - other.at <= 36
            && edge.contrast.min(other.contrast) * 2 >= edge.contrast.max(other.contrast)
        {
            out.push((other.at, (other.width + edge.width) / 2.));
        }
    }
    out
}

#[derive(Clone, Copy)]
struct Sample {
    point: [u32; 2],
    cell: [u32; 2],
    horizontal_scan: bool,
    width: f32,
    strokes: usize,
    tracks: usize,
}

fn sample_cell(
    img: &impl GenericImageView<Pixel = Rgba<u8>>,
    cell: [u32; 2],
    horizontal: bool,
) -> Option<Sample> {
    let [w, h] = [img.width(), img.height()];
    let axis = |v: [u32; 2]| if horizontal { v } else { [v[1], v[0]] };
    let [along, across] = axis([w, h]);
    let [a, b] = axis(cell);
    let start = along * a / GRID;
    let end = along * (a + 1) / GRID;
    let lo = across * b / GRID;
    let hi = across * (b + 1) / GRID;
    if end - start < 20 || hi - lo < 8 {
        return None;
    }
    let windows = (end - start).div_ceil(WINDOW).min(3);
    let length = (end - start) / windows;
    let count = (hi - lo - 4).min(TRACKS);
    let mut samples = Vec::new();
    let mut supported = 0;
    for track in 0..count {
        let cross = lo + 2 + (2 * track + 1) * (hi - lo - 4) / (2 * count);
        let old = samples.len();
        for window in 0..windows {
            let size = length.min(WINDOW);
            let from = start + window * length + (length - size) / 2;
            let profile: Vec<_> = (from..from + size)
                .map(|x| {
                    [cross - 2, cross, cross + 2].map(|y| {
                        let [x, y] = axis([x, y]);
                        luma(img.get_pixel(x, y))
                    })
                })
                .collect();
            for (at, width) in stroke_edges(&profile) {
                samples.push((width, axis([from + at as u32, cross])));
            }
        }
        supported += usize::from(samples.len() > old);
    }
    if samples.len() < 6 || supported < 3 {
        return None;
    }
    samples.sort_unstable_by(|a, b| a.0.total_cmp(&b.0));
    let (width, point) = samples[samples.len() / 2];
    Some(Sample {
        point,
        cell,
        horizontal_scan: horizontal,
        width,
        strokes: samples.len(),
        tracks: supported,
    })
}

#[derive(Clone, Default)]
pub struct Profile {
    size: [u32; 2],
    samples: Vec<Sample>,
}

pub fn measure(img: &impl GenericImageView<Pixel = Rgba<u8>>) -> Profile {
    let mut profile = Profile {
        size: [img.width(), img.height()],
        samples: Vec::new(),
    };
    for y in 0..GRID {
        for x in 0..GRID {
            for horizontal in [true, false] {
                if let Some(s) = sample_cell(img, [x, y], horizontal) {
                    profile.samples.push(s);
                }
            }
        }
    }
    profile
}

impl Profile {
    pub fn report(&self, draft: &str, revision: u32, section: u32, page: usize) -> Value {
        let [w, h] = self.size;
        let crop = |[x, y]: [u32; 2]| {
            let cw = w.min(240);
            let ch = h.min(160);
            let l = x.saturating_sub(cw / 2).min(w - cw);
            let t = y.saturating_sub(ch / 2).min(h - ch);
            json!({"draft_id":draft,"revision":revision,"section":section,"page":page,"view":"review",
                "region":[[l,t],[l+cw,t],[l+cw,t+ch],[l,t+ch]]})
        };
        let site = |role: &str, s: &Sample| {
            json!({"role":role,"sample_point":s.point,"median_edge_width_px":s.width,"sampled_strokes":s.strokes,
            "supported_tracks":s.tracks,"scan_direction":if s.horizontal_scan {"horizontal"} else {"vertical"},
            "preview_arguments":crop(s.point)})
        };
        let mut cells = [false; 16];
        for s in &self.samples {
            cells[(s.cell[1] * GRID + s.cell[0]) as usize] = true;
        }
        let coverage = cells.iter().filter(|v| **v).count();
        let mut largest = None;
        let mut references = None;
        for a in &self.samples {
            for b in &self.samples {
                let difference = b.width - a.width;
                if a.horizontal_scan != b.horizontal_scan || a.cell == b.cell || difference < 0. {
                    continue;
                }
                if references.is_none_or(|(d, _, _)| difference > d) {
                    references = Some((difference, a, b));
                }
                if b.width >= 2.0
                    && difference >= 1.1
                    && b.width >= 1.65 * a.width
                    && largest.is_none_or(|(d, _, _)| difference > d)
                {
                    largest = Some((difference, a, b));
                }
            }
        }
        let mut regions = Vec::new();
        let status = if let Some((_, a, b)) = largest {
            regions.push(site("narrower_edges", a));
            regions.push(site("broader_edges", b));
            let mid = [(a.point[0] + b.point[0]) / 2, (a.point[1] + b.point[1]) / 2];
            let between = self
                .samples
                .iter()
                .filter(|s| {
                    s.horizontal_scan == a.horizontal_scan
                        && s.cell != a.cell
                        && s.cell != b.cell
                        && s.width > a.width + 0.25
                        && s.width < b.width - 0.25
                        && (0..2).all(|k| {
                            (a.cell[k].min(b.cell[k])..=a.cell[k].max(b.cell[k]))
                                .contains(&s.cell[k])
                        })
                })
                .min_by_key(|s| {
                    (0..2)
                        .map(|k| u64::from(s.point[k].abs_diff(mid[k])).pow(2))
                        .sum::<u64>()
                });
            regions.push(between.map_or_else(
                || json!({"role":"between_samples","preview_arguments":crop(mid)}),
                |s| site("intermediate_edges", s),
            ));
            "spatial_variation"
        } else if let Some(broadest) = self
            .samples
            .iter()
            .max_by(|a, b| a.width.total_cmp(&b.width))
        {
            if let Some((_, a, b)) = references {
                regions.push(site("narrower_reference", a));
                regions.push(site("broader_reference", b));
            } else {
                regions.push(site("paper_edge_sample", broadest));
            }
            let broad = self.samples.iter().all(|s| s.width >= 2.);
            let spread = (0..GRID).all(|k| {
                self.samples.iter().any(|s| s.cell[0] == k)
                    && self.samples.iter().any(|s| s.cell[1] == k)
            });
            if broad && coverage >= 8 && spread {
                "broad_edges_across_sheet"
            } else if broadest.width >= 2. {
                "broad_edges_in_samples"
            } else {
                "no_clear_softening_in_samples"
            }
        } else {
            regions.push(json!({"role":"inspect_paper","preview_arguments":crop([w/2,h/2])}));
            "insufficient_edge_support"
        };
        let guidance = match status {
            "spatial_variation" => {
                "底纸不同位置的深色印刷边缘过渡宽度有差异。按区域参数用原尺寸从较清晰处经过交界到较软处，对照当地纸上细线、图形轮廓、图内标签和正文。between_samples 是待核对点。"
            }
            "broad_edges_across_sheet" | "broad_edges_in_samples" => {
                "受支持的底纸样本有较宽的边缘过渡。按区域参数检查原尺寸印迹，比较各处图线、标签和正文与当地纸边。"
            }
            "insufficient_edge_support" => {
                "底纸上可重复测量的深色边缘不足。用原尺寸检查原纸上的细线或印字，尤其留意用户标注的位置。"
            }
            _ => {
                "采样差异未达显著门槛。有同向可比样本时，参考裁区给出较窄与较宽的实测边缘。缓慢渐变和很小的软区可能遗漏。沿同一条纸上印线或同类印字连续检查相邻区域，用原尺寸对照图线、图内标签和正文。"
            }
        };
        json!({"status":status,"supported_cells":coverage,"grid":[GRID,GRID],"regions":regions,"guidance":guidance,
            "local_edit_guidance":"优先检查用户指明的位置，可平移 region 连续查看过渡，保留原纸与清晰区。仅在裁图或用户反馈支持时，对可独立选择的字或图块分区小调 softness 后复看。若布局只给流程图及其标签一个字形 ID，softness 会影响整张图；需要只改某一部分应在可局部修改的图源中处理。",
            "method":"Native 20–80% lightness transition width on opposing, locally contrasted stroke edges, confirmed by parallel profiles. Comparisons use the same scan direction. Print, material and capture can all broaden an edge."})
    }
}

#[derive(Default)]
pub struct Cache(Mutex<VecDeque<(String, Profile)>>);

impl Cache {
    pub fn remember(&self, id: &str, profile: Profile) {
        let mut entries = self.0.lock().unwrap_or_else(|e| e.into_inner());
        entries.retain(|e| e.0 != id);
        entries.push_back((id.to_owned(), profile));
        if entries.len() > 32 {
            entries.pop_front();
        }
    }

    pub fn report(&self, draft: &Snapshot<'_>, section: u32, page: usize) -> Result<Option<Value>> {
        if draft.paper.is_none() {
            return Ok(None);
        }
        let profile = self
            .0
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .iter()
            .find(|e| e.0 == draft.id)
            .map(|e| e.1.clone());
        let profile = match profile {
            Some(v) => v,
            None => {
                let Some(bytes) = draft.background()? else {
                    return Ok(None);
                };
                let v = measure(&imaging::decode(&bytes, &Limits::default())?);
                self.remember(draft.id, v.clone());
                v
            }
        };
        Ok(Some(profile.report(
            draft.id,
            draft.revision,
            section,
            page,
        )))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{DynamicImage, GrayImage, Luma, imageops};

    fn rulings(vertical: bool, contrast: u8) -> GrayImage {
        GrayImage::from_fn(480, 480, |x, y| {
            let line = if vertical { x } else { y };
            Luma([if (line % 22) < 6 { 238 - contrast } else { 238 }])
        })
    }

    fn report(img: GrayImage) -> Value {
        measure(&DynamicImage::ImageLuma8(img)).report("draft", 2, 3, 4)
    }

    #[test]
    fn widths_follow_blur_in_either_direction_without_equating_ink_contrast_to_focus() {
        for vertical in [true, false] {
            let lines = rulings(vertical, 160);
            let soft = imageops::blur(&lines, 2.);
            let medium = imageops::blur(&lines, 1.1);
            let original = report(lines.clone());
            assert_eq!(original["status"], "no_clear_softening_in_samples");
            assert_eq!(original["regions"][0]["role"], "narrower_reference");
            assert_eq!(original["regions"][1]["role"], "broader_reference");
            assert_eq!(
                original["regions"][0]["scan_direction"],
                original["regions"][1]["scan_direction"]
            );
            assert_ne!(
                original["regions"][0]["sample_point"],
                original["regions"][1]["sample_point"]
            );
            assert_eq!(report(soft.clone())["status"], "broad_edges_across_sheet");
            let stages = GrayImage::from_fn(480, 480, |x, y| {
                *[&lines, &medium, &medium, &soft][x as usize / 120].get_pixel(x, y)
            });
            let result = report(stages);
            assert_eq!(result["status"], "spatial_variation", "{result}");
            assert_eq!(result["regions"][2]["role"], "intermediate_edges");
            let thinner = result["regions"][0]["median_edge_width_px"]
                .as_f64()
                .unwrap();
            let broader = result["regions"][1]["median_edge_width_px"]
                .as_f64()
                .unwrap();
            assert!(broader > thinner + 1.);
            let pale = rulings(vertical, 45);
            let colors =
                GrayImage::from_fn(
                    480,
                    480,
                    |x, y| if x < 240 { lines[(x, y)] } else { pale[(x, y)] },
                );
            assert_eq!(report(colors)["status"], original["status"]);
        }
    }

    #[test]
    fn blank_shadow_and_weak_grain_supply_no_supported_strokes() {
        let noisy = GrayImage::from_fn(480, 360, |x, y| {
            Luma([(160 + x / 12 + (x.wrapping_mul(y) % 8)) as u8])
        });
        for img in [GrayImage::from_pixel(480, 360, Luma([225])), noisy] {
            let r = report(img);
            assert_eq!(r["status"], "insufficient_edge_support");
            assert_eq!(r["supported_cells"], 0);
        }
    }
}
