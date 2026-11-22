use anyhow::{Context, Result, ensure};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use handwriting_core::{Limits, Parameters, imaging};
use serde::{Deserialize, Serialize};
use std::{fs::File, io::Read, path::Path};

#[derive(Serialize, Deserialize)]
pub struct PaperLayout {
    pub width: u32,
    pub height: u32,
    pub ruled: bool,
    pub line_spacing: f32,
    pub left: u32,
    pub right: u32,
    pub top: u32,
    pub bottom: u32,
}

impl PaperLayout {
    pub fn apply(&self, params: &mut Parameters) {
        params.width = None;
        params.height = None;
        params.background_ruled = self.ruled;
        params.line_spacing = self.line_spacing;
        if self.ruled && params.font_size >= self.line_spacing {
            params.font_size = (self.line_spacing * 0.72).round().max(1.);
        }
        params.left_margin = self.left as f32;
        params.right_margin = self.right as f32;
        params.top_margin = self.top as f32;
        params.bottom_margin = self.bottom as f32;
    }
}

pub struct ImportedPaper {
    pub layout: PaperLayout,
    pub bytes: Vec<u8>,
}

impl ImportedPaper {
    pub fn read(path: &Path, font_size: u8) -> Result<Self> {
        ensure!(
            path.is_absolute() && path.is_file(),
            "paper_path must be an absolute path to a local image file"
        );
        let limits = Limits::default();
        let file = File::open(path).context("Cannot open paper image")?;
        ensure!(
            file.metadata()?.len() <= limits.max_file_bytes as u64,
            "Paper image exceeds the file size limit"
        );
        let mut bytes = Vec::new();
        file.take(limits.max_file_bytes as u64 + 1)
            .read_to_end(&mut bytes)?;
        let image = imaging::decode(&bytes, &limits)?;
        let layout = match imaging::identify(&image) {
            Ok(lines) => {
                if let Some(corrected) = lines.corrected_background {
                    bytes = STANDARD.decode(corrected)?;
                    ensure!(
                        bytes.len() <= limits.max_file_bytes,
                        "Aligned paper exceeds the file size limit"
                    );
                }
                PaperLayout {
                    width: lines.image_width,
                    height: lines.image_height,
                    ruled: true,
                    line_spacing: lines.line_spacing as f32,
                    left: lines.margin_left,
                    right: lines.margin_right,
                    top: lines.layout_top_margin,
                    bottom: lines.layout_bottom_margin,
                }
            }
            Err(err) if err.code == "identification_unreliable" => PaperLayout {
                width: image.width(),
                height: image.height(),
                ruled: false,
                line_spacing: (f32::from(font_size) * 1.65).round(),
                left: image.width() / 12,
                right: image.width() / 12,
                top: image.height() / 18,
                bottom: image.height() / 18,
            },
            Err(err) => return Err(err.into()),
        };
        let mut params = Parameters {
            font_size: f32::from(font_size),
            ..Default::default()
        };
        layout.apply(&mut params);
        params.validate(layout.width, layout.height, &limits)?;
        Ok(Self { layout, bytes })
    }
}
