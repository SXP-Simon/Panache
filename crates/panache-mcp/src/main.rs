mod controls;
mod drafts;
mod engine;
mod inputs;
mod markdown;
mod paper;

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
    output: PathBuf,
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
        let saved = tokio::task::spawn_blocking({
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
                state
                    .drafts
                    .save(&input, &prepared, style.as_ref(), paper.as_ref())
            }
        })
        .await??;
        let message = format!(
            "已保存稿件 `{}` 的第 {} 节，当前版本 **{}**。",
            saved["draft_id"].as_str().unwrap_or_default(),
            saved["section"],
            saved["revision"]
        );
        Ok(reply(message, saved))
    }
}

#[tool_handler]
impl ServerHandler for Panache {
    fn get_info(&self) -> rmcp::model::ServerConfig {
        use rmcp::model::{Implementation, ServerCapabilities, ServerConfig};
        ServerConfig::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new("panache-mcp", handwriting_core::app_version()))
            .with_instructions("Drafts contain versioned Markdown sections. Images, the saved paper and per-glyph geometry are available on demand. Photo-space coordinates describe the preview; local adjustments use paper-space pixels.")
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
        description = "Tune a saved draft with a sparse control patch; returns a new revision. Preview that revision before export."
    )]
    fn tune_handwriting(&self, Parameters(input): Parameters<Tune>) -> CallToolResult {
        tool_result((|| {
            let draft = self
                .0
                .drafts
                .snapshot(&input.draft_id, Some(input.expected_revision))?;
            let changes = controls::merge(
                &draft.controls,
                &input.changes.into_iter().collect(),
                &self.0.fonts,
            )?;
            ensure!(changes != draft.controls, "No control values changed");
            controls::parameters(&draft, 1, &changes)?;
            let camera_only = changes.keys().chain(draft.controls.keys()).all(|key| {
                controls::catalog()["camera"].get(key).is_some()
                    || changes.get(key) == draft.controls.get(key)
            });
            let next = self.0.drafts.tune(&draft, &changes, camera_only)?;
            Ok(reply(
                format!("Saved revision {next}."),
                json!({"draft_id":draft.id,"revision":next,"controls":changes,"fine_layout":if camera_only { "preserved" } else { "inspect_again" }}),
            ))
        })())
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
        description = "Read one section: summary, excerpt (default, image data omitted), or exact source. Offset counts Unicode characters in the selected view."
    )]
    fn read_section(&self, Parameters(input): Parameters<Read>) -> CallToolResult {
        tool_result((|| {
            let draft = self.0.drafts.snapshot(&input.draft_id, input.revision)?;
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
        annotations(read_only_hint = true, open_world_hint = false),
        description = "Preview one page. Default image; view=layout returns base glyph boxes [x,y,width,height] in pixels, paginated with offset/limit, for adjust_glyphs. view=paper gives the saved background alone. Set illustrations_only=true in layout for editable diagram outlines and details. Projected layouts include base photo_quad (TL,TR,BR,BL) and photo_baseline in image pixels."
    )]
    async fn preview_handwriting(
        &self,
        Parameters(input): Parameters<Preview>,
        ctx: RequestContext<RoleServer>,
    ) -> CallToolResult {
        let result = self
            .render(ctx, move |state, engine, cancel| {
                let draft = state.drafts.snapshot(&input.draft_id, input.revision)?;
                ensure!(input.illustrations_only.is_none() || input.view==Some(PreviewView::Layout),"illustrations_only requires view=layout");
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
                if input.view == Some(PreviewView::Layout) {
                    let result = engine.layout(&draft, section, &input, cancel)?;
                    return Ok(reply(result.to_string(), result));
                }
                ensure!(
                    input.offset.is_none() && input.limit.is_none(),
                    "offset and limit require view=layout"
                );
                let (png, cached) = engine.preview(&draft, section, page, cancel)?;
                let mut result = reply(
                    format!("第 {number} 节 · 第 {page} 页 · 版本 {}", draft.revision),
                    json!({
                        "draft_id": input.draft_id, "revision": draft.revision,
                        "section": number, "page_in_section": page, "cached": cached
                    }),
                );
                result.content.push(ContentBlock::image(png, "image/png"));
                Ok(result)
            })
            .await;
        tool_result(result)
    }

    #[tool(
        description = "Adjust selected glyphs in one section/page by IDs from its layout view. Use the same revision. Offsets and shape are in paper space before sheet projection. Shape applies additional local shear or taper."
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
        description = "Export the complete saved revision, in section order, to a local PDF (default) or ZIP of page PNGs. Returns absolute path and actual page count."
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
            let (path, pages) = engine.export(
                &state.output, &draft, sections, input.format.unwrap_or_default(), cancel,
                |pages| {
                    if let Some(token) = &progress_token {
                        let update = rmcp::model::ProgressNotificationParam::new(token.clone(), pages as f64)
                            .with_message(format!("{pages} pages rendered"));
                        let _ = tokio::runtime::Handle::current().block_on(peer.notify_progress(update));
                    }
                },
            )?;
            let message = format!("已导出 **{pages} 页**（版本 {}）。\n\n`{}`", draft.revision, path.display());
            Ok(reply(message, json!({
                "draft_id": input.draft_id, "revision": draft.revision, "path": path, "pages": pages
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
    let state = State {
        drafts: Drafts::open(&home)?,
        fonts: engine.names.clone(),
        engine: Mutex::new(engine),
        output: std::path::absolute(output)?,
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
