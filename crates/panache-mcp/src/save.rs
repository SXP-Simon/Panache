use crate::{Panache, Paper, Save, State, Style, markdown, paper, reply};
use anyhow::{Result, ensure};
use handwriting_core::Limits;
use rmcp::model::CallToolResult;
use serde_json::{Value, json};

pub(super) async fn run(server: &Panache, input: Save) -> Result<CallToolResult> {
    let style = validate(&input, &server.0.fonts)?;
    let state = server.0.clone();
    let permit = state.prepare_slot.clone().acquire_owned().await?;
    let saved = tokio::task::spawn_blocking(move || {
        let _permit = permit;
        prepare_and_save(&state, &input, style)
    })
    .await??;
    Ok(saved_reply(saved))
}

fn validate(input: &Save, bundled: &[String]) -> Result<Option<Style>> {
    ensure!(
        !input.markdown.trim().is_empty() && !input.markdown.contains('\0'),
        "Supply nonempty Markdown without NUL characters"
    );
    ensure!(
        input.markdown.chars().count() <= Limits::default().max_text_chars,
        "Section too long"
    );
    ensure!(
        input.paper_path.is_some() || (input.paper_mode.is_none() && input.paper_guides.is_none()),
        "paper_mode and paper_guides require paper_path at creation"
    );
    if input.draft_id.is_none() {
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
        let style = input
            .style
            .as_ref()
            .map(|s| s.resolve(bundled))
            .unwrap_or_default();
        style.ink_rgba()?;
        ensure!(
            (16..=72).contains(&style.font_size),
            "font_size must be 16..72"
        );
        Ok(Some(style))
    } else {
        ensure!(
            input.title.is_none()
                && input.style.is_none()
                && input.paper_path.is_none()
                && input.expected_revision.is_some(),
            "An update needs expected_revision and uses the saved title, style and paper"
        );
        Ok(None)
    }
}

fn prepare_and_save(state: &State, input: &Save, mut style: Option<Style>) -> Result<Value> {
    let prepared = markdown::prepare(&state.worker, &input.markdown)?;
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
    let font = match &mut style {
        Some(style) => {
            let font = state.import_catalog_font(&style.font, 1)?;
            if let Some((handle, _)) = &font {
                style.font.clone_from(handle);
            }
            font
        }
        None => None,
    };
    let bytes = paper.as_ref().map_or(0, |p| p.bytes.len())
        + font.as_ref().map_or(0, |(_, data)| data.len());
    let _budget = (bytes > 0)
        .then(|| state.storage.import(bytes))
        .transpose()?;
    state.drafts.save(
        input,
        &prepared,
        style.as_ref(),
        paper.as_ref(),
        font.as_ref().map(|(_, bytes)| bytes.as_slice()),
    )
}

fn saved_reply(mut saved: Value) -> CallToolResult {
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
    reply(message, saved)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn illustration_pen_default_is_pinned_when_homework_is_created() -> Result<()> {
        for (args, enabled) in [
            (json!({}), false),
            (json!({"homework":true}), true),
            (
                json!({"homework":true,"illustration_uses_pen":false}),
                false,
            ),
            (json!({"illustration_uses_pen":true}), true),
        ] {
            let style: crate::CreationStyle = serde_json::from_value(args)?;
            assert_eq!(
                style.resolve(&[]).illustration_uses_pen.unwrap_or(false),
                enabled
            );
        }
        let archived: Style = serde_json::from_value(json!({"homework":true}))?;
        assert!(!archived.illustration_uses_pen.unwrap_or(false));
        Ok(())
    }

    #[test]
    fn homework_variation_is_saved_on_creation_and_respects_overrides() -> Result<()> {
        use crate::{controls, drafts::Drafts};
        let root = tempfile::tempdir()?;
        let drafts = Drafts::open(root.path())?;
        for (args, legacy, size, angle) in [
            (json!({"homework":true}), false, 1.5, 0.07),
            (
                json!({"homework":true,"relaxed_handwriting":false}),
                false,
                1.,
                0.05,
            ),
            (json!({"homework":true}), true, 1., 0.05),
            (json!({}), false, 1., 0.05),
        ] {
            let input: Save = serde_json::from_value(json!({"markdown":"作业","style":args}))?;
            let style = if legacy {
                // Archived styles predate the creation-time variation choice.
                serde_json::from_value(args)?
            } else {
                validate(&input, &[])?.unwrap()
            };
            let saved = drafts.save(&input, "作业", Some(&style), None, None)?;
            let draft = drafts.snapshot(saved["draft_id"].as_str().unwrap(), Some(1))?;
            let params = controls::parameters(&draft, 1, &draft.controls)?;
            assert_eq!(
                (params.font_size_sigma, params.perturb_theta_sigma),
                (size, angle)
            );
            let patch = serde_json::from_value(json!({"perturb_theta_sigma":0.0}))?;
            let tuned = controls::parameters(&draft, 1, &patch)?;
            assert_eq!(
                (tuned.font_size_sigma, tuned.perturb_theta_sigma),
                (size, 0.)
            );
        }
        Ok(())
    }

    #[test]
    fn homework_font_is_a_creation_default_on_any_paper() {
        let bundled = vec!["李国夫手写体.ttf".to_owned(), "霞鹜文楷.ttf".to_owned()];
        let font = |args: Value, fonts: &[String]| {
            let mut args = args;
            args["markdown"] = json!("试写");
            validate(&serde_json::from_value(args).unwrap(), fonts)
                .unwrap()
                .unwrap()
                .font
        };
        let homework = json!({"paper_path":"example.png","style":{"homework":true}});
        assert_eq!(font(homework.clone(), &bundled), bundled[0]);
        assert_eq!(font(homework.clone(), &bundled[1..]), bundled[1]);
        for assignment in [
            json!({"style":{"homework":true}}),
            json!({"style":{"homework":true,"paper":"ruled"}}),
            json!({"paper_path":"example.png","paper_mode":"flatten","style":{"homework":true}}),
        ] {
            assert_eq!(font(assignment, &bundled), bundled[0]);
        }
        for plain in [
            json!({}),
            json!({"paper_path":"example.png"}),
            json!({"paper_path":"example.png","style":{"homework":false}}),
        ] {
            assert_eq!(font(plain, &bundled), bundled[1]);
        }
        let mut explicit = homework;
        explicit["style"]["font"] = json!("霞鹜文楷.ttf");
        assert_eq!(font(explicit.clone(), &bundled), bundled[1]);
        explicit["style"]["font"] = json!("custom-font");
        assert_eq!(font(explicit.clone(), &bundled), "custom-font");
        explicit["markdown"] = json!("试写");
        explicit["style"]["font"] = Value::Null;
        assert!(serde_json::from_value::<Save>(explicit).is_err());
        assert!(
            serde_json::from_value::<Save>(json!({"markdown":"a","style":{"oops":true}})).is_err()
        );
    }
}
