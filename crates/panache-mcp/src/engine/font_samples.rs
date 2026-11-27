use super::Engine;
use crate::{FontSample, State, reply};
use anyhow::{Context, Result, ensure};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use handwriting_core::{Cancellation, FontBook, Limits, export};
use image::{GenericImageView, RgbaImage, imageops};
use rmcp::model::{CallToolResult, ContentBlock};
use serde_json::json;

const MAX_EDGE: u32 = 640;

fn crop_image(image: &RgbaImage, crop: Option<[u32; 4]>) -> Result<RgbaImage> {
    let [x, y, w, h] = crop.unwrap_or([0, 0, image.width(), image.height()]);
    ensure!(
        w > 0
            && h > 0
            && x.checked_add(w).is_some_and(|r| r <= image.width())
            && y.checked_add(h).is_some_and(|b| b <= image.height()),
        "crop must be a nonempty rectangle within the {} × {} output",
        image.width(),
        image.height()
    );
    let view = image.view(x, y, w, h);
    let longest = w.max(h);
    if longest <= MAX_EDGE {
        return Ok(view.to_image());
    }
    let size = |n| ((u64::from(n) * u64::from(MAX_EDGE)) / u64::from(longest)).max(1) as u32;
    Ok(imageops::thumbnail(&*view, size(w), size(h)))
}

pub(crate) fn compare(
    state: &State,
    engine: &mut Engine,
    sample: FontSample,
    cancel: &Cancellation,
) -> Result<CallToolResult> {
    ensure!(
        (1..=2).contains(&sample.fonts.len()),
        "Supply one or two candidate font IDs"
    );
    let draft = state.drafts.snapshot(&sample.draft_id, sample.revision)?;
    let current = draft.font_name();
    let section_number = sample.section.unwrap_or(1);
    let page = sample.page.unwrap_or(1);
    ensure!(
        (1..=Limits::default().max_pages).contains(&page),
        "Invalid page number"
    );
    let section = state
        .drafts
        .sections(draft.id, draft.revision, Some(section_number))?
        .pop()
        .context("Unknown section")?;
    let (_, edits) = draft.edits(&section)?;
    let mut background = draft.background()?;
    let photo = Engine::photo(&draft, &mut background)?;
    let mut choices = vec![current];
    for id in &sample.fonts {
        if !choices.contains(&id.as_str()) {
            choices.push(id);
        }
    }
    let mut data = json!({
        "draft_id":draft.id, "revision":draft.revision, "section":section_number, "page":page,
        "crop":sample.crop, "current_font":current
    });
    if choices.len() > 1 {
        data["content_note"] = json!(if sample.crop.is_some() {
            "各图取自同一页码和同一纸面位置。换字可能改变换行和分页，请核对裁区内的文字是否仍是同一句。"
        } else {
            "各图取相同页码。换字可能改变换行和分页，请按实际出现的文字比较。"
        });
        if edits.is_some() {
            data["placement_note"] = json!(
                "当前样张保留本节手摆位置和其他局部调整。备选样张按新字体重新排版，采纳参数会保护已有调整。"
            );
        }
    }
    let mut rows = Vec::new();
    let mut unavailable = Vec::new();
    let mut blocks = Vec::new();
    for id in choices {
        cancel.check()?;
        let (name, primary) = if id.starts_with("upload:") || engine.names.iter().any(|f| f == id) {
            (id.to_owned(), engine.draft_font(&draft, id)?)
        } else {
            let (entry, bytes) = state.local_fonts.read(id)?;
            (entry.name, FontBook::load(&bytes)?)
        };
        // Font changes reset local glyph placements in tune_handwriting.
        let local_edits = if id == current { edits.clone() } else { None };
        let mut request = engine.request_with_font(
            &draft,
            section.clone(),
            background.clone(),
            local_edits,
            primary,
        )?;
        if request.params.transparent_background {
            request.params.transparent_background = false;
            data["background_note"] = json!(
                "本稿已开启透明 PNG。这里临时显示底纸以比较字体，稿件的 PNG 预览和导出仍使用透明背景。"
            );
        }
        let rendered = Engine::render_page(
            &draft,
            section_number,
            &request,
            photo.as_ref(),
            cancel,
            page,
        );
        let image = match rendered {
            Err(error)
                if id != current
                    && error
                        .downcast_ref::<handwriting_core::Error>()
                        .is_some_and(|error| error.code == "invalid_page") =>
            {
                let note =
                    format!("备选字体 {name} 重新分页后，第 {section_number} 节没有第 {page} 页。");
                unavailable.push(json!({"font":id, "name":name, "section":section_number,
                    "page":page, "reason":"page_missing_after_reflow", "message":note}));
                blocks.push(ContentBlock::text(note));
                continue;
            }
            other => other
                .with_context(|| format!("字体 {name} · 第 {section_number} 节第 {page} 页"))?,
        };
        let crop = crop_image(&image, sample.crop)?;
        data["native_size"] = json!([image.width(), image.height()]);
        data["sample_size"] = json!([crop.width(), crop.height()]);
        let mut row = json!({"font":id,"name":name});
        let label = if id == current {
            format!("当前字体 · {name}")
        } else {
            row["tune_arguments"] = json!({
                "draft_id":draft.id, "expected_revision":draft.revision,
                "changes":{"font":id}, "preserve_local_adjustments":true
            });
            format!("备选字体 · {name}")
        };
        blocks.push(ContentBlock::text(label));
        blocks.push(ContentBlock::image(
            STANDARD.encode(export::png(&crop)?),
            "image/png",
        ));
        rows.push(row);
    }
    data["samples"] = json!(rows);
    if !unavailable.is_empty() {
        data["unavailable_samples"] = json!(unavailable);
    }
    let notes = ["content_note", "placement_note", "background_note"]
        .into_iter()
        .filter_map(|key| data[key].as_str())
        .collect::<Vec<_>>()
        .join("\n");
    let mut result = reply(
        format!(
            "第 {} 版 · 第 {section_number} 节第 {page} 页。第一张为当前字体。请比较字形、粗细，以及英文和数字是否清楚。若保留当前字体，无需改稿。\n{notes}\n{data}",
            draft.revision
        ),
        data,
    );
    result.content.extend(blocks);
    Ok(result)
}
