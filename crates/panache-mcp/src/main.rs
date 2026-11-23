mod controls;
mod drafts;
mod engine;
mod inputs;
mod markdown;
mod paper;
mod placement;
mod review;
mod storage;
mod tuning;

use anyhow::{Context, Result, ensure};
use drafts::Drafts;
use engine::Engine;
use handwriting_core::{Cancellation, Limits};
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
    engine: Mutex<Engine>,
    fonts: Vec<String>,
    storage: storage::Storage,
    worker: Arc<str>,
    render_slot: Arc<Semaphore>,
    prepare_slot: Arc<Semaphore>,
}
#[derive(Clone)]
struct Panache(Arc<State>);

fn reply(message: String, metadata: serde_json::Value) -> CallToolResult {
    let mut result = CallToolResult::success(vec![ContentBlock::text(message)]);
    result.structured_content = Some(metadata);
    result
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
    async fn save(&self, input: Save) -> Result<CallToolResult> {
        ensure!(
            !input.markdown.trim().is_empty() && !input.markdown.contains('\0'),
            "Supply nonempty Markdown without NUL characters"
        );
        ensure!(
            input.markdown.chars().count() <= Limits::default().max_text_chars,
            "Section too long"
        );
        ensure!(
            input.paper_path.is_some()
                || (input.paper_mode.is_none() && input.paper_guides.is_none()),
            "paper_mode and paper_guides require paper_path at creation"
        );
        let style = if input.draft_id.is_none() {
            ensure!(
                input.expected_revision.unwrap_or(0) == 0 && input.section.unwrap_or(1) == 1,
                "A new draft starts at section 1"
            );
            ensure!(
                input
                    .title
                    .as_ref()
                    .is_none_or(|v| v.chars().count() <= 150),
                "Title too long"
            );
            let style = input.style.clone().unwrap_or_default();
            ensure!(
                self.0.fonts.contains(&style.font),
                "Unknown font. Use list_fonts to choose an installed font."
            );
            style.ink_rgba()?;
            ensure!(
                (16..=72).contains(&style.font_size),
                "font_size must be 16..72"
            );
            Some(style)
        } else {
            ensure!(
                input.title.is_none()
                    && input.style.is_none()
                    && input.paper_path.is_none()
                    && input.expected_revision.is_some(),
                "An update needs expected_revision and uses the saved title, style and paper"
            );
            None
        };
        let permit = self.0.prepare_slot.clone().acquire_owned().await?;
        let worker = self.0.worker.clone();
        let mut saved = tokio::task::spawn_blocking({
            let state = self.0.clone();
            move || -> Result<serde_json::Value> {
                let _permit = permit;
                let prepared = markdown::prepare(&worker, &input.markdown)?;
                ensure!(
                    !prepared.trim().is_empty(),
                    "Markdown produced no printable text"
                );
                handwriting_core::validate_document(&prepared, &Limits::default())?;
                let paper = match (&input.paper_path, &style) {
                    (Some(path), Some(style)) => {
                        ensure!(
                            matches!(style.paper, Paper::Plain),
                            "Choose either paper_path or a paper preset"
                        );
                        Some(paper::ImportedPaper::read(
                            path,
                            style.font_size,
                            input.paper_mode.unwrap_or_default(),
                            input.paper_guides.as_deref(),
                        )?)
                    }
                    _ => None,
                };
                let _budget = paper
                    .as_ref()
                    .map(|p| state.storage.import(p.bytes.len()))
                    .transpose()?;
                state
                    .drafts
                    .save(&input, &prepared, style.as_ref(), paper.as_ref())
            }
        })
        .await??;
        let mut message = format!(
            "已保存稿件 `{}` 的第 {} 节，当前版本 **{}**。",
            saved["draft_id"].as_str().unwrap_or_default(),
            saved["section"],
            saved["revision"]
        );
        if saved["paper"]["alignment"] == "unverified" {
            let hint = "未识别到可靠横线。无横线纸和画作均可继续使用。若落字位置不明确，先问用户想写在哪一侧、是否方便圈出区域，或哪些图案要留白。已有指定区域或用户已委托选位时，可直接按意图在本稿排版；用 tune_handwriting 的 paper_guides 定位，再用 preview_handwriting 的 review 视图复查。";
            saved["placement_guidance"] = json!(hint);
            message.push('\n');
            message.push_str(hint);
        }
        Ok(reply(message, saved))
    }
}

#[tool_handler]
impl ServerHandler for Panache {
    fn get_info(&self) -> rmcp::model::ServerConfig {
        use rmcp::model::{Implementation, ServerCapabilities, ServerConfig};
        ServerConfig::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new("panache-mcp", handwriting_core::app_version()))
            .with_instructions(concat!(
                "Start with save_section(markdown). Use its draft_id and revision for preview_handwriting or export_handwriting. ",
                "Use list_fonts for names and list_drafts to resume. A paper_path must be readable on the server computer. ",
                "For photos use preview_handwriting(view=review). Follow photo_appearance.preview_arguments for a native detail crop when available. ",
                "If images cannot reach the model, use the reported measurements and ask the user to inspect the page before judging its appearance. ",
                "Unruled paper and artwork are supported. If placement is unclear ask where to write or what to keep clear; follow specified or delegated choices. ",
                "Only suggest a clearer, flatter photo if visible blur, occlusion or perspective prevents the requested placement; identify the obstruction. ",
                "Photo coordinates use native output pixels; local dx/dy use paper-space pixels. ",
                "Review the edited revision. Use read_section(view=trajectory) to revisit actions and evidence."
            ))
    }
}

#[tool_router]
impl Panache {
    #[tool(
        annotations(read_only_hint = true, open_world_hint = false),
        description = "Discover handwriting settings by group. Omit group for an index; request one group before tuning."
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
        description = "Revise a draft: change controls, import a local font_path, or replace paper_guides on its saved image. Map the intended area onto first/last writable baselines even on artwork or unruled paper. Review the new revision before export."
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
        description = "List local font filenames accepted by save_section."
    )]
    fn list_fonts(&self) -> CallToolResult {
        let names = self
            .0
            .fonts
            .iter()
            .map(|name| format!("- {name}"))
            .collect::<Vec<_>>();
        reply(names.join("\n"), json!({"fonts": self.0.fonts}))
    }

    #[tool(
        description = "Save Markdown without rendering. For pen-matched flowcharts, use a circuitikz environment with \\draw[->] paths and node labels. On creation, optionally import a local stationery image with paper_path. Append or revise a section with expected_revision. Each section starts a new page. Keep the returned draft_id and revision. Returns detected paper.alignment."
    )]
    async fn save_section(&self, Parameters(input): Parameters<Save>) -> CallToolResult {
        tool_result(self.save(input).await)
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
        description = "Read view=review with review_id for exact stored evidence and its user quotes or model observations. Read view=trajectory for recent draft edits, user-provided edit notes and page review evidence (offset/limit count events). Other views read one section: summary, excerpt (default, image data omitted), or exact source. Offset counts Unicode characters in the selected view."
    )]
    fn read_section(&self, Parameters(input): Parameters<Read>) -> CallToolResult {
        tool_result((|| {
            let draft = self.0.drafts.snapshot(&input.draft_id, input.revision)?;
            if input.view == Some(ReadView::Review) {
                ensure!(
                    input.section.is_none() && input.offset.is_none() && input.limit.is_none(),
                    "Exact review lookup uses draft_id and review_id"
                );
                let data =
                    draft.observation(input.review_id.as_deref().context("Provide review_id")?)?;
                return Ok(reply(data.to_string(), data));
            }
            ensure!(input.review_id.is_none(), "review_id requires view=review");
            if input.view == Some(ReadView::Trajectory) {
                let result = self.0.drafts.trajectory(
                    draft.id,
                    draft.revision,
                    input.offset.unwrap_or(0),
                    input.limit.unwrap_or(12),
                )?;
                return Ok(reply(result.to_string(), result));
            }
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
        description = "view=review returns paper, finished appearance, overlay and full-page evidence. With compare_revision alone it reads stored data, review IDs, intervening edits and limitations. With region it renders labeled local crops in native image coordinates and measures visible changes; add compare_revision for paired before/after, and previous_region for the old location of moved content. Use a separate region to inspect protected content. view=layout returns glyph IDs and base boxes [x,y,width,height], paginated by offset/limit. Use region to select current glyph centers, illustrations_only for diagrams. Projected layouts include base photo_quad (TL,TR,BR,BL) and photo_baseline. view=paper returns the saved background."
    )]
    async fn preview_handwriting(
        &self,
        Parameters(input): Parameters<Preview>,
        ctx: RequestContext<RoleServer>,
    ) -> CallToolResult {
        if input.previous_region.is_some()
            && !(input.view == Some(PreviewView::Review)
                && input.region.is_some()
                && input.compare_revision.is_some())
        {
            return tool_result(Err(anyhow::anyhow!(
                "previous_region requires view=review, region and compare_revision"
            )));
        }
        if let Some(before) = input.compare_revision
            && input.region.is_none()
        {
            return tool_result((|| {
                ensure!(
                    input.view == Some(PreviewView::Review) && input.illustrations_only.is_none(),
                    "compare_revision requires an unfiltered review view"
                );
                let draft = self.0.drafts.snapshot(&input.draft_id, input.revision)?;
                let data = draft.compare_reviews(
                    before,
                    input.section.unwrap_or(1),
                    input.page.unwrap_or(1),
                    u32::try_from(input.offset.unwrap_or(0))?,
                    u32::try_from(input.limit.unwrap_or(20))?,
                )?;
                Ok(reply(data.to_string(), data))
            })());
        }
        let result = self
            .render(ctx, move |state, engine, cancel| {
                let draft = state.drafts.snapshot(&input.draft_id, input.revision)?;
                ensure!(input.illustrations_only.is_none() || input.view==Some(PreviewView::Layout),"illustrations_only requires view=layout");
                ensure!(input.region.is_none() || matches!(input.view, Some(PreviewView::Layout | PreviewView::Review)),"region requires view=layout or review");
                ensure!(input.compare_revision.is_none() || input.view==Some(PreviewView::Review),"compare_revision requires view=review");
                if input.view==Some(PreviewView::Paper){
                    ensure!(input.offset.is_none() && input.limit.is_none() && input.section.is_none() && input.page.is_none(),"view=paper takes only draft_id and revision");
                    let bytes=draft.background()?.context("No imported paper for this draft")?;
                    let img=handwriting_core::imaging::decode(&bytes,&Limits::default())?.into_rgba8();
                    use base64::{Engine as _,engine::general_purpose::STANDARD};
                    let mut result=reply("稿件底纸".into(),json!({"width":img.width(),"height":img.height(),"revision":draft.revision}));
                    result.content.push(ContentBlock::image(STANDARD.encode(draft.camera(Some(&bytes))?.png(&img)?),"image/png"));return Ok(result);
                }
                let number = input.section.unwrap_or(1);
                let section = state
                    .drafts
                    .sections(&input.draft_id, draft.revision, Some(number))?
                    .pop()
                    .context("Empty draft")?;
                let page = input.page.unwrap_or(1);
                if input.view == Some(PreviewView::Review) {
                    ensure!(input.limit.is_none() && input.offset.is_none(),"Review a single page without pagination");
                    if let Some(region) = &input.region {
                        return review::local::page(&state.drafts, engine, &draft, section, &input, region, cancel);
                    }
                    let baselines=engine.review_baselines(&draft,section.clone(),page,cancel)?;
                    let (preview,_)=engine.preview(&draft,section,page,cancel)?;
                    return review::page(&draft,number,page,&preview.png,&baselines,cancel);
                }
                if input.view == Some(PreviewView::Layout) {
                    let result = engine.layout(&draft, section, &input, cancel)?;
                    return Ok(reply(result.to_string(), result));
                }
                ensure!(
                    input.offset.is_none() && input.limit.is_none(),
                    "offset and limit require view=layout"
                );
                let (preview, cached) = engine.preview(&draft, section, page, cancel)?;
                let mut result = reply(
                    format!("第 {number} 节 · 第 {page} 页 · 版本 {}", draft.revision),
                    json!({
                        "draft_id": input.draft_id, "revision": draft.revision,
                        "section": number, "page_in_section": page, "cached": cached
                    }),
                );
                result.content.push(ContentBlock::image(preview.png, "image/png"));
                Ok(result)
            })
            .await;
        tool_result(result)
    }

    #[tool(
        description = "Attach a user's exact quote or your own model observation to a review_id. Does not advance the draft revision. Use read_section(view=review,review_id=...) to retrieve it."
    )]
    fn annotate_review(&self, Parameters(input): Parameters<ReviewFeedback>) -> CallToolResult {
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
        description = "Export the complete saved revision, in section order, to a local PDF (default) or ZIP of page PNGs. Returns a local file path and page count. For ink-only PNG pages, set transparent_background=true with tune_handwriting (ink group) and export ZIP. PDF always includes paper. Text-only clients can give the user the PDF path for visual inspection. Review the intended revision, especially after moving glyphs or changing ink."
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
            let (reviewed,visibility_flags)=draft.review_counts()?;
            let params=controls::parameters(&draft,1,&draft.controls)?;
            let zero_text_ink=params.ink_opacity==0 || params.fill[3]==0;
            let format = input.format.unwrap_or_default();
            let (path, pages) = state.storage.export(&state.drafts,draft.id,draft.revision,format, |writer| engine.export(
                writer, &draft, sections, format, cancel,
                |pages| {
                    if let Some(token) = &progress_token {
                        let update = rmcp::model::ProgressNotificationParam::new(token.clone(), pages as f64)
                            .with_message(format!("{pages} pages rendered"));
                        let _ = tokio::runtime::Handle::current().block_on(peer.notify_progress(update));
                    }
                },
            ))?;
            let warning=if zero_text_ink || visibility_flags>0 {"墨迹可见性需要复查。"}else if (reviewed as usize)<pages {"未复盘页的局部墨迹可见性尚未核验。"}else{""};
            let message = format!("已导出 **{pages} 页**（版本 {}）。该版已有 {reviewed}/{pages} 页复盘证据。{warning}可用 preview_handwriting(view=review) 核对成品。\n\n`{}`", draft.revision, path.display());
            Ok(reply(message, json!({
                "draft_id": input.draft_id, "revision": draft.revision, "path": path, "pages": pages, "review":{"pages_with_evidence":reviewed,"pages_with_visibility_flags":visibility_flags,"global_text_ink_zero":zero_text_ink,"pages_without_visibility_evidence":pages.saturating_sub(reviewed as usize)}
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
    let state = State {
        storage: storage::Storage::open(&home, &drafts)?,
        drafts,
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
