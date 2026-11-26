use anyhow::{Result, ensure};
use handwriting_core::local_fonts::FontSource;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Default, Deserialize, JsonSchema)]
#[serde(default, deny_unknown_fields)]
pub struct FontList {
    /// Case-insensitive substring of the face, localized family or filename.
    pub query: String,
    pub source: Option<FontSource>,
    pub offset: usize,
    /// Number of faces to return (default 20, maximum 100).
    pub limit: Option<usize>,
    /// Rescan after adding, removing or installing fonts.
    pub refresh: bool,
    /// Set false only to look up an already approved font or its ID when no new style choice is needed. Omit or set true for samples and style choices, even with an exact-name query.
    pub include_sample_guidance: Option<bool>,
}

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
    /// Main font ID from list_fonts. Bundled filenames remain valid. English letters and digits follow it by default.
    pub font: String,
    pub paper: Paper,
    /// RGB hex color, e.g. #302c30.
    pub ink: String,
    /// Pixels at the paper's native resolution (794 × 1123 for presets). Accepted range 16–72.
    pub font_size: u8,
    pub homework: bool,
    /// Keep this value to reproduce handwriting variations.
    #[schemars(transform = remove_seed_default)]
    pub seed: u32,
}
fn remove_seed_default(schema: &mut schemars::Schema) {
    schema.remove("default");
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
    /// Count writable baselines from row 0. At the image center, leave one full row interval above row 0; on a tight crop start at the next visible ruling.
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
pub struct ReplaceText {
    pub draft_id: String,
    pub expected_revision: u32,
    pub section: u32,
    /// Exact whole line (normally 1–160 characters). A second occurrence anywhere in the section source, even within another line, is ambiguous.
    pub old_text: String,
    /// Different whole line. Normally use 1–160 letters (including Han characters), digits or interior ASCII spaces.
    pub new_text: String,
    /// Set true on a suggested retry for a long line or ordinary punctuation. Uses stored source and preserves image data.
    #[serde(default)]
    pub retry_plain: bool,
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Describe {
    /// Pass with group to read this saved draft's effective values.
    pub draft_id: Option<String>,
    /// Requires draft_id and group. Omit to read the latest saved revision.
    pub revision: Option<u32>,
    /// Use {} to list group names, or group alone for its fields, units, ranges and choices.
    /// Use "layout" for line spacing and page geometry, not paper guide calibration.
    pub group: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Tune {
    /// Set to true only when the user wants to preserve manual glyph adjustments. Reject reflow that would stop applying them. Ink and camera changes can still be saved.
    #[serde(default)]
    pub preserve_local_adjustments: bool,
    /// Replace the writing area on the saved paper with 2..32 photo-space baselines. Use the top and bottom writable lines even on unruled paper. Pass [] to restore the original import calibration. Existing text is reflowed.
    /// Setting guides (including []) clears saved top_margin, bottom_margin, left_margin, right_margin, and text line_spacing unless those keys are included in changes in the same call.
    /// To keep specific overrides, resend only their approved saved values in changes; omit them to inherit from the paper. Restoring those numbers still reflows hand-placed text. If its placement must stay, also set preserve_local_adjustments=true. If refused, leave the draft as it is.
    pub paper_guides: Option<Vec<Guide>>,
    /// Import an absolute local TTF/OTF file into this draft. Its bytes are retained across restarts.
    pub font_path: Option<std::path::PathBuf>,
    /// Brief observable issue or user instruction that motivated this edit (max 320 characters).
    pub note: Option<String>,
    pub draft_id: String,
    /// Current revision returned by list_drafts or the last edit.
    pub expected_revision: u32,
    /// Pass controls under changes, e.g. {"perturb_theta_sigma":0.07}. Group objects from describe_controls also work inside changes. Null restores a control.
    #[serde(default)]
    pub changes: serde_json::Map<String, serde_json::Value>,
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct List {
    /// Rows to skip in creation order. Omit with before_draft_id. The response echoes this skip count (default 0).
    pub offset: Option<u32>,
    /// For the next page, pass the exact next_before_draft_id returned by list_drafts.
    pub before_draft_id: Option<String>,
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

#[derive(Clone, Copy, Deserialize, JsonSchema)]
#[serde(untagged)]
pub enum ReviewPage {
    Number(u32),
    Last(LastPage),
}

#[derive(Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum LastPage {
    Last,
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Read {
    /// With view=review, retrieve the most recently recorded full-page measurement at this one-based
    /// page, or "last" to paginate the selected section at the same revision. With "last" or before_text,
    /// specify the section containing the requested body in a multi-section draft. Omit review_id.
    pub page: Option<ReviewPage>,
    /// For a page review just before an addition: an exact, distinctive fragment of the added Markdown.
    /// Uses the revision immediately before its unique introduction; repeated introductions are ambiguous. Omit revision.
    pub before_text: Option<String>,
    /// With view=review, retrieve one immutable measurement and its attributed feedback by ID instead of page.
    pub review_id: Option<String>,
    /// With trajectory, pass next_cursor to continue the same snapshot, including its filters. Omit offset.
    pub cursor: Option<String>,
    /// With trajectory, return only annotations from this source.
    pub feedback_origin: Option<FeedbackOrigin>,
    /// Default excerpt omits inline image bytes; summary omits text; source reads exact Markdown.
    pub view: Option<ReadView>,
    pub draft_id: String,
    /// Omit for latest.
    pub revision: Option<u32>,
    /// One-based. In trajectory, select events attributed to this section; omit for the whole draft, including global edits. Text views default to section 1.
    pub section: Option<u32>,
    /// Trajectory: matching events to skip. Text views: Unicode characters to skip.
    pub offset: Option<u32>,
    /// Trajectory: 1..50 matching events (default 12). Text views: 1..4000 characters (default 1000).
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
    /// Use the revision returned by the layout that supplied these IDs. On conflict, read the latest layout and locate the intended text again.
    pub expected_revision: u32,
    pub section: u32,
    pub page: usize,
    /// Up to 32 glyph IDs from preview_handwriting(view="layout") on this page.
    pub ids: Vec<u32>,
    /// For a named text target, send its intended glyph text in ids order (one exact string per ID). A mismatch rejects the whole edit. For repeated text, use nearby words or position to select the occurrence.
    pub expected_texts: Option<Vec<String>>,
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
    /// For text glyphs, a local multiplier of the draft-wide ink opacity, 0..100 percent. 100 adds no fading, 0 hides the glyph. This cannot exceed the global opacity.
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
    /// In layout view, only return raster illustration outlines and isolated details. Omit for generated circuitikz: its labels and lines are one glyph.
    pub illustrations_only: Option<bool>,
    /// "image" (default), "paper" for saved stationery, "layout" for glyph geometry, or "review" for appearance evidence.
    pub view: Option<PreviewView>,
    /// For image (the default): render the page again instead of reusing its cached PNG,
    /// e.g. after replacing a configured font file. Does not change the draft or file a review.
    #[serde(default)]
    pub fresh: bool,
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

#[derive(Clone, Copy, Deserialize, JsonSchema, PartialEq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum FeedbackOrigin {
    UserQuote,
    ModelObservation,
}

impl FeedbackOrigin {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::UserQuote => "user_quote",
            Self::ModelObservation => "model_observation",
        }
    }
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

#[cfg(test)]
mod seed_schema_tests {
    use super::Style;
    use serde_json::{Value, json};

    #[test]
    fn seed_schema_omits_random_default_without_changing_deserialization() {
        let schemas: Vec<Value> = (0..4)
            .map(|_| serde_json::to_value(schemars::schema_for!(Style)).unwrap())
            .collect();
        assert!(schemas.windows(2).all(|pair| pair[0] == pair[1]));
        let schema = &schemas[0];
        let seed = &schema["properties"]["seed"];
        assert_eq!(seed["type"], "integer");
        assert!(seed.get("default").is_none());
        assert!(
            !schema["required"]
                .as_array()
                .is_some_and(|fields| fields.contains(&json!("seed")))
        );
        assert_eq!(schema["properties"]["font_size"]["default"], 34);

        let explicit: Style = serde_json::from_value(json!({"seed": 42})).unwrap();
        assert_eq!(explicit.seed, 42);
        assert_eq!(serde_json::to_value(&explicit).unwrap()["seed"], 42);
        let omitted: Style = serde_json::from_value(json!({})).unwrap();
        assert_eq!(omitted.font_size, 34);
    }
}
