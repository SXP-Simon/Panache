use super::Drafts;
use crate::{FeedbackOrigin, Read};
use anyhow::{Context, Result, ensure};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use rusqlite::{OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

// Edits advance the revision. Reviews and annotations can be appended to older revisions.
#[derive(Deserialize, Serialize)]
struct Cursor {
    draft_id: String,
    revision: u32,
    review_seq: i64,
    feedback_rowid: i64,
    section: Option<u32>,
    feedback_origin: Option<FeedbackOrigin>,
    offset: u32,
}

impl Drafts {
    pub fn trajectory(&self, input: &Read) -> Result<Value> {
        let limit = input.limit.unwrap_or(12);
        ensure!((1..=50).contains(&limit), "Trajectory limit must be 1..50");
        ensure!(input.section != Some(0), "Section numbers start at 1");
        let db = self.connect()?;
        // A single SQLite read captures all three append-only boundaries together.
        let (latest, review_seq, feedback_rowid): (u32, i64, i64) = db
            .query_row(
                "SELECT revision, (SELECT coalesce(max(seq),0) FROM review_observations),
                    (SELECT coalesce(max(rowid),0) FROM review_feedback) FROM drafts WHERE id=?",
                [&input.draft_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .optional()?
            .context("Unknown draft")?;
        let mut page = if let Some(token) = &input.cursor {
            let bytes = URL_SAFE_NO_PAD
                .decode(token)
                .context("Invalid trajectory cursor")?;
            let saved: Cursor =
                serde_json::from_slice(&bytes).context("Invalid trajectory cursor")?;
            ensure!(
                input.offset.is_none(),
                "Omit offset when continuing a cursor"
            );
            ensure!(
                saved.draft_id == input.draft_id
                    && input.revision.is_none_or(|r| r == saved.revision)
                    && (input.section.is_none() || input.section == saved.section)
                    && (input.feedback_origin.is_none()
                        || input.feedback_origin == saved.feedback_origin),
                "Cursor belongs to a different draft, revision or filter"
            );
            saved
        } else {
            let revision = input.revision.unwrap_or(latest);
            Cursor {
                draft_id: input.draft_id.clone(),
                revision,
                section: input.section,
                feedback_origin: input.feedback_origin,
                offset: input.offset.unwrap_or(0),
                review_seq,
                feedback_rowid,
            }
        };
        ensure!(
            (1..=latest).contains(&page.revision),
            "Unknown revision (latest: {latest})"
        );
        ensure!(
            (0..=review_seq).contains(&page.review_seq)
                && (0..=feedback_rowid).contains(&page.feedback_rowid),
            "Invalid trajectory snapshot bounds"
        );
        let mut stmt=db.prepare(
            "WITH events(revision,action,section,page,evidence,review_id,origin,seq) AS (
              SELECT revision,'save_section',number,NULL,NULL,NULL,'draft_edit',0 FROM sections WHERE draft=?1
              UNION ALL SELECT revision,'tune_handwriting',NULL,NULL,NULL,NULL,'draft_edit',0 FROM settings WHERE draft=?1
              UNION ALL SELECT revision,'adjust_glyphs',section,NULL,NULL,NULL,'draft_edit',0 FROM glyph_edits WHERE draft=?1
              UNION ALL SELECT revision,'page_review',section,page,evidence,review_id,'measurement',seq
                FROM review_observations WHERE draft=?1 AND seq<=?7
              UNION ALL SELECT o.revision,'review_feedback',o.section,o.page,json_object('text',f.note),
                       o.review_id,f.origin,f.rowid FROM review_feedback f JOIN review_observations o USING(review_id)
                WHERE o.draft=?1 AND o.seq<=?7 AND f.rowid<=?8
            )
            SELECT e.revision,e.action,e.section,COALESCE(e.page,json_extract(n.details,'$.page')),
                   COALESCE(e.evidence,n.details,'{}'),e.review_id,e.origin
            FROM events e LEFT JOIN edit_notes n ON n.draft=?1 AND n.revision=e.revision
            WHERE e.revision<=?2 AND (?5 IS NULL OR e.section=?5) AND (?6 IS NULL OR e.origin=?6)
            ORDER BY e.revision DESC,(e.action='review_feedback') DESC,(e.action='page_review') DESC,e.seq DESC,e.section,e.page
            LIMIT ?3 OFFSET ?4")?;
        let mut entries = Vec::new();
        let mut rows = stmt.query(params![
            page.draft_id,
            page.revision,
            limit + 1,
            page.offset,
            page.section,
            page.feedback_origin.as_ref().map(FeedbackOrigin::as_str),
            page.review_seq,
            page.feedback_rowid
        ])?;
        while let Some(row) = rows.next()? {
            let details: String = row.get(4)?;
            entries.push(json!({
                "revision":row.get::<_,u32>(0)?,
                "action":row.get::<_,String>(1)?,
                "review_id":row.get::<_,Option<String>>(5)?,"origin":row.get::<_,String>(6)?,
                "section":row.get::<_,Option<u32>>(2)?,
                "page":row.get::<_,Option<u32>>(3)?,
                "details":serde_json::from_str::<Value>(&details)?,
            }));
        }
        let more = entries.len() > limit as usize;
        entries.truncate(limit as usize);
        let next_offset = page.offset.checked_add(limit).filter(|_| more);
        let mut result = json!({"draft_id":page.draft_id,"revision":page.revision,"events":entries,"next_offset":next_offset,
            "event_order":"reviewed_or_edited_revision_desc",
            "order_note":"检查单和评语按受检稿件版本排列。要判断何时开单，请按 review_id 查原单的 filed_at_revision；旧单可能缺少这项记录。"});
        if let Some(offset) = next_offset {
            page.offset = offset;
            result["next_cursor"] = json!(URL_SAFE_NO_PAD.encode(serde_json::to_vec(&page)?));
        }
        Ok(result)
    }
}
