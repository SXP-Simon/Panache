use crate::{Error, Result};
use image::{DynamicImage, ImageFormat, RgbaImage};
use pdf_writer::{Content, Filter, Finish, Name, Pdf, Rect, Ref};
use std::io::{Cursor, Seek, Write};
pub const PDF_JPEG_QUALITY: u8 = 75;
pub fn png(image: &RgbaImage) -> Result<Vec<u8>> {
    let mut out = Cursor::new(Vec::new());
    image
        .write_to(&mut out, ImageFormat::Png)
        .map_err(|e| Error::new("encode_failed", e.to_string()))?;
    Ok(out.into_inner())
}
pub struct PdfExport {
    pdf: Pdf,
    pages: Vec<Ref>,
}
impl Default for PdfExport {
    fn default() -> Self {
        Self::new()
    }
}
impl PdfExport {
    pub fn new() -> Self {
        Self {
            pdf: Pdf::new(),
            pages: Vec::new(),
        }
    }
    pub fn add(&mut self, image: &RgbaImage) -> Result<()> {
        let id = 3 + self.pages.len() as i32 * 3;
        let page_id = Ref::new(id);
        let image_id = Ref::new(id + 1);
        let content_id = Ref::new(id + 2);
        let (w, h) = (image.width() as f32, image.height() as f32);
        let rgb = DynamicImage::ImageRgba8(image.clone()).to_rgb8();
        let mut jpeg = Vec::new();
        image::codecs::jpeg::JpegEncoder::new_with_quality(&mut jpeg, PDF_JPEG_QUALITY)
            .encode_image(&rgb)
            .map_err(|e| Error::new("encode_failed", e.to_string()))?;
        let mut page = self.pdf.page(page_id);
        page.media_box(Rect::new(0., 0., w, h));
        page.parent(Ref::new(2));
        page.contents(content_id);
        page.resources().x_objects().pair(Name(b"Im"), image_id);
        page.finish();
        let mut img = self.pdf.image_xobject(image_id, &jpeg);
        img.filter(Filter::DctDecode);
        img.width(w as i32);
        img.height(h as i32);
        img.color_space().device_rgb();
        img.bits_per_component(8);
        img.finish();
        let mut content = Content::new();
        content.save_state();
        content.transform([w, 0., 0., h, 0., 0.]);
        content.x_object(Name(b"Im"));
        content.restore_state();
        self.pdf.stream(content_id, &content.finish());
        self.pages.push(page_id);
        Ok(())
    }
    pub fn finish(mut self) -> Vec<u8> {
        self.pdf.catalog(Ref::new(1)).pages(Ref::new(2));
        self.pdf
            .pages(Ref::new(2))
            .kids(self.pages.iter().copied())
            .count(self.pages.len() as i32);
        self.pdf.finish()
    }
}
pub struct ZipExport<W: Write + Seek> {
    zip: zip::ZipWriter<W>,
}
impl<W: Write + Seek> ZipExport<W> {
    pub fn new(writer: W) -> Self {
        Self {
            zip: zip::ZipWriter::new(writer),
        }
    }
    pub fn add(&mut self, index: usize, image: &RgbaImage) -> Result<()> {
        self.zip
            .start_file(
                format!("{index}.png"),
                zip::write::SimpleFileOptions::default()
                    .compression_method(zip::CompressionMethod::Stored),
            )
            .map_err(|e| Error::new("encode_failed", e.to_string()))?;
        self.zip
            .write_all(&png(image)?)
            .map_err(|e| Error::new("encode_failed", e.to_string()))
    }
    pub fn finish(self) -> Result<W> {
        self.zip
            .finish()
            .map_err(|e| Error::new("encode_failed", e.to_string()))
    }
}
