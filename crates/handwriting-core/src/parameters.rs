use crate::{Error, Result};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Debug, Clone)]
pub struct Limits {
    pub max_pixels: u64,
    pub max_text_chars: usize,
    pub max_pages: usize,
    pub max_file_bytes: usize,
    pub max_archive_bytes: u64,
}
impl Default for Limits {
    fn default() -> Self {
        Self {
            max_pixels: 16_000_000,
            max_text_chars: 100_000,
            max_pages: 200,
            max_file_bytes: 32 * 1024 * 1024,
            max_archive_bytes: 64 * 1024 * 1024,
        }
    }
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Parameters {
    pub font_size: f32,
    pub line_spacing: f32,
    pub word_spacing: f32,
    pub left_margin: f32,
    pub right_margin: f32,
    pub top_margin: f32,
    pub bottom_margin: f32,
    pub line_spacing_sigma: f32,
    pub font_size_sigma: f32,
    pub word_spacing_sigma: f32,
    pub perturb_x_sigma: f32,
    pub perturb_y_sigma: f32,
    pub perturb_theta_sigma: f32,
    pub strikethrough_probability: f32,
    pub strikethrough_length_sigma: f32,
    pub strikethrough_width_sigma: f32,
    pub strikethrough_angle_sigma: f32,
    pub strikethrough_width: f32,
    pub ink_depth_sigma: f32,
    pub fill: [u8; 4],
    pub underlined: bool,
    pub english_spacing: bool,
    pub grid_layout: bool,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub seed: u64,
    pub preview: bool,
    pub full_preview: bool,
    pub pdf_save: bool,
}
impl Default for Parameters {
    fn default() -> Self {
        Self {
            font_size: 124.,
            line_spacing: 200.,
            word_spacing: 1.,
            left_margin: 50.,
            right_margin: 50.,
            top_margin: 50.,
            bottom_margin: 50.,
            line_spacing_sigma: 0.,
            font_size_sigma: 2.,
            word_spacing_sigma: 2.,
            perturb_x_sigma: 3.,
            perturb_y_sigma: 3.,
            perturb_theta_sigma: 0.05,
            strikethrough_probability: 0.005,
            strikethrough_length_sigma: 2.,
            strikethrough_width_sigma: 2.,
            strikethrough_angle_sigma: 2.,
            strikethrough_width: 8.,
            ink_depth_sigma: 30.,
            fill: [0, 0, 0, 255],
            underlined: false,
            english_spacing: false,
            grid_layout: false,
            width: Some(2481),
            height: Some(3507),
            seed: 0,
            preview: true,
            full_preview: true,
            pdf_save: false,
        }
    }
}
impl Parameters {
    pub fn from_form(f: &HashMap<String, String>) -> Result<Self> {
        let mut p = Self::default();
        macro_rules! numbers { ($($key:ident),*) => { $(if let Some(v) = f.get(stringify!($key)) { p.$key = v.parse().map_err(|_| Error::new("invalid_parameter", stringify!($key)))?; })* }; }
        numbers!(
            font_size,
            line_spacing,
            word_spacing,
            left_margin,
            right_margin,
            top_margin,
            bottom_margin,
            line_spacing_sigma,
            font_size_sigma,
            word_spacing_sigma,
            perturb_x_sigma,
            perturb_y_sigma,
            perturb_theta_sigma,
            strikethrough_probability,
            strikethrough_length_sigma,
            strikethrough_width_sigma,
            strikethrough_angle_sigma,
            strikethrough_width,
            ink_depth_sigma,
            seed
        );
        fn boolean(f: &HashMap<String, String>, key: &str, default: bool) -> Result<bool> {
            match f.get(key).map(|v| v.to_ascii_lowercase()).as_deref() {
                None => Ok(default),
                Some("true") => Ok(true),
                Some("false") => Ok(false),
                _ => Err(Error::new("invalid_parameter", key)),
            }
        }
        p.underlined = boolean(f, "isUnderlined", false)?;
        p.english_spacing = boolean(f, "enableEnglishSpacing", false)?;
        p.grid_layout = boolean(f, "grid_layout", false)?;
        p.preview = boolean(f, "preview", true)?;
        p.full_preview = boolean(f, "full_preview", true)?;
        p.pdf_save = boolean(f, "pdf_save", false)?;
        p.width = f
            .get("width")
            .map(|s| s.parse::<u32>())
            .transpose()
            .map_err(|_| Error::new("invalid_parameter", "width"))?;
        p.height = f
            .get("height")
            .map(|s| s.parse::<u32>())
            .transpose()
            .map_err(|_| Error::new("invalid_parameter", "height"))?;
        if let Some(fill) = f.get("fill") {
            let values: Vec<u8> = fill
                .trim_matches(|c: char| c == '(' || c == ')' || c == '[' || c == ']')
                .split(',')
                .map(|s| s.trim().parse())
                .collect::<std::result::Result<_, _>>()
                .map_err(|_| Error::new("invalid_parameter", "fill"))?;
            match values.as_slice() {
                [v] => p.fill = [*v, *v, *v, 255],
                [r, g, b] => p.fill = [*r, *g, *b, 255],
                [r, g, b, a] => p.fill = [*r, *g, *b, *a],
                _ => return Err(Error::new("invalid_parameter", "fill")),
            }
        }
        Ok(p)
    }
    pub fn validate(&self, width: u32, height: u32, limits: &Limits) -> Result<()> {
        let nonnegative = [
            self.left_margin,
            self.right_margin,
            self.top_margin,
            self.bottom_margin,
            self.line_spacing_sigma,
            self.font_size_sigma,
            self.word_spacing_sigma,
            self.perturb_x_sigma,
            self.perturb_y_sigma,
            self.perturb_theta_sigma,
            self.strikethrough_probability,
            self.strikethrough_length_sigma,
            self.strikethrough_width_sigma,
            self.strikethrough_angle_sigma,
            self.strikethrough_width,
            self.ink_depth_sigma,
        ];
        if nonnegative
            .iter()
            .any(|v| !v.is_finite() || *v < 0. || *v > 10000.)
            || !self.word_spacing.is_finite()
            || !self.font_size.is_finite()
            || !self.line_spacing.is_finite()
            || self.font_size < 1.
            || self.font_size > 2048.
            || self.line_spacing < self.font_size
            || self.strikethrough_probability > 1.
            || self.word_spacing <= -self.font_size / 2.
        {
            return Err(Error::new("invalid_parameter", "参数超出范围"));
        }
        if width == 0 || height == 0 || u64::from(width) * u64::from(height) > limits.max_pixels {
            return Err(Error::new("image_limit", "图片尺寸超出限制"));
        }
        if self.left_margin + self.effective_right_margin() + self.font_size > width as f32
            || self.top_margin + self.bottom_margin + self.line_spacing > height as f32
        {
            return Err(Error::new("invalid_layout", "纸张无法容纳当前字号和边距"));
        }
        Ok(())
    }
    // 2026-10-12：保留 Python 入口对右边距的字距补偿。
    pub fn effective_right_margin(&self) -> f32 {
        self.right_margin - self.word_spacing * 2.
    }
}
