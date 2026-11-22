use crate::{Guide, PaperMode};
use anyhow::{Context, Result, ensure};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use handwriting_core::photo::PaperProjection;
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub projection: Option<PaperProjection>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub guided: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub photo_size: Option<[u32; 2]>,
}

impl PaperLayout {
    pub fn summary(&self) -> serde_json::Value {
        let mut data = serde_json::json!({"width":self.width,"height":self.height,"ruled":self.ruled,"line_spacing":self.line_spacing,"left":self.left,"right":self.right,"top":self.top,"bottom":self.bottom});
        if let Some(map) = &self.projection {
            data["alignment"] = serde_json::json!(if self.guided {
                "manual_guides"
            } else {
                map.kind()
            });
            data["photo_size"] = serde_json::json!(self.photo_size);
        } else if !self.ruled {
            data["alignment"] = serde_json::json!("unverified");
        } else {
            data["alignment"] = serde_json::json!("stored_canvas");
        }
        data
    }
    fn from_guides(width: u32, height: u32, guides: &[Guide]) -> Result<Self> {
        ensure!(
            (2..=32).contains(&guides.len()) && guides[0].row == 0,
            "Supply 2..32 guides starting at row 0"
        );
        for g in guides {
            ensure!(
                g.row <= 512
                    && g.right[0] > g.left[0]
                    && [g.left, g.right]
                        .iter()
                        .all(|p| p[0] < width && p[1] < height),
                "Invalid guide coordinates or row number"
            );
        }
        let columns = std::array::from_fn(|i| i as f32 * (width - 1) as f32 / 8.);
        let line = |g: &Guide, x: f32| {
            g.left[1] as f32
                + (g.right[1] as f32 - g.left[1] as f32) * (x - g.left[0] as f32)
                    / (g.right[0] - g.left[0]) as f32
        };
        let center = width as f32 / 2.;
        let last = guides.last().unwrap();
        let first_y = line(&guides[0], center);
        let last_y = line(last, center);
        let step = (last_y - first_y) / f32::from(last.row);
        ensure!(
            step >= 1. && first_y >= step && last_y < height as f32,
            "Guides leave no room for the first or last line"
        );
        let left = guides[0].left[0];
        let right = guides[0].right[0];
        let mut rows = Vec::new();
        for pair in guides.windows(2) {
            let (a, b) = (&pair[0], &pair[1]);
            ensure!(
                b.row > a.row
                    && [0., width as f32 - 1.]
                        .into_iter()
                        .all(|x| line(b, x) > line(a, x)),
                "Guides must be ordered and may not cross within the image"
            );
            let wa = (a.right[0] - a.left[0]) as f32;
            let wb = (b.right[0] - b.left[0]) as f32;
            for idx in a.row..b.row {
                let t = f32::from(idx - a.row) / f32::from(b.row - a.row);
                // Equal distances on a plane divide a receding pair of edges projectively.
                let t = t * wa / ((1. - t) * wb + t * wa);
                let point = |u: f32, v: f32| u + (v - u) * t;
                rows.push(handwriting_core::photo::Ruling {
                    edges: [
                        point(a.left[0] as f32, b.left[0] as f32),
                        point(a.right[0] as f32, b.right[0] as f32),
                    ],
                    heights: columns.map(|x| point(line(a, x), line(b, x))),
                });
            }
        }
        rows.push(handwriting_core::photo::Ruling {
            edges: [last.left[0] as f32, last.right[0] as f32],
            heights: columns.map(|x| line(last, x)),
        });
        Ok(Self {
            width,
            height,
            ruled: true,
            line_spacing: step,
            left,
            right: width - right,
            top: (first_y - step).round() as u32,
            bottom: (height as f32 - last_y - step * 0.25).max(0.).round() as u32,
            projection: Some(PaperProjection::Rulings {
                first: first_y,
                step,
                layout_edges: [left as f32, right as f32],
                columns,
                rows,
            }),
            guided: true,
            photo_size: Some([width, height]),
        })
    }
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
    pub fn read(
        path: &Path,
        font_size: u8,
        mode: PaperMode,
        guides: Option<&[Guide]>,
    ) -> Result<Self> {
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
        let layout = if let Some(guides) = guides {
            ensure!(mode == PaperMode::Photo, "paper_guides require photo mode");
            PaperLayout::from_guides(image.width(), image.height(), guides)?
        } else {
            let detected = match mode {
                PaperMode::Photo => imaging::identify_photo(&image),
                PaperMode::Flatten => imaging::identify(&image),
            };
            match detected {
                Ok(mut lines) => {
                    if mode == PaperMode::Flatten {
                        if let Some(corrected) = lines.corrected_background.take() {
                            bytes = STANDARD.decode(corrected)?;
                            ensure!(
                                bytes.len() <= limits.max_file_bytes,
                                "Aligned paper exceeds the file size limit"
                            );
                        }
                        lines.projection = None;
                    }
                    PaperLayout {
                        photo_size: lines
                            .projection
                            .as_ref()
                            .map(|_| [image.width(), image.height()]),
                        guided: false,
                        projection: lines.projection,
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
                    guided: false,
                    projection: None,
                    photo_size: None,
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
            }
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
