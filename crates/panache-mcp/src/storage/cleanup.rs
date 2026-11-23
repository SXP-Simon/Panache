use super::*;
use rusqlite::{OptionalExtension, Row};
use std::{
    collections::{HashMap, HashSet},
    time::{Duration, Instant, SystemTime},
};

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct CleanupScope {
    /// Exact current draft. Other drafts are never included.
    pub draft_id: String,
    /// Continue the inventory after this returned ID.
    pub after_id: Option<String>,
}
#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ApplyCleanup {
    /// Short-lived plan from this MCP session.
    pub plan_id: String,
    /// Only abandoned_temp candidates in that plan may be selected.
    pub candidate_ids: Vec<String>,
}

struct Entry {
    id: String,
    draft: String,
    revision: u32,
    format: String,
    temp: String,
    identity: String,
    published: bool,
}

impl Entry {
    fn read(r: &Row<'_>) -> rusqlite::Result<Self> {
        Ok(Self {
            id: r.get(0)?,
            draft: r.get(1)?,
            revision: r.get(2)?,
            format: r.get(3)?,
            temp: r.get(4)?,
            identity: r.get(5)?,
            published: r.get(6)?,
        })
    }
    fn inspect(&mut self, store: &Storage) -> Result<Option<(PathBuf, Stamp)>> {
        ensure!(
            Uuid::parse_str(&self.id).is_ok() && matches!(self.format.as_str(), "pdf" | "zip"),
            "Invalid export registration"
        );
        let final_name = format!("panache-{}.{}", self.id, self.format);
        // Publication renames before SQLite is marked complete. After a crash the final
        // file stays protected, including when somebody later replaces that path.
        if !self.published && metadata(&store.exports.join(&final_name))?.is_some() {
            self.published = true;
        }
        let filename = if self.published {
            final_name
        } else {
            ensure!(
                self.temp.starts_with(".panache-")
                    && self.temp.ends_with(".part")
                    && self
                        .temp
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b'_')),
                "Invalid staging registration"
            );
            self.temp.clone()
        };
        let path = store.exports.join(filename);
        let Some(m) = metadata(&path)? else {
            return Ok(None);
        };
        if !m.is_file() || redirected(&m) || identity(&path)? != self.identity {
            return Ok(None);
        }
        Ok(Some((
            path,
            Stamp {
                bytes: m.len(),
                modified: m.modified()?,
                identity: self.identity.clone(),
            },
        )))
    }
}
const COLUMNS: &str =
    "SELECT id,draft,revision,format,temp_name,identity,published FROM export_files";
#[derive(Clone, PartialEq)]
struct Stamp {
    bytes: u64,
    modified: SystemTime,
    identity: String,
}
struct Plan {
    created: Instant,
    draft: String,
    items: HashMap<String, Stamp>,
}
#[derive(Default)]
pub(super) struct Plans {
    entries: HashMap<String, Plan>,
}

#[derive(Default)]
pub(super) struct Totals {
    pub temporary: u64,
    pub delivered: u64,
    pub scoped_temporary: u64,
    pub scoped_delivered: u64,
    pub busy: bool,
}
impl Storage {
    pub(super) fn cleanup_totals(&self, db: &Connection, draft: Option<&str>) -> Result<Totals> {
        let guard = self.lock_file()?;
        let busy = match guard.try_lock() {
            Ok(()) => false,
            Err(fs::TryLockError::WouldBlock) => true,
            Err(e) => return Err(e.into()),
        };
        let mut stmt = db.prepare(COLUMNS)?;
        let mut totals = Totals {
            busy,
            ..Default::default()
        };
        for row in stmt.query_map([], Entry::read)? {
            let mut entry = row?;
            if !entry.published && busy {
                continue;
            }
            if let Some((_, stamp)) = entry.inspect(self)? {
                let scoped = draft.is_none_or(|d| d == entry.draft);
                if entry.published {
                    totals.delivered += stamp.bytes;
                    if scoped {
                        totals.scoped_delivered += stamp.bytes
                    }
                } else {
                    totals.temporary += stamp.bytes;
                    if scoped {
                        totals.scoped_temporary += stamp.bytes
                    }
                }
            }
        }
        Ok(totals)
    }
    pub fn plan_cleanup(&self, drafts: &Drafts, input: CleanupScope) -> Result<Value> {
        drafts.snapshot(&input.draft_id, None)?;
        let _guard = self.write_lock()?;
        let db = drafts.connect()?;
        let mut stmt = db.prepare(&format!(
            "{COLUMNS} WHERE draft=?1 AND id>?2 ORDER BY id LIMIT 51"
        ))?;
        let mut rows = stmt.query_map(
            params![input.draft_id, input.after_id.unwrap_or_default()],
            Entry::read,
        )?;
        let mut listed = Vec::new();
        let mut items = HashMap::new();
        let mut last_id = String::new();
        for row in rows.by_ref().take(50) {
            let mut entry = row?;
            last_id.clone_from(&entry.id);
            let found = entry.inspect(self)?;
            let bytes = found.as_ref().map(|(_, s)| s.bytes);
            let name = found
                .as_ref()
                .and_then(|(p, _)| p.file_name())
                .and_then(|s| s.to_str());
            let class = match &found {
                None => "missing_or_identity_changed",
                Some(_) if entry.published => "delivered_report_only",
                Some(_) => "abandoned_temp",
            };
            listed.push(json!({"id":entry.id,"revision":entry.revision,"format":entry.format,"filename":name,"bytes":bytes,"class":class}));
            if let Some((_, stamp)) = found
                && !entry.published
            {
                items.insert(entry.id, stamp);
            }
        }
        let next = rows.next().transpose()?.map(|_| last_id);
        let eligible: u64 = items.values().map(|s| s.bytes).sum();
        let plan_id = if items.is_empty() {
            None
        } else {
            let mut plans = self
                .plans
                .lock()
                .map_err(|_| anyhow::anyhow!("Plans unavailable"))?;
            plans
                .entries
                .retain(|_, p| p.created.elapsed() < Duration::from_secs(300));
            if plans.entries.len() >= 32
                && let Some(old) = plans
                    .entries
                    .iter()
                    .min_by_key(|(_, p)| p.created)
                    .map(|(k, _)| k.clone())
            {
                plans.entries.remove(&old);
            }
            let id = Uuid::new_v4().to_string();
            plans.entries.insert(
                id.clone(),
                Plan {
                    draft: input.draft_id.clone(),
                    created: Instant::now(),
                    items,
                },
            );
            Some(id)
        };
        Ok(
            json!({"draft_id":input.draft_id,"plan_id":plan_id,"entries":listed,"eligible_temp_bytes":eligible,
            "next_after_id":next,"scope":"Only registered abandoned temporary files can be removed. Delivered files are report-only; unknown files are excluded. A plan expires after 300 seconds or server restart."}),
        )
    }

    pub fn apply_cleanup(&self, drafts: &Drafts, input: ApplyCleanup) -> Result<Value> {
        ensure!(
            (1..=50).contains(&input.candidate_ids.len()),
            "Choose 1..50 candidate IDs from one plan"
        );
        let _guard = self.write_lock()?;
        let plans = self
            .plans
            .lock()
            .map_err(|_| anyhow::anyhow!("Plans unavailable"))?;
        let plan = plans
            .entries
            .get(&input.plan_id)
            .context("Unknown plan; preview again")?;
        ensure!(
            plan.created.elapsed() < Duration::from_secs(300),
            "Plan expired; preview again"
        );
        let ids = input.candidate_ids.iter().collect::<HashSet<_>>();
        ensure!(
            ids.iter().all(|id| plan.items.contains_key(*id)),
            "Selection contains an ineligible ID"
        );
        let db = drafts.connect()?;
        let mut removed = Vec::new();
        let mut skipped = Vec::new();
        let mut bytes = 0;
        for id in ids {
            let entry = db
                .query_row(
                    &format!("{COLUMNS} WHERE id=? AND draft=? AND published=0"),
                    params![id, plan.draft],
                    Entry::read,
                )
                .optional()?;
            let candidate = if let Some(mut entry) = entry {
                let found = entry.inspect(self)?;
                if entry.published { None } else { found }
            } else {
                None
            };
            if let Some((path, stamp)) = candidate
                && plan.items[id] == stamp
            {
                match fs::remove_file(&path) {
                    Ok(()) => {
                        bytes += stamp.bytes;
                        removed.push(id);
                        db.execute("DELETE FROM export_files WHERE id=? AND published=0", [id])?;
                    }
                    Err(e) => skipped.push(json!({"id":id,"reason":e.kind().to_string()})),
                }
            } else {
                skipped.push(json!({"id":id,"reason":"missing_or_changed"}));
            }
        }
        Ok(json!({"removed_ids":removed,"removed_file_bytes":bytes,"skipped":skipped}))
    }
}
