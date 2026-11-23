use super::{decode_page, reference_paper, rgb_delta, thumbnail};
use crate::{
    Preview, controls,
    drafts::{Drafts, Section, Snapshot},
    engine::Engine,
    reply,
};
use anyhow::{Context, Result, ensure};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use handwriting_core::{Cancellation, Parameters, export};
use image::{GenericImageView, Pixel, RgbaImage};
use rmcp::model::{CallToolResult, ContentBlock};
use serde::Serialize;
use serde_json::json;

type Point = [i32; 2];
const THRESHOLD: u16 = 8;

fn edges(poly: &[Point]) -> impl Iterator<Item = (Point, Point)> + '_ {
    poly.iter()
        .copied()
        .zip(poly.iter().copied().cycle().skip(1))
}

fn turn(a: Point, b: Point, p: Point) -> i64 {
    i64::from(b[0] - a[0]) * i64::from(p[1] - a[1])
        - i64::from(b[1] - a[1]) * i64::from(p[0] - a[0])
}

fn between(a: Point, p: Point, b: Point) -> bool {
    (0..2).all(|i| (a[i].min(b[i])..=a[i].max(b[i])).contains(&p[i]))
}

fn intersects(a: Point, b: Point, c: Point, d: Point) -> bool {
    let (ac, ad, ca, cb) = (turn(a, b, c), turn(a, b, d), turn(c, d, a), turn(c, d, b));
    (ac.signum() * ad.signum() < 0 && ca.signum() * cb.signum() < 0)
        || (ac == 0 && between(a, c, b))
        || (ad == 0 && between(a, d, b))
        || (ca == 0 && between(c, a, d))
        || (cb == 0 && between(c, b, d))
}

fn validate_polygon(poly: &[Point], (w, h): (u32, u32)) -> Result<()> {
    ensure!((3..=32).contains(&poly.len()), "Use 3..32 polygon vertices");
    ensure!(
        poly.iter()
            .all(|&[x, y]| (0..=w as i32).contains(&x) && (0..=h as i32).contains(&y)),
        "Polygon vertices must be inside native output pixel edges [0,{w}] x [0,{h}]"
    );
    for (i, (a, b)) in edges(poly).enumerate() {
        let c = poly[(i + 2) % poly.len()];
        ensure!(
            a != b && (turn(a, b, c) != 0 || between(a, b, c)),
            "Polygon has a duplicate or reversing edge"
        );
        for (j, (c, d)) in edges(poly).enumerate().skip(i + 2) {
            if i != 0 || j + 1 != poly.len() {
                ensure!(
                    !intersects(a, b, c, d),
                    "Polygon must be simple with no intersecting edges"
                );
            }
        }
    }
    Ok(())
}

// Fill horizontal spans at pixel centers. Concave polygons can produce several spans.
fn row_mask(poly: &[Point], y: u32, mask: &mut [bool]) {
    mask.fill(false);
    let cy = f64::from(y) + 0.5;
    let mut cuts = [0usize; 32];
    let mut count = 0;
    for ([ax, ay], [bx, by]) in edges(poly) {
        if (f64::from(ay) > cy) != (f64::from(by) > cy) {
            let x = f64::from(ax) + (cy - f64::from(ay)) * f64::from(bx - ax) / f64::from(by - ay);
            cuts[count] = (x - 0.5).ceil() as usize;
            count += 1;
        }
    }
    cuts[..count].sort_unstable();
    for pair in cuts[..count].chunks_exact(2) {
        mask[pair[0]..pair[1]].fill(true);
    }
}

#[derive(Default, Serialize)]
struct Ink {
    sampled_pixels: u64,
    ink_pixels: u64,
    max_rgb_delta: u16,
}

impl Ink {
    fn sample(&mut self, delta: u16) {
        self.sampled_pixels += 1;
        self.ink_pixels += u64::from(delta >= THRESHOLD);
        self.max_rgb_delta = self.max_rgb_delta.max(delta);
    }
}

#[derive(Default, Serialize)]
struct Measurements {
    region: Ink,
    previous_region: Option<Ink>,
}

impl Measurements {
    fn sample(&mut self, region: bool, previous: bool, delta: u16) {
        if region {
            self.region.sample(delta);
        }
        if previous {
            self.previous_region.get_or_insert_default().sample(delta);
        }
    }
}

#[derive(Default, Serialize)]
struct Difference {
    inside_union_changed_pixels: u64,
    outside_union_changed_pixels: u64,
    region_changed_pixels: u64,
    previous_region_changed_pixels: Option<u64>,
}

struct Appearance {
    finished: RgbaImage,
    params: Parameters,
    content_sha256: String,
    fine_edit: bool,
}

impl Appearance {
    fn render(
        engine: &mut Engine,
        draft: &Snapshot<'_>,
        section: Section,
        page: usize,
        cancel: &Cancellation,
    ) -> Result<Self> {
        let params = controls::parameters(draft, section.number, &draft.controls)?;
        let sample = engine.review_baselines(draft, section.clone(), page, cancel)?;
        let (preview, _) = engine.preview(draft, section, page, cancel)?;
        Ok(Self {
            finished: decode_page(&preview.png)?,
            params,
            content_sha256: sample.content_sha256,
            fine_edit: preview.fine_edit,
        })
    }

    fn composite(&mut self, paper: &RgbaImage, cancel: &Cancellation) -> Result<()> {
        if self.params.transparent_background {
            for (pixels, bases) in self.finished.rows_mut().zip(paper.rows()) {
                cancel.check()?;
                for (pixel, &base) in pixels.zip(bases) {
                    let mut visible = base;
                    visible.blend(pixel);
                    *pixel = visible;
                }
            }
        }
        Ok(())
    }
}

pub fn page(
    drafts: &Drafts,
    engine: &mut Engine,
    draft: &Snapshot<'_>,
    section: Section,
    input: &Preview,
    region: &[Point],
    cancel: &Cancellation,
) -> Result<CallToolResult> {
    let page = input.page.unwrap_or(1);
    let number = section.number;
    let previous = input.previous_region.as_deref().unwrap_or_default();
    ensure!(
        input
            .compare_revision
            .is_none_or(|rev| rev > 0 && rev < draft.revision),
        "compare_revision must identify an earlier revision"
    );
    let mut after = Appearance::render(engine, draft, section, page, cancel)?;
    let size = after.finished.dimensions();
    validate_polygon(region, size)?;
    if let Some(old) = &input.previous_region {
        validate_polygon(old, size)?;
    }
    let paper = reference_paper(draft, size, &after.params)?;
    after.composite(&paper, cancel)?;
    let before = if let Some(revision) = input.compare_revision {
        let old = drafts.snapshot(draft.id, Some(revision))?;
        let section = drafts
            .sections(old.id, revision, Some(number))?
            .pop()
            .context("Section absent in compare_revision")?;
        let mut before = Appearance::render(engine, &old, section, page, cancel)?;
        ensure!(
            before.finished.dimensions() == size,
            "Cannot compare local pixels: different_image_dimensions"
        );
        ensure!(
            before.content_sha256 == after.content_sha256,
            "Cannot compare local pixels: page_content_changed_or_repaginated"
        );
        // Imported paper bytes are immutable per draft; generated stationery depends on controls.
        if old.paper.is_none() {
            ensure!(
                reference_paper(&old, size, &before.params)? == paper,
                "Cannot compare local pixels: different_reference_paper"
            );
        }
        before.composite(&paper, cancel)?;
        Some(before)
    } else {
        None
    };
    let [mut left, mut top] = region[0];
    let [mut right, mut bottom] = region[0];
    for &[x, y] in region.iter().chain(previous) {
        left = left.min(x);
        top = top.min(y);
        right = right.max(x);
        bottom = bottom.max(y);
    }
    let bounds = [
        left as u32,
        top as u32,
        (right - left) as u32,
        (bottom - top) as u32,
    ];
    let mut after_metrics = Measurements::default();
    let mut before_metrics = Measurements::default();
    let mut diff = Difference {
        previous_region_changed_pixels: input.previous_region.as_ref().map(|_| 0),
        ..Default::default()
    };
    let mut mask = vec![false; size.0 as usize];
    let mut old_mask = mask.clone();
    let rows = if before.is_some() {
        0..size.1
    } else {
        bounds[1]..bounds[1] + bounds[3]
    };
    let cols = if before.is_some() {
        0..size.0
    } else {
        bounds[0]..bounds[0] + bounds[2]
    };
    for y in rows {
        cancel.check()?;
        row_mask(region, y, &mut mask);
        row_mask(previous, y, &mut old_mask);
        for x in cols.clone() {
            let inside = mask[x as usize];
            let old = old_mask[x as usize];
            let pixel = after.finished[(x, y)];
            let base = paper[(x, y)];
            if inside || old {
                after_metrics.sample(inside, old, rgb_delta(pixel, base));
            }
            if let Some(before) = &before {
                let prior = before.finished[(x, y)];
                if inside || old {
                    before_metrics.sample(inside, old, rgb_delta(prior, base));
                }
                if rgb_delta(pixel, prior) >= THRESHOLD {
                    diff.region_changed_pixels += u64::from(inside);
                    if let Some(count) = &mut diff.previous_region_changed_pixels {
                        *count += u64::from(old);
                    }
                    if inside || old {
                        diff.inside_union_changed_pixels += 1;
                    } else {
                        diff.outside_union_changed_pixels += 1;
                    }
                }
            }
        }
    }
    ensure!(
        after_metrics.region.sampled_pixels > 0
            && (previous.is_empty() || after_metrics.previous_region.is_some()),
        "Each polygon must enclose at least one pixel center"
    );
    let crop = |img: &RgbaImage| {
        let [x, y, w, h] = bounds;
        thumbnail(&*img.view(x, y, w, h))
    };
    let paper_crop = crop(&paper);
    let mut metadata = json!({
        "draft_id":draft.id,"section":number,"page":page,"revision":draft.revision,"compare_revision":input.compare_revision,
        "photo_size":size,"region":region,"previous_region":input.previous_region,"crop_bounds":bounds,
        "crop_image_size":paper_crop.dimensions(),"channel_delta_threshold":THRESHOLD,
        "coordinate_space":"Native output pixel edges; origin top left, x right, y down. crop_bounds is [x,y,width,height]. Measurements use pixel centers inside each polygon.",
        "after":after_metrics,"before":before.as_ref().map(|_|before_metrics),"difference":before.as_ref().map(|_|diff),
        "guidance":"Ink counts pixels whose largest visible RGB channel difference from the paper is at least 8. Revision differences apply the same threshold to before and after appearances; outside_union_changed_pixels covers the entire page outside both polygons. This local inspection leaves full-page review status unchanged. Inspect the crops against the request, including whether disappearance was intended. Overlapping text and diagrams contribute to the same pixels. Check protected areas with another region. Stop once the target and protected areas meet the request; ask if intent or attribution is unclear."
    });
    if let Some(prior) = &before
        && prior.fine_edit != after.fine_edit
    {
        let mode = |fine| if fine { "fine_edit" } else { "standard" };
        metadata["render_mode_change"] = json!({
            "before": mode(prior.fine_edit), "after": mode(after.fine_edit),
            "guidance": "Fine edit applies ink variation to individual glyphs. Switching rendering modes can change unedited writing. All measured differences remain visible changes; inspect protected areas before judging the edit."
        });
    }
    let mut response = reply(metadata.to_string(), metadata);
    let mut append = |label: &str, img: RgbaImage| -> Result<()> {
        response.content.push(ContentBlock::text(label));
        response.content.push(ContentBlock::image(
            STANDARD.encode(export::png(&img)?),
            "image/png",
        ));
        Ok(())
    };
    append("Saved paper crop", paper_crop)?;
    if let Some(before) = before {
        append("Before crop", crop(&before.finished))?;
    }
    append("After crop", crop(&after.finished))?;
    Ok(response)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_invalid_photo_polygons() {
        for poly in [
            vec![[1, 0], [2, 0], [3, 0]],
            vec![[0, 0], [8, 8], [8, 0], [0, 8]],
            vec![[0, 0], [9, 1], [1, 4]],
            vec![[0, 0], [8, 0], [8, 8], [0, 0]],
            vec![[0, 0], [8, 0], [7, 0], [0, 8]],
        ] {
            assert!(validate_polygon(&poly, (8, 8)).is_err(), "{poly:?}");
        }
    }

    #[test]
    fn mask_matches_even_odd_centers_for_concave_polygon_including_photo_edges() {
        let poly = [[0, 0], [8, 0], [8, 6], [6, 4], [4, 1], [2, 4], [0, 6]];
        validate_polygon(&poly, (8, 6)).unwrap();
        let mut mask = [true; 8];
        for y in 0..6 {
            row_mask(&poly, y, &mut mask);
            for (x, &inside) in mask.iter().enumerate() {
                assert_eq!(
                    inside,
                    super::super::contains(&poly, [x as f32 + 0.5, y as f32 + 0.5])
                );
            }
        }
    }
}
