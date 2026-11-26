//! Searchable on-device font catalog shared by the desktop sidecar and the stdio MCP server.
use crate::{Error, FontBook, Result};
use fontdb::{Database, Source};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::HashSet,
    env, fs,
    io::{Read, Seek, SeekFrom},
    path::{Path, PathBuf},
    sync::Mutex,
};
use write_fonts::{FontBuilder, read::FontRef, types::Tag};

#[derive(
    Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, Serialize, Deserialize, JsonSchema,
)]
#[serde(rename_all = "snake_case")]
pub enum FontSource {
    Bundled,
    User,
    System,
}

#[derive(Clone, Serialize)]
pub struct FontEntry {
    pub id: String,
    pub name: String,
    pub filename: String,
    pub source: FontSource,
}

#[derive(Default, Deserialize, JsonSchema)]
#[serde(default, deny_unknown_fields)]
pub struct FontSearch {
    /// Case-insensitive substring of the face, localized family or filename.
    pub query: String,
    pub source: Option<FontSource>,
    pub offset: usize,
    /// Number of faces to return (default 20, maximum 100).
    pub limit: Option<usize>,
    /// Rescan after adding, removing or installing fonts.
    pub refresh: bool,
}

#[derive(Serialize)]
pub struct FontPage {
    pub fonts: Vec<FontEntry>,
    pub total: usize,
    pub next_offset: Option<usize>,
    pub user_dir: Option<PathBuf>,
}

struct Entry {
    info: FontEntry,
    keywords: String,
    face: Option<fontdb::ID>,
}

struct Index {
    db: Database,
    user_dir: std::result::Result<PathBuf, String>,
    entries: Vec<Entry>,
}

pub struct LocalFonts {
    bundled: Vec<String>,
    bundled_dir: Option<PathBuf>,
    user_dir: Option<PathBuf>,
    max_bytes: usize,
    index: Mutex<Option<Index>>,
}

fn user_dir() -> Option<PathBuf> {
    if let Some(path) = env::var_os("PANACHE_USER_FONT_DIR") {
        return Some(path.into());
    }
    let base = if cfg!(windows) {
        env::var_os("LOCALAPPDATA").map(PathBuf::from)
    } else if cfg!(target_os = "macos") {
        env::var_os("HOME").map(|v| PathBuf::from(v).join("Library/Application Support"))
    } else {
        env::var_os("XDG_DATA_HOME")
            .map(PathBuf::from)
            .or_else(|| env::var_os("HOME").map(|v| PathBuf::from(v).join(".local/share")))
    };
    base.map(|base| base.join("Panache/fonts"))
}

fn invalid(message: impl Into<String>) -> Error {
    Error::new("invalid_font", message)
}

// The render and workspace formats both expect face zero in one standalone font.
// Size the actual selected face before allocating, even for a very large CJK collection.
fn face_format(data: &[u8], index: u32, limit: usize) -> Option<(&'static str, bool)> {
    let font = FontRef::from_index(data, index).ok()?;
    let records = font.table_directory().table_records();
    let has = |tag: &[u8; 4]| records.iter().any(|r| r.tag() == Tag::new(tag));
    let ext = if has(b"glyf") {
        "ttf"
    } else if has(b"CFF ") || has(b"CFF2") {
        "otf"
    } else {
        return None;
    };
    let collection = data.starts_with(b"ttcf");
    let size = if collection {
        records.iter().try_fold(12 + 16 * records.len(), |n, r| {
            n.checked_add((r.length() as usize).checked_add(3)? & !3)
        })?
    } else {
        data.len()
    };
    (size <= limit).then_some((ext, collection))
}

fn display_name(data: &[u8], idx: u32) -> Option<String> {
    let face = ttf_parser::RawFace::parse(data, idx).ok()?;
    let names =
        ttf_parser::name::Table::parse(face.table(ttf_parser::Tag::from_bytes(b"name"))?)?.names;
    let mut english = None;
    let mut chinese = None;
    let mut first = None;
    for name in names
        .into_iter()
        .filter(|n| n.name_id == ttf_parser::name_id::FULL_NAME)
    {
        let Some(text) = name.to_string().filter(|s| !s.trim().is_empty()) else {
            continue;
        };
        match name.language() {
            ttf_parser::Language::Chinese_PeoplesRepublicOfChina => chinese = Some(text),
            ttf_parser::Language::English_UnitedStates => english = Some(text),
            _ => {
                first.get_or_insert(text);
            }
        }
    }
    match (chinese, english) {
        (Some(zh), Some(en)) if en != zh => Some(format!("{zh} ({en})")),
        (zh, en) => zh.or(en).or(first),
    }
}

// Bundled entries keep the filenames used by the renderer. Read only the directory
// and name table, not CJK outlines; unusual or unreadable files still match by filename.
fn bundled_families(path: &Path) -> Option<Vec<String>> {
    if !fs::symlink_metadata(path).ok()?.is_file() {
        return None;
    }
    let mut file = fs::File::open(path).ok()?;
    let mut header = Vec::new();
    (&mut file).take(4096).read_to_end(&mut header).ok()?;
    let face = ttf_parser::RawFace::parse(&header, 0).ok()?;
    let name = face
        .table_records
        .into_iter()
        .find(|r| r.tag == ttf_parser::Tag::from_bytes(b"name"))?;
    if name.length > 64 * 1024 {
        return None;
    }
    file.seek(SeekFrom::Start(u64::from(name.offset))).ok()?;
    let mut data = vec![0; name.length as usize];
    file.read_exact(&mut data).ok()?;
    let names = ttf_parser::name::Table::parse(&data)?.names;
    Some(
        names
            .into_iter()
            .filter(|n| {
                matches!(
                    n.name_id,
                    ttf_parser::name_id::FAMILY | ttf_parser::name_id::TYPOGRAPHIC_FAMILY
                ) && n.is_unicode()
                    && n.name.len() <= 512
            })
            .take(64)
            .filter_map(|n| n.to_string())
            .collect(),
    )
}

impl LocalFonts {
    pub fn new(bundled: Vec<String>, max_bytes: usize) -> Self {
        Self {
            bundled,
            bundled_dir: None,
            user_dir: user_dir(),
            max_bytes,
            index: Mutex::new(None),
        }
    }

    pub fn with_bundled_dir(mut self, dir: PathBuf) -> Self {
        self.bundled_dir = Some(dir);
        self
    }

    fn open_user_dir(&self) -> std::result::Result<PathBuf, String> {
        let dir = self
            .user_dir
            .as_deref()
            .ok_or("Set PANACHE_USER_FONT_DIR to a writable directory")?;
        if !dir.is_absolute() {
            return Err("PANACHE_USER_FONT_DIR must be an absolute directory".into());
        }
        fs::create_dir_all(dir)
            .and_then(|()| fs::read_dir(dir))
            .map_err(|e| format!("Cannot open personal font directory {}: {e}", dir.display()))?;
        Ok(dir.into())
    }

    fn scan(&self, system: impl FnOnce(&mut Database)) -> Index {
        let mut db = Database::new();
        let user_dir = self.open_user_dir();
        if let Ok(dir) = &user_dir {
            db.load_fonts_dir(dir);
        }
        let user_ids: HashSet<_> = db.faces().map(|f| f.id).collect();
        system(&mut db);
        let mut entries = self
            .bundled
            .iter()
            .map(|name| Entry {
                info: FontEntry {
                    id: name.clone(),
                    name: name.clone(),
                    filename: name.clone(),
                    source: FontSource::Bundled,
                },
                keywords: {
                    let mut keywords = name.to_lowercase();
                    if let Some(families) = self
                        .bundled_dir
                        .as_ref()
                        .and_then(|dir| bundled_families(&dir.join(name)))
                    {
                        for family in families {
                            keywords.push(' ');
                            keywords.push_str(&family.to_lowercase());
                        }
                    }
                    keywords
                },
                face: None,
            })
            .collect::<Vec<_>>();
        let mut seen = HashSet::new();
        for face in db.faces() {
            let Source::File(path) = &face.source else {
                continue;
            };
            let Some(((ext, collection), title)) = db
                .with_face_data(face.id, |data, idx| {
                    Some((
                        face_format(data, idx, self.max_bytes)?,
                        display_name(data, idx),
                    ))
                })
                .flatten()
            else {
                continue;
            };
            if !seen.insert((path, face.index)) {
                continue;
            }
            let user = user_ids.contains(&face.id);
            let source = if user {
                FontSource::User
            } else {
                FontSource::System
            };
            let prefix = if user { "user" } else { "system" };
            let hash = Sha256::new()
                .chain_update(path.as_os_str().as_encoded_bytes())
                .chain_update(face.index.to_be_bytes())
                .finalize();
            let digest = format!("{hash:x}");
            let id = format!("{prefix}:{}", &digest[..24]);
            let basename = path.file_name().unwrap_or_default().to_string_lossy();
            let family = face
                .families
                .iter()
                .map(|(name, _)| name.as_str())
                .collect::<Vec<_>>()
                .join(" ");
            let name = title.unwrap_or_else(|| face.post_script_name.clone());
            let filename = if collection {
                format!(
                    "{}-{}.{}",
                    path.file_stem().unwrap_or_default().to_string_lossy(),
                    face.index + 1,
                    ext
                )
            } else {
                basename.to_string()
            };
            entries.push(Entry {
                keywords: format!(
                    "{name} {family} {basename} {filename} {}",
                    face.post_script_name
                )
                .to_lowercase(),
                info: FontEntry {
                    id,
                    name,
                    filename,
                    source,
                },
                face: Some(face.id),
            });
        }
        entries.sort_by(|a, b| {
            (a.info.source, &a.info.name, &a.info.id).cmp(&(
                b.info.source,
                &b.info.name,
                &b.info.id,
            ))
        });
        Index {
            db,
            user_dir,
            entries,
        }
    }

    fn with_index<T>(&self, refresh: bool, visit: impl FnOnce(&Index) -> Result<T>) -> Result<T> {
        let mut cache = self
            .index
            .lock()
            .map_err(|_| invalid("Font catalog unavailable"))?;
        if cache.is_none() || refresh {
            *cache = Some(self.scan(Database::load_system_fonts));
        }
        visit(cache.as_ref().unwrap())
    }

    pub fn search(&self, search: &FontSearch) -> Result<FontPage> {
        let limit = search.limit.unwrap_or(20);
        if !(1..=100).contains(&limit) {
            return Err(invalid("Font search limit must be 1..100"));
        }
        let keyword = search.query.trim().to_lowercase();
        self.with_index(search.refresh, |index| {
            if search.source == Some(FontSource::User)
                && let Err(message) = &index.user_dir
            {
                return Err(invalid(message));
            }
            let mut fonts = Vec::new();
            let mut total = 0;
            for entry in &index.entries {
                if search.source.is_some_and(|s| s != entry.info.source)
                    || !entry.keywords.contains(&keyword)
                {
                    continue;
                }
                if total >= search.offset && fonts.len() < limit {
                    fonts.push(entry.info.clone());
                }
                total += 1;
            }
            let end = search.offset.saturating_add(fonts.len());
            Ok(FontPage {
                fonts,
                total,
                next_offset: (end < total).then_some(end),
                user_dir: index.user_dir.as_ref().ok().cloned(),
            })
        })
    }

    pub fn read(&self, id: &str) -> Result<(FontEntry, Vec<u8>)> {
        self.with_index(false, |index| {
            if id.starts_with("user:")
                && let Err(message) = &index.user_dir
            {
                return Err(invalid(message));
            }
            let entry = index
                .entries
                .iter()
                .find(|e| e.info.id == id)
                .ok_or_else(|| invalid("Unknown local font ID. Search or refresh the catalog."))?;
            let face = entry
                .face
                .ok_or_else(|| invalid("Choose a user or system font ID"))?;
            let bytes = index
                .db
                .with_face_data(face, |data, idx| {
                    let (_, collection) = face_format(data, idx, self.max_bytes)?;
                    if collection {
                        Some(
                            FontBuilder::new()
                                .copy_missing_tables(FontRef::from_index(data, idx).ok()?)
                                .build(),
                        )
                    } else {
                        Some(data.to_vec())
                    }
                })
                .flatten()
                .ok_or_else(|| invalid("Font is unavailable or exceeds the upload limit"))?;
            if bytes.len() > self.max_bytes {
                return Err(invalid("Font exceeds the upload limit"));
            }
            FontBook::load(&bytes)?;
            Ok((entry.info.clone(), bytes))
        })
    }
}

#[cfg(test)]
mod tests;
