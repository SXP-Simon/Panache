use crate::inputs::Format;
use base64::{Engine as _, engine::general_purpose::STANDARD};
use rmcp::model::{CallToolResult, ContentBlock, ResourceContents};
use serde_json::json;
use std::{
    fs::File,
    io::{self, Read, Seek},
    path::Path,
};

// Applied to the file before base64 expands it by about a third.
const MAX_FILE_BYTES: u64 = 512 * 1024;

fn file_bytes(mut file: File) -> io::Result<Option<Vec<u8>>> {
    if file.metadata()?.len() > MAX_FILE_BYTES {
        return Ok(None);
    }
    file.rewind()?;
    let mut bytes = Vec::new();
    file.take(MAX_FILE_BYTES + 1).read_to_end(&mut bytes)?;
    Ok((bytes.len() as u64 <= MAX_FILE_BYTES).then_some(bytes))
}

pub(super) fn include_file(result: &mut CallToolResult, file: File, path: &Path, format: Format) {
    // Keep the published handle. Reopening a pathname could read a replacement file.
    let (status, message) = match file_bytes(file) {
        Ok(Some(bytes)) => {
            let mime = match format {
                Format::Pdf => "application/pdf",
                Format::Zip => "application/zip",
            };
            let name = path.file_name().unwrap_or_default().to_string_lossy();
            let resource =
                ResourceContents::blob(STANDARD.encode(bytes), format!("panache-export:///{name}"))
                    .with_mime_type(mime);
            result.content.push(ContentBlock::resource(resource));
            (
                "included",
                "文件内容已写入工具回复。聊天客户端给出用户可用的下载链接时，在答复中原样贴出；只有聊天客户端确认附件已展示且未提供链接时，才请用户打开附件。没有这项确认时，请告知文件已导出，并用纯文本给出运行 Panache 的电脑上的取件路径。",
            )
        }
        Ok(None) => (
            "too_large",
            "文件已生成，超过随回复传送的 512 KiB。请从运行 Panache 的电脑取回。",
        ),
        Err(_) => (
            "unavailable",
            "文件已生成，但本次回复未能读取文件内容。请从运行 Panache 的电脑取回。",
        ),
    };
    result.content.push(ContentBlock::text(message));
    if let Some(metadata) = &mut result.structured_content {
        metadata["file_transfer"] = json!({"status": status, "max_bytes": MAX_FILE_BYTES});
    }
}

pub(super) fn append_experience_reflection(
    reply: &mut CallToolResult,
    draft: &str,
    revision: u32,
    export_id: &str,
    evidence: &[serde_json::Value],
    reviewed: usize,
) {
    let compared = evidence
        .iter()
        .any(|page| page["earlier_reference"].is_object());
    let guidance = if compared {
        "交付前请根据同页两版检查单复盘。先想清一件事：换掉本题的数字、文字和草稿编号后，修好这页的哪一个动作仍能帮助另一份作业？从修前实际可见的问题、修后实际变化写出适用条件与动作。调用 record_homework_experience，每个可独立验证的做法写一条，分别引用 earlier_reference 和 reference。等其他作业验证之前，候选不会指导新作业。若证据只能支持本题的具体答案或一次偶发修改，可以提交零条。在交付回复里简述本次记下的做法及待验证状态，或说明本题为何无需记经验。"
    } else if revision > 1 {
        "这次作业值得记下什么？若确实返工，先看修前和交付版同一位置的实际差异。可用 preview_handwriting(view=review, revision=交付版, compare_revision=修前版, section, page) 查两版检查单，加 region 可重看局部。缺哪一版整页单，就按明确版本查看；补看的旧版应注明是事后复核。若差异支持可复用做法，用 record_homework_experience 逐条引用两版证据。若没有可复用结论，可直接交付或传 rules=[]。"
    } else if evidence.is_empty() {
        "这次作业值得记下什么？这一版没有整页检查证据，可以直接交付，保留零条经验。"
    } else {
        "这次作业值得记下什么？顺利完成时可以直接交付，保留零条经验。若整页检查支持具体、可复用的做法，可用 record_homework_experience 各记一条，并分别引用该版检查单。"
    };
    let guidance = if revision > 1 || !evidence.is_empty() {
        format!(
            "{guidance} 提案尽量沿用建稿时的主题标签，只选适用所必需的词，把具体条件写进 scope。"
        )
    } else {
        guidance.to_owned()
    };
    let mut result = json!({"guidance":guidance,"reviewed_pages":reviewed,"page_reviews":evidence});
    if !evidence.is_empty() {
        result["tool"] = json!("record_homework_experience");
        result["delivery"] = json!({"draft_id":draft,"revision":revision,"export_id":export_id});
    }
    let message = if compared {
        format!(
            "{guidance}\n{}",
            json!({"draft_id":draft,"revision":revision,"export_id":export_id,"page_reviews":evidence})
        )
    } else {
        guidance
    };
    reply.content.push(ContentBlock::text(message));
    reply.structured_content.as_mut().unwrap()["experience_reflection"] = result;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reflection_offers_evidence_for_distinct_rules_and_allows_zero() {
        let mut reply = crate::reply("exported".into(), json!({}));
        append_experience_reflection(&mut reply, "doc", 1, "published", &[], 0);
        let none = &reply.structured_content.as_ref().unwrap()["experience_reflection"];
        assert!(none.get("tool").is_none());
        let samples =
            [json!({"section":1,"page":2,"reference":{"revision":3,"review_id":"verified"}})];
        append_experience_reflection(&mut reply, "doc", 3, "published", &samples, 1);
        let some = &reply.structured_content.as_ref().unwrap()["experience_reflection"];
        assert_eq!(some["page_reviews"], json!(samples));
        assert_eq!(
            some["delivery"],
            json!({"draft_id":"doc","revision":3,"export_id":"published"})
        );
        assert!(some.get("arguments").is_none());
        assert_eq!(some["tool"], "record_homework_experience");
    }

    #[test]
    fn revision_decision_follows_the_attachment_and_collection_path() -> io::Result<()> {
        let mut response = crate::reply("published path".into(), json!({"export_id":"published"}));
        let file = tempfile::tempfile()?;
        include_file(&mut response, file, Path::new("homework.pdf"), Format::Pdf);
        append_experience_reflection(&mut response, "doc", 4, "published", &[], 0);
        let metadata = response.structured_content.unwrap();
        assert_eq!(metadata["file_transfer"]["status"], "included");
        let guidance = metadata["experience_reflection"]["guidance"]
            .as_str()
            .unwrap();
        assert!(guidance.contains("compare_revision"));
        assert!(guidance.contains("事后复核"));
        let blocks = serde_json::to_value(&response.content)?;
        assert_eq!(blocks[1]["type"], "resource");
        assert!(blocks[2]["text"].as_str().unwrap().contains("取件路径"));
        assert_eq!(blocks[3]["text"], guidance);
        assert_eq!(blocks.as_array().unwrap().len(), 4);
        Ok(())
    }

    #[test]
    fn unreadable_bytes_preserve_export_receipt() -> io::Result<()> {
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("sample.pdf");
        let write_only = File::create(&path)?;
        let mut result = crate::reply("exported".into(), json!({"pages": 1}));
        include_file(&mut result, write_only, &path, Format::Pdf);
        assert_eq!(
            result.structured_content.as_ref().unwrap()["file_transfer"]["status"],
            "unavailable"
        );
        assert_eq!(result.structured_content.as_ref().unwrap()["pages"], 1);
        assert!(
            result
                .content
                .iter()
                .all(|block| matches!(block, ContentBlock::Text(_)))
        );
        assert!(path.is_file());
        Ok(())
    }

    #[test]
    fn attachment_size_boundary() -> io::Result<()> {
        for size in [MAX_FILE_BYTES, MAX_FILE_BYTES + 1] {
            let file = tempfile::tempfile()?;
            file.set_len(size)?;
            assert_eq!(
                file_bytes(file)?.map(|b| b.len() as u64),
                (size == MAX_FILE_BYTES).then_some(size)
            );
        }
        Ok(())
    }
}
