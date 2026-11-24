use crate::{Error, Limits, Result};
use std::fmt::Display;
use std::io::{Cursor, Read};

mod word_xml;

pub fn extract(name: &str, bytes: &[u8], limits: &Limits) -> Result<String> {
    if bytes.len() > limits.max_file_bytes {
        return Err(Error::new("upload_limit", "文档文件过大"));
    }
    let ext = name.rsplit('.').next().unwrap_or("").to_ascii_lowercase();
    let text = match ext.as_str() {
        "txt" | "rtf" => String::from_utf8_lossy(bytes)
            .trim_start_matches('\u{feff}')
            .to_owned(),
        "docx" => docx(bytes, limits)?,
        "pdf" => pdf_extract::extract_text_from_mem(bytes).map_err(invalid_document)?,
        "doc" => {
            return Err(Error::new(
                "unsupported_document",
                "doc 暂不支持，请转换为 docx",
            ));
        }
        _ => return Err(Error::new("unsupported_document", "不支持的文档格式")),
    };
    if text.chars().count() > limits.max_text_chars {
        return Err(Error::new("text_limit", "提取文本过长"));
    }
    Ok(text)
}

fn invalid_document(error: impl Display) -> Error {
    Error::new("invalid_document", error.to_string())
}

fn docx(bytes: &[u8], limits: &Limits) -> Result<String> {
    let mut archive = zip::ZipArchive::new(Cursor::new(bytes)).map_err(invalid_document)?;
    if archive.len() > 4096 {
        return Err(Error::new("archive_limit", "DOCX 文件条目过多"));
    }
    let mut size = 0u64;
    for i in 0..archive.len() {
        size = size.saturating_add(archive.by_index(i).map_err(invalid_document)?.size());
    }
    if size > limits.max_archive_bytes {
        return Err(Error::new("archive_limit", "DOCX 解压大小超出限制"));
    }
    let entry = archive
        .by_name("word/document.xml")
        .map_err(invalid_document)?;
    let mut xml = Vec::new();
    entry
        .take(limits.max_archive_bytes + 1)
        .read_to_end(&mut xml)
        .map_err(invalid_document)?;
    if xml.len() as u64 > limits.max_archive_bytes {
        return Err(Error::new("archive_limit", "XML 过大"));
    }
    word_xml::extract(&xml, limits.max_text_chars)
}
