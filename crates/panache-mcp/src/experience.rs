//! Evidence-backed, individually retrievable guidance from ordinary homework deliveries.
#[cfg(test)]
mod tests;

use crate::drafts::Drafts;
use anyhow::{Context, Result, ensure};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::BTreeSet;
use uuid::Uuid;

pub(crate) fn initialize(db: &Connection) -> Result<()> {
    db.execute_batch("
        CREATE TABLE IF NOT EXISTS experience_rules (
            id TEXT PRIMARY KEY, signature TEXT NOT NULL UNIQUE, scope TEXT NOT NULL,
            action TEXT NOT NULL, reason TEXT NOT NULL, status TEXT NOT NULL, retirement TEXT
        );
        CREATE TABLE IF NOT EXISTS experience_tags (
            rule_id TEXT NOT NULL, tag TEXT NOT NULL, PRIMARY KEY(rule_id,tag)
        );
        CREATE INDEX IF NOT EXISTS experience_by_tag ON experience_tags(tag,rule_id);
        CREATE TABLE IF NOT EXISTS experience_cases(
            seq INTEGER PRIMARY KEY, rule_id TEXT NOT NULL, role TEXT NOT NULL,
            draft TEXT NOT NULL, revision INTEGER NOT NULL, export_id TEXT NOT NULL,
            format TEXT NOT NULL, reviews TEXT NOT NULL, passed INTEGER NOT NULL, reason TEXT NOT NULL,
            UNIQUE(rule_id,role,draft,revision,reviews,passed,reason)
        );
        CREATE UNIQUE INDEX IF NOT EXISTS experience_source_evidence
            ON experience_cases(rule_id,draft,revision,reviews) WHERE role='source';
        CREATE INDEX IF NOT EXISTS experience_cases_by_rule ON experience_cases(rule_id,seq);
    ")?;
    Ok(())
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SourceReview {
    /// Exact revision of this native full-page review. May precede delivery.
    revision: u32,
    review_id: String,
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Rule {
    /// All tags must apply. Prefer reusable terms such as formula, table or photographed-paper.
    tags: Vec<String>,
    /// Observable conditions under which this one action helps.
    scope: String,
    /// Specific instruction the next host can execute and check.
    action: String,
    /// Cite specific marks, symbols or locations visible in the referenced reviews.
    reason: String,
    reviews: Vec<SourceReview>,
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Record {
    draft_id: String,
    revision: u32,
    /// Published export_handwriting receipt for this exact draft and revision.
    export_id: String,
    /// Zero or more independent lessons. Each cites a review at delivery and optionally earlier failed attempts.
    rules: Vec<Rule>,
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Search {
    /// Task topics in either language. Use [] for active vocabulary. Canonical examples: homework, photographed-paper, ruled-paper, formula, table, flowchart, illustration.
    tags: Vec<String>,
    /// Result offset; also pages the vocabulary on a miss.
    #[serde(default)]
    offset: u32,
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Read {
    rule_id: String,
    /// Exclusive evidence sequence cursor from a previous read.
    #[serde(default)]
    after: u64,
}

#[derive(Copy, Clone, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    /// The action helped an in-scope homework.
    Positive,
    /// An independent out-of-scope or already-correct case remained unharmed.
    Boundary,
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Validate {
    rule_id: String,
    kind: Kind,
    passed: bool,
    /// Host observation explaining the benefit, boundary behavior or failure.
    reason: String,
    draft_id: String,
    revision: u32,
    export_id: String,
    reviews: Vec<SourceReview>,
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Retire {
    rule_id: String,
    reason: String,
}

fn bounded(text: &str, name: &str, limit: usize) -> Result<()> {
    ensure!(
        !text.trim().is_empty() && text.chars().count() <= limit,
        "{name} must contain 1..{limit} characters"
    );
    Ok(())
}

fn tags(values: &[String]) -> Result<Vec<String>> {
    ensure!(values.len() <= 16, "At most 16 tags");
    let mut normalized = BTreeSet::new();
    for value in values {
        let tag = value.trim().to_lowercase();
        bounded(&tag, "tag", 64)?;
        normalized.insert(tag);
    }
    Ok(normalized.into_iter().collect())
}

fn delivery(db: &Connection, draft: &str, revision: u32, id: &str) -> Result<String> {
    db.query_row(
        "SELECT format FROM export_files WHERE id=? AND draft=? AND revision=? AND published=1",
        params![id, draft, revision],
        |r| r.get(0),
    )
    .optional()?
    .context("Expected a published export_id for this exact draft and revision")
}

#[derive(Serialize)]
struct Review {
    draft_id: String,
    read_section_arguments: Value,
    review_id: String,
    revision: u32,
    section: u32,
    page: u32,
    pixel_sha256: String,
}

fn reviews(db: &Connection, draft: &str, revision: u32, refs: &[SourceReview]) -> Result<String> {
    ensure!(
        refs.len() <= 16 && refs.iter().any(|r| r.revision == revision),
        "Cite a full-page review at the delivery revision; up to 16 reviews"
    );
    let mut rows = Vec::new();
    for reference in refs {
        ensure!(
            reference.revision <= revision,
            "Review is later than the delivered revision"
        );
        let row = db
            .query_row(
                "SELECT section,page,pixel_sha256 FROM review_observations
             WHERE review_id=? AND draft=? AND revision=? AND pixel_sha256 IS NOT NULL",
                params![reference.review_id, draft, reference.revision],
                |r| {
                    Ok(Review {
                        draft_id: draft.into(),
                        read_section_arguments: json!({
                            "view": "review", "draft_id": draft,
                            "revision": reference.revision, "review_id": reference.review_id,
                        }),
                        review_id: reference.review_id.clone(),
                        revision: reference.revision,
                        section: r.get(0)?,
                        page: r.get(1)?,
                        pixel_sha256: r.get(2)?,
                    })
                },
            )
            .optional()?
            .context("Unknown pixel-backed review at the cited draft and revision")?;
        rows.push(row);
    }
    rows.sort_by(|a, b| a.review_id.cmp(&b.review_id));
    rows.dedup_by(|a, b| a.review_id == b.review_id);
    Ok(serde_json::to_string(&rows)?)
}

struct Case<'a> {
    draft: &'a str,
    revision: u32,
    export_id: &'a str,
    format: &'a str,
    reviews: String,
    role: &'a str,
    passed: bool,
    reason: &'a str,
}

impl Case<'_> {
    fn insert(&self, db: &Connection, rule: &str) -> Result<()> {
        // A different export of one draft, or a new draft containing identical reviewed
        // pixels, cannot serve as the opposite control or as independent discovery evidence.
        let conflicts: bool = db.query_row("SELECT EXISTS (
            SELECT 1 FROM experience_cases c WHERE rule_id=? AND role<>?
            AND (draft=? OR EXISTS (
                SELECT 1 FROM json_each(c.reviews) old JOIN json_each(?) new
                  ON json_extract(old.value,'$.pixel_sha256')=json_extract(new.value,'$.pixel_sha256')
                WHERE json_extract(old.value,'$.revision')=c.revision AND json_extract(new.value,'$.revision')=?
            ))
        )",params![rule,self.role,self.draft,self.reviews,self.revision],|r| r.get(0))?;
        ensure!(
            !conflicts,
            "Source, positive and boundary roles require independent drafts and independently rendered final review pixels"
        );
        db.execute("INSERT INTO experience_cases(rule_id,role,draft,revision,export_id,format,reviews,passed,reason)
            VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT DO NOTHING",
            params![rule,self.role,self.draft,self.revision,self.export_id,self.format,self.reviews,self.passed,self.reason])?;
        Ok(())
    }
}

fn json_column(row: &rusqlite::Row<'_>, index: usize) -> rusqlite::Result<Value> {
    let text: String = row.get(index)?;
    serde_json::from_str(&text).map_err(|error| {
        rusqlite::Error::FromSqlConversionFailure(
            index,
            rusqlite::types::Type::Text,
            Box::new(error),
        )
    })
}

fn status(db: &Connection, id: &str) -> Result<String> {
    db.query_row(
        "SELECT status FROM experience_rules WHERE id=?",
        [id],
        |r| r.get(0),
    )
    .optional()?
    .context("Unknown experience rule")
}

impl Drafts {
    pub fn record_experience(&self, input: Record) -> Result<Value> {
        ensure!(
            input.rules.len() <= 16,
            "At most 16 rules per delivery call"
        );
        let mut db = self.connect()?;
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let format = delivery(&tx, &input.draft_id, input.revision, &input.export_id)?;
        let mut result = Vec::new();
        for rule in input.rules {
            let tags = tags(&rule.tags)?;
            ensure!(!tags.is_empty(), "Supply at least one applicable tag");
            bounded(&rule.scope, "scope", 800)?;
            bounded(&rule.action, "action", 1200)?;
            bounded(&rule.reason, "reason", 1200)?;
            let case = Case {
                draft: &input.draft_id,
                revision: input.revision,
                export_id: &input.export_id,
                format: &format,
                reviews: reviews(&tx, &input.draft_id, input.revision, &rule.reviews)?,
                role: "source",
                passed: true,
                reason: rule.reason.trim(),
            };
            let signature = serde_json::to_string(&(&tags, rule.scope.trim(), rule.action.trim()))?;
            let id = Uuid::new_v4().to_string();
            tx.execute("INSERT INTO experience_rules(id,signature,scope,action,reason,status) VALUES(?,?,?,?,?,'pending') ON CONFLICT(signature) DO NOTHING", params![id,signature,rule.scope.trim(),rule.action.trim(),rule.reason.trim()])?;
            let (id, state): (String, String) = tx.query_row(
                "SELECT id,status FROM experience_rules WHERE signature=?",
                [&signature],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )?;
            if state == "pending" || state == "active" {
                for tag in tags {
                    tx.execute(
                        "INSERT OR IGNORE INTO experience_tags(rule_id,tag) VALUES(?,?)",
                        params![id, tag],
                    )?;
                }
                case.insert(&tx, &id)?;
            }
            let next_step = match state.as_str() {
                "pending" => {
                    "Use validate_homework_experience on separate positive and boundary homework deliveries with their native reviews. Search can return the rule after both pass."
                }
                "active" => "Search again with current homework tags before applying the rule.",
                _ => {
                    "This rule is permanently unavailable to ordinary search. Recording it again does not reactivate it."
                }
            };
            result.push(json!({"rule_id":id,"status":state,"next_step":next_step}));
        }
        tx.commit()?;
        Ok(json!({"rules":result}))
    }

    pub fn search_experience(&self, input: Search) -> Result<Value> {
        let query = serde_json::to_string(&tags(&input.tags)?)?;
        let mut db = self.connect()?;
        let tx = db.transaction()?;
        let mut stmt = tx.prepare("SELECT r.id,r.scope,r.action,r.reason,
                (SELECT json_group_array(tag) FROM experience_tags WHERE rule_id=r.id),
                (SELECT json_object('draft_id',draft,'revision',revision,'export_id',export_id,'reviews',json(reviews))
                    FROM experience_cases WHERE rule_id=r.id AND role='source' ORDER BY seq LIMIT 1)
            FROM experience_rules r WHERE status='active' AND NOT EXISTS (
                SELECT 1 FROM experience_tags t WHERE t.rule_id=r.id AND tag NOT IN (SELECT value FROM json_each(?)))
            ORDER BY (SELECT count(*) FROM experience_tags WHERE rule_id=r.id) DESC,r.id LIMIT 21 OFFSET ?")?;
        let mut rules = stmt
            .query_map(params![query, input.offset], |r| {
                Ok(json!({
                    "rule_id": r.get::<_, String>(0)?, "status": "active",
                    "scope": r.get::<_, String>(1)?, "action": r.get::<_, String>(2)?,
                    "reason": r.get::<_, String>(3)?, "tags": json_column(r, 4)?,
                    "source": json_column(r, 5)?,
                }))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let more = rules.len() > 20;
        rules.truncate(20);
        let mut result =
            json!({"rules":rules,"next_offset":more.then_some(u64::from(input.offset)+20)});
        if rules.is_empty() {
            let mut s = tx.prepare("SELECT DISTINCT tag FROM experience_tags t JOIN experience_rules r ON t.rule_id=r.id WHERE r.status='active' ORDER BY tag LIMIT 51 OFFSET ?")?;
            let mut vocabulary = s
                .query_map([input.offset], |r| r.get::<_, String>(0))?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            let more = vocabulary.len() > 50;
            vocabulary.truncate(50);
            result["available_tags"] = json!(vocabulary);
            result["next_tag_offset"] = json!(more.then_some(u64::from(input.offset) + 50));
        }
        Ok(result)
    }

    pub fn validate_experience(&self, input: Validate) -> Result<Value> {
        bounded(&input.reason, "reason", 1200)?;
        let role = match input.kind {
            Kind::Positive => "positive",
            Kind::Boundary => "boundary",
        };
        let mut db = self.connect()?;
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let state = status(&tx, &input.rule_id)?;
        let format = delivery(&tx, &input.draft_id, input.revision, &input.export_id)?;
        let case = Case {
            draft: &input.draft_id,
            revision: input.revision,
            export_id: &input.export_id,
            format: &format,
            reviews: reviews(&tx, &input.draft_id, input.revision, &input.reviews)?,
            role,
            passed: input.passed,
            reason: input.reason.trim(),
        };
        if state == "rejected" || state == "retired" {
            let replay:bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM experience_cases WHERE rule_id=? AND role=? AND draft=? AND revision=? AND reviews=? AND passed=? AND reason=?)",
                params![input.rule_id,role,case.draft,case.revision,case.reviews,case.passed,case.reason],|r|r.get(0))?;
            ensure!(replay, "This rule is permanently {state}");
        } else {
            case.insert(&tx, &input.rule_id)?;
            tx.execute("UPDATE experience_rules SET status=CASE
                WHEN NOT ? THEN 'rejected'
                WHEN (SELECT count(DISTINCT role) FROM experience_cases WHERE rule_id=? AND passed=1 AND role IN ('positive','boundary'))=2 THEN 'active'
                ELSE 'pending' END WHERE id=?",params![case.passed,input.rule_id,input.rule_id])?;
        }
        let state = status(&tx, &input.rule_id)?;
        tx.commit()?;
        Ok(json!({"rule_id":input.rule_id,"status":state}))
    }

    pub fn retire_experience(&self, input: Retire) -> Result<Value> {
        bounded(&input.reason, "reason", 1200)?;
        let mut db = self.connect()?;
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let state = status(&tx, &input.rule_id)?;
        ensure!(state != "rejected", "Rule already rejected by validation");
        tx.execute("UPDATE experience_rules SET status='retired',retirement=? WHERE id=? AND status<>'retired'",params![input.reason.trim(),input.rule_id])?;
        tx.commit()?;
        Ok(json!({"rule_id":input.rule_id,"status":"retired"}))
    }

    pub fn read_experience(&self, input: Read) -> Result<Value> {
        let mut db = self.connect()?;
        let tx = db.transaction()?;
        let mut rule = tx.query_row(
            "SELECT scope,action,reason,status,retirement FROM experience_rules WHERE id=?",
            [&input.rule_id],
            |r| Ok(json!({
                "rule_id": input.rule_id, "scope": r.get::<_, String>(0)?,
                "action": r.get::<_, String>(1)?, "reason": r.get::<_, String>(2)?,
                "status": r.get::<_, String>(3)?, "retirement": r.get::<_, Option<String>>(4)?,
            })),
        ).optional()?.context("Unknown experience rule")?;
        let mut stmt =
            tx.prepare("SELECT tag FROM experience_tags WHERE rule_id=? ORDER BY tag")?;
        rule["tags"] = json!(
            stmt.query_map([&input.rule_id], |r| r.get::<_, String>(0))?
                .collect::<rusqlite::Result<Vec<_>>>()?
        );
        let mut stmt = tx.prepare(
            "SELECT seq,role,draft,revision,export_id,format,reviews,passed,reason
             FROM experience_cases WHERE rule_id=? AND seq>? ORDER BY seq LIMIT 21",
        )?;
        let mut cases = stmt.query_map(params![input.rule_id, i64::try_from(input.after)?], |r| Ok(json!({
            "seq": r.get::<_, i64>(0)?, "kind": r.get::<_, String>(1)?,
            "draft_id": r.get::<_, String>(2)?, "revision": r.get::<_, u32>(3)?,
            "export_id": r.get::<_, String>(4)?, "format": r.get::<_, String>(5)?,
            "reviews": json_column(r, 6)?, "passed": r.get::<_, bool>(7)?, "reason": r.get::<_, String>(8)?,
        })))?.collect::<rusqlite::Result<Vec<_>>>()?;
        let more = cases.len() > 20;
        cases.truncate(20);
        rule["next_after"] = if more {
            cases[19]["seq"].clone()
        } else {
            Value::Null
        };
        rule["cases"] = json!(cases);
        Ok(rule)
    }
}
