use super::invalid_document;
use crate::{Error, Result};
use quick_xml::{
    NsReader,
    escape::resolve_xml_entity,
    events::{BytesRef, BytesStart, Event},
    name::ResolveResult,
};

pub(super) fn extract(xml: &[u8], max_chars: usize) -> Result<String> {
    let mut reader = NsReader::from_reader(xml);
    let mut text = DocumentText {
        horizontal_span: 1,
        byte_budget: max_chars.saturating_mul(4),
        ..Default::default()
    };
    let mut depth = 0usize;
    loop {
        text.check_budget()?;
        let (namespace, event) = reader.read_resolved_event().map_err(invalid_document)?;
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
                if known {
                    text.start(e.local_name().as_ref());
                }
            }
            Event::Empty(e) if known => text.empty(&e),
            Event::Text(e) if text.text_depth > 0 => text
                .paragraph
                .push_str(&e.xml_content(quick_xml::XmlVersion::Implicit1_0)),
            Event::GeneralRef(e) if text.text_depth > 0 => text.push_entity(&e)?,
            Event::End(e) => {
                depth = depth.saturating_sub(1);
                if known {
                    text.end(e.local_name().as_ref())?;
                }
            }
            Event::DocType(_) => return Err(Error::new("invalid_document", "DOCX 不允许 DTD")),
            Event::Eof => break,
            _ => (),
        }
    }
    text.paragraphs.extend(text.rows);
    Ok(text.paragraphs.join("\n"))
}

#[derive(Default)]
struct DocumentText {
    paragraphs: Vec<String>,
    paragraph: String,
    text_depth: usize,
    table_depth: usize,
    rows: Vec<String>,
    previous_row: Vec<String>,
    cells: Vec<String>,
    cell: String,
    horizontal_span: usize,
    vertical_continue: bool,
    produced: usize,
    byte_budget: usize,
}

impl DocumentText {
    fn check_budget(&self) -> Result<()> {
        let bytes = self
            .produced
            .saturating_add(self.paragraph.len())
            .saturating_add(self.cell.len());
        if bytes > self.byte_budget {
            return Err(Error::new("text_limit", "提取文本过长"));
        }
        Ok(())
    }

    fn push_entity(&mut self, entity: &BytesRef<'_>) -> Result<()> {
        if let Some(c) = entity.resolve_char_ref().map_err(invalid_document)? {
            self.paragraph.push(c);
        } else {
            let value = resolve_xml_entity(entity)
                .ok_or_else(|| Error::new("invalid_document", "不支持 XML 实体"))?;
            self.paragraph.push_str(value);
        }
        Ok(())
    }

    fn start(&mut self, name: &str) {
        match name {
            "t" => self.text_depth += 1,
            "p" => self.paragraph.clear(),
            "tbl" => self.table_depth += 1,
            "tr" => self.cells.clear(),
            "tc" => {
                self.cell.clear();
                self.horizontal_span = 1;
                self.vertical_continue = false;
            }
            _ => (),
        }
    }

    fn empty(&mut self, element: &BytesStart<'_>) {
        match element.local_name().as_ref() {
            "tab" => self.paragraph.push('\t'),
            "br" | "cr" => self.paragraph.push('\n'),
            "gridSpan" => {
                for attr in element.attributes().flatten() {
                    if attr.key.local_name().as_ref() == "val" {
                        self.horizontal_span = attr.value.parse().unwrap_or(1).clamp(1, 1024);
                    }
                }
            }
            "vMerge" => {
                self.vertical_continue = !element.attributes().flatten().any(|attr| {
                    attr.key.local_name().as_ref() == "val" && attr.value.as_ref() == "restart"
                });
            }
            _ => (),
        }
    }

    fn end(&mut self, name: &str) -> Result<()> {
        match name {
            "t" => self.text_depth -= 1,
            "p" if self.table_depth == 0 => {
                self.produced = self.produced.saturating_add(self.paragraph.len() + 1);
                self.paragraphs.push(std::mem::take(&mut self.paragraph));
            }
            "p" => {
                self.cell.push_str(&self.paragraph);
                self.paragraph.clear();
            }
            "tc" => self.finish_cell()?,
            "tr" => {
                self.rows.push(self.cells.join("\t"));
                self.previous_row.clone_from(&self.cells);
            }
            "tbl" => self.table_depth -= 1,
            _ => (),
        }
        Ok(())
    }

    fn finish_cell(&mut self) -> Result<()> {
        let value = if self.vertical_continue {
            self.previous_row
                .get(self.cells.len())
                .cloned()
                .unwrap_or_default()
        } else {
            self.cell.trim().to_owned()
        };
        let added = value
            .len()
            .saturating_add(1)
            .saturating_mul(self.horizontal_span);
        let produced = self.produced.saturating_add(added);
        if produced > self.byte_budget {
            return Err(Error::new("text_limit", "表格文本过长"));
        }
        self.produced = produced;
        self.cells
            .extend(std::iter::repeat_n(value, self.horizontal_span));
        Ok(())
    }
}
