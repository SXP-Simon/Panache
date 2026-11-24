mod measurements;
mod regions;

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
use image::{Pixel, RgbaImage};
use regions::{Point, Regions};
use rmcp::model::{CallToolResult, ContentBlock};
use serde_json::json;

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

    fn check_comparable(&self, old: &Snapshot<'_>, after: &Self, paper: &RgbaImage) -> Result<()> {
        ensure!(
            self.finished.dimensions() == after.finished.dimensions(),
            "Cannot compare local pixels: different_image_dimensions"
        );
        ensure!(
            self.content_sha256 == after.content_sha256,
            "Cannot compare local pixels: page_content_changed_or_repaginated"
        );
        // Imported paper bytes are immutable per draft; generated stationery depends on controls.
        if old.paper.is_none() {
            ensure!(
                &reference_paper(old, after.finished.dimensions(), &self.params)? == paper,
                "Cannot compare local pixels: different_reference_paper"
            );
        }
        Ok(())
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
    ensure!(
        input
            .compare_revision
            .is_none_or(|rev| rev > 0 && rev < draft.revision),
        "compare_revision must identify an earlier revision"
    );
    let mut after = Appearance::render(engine, draft, section, page, cancel)?;
    let size = after.finished.dimensions();
    let regions = Regions::new(region, input.previous_region.as_deref(), size)?;
    let paper = reference_paper(draft, size, &after.params)?;
    after.composite(&paper, cancel)?;
    let before = if let Some(revision) = input.compare_revision {
        let old = drafts.snapshot(draft.id, Some(revision))?;
        let section = drafts
            .sections(old.id, revision, Some(number))?
            .pop()
            .context("Section absent in compare_revision")?;
        let mut before = Appearance::render(engine, &old, section, page, cancel)?;
        before.check_comparable(&old, &after, &paper)?;
        before.composite(&paper, cancel)?;
        Some(before)
    } else {
        None
    };
    let evidence = measurements::measure(
        &regions,
        &paper,
        &after.finished,
        before.as_ref().map(|p| &p.finished),
        cancel,
    )?;
    let paper_crop = regions.crop(&paper);
    let mut metadata = json!({
        "draft_id":draft.id,"section":number,"page":page,"revision":draft.revision,"compare_revision":input.compare_revision,
        "photo_size":size,"region":region,"previous_region":input.previous_region,"crop_bounds":regions.bounds,
        "crop_image_size":paper_crop.dimensions(),"channel_delta_threshold":measurements::THRESHOLD,
        "coordinate_space":"Native output pixel edges; origin top left, x right, y down. crop_bounds is [x,y,width,height]. Measurements use pixel centers inside each polygon.",
        "after":evidence.after,"before":evidence.before,"difference":evidence.difference,
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
        append("Before crop", regions.crop(&before.finished))?;
    }
    append("After crop", regions.crop(&after.finished))?;
    Ok(response)
}
