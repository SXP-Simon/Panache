//! Track printed rulings across a photograph and flatten the writing area.
use super::{Identification, has_printed_header};
use crate::{
    Result,
    export::CameraMetadata,
    photo::{PaperProjection, Ruling},
};
use base64::Engine;
use image::{Rgba, RgbaImage};

const STRIPS: usize = 9;
const MID: usize = STRIPS / 2;
const MIN_TRACKED_LINES: usize = 6;

fn strip_centers(rows: &[u32], threshold: u32) -> Vec<f32> {
    let mut centers = Vec::new();
    let gap = (rows.len() / 220).max(2);
    let (mut first, mut last, mut count, mut weighted) = (0, 0, 0., 0.);
    for (y, value) in rows
        .iter()
        .copied()
        .enumerate()
        .filter(|(_, n)| *n >= threshold)
    {
        if count == 0. || y - last > gap {
            if count > 0. && last - first <= gap * 2 {
                centers.push(weighted / count);
            }
            first = y;
            count = 0.;
            weighted = 0.;
        }
        last = y;
        count += value as f32;
        weighted += y as f32 * value as f32;
    }
    if count > 0. && last - first <= gap * 2 {
        centers.push(weighted / count);
    }
    centers
}

fn nearest_ruling(strip: &[f32], y: f32, tolerance: f32) -> f32 {
    if strip.is_empty() || !y.is_finite() {
        return f32::NAN;
    }
    let next = strip.partition_point(|candidate| *candidate < y);
    let left = strip[next.saturating_sub(1)];
    let right = strip[next.min(strip.len() - 1)];
    let matched = if (y - left).abs() < (right - y).abs() {
        left
    } else {
        right
    };
    if (matched - y).abs() <= tolerance {
        matched
    } else {
        f32::NAN
    }
}

fn smooth_ruling_run(centers: &[f32]) -> &[f32] {
    let mut start = 0;
    let mut best = &centers[..0];
    for (i, window) in centers.windows(3).enumerate() {
        let previous = window[1] - window[0];
        let next = window[2] - window[1];
        if next < 0.75 * previous || next > 1.33 * previous {
            if i + 2 - start > best.len() {
                best = &centers[start..i + 2];
            }
            start = i + 1;
        }
    }
    if centers.len() - start > best.len() {
        &centers[start..]
    } else {
        best
    }
}

fn sample_strips(
    points: &[(f32, f32)],
    w: u32,
    h: u32,
    columns: &[f32; STRIPS],
) -> [Vec<f32>; STRIPS] {
    let radius = (w / 120).max(4) as f32;
    let mut rows = vec![[0; STRIPS]; h as usize];
    for &(x, y) in points {
        let x = x + w as f32 / 2.;
        let index = ((x / w as f32 - 0.22) / 0.07).round() as usize;
        if index < STRIPS && (x - columns[index]).abs() < radius {
            rows[(y + h as f32 / 2.) as usize][index] += 1;
        }
    }
    std::array::from_fn(|index| {
        let profile: Vec<_> = rows.iter().map(|row| row[index]).collect();
        strip_centers(&profile, (radius * 0.8).ceil() as u32)
    })
}

fn follow_strips(
    indices: impl Iterator<Item = usize>,
    strips: &[Vec<f32>; STRIPS],
    tracks: &mut [Vec<f32>; STRIPS],
    sequence: &[f32],
    tolerances: &[f32],
) {
    let mut previous = sequence.to_vec();
    for index in indices {
        tracks[index] = previous
            .iter_mut()
            .zip(tolerances)
            .map(|(y, &tolerance)| {
                let matched = nearest_ruling(&strips[index], *y, tolerance);
                if matched.is_finite() {
                    *y = matched;
                }
                matched
            })
            .collect();
    }
}

fn track_sequence(strips: &[Vec<f32>; STRIPS], sequence: &[f32]) -> [Vec<f32>; STRIPS] {
    let mut tracks: [Vec<f32>; STRIPS] = std::array::from_fn(|_| Vec::new());
    tracks[MID] = sequence.to_vec();
    let tolerances: Vec<_> = (0..sequence.len())
        .map(|i| {
            let previous = if i == 0 {
                f32::INFINITY
            } else {
                sequence[i] - sequence[i - 1]
            };
            let next = sequence
                .get(i + 1)
                .map_or(f32::INFINITY, |y| y - sequence[i]);
            previous.min(next) * 0.42
        })
        .collect();
    follow_strips((0..MID).rev(), strips, &mut tracks, sequence, &tolerances);
    follow_strips(MID + 1..STRIPS, strips, &mut tracks, sequence, &tolerances);
    // Interpolate only an isolated missing sample with measured neighbors.
    for index in 1..STRIPS - 1 {
        let (before, rest) = tracks.split_at_mut(index);
        let (middle, after) = rest.split_at_mut(1);
        for (i, y) in middle[0].iter_mut().enumerate() {
            let (left, right) = (before[index - 1][i], after[0][i]);
            if !y.is_finite() && (left - right).abs() <= tolerances[i] {
                *y = (left + right) / 2.;
            }
        }
    }
    tracks
}

struct RulingGrid {
    columns: [f32; STRIPS],
    tracks: [Vec<f32>; STRIPS],
    confidence: f32,
}

impl RulingGrid {
    fn detect(points: &[(f32, f32)], w: u32, h: u32) -> Option<Self> {
        let columns: [f32; STRIPS] = std::array::from_fn(|i| w as f32 * (0.22 + i as f32 * 0.07));
        let strips = sample_strips(points, w, h, &columns);
        let sequence = smooth_ruling_run(&strips[MID]);
        if sequence.len() < MIN_TRACKED_LINES
            || sequence.windows(2).any(|pair| pair[1] - pair[0] < 5.)
        {
            return None;
        }
        let mut tracks = track_sequence(&strips, sequence);
        let mut start = 0;
        let mut run = 0..0;
        for i in 0..=sequence.len() {
            if i == sequence.len() || tracks.iter().any(|track| !track[i].is_finite()) {
                if i - start > run.len() {
                    run = start..i;
                }
                start = i + 1;
            }
        }
        if run.len() < MIN_TRACKED_LINES || run.len() * 4 < sequence.len() * 3 {
            return None;
        }
        let confidence = run.len() as f32 / sequence.len() as f32;
        for track in &mut tracks {
            track.truncate(run.end);
            track.drain(..run.start);
        }
        Some(Self {
            columns,
            tracks,
            confidence,
        })
    }

    fn nonlinear(&self, spacing: f32) -> bool {
        let first = self.tracks[MID][0];
        let slope = (self.tracks[STRIPS - 1][0] - self.tracks[0][0])
            / (self.columns[STRIPS - 1] - self.columns[0]);
        self.tracks.iter().zip(self.columns).any(|(track, x)| {
            track.iter().enumerate().any(|(i, y)| {
                (y - (first + spacing * i as f32 + slope * (x - self.columns[MID]))).abs() > 3.
            })
        })
    }

    fn heights_at(&self, x: f32) -> impl Iterator<Item = f32> {
        let j = self
            .columns
            .partition_point(|column| *column < x)
            .saturating_sub(1)
            .min(STRIPS - 2);
        let t = (x - self.columns[j]) / (self.columns[j + 1] - self.columns[j]);
        self.tracks[j]
            .iter()
            .zip(&self.tracks[j + 1])
            .map(move |(&left, &right)| left + t * (right - left))
    }
}

fn writing_edges(
    grid: &RulingGrid,
    points: &[(f32, f32)],
    w: u32,
    h: u32,
) -> Option<(Vec<usize>, Vec<usize>)> {
    let analysis_tracks: Vec<Vec<f32>> = (0..w)
        .map(|x| grid.heights_at(x as f32).collect())
        .collect();
    if analysis_tracks
        .iter()
        .any(|track| track.windows(2).any(|pair| pair[0] >= pair[1]))
    {
        return None;
    }
    let mut support = vec![vec![false; w as usize]; grid.tracks[MID].len()];
    for &(x, y) in points {
        let x = (x + w as f32 / 2.) as usize;
        let y = y + h as f32 / 2.;
        let track = &analysis_tracks[x];
        let first = track.partition_point(|line| *line < y - 3.);
        if track.get(first).is_some_and(|line| *line <= y + 3.) {
            support[first][x] = true;
        }
    }
    // Use the shared writing area when perspective makes the lower rows wider.
    let mut left_edges = Vec::new();
    let mut right_edges = Vec::new();
    let max_gap = (w as usize / 30).max(3);
    for row in support {
        let ink: Vec<_> = row
            .iter()
            .enumerate()
            .filter_map(|(x, &present)| present.then_some(x))
            .collect();
        let continuous = ink
            .chunk_by(|a, b| b - a <= max_gap)
            .max_by_key(|run| run.len())?;
        if continuous.len() < w as usize / 3 {
            return None;
        }
        let trim = continuous.len() / 40;
        left_edges.push(continuous[trim]);
        right_edges.push(continuous[continuous.len() - 1 - trim]);
    }
    Some((left_edges, right_edges))
}

fn edge_drift(edges: &[usize]) -> f32 {
    let quarter = (edges.len() / 4).max(1);
    let mean = |slice: &[usize]| slice.iter().sum::<usize>() as f32 / slice.len() as f32;
    (mean(&edges[..quarter]) - mean(&edges[edges.len() - quarter..])).abs()
}

fn straighten_columns(
    opaque: &RgbaImage,
    grid: &RulingGrid,
    ratio: f32,
    top: u32,
    step: u32,
) -> Option<RgbaImage> {
    let (ow, oh) = opaque.dimensions();
    let destinations: Vec<_> = std::iter::once(0)
        .chain((0..grid.tracks[MID].len()).map(|i| top + i as u32 * step))
        .chain([oh - 1])
        .collect();
    let mut corrected = RgbaImage::new(ow, oh);
    for x in 0..ow {
        let source: Vec<_> = std::iter::once(0.)
            .chain(grid.heights_at(x as f32 * ratio).map(|y| y / ratio))
            .chain([(oh - 1) as f32])
            .collect();
        if source.windows(2).any(|pair| pair[0] >= pair[1]) {
            return None;
        }
        for (pair, dest) in source.windows(2).zip(destinations.windows(2)) {
            let (start, end) = (dest[0], dest[1]);
            for y in start..=end {
                let weight = (y - start) as f32 / (end - start) as f32;
                let source_y = (pair[0] + weight * (pair[1] - pair[0])).clamp(0., (oh - 1) as f32);
                let before = source_y.floor() as u32;
                let after = (before + 1).min(oh - 1);
                let fraction = source_y - before as f32;
                corrected[(x, y)] = Rgba(std::array::from_fn(|channel| {
                    let a = opaque[(x, before)][channel] as f32;
                    let b = opaque[(x, after)][channel] as f32;
                    (a + fraction * (b - a)).round() as u8
                }));
            }
        }
    }
    Some(corrected)
}

pub(super) fn flatten(
    opaque: &RgbaImage,
    points: &[(f32, f32)],
    w: u32,
    h: u32,
    ratio: f32,
    camera: Option<&CameraMetadata>,
) -> Result<Option<Identification>> {
    let Some(grid) = RulingGrid::detect(points, w, h) else {
        return Ok(None);
    };
    let best = &grid.tracks[MID];
    let spacing = (best[best.len() - 1] - best[0]) / (best.len() - 1) as f32;
    // Leave flat or uniformly rotated paper on the existing affine path.
    let nonlinear = grid.nonlinear(spacing);
    if !nonlinear && camera.is_some() {
        return Ok(None);
    }
    let (ow, oh) = opaque.dimensions();
    let step = (spacing / ratio).round() as u32;
    let top = (best[0] / ratio).round() as u32;
    let last = top + (best.len() - 1) as u32 * step;
    if top == 0 || last >= oh - 1 {
        return Ok(None);
    }
    let Some((mut left_edges, mut right_edges)) = writing_edges(&grid, points, w, h) else {
        return Ok(None);
    };
    // Parallel rulings can still sit inside a sheared box.
    if !nonlinear && edge_drift(&left_edges).max(edge_drift(&right_edges)) < w as f32 * 0.025 {
        return Ok(None);
    }
    // The end points carry the horizontal foreshortening as well as the varying line pitch.
    let measured_rows = (0..best.len())
        .map(|i| Ruling {
            edges: [left_edges[i] as f32 / ratio, right_edges[i] as f32 / ratio],
            heights: std::array::from_fn(|j| grid.tracks[j][i] / ratio),
        })
        .collect();
    left_edges.sort_unstable();
    right_edges.sort_unstable();
    let trim = best.len() / 10;
    let left = left_edges[best.len() - 1 - trim];
    let right = right_edges[trim];
    if right.saturating_sub(left) < w as usize / 3 {
        return Ok(None);
    }
    let Some(corrected) = straighten_columns(opaque, &grid, ratio, top, step) else {
        return Ok(None);
    };
    let bottom = oh - last;
    let first_writable = if top >= step && !has_printed_header(&corrected, top, step) {
        top
    } else {
        top + step
    };
    Ok(Some(Identification {
        margin_left: (left as f32 / ratio).round() as u32,
        margin_right: ((w as usize - 1 - right) as f32 / ratio).round() as u32,
        margin_top: top,
        margin_bottom: bottom,
        layout_top_margin: first_writable - step,
        layout_bottom_margin: bottom.saturating_sub(step.div_ceil(4)),
        image_width: ow,
        image_height: oh,
        line_spacing: step,
        deskew_angle_degrees: 0.,
        confidence: grid.confidence,
        projection: Some(PaperProjection::Rulings {
            first: top as f32,
            step: step as f32,
            layout_edges: [
                (left as f32 / ratio).round(),
                ow as f32 - ((w as usize - 1 - right) as f32 / ratio).round(),
            ],
            columns: grid.columns.map(|x| x / ratio),
            rows: measured_rows,
        }),
        corrected_background: camera
            .map(|camera| camera.png(&corrected))
            .transpose()?
            .map(|png| base64::engine::general_purpose::STANDARD.encode(png)),
    }))
}
