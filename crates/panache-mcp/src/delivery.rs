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
                "文件内容已传给客户端。请由客户端提供可打开的附件。",
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

#[cfg(test)]
mod tests {
    use super::*;

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
