//! Ownership and write budgets for the MCP data directory.
mod cleanup;
#[cfg(test)]
mod tests;
pub use cleanup::{ApplyCleanup, CleanupScope};

use crate::{Format, drafts::Drafts};
use anyhow::{Context, Result, ensure};
use rusqlite::{Connection, params};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    env,
    fs::{self, File, Metadata, OpenOptions},
    io::{self, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    sync::Mutex,
};
use tempfile::Builder;
use uuid::Uuid;

pub(crate) struct PublishedExport {
    pub id: String,
    pub path: PathBuf,
    pub pages: usize,
    pub file: File,
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Usage {
    /// Optional draft for logical payload counts. File and volume totals always cover this MCP home.
    pub draft_id: Option<String>,
}

#[derive(Default, Serialize)]
struct Policy {
    warn_bytes: Option<u64>,
    max_home_bytes: Option<u64>,
    min_free_bytes: Option<u64>,
}

fn setting(key: &str) -> Result<Option<u64>> {
    env::var_os(key)
        .map(|raw| {
            raw.to_str()
                .context("Invalid environment value")?
                .parse()
                .with_context(|| format!("{key} must be an unsigned byte count"))
        })
        .transpose()
}

pub struct Storage {
    home: PathBuf,
    exports: PathBuf,
    policy: Policy,
    plans: Mutex<cleanup::Plans>,
}

// Windows junctions can have directory type even though they redirect traversal.
fn redirected(meta: &Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        meta.file_attributes() & 0x400 != 0
    }
    #[cfg(not(windows))]
    {
        meta.is_symlink()
    }
}

fn metadata(path: &Path) -> io::Result<Option<Metadata>> {
    match fs::symlink_metadata(path) {
        Ok(m) => Ok(Some(m)),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e),
    }
}

fn directory_bytes(root: &Path) -> Result<u64> {
    let mut total = 0u64;
    let mut dirs = vec![root.to_owned()];
    while let Some(dir) = dirs.pop() {
        for entry in fs::read_dir(dir)? {
            let path = entry?.path();
            let Some(m) = metadata(&path)? else { continue };
            if redirected(&m) {
                continue;
            }
            if m.is_dir() {
                dirs.push(path)
            } else if m.is_file() {
                total = total.saturating_add(m.len())
            }
        }
    }
    Ok(total)
}

fn identity(path: &Path) -> Result<String> {
    use file_id::FileId::*;
    let id = match file_id::get_file_id(path)? {
        Inode {
            device_id,
            inode_number,
        } => format!("i:{device_id}:{inode_number}"),
        LowRes {
            volume_serial_number,
            file_index,
        } => format!("l:{volume_serial_number}:{file_index}"),
        HighRes {
            volume_serial_number,
            file_id,
        } => format!("h:{volume_serial_number}:{file_id}"),
    };
    let created = fs::symlink_metadata(path)?
        .created()
        .ok()
        .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_nanos());
    Ok(format!("{id}:{created:?}"))
}

impl Storage {
    pub fn open(home: &Path, db: &Drafts) -> Result<Self> {
        let home = home.canonicalize()?;
        let exports = home.join("exports");
        let store = Self {
            home,
            exports,
            policy: Policy {
                warn_bytes: setting("PANACHE_MCP_WARN_BYTES")?,
                max_home_bytes: setting("PANACHE_MCP_MAX_HOME_BYTES")?,
                min_free_bytes: setting("PANACHE_MCP_MIN_FREE_BYTES")?,
            },
            plans: Mutex::default(),
        };
        store.check_directory()?;
        store.lock_file()?;
        db.connect()?.execute_batch(
            "CREATE TABLE IF NOT EXISTS export_files(
            id TEXT PRIMARY KEY, draft TEXT NOT NULL, revision INTEGER NOT NULL,
            format TEXT NOT NULL, temp_name TEXT NOT NULL, identity TEXT NOT NULL,
            published INTEGER NOT NULL DEFAULT 0);
            CREATE INDEX IF NOT EXISTS exports_by_draft ON export_files(draft,id);",
        )?;
        Ok(store)
    }

    fn check_directory(&self) -> Result<()> {
        let m = fs::symlink_metadata(&self.exports)?;
        ensure!(
            m.is_dir() && !redirected(&m),
            "Expected a local exports directory"
        );
        Ok(())
    }

    fn lock_file(&self) -> Result<File> {
        let path = self.home.join(".large-writes.lock");
        if let Some(m) = metadata(&path)? {
            ensure!(m.is_file() && !redirected(&m), "Invalid storage lock");
        }
        Ok(OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(path)?)
    }

    pub fn write_lock(&self) -> Result<File> {
        self.check_directory()?;
        let lock = self.lock_file()?;
        lock.try_lock()
            .context("Storage busy: retry when the current import, export or cleanup ends")?;
        Ok(lock)
    }

    fn allowance(&self) -> Result<u64> {
        let mut remaining = u64::MAX;
        if let Some(cap) = self.policy.max_home_bytes {
            remaining = cap.saturating_sub(directory_bytes(&self.home)?);
        }
        if let Some(reserve) = self.policy.min_free_bytes {
            remaining = remaining.min(fs2::available_space(&self.home)?.saturating_sub(reserve));
        }
        Ok(remaining)
    }

    pub fn import(&self, bytes: usize) -> Result<File> {
        let guard = self.write_lock()?;
        let remaining = self.allowance()?;
        ensure!(
            bytes as u64 <= remaining,
            "Storage limit: {bytes} requested, {remaining} available for imports; inspect storage_usage and plan_cleanup"
        );
        Ok(guard)
    }

    pub fn export<F>(
        &self,
        drafts: &Drafts,
        draft: &str,
        revision: u32,
        format: Format,
        render: F,
    ) -> Result<PublishedExport>
    where
        F: FnOnce(&mut BudgetWriter<'_>) -> Result<usize>,
    {
        let _guard = self.write_lock()?;
        ensure!(
            self.allowance()? > 0,
            "Storage limit: no capacity for a new export; inspect storage_usage and plan_cleanup"
        );
        let db = drafts.connect()?;
        let id = Uuid::new_v4().to_string();
        let extension = match format {
            Format::Pdf => "pdf",
            Format::Zip => "zip",
        };
        let mut temp = Builder::new()
            .prefix(".panache-")
            .suffix(".part")
            .tempfile_in(&self.exports)?;
        let name = temp
            .path()
            .file_name()
            .and_then(|v| v.to_str())
            .context("Invalid staging name")?;
        db.execute("INSERT INTO export_files(id,draft,revision,format,temp_name,identity) VALUES(?,?,?,?,?,?)",
            params![id,draft,revision,extension,name,identity(temp.path())?])?;
        let path = self.exports.join(format!("panache-{id}.{extension}"));
        let publish = || -> Result<_> {
            let mut output = BudgetWriter {
                file: temp.as_file_mut(),
                limit: self.allowance()?,
                reserve: self.policy.min_free_bytes,
                volume: &self.home,
            };
            let pages = render(&mut output)?;
            output.flush()?;
            let file = temp.persist_noclobber(&path)?;
            db.execute("UPDATE export_files SET published=1 WHERE id=?", [&id])?;
            Ok((pages, file))
        };
        let result = publish();
        if result.is_err() && metadata(&path)?.is_none() {
            db.execute("DELETE FROM export_files WHERE id=? AND published=0", [&id])?;
        }
        result.map(|(pages, file)| PublishedExport {
            id,
            path,
            pages,
            file,
        })
    }

    pub fn usage(&self, drafts: &Drafts, input: Usage) -> Result<Value> {
        self.check_directory()?;
        if let Some(id) = &input.draft_id {
            drafts.snapshot(id, None)?;
        }
        let db = drafts.connect()?;
        let total = directory_bytes(&self.home)?;
        let export_bytes = directory_bytes(&self.exports)?;
        let mut database = serde_json::Map::new();
        for name in ["drafts.sqlite3", "drafts.sqlite3-wal", "drafts.sqlite3-shm"] {
            database.insert(
                name.into(),
                json!(
                    metadata(&self.home.join(name))?
                        .filter(|m| m.is_file() && !redirected(m))
                        .map_or(0, |m| m.len())
                ),
            );
        }
        let mut logical = serde_json::Map::new();
        for (label, table, bytes) in [
            ("fonts", "draft_fonts", "length(bytes)"),
            ("papers", "papers", "length(image)"),
            (
                "section_versions",
                "sections",
                "octet_length(source)+octet_length(prepared)",
            ),
            (
                "observations",
                "review_observations",
                "octet_length(evidence)",
            ),
            (
                "feedback",
                "review_feedback JOIN review_observations USING(review_id)",
                "octet_length(note)",
            ),
            ("glyph_edits", "glyph_edits", "octet_length(edits)"),
            ("edit_notes", "edit_notes", "octet_length(details)"),
        ] {
            let sql = format!(
                "SELECT count(*),coalesce(sum({bytes}),0) FROM {table} WHERE ?1 IS NULL OR draft=?1"
            );
            logical.insert(
                label.into(),
                db.query_row(&sql, [&input.draft_id], |r| {
                    Ok(json!({"count":r.get::<_,i64>(0)?,"payload_bytes":r.get::<_,i64>(1)?}))
                })?,
            );
        }
        let totals = self.cleanup_totals(&db, input.draft_id.as_deref())?;
        let free = fs2::available_space(&self.home)?;
        Ok(
            json!({"draft_id":input.draft_id,"home_file_bytes":total,"database_file_bytes":database,"export_directory_bytes":export_bytes,
            "available_disk_bytes":free,"policy":self.policy,"warning":self.policy.warn_bytes.is_some_and(|n|total>=n)
                || self.policy.max_home_bytes.is_some_and(|n|total>=n) || self.policy.min_free_bytes.is_some_and(|n|free<=n),
            "logical_payload":logical,"eligible_temp_bytes":totals.scoped_temporary,"delivered_bytes":totals.scoped_delivered,"writer_busy":totals.busy,
            "home_classes":{"abandoned_temp_bytes":totals.temporary,"delivered_report_only_bytes":totals.delivered,"protected_or_unclassified_bytes":total.saturating_sub(totals.temporary).saturating_sub(totals.delivered),"unclassified_export_bytes":export_bytes.saturating_sub(totals.temporary).saturating_sub(totals.delivered)},
            "scope":"Home totals count regular file lengths. Logical payload and registered file classes use the selected draft. Other files, database history and delivered outputs are protected from apply_cleanup."}),
        )
    }
}

pub struct BudgetWriter<'a> {
    file: &'a mut File,
    limit: u64,
    reserve: Option<u64>,
    volume: &'a Path,
}

impl Write for BudgetWriter<'_> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        if self.limit != u64::MAX || self.reserve.is_some() {
            let end = self
                .file
                .stream_position()?
                .saturating_add(buf.len() as u64);
            let growth = end.saturating_sub(self.file.metadata()?.len());
            if end > self.limit
                || (self.reserve.is_some()
                    && growth
                        > fs2::available_space(self.volume)?
                            .saturating_sub(self.reserve.unwrap_or_default()))
            {
                return Err(io::Error::other(format!(
                    "Storage limit: export requests end offset {end}, budget {}; inspect storage_usage and plan_cleanup",
                    self.limit
                )));
            }
        }
        self.file.write(buf)
    }
    fn flush(&mut self) -> io::Result<()> {
        self.file.flush()
    }
}

impl Seek for BudgetWriter<'_> {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        self.file.seek(pos)
    }
}
