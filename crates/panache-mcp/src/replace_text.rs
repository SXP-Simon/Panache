use crate::{Panache, ReplaceText, Save, markdown, reply};
use anyhow::{Context, Result, ensure};
use handwriting_core::{Limits, text};
use rmcp::model::CallToolResult;

const RETRY_PLAIN: &str = "Nothing was saved. Retry replace_section_text with the same arguments plus retry_plain=true. The server will check the complete stored section and keep inline images verbatim.";
const KEEP_SOURCE: &str = "Nothing was saved. Leave the draft intact if the requested change or preservation of the remaining content cannot be verified.";

pub(super) async fn run(server: &Panache, input: ReplaceText) -> Result<CallToolResult> {
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
        validate_operand(&input.old_text, input.retry_plain)?;
        validate_operand(&input.new_text, input.retry_plain)?;
        let limits = Limits::default();
        ensure!(
            source.chars().count() <= limits.max_text_chars
                && prepared.chars().count() <= limits.max_text_chars,
            "Section too long"
        );
        let new_source = replace_standalone_line(&source, &input.old_text, &input.new_text)?;
        let raw_images = simple_document(&source, input.retry_plain)?;
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
            "Cannot prove only the requested plain line changed. {KEEP_SOURCE}"
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

fn plain_line(line: &str, with_punctuation: bool) -> bool {
    !line.is_empty()
        && !line.starts_with(' ')
        && !line.ends_with(' ')
        && line.chars().all(|c| {
            c.is_alphanumeric()
                || c == ' '
                || (with_punctuation && "，。！？；：、（）“”‘’,.!?;:()".contains(c))
        })
}

fn validate_operand(line: &str, retry: bool) -> Result<()> {
    let length = line.chars().count();
    ensure!(
        plain_line(line, true) && length <= Limits::default().max_text_chars,
        "Use a single plain-text paragraph. {KEEP_SOURCE}"
    );
    ensure!(
        retry || (length <= 160 && plain_line(line, false)),
        "{RETRY_PLAIN}"
    );
    Ok(())
}

fn replace_standalone_line(document: &str, old: &str, new: &str) -> Result<String> {
    let first = document.find(old).context("No exact source match. Read the specified source revision to locate the intended text before editing.")?;
    let end = first + old.len();
    let step = old.chars().next().context("Empty search text")?.len_utf8();
    // Start just after the first scalar, so overlapped candidate spans still count.
    ensure!(
        !document[first + step..].contains(old),
        "Source match is ambiguous. Leave the draft unchanged and ask which occurrence the user means if their request does not identify it."
    );
    ensure!(
        (first == 0 || document.as_bytes()[first - 1] == b'\n')
            && (end == document.len() || document.as_bytes()[end] == b'\n'),
        "Match is not a whole plain-text line. Read the source at this revision and identify the complete paragraph before retrying."
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
fn simple_document(source: &str, retry: bool) -> Result<Vec<(String, String)>> {
    let mut result = Vec::new();
    let mut previous = false;
    for line in source.split('\n') {
        if line.is_empty() {
            previous = false;
            continue;
        }
        ensure!(
            !previous,
            "Only standalone one-line paragraphs are supported. {KEEP_SOURCE}"
        );
        previous = true;
        if plain_line(line, true) {
            ensure!(
                retry || plain_line(line, false),
                "Unsupported markup in plain text. {RETRY_PLAIN}"
            );
            continue;
        }
        ensure!(
            line.starts_with("!["),
            "Unsupported markup near the replacement. {KEEP_SOURCE}"
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
        assert!(
            simple_document("Alpha\n\n![图](data:image/png;base64,AAAA)\n\nBeta", false).is_ok()
        );
        for unsupported in [
            "Alpha\nBeta",
            "Alpha\n\n```\nBeta\n```",
            "Alpha\n\n![p](local.png)",
            "https://example.test\n\nBeta",
        ] {
            assert!(simple_document(unsupported, true).is_err(), "{unsupported}");
        }
    }
}
