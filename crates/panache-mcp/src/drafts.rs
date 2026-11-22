use anyhow::{Context, Result, ensure};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use uuid::Uuid;

use crate::Style;
use crate::paper::{ImportedPaper, PaperLayout};

pub struct Drafts(PathBuf);

pub struct Snapshot<'a> {
    pub revision: u32,
    pub style: Style,
    pub controls: crate::controls::Changes,
    pub settings_revision: u32,
    pub id: &'a str,
    pub paper: Option<PaperLayout>,
    drafts: &'a Drafts,
}

impl Snapshot<'_> {
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

pub struct Section {
    pub number: u32,
    pub version: u32,
    pub text: String,
}

impl Drafts {
    pub fn open(dir: &Path) -> Result<Self> {
        let drafts = Self(dir.join("drafts.sqlite3"));
        drafts.connect()?.execute_batch(
            "
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS drafts (
                id TEXT PRIMARY KEY, title TEXT NOT NULL, style TEXT NOT NULL,
                revision INTEGER NOT NULL, chars INTEGER NOT NULL, sections INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS settings (
                draft TEXT NOT NULL REFERENCES drafts(id), revision INTEGER NOT NULL,
                controls TEXT NOT NULL, PRIMARY KEY(draft,revision)
            );
            CREATE TABLE IF NOT EXISTS sections (
                draft TEXT NOT NULL REFERENCES drafts(id), number INTEGER NOT NULL,
                revision INTEGER NOT NULL, source TEXT NOT NULL, prepared TEXT NOT NULL,
                PRIMARY KEY(draft,number,revision)
            );
            CREATE TABLE IF NOT EXISTS papers (
                draft TEXT PRIMARY KEY REFERENCES drafts(id), layout TEXT NOT NULL, image BLOB NOT NULL
            );
        ",
        )?;
        Ok(drafts)
    }
    fn connect(&self) -> Result<Connection> {
        let db = Connection::open(&self.0)?;
        db.busy_timeout(std::time::Duration::from_secs(5))?;
        Ok(db)
    }
    pub fn save(
        &self,
        input: &crate::Save,
        prepared: &str,
        new_style: Option<&Style>,
        paper: Option<&ImportedPaper>,
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
            saved["paper"] = serde_json::to_value(&paper.layout)?;
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
        let settings: Option<(u32,String)> = self.connect()?.query_row(
            "SELECT revision,controls FROM settings WHERE draft=?1 AND revision<=?2 ORDER BY revision DESC LIMIT 1",
            params![id,revision], |r| Ok((r.get(0)?,r.get(1)?))).optional()?;
        let (settings_revision, controls) = match settings {
            Some((r, s)) => (r, serde_json::from_str(&s)?),
            None => (0, crate::controls::Changes::new()),
        };
        Ok(Snapshot {
            controls,
            settings_revision,
            id,
            drafts: self,
            paper: layout.as_deref().map(serde_json::from_str).transpose()?,
            revision,
            style: serde_json::from_str(&style)?,
        })
    }
    pub fn tune(
        &self,
        id: &str,
        expected: u32,
        controls: &crate::controls::Changes,
    ) -> Result<u32> {
        let mut db = self.connect()?;
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let next = Self::advance(&tx, id, expected)?;
        tx.execute(
            "INSERT INTO settings VALUES (?1,?2,?3)",
            params![id, next, serde_json::to_string(controls)?],
        )?;
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
    ) -> Result<Value> {
        ensure!(
            (1..=4000).contains(&limit),
            "limit must be 1..4000 characters"
        );
        let (source, len, version): (String, u32, u32) = self
            .connect()?
            .query_row(
                "SELECT substr(source,?4+1,?5), length(source), revision FROM sections
             WHERE draft=?1 AND number=?2 AND revision<=?3 ORDER BY revision DESC LIMIT 1",
                params![id, number, rev, offset, limit],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()?
            .context("Section does not exist at this revision")?;
        Ok(
            json!({"draft_id":id,"revision":rev,"section":number,"section_revision":version,
            "markdown":source,"offset":offset,"total_chars":len,
            "next_offset":offset.checked_add(limit).filter(|end| *end<len)}),
        )
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
