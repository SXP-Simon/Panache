#[cfg(test)]
mod list_tests;
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

const REVISION_CONFLICT: &str = "Revision conflict; read the latest revision before retrying";

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

#[cfg(test)]
#[test]
fn glyph_edit_committed_after_preflight_wins_the_revision() -> Result<()> {
    let home = tempfile::tempdir()?;
    let drafts = Drafts::open(home.path())?;
    let save = serde_json::from_value(json!({"markdown":"字"}))?;
    let saved = drafts.save(&save, "字", Some(&Style::default()), None, None)?;
    let draft = drafts.snapshot(saved["draft_id"].as_str().unwrap(), Some(1))?;
    draft.require_unadjusted_layout()?;

    // Commit another writer's glyph edit between the guard and the settings write.
    let edits = serde_json::from_value(json!({"key":"test","glyphs":[
        {"id":0,"dx":12,"dy":0,"scale":100,"angle":0,"opacity":100,"color":null}
    ]}))?;
    assert_eq!(draft.store_edits(1, 1, &edits, &Value::Null)?, 2);
    let result = drafts.tune(&draft, &draft.controls, false, None, None, &Value::Null);
    assert_eq!(result.unwrap_err().to_string(), REVISION_CONFLICT);
    let current = drafts.snapshot(draft.id, None)?;
    assert_eq!(current.revision, 2);
    assert_eq!(current.settings_revision, 0);
    assert!(current.require_unadjusted_layout().is_err());
    Ok(())
}

pub struct Snapshot<'a> {
    pub latest_revision: u32,
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
    pub fn font_name(&self) -> &str {
        self.controls
            .get("font")
            .and_then(Value::as_str)
            .unwrap_or(&self.style.font)
    }

    pub fn review_section(&self, requested: Option<u32>) -> Result<u32> {
        if let Some(section) = requested {
            ensure!(section > 0, "section starts at 1");
            let exists: bool = self.drafts.connect()?.query_row(
                "SELECT EXISTS(SELECT 1 FROM sections WHERE draft=? AND number=? AND revision<=?)",
                params![self.id, section, self.revision],
                |row| row.get(0),
            )?;
            ensure!(
                exists,
                "第 {} 版还没有第 {section} 节。请保留所查版本和页码，按待查正文选择已有的节：{}",
                self.revision,
                self.drafts
                    .review_section_choices(self.id, self.revision)?
                    .join(" · ")
            );
            return Ok(section);
        }
        let choices = self.drafts.review_section_choices(self.id, self.revision)?;
        ensure!(
            choices.len() == 1,
            "请按待查的正文选择 section。第 {} 版可查的节：{}",
            self.revision,
            choices.join(" · ")
        );
        Ok(1)
    }

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

    pub fn require_current_revision(&self) -> Result<()> {
        ensure!(self.revision == self.latest_revision, "{REVISION_CONFLICT}");
        Ok(())
    }

    pub fn require_unadjusted_layout(&self) -> Result<()> {
        self.require_current_revision()?;
        // This query reads immutable history. Drafts::advance rejects a write racing the preflight.
        let section: Option<u32> = self
            .drafts
            .connect()?
            .query_row(
                "SELECT e.section FROM glyph_edits e
                 WHERE e.draft=?1 AND e.settings_revision=?2 AND e.revision<=?3
                   AND e.source_revision=(SELECT MAX(s.revision) FROM sections s
                       WHERE s.draft=e.draft AND s.number=e.section AND s.revision<=?3)
                 LIMIT 1",
                params![self.id, self.layout_revision, self.revision],
                |row| row.get(0),
            )
            .optional()?;
        if let Some(section) = section {
            anyhow::bail!(
                "Reflow would stop applying local glyph adjustments in section {section} of revision {}. This request saved no new revision. Keep preserve_local_adjustments=true. Only if the user explicitly agrees to lose those adjustments in the new layout may you use preserve_local_adjustments=false.",
                self.revision
            );
        }
        Ok(())
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
        self.save_scoped(input, prepared, new_style, paper, font, false)
    }

    pub fn plain_replacement_source(&self, input: &crate::ReplaceText) -> Result<(String, String)> {
        let mut db = self.connect()?;
        let tx = db.transaction()?;
        let current: u32 = tx
            .query_row(
                "SELECT revision FROM drafts WHERE id=?1",
                [&input.draft_id],
                |r| r.get(0),
            )
            .optional()?
            .context("Unknown draft")?;
        ensure!(
            current == input.expected_revision,
            "Draft is at revision {current}. Review it before updating."
        );
        let (section_revision, source, prepared): (u32, String, String) = tx
            .query_row(
                "SELECT revision,source,prepared FROM sections WHERE draft=?1 AND number=?2
                 AND revision<=?3 ORDER BY revision DESC LIMIT 1",
                params![input.draft_id, input.section, current],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()?
            .context("Choose an existing section; replacement cannot append")?;
        let fine: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM glyph_edits
             WHERE draft=?1 AND section=?2 AND source_revision=?3)",
            params![input.draft_id, input.section, section_revision],
            |r| r.get(0),
        )?;
        ensure!(
            !fine,
            "Section has saved glyph adjustments. Nothing was saved. A whole-section save would not carry those positions into the new revision. Leave this version intact unless the user explicitly accepts losing these positions. Tell them the text is unchanged and offer to keep this layout or re-layout and preview. After explicit acceptance, read the complete source of this section at the agreed revision, then use save_section with that expected_revision and preview_handwriting(view=image). Do not retry this shortcut to discard placements. If you cannot reproduce the original safely, including any inline images, stop and explain before saving."
        );
        Ok((source, prepared))
    }

    pub fn save_plain_replacement(&self, input: &crate::Save, prepared: &str) -> Result<Value> {
        self.save_scoped(input, prepared, None, None, None, true)
    }

    fn save_scoped(
        &self,
        input: &crate::Save,
        prepared: &str,
        new_style: Option<&Style>,
        paper: Option<&ImportedPaper>,
        font: Option<&[u8]>,
        existing_only: bool,
    ) -> Result<Value> {
        if existing_only {
            ensure!(
                input.draft_id.is_some()
                    && input.expected_revision.is_some()
                    && input.section.is_some(),
                "Use an existing draft and section for replacement"
            );
        }

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
        if existing_only {
            let exists: bool = tx.query_row(
                "SELECT EXISTS(SELECT 1 FROM sections WHERE draft=?1 AND number=?2 AND revision<=?3)",
                params![id, number, rev],
                |r| r.get(0),
            )?;
            ensure!(
                exists,
                "Choose an existing section; replacement cannot append"
            );
        }

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
    pub fn list(&self, input: &crate::List) -> Result<Value> {
        ensure!(
            input.offset.is_none() || input.before_draft_id.is_none(),
            "Omit offset when using before_draft_id"
        );
        let offset = input.offset.unwrap_or(0);
        let mut db = self.connect()?;
        // Resolve the anchor and read its older neighbors from the same SQLite snapshot.
        let tx = db.transaction()?;
        let (query, value) = if let Some(id) = input.before_draft_id.as_deref() {
            let rowid: i64 = tx
                .query_row("SELECT rowid FROM drafts WHERE id=?1", [id], |r| r.get(0))
                .optional()?
                .context("Unknown before_draft_id")?;
            (
                "SELECT id,title,revision,sections FROM drafts WHERE rowid < ?1 ORDER BY rowid DESC LIMIT 21",
                rowid,
            )
        } else {
            (
                "SELECT id,title,revision,sections FROM drafts ORDER BY rowid DESC LIMIT 21 OFFSET ?1",
                i64::from(offset),
            )
        };
        let mut stmt = tx.prepare(query)?;
        let mut entries = stmt
            .query_map([value], |r| {
                Ok(json!({
                    "draft_id":r.get::<_,String>(0)?, "title":r.get::<_,String>(1)?,
                    "revision":r.get::<_,u32>(2)?, "sections":r.get::<_,u32>(3)?
                }))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let mut result = json!({"offset":offset});
        if entries.len() > 20 {
            entries.truncate(20);
            result["next_before_draft_id"] = entries[19]["draft_id"].clone();
        }
        result["drafts"] = entries.into();
        Ok(result)
    }
    // Bound the source prefix in SQLite, including when a section starts with an inline photo.
    fn review_section_choices(&self, id: &str, revision: u32) -> Result<Vec<String>> {
        let db = self.connect()?;
        let mut stmt = db.prepare(
            "SELECT number, substr(source,1,48) FROM sections JOIN (
                SELECT number, max(revision) AS revision FROM sections
                WHERE draft=?1 AND revision<=?2 GROUP BY number ORDER BY number LIMIT 5
             ) USING(number,revision) WHERE draft=?1 ORDER BY number",
        )?;
        let mut choices = Vec::new();
        let mut rows = stmt.query(params![id, revision])?;
        while let Some(row) = rows.next()? {
            if choices.len() == 4 {
                choices.push("其余节可用 view=excerpt 查阅".to_owned());
                break;
            }
            let number: u32 = row.get(0)?;
            let prefix: String = row.get(1)?;
            let before_image = prefix
                .find("![")
                .into_iter()
                .chain(prefix.find("data:"))
                .min()
                .unwrap_or(prefix.len());
            let text = prefix[..before_image]
                .split_whitespace()
                .collect::<Vec<_>>()
                .join(" ");
            choices.push(format!("section={number} {}", json!(text)));
        }
        Ok(choices)
    }

    /// Find a single transition from absent to present across all versions of all sections.
    pub fn text_introduction(&self, id: &str, text: &str) -> Result<(u32, u32)> {
        ensure!(
            !text.trim().is_empty() && text.chars().count() <= 160,
            "before_text needs 1..160 characters from the saved Markdown"
        );
        let db = self.connect()?;
        let mut statement = db.prepare(
            "WITH versions AS (
                 SELECT number,revision,instr(source,?2)>0 AS present
                 FROM sections WHERE draft=?1
             ), changes AS (
                 SELECT number,revision,present,
                        lag(present,1,0) OVER (PARTITION BY number ORDER BY revision) AS previously_present
                 FROM versions
             )
             SELECT number,revision FROM changes WHERE present AND NOT previously_present
             ORDER BY revision,number LIMIT 3",
        )?;
        let matches = statement
            .query_map(params![id, text], |row| {
                Ok((row.get::<_, u32>(0)?, row.get::<_, u32>(1)?))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let &(section, revision) = matches.first().context(
            "No section contains before_text. Read the source for a literal fragment or specify a revision."
        )?;
        if matches.len() > 1 {
            let mut message = String::from(
                "这段原文有多个加入时点。请让用户确认是首次加入之前，还是后来再次加入之前；也可分别核对并逐版列出，未确认时不要代选。",
            );
            let same_section = matches[0].0 == matches[1].0;
            for (number, added) in matches.iter().take(2) {
                if same_section {
                    message.push_str(&format!("\n第 {added} 版加入了这段原文。"));
                } else {
                    message.push_str(&format!("\n第 {added} 版在第 {number} 节加入了这段原文。"));
                }
                if *added == 1 {
                    message.push_str("这是初稿，之前没有稿件。");
                } else {
                    let before = added - 1;
                    let choices = self.review_section_choices(id, before)?;
                    message.push_str(&format!(
                        "加入前查 revision={before}；该版可查的正文：{}",
                        choices.join(" · ")
                    ));
                }
            }
            if matches.len() > 2 {
                message.push_str(
                    "\n这里只列最早两次，另有加入时点。可通过 trajectory 和 source 核对。",
                );
            }
            anyhow::bail!(
                "{message}\n所补文字只用来认版本。请按用户要查的正文选择 section，保留 page，移除 before_text 后按明确版本查单。"
            );
        }
        ensure!(
            revision > 1,
            "before_text already occurs in the first revision; no earlier draft exists."
        );
        Ok((section, revision))
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
            latest_revision: latest,
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
            "{REVISION_CONFLICT}"
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
