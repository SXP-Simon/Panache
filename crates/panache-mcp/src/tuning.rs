use crate::{Limits, State, Tune, controls, paper, reply};
use anyhow::{Context, Result, ensure};
use rmcp::model::CallToolResult;
use serde_json::json;
use std::fs;

pub fn apply(state: &State, mut input: Tune) -> Result<CallToolResult> {
    input.changes = controls::flatten_patch(input.changes)?;
    let mut draft = state
        .drafts
        .snapshot(&input.draft_id, Some(input.expected_revision))?;
    ensure!(
        input.note.as_ref().is_none_or(|s| s.chars().count() <= 320),
        "Note exceeds 320 characters"
    );
    let font = if let Some(path) = &input.font_path {
        use std::io::Read;
        let extension = path
            .extension()
            .and_then(|ext| ext.to_str())
            .unwrap_or_default();
        ensure!(
            path.is_absolute()
                && (extension.eq_ignore_ascii_case("ttf") || extension.eq_ignore_ascii_case("otf")),
            "Supply an absolute TTF or OTF path"
        );
        ensure!(
            !input.changes.contains_key("font"),
            "Choose font_path or font"
        );
        let file = fs::File::open(path)?;
        let limit = Limits::default().max_file_bytes;
        ensure!(
            file.metadata()?.is_file() && file.metadata()?.len() <= limit as u64,
            "Invalid font file or size"
        );
        let mut bytes = Vec::new();
        file.take(limit as u64 + 1).read_to_end(&mut bytes)?;
        ensure!(bytes.len() <= limit, "Font exceeds size limit");
        handwriting_core::FontBook::load(&bytes)?;
        let handle = format!(
            "upload:{}:{}",
            draft.revision + 1,
            path.file_name().unwrap_or_default().to_string_lossy()
        );
        Some((handle, bytes))
    } else if let Some(id) = input
        .changes
        .get("font")
        .and_then(|v| v.as_str())
        .filter(|id| !id.starts_with("upload:"))
    {
        state.import_catalog_font(id, draft.revision + 1)?
    } else {
        None
    };
    let mut patch = input.changes.clone();
    let mut fonts = state.fonts.clone();
    if let Some((handle, _)) = &font {
        patch.insert("font".into(), json!(handle));
        fonts.push(handle.clone());
    } else if let Some(handle) = patch
        .get("font")
        .and_then(|v| v.as_str())
        .filter(|s| s.starts_with("upload:"))
    {
        ensure!(draft.has_font(handle)?, "Unknown font for this draft");
        fonts.push(handle.to_owned());
    }
    let mut changes = if patch.is_empty() {
        draft.controls.clone()
    } else {
        controls::merge(&draft.controls, &patch, &fonts)?
    };
    let keys = &input.readback_variation;
    let before = if keys.is_empty() {
        None
    } else {
        ensure!(
            keys.len() <= 2
                && keys.iter().all(|k| input.changes.contains_key(k)
                    && controls::catalog()["variation"].get(k).is_some()),
            "readback_variation must name up to two variation controls in changes"
        );
        Some(serde_json::to_value(controls::parameters(
            &draft,
            1,
            &draft.controls,
        )?)?)
    };
    if let Some(guides) = &input.paper_guides {
        let paper = draft
            .paper
            .as_ref()
            .context("Import stationery before supplying guides")?;
        let [w, h] = paper.photo_size.unwrap_or([paper.width, paper.height]);
        draft.paper = if guides.is_empty() {
            state.drafts.snapshot(draft.id, Some(1))?.paper
        } else {
            Some(paper::PaperLayout::from_guides(w, h, guides)?)
        };
        for key in [
            "top_margin",
            "bottom_margin",
            "left_margin",
            "right_margin",
            "line_spacing",
        ] {
            if !input.changes.contains_key(key) {
                changes.remove(key);
            }
        }
    }
    if input.paper_guides.is_none() && changes == draft.controls {
        ensure!(
            !patch.is_empty(),
            "Supply controls, font_path or paper_guides"
        );
        draft.require_current_revision()?;
        let mut receipt = json!({"draft_id":draft.id,"revision":draft.revision,"changed":false,"paper":null,
            "controls":changes,"fine_layout":"preserved"});
        if !keys.is_empty() {
            receipt["effective_changes"] = json!({});
        }
        return Ok(reply(
            format!("Controls already match revision {}.", draft.revision),
            receipt,
        ));
    }
    let params = controls::parameters(&draft, 1, &changes)?;
    let mut delta = controls::Changes::new();
    if let Some(before) = before {
        let after = serde_json::to_value(&params)?;
        for k in keys {
            if before[k] != after[k] {
                delta.insert(k.clone(), json!({"before":before[k],"after":after[k]}));
            }
        }
    }
    let preserve_layout = changes.keys().chain(draft.controls.keys()).all(|key| {
        controls::catalog()["ink"].get(key).is_some()
            || controls::catalog()["camera"].get(key).is_some()
            || changes.get(key) == draft.controls.get(key)
    });
    let paper = input.paper_guides.as_ref().and(draft.paper.as_ref());
    let details = json!({"changes":input.changes,"font":font.as_ref().map(|(name,_)|name),"paper_guides":input.paper_guides,"note":input.note});
    let preserve_layout = preserve_layout && paper.is_none();
    if input.preserve_local_adjustments && !preserve_layout {
        draft.require_unadjusted_layout()?;
    }
    let _budget = font
        .as_ref()
        .map(|(_, bytes)| state.storage.import(bytes.len()))
        .transpose()?;
    let next = state.drafts.tune(
        &draft,
        &changes,
        preserve_layout,
        paper,
        font.as_ref().map(|(k, v)| (k.as_str(), v.as_slice())),
        &details,
    )?;
    let mut receipt = json!({"draft_id":draft.id,"revision":next,"changed":true,"paper":paper.map(|p|p.summary()),"controls":changes,"fine_layout":if preserve_layout { "preserved" } else { "inspect_again" }});
    if !keys.is_empty() {
        receipt["effective_changes"] = json!(delta);
    }
    Ok(reply(format!("Saved revision {next}."), receipt))
}
