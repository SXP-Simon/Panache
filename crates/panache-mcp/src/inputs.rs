use anyhow::{Result, ensure};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Clone, Default, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Paper {
    #[default]
    Plain,
    Ruled,
    Grid,
    Dots,
}

#[derive(Deserialize, JsonSchema, Default)]
#[serde(rename_all = "snake_case")]
pub enum Format {
    #[default]
    Pdf,
    Zip,
}

#[derive(Clone, Serialize, Deserialize, JsonSchema)]
#[serde(default, deny_unknown_fields)]
pub struct Style {
    /// Exact filename from list_fonts.
    pub font: String,
    pub paper: Paper,
    /// RGB hex color, e.g. #302c30.
    pub ink: String,
    /// Pixels at the paper's native resolution (794 × 1123 for presets). Accepted range 16–72.
    pub font_size: u8,
    pub homework: bool,
    /// Keep this value to reproduce handwriting variations.
    pub seed: u32,
}
impl Default for Style {
    fn default() -> Self {
        Self {
            font: "霞鹜文楷.ttf".into(),
            paper: Paper::Plain,
            ink: "#302c30".into(),
            font_size: 34,
            homework: false,
            seed: u32::from_le_bytes(Uuid::new_v4().as_bytes()[..4].try_into().unwrap()),
        }
    }
}
impl Style {
    pub fn ink_rgba(&self) -> Result<[u8; 4]> {
        let hex = self.ink.strip_prefix('#').unwrap_or("");
        ensure!(
            hex.len() == 6 && hex.bytes().all(|b| b.is_ascii_hexdigit()),
            "ink must be #RRGGBB"
        );
        let rgb = u32::from_str_radix(hex, 16)?.to_be_bytes();
        Ok([rgb[1], rgb[2], rgb[3], 255])
    }
}
#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Save {
    /// Optional absolute local image path for a new draft. Imports and aligns the paper once.
    /// Use with the default plain preset. All revisions share the saved image.
    pub paper_path: Option<std::path::PathBuf>,
    /// Original Markdown of just this section. A new section starts on a fresh page.
    pub markdown: String,
    /// Omit to create a draft. Supply the returned ID to append or edit.
    pub draft_id: Option<String>,
    /// Required when updating an existing draft.
    pub expected_revision: Option<u32>,
    /// One-based. Omit to append.
    pub section: Option<u32>,
    /// Set only on creation.
    pub title: Option<String>,
    /// Set only on creation. Stored with the draft.
    pub style: Option<Style>,
}
#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Describe {
    /// Omit for group names. Supply a group to get field names, units and ranges.
    pub group: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Tune {
    pub draft_id: String,
    pub expected_revision: u32,
    /// Sparse name/value patch from describe_controls. Null restores the original setting.
    pub changes: std::collections::BTreeMap<String, serde_json::Value>,
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct List {
    pub offset: Option<u32>,
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Read {
    pub draft_id: String,
    /// Omit for latest.
    pub revision: Option<u32>,
    /// One-based. Defaults to the first section.
    pub section: Option<u32>,
    /// Unicode character offset.
    pub offset: Option<u32>,
    /// Defaults to 1000, maximum 4000 characters.
    pub limit: Option<u32>,
}
#[derive(Deserialize, JsonSchema, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum PreviewView {
    Image,
    Layout,
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Nudge {
    pub draft_id: String,
    pub expected_revision: u32,
    pub section: u32,
    pub page: usize,
    /// Up to 32 glyph IDs from preview_handwriting(view="layout") on this page.
    pub ids: Vec<u32>,
    /// Absolute offsets in pixels from the original glyph position. Omitted fields retain their values.
    pub dx: Option<i32>,
    pub dy: Option<i32>,
    /// Percent of original size, 50..200.
    pub scale: Option<u8>,
    /// Clockwise rotation in degrees, -45..45 (engine coordinates).
    pub angle: Option<i8>,
    /// Ink opacity in percent, 0..100.
    pub opacity: Option<u8>,
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Preview {
    /// "image" (default) or "layout" for bounded base glyph boxes without pixels.
    pub view: Option<PreviewView>,
    /// Layout mode: start index and number of glyphs (default 12, max 32).
    pub offset: Option<usize>,
    pub limit: Option<usize>,
    pub draft_id: String,
    pub revision: Option<u32>,
    /// Section number (one-based). Defaults to the first section.
    pub section: Option<u32>,
    /// Page within the section (one-based). Defaults to its first page.
    pub page: Option<usize>,
}
#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Export {
    pub draft_id: String,
    pub revision: Option<u32>,
    pub format: Option<Format>,
}
