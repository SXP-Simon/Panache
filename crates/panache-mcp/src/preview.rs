use crate::{
    Panache, Preview, PreviewView, State,
    drafts::{Section, Snapshot},
    engine::{Engine, export_blur},
    reply, review,
};
use anyhow::{Context, Result, ensure};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use handwriting_core::{Cancellation, Limits, export};
use rmcp::{
    RoleServer,
    model::{CallToolResult, ContentBlock},
    service::RequestContext,
};
use serde_json::json;

pub(super) async fn run(
    server: &Panache,
    input: Preview,
    ctx: RequestContext<RoleServer>,
) -> Result<CallToolResult> {
    let finish = export_blur::finish(input.export_blur_px, input.export_blur_gradient)?;
    if finish.is_some() {
        ensure!(
            matches!(input.view, None | Some(PreviewView::Image)),
            "export_blur_px and export_blur_gradient require view=image"
        );
    }
    ensure!(
        !input.fresh || matches!(input.view, None | Some(PreviewView::Image)),
        "fresh=true requires view=image (or no view)"
    );
    ensure!(
        input.before_review_id.is_none()
            || (input.view == Some(PreviewView::Review)
                && input.compare_revision.is_some()
                && input.region.is_none()
                && input.previous_region.is_none()
                && input.illustrations_only.is_none()),
        "before_review_id requires an unfiltered view=review with compare_revision and no region"
    );
    ensure!(
        input.previous_region.is_none()
            || (input.view == Some(PreviewView::Review)
                && input.region.is_some()
                && input.compare_revision.is_some()),
        "previous_region requires view=review, region and compare_revision"
    );
    if let Some(before) = input.compare_revision
        && input.region.is_none()
    {
        ensure!(
            input.view == Some(PreviewView::Review) && input.illustrations_only.is_none(),
            "compare_revision requires an unfiltered review view"
        );
        let draft = server.0.drafts.snapshot(&input.draft_id, input.revision)?;
        let data = draft.compare_reviews(
            before,
            input.section.unwrap_or(1),
            input.page.unwrap_or(1),
            u32::try_from(input.offset.unwrap_or(0))?,
            u32::try_from(input.limit.unwrap_or(20))?,
            input.before_review_id.as_deref(),
        )?;
        return Ok(reply(data.to_string(), data));
    }
    server
        .render(ctx, move |state, engine, cancel| {
            render(state, engine, &input, finish, cancel)
        })
        .await
}

fn render(
    state: &State,
    engine: &mut Engine,
    input: &Preview,
    finish: Option<export_blur::Finish>,
    cancel: &Cancellation,
) -> Result<CallToolResult> {
    let draft = state.drafts.snapshot(&input.draft_id, input.revision)?;
    ensure!(
        input.illustrations_only.is_none() || input.view == Some(PreviewView::Layout),
        "illustrations_only requires view=layout"
    );
    ensure!(
        input.region.is_none()
            || matches!(input.view, Some(PreviewView::Layout | PreviewView::Review))
            || finish.is_some(),
        "region requires view=layout, view=review, or view=image with an explicit PNG finish"
    );
    ensure!(
        input.compare_revision.is_none() || input.view == Some(PreviewView::Review),
        "compare_revision requires view=review"
    );
    if input.view == Some(PreviewView::Paper) {
        ensure!(
            input.offset.is_none()
                && input.limit.is_none()
                && input.section.is_none()
                && input.page.is_none(),
            "view=paper takes only draft_id and revision"
        );
        return paper(&draft);
    }
    let number = input.section.unwrap_or(1);
    let section = state
        .drafts
        .sections(&input.draft_id, draft.revision, Some(number))?
        .pop()
        .context("Empty draft")?;
    let page = input.page.unwrap_or(1);
    let max = Limits::default().max_pages;
    ensure!(
        (1..=max).contains(&page),
        "Requested page {page} in section {number}. Page numbers start at 1 within each section (maximum {max})."
    );
    if input.view == Some(PreviewView::Review) {
        ensure!(
            input.limit.is_none() && input.offset.is_none(),
            "Review a single page without pagination"
        );
        if let Some(region) = &input.region {
            return review::local::page(
                &state.drafts,
                engine,
                &draft,
                section,
                input,
                region,
                cancel,
            );
        }
        ensure!(
            !state.preserve_reviews,
            "此连接保留原有检查记录。看成图请用 view=image，查原单请用 read_section(view=review)，打印请用 export_handwriting。"
        );
        let baselines = engine.review_baselines(&draft, section.clone(), page, cancel)?;
        let (preview, _) = engine.preview(&draft, section, page, cancel)?;
        let result = review::page(&draft, number, page, &preview.png, &baselines, cancel)?;
        return add_paper_focus(state, &draft, number, page, result);
    }
    if input.view == Some(PreviewView::Layout) {
        let result = engine.layout(&draft, section, input, cancel)?;
        return Ok(reply(result.to_string(), result));
    }
    ensure!(
        input.offset.is_none() && input.limit.is_none(),
        "offset and limit require view=layout"
    );
    if let Some(finish) = finish {
        let (preview, cached) =
            engine.preview_with_refresh(&draft, section, page, input.fresh, cancel)?;
        let original = review::decode_page(&preview.png)?;
        let size = original.dimensions();
        let bounds = input
            .region
            .as_deref()
            .map(|region| review::local::crop_bounds(region, size))
            .transpose()?;
        let mut finished = if finish.active() {
            finish.apply(&original, cancel)?
        } else {
            original
        };
        if let Some([x, y, width, height]) = bounds {
            finished = image::imageops::crop_imm(&finished, x, y, width, height).to_image();
        }
        let mut metadata = json!({"draft_id":draft.id,"revision":draft.revision,"section":number,"page_in_section":page,"cached":cached,
            "photo_size":size,"crop_bounds":bounds,"image_size":finished.dimensions()});
        finish.write_metadata(&mut metadata);
        let mut result = reply(format!("PNG 导出效果，原图像素。{metadata}"), metadata);
        result.content.push(ContentBlock::image(
            STANDARD.encode(export::png(&finished)?),
            "image/png",
        ));
        return Ok(result);
    }
    let result = image(
        engine,
        &draft,
        section,
        page,
        input.fresh,
        !state.preserve_reviews,
        cancel,
    )?;
    add_paper_focus(state, &draft, number, page, result)
}

fn add_paper_focus(
    state: &State,
    draft: &Snapshot<'_>,
    section: u32,
    page: usize,
    mut result: CallToolResult,
) -> Result<CallToolResult> {
    if let Some(focus) = state.paper_focus.report(draft, section, page)? {
        result
            .content
            .push(ContentBlock::text(format!("底纸边缘原尺寸检查 {focus}")));
        if let Some(data) = result.structured_content.as_mut() {
            data["paper_focus_check"] = focus;
        }
    }
    Ok(result)
}

fn paper(draft: &Snapshot<'_>) -> Result<CallToolResult> {
    let bytes = draft
        .background()?
        .context("No imported paper for this draft")?;
    let img = handwriting_core::imaging::decode(&bytes, &Limits::default())?.into_rgba8();
    let mut result = reply(
        "稿件底纸".into(),
        json!({"width":img.width(),"height":img.height(),"revision":draft.revision}),
    );
    result.content.push(ContentBlock::image(
        STANDARD.encode(draft.camera(Some(&bytes))?.png(&img)?),
        "image/png",
    ));
    Ok(result)
}

fn image(
    engine: &mut Engine,
    draft: &Snapshot<'_>,
    section: Section,
    page: usize,
    fresh: bool,
    review_allowed: bool,
    cancel: &Cancellation,
) -> Result<CallToolResult> {
    let number = section.number;
    let contains_drawing =
        section.text.contains("](data:image/") || section.text.contains("\\begin{circuitikz}");
    let read_only_sample = if draft.paper.is_some() && !review_allowed {
        Some(engine.review_baselines(draft, section.clone(), page, cancel)?)
    } else {
        None
    };
    let (preview, cached) = engine.preview_with_refresh(draft, section, page, fresh, cancel)?;
    let mut message = format!("第 {number} 节 · 第 {page} 页 · 版本 {}", draft.revision);
    let mut data = json!({"draft_id":draft.id,"revision":draft.revision,"section":number,"page_in_section":page,"cached":cached});
    if contains_drawing {
        let hint = "如果当前页既有手绘图又有文字，在判断笔迹一致前，用 view=review 加 region 框住一段图线和旁边的字，同倍率比较粗细和墨色。先对照节点和分支标签与正文的字形、字号，再看箭杆和框线是否接近文字的主笔画。在横线纸上沿箭杆追到箭头。图线与纸线重合时，优先平移整图或调整节点间距，缩放整图会连同标签一起缩放。同页看图与字只传当前版，省略 compare_revision。看不清时说明还不能判断。";
        message.push('\n');
        message.push_str(hint);
        data["illustration_inspection"] = json!(hint);
    }
    if draft.paper.is_some() && review_allowed {
        let hint = "用 view=review 的 local_paper_ink_check 在原尺寸查看页首和正文，把新笔迹和附近原纸印迹放在一起看。页首纸线淡而字重时，先局部调 opacity，再查看过渡行。整页缩略图会掩盖反差。按 adjacent_row_check 检查邻行字形，有图时也对照图线。";
        message.push('\n');
        message.push_str(hint);
        data["photo_review_arguments"] = json!({"draft_id":draft.id,"revision":draft.revision,"section":number,"page":page,"view":"review"});
    }
    if let Some(sample) = read_only_sample
        && let Some(check) =
            review::local_ink_preview(draft, number, page, &preview.png, &sample, cancel)?
    {
        message.push_str(&format!("\n原纸与新增笔迹的局部反差 {check}"));
        data["local_paper_ink_check"] = check;
    }
    let mut result = reply(message, data);
    result
        .content
        .push(ContentBlock::image(preview.png, "image/png"));
    Ok(result)
}
