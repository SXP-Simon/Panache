mod controls;
mod drafts;
mod engine;
mod inputs;
mod markdown;
mod paper;
mod placement;
mod preview;
mod replace_text;
mod review;
mod save;
mod storage;
mod tuning;

use anyhow::{Context, Result, ensure};
use drafts::Drafts;
use engine::Engine;
use handwriting_core::{
    Cancellation, Limits,
    local_fonts::{FontSearch, LocalFonts},
};
use inputs::*;
use rmcp::{
    RoleServer, ServerHandler, ServiceExt,
    handler::server::wrapper::Parameters,
    model::{CallToolResult, ContentBlock},
    service::RequestContext,
    tool, tool_handler, tool_router,
};
use serde_json::json;
use std::{
    env, fs,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};
use tokio::sync::Semaphore;

struct State {
    drafts: Drafts,
    preserve_reviews: bool,
    engine: Mutex<Engine>,
    fonts: Vec<String>,
    local_fonts: LocalFonts,
    storage: storage::Storage,
    worker: Arc<str>,
    render_slot: Arc<Semaphore>,
    prepare_slot: Arc<Semaphore>,
}
#[derive(Clone)]
struct Panache(Arc<State>);

impl State {
    fn import_catalog_font(&self, id: &str, revision: u32) -> Result<Option<(String, Vec<u8>)>> {
        if self.fonts.iter().any(|f| f == id) {
            return Ok(None);
        }
        let (entry, bytes) = self.local_fonts.read(id)?;
        Ok(Some((
            format!("upload:{revision}:{}", entry.filename),
            bytes,
        )))
    }
}

fn reply(message: String, metadata: serde_json::Value) -> CallToolResult {
    let mut result = CallToolResult::success(vec![ContentBlock::text(message)]);
    result.structured_content = Some(metadata);
    result
}

fn add_receipt_summary(record: &mut serde_json::Value) -> String {
    let position = format!(
        "第 {} 版 · 第 {} 节第 {} 页",
        record["revision"], record["section"], record["page"]
    );
    let conclusion = match record["review_id"].as_str() {
        None => format!("{position}没有已存的整页检查单。是否曾在纸上看过，档案无法判断。"),
        Some(id) => match record["filed_at_revision"].as_u64() {
            Some(filed) if Some(filed) == record["revision"].as_u64() => {
                format!(
                    "{position}已存整页检查单，检查单号 {id}。首次入档时稿件仍为第 {filed} 版。"
                )
            }
            Some(filed) => format!(
                "{position}有一张事后补验的检查单，检查单号 {id}。首次入档时稿件已到第 {filed} 版，这张单无法证明改稿前已经验过。"
            ),
            None => format!(
                "能否确认改稿前已验过？无法确认。{position}有旧单，检查单号 {id}。旧单未记录首次入档时的稿件版本，可能是事后补验。"
            ),
        },
    };
    record["receipt_summary"] = json!(conclusion);
    conclusion
}

fn page_receipt(
    draft: &drafts::Snapshot<'_>,
    section: u32,
    page: u32,
    anchor: Option<(u32, u32)>,
) -> Result<CallToolResult> {
    let mut record = draft.page_observation(section, page)?;
    record["latest_draft_revision"] = json!(draft.latest_revision);
    if let Some((anchor_section, added_revision)) = anchor {
        record["before_text_match"] =
            json!({"section": anchor_section, "introduced_revision": added_revision});
    }
    let conclusion = add_receipt_summary(&mut record);
    let text = format!(
        "{conclusion}\n当前稿件第 {} 版。\n{record}",
        draft.latest_revision
    );
    Ok(reply(text, record))
}

impl Panache {
    async fn read_review(
        &self,
        input: Read,
        ctx: RequestContext<RoleServer>,
    ) -> Result<CallToolResult> {
        ensure!(
            input.cursor.is_none() && input.feedback_origin.is_none(),
            "cursor and feedback_origin require view=trajectory"
        );
        ensure!(
            input.offset.is_none() && input.limit.is_none(),
            "view=review does not use offset or limit"
        );
        if let Some(page) = input.page {
            ensure!(input.review_id.is_none(), "Use page or review_id, not both");
            ensure!(
                input.before_text.is_none() || input.revision.is_none(),
                "Use before_text or revision, not both"
            );
            let anchor = input
                .before_text
                .as_deref()
                .map(|t| self.0.drafts.text_introduction(&input.draft_id, t))
                .transpose()?;
            let revision = anchor.map(|(_, added)| added - 1).or(input.revision);
            return match page {
                ReviewPage::Number(n) => {
                    let draft = self.0.drafts.snapshot(&input.draft_id, revision)?;
                    let section = if anchor.is_some() {
                        draft.review_section(input.section)?
                    } else {
                        input.section.unwrap_or(1)
                    };
                    page_receipt(&draft, section, n, anchor)
                }
                ReviewPage::Last(_) => {
                    self.render(ctx, move |state, engine, cancel| {
                        let draft = state.drafts.snapshot(&input.draft_id, revision)?;
                        let section = draft.review_section(input.section)?;
                        let source = state
                            .drafts
                            .sections(draft.id, draft.revision, Some(section))?
                            .pop()
                            .context("Empty section")?;
                        let last = engine.page_count(&draft, source, cancel)?;
                        page_receipt(&draft, section, last, anchor)
                    })
                    .await
                }
            };
        }
        ensure!(
            input.section.is_none() && input.before_text.is_none(),
            "Supply page with section or before_text, or review_id alone"
        );
        let draft = self.0.drafts.snapshot(&input.draft_id, input.revision)?;
        let mut data = draft.observation(
            input
                .review_id
                .as_deref()
                .context("Supply review_id or page")?,
        )?;
        let summary = add_receipt_summary(&mut data);
        let mut content_note = None;
        if input.revision.is_some() && data["revision"].as_u64() != Some(u64::from(draft.revision))
        {
            content_note = Some(ContentBlock::text(format!(
                "此单属于第 {} 版。若要确认所查第 {} 版是否留有整页检查单，请用 read_section(view=review, revision={}, section={}, page={}) 查该版。",
                data["revision"], draft.revision, draft.revision, data["section"], data["page"]
            )));
        }
        let mut result = reply(data.to_string(), data);
        result.content.push(ContentBlock::text(summary));
        result.content.extend(content_note);
        Ok(result)
    }
}

fn tool_result(out: Result<CallToolResult>) -> CallToolResult {
    out.unwrap_or_else(|error| {
        CallToolResult::error(vec![ContentBlock::text(format!("{error:#}"))])
    })
}

struct CancelOnDrop(Cancellation);
impl Drop for CancelOnDrop {
    fn drop(&mut self) {
        self.0.cancel();
    }
}

impl Panache {
    async fn storage_task(
        &self,
        run: impl FnOnce(&storage::Storage, &Drafts) -> Result<serde_json::Value> + Send + 'static,
    ) -> CallToolResult {
        let state = self.0.clone();
        tool_result(
            async {
                let value = tokio::task::spawn_blocking(move || run(&state.storage, &state.drafts))
                    .await??;
                Ok(reply(value.to_string(), value))
            }
            .await,
        )
    }
    async fn render(
        &self,
        ctx: RequestContext<RoleServer>,
        work: impl FnOnce(&State, &mut Engine, &Cancellation) -> Result<CallToolResult> + Send + 'static,
    ) -> Result<CallToolResult> {
        let permit = tokio::select! {
            slot=self.0.render_slot.clone().acquire_owned()=>slot?,
            _=ctx.ct.cancelled()=>anyhow::bail!("Cancelled"),
        };
        let state = self.0.clone();
        let guard = CancelOnDrop(Cancellation::default());
        let token = guard.0.clone();
        let worker = tokio::task::spawn_blocking(move || {
            let _permit = permit;
            let mut engine = state
                .engine
                .lock()
                .map_err(|_| anyhow::anyhow!("Render worker unavailable"))?;
            let result = work(&state, &mut engine, &token);
            engine.release_fonts();
            result
        });
        tokio::select! {
            result=worker=>result?,
            _=ctx.ct.cancelled()=>anyhow::bail!("Cancelled"),
        }
    }
}

#[tool_handler]
impl ServerHandler for Panache {
    fn get_info(&self) -> rmcp::model::ServerConfig {
        use rmcp::model::{Implementation, ServerCapabilities, ServerConfig};
        let instructions = concat!(
            "If a required area of a photo is outside the frame, or blur, occlusion or perspective prevents locating it, identify that area before drafting. ",
            "Ask for a photo clearly showing it or permission to fill only visible areas; wait before saving or trial placement. If partial work was requested, proceed there. ",
            "For looser, less uniform homework or lab handwriting (字稍微草一点), inspect describe_controls(group=variation). For requested crossed-out mistakes (涂改痕迹), inspect group=strike. ",
            "Use save_section(markdown), then its draft_id and revision for preview_handwriting or export_handwriting. ",
            "English letters and digits follow the main font by default. Leave Latin controls unset unless the user requests a different look for them or dislikes how they appear. For an undecided homework or lab-report style, see list_fonts for sample guidance. Use list_drafts to resume. A paper_path must be readable on the server computer. ",
            "For old checks before a passage was added, use read_section(view=review, before_text=literal from that addition, section, page); page can be \"last\". For current checks omit revision. If the user asks to see or print without a new check, use view=image for the appearance and export_handwriting for the file and missing pages. A full-page preview_handwriting(view=review) records a check. Follow photo_appearance.preview_arguments for a native detail crop when available. ",
            "If images cannot reach the model, use the reported measurements and ask the user to inspect the page before judging its appearance. ",
            "Forms, unruled paper and artwork are supported. Follow specified or delegated placement, matching field orientation and preserving printed labels. ",
            "If the intended writing area is ambiguous, ask which field to fill or leave clear. ",
            "Photo coordinates use native output pixels; local dx/dy use paper-space pixels. ",
            "Inspect the edited appearance with view=image when no new check is requested. Use read_section(view=trajectory) to revisit actions and evidence."
        );
        let mode = if self.0.preserve_reviews {
            "This connection preserves stored reviews. Use view=image to inspect and export_handwriting to print. "
        } else {
            ""
        };
        ServerConfig::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new(
                "panache-mcp",
                handwriting_core::app_version(),
            ))
            .with_instructions(format!("{mode}{instructions}"))
    }
}

#[tool_router]
impl Panache {
    #[tool(
        annotations(read_only_hint = true, open_world_hint = false),
        description = "For less even handwriting, inspect group=variation; for requested occasional crossed-out mistakes, group=strike. Pass draft_id to read current values before tune_handwriting. Omit group for the index."
    )]
    fn describe_controls(&self, Parameters(input): Parameters<Describe>) -> CallToolResult {
        tool_result((|| {
            let catalog = controls::catalog();
            ensure!(
                input.revision.is_none() || input.draft_id.is_some(),
                "revision requires draft_id"
            );
            ensure!(
                input.draft_id.is_none() || input.group.is_some(),
                "Select a group to inspect values"
            );
            let mut data = match input.group {
                Some(group) => {
                    json!({"group":group,"controls":catalog.get(&group).context("Unknown group; omit group for index")?})
                }
                None => json!({"groups":catalog.keys().collect::<Vec<_>>()}),
            };
            if let Some(id) = input.draft_id {
                let draft = self.0.drafts.snapshot(&id, input.revision)?;
                let params = controls::parameters(&draft, 1, &draft.controls)?;
                let values = serde_json::to_value(&params)?;
                let mut effective = serde_json::Map::new();
                for k in data["controls"].as_object().unwrap().keys() {
                    let val = match k.as_str() {
                        "font" => json!(
                            draft
                                .controls
                                .get(k)
                                .and_then(|v| v.as_str())
                                .unwrap_or(&draft.style.font)
                        ),
                        "paper" => draft
                            .controls
                            .get(k)
                            .cloned()
                            .unwrap_or(json!(draft.style.paper)),
                        "ink_alpha" => json!(params.fill[3]),
                        "ink" => json!(
                            draft
                                .controls
                                .get(k)
                                .and_then(|v| v.as_str())
                                .unwrap_or(&draft.style.ink)
                        ),
                        "width" if draft.paper.is_some() => {
                            json!(draft.paper.as_ref().map(|p| p.width))
                        }
                        "height" if draft.paper.is_some() => {
                            json!(draft.paper.as_ref().map(|p| p.height))
                        }
                        _ => values[k].clone(),
                    };
                    effective.insert(k.clone(), val);
                }
                data["values"] = json!(effective);
                data["revision"] = json!(draft.revision);
            }
            Ok(reply(data.to_string(), data))
        })())
    }

    #[tool(
        description = "Revise a draft: change controls, import a local font_path, or replace paper_guides on its saved image. Map the intended area onto first/last writable baselines even on artwork or unruled paper. Ink-group changes preserve local glyph placement; after changing font, size or guides, inspect the new layout. Use view=image to inspect the result when the user wants to preserve checks."
    )]
    async fn tune_handwriting(&self, Parameters(input): Parameters<Tune>) -> CallToolResult {
        let state = self.0.clone();
        tool_result(
            async {
                let permit = state.prepare_slot.clone().acquire_owned().await?;
                tokio::task::spawn_blocking(move || {
                    let _permit = permit;
                    tuning::apply(&state, input)
                })
                .await?
            }
            .await,
        )
    }

    #[tool(
        annotations(read_only_hint = true, open_world_hint = false),
        description = "Search bundled, personal and system fonts by name/source. Results are paged. Use an entry ID in save_section style.font or tune_handwriting changes.font; user and system faces are saved with the draft."
    )]
    async fn list_fonts(&self, Parameters(query): Parameters<FontSearch>) -> CallToolResult {
        let state = self.0.clone();
        let result = async {
            let page = tokio::task::spawn_blocking(move || state.local_fonts.search(&query)).await??;
            let names: Vec<_> = page.fonts.iter().map(|font| &font.id).collect();
            let guidance = concat!(
                "Select only the main font for a new draft. Its letters and digits are the default, including for homework and lab reports. ",
                "For a hurried pen style, try 李国夫手写体.ttf if listed. Use a short line from the task with Chinese, an English term and a number or unit. ",
                "Preview it at the intended size on the intended paper. Compare stroke weight, slant, relative size and digit legibility. ",
                "If the style is undecided, show the sample, recommend a font based on what is visible, and ask if it fits before laying out the full page. ",
                "Keep an approved font. For a less regular hand inspect describe_controls(group=variation) and preview a small change. If the user wants occasional corrections, inspect group=strike. Only consider separate settings for letters or digits when the user specifically requests them or expresses dissatisfaction with their appearance; then inspect describe_controls(group=typography)."
            );
            let mut data = json!({
                "entries": page.fonts, "total": page.total,
                "next_offset": page.next_offset, "user_dir": page.user_dir
            });
            let message = format!("{data}\n\n{guidance}");
            data["fonts"] = json!(names);
            data["sample_guidance"] = json!(guidance);
            Ok(reply(message, data))
        }.await;
        tool_result(result)
    }

    #[tool(
        description = "Save Markdown without rendering. For pen-matched flowcharts, use a circuitikz environment with \\draw[->] paths and node labels. On creation, optionally import a local stationery image with paper_path. Append or revise a section with expected_revision. Each section starts a new page. Keep the returned draft_id and revision. Returns detected paper.alignment."
    )]
    async fn save_section(&self, Parameters(input): Parameters<Save>) -> CallToolResult {
        tool_result(save::run(self, input).await)
    }

    #[tool(
        description = "Replace one whole line in an existing section at its current revision without resending Markdown or inline images. The entire section must consist of blank-line-separated blocks: single lines of letters (including Han characters), digits and interior ASCII spaces, or validated standalone embedded images. Saved glyph adjustments in this section prevent replacement."
    )]
    async fn replace_section_text(
        &self,
        Parameters(input): Parameters<ReplaceText>,
    ) -> CallToolResult {
        tool_result(replace_text::run(self, input).await)
    }

    #[tool(
        annotations(read_only_hint = true, open_world_hint = false),
        description = "Find previously saved drafts across sessions. Returns up to 20 summaries, newest creations first."
    )]
    fn list_drafts(&self, Parameters(input): Parameters<List>) -> CallToolResult {
        tool_result(self.0.drafts.list(input.offset.unwrap_or(0)).map(|result| {
            let mut lines = vec!["## 本地稿件".to_owned()];
            for row in result["drafts"].as_array().into_iter().flatten() {
                lines.push(format!(
                    "- {} · `{}` · 版本 {} · {} 节",
                    row["title"].as_str().unwrap_or_default(),
                    row["draft_id"].as_str().unwrap_or_default(),
                    row["revision"],
                    row["sections"]
                ));
            }
            reply(lines.join("\n"), result)
        }))
    }

    #[tool(
        annotations(read_only_hint = true, open_world_hint = false),
        description = "For a prior check of a particular sheet, use view=review, section and page. For “before adding [words]” pass before_text with a literal fragment of the addition; for the final sheet of that section pass page=\"last\". These select and paginate the same historical version in one lookup. For a single requested sheet cite its returned review_id and receipt_summary. Other revisions can have separate receipts for the same page. Otherwise omit revision for current or set a revision. The check receipt number (检查单号) is review_id. Read its saved measurements and attributed feedback, or no_recorded_review, without creating a check. A known review_id retrieves that record. Use view=trajectory to identify revisions from edits or search across versions: older events remain in the results. Filter by section and feedback_origin=user_quote for verbatim events[].details.text. Text views: summary, excerpt (default, image data omitted), source (exact Markdown)."
    )]
    async fn read_section(
        &self,
        Parameters(input): Parameters<Read>,
        ctx: RequestContext<RoleServer>,
    ) -> CallToolResult {
        if input.view == Some(ReadView::Review) {
            return tool_result(self.read_review(input, ctx).await);
        }
        tool_result((|| {
            ensure!(
                input.feedback_origin.is_none() || input.view == Some(ReadView::Trajectory),
                "feedback_origin requires view=trajectory"
            );
            ensure!(
                input.page.is_none() && input.before_text.is_none(),
                "page and before_text require view=review"
            );
            if input.view == Some(ReadView::Trajectory) {
                ensure!(input.review_id.is_none(), "review_id requires view=review");
                let result = self.0.drafts.trajectory(&input)?;
                return Ok(reply(result.to_string(), result));
            }
            ensure!(input.cursor.is_none(), "cursor requires view=trajectory");
            let draft = self.0.drafts.snapshot(&input.draft_id, input.revision)?;
            ensure!(input.review_id.is_none(), "review_id requires view=review");
            let mut result = self.0.drafts.review(
                &input.draft_id,
                draft.revision,
                input.section.unwrap_or(1),
                input.offset.unwrap_or(0),
                input.limit.unwrap_or(1000),
                input.view.unwrap_or_default(),
            )?;
            result["style"] = serde_json::to_value(&draft.style)?;
            if !draft.controls.is_empty() {
                result["controls"] = json!(draft.controls);
            }
            if let Some(layout) = &draft.paper {
                result["paper"] = layout.summary();
            }
            if input.view == Some(ReadView::Summary) {
                return Ok(reply(result.to_string(), result));
            }
            let message = format!(
                "稿件 `{}` · 版本 {} · 第 {} 节 · 从第 {} 个字符起（共 {} 个）\n\n{}",
                input.draft_id,
                draft.revision,
                result["section"],
                result["offset"],
                result["total_chars"],
                result["markdown"].as_str().unwrap_or_default()
            );
            Ok(reply(message, result))
        })())
    }

    #[tool(
        annotations(open_world_hint = false),
        description = "Use view=image to see the page without filing a check. A full-page view=review renders and records a check. To look up an existing check without rendering use read_section(view=review, section, page). view=review returns paper, finished appearance, overlay and full-page evidence. With compare_revision alone it reads stored data, review IDs, intervening edits and limitations. With region it renders labeled local crops in native image coordinates and measures visible changes; add compare_revision for paired before/after, and previous_region for the old location of moved content. Use a separate region to inspect protected content. view=layout returns glyph IDs and base boxes [x,y,width,height], paginated by offset/limit. Use region to select current glyph centers, illustrations_only for diagrams. Projected layouts include base photo_quad (TL,TR,BR,BL) and photo_baseline. view=paper returns the saved background."
    )]
    async fn preview_handwriting(
        &self,
        Parameters(input): Parameters<Preview>,
        ctx: RequestContext<RoleServer>,
    ) -> CallToolResult {
        tool_result(preview::run(self, input, ctx).await)
    }

    #[tool(
        description = "Attach a user's exact quote or your own model observation to a review_id. Does not advance the draft revision. Use read_section(view=review,review_id=...) to retrieve it."
    )]
    fn annotate_review(&self, Parameters(input): Parameters<ReviewFeedback>) -> CallToolResult {
        if self.0.preserve_reviews {
            return tool_result(Err(anyhow::anyhow!(
                "此连接保留原有检查记录，无法添加评语。可用 read_section(view=review) 查阅原单。"
            )));
        }
        tool_result(
            self.0
                .drafts
                .annotate(&input)
                .map(|data| reply(data.to_string(), data)),
        )
    }

    #[tool(
        description = "Adjust selected glyphs in one section/page by IDs from its layout view. Use the same revision. Offsets and shape are in paper space before sheet projection. Use place_center for a group move; target_quad maps the entire selected text block into four corners on the image. Shape adjusts each glyph individually."
    )]
    async fn adjust_glyphs(
        &self,
        Parameters(input): Parameters<Nudge>,
        ctx: RequestContext<RoleServer>,
    ) -> CallToolResult {
        tool_result(
            self.render(ctx, move |state, engine, cancel| {
                let draft = state
                    .drafts
                    .snapshot(&input.draft_id, Some(input.expected_revision))?;
                let section = state
                    .drafts
                    .sections(draft.id, draft.revision, Some(input.section))?
                    .pop()
                    .context("Unknown section")?;
                ensure!(
                    input.note.as_ref().is_none_or(|s| s.chars().count() <= 320),
                    "Note exceeds 320 characters"
                );
                let next = engine.adjust(&draft, section, &input, cancel)?;
                Ok(reply(
                    format!("Saved revision {next}."),
                    json!({"draft_id":draft.id,"revision":next,"count":input.ids.len()}),
                ))
            })
            .await,
        )
    }

    #[tool(
        annotations(read_only_hint = true, open_world_hint = false),
        description = "Inspect MCP home file sizes, available volume space, limits and protected payload. Optionally scope logical counts and registered exports to one draft. Use before considering cleanup."
    )]
    async fn storage_usage(&self, Parameters(input): Parameters<storage::Usage>) -> CallToolResult {
        self.storage_task(move |store, drafts| store.usage(drafts, input))
            .await
    }
    #[tool(
        annotations(read_only_hint = true, open_world_hint = false),
        description = "Preview one draft's registered exports, eligible abandoned temporary files and byte estimates. Delivered files are report-only. No disk changes. Pass next_after_id to see more."
    )]
    async fn plan_cleanup(
        &self,
        Parameters(input): Parameters<storage::CleanupScope>,
    ) -> CallToolResult {
        self.storage_task(move |store, drafts| store.plan_cleanup(drafts, input))
            .await
    }
    #[tool(
        annotations(destructive_hint = true, open_world_hint = false),
        description = "Remove selected abandoned temporary files from a fresh plan in this session. Intended only for reclaiming failed exports. A plan is not permission to delete user deliverables. No paths, completed exports, manuscript history, fonts, papers or reviews can be selected."
    )]
    async fn apply_cleanup(
        &self,
        Parameters(input): Parameters<storage::ApplyCleanup>,
    ) -> CallToolResult {
        self.storage_task(move |store, drafts| store.apply_cleanup(drafts, input))
            .await
    }

    #[tool(
        description = "Export the complete saved revision, in section order, to a local PDF (default) or ZIP of page PNGs. Returns the path, page count and review.unreviewed_pages in print order. For a print-and-report request return the file and missing pages. Only if a new check is requested, use preview_handwriting(view=review) at the exported revision. For ink-only PNG pages, set transparent_background=true with tune_handwriting (ink group) and export ZIP. PDF always includes paper. Text-only clients can give the user the PDF path for visual inspection. Use view=image to inspect the intended appearance without filing a check."
    )]
    async fn export_handwriting(
        &self,
        Parameters(input): Parameters<Export>,
        ctx: RequestContext<RoleServer>,
    ) -> CallToolResult {
        let progress_token = ctx.meta.get_progress_token();
        let peer = ctx.peer.clone();
        let result = self.render(ctx, move |state, engine, cancel| {
            let draft = state.drafts.snapshot(&input.draft_id, input.revision)?;
            let sections = state.drafts.sections(&input.draft_id, draft.revision, None)?;
            let reviewed_pages = draft.reviewed_pages()?;
            let mut unreviewed = Vec::new();
            let mut visibility_flags = 0;
            let params = controls::parameters(&draft, 1, &draft.controls)?;
            let zero_text_ink = params.ink_opacity == 0 || params.fill[3] == 0;
            let format = input.format.unwrap_or_default();
            let (path, pages) = state.storage.export(&state.drafts,draft.id,draft.revision,format, |writer| engine.export(
                writer, &draft, sections, format, cancel,
                |pages, section, page| {
                    match reviewed_pages.get(&(section, page)) {
                        Some(flagged) => visibility_flags += usize::from(*flagged),
                        None => unreviewed.push(json!({"section":section,"page":page})),
                    }
                    if let Some(token) = &progress_token {
                        let update = rmcp::model::ProgressNotificationParam::new(token.clone(), pages as f64)
                            .with_message(format!("{pages} pages rendered"));
                        let _ = tokio::runtime::Handle::current().block_on(peer.notify_progress(update));
                    }
                },
            ))?;
            let reviewed = pages - unreviewed.len();
            let warning = if zero_text_ink || visibility_flags > 0 {
                "墨迹可见性需要复查。"
            } else if reviewed < pages {
                "未复盘页的局部墨迹可见性尚未核验。"
            } else {
                ""
            };
            let remaining = if unreviewed.is_empty() {
                String::new()
            } else {
                format!(" 缺少整页检查单的节内页码：{}。", serde_json::to_string(&unreviewed)?)
            };
            let message = format!("已导出 **{pages} 页**（版本 {}）。该版已有 {reviewed}/{pages} 页复盘证据。{warning}{remaining}\n\n`{}`", draft.revision, path.display());
            Ok(reply(message, json!({
                "draft_id": input.draft_id, "revision": draft.revision, "path": path, "pages": pages,
                "review": {
                    "pages_with_evidence": reviewed,
                    "pages_with_visibility_flags": visibility_flags,
                    "global_text_ink_zero": zero_text_ink,
                    "pages_without_visibility_evidence": unreviewed.len(),
                    "unreviewed_pages": unreviewed,
                }
            })))
        }).await;
        tool_result(result)
    }
}

fn asset(key: &str, beside: &Path, name: &str, source: &str) -> PathBuf {
    env::var_os(key).map(PathBuf::from).unwrap_or_else(|| {
        let installed = beside.join(name);
        if installed.exists() || beside.join("VERSION").is_file() {
            installed
        } else {
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../..")
                .join(source)
        }
    })
}

#[tokio::main]
async fn main() -> Result<()> {
    let exe = env::current_exe()?;
    let beside = exe.parent().context("Missing executable directory")?;
    let engine = Engine::new(asset(
        "PANACHE_FONT_DIR",
        beside,
        "font_assets",
        "assets/font_assets",
    ))?;
    let worker=asset("PANACHE_MARKDOWN_WORKER",beside,"prepare-text-worker.js","app/web/prepare-text-worker.js")
        .canonicalize().context("Build the Markdown worker with python scripts/build-text-worker.py, or set PANACHE_MARKDOWN_WORKER")?;
    let home = env::var_os("PANACHE_MCP_HOME")
        .map(PathBuf::from)
        .or_else(|| {
            env::var_os("LOCALAPPDATA")
                .or_else(|| env::var_os("XDG_DATA_HOME"))
                .map(PathBuf::from)
                .or_else(|| env::var_os("HOME").map(|v| PathBuf::from(v).join(".local/share")))
                .map(|p| p.join("Panache/mcp"))
        })
        .context("Set PANACHE_MCP_HOME to a writable directory")?;
    let output = home.join("exports");
    fs::create_dir_all(&output)?;
    let drafts = Drafts::open(&home)?;
    let preserve_reviews = match env::var_os("PANACHE_MCP_PRESERVE_REVIEWS").as_deref() {
        None => false,
        Some(value) if value == "0" => false,
        Some(value) if value == "1" => true,
        _ => anyhow::bail!("PANACHE_MCP_PRESERVE_REVIEWS must be 0 or 1"),
    };
    let state = State {
        preserve_reviews,
        storage: storage::Storage::open(&home, &drafts)?,
        drafts,
        local_fonts: LocalFonts::new(engine.names.clone(), Limits::default().max_file_bytes),
        fonts: engine.names.clone(),
        engine: Mutex::new(engine),
        worker: fs::read_to_string(worker)?.into(),
        render_slot: Arc::new(Semaphore::new(1)),
        prepare_slot: Arc::new(Semaphore::new(1)),
    };
    Panache(Arc::new(state))
        .serve(rmcp::transport::stdio())
        .await?
        .waiting()
        .await?;
    Ok(())
}
