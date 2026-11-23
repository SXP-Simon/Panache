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

#[derive(Clone, Copy, Deserialize, JsonSchema, Default)]
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
#[derive(Clone, Copy, Default, Deserialize, JsonSchema, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum PaperMode {
    #[default]
    Photo,
    Flatten,
}

#[derive(serde::Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Guide {
    /// Zero-based writable ruling number, counted from the first supplied ruling.
    pub row: u16,
    /// Left and right endpoints [x,y] of this same baseline in original photo pixels.
    pub left: [u32; 2],
    pub right: [u32; 2],
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Save {
    /// Optional absolute local image path for a new draft. Imports and aligns the paper once.
    /// Use with the default plain preset. All revisions share the saved image.
    pub paper_path: Option<std::path::PathBuf>,
    /// With paper_path: photo (default) preserves camera perspective; flatten aligns the background.
    pub paper_mode: Option<PaperMode>,
    /// Optional photo-space baselines overriding auto detection on import. Give 2..32 guides, first row 0, last row the last writable line; intermediate guides refine the fit.
    pub paper_guides: Option<Vec<Guide>>,
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
    /// Optionally include this draft's effective values for the selected group.
    pub draft_id: Option<String>,
    pub revision: Option<u32>,
    /// Omit for group names. Supply a group to get field names, units and ranges.
    pub group: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Tune {
    /// Replace the writing area on the saved paper, using 2..32 photo-space baselines. Pass [] to restore the original import calibration. Existing text is reflowed. Use the top and bottom writable lines even on unruled paper.
    pub paper_guides: Option<Vec<Guide>>,
    /// Import an absolute local TTF/OTF file into this draft. Its bytes are retained across restarts.
    pub font_path: Option<std::path::PathBuf>,
    /// Brief observable issue or user instruction that motivated this edit (max 320 characters).
    pub note: Option<String>,
    pub draft_id: String,
    pub expected_revision: u32,
    /// Sparse name/value patch from describe_controls. Null restores the original setting.
    #[serde(default)]
    pub changes: serde_json::Map<String, serde_json::Value>,
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct List {
    pub offset: Option<u32>,
}

#[derive(Clone, Copy, Default, Deserialize, JsonSchema, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum ReadView {
    Review,
    Trajectory,
    #[default]
    Excerpt,
    Summary,
    Source,
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Read {
    /// With view=review, retrieve one immutable measurement and its attributed feedback.
    pub review_id: Option<String>,
    /// Default excerpt omits inline image bytes; summary omits text; source reads exact Markdown.
    pub view: Option<ReadView>,
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
    Review,
    Paper,
    Image,
    Layout,
}

#[derive(serde::Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Shape {
    /// Horizontal shear in degrees, -20..20. Positive displaces the bottom to the right.
    pub shear_degrees: i8,
    /// Top edge width relative to bottom, 80..120 percent. 100 makes parallel sides.
    pub top_width_percent: u8,
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Nudge {
    /// Optional short user feedback or observable reason to retain with this revision.
    pub note: Option<String>,
    pub draft_id: String,
    pub expected_revision: u32,
    pub section: u32,
    pub page: usize,
    /// Up to 32 glyph IDs from preview_handwriting(view="layout") on this page.
    pub ids: Vec<u32>,
    /// Move this selection as a group so its mean glyph center lands at [x,y] on the preview. Use separately from dx, dy and shape.
    pub place_center: Option<[u32; 2]>,
    /// Image destinations of the original block's TL,TR,BR,BL corners, in that order (for a 90° counterclockwise sidebar: BL,TL,TR,BR of the field). Replaces prior geometry; use separately from other geometry changes.
    pub target_quad: Option<[[u32; 2]; 4]>,
    /// Absolute offsets in pixels from the original glyph position. Omitted fields retain their values.
    pub dx: Option<i32>,
    pub dy: Option<i32>,
    /// Percent of original size, 50..200.
    pub scale: Option<u8>,
    /// Clockwise rotation in degrees, -45..45 (engine coordinates).
    pub angle: Option<i8>,
    /// Ink opacity in percent, 0..100.
    pub opacity: Option<u8>,
    /// Stroke weight delta in pixels, -2..2, in 0.1 px steps.
    pub thickness: Option<f64>,
    /// Edge softness delta in pixels, -2..2, in 0.1 px steps.
    pub softness: Option<f64>,
    /// Local RGB ink, "#RRGGBB". Use "inherit" to restore the original ink.
    pub color: Option<String>,
    /// Optional residual glyph shape in paper space. Replaces prior shape; 0 degrees and 100 percent resets.
    pub shape: Option<Shape>,
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Preview {
    /// In review, compare with an earlier revision. Omit region for stored, data-only evidence (offset/limit paginate edits). With region, render paired crops.
    pub compare_revision: Option<u32>,
    /// 3..32 vertices in native output image pixels, origin top left. Layout selects glyph centers. Review measures the polygon and shows its bounding crop.
    pub region: Option<Vec<[i32; 2]>>,
    /// With review, region and compare_revision, mark the original position of moved content. The crop covers both polygons; differences outside their union cover the rest of the page.
    pub previous_region: Option<Vec<[i32; 2]>>,
    /// In layout view, only return illustration outlines and isolated details.
    pub illustrations_only: Option<bool>,
    /// "image" (default), "paper" for saved stationery, "layout" for glyph geometry, or "review" for appearance evidence.
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
    /// PDF includes the paper. ZIP contains page PNGs and respects the transparent_background ink control.
    pub format: Option<Format>,
}

#[derive(Deserialize, JsonSchema, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum FeedbackOrigin {
    UserQuote,
    ModelObservation,
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ReviewFeedback {
    pub draft_id: String,
    pub review_id: String,
    /// user_quote is reserved for the user's actual words; use model_observation for your interpretation.
    pub origin: FeedbackOrigin,
    /// Short, page-specific feedback, up to 320 characters.
    pub text: String,
}
