use crate::{Panache, ReplaceText, Save, markdown, reply};
use anyhow::{Context, Result, ensure};
use handwriting_core::{Limits, text};
use rmcp::model::CallToolResult;

pub(super) async fn run(server: &Panache, input: ReplaceText) -> Result<CallToolResult> {
    validate_operand(&input.old_text)?;
    validate_operand(&input.new_text)?;
    ensure!(input.old_text != input.new_text, "Replacement is unchanged");
    ensure!(
        input.section > 0 && input.expected_revision > 0,
        "Use a saved draft, its current positive revision and an existing section"
    );
    let state = server.0.clone();
    let permit = state.prepare_slot.clone().acquire_owned().await?;
    let saved = tokio::task::spawn_blocking(move || {
        let _permit = permit;
        let (source, prepared) = state.drafts.plain_replacement_source(&input)?;
        let limits = Limits::default();
        ensure!(
            source.chars().count() <= limits.max_text_chars
                && prepared.chars().count() <= limits.max_text_chars,
            "Section too long"
        );
        let new_source = replace_standalone_line(&source, &input.old_text, &input.new_text)?;
        let raw_images = simple_document(&source)?;
        ensure!(
            new_source.chars().count() <= limits.max_text_chars,
            "Section too long"
        );
        let expected = replace_standalone_line(&prepared, &input.old_text, &input.new_text)
            .context("Cannot prove the same line in the prepared document")?;
        let updated = markdown::prepare(&state.worker, &new_source)?;
        handwriting_core::validate_document(&updated, &limits)?;
        ensure!(
            updated == expected
                && raw_images == images(text::parse(&prepared))
                && raw_images == images(text::parse(&updated)),
            "Cannot prove only the requested plain line changed"
        );
        let update = Save {
            paper_path: None,
            paper_mode: None,
            paper_guides: None,
            markdown: new_source,
            draft_id: Some(input.draft_id),
            expected_revision: Some(input.expected_revision),
            section: Some(input.section),
            title: None,
            style: None,
        };
        state.drafts.save_plain_replacement(&update, &updated)
    })
    .await??;
    Ok(reply(
        format!(
            "Replaced one plain-text paragraph in section {}; saved revision {}.",
            saved["section"], saved["revision"]
        ),
        saved,
    ))
}

fn plain_line(line: &str) -> bool {
    !line.is_empty()
        && !line.starts_with(' ')
        && !line.ends_with(' ')
        && line.chars().all(|c| c.is_alphanumeric() || c == ' ')
}

fn validate_operand(line: &str) -> Result<()> {
    ensure!(
        plain_line(line) && line.chars().count() <= 160,
        "Supply 1..160 letters, digits or interior spaces for a whole plain-text paragraph"
    );
    Ok(())
}

fn replace_standalone_line(document: &str, old: &str, new: &str) -> Result<String> {
    let first = document.find(old).context("No exact source match")?;
    let end = first + old.len();
    let step = old.chars().next().context("Empty search text")?.len_utf8();
    // Start just after the first scalar, so overlapped candidate spans still count.
    ensure!(
        !document[first + step..].contains(old),
        "Source match is ambiguous"
    );
    ensure!(
        (first == 0 || document.as_bytes()[first - 1] == b'\n')
            && (end == document.len() || document.as_bytes()[end] == b'\n'),
        "Match is not a whole plain-text line"
    );
    let mut output = String::with_capacity(document.len() - old.len() + new.len());
    output.push_str(&document[..first]);
    output.push_str(new);
    output.push_str(&document[end..]);
    Ok(output)
}

fn images(nodes: Vec<text::Node>) -> Vec<(String, String)> {
    nodes
        .into_iter()
        .filter_map(|n| match n {
            text::Node::Image { alt, data } => Some((alt, data)),
            _ => None,
        })
        .collect()
}

// This opt-in operation accepts only an intentionally small source grammar;
// it is not an alternate parser for arbitrary Markdown.
fn simple_document(source: &str) -> Result<Vec<(String, String)>> {
    let mut result = Vec::new();
    let mut previous = false;
    for line in source.split('\n') {
        if line.is_empty() {
            previous = false;
            continue;
        }
        ensure!(
            !previous,
            "Only standalone one-line paragraphs are supported"
        );
        previous = true;
        if plain_line(line) {
            continue;
        }
        ensure!(
            line.starts_with("!["),
            "Unsupported markup near the replacement"
        );
        let mut nodes = text::parse(line).into_iter();
        let Some(text::Node::Image { alt, data }) = nodes.next() else {
            anyhow::bail!("Only single-line embedded images are supported");
        };
        ensure!(
            nodes.next().is_none(),
            "Only single-line embedded images are supported"
        );
        ensure!(
            line == format!("![{alt}]({data})")
                && handwriting_core::review_text(line) == format!("![{alt}](attachment)"),
            "Only validated inline image data is supported"
        );
        result.push((alt, data));
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn source_spans_include_overlaps_and_keep_utf8() -> Result<()> {
        assert!(
            replace_standalone_line("aaa", "aa", "BB")
                .unwrap_err()
                .to_string()
                .contains("ambiguous")
        );
        assert!(replace_standalone_line("BEFORE old", "old", "new").is_err());
        assert_eq!(
            replace_standalone_line("开头\n\n秦风\n", "秦风", "秦雨")?,
            "开头\n\n秦雨\n"
        );
        Ok(())
    }

    #[test]
    fn only_standalone_prose_and_real_inline_data() {
        assert!(simple_document("Alpha\n\n![图](data:image/png;base64,AAAA)\n\nBeta").is_ok());
        for unsupported in [
            "Alpha\nBeta",
            "Alpha\n\n```\nBeta\n```",
            "Alpha\n\n![p](local.png)",
            "https://example.test\n\nBeta",
        ] {
            assert!(simple_document(unsupported).is_err(), "{unsupported}");
        }
    }
}
