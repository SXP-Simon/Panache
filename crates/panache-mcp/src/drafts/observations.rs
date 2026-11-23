use super::{Drafts, Snapshot};
use anyhow::{Context, Result, ensure};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde_json::{Value, json};
use uuid::Uuid;

pub(super) fn initialize(db: &mut Connection) -> Result<()> {
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    tx.execute_batch("
        CREATE TABLE IF NOT EXISTS review_observations(
            seq INTEGER PRIMARY KEY, review_id TEXT NOT NULL UNIQUE,
            draft TEXT NOT NULL, revision INTEGER NOT NULL, section INTEGER NOT NULL, page INTEGER NOT NULL,
            algorithm TEXT, pixel_sha256 TEXT, content_sha256 TEXT, evidence TEXT NOT NULL,
            UNIQUE(draft,revision,section,page,algorithm,pixel_sha256)
        );
        CREATE INDEX IF NOT EXISTS reviews_by_page ON review_observations(draft,revision,section,page,seq);
        CREATE TABLE IF NOT EXISTS review_feedback(
            review_id TEXT NOT NULL REFERENCES review_observations(review_id),
            origin TEXT NOT NULL, note TEXT NOT NULL, UNIQUE(review_id,origin,note)
        );")?;
    if tx.table_exists(None, "page_reviews")? {
        // Older observations did not retain a pixel digest or measurement version.
        tx.execute_batch("INSERT INTO review_observations(review_id,draft,revision,section,page,evidence)
            SELECT lower(hex(randomblob(16))),draft,revision,section,page,evidence FROM page_reviews;
            DROP TABLE page_reviews;")?;
    }
    tx.commit()?;
    Ok(())
}

fn by_id(db: &Connection, id: &str, draft: &Snapshot<'_>) -> Result<Value> {
    let mut record=db.query_row("SELECT revision,section,page,algorithm,pixel_sha256,content_sha256,evidence
        FROM review_observations WHERE draft=? AND review_id=? AND revision<=?",
        params![draft.id,id,draft.revision],|r|Ok(json!({
            "draft_id":draft.id,"review_id":id,"origin":"measurement","revision":r.get::<_,u32>(0)?,
            "section":r.get::<_,u32>(1)?,"page":r.get::<_,u32>(2)?,"algorithm":r.get::<_,Option<String>>(3)?,
            "pixel_sha256":r.get::<_,Option<String>>(4)?,"page_content_sha256":r.get::<_,Option<String>>(5)?,
            "evidence":r.get::<_,String>(6)?,
        }))).optional()?.context("Unknown review in this draft and revision range")?;
    record["evidence"] = serde_json::from_str(
        record["evidence"]
            .as_str()
            .context("Invalid review evidence")?,
    )?;
    let mut stmt = db.prepare(
        "SELECT origin,note FROM review_feedback WHERE review_id=? ORDER BY rowid DESC LIMIT 51",
    )?;
    let mut notes = stmt
        .query_map([id], |r| {
            Ok(json!({"origin":r.get::<_,String>(0)?,"text":r.get::<_,String>(1)?}))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    record["more_feedback"] = json!(notes.len() > 50);
    notes.truncate(50);
    record["feedback"] = json!(notes);
    Ok(record)
}

impl Snapshot<'_> {
    pub fn record_review(
        &self,
        section: u32,
        page: usize,
        algorithm: &str,
        pixel: &str,
        content: &str,
        evidence: &Value,
    ) -> Result<Value> {
        let page = u32::try_from(page)?;
        let mut db = self.drafts.connect()?;
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        tx.execute("INSERT INTO review_observations(review_id,draft,revision,section,page,algorithm,pixel_sha256,content_sha256,evidence)
            VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(draft,revision,section,page,algorithm,pixel_sha256) DO NOTHING",
            params![Uuid::new_v4().to_string(),self.id,self.revision,section,page,algorithm,pixel,content,evidence.to_string()])?;
        let id:String=tx.query_row("SELECT review_id FROM review_observations
            WHERE draft=? AND revision=? AND section=? AND page=? AND algorithm=? AND pixel_sha256=?",
            params![self.id,self.revision,section,page,algorithm,pixel],|r|r.get(0))?;
        let record = by_id(&tx, &id, self)?;
        tx.commit()?;
        Ok(record)
    }

    pub fn observation(&self, id: &str) -> Result<Value> {
        by_id(&self.drafts.connect()?, id, self)
    }

    pub fn review_counts(&self) -> Result<(u32, u32)> {
        Ok(self.drafts.connect()?.query_row("SELECT count(*),
            count(CASE WHEN json_extract(evidence,'$.visibility') IN ('no_visible_change','very_low_contrast') THEN 1 END)
            FROM review_observations WHERE seq IN (SELECT max(seq) FROM review_observations
            WHERE draft=? AND revision=? GROUP BY section,page)",params![self.id,self.revision],
            |r|Ok((r.get(0)?,r.get(1)?)))?)
    }

    pub fn compare_reviews(
        &self,
        before: u32,
        section: u32,
        page: usize,
        offset: u32,
        limit: u32,
    ) -> Result<Value> {
        ensure!(
            before > 0 && before < self.revision,
            "compare_revision must identify an earlier revision"
        );
        ensure!(
            section > 0 && page > 0 && (1..=50).contains(&limit),
            "Use a one-based section/page and 1..50 edit actions"
        );
        let mut db = self.drafts.connect()?;
        let tx = db.transaction()?;
        let fetch = |rev: u32| -> Result<Option<Value>> {
            let id: Option<String> = tx
                .query_row(
                    "SELECT review_id FROM review_observations
                WHERE draft=? AND revision=? AND section=? AND page=? ORDER BY seq DESC LIMIT 1",
                    params![self.id, rev, section, u32::try_from(page)?],
                    |r| r.get(0),
                )
                .optional()?;
            id.map(|v| by_id(&tx, &v, self)).transpose()
        };
        let previous = fetch(before)?;
        let current = fetch(self.revision)?;
        let mut stmt=tx.prepare("WITH actions(rev,action,section) AS (
            SELECT revision,'save_section',number FROM sections WHERE draft=?1
            UNION ALL SELECT revision,'tune_handwriting',NULL FROM settings WHERE draft=?1
            UNION ALL SELECT revision,'adjust_glyphs',section FROM glyph_edits WHERE draft=?1)
            SELECT rev,action,section,details FROM actions LEFT JOIN edit_notes ON draft=?1 AND revision=rev
            WHERE rev>?2 AND rev<=?3 ORDER BY rev LIMIT ?4 OFFSET ?5")?;
        let mut rows = stmt.query(params![self.id, before, self.revision, limit + 1, offset])?;
        let mut actions = Vec::new();
        while let Some(row) = rows.next()? {
            let details: Option<String> = row.get(3)?;
            actions.push(json!({"revision":row.get::<_,u32>(0)?,"action":row.get::<_,String>(1)?,
                "section":row.get::<_,Option<u32>>(2)?,"details":details.as_deref().map(serde_json::from_str::<Value>).transpose()?}));
        }
        let more = actions.len() > limit as usize;
        actions.truncate(limit as usize);
        Ok(
            json!({"draft_id":self.id,"section":section,"page":page,"compare_revision":before,"revision":self.revision,
            "comparison":compare(previous.as_ref(),current.as_ref()),"before":previous,"after":current,
            "actions":actions,"next_offset":if more{offset.checked_add(limit)}else{None},
            "guidance":"Deltas are after minus before. Check support, visible ink and attributed feedback before judging placement or aesthetics. Actions show what changed; concurrent edits do not isolate a cause. Request view=image with a revision to see a fresh rendering."}),
        )
    }
}

impl Drafts {
    pub fn annotate(&self, input: &crate::ReviewFeedback) -> Result<Value> {
        let text = input.text.trim();
        ensure!(
            !text.is_empty() && text.chars().count() <= 320,
            "Feedback must contain 1..320 characters"
        );
        let origin = input.origin.as_str();
        let mut db = self.connect()?;
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let revision: u32 = tx
            .query_row(
                "SELECT revision FROM review_observations WHERE draft=? AND review_id=?",
                params![input.draft_id, input.review_id],
                |r| r.get(0),
            )
            .optional()?
            .context("Unknown review in this draft")?;
        tx.execute(
            "INSERT INTO review_feedback(review_id,origin,note) VALUES(?,?,?)
            ON CONFLICT(review_id,origin,note) DO NOTHING",
            params![input.review_id, origin, text],
        )?;
        tx.commit()?;
        Ok(
            json!({"draft_id":input.draft_id,"review_id":input.review_id,"revision":revision,"origin":origin,"text":text}),
        )
    }
}

fn compare(before: Option<&Value>, after: Option<&Value>) -> Value {
    let mut reasons = Vec::new();
    if before.is_none() {
        reasons.push("missing_before_review");
    }
    if after.is_none() {
        reasons.push("missing_after_review");
    }
    let (Some(a), Some(b)) = (before, after) else {
        return json!({"limitations":reasons,"delta":null});
    };
    if a["algorithm"].is_null() || b["algorithm"].is_null() {
        reasons.push("unknown_algorithm");
    } else if a["algorithm"] != b["algorithm"] {
        reasons.push("different_algorithms");
    }
    if a["page_content_sha256"].is_null() || b["page_content_sha256"].is_null() {
        reasons.push("unknown_page_content");
    } else if a["page_content_sha256"] != b["page_content_sha256"] {
        reasons.push("page_content_changed_or_repaginated");
    }
    let (a, b) = (&a["evidence"], &b["evidence"]);
    if a["photo_size"] != b["photo_size"] {
        reasons.push("different_image_dimensions");
    }
    if !reasons.is_empty() {
        return json!({"limitations":reasons,"delta":null});
    }
    let difference = |x: &Value, y: &Value| -> Option<i64> { Some(y.as_i64()? - x.as_i64()?) };
    let bands=(0..3).map(|i|{
        let x=&a["nearby_dark_ridge_by_image_third"][i];
        let y=&b["nearby_dark_ridge_by_image_third"][i];
        let support=[x["supported_samples"].as_u64().unwrap_or(0),y["supported_samples"].as_u64().unwrap_or(0)];
        let enough=support.iter().all(|n|*n>=3);
        json!({"supported_before_after":support,"limitation":if enough {None}else{Some("insufficient_ridge_support")},
            "median_abs_dy_px":if enough{difference(&x["median_abs_dy_px"],&y["median_abs_dy_px"])}else{None},
            "changed_pixels":difference(&a["changed_pixels_by_image_third"][i],&b["changed_pixels_by_image_third"][i])})
    }).collect::<Vec<_>>();
    json!({"limitations":reasons,"delta":{"visibility_before":a["visibility"],"visibility_after":b["visibility"],
        "max_rgb_delta":difference(&a["max_rgb_delta"],&b["max_rgb_delta"]),
        "changed_pixels_outside_each_reference":difference(&a["changed_pixels_outside_reference"],&b["changed_pixels_outside_reference"]),
        "by_image_third":bands,"global_ink_settings_equal":a["global_ink"]==b["global_ink"]}})
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn upgrades_old_rows_without_inventing_provenance_and_deduplicates_new_observations()
    -> Result<()> {
        let home = tempfile::tempdir()?;
        let db = Connection::open(home.path().join("drafts.sqlite3"))?;
        db.execute_batch("CREATE TABLE page_reviews(draft TEXT NOT NULL,revision INTEGER NOT NULL,
            section INTEGER NOT NULL,page INTEGER NOT NULL,evidence TEXT NOT NULL,PRIMARY KEY(draft,revision,section,page));
            INSERT INTO page_reviews VALUES('d',1,1,1,'{\"visibility\":\"no_visible_change\"}');")?;
        drop(db);
        let drafts = Drafts::open(home.path())?;
        drafts.connect()?.execute(
            "INSERT INTO drafts VALUES ('d','title',?,3,0,1)",
            [serde_json::to_string(&crate::Style::default())?],
        )?;
        let old = drafts.snapshot("d", Some(1))?;
        let legacy_id = drafts.trajectory(&serde_json::from_value(
            json!({"draft_id":"d","revision":1,"limit":5}),
        )?)?["events"][0]["review_id"]
            .as_str()
            .unwrap()
            .to_owned();
        let legacy = old.observation(&legacy_id)?;
        assert!(
            legacy["algorithm"].is_null()
                && legacy["pixel_sha256"].is_null()
                && legacy["page_content_sha256"].is_null()
        );
        assert_eq!(legacy["evidence"]["visibility"], "no_visible_change");
        let observation = json!({"visibility":"inspect_visually","photo_size":[400,500]});
        let rev2 = drafts.snapshot("d", Some(2))?;
        let first = rev2.record_review(1, 1, "a", "pixels", "content", &observation)?;
        for _ in 0..9 {
            assert_eq!(
                rev2.record_review(1, 1, "a", "pixels", "content", &observation)?,
                first
            );
        }
        assert_eq!(
            drafts.connect()?.query_row(
                "SELECT count(*) FROM review_observations WHERE revision=2",
                [],
                |r| r.get::<_, u32>(0)
            )?,
            1
        );
        let changed = rev2.record_review(1, 1, "a", "other-pixels", "content", &observation)?;
        let upgraded = rev2.record_review(
            1,
            1,
            "b",
            "other-pixels",
            "content",
            &json!({"visibility":"very_low_contrast","photo_size":[400,500]}),
        )?;
        assert_ne!(first["review_id"], changed["review_id"]);
        assert_ne!(changed["review_id"], upgraded["review_id"]);
        assert_eq!(rev2.review_counts()?, (1, 1));
        let rev3 = drafts.snapshot("d", Some(3))?;
        rev3.record_review(1, 1, "a", "pixels", "content", &observation)?;
        let comparison = rev3.compare_reviews(2, 1, 1, 0, 5)?;
        assert_eq!(
            comparison["comparison"]["limitations"],
            json!(["different_algorithms"])
        );
        assert!(comparison["comparison"]["delta"].is_null());
        assert!(
            rev3.compare_reviews(1, 1, 1, 0, 5)?["comparison"]["limitations"]
                .as_array()
                .unwrap()
                .contains(&json!("unknown_algorithm"))
        );
        for record in [first, changed, upgraded, legacy] {
            let reopened = Drafts::open(home.path())?;
            assert_eq!(
                reopened
                    .snapshot("d", None)?
                    .observation(record["review_id"].as_str().unwrap())?,
                record
            );
        }
        Ok(())
    }
}
