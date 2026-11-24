use crate::{
    Panache, Preview, PreviewView, State,
    drafts::{Section, Snapshot},
    engine::Engine,
    reply, review,
};
use anyhow::{Context, Result, ensure};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use handwriting_core::{Cancellation, Limits};
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
        )?;
        return Ok(reply(data.to_string(), data));
    }
    server
        .render(ctx, move |state, engine, cancel| {
            render(state, engine, &input, cancel)
        })
        .await
}

fn render(
    state: &State,
    engine: &mut Engine,
    input: &Preview,
    cancel: &Cancellation,
) -> Result<CallToolResult> {
    let draft = state.drafts.snapshot(&input.draft_id, input.revision)?;
    ensure!(
        input.illustrations_only.is_none() || input.view == Some(PreviewView::Layout),
        "illustrations_only requires view=layout"
    );
    ensure!(
        input.region.is_none()
            || matches!(input.view, Some(PreviewView::Layout | PreviewView::Review)),
        "region requires view=layout or review"
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
        let baselines = engine.review_baselines(&draft, section.clone(), page, cancel)?;
        let (preview, _) = engine.preview(&draft, section, page, cancel)?;
        return review::page(&draft, number, page, &preview.png, &baselines, cancel);
    }
    if input.view == Some(PreviewView::Layout) {
        let result = engine.layout(&draft, section, input, cancel)?;
        return Ok(reply(result.to_string(), result));
    }
    ensure!(
        input.offset.is_none() && input.limit.is_none(),
        "offset and limit require view=layout"
    );
    image(engine, &draft, section, page, cancel)
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
    cancel: &Cancellation,
) -> Result<CallToolResult> {
    let number = section.number;
    let (preview, cached) = engine.preview(draft, section, page, cancel)?;
    let mut result = reply(
        format!("第 {number} 节 · 第 {page} 页 · 版本 {}", draft.revision),
        json!({"draft_id":draft.id,"revision":draft.revision,"section":number,"page_in_section":page,"cached":cached}),
    );
    result
        .content
        .push(ContentBlock::image(preview.png, "image/png"));
    Ok(result)
}
