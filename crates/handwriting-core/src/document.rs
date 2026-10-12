use crate::{Error, Limits, Result};
use quick_xml::{NsReader, events::Event, name::ResolveResult};
use std::io::{Cursor, Read};

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
        "pdf" => pdf_extract::extract_text_from_mem(bytes)
            .map_err(|e| Error::new("invalid_document", e.to_string()))?,
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
fn docx(bytes: &[u8], limits: &Limits) -> Result<String> {
    let mut archive = zip::ZipArchive::new(Cursor::new(bytes))
        .map_err(|e| Error::new("invalid_document", e.to_string()))?;
    if archive.len() > 4096 {
        return Err(Error::new("archive_limit", "DOCX 文件条目过多"));
    }
    let mut size = 0u64;
    for i in 0..archive.len() {
        size = size.saturating_add(
            archive
                .by_index(i)
                .map_err(|e| Error::new("invalid_document", e.to_string()))?
                .size(),
        );
    }
    if size > limits.max_archive_bytes {
        return Err(Error::new("archive_limit", "DOCX 解压大小超出限制"));
    }
    let entry = archive
        .by_name("word/document.xml")
        .map_err(|e| Error::new("invalid_document", e.to_string()))?;
    let mut xml = Vec::new();
    entry
        .take(limits.max_archive_bytes + 1)
        .read_to_end(&mut xml)
        .map_err(|e| Error::new("invalid_document", e.to_string()))?;
    if xml.len() as u64 > limits.max_archive_bytes {
        return Err(Error::new("archive_limit", "XML 过大"));
    }
    let mut reader = NsReader::from_reader(xml.as_slice());
    let mut paragraphs = Vec::new();
    let mut rows = Vec::new();
    let mut paragraph = String::new();
    let mut cell = String::new();
    let mut cells = Vec::new();
    let mut table_depth = 0;
    let mut text_depth = 0;
    let mut depth = 0usize;
    let mut horizontal_span = 1usize;
    let mut vertical_continue = false;
    let mut previous_row: Vec<String> = Vec::new();
    let byte_budget = limits.max_text_chars.saturating_mul(4);
    let mut produced = 0usize;
    loop {
        if produced
            .saturating_add(paragraph.len())
            .saturating_add(cell.len())
            > byte_budget
        {
            return Err(Error::new("text_limit", "提取文本过长"));
        }
        let (namespace, event) = reader
            .read_resolved_event()
            .map_err(|e| Error::new("invalid_document", e.to_string()))?;
        let known = matches!(namespace, ResolveResult::Bound(ns) if matches!(ns.as_ref(),
            "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
            | "http://schemas.openxmlformats.org/officeDocument/2006/math"
            | "http://purl.oclc.org/ooxml/wordprocessingml/main"
            | "http://purl.oclc.org/ooxml/officeDocument/math"));
        match event {
            Event::Start(e) => {
                depth += 1;
                if depth > 256 {
                    return Err(Error::new("archive_limit", "XML 嵌套过深"));
                }
                if !known {
                    continue;
                }
                match e.local_name().as_ref() {
                    "tbl" => table_depth += 1,
                    "p" => paragraph.clear(),
                    "tc" => {
                        cell.clear();
                        horizontal_span = 1;
                        vertical_continue = false;
                    }
                    "tr" => cells.clear(),
                    "t" => text_depth += 1,
                    _ => (),
                }
            }
            Event::Empty(e) if known => match e.local_name().as_ref() {
                "tab" => paragraph.push('\t'),
                "br" | "cr" => paragraph.push('\n'),
                "gridSpan" => {
                    for a in e.attributes().flatten() {
                        if a.key.local_name().as_ref() == "val" {
                            horizontal_span = a.value.parse().ok().unwrap_or(1).clamp(1, 1024);
                        }
                    }
                }
                "vMerge" => {
                    vertical_continue = !e.attributes().flatten().any(|a| {
                        a.key.local_name().as_ref() == "val" && a.value.as_ref() == "restart"
                    });
                }
                _ => (),
            },
            Event::Text(e) if text_depth > 0 => {
                paragraph.push_str(&e.xml_content(quick_xml::XmlVersion::Implicit1_0))
            }
            Event::GeneralRef(e) if text_depth > 0 => {
                if let Some(c) = e
                    .resolve_char_ref()
                    .map_err(|e| Error::new("invalid_document", e.to_string()))?
                {
                    paragraph.push(c);
                } else {
                    match e.as_ref() {
                        "amp" => paragraph.push('&'),
                        "lt" => paragraph.push('<'),
                        "gt" => paragraph.push('>'),
                        "quot" => paragraph.push('"'),
                        "apos" => paragraph.push('\''),
                        _ => return Err(Error::new("invalid_document", "不支持 XML 实体")),
                    }
                }
            }
            Event::End(e) => {
                depth = depth.saturating_sub(1);
                if !known {
                    continue;
                }
                match e.local_name().as_ref() {
                    "t" => text_depth -= 1,
                    "p" => {
                        if table_depth == 0 {
                            produced = produced.saturating_add(paragraph.len() + 1);
                            paragraphs.push(std::mem::take(&mut paragraph));
                        } else {
                            cell.push_str(&paragraph);
                            paragraph.clear();
                        }
                    }
                    "tc" => {
                        let value = if vertical_continue {
                            previous_row.get(cells.len()).cloned().unwrap_or_default()
                        } else {
                            cell.trim().to_string()
                        };
                        let added = value
                            .len()
                            .saturating_add(1)
                            .saturating_mul(horizontal_span);
                        if produced.saturating_add(added) > byte_budget {
                            return Err(Error::new("text_limit", "表格文本过长"));
                        }
                        produced = produced.saturating_add(added);
                        for _ in 0..horizontal_span {
                            cells.push(value.clone());
                        }
                    }
                    "tr" => {
                        rows.push(cells.join("\t"));
                        previous_row = cells.clone();
                    }
                    "tbl" => table_depth -= 1,
                    _ => (),
                }
            }
            Event::DocType(_) => return Err(Error::new("invalid_document", "DOCX 不允许 DTD")),
            Event::Eof => break,
            _ => (),
        }
    }
    paragraphs.extend(rows);
    Ok(paragraphs.join("\n"))
}
