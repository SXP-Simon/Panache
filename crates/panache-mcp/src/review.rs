mod consistency;
mod drawing;
pub(crate) use drawing::Drawing;
pub mod local;
mod paper_ink;
pub(crate) use consistency::{Bounds, TextSample};

use crate::{controls, drafts::Snapshot, reply};
use anyhow::{Result, ensure};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use handwriting_core::{Cancellation, Limits, Parameters, export, imaging};
use image::{GenericImageView, Pixel, Rgba, RgbaImage, imageops};
use rmcp::model::{CallToolResult, ContentBlock};
use serde_json::{Value, json};

pub fn photo_point(draft: &Snapshot<'_>, [x, y]: [f32; 2]) -> [f32; 2] {
    draft
        .paper
        .as_ref()
        .and_then(|p| p.projection.as_ref())
        .map_or([x, y], |m| m.photo_point(x, y))
}

// Even–odd crossings also handle concave freehand selections.
pub fn contains(poly: &[[i32; 2]], [x, y]: [f32; 2]) -> bool {
    poly.iter()
        .zip(poly.iter().cycle().skip(1))
        .filter(|(a, b)| {
            let [ax, ay] = a.map(|v| v as f32);
            let [bx, by] = b.map(|v| v as f32);
            (ay > y) != (by > y) && x < (bx - ax) * (y - ay) / (by - ay) + ax
        })
        .count()
        % 2
        == 1
}

const REVIEW_MAX_EDGE: u32 = 900;

fn thumbnail(img: &impl GenericImageView<Pixel = Rgba<u8>>) -> RgbaImage {
    let scale = (REVIEW_MAX_EDGE as f32 / img.width().max(img.height()) as f32).min(1.);
    imageops::thumbnail(
        img,
        (img.width() as f32 * scale).round().max(1.) as u32,
        (img.height() as f32 * scale).round().max(1.) as u32,
    )
}
fn draw_path(img: &mut RgbaImage, points: &[[f32; 2]], sx: f32, sy: f32, color: Rgba<u8>) {
    for pair in points.windows(2) {
        let (x, y) = (pair[0][0] * sx, pair[0][1] * sy);
        let (dx, dy) = (pair[1][0] * sx - x, pair[1][1] * sy - y);
        let steps = dx.abs().max(dy.abs()).ceil().clamp(1., 2048.) as u32;
        for i in 0..=steps {
            let t = i as f32 / steps as f32;
            let (px, py) = ((x + dx * t).round() as i32, (y + dy * t).round() as i32);
            if px >= 0 && py >= 0 && px < img.width() as i32 && py < img.height() as i32 {
                img.put_pixel(px as u32, py as u32, color);
            }
        }
    }
}

// Look for a continuous dark ridge in the untouched paper, on both sides of
// the glyph baseline. No contrast support means unknown, including blank paper.
fn ruling_offset(paper: &RgbaImage, point: [f32; 2], radius: i32) -> Option<i32> {
    let [x, y] = point.map(|n| n.round() as i32);
    if x < 3
        || x >= paper.width() as i32 - 3
        || y < radius + 3
        || y >= paper.height() as i32 - radius - 3
    {
        return None;
    }
    let light =
        |dx: i32, dy: i32| i32::from(paper[((x + dx) as u32, (y + dy) as u32)].to_luma()[0]);
    let score = |dy: i32| {
        (-3..=3)
            .map(|dx| (light(dx, dy - 3).min(light(dx, dy + 3)) - light(dx, dy)).max(0))
            .sum::<i32>()
    };
    let best = (-radius..=radius)
        .map(|dy| (score(dy), -dy.abs(), dy))
        .max()?;
    (best.0 >= 7 * 8).then_some(best.2)
}

pub struct PageSample {
    pub baselines: Vec<[f32; 2]>,
    pub content_sha256: String,
    pub text: Vec<TextSample>,
    pub drawings: Vec<Drawing>,
}

// Suggest a crop around a sampled text line at native resolution, including neighboring paper.
fn detail_region(
    baselines: &[[f32; 2]],
    (width, height): (u32, u32),
    font_size: f32,
) -> Option<[[u32; 2]; 4]> {
    let on_page = |&&[x, y]: &&[f32; 2]| {
        (0. ..width as f32).contains(&x) && (0. ..height as f32).contains(&y)
    };
    let mut points = baselines.iter().filter(on_page);
    let middle = points.clone().count() / 2;
    let &[x, y] = points.nth(middle)?;
    let w = width.min((font_size * 10.).round().clamp(160., 800.) as u32);
    let h = height.min((font_size * 4.).round().clamp(96., 480.) as u32);
    let left = (x as u32).saturating_sub(w / 2).min(width - w);
    let top = (y as u32).saturating_sub(h / 2).min(height - h);
    Some([
        [left, top],
        [left + w, top],
        [left + w, top + h],
        [left, top + h],
    ])
}

pub(crate) fn decode_page(png: &str) -> Result<RgbaImage> {
    let bytes = STANDARD.decode(png)?;
    let limits = Limits {
        max_file_bytes: bytes.len(),
        ..Default::default()
    };
    Ok(imaging::decode(&bytes, &limits)?.into_rgba8())
}

fn reference_paper(
    draft: &Snapshot<'_>,
    size: (u32, u32),
    params: &Parameters,
) -> Result<RgbaImage> {
    let limits = Limits::default();
    let paper = match draft.background()? {
        Some(b) => imaging::decode(&b, &limits)?.into_rgba8(),
        None => handwriting_core::render::preset_paper(size.0, size.1, params, &limits)?,
    };
    ensure!(
        paper.dimensions() == size,
        "Paper and output dimensions differ"
    );
    Ok(paper)
}

fn rgb_delta(a: Rgba<u8>, b: Rgba<u8>) -> u16 {
    let white =
        |p: Rgba<u8>, c: usize| 255 - ((255 - u16::from(p[c])) * u16::from(p[3])).div_ceil(255);
    (0..3)
        .map(|c| white(a, c).abs_diff(white(b, c)))
        .max()
        .unwrap()
}

pub fn pixel_sha256(image: &RgbaImage) -> String {
    use sha2::{Digest, Sha256};
    let mut hash = Sha256::new();
    hash.update(image.width().to_le_bytes());
    hash.update(image.height().to_le_bytes());
    hash.update(image.as_raw());
    format!("{:x}", hash.finalize())
}

fn composite_on_paper(
    finished: &mut RgbaImage,
    paper: &RgbaImage,
    cancel: &Cancellation,
) -> Result<()> {
    for (row, base) in finished.rows_mut().zip(paper.rows()) {
        cancel.check()?;
        for (pixel, &under) in row.zip(base) {
            let mut visible = under;
            visible.blend(pixel);
            *pixel = visible;
        }
    }
    Ok(())
}

// Used by read-only image previews as well. All measurements use the visible output on the saved paper.
pub fn local_ink_preview(
    draft: &Snapshot<'_>,
    section: u32,
    page: usize,
    png: &str,
    sample: &PageSample,
    cancel: &Cancellation,
) -> Result<Option<serde_json::Value>> {
    if draft.paper.is_none() {
        return Ok(None);
    }
    let params = controls::parameters(draft, section, &draft.controls)?;
    let mut finished = decode_page(png)?;
    let paper = reference_paper(draft, finished.dimensions(), &params)?;
    if params.transparent_background {
        composite_on_paper(&mut finished, &paper, cancel)?;
    }
    Ok(paper_ink::measure(sample, &paper, &finished, None, cancel)?
        .map(|e| paper_ink::report(&e, draft.id, draft.revision, section, page)))
}

// Paper measurements identify places worth inspecting, not a defect in the new ink.
fn photo_ink_adjustment(
    projected: bool,
    visible_ink: bool,
    draft: &str,
    revision: u32,
    review: &Value,
) -> Option<Value> {
    if !projected || !visible_ink {
        return None;
    }
    let focus = review["paper_focus_check"]["status"] == "spatial_variation"
        || review.get("png_finish_comparison").is_some();
    let light = review["local_paper_ink_check"]["samples"]
        .as_array()
        .is_some_and(|samples| {
            samples.iter().any(|sample| {
                sample["paper_marks"]["supported"] == true
                    && sample["added_writing"]["median_glyph_p90_luma_drop"].is_number()
            })
        });
    if !focus && !light {
        return None;
    }
    let mut hint = json!({
        "describe_arguments":{"draft_id":draft,"revision":revision,"group":"ink"},
        "guidance":"The paper readings locate comparisons, not faults. Use the user's request or confirm a mismatch in native crops. If the ink already fits, leave it unchanged. After any trial compare the same region at the same scale and check readable fine strokes and protected print."
    });
    if focus {
        hint["focus"] = json!(
            "If one area needs softer NEW strokes while the original print stays sharp, look up photo_ink_focus and try it in tune_handwriting changes. Inspect the softer, transition and sharp areas at native size; keep the sharp endpoint at zero. For a single word or shape, prefer a local edit. export_blur_gradient is a PNG finish and softens paper and ink together."
        );
    }
    if light {
        hint["light"] = json!(
            "If new ink should follow the paper's local shade or tint, look up photo_ink_light and try it in tune_handwriting changes. This adjusts new pen color, not sharpness or alpha; pure black is unchanged. Darker writing or nearby shadow alone does not justify adjusting it."
        );
    }
    Some(hint)
}

pub fn page(
    draft: &Snapshot<'_>,
    section: u32,
    page: usize,
    png: &str,
    sample: &PageSample,
    focus: &crate::paper::focus::Cache,
    cancel: &Cancellation,
) -> Result<CallToolResult> {
    let params = controls::parameters(draft, section, &draft.controls)?;
    let mut finished = decode_page(png)?;
    let pixel_digest = pixel_sha256(&finished);
    let baselines = &sample.baselines;
    let paper = reference_paper(draft, finished.dimensions(), &params)?;
    let (w, h) = paper.dimensions();
    // The reference is anchored to the imported stationery, independent of later margin adjustments.
    let (left, right, top, bottom, step) = draft.paper.as_ref().map_or(
        (
            params.left_margin,
            w as f32 - params.right_margin,
            params.top_margin,
            h as f32 - params.bottom_margin,
            params.line_spacing,
        ),
        |p| {
            (
                p.left as f32,
                (p.width - p.right) as f32,
                p.top as f32,
                (p.height - p.bottom) as f32,
                p.line_spacing,
            )
        },
    );
    let path = |y: f32| {
        (0..=16)
            .map(|i| photo_point(draft, [left + (right - left) * i as f32 / 16., y]))
            .collect::<Vec<_>>()
    };
    let mut perimeter = path(top);
    let steps = ((bottom - top) / step).ceil().clamp(1., 512.) as u32;
    for i in 1..=steps {
        perimeter.push(photo_point(
            draft,
            [right, top + (bottom - top) * i as f32 / steps as f32],
        ));
    }
    perimeter.extend(path(bottom).into_iter().rev());
    for i in (0..steps).rev() {
        perimeter.push(photo_point(
            draft,
            [left, top + (bottom - top) * i as f32 / steps as f32],
        ));
    }
    let mut changed = [0u64; 3];
    let mut outside = 0u64;
    let mut peak = 0;
    for y in 0..h {
        cancel.check()?;
        let mut cuts = Vec::new();
        let cy = y as f32 + 0.5;
        for seg in perimeter.windows(2) {
            let ([ax, ay], [bx, by]) = (seg[0], seg[1]);
            if (ay > cy) != (by > cy) {
                cuts.push(ax + (cy - ay) * (bx - ax) / (by - ay));
            }
        }
        cuts.sort_by(f32::total_cmp);
        for x in 0..w {
            let base = paper[(x, y)];
            let pixel = &mut finished[(x, y)];
            if params.transparent_background {
                let mut composite = base;
                composite.blend(pixel);
                *pixel = composite;
            }
            let delta = rgb_delta(*pixel, base);
            peak = peak.max(delta);
            if delta >= 8 {
                changed[(y as usize * 3 / h as usize).min(2)] += 1;
                if cuts.partition_point(|v| *v <= x as f32 + 0.5) % 2 == 0 {
                    outside += 1;
                }
            }
        }
    }
    let result = thumbnail(&finished);
    let mut overlay = result.clone();
    let (sx, sy) = (
        overlay.width() as f32 / w as f32,
        overlay.height() as f32 / h as f32,
    );
    draw_path(&mut overlay, &perimeter, sx, sy, Rgba([228, 86, 35, 255]));
    let rows = ((bottom - top) / step).floor() as usize;
    for i in (1..=rows).step_by(rows.div_ceil(100).max(1)) {
        draw_path(
            &mut overlay,
            &path(top + step * i as f32),
            sx,
            sy,
            Rgba([0, 154, 171, 255]),
        );
    }
    let status = if peak == 0 {
        "no_visible_change"
    } else if changed.iter().sum::<u64>() == 0 {
        "very_low_contrast"
    } else {
        "inspect_visually"
    };
    let mut offsets: [Vec<i32>; 3] = Default::default();
    let mut sampled = [0u32; 3];
    for &point in baselines {
        let band = (point[1].max(0.) as usize).min(h as usize - 1) * 3 / h as usize;
        sampled[band] += 1;
        if let Some(dy) = ruling_offset(&paper, point, (step / 3.).clamp(2., 18.) as i32) {
            offsets[band].push(dy.abs());
        }
    }
    let band_alignment = offsets
        .into_iter()
        .zip(sampled)
        .map(|(mut v, total)| {
            v.sort_unstable();
            json!({"sampled":total,"supported_samples":v.len(),"median_abs_dy_px":v.get(v.len()/2)})
        })
        .collect::<Vec<_>>();
    let mut evidence = json!({
        "visibility":status,
        "photo_size":[w,h],
        "global_ink":{"rgba":params.fill,"opacity":params.ink_opacity,"thickness":params.ink_thickness,"softness":params.ink_softness,"depth_sigma":params.ink_depth_sigma},
        "alignment":draft.paper.as_ref().map(|p|p.summary()["alignment"].clone()),
        "baseline_samples":baselines.len(),
        "nearby_dark_ridge_by_image_third":band_alignment,
        "max_rgb_delta":peak,
        "changed_pixels_by_image_third":changed,
        "channel_delta_threshold":8,
        "changed_pixels_outside_reference":outside,
        "transparent_png":params.transparent_background,
    });
    let checks = consistency::checks(
        sample,
        &paper,
        &finished,
        &params,
        draft.paper.is_some(),
        cancel,
    )?;
    if let Some(rows) = &checks.rows {
        evidence["adjacent_rows"] = rows.metrics.clone();
    }
    if let Some(ink) = &checks.ink {
        evidence["illustration_contrast"] = ink.metrics.clone();
    }
    let local_ink = if draft.paper.is_some() {
        paper_ink::measure(sample, &paper, &finished, None, cancel)?
    } else {
        None
    };
    if let Some(value) = &local_ink {
        evidence["local_paper_ink"] = value.clone();
    }
    let observation = draft.record_review(
        section,
        page,
        "paper-review/4",
        &pixel_digest,
        &sample.content_sha256,
        &evidence,
    )?;
    let next = if peak == 0 {
        "If this page should contain text, check ink opacity/color, local edits and off-page placement. Review the new revision."
    } else if outside > 0 || draft.paper.as_ref().is_some_and(|p| !p.ruled) {
        "Check the overlay against the intended fields and protected print. Writing outside the reference can belong in a header or sidebar. If placement is unclear, ask where to write or what to keep clear; follow specified or delegated placement."
    } else {
        "Compare writing across the occupied parts of the page with the saved paper. Check the requested position, header clearance, contrast, focus and letter size."
    };
    let metadata = {
        let mut metadata = observation;
        metadata["photo_size"] = json!([w, h]);
        metadata["thumbnail_size"] = json!([result.width(), result.height()]);
        metadata["next_step"] = json!(next);
        if let Some(e) = local_ink {
            metadata["local_paper_ink_check"] =
                paper_ink::report(&e, draft.id, draft.revision, section, page);
        }
        let arguments = |region| json!({"draft_id":draft.id,"revision":draft.revision,"section":section,"page":page,"view":"review","region":region});
        if let Some(rows) = checks.rows {
            metadata["adjacent_row_check"] = rows.guidance(&arguments,
                "Inspect these neighboring text rows at native size. The horizontal-to-vertical stretch describes letter proportions on the photo; paper vertical scale describes the change in letter height before photo projection. Compare both rows’ median values and inspect the crop. Check whether the difference suits the writing before making a local edit.");
        }
        if let Some(ink) = checks.ink {
            metadata["illustration_ink_check"] = ink.guidance(&arguments,
                "At native size compare a diagram label and nearby writing, then compare a straight frame or arrow shaft with a letter stem. Inspect letterforms, size, width, edge softness and darkness. The regions measure added ink against the saved paper. Different coverage, overlapping marks, color and paper lighting can affect the readings. Inspect thickness and darkness in the crops. If a crop misses a frame, arrow or identifiable nearby letters, move or expand the region to include comparable marks at native scale. On ruled paper trace each arrow to its head and check that it remains distinct from the ruling. If only the diagram needs changing, adjust its source or pen settings. Use each preview call as given for one revision; omit compare_revision.");
        }
        if draft.paper.is_some() {
            let mut appearance = json!({
                "inspect":"Compare contrast and size with photographed marks. Check letter size against writing space. Baselines measure placement only. Without images, credit the user's observations; ask the user to inspect the crop if visual evidence is needed.",
                "ink_edge_guidance":"Keep ink if requested or suitable. Only soften if the user reports overly sharp strokes or a native crop shows sharper stroke edges than comparable nearby marks. Shadow or faint ink alone is insufficient. For selected words or lines, get their glyph IDs from layout and use adjust_glyphs softness. For the whole draft, use tune_handwriting ink_softness. Start small.",
                "controls":"describe_controls with draft_id, revision and group: ink (ink #RRGGBB, ink_opacity %, ink_softness and ink_thickness in paper-space px); layout (font_size in paper-space px); typography (font).",
                "after_edit":"Use compare_revision for paper/before/after crops of the same region. Also compare any area the user explicitly asked to preserve. Check fine strokes and contrast; keep the original if worse or unsure. After page reflow inspect each revision separately."
            });
            if let Some(region) = detail_region(baselines, (w, h), params.font_size) {
                appearance["preview_arguments"] = json!({
                    "draft_id":draft.id,"revision":draft.revision,"section":section,"page":page,
                    "view":"review","region":region
                });
            }
            metadata["photo_appearance"] = appearance;
        }
        drawing::add_check(&mut metadata, draft, section, page, sample, (w, h), None);
        focus.add_review_guidance(
            draft,
            section,
            page,
            params.transparent_background,
            true,
            &mut metadata,
        )?;
        if let Some(hint) = photo_ink_adjustment(
            draft.paper.as_ref().is_some_and(|p| p.projection.is_some()),
            status == "inspect_visually",
            draft.id,
            draft.revision,
            &metadata,
        ) {
            metadata["photo_ink_adjustment"] = hint;
        }
        metadata
    };
    let mut response = reply(
        format!(
            "{metadata}\nOrange = estimated writing area; cyan = projected layout guides. Baseline offsets sample nearby dark ridges on unmarked paper (null = no supported sample); a decoration can also form a ridge. Transparent PNG is shown on its paper for comparison."
        ),
        metadata,
    );
    for (label, img) in [
        ("Saved paper", thumbnail(&paper)),
        ("Finished appearance", result),
        ("Reference overlay", overlay),
    ] {
        response.content.push(ContentBlock::text(label));
        response.content.push(ContentBlock::image(
            STANDARD.encode(export::png(&img)?),
            "image/png",
        ));
    }
    Ok(response)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn photo_ink_hint_is_scoped_to_eligible_visible_evidence() {
        let hint =
            |projected, visible, data| photo_ink_adjustment(projected, visible, "d", 3, &data);
        let spatial = json!({"paper_focus_check":{"status":"spatial_variation"}});
        assert!(hint(false, true, spatial.clone()).is_none());
        assert!(hint(true, false, spatial.clone()).is_none());
        assert!(hint(true, true, json!({})).is_none());
        let focus = hint(true, true, spatial).unwrap();
        assert!(focus.get("focus").is_some() && focus.get("light").is_none());
        assert_eq!(
            focus["describe_arguments"],
            json!({"draft_id":"d","revision":3,"group":"ink"})
        );
        let compare = json!({"local_paper_ink_check":{"samples":[{
            "paper_marks":{"supported":true},
            "added_writing":{"median_glyph_p90_luma_drop":52}
        }]}});
        let light = hint(true, true, compare).unwrap();
        assert!(light.get("light").is_some() && light.get("focus").is_none());
        let unsupported = json!({"local_paper_ink_check":{"samples":[{
            "paper_marks":{"supported":false},
            "added_writing":{"median_glyph_p90_luma_drop":52}
        }]}});
        assert!(hint(true, true, unsupported).is_none());
    }
}
