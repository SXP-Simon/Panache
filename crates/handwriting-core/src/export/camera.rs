//! Only copy camera and exposure tags from the paper, never its entire EXIF block.
use crate::{Error, Result};
use exif::{Field, In, Reader, Tag, Value, experimental::Writer};
use serde::{Deserialize, Serialize};
use std::io::{BufRead, Cursor, Seek};

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct CameraInput {
    pub camera_make: Option<String>,
    pub camera_model: Option<String>,
    pub camera_lens: Option<String>,
    pub camera_iso: Option<u16>,
}

impl CameraInput {
    pub fn validate(&self) -> Result<()> {
        for (name, value) in [
            ("camera_make", &self.camera_make),
            ("camera_model", &self.camera_model),
            ("camera_lens", &self.camera_lens),
        ] {
            if let Some(value) = value
                && !valid_label(value.as_bytes())
            {
                return Err(Error::new("invalid_parameter", name));
            }
        }
        if self.camera_iso == Some(0) {
            return Err(Error::new("invalid_parameter", "camera_iso"));
        }
        Ok(())
    }
}

fn valid_label(bytes: &[u8]) -> bool {
    (1..=96).contains(&bytes.len())
        && bytes.iter().all(|&b| (b' '..=b'~').contains(&b))
        && bytes.iter().any(|&b| b != b' ')
}

fn ascii(bytes: &[u8]) -> Value {
    Value::Ascii(vec![bytes.to_vec()])
}

#[derive(Default)]
pub struct CameraMetadata {
    pub(crate) exif: Vec<u8>,
    pub(crate) summary: String,
}

impl CameraMetadata {
    pub fn exif(&self) -> &[u8] {
        &self.exif
    }

    pub fn from_paper(paper: Option<&[u8]>, input: &CameraInput) -> Result<Self> {
        Self::from_reader(paper.map(Cursor::new), input)
    }

    pub fn from_reader<R: BufRead + Seek>(paper: Option<R>, input: &CameraInput) -> Result<Self> {
        input.validate()?;
        // WebP and PNG may carry EXIF after the pixels. Scan without decoding the image.
        let source =
            paper.and_then(|mut reader| Reader::new().read_from_container(&mut reader).ok());
        let mut fields = Vec::new();
        let mut supplied = Vec::new();
        let mut details = Vec::new();
        for (tag, label, fallback) in [
            (
                Tag::Make,
                "Make",
                input.camera_make.as_deref().map(|s| ascii(s.as_bytes())),
            ),
            (
                Tag::Model,
                "Model",
                input.camera_model.as_deref().map(|s| ascii(s.as_bytes())),
            ),
            (
                Tag::LensModel,
                "LensModel",
                input.camera_lens.as_deref().map(|s| ascii(s.as_bytes())),
            ),
            (
                Tag::PhotographicSensitivity,
                "ISO",
                input.camera_iso.map(|n| Value::Short(vec![n])),
            ),
            (Tag::FocalLength, "FocalLength", None),
            (Tag::FNumber, "FNumber", None),
            (Tag::ExposureTime, "ExposureTime", None),
        ] {
            let from_file = source
                .as_ref()
                .and_then(|exif| exif.get_field(tag, In::PRIMARY))
                .filter(|field| match (&field.value, tag) {
                    (Value::Ascii(v), Tag::Make | Tag::Model | Tag::LensModel) => {
                        matches!(v.as_slice(), [s] if valid_label(s))
                    }
                    (Value::Short(v), Tag::PhotographicSensitivity) => {
                        matches!(v.as_slice(), [n] if *n > 0)
                    }
                    (Value::Rational(v), Tag::FocalLength | Tag::FNumber | Tag::ExposureTime) => {
                        matches!(v.as_slice(), [r] if r.num > 0 && r.denom > 0)
                    }
                    _ => false,
                });
            let value = match (from_file, fallback) {
                (Some(f), _) => f.value.clone(),
                (None, Some(v)) => {
                    supplied.push(label);
                    v
                }
                _ => continue,
            };
            let field = Field {
                tag,
                ifd_num: In::PRIMARY,
                value,
            };
            details.push(format!("{label}={}", field.display_value().with_unit(())));
            fields.push(field);
        }
        if fields.is_empty() {
            return Ok(Self::default());
        }
        let mut description = String::from("Paper background camera information.");
        if !supplied.is_empty() {
            description.push_str(&format!(" User supplied: {}.", supplied.join(", ")));
        }
        for (tag, value) in [
            (Tag::Software, "Panache"),
            (Tag::ImageDescription, &description),
        ] {
            fields.push(Field {
                tag,
                ifd_num: In::PRIMARY,
                value: ascii(value.as_bytes()),
            });
        }
        let mut writer = Writer::new();
        for f in &fields {
            writer.push_field(f);
        }
        let mut data = Cursor::new(Vec::new());
        writer
            .write(&mut data, true)
            .map_err(|e| Error::new("encode_failed", e.to_string()))?;
        Ok(Self {
            exif: data.into_inner(),
            summary: format!("{description} {}", details.join(", ")),
        })
    }
}
