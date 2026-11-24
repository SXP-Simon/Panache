mod observations;
mod trajectory;
use anyhow::{Context, Result, ensure};
use rusqlite::{Connection, ErrorCode, OptionalExtension, TransactionBehavior, params};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use uuid::Uuid;

use crate::Style;
use crate::paper::{ImportedPaper, PaperLayout};

pub struct Drafts(PathBuf);

#[cfg(test)]
#[test]
fn concurrent_first_opens_share_a_complete_schema() -> Result<()> {
    let home = tempfile::tempdir()?;
    let ready = std::sync::Barrier::new(8);
    std::thread::scope(|s| -> Result<()> {
        let workers: Vec<_> = (0..8)
            .map(|_| {
                s.spawn(|| -> Result<()> {
                    ready.wait();
                    let drafts = Drafts::open(home.path())?;
                    let db = drafts.connect()?;
                    assert!(
                        db.table_exists(None, "drafts")?
                            && db.table_exists(None, "review_observations")?
                    );
                    assert_eq!(
                        db.pragma_query_value(None, "journal_mode", |r| r.get::<_, String>(0))?,
                        "wal"
                    );
                    Ok(())
                })
            })
            .collect();
        for worker in workers {
            worker.join().unwrap()?;
        }
        Ok(())
    })
}

pub struct Snapshot<'a> {
    pub revision: u32,
    pub style: Style,
    pub controls: crate::controls::Changes,
    pub settings_revision: u32,
    layout_revision: u32,
    pub id: &'a str,
    pub paper: Option<PaperLayout>,
    drafts: &'a Drafts,
}

impl Snapshot<'_> {
    pub fn page_error(&self, section: u32, mut error: handwriting_core::Error) -> anyhow::Error {
        if error.code != "invalid_page" {
            return error.into();
        }
        let next = self.drafts.connect().and_then(|db| {
            Ok(db.query_row(
                "SELECT MIN(number) FROM sections WHERE draft=? AND number>? AND revision<=?",
                params![self.id, section, self.revision],
                |row| row.get::<_, Option<u32>>(0),
            )?)
        });
        let hint = match next {
            Ok(Some(next)) => {
                format!("To continue after this section, use section={next}, page=1.")
            }
            Ok(None) => "This is the last section at this revision.".to_owned(),
            Err(_) => "Check the available sections before continuing.".to_owned(),
        };
        error.message = format!(
            "{} (revision {}, section {section}). Pages start at 1 within each section. {hint}",
            error.message, self.revision
        );
        error.into()
    }

    pub fn has_font(&self, handle: &str) -> Result<bool> {
        Ok(self.drafts.connect()?.query_row(
            "SELECT EXISTS(SELECT 1 FROM draft_fonts WHERE draft=? AND handle=?)",
            params![self.id, handle],
            |r| r.get(0),
        )?)
    }
    pub fn font_bytes(&self, handle: &str) -> Result<Vec<u8>> {
        Ok(self.drafts.connect()?.query_row(
            "SELECT bytes FROM draft_fonts WHERE draft=? AND handle=?",
            params![self.id, handle],
            |r| r.get(0),
        )?)
    }
    pub fn camera(&self, paper: Option<&[u8]>) -> Result<handwriting_core::export::CameraMetadata> {
        let input = serde_json::from_value(Value::Object(self.controls.clone()))?;
        Ok(handwriting_core::export::CameraMetadata::from_paper(
            paper, &input,
        )?)
    }

    pub fn edits(
        &self,
        section: &Section,
    ) -> Result<(u32, Option<handwriting_core::fine_edit::Adjustments>)> {
        let row:Option<(u32,String)>=self.drafts.connect()?.query_row(
            "SELECT revision,edits FROM glyph_edits WHERE draft=?1 AND section=?2 AND source_revision=?3 AND settings_revision=?4 AND revision<=?5 ORDER BY revision DESC LIMIT 1",
            params![self.id,section.number,section.version,self.layout_revision,self.revision],
            |r|Ok((r.get(0)?,r.get(1)?))).optional()?;
        match row {
            Some((rev, json)) => Ok((rev, Some(serde_json::from_str(&json)?))),
            None => Ok((0, None)),
        }
    }

    pub fn store_edits(
        &self,
        section: u32,
        version: u32,
        edits: &handwriting_core::fine_edit::Adjustments,
        details: &Value,
    ) -> Result<u32> {
        let mut db = self.drafts.connect()?;
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let next = Drafts::advance(&tx, self.id, self.revision)?;
        tx.execute(
            "INSERT INTO glyph_edits VALUES (?1,?2,?3,?4,?5,?6)",
            params![
                self.id,
                section,
                version,
                self.layout_revision,
                next,
                serde_json::to_string(edits)?
            ],
        )?;
        tx.execute(
            "INSERT INTO edit_notes VALUES(?,?,?)",
            params![self.id, next, details.to_string()],
        )?;
        tx.commit()?;
        Ok(next)
    }

    pub fn background(&self) -> Result<Option<Vec<u8>>> {
        if self.paper.is_none() {
            return Ok(None);
        }
        Ok(Some(self.drafts.connect()?.query_row(
            "SELECT image FROM papers WHERE draft=?1",
            [self.id],
            |r| r.get(0),
        )?))
    }
}

#[derive(Clone)]
pub struct Section {
    pub number: u32,
    pub version: u32,
    pub text: String,
}

impl Drafts {
    pub fn open(dir: &Path) -> Result<Self> {
        let drafts = Self(dir.join("drafts.sqlite3"));
        let mut db = drafts.connect()?;
        // Concurrent first opens can both hold read locks when SQLite upgrades to WAL.
        // SQLite may return BUSY immediately for this upgrade despite its busy timeout.
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            match db.pragma_update(None, "journal_mode", "WAL") {
                Err(err)
                    if matches!(
                        err.sqlite_error_code(),
                        Some(ErrorCode::DatabaseBusy | ErrorCode::DatabaseLocked)
                    ) && Instant::now() < deadline =>
                {
                    std::thread::sleep(Duration::from_millis(20))
                }
                result => {
                    result.context("Enable WAL for the draft database")?;
                    break;
                }
            }
        }
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        tx.execute_batch(
            "
            CREATE TABLE IF NOT EXISTS drafts (
                id TEXT PRIMARY KEY, title TEXT NOT NULL, style TEXT NOT NULL,
                revision INTEGER NOT NULL, chars INTEGER NOT NULL, sections INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS glyph_edits (
                draft TEXT NOT NULL REFERENCES drafts(id), section INTEGER NOT NULL,
                source_revision INTEGER NOT NULL, settings_revision INTEGER NOT NULL,
                revision INTEGER NOT NULL, edits TEXT NOT NULL,
                PRIMARY KEY(draft,section,source_revision,settings_revision,revision)
            );
            CREATE TABLE IF NOT EXISTS settings (
                draft TEXT NOT NULL REFERENCES drafts(id), revision INTEGER NOT NULL,
                controls TEXT NOT NULL, PRIMARY KEY(draft,revision)
            );
            CREATE TABLE IF NOT EXISTS camera_revisions (
                draft TEXT NOT NULL REFERENCES drafts(id), revision INTEGER NOT NULL,
                layout_revision INTEGER NOT NULL, PRIMARY KEY(draft, revision)
            );
            CREATE TABLE IF NOT EXISTS sections (
                draft TEXT NOT NULL REFERENCES drafts(id), number INTEGER NOT NULL,
                revision INTEGER NOT NULL, source TEXT NOT NULL, prepared TEXT NOT NULL,
                PRIMARY KEY(draft,number,revision)
            );
            CREATE TABLE IF NOT EXISTS paper_layouts (
                draft TEXT NOT NULL, revision INTEGER NOT NULL, layout TEXT NOT NULL,
                PRIMARY KEY(draft,revision)
            );
            CREATE TABLE IF NOT EXISTS draft_fonts (
                draft TEXT NOT NULL, handle TEXT NOT NULL, bytes BLOB NOT NULL,
                PRIMARY KEY(draft,handle)
            );
            CREATE TABLE IF NOT EXISTS edit_notes (
                draft TEXT NOT NULL, revision INTEGER NOT NULL, details TEXT NOT NULL,
                PRIMARY KEY(draft,revision)
            );
            CREATE TABLE IF NOT EXISTS papers (
                draft TEXT PRIMARY KEY REFERENCES drafts(id), layout TEXT NOT NULL, image BLOB NOT NULL
            );
        ",
        )?;
        tx.commit()?;
        observations::initialize(&mut db)?;
        Ok(drafts)
    }
    pub(crate) fn connect(&self) -> Result<Connection> {
        let db = Connection::open(&self.0)?;
        db.busy_timeout(Duration::from_secs(5))?;
        Ok(db)
    }
    pub fn save(
        &self,
        input: &crate::Save,
        prepared: &str,
        new_style: Option<&Style>,
        paper: Option<&ImportedPaper>,
        font: Option<&[u8]>,
    ) -> Result<Value> {
        let mut db = self.connect()?;
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let id = input
            .draft_id
            .clone()
            .unwrap_or_else(|| Uuid::new_v4().to_string());
        if let Some(style) = new_style {
            tx.execute(
                "INSERT INTO drafts VALUES (?1,?2,?3,0,0,0)",
                params![
                    id,
                    input.title.as_deref().unwrap_or("Untitled"),
                    serde_json::to_string(style)?
                ],
            )?;
            if let Some(bytes) = font {
                tx.execute(
                    "INSERT INTO draft_fonts VALUES(?,?,?)",
                    params![id, style.font, bytes],
                )?;
            }
            if let Some(paper) = paper {
                tx.execute(
                    "INSERT INTO papers (draft,layout,image) VALUES (?1,?2,?3)",
                    params![id, serde_json::to_string(&paper.layout)?, paper.bytes],
                )?;
            }
        }
        let (rev, chars, count): (u32, u32, u32) = tx
            .query_row(
                "SELECT revision,chars,sections FROM drafts WHERE id=?1",
                [&id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()?
            .context("Unknown draft")?;
        ensure!(
            rev == input.expected_revision.unwrap_or(0),
            "Draft is at revision {rev}. Review it before updating."
        );
        let number = input.section.unwrap_or(count + 1);
        ensure!(
            (1..=count + 1).contains(&number),
            "Choose an existing section or append the next one"
        );
        let limits = handwriting_core::Limits::default();
        ensure!(number as usize <= limits.max_pages, "Too many sections");
        let previous: u32 = tx.query_row(
            "SELECT length(prepared) FROM sections WHERE draft=?1 AND number=?2 ORDER BY revision DESC LIMIT 1",
            params![id, number], |r| r.get(0)).optional()?.unwrap_or(0);
        let total = chars - previous + u32::try_from(prepared.chars().count())?;
        ensure!(
            total as usize <= limits.max_text_chars,
            "Draft exceeds the engine text limit of {} characters",
            limits.max_text_chars
        );
        let next = rev + 1;
        tx.execute(
            "INSERT INTO sections VALUES (?1,?2,?3,?4,?5)",
            params![id, number, next, input.markdown, prepared],
        )?;
        tx.execute(
            "UPDATE drafts SET revision=?1,chars=?2,sections=?3 WHERE id=?4",
            params![next, total, number.max(count), id],
        )?;
        tx.commit()?;
        let mut saved = json!({"draft_id":id,"revision":next,"section":number,"sections":number.max(count),"prepared_chars":total});
        if let Some(paper) = paper {
            saved["paper"] = paper.layout.summary();
        }
        Ok(saved)
    }
    pub fn list(&self, offset: u32) -> Result<Value> {
        let db = self.connect()?;
        let mut stmt = db.prepare(
            "SELECT id,title,revision,sections FROM drafts ORDER BY rowid DESC LIMIT 20 OFFSET ?1",
        )?;
        let entries = stmt
            .query_map([offset], |r| {
                Ok(json!({
                    "draft_id":r.get::<_,String>(0)?, "title":r.get::<_,String>(1)?,
                    "revision":r.get::<_,u32>(2)?, "sections":r.get::<_,u32>(3)?
                }))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(json!({"drafts":entries,"offset":offset}))
    }
    pub fn snapshot<'a>(&'a self, id: &'a str, requested: Option<u32>) -> Result<Snapshot<'a>> {
        let (latest, style, layout): (u32, String, Option<String>) = self
            .connect()?
            .query_row("SELECT d.revision,d.style,p.layout FROM drafts d LEFT JOIN papers p ON p.draft=d.id WHERE d.id=?1", [id], |r| {
                Ok((r.get(0)?, r.get(1)?,r.get(2)?))
            })
            .optional()?
            .context("Unknown draft")?;
        let revision = requested.unwrap_or(latest);
        ensure!(
            (1..=latest).contains(&revision),
            "Unknown revision (latest: {latest})"
        );
        let settings: Option<(u32, u32, String)> = self
            .connect()?
            .query_row(
                "SELECT s.revision,COALESCE(c.layout_revision,s.revision),s.controls
             FROM settings s LEFT JOIN camera_revisions c USING(draft,revision)
             WHERE s.draft=?1 AND s.revision<=?2 ORDER BY s.revision DESC LIMIT 1",
                params![id, revision],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()?;
        let (settings_revision, layout_revision, controls) = match settings {
            Some((r, layout, s)) => (r, layout, serde_json::from_str(&s)?),
            None => (0, 0, crate::controls::Changes::new()),
        };
        let updated_layout: Option<String> = self.connect()?.query_row(
            "SELECT layout FROM paper_layouts WHERE draft=? AND revision<=? ORDER BY revision DESC LIMIT 1",
            params![id,revision], |r| r.get(0)).optional()?;
        Ok(Snapshot {
            controls,
            settings_revision,
            layout_revision,
            id,
            drafts: self,
            paper: updated_layout
                .or(layout)
                .as_deref()
                .map(serde_json::from_str)
                .transpose()?,
            revision,
            style: serde_json::from_str(&style)?,
        })
    }
    pub fn tune(
        &self,
        draft: &Snapshot<'_>,
        controls: &crate::controls::Changes,
        preserve_layout: bool,
        paper: Option<&PaperLayout>,
        font: Option<(&str, &[u8])>,
        details: &Value,
    ) -> Result<u32> {
        let mut db = self.connect()?;
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let next = Self::advance(&tx, draft.id, draft.revision)?;
        tx.execute(
            "INSERT INTO settings VALUES (?1,?2,?3)",
            params![draft.id, next, serde_json::to_string(controls)?],
        )?;
        if let Some(paper) = paper {
            tx.execute(
                "INSERT INTO paper_layouts VALUES(?,?,?)",
                params![draft.id, next, serde_json::to_string(paper)?],
            )?;
        }
        if let Some((handle, bytes)) = font {
            tx.execute(
                "INSERT INTO draft_fonts VALUES(?,?,?)",
                params![draft.id, handle, bytes],
            )?;
        }
        tx.execute(
            "INSERT INTO edit_notes VALUES(?,?,?)",
            params![draft.id, next, details.to_string()],
        )?;
        if preserve_layout {
            tx.execute(
                "INSERT INTO camera_revisions VALUES (?1,?2,?3)",
                params![draft.id, next, draft.layout_revision],
            )?;
        }
        tx.commit()?;
        Ok(next)
    }
    fn advance(tx: &rusqlite::Transaction<'_>, id: &str, expected: u32) -> Result<u32> {
        let next = expected.checked_add(1).context("Revision overflow")?;
        ensure!(
            tx.execute(
                "UPDATE drafts SET revision=?1 WHERE id=?2 AND revision=?3",
                params![next, id, expected]
            )? == 1,
            "Revision conflict; read the latest revision before retrying"
        );
        Ok(next)
    }
    pub fn review(
        &self,
        id: &str,
        rev: u32,
        number: u32,
        offset: u32,
        limit: u32,
        view: crate::ReadView,
    ) -> Result<Value> {
        ensure!(
            (1..=4000).contains(&limit),
            "limit must be 1..4000 characters"
        );
        let db = self.connect()?;
        let (source_len,version):(u32,u32)=db.query_row(
            "SELECT length(source),revision FROM sections WHERE draft=?1 AND number=?2 AND revision<=?3 ORDER BY revision DESC LIMIT 1",
            params![id,number,rev],|r|Ok((r.get(0)?,r.get(1)?))).optional()?.context("Section does not exist at this revision")?;
        let mut result = json!({"draft_id":id,"revision":rev,"section":number,"section_revision":version,"source_chars":source_len});
        if view == crate::ReadView::Summary {
            return Ok(result);
        }
        let (excerpt, len): (String, u32) = if view == crate::ReadView::Source {
            let slice=db.query_row("SELECT substr(source,?4+1,?5) FROM sections WHERE draft=?1 AND number=?2 AND revision=?3",
                params![id,number,version,offset,limit],|r|r.get(0))?;
            (slice, source_len)
        } else {
            let raw: String = db.query_row(
                "SELECT source FROM sections WHERE draft=?1 AND number=?2 AND revision=?3",
                params![id, number, version],
                |r| r.get(0),
            )?;
            let readable = handwriting_core::review_text(&raw);
            (
                readable
                    .chars()
                    .skip(offset as usize)
                    .take(limit as usize)
                    .collect(),
                readable.chars().count() as u32,
            )
        };
        result["markdown"] = json!(excerpt);
        result["offset"] = json!(offset);
        result["total_chars"] = json!(len);
        result["next_offset"] = json!(offset.checked_add(limit).filter(|n| *n < len));
        Ok(result)
    }
    pub fn sections(&self, id: &str, rev: u32, number: Option<u32>) -> Result<Vec<Section>> {
        let db = self.connect()?;
        let mut stmt = db.prepare("SELECT s.number,s.revision,s.prepared FROM sections s
            JOIN (SELECT number, MAX(revision) AS version FROM sections
              WHERE draft=?1 AND revision<=?2 AND (?3 IS NULL OR number=?3) GROUP BY number) latest
            ON latest.number=s.number AND latest.version=s.revision WHERE s.draft=?1 ORDER BY s.number")?;
        let sections = stmt
            .query_map(params![id, rev, number], |r| {
                Ok(Section {
                    number: r.get(0)?,
                    version: r.get(1)?,
                    text: r.get(2)?,
                })
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        ensure!(
            !sections.is_empty(),
            "Section does not exist at this revision"
        );
        Ok(sections)
    }
}
