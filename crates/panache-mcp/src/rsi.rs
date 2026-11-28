//! Host-directed handwriting experiments. All visual judgments remain with the caller.
mod policy;
pub use policy::{PolicyQuery, Publish, Validate};
#[cfg(test)]
mod tests;

use crate::drafts::Drafts;
use anyhow::{Context, Result, ensure};
use policy::Rules;
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::HashSet;
use uuid::Uuid;

pub fn initialize(db: &Connection) -> Result<()> {
    db.execute_batch("
        CREATE TABLE IF NOT EXISTS rsi_tasks (
            id TEXT PRIMARY KEY, state TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS rsi_policies (
            id TEXT PRIMARY KEY, document TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS rsi_validations (
            policy TEXT NOT NULL, report TEXT NOT NULL, UNIQUE(policy,report)
        );
        CREATE TABLE IF NOT EXISTS rsi_previews (
            id TEXT PRIMARY KEY, task TEXT NOT NULL, revision INTEGER NOT NULL, receipt TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS rsi_previews_by_task ON rsi_previews(task,revision);")?;
    policy::seed(db)
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Start {
    pub draft_id: String,
    pub revision: u32,
    /// User's outcome, constraints and acceptance criteria.
    pub objective: String,
    /// Immutable version returned by read_rsi_policy.
    pub policy_id: String,
    /// Name supplied by the host model or external decision provider.
    pub decision_provider: String,
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TaskQuery {
    pub task_id: String,
}

#[derive(Clone, Copy, PartialEq, Eq, Hash, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum EditTool {
    TuneHandwriting,
    AdjustGlyphs,
    SaveSection,
    ReplaceSectionText,
}

#[derive(Clone, Copy, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Action {
    RequestEvidence,
    Revise,
    Select,
    Stop,
}

#[derive(Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Advance {
    pub task_id: String,
    pub expected_step: usize,
    /// Candidate revision to inspect, edit, select or stop on.
    pub revision: u32,
    pub action: Action,
    /// What the evidence shows, what remains uncertain and why this action follows.
    pub reason: String,
    /// Full-page review_id or task-bound preview evidence_id at this exact candidate.
    #[serde(default)]
    pub review_ids: Vec<String>,
    /// Required for revise.
    pub tool: Option<EditTool>,
    /// Required for request_evidence and revise. State what to inspect or change and the expected result.
    pub instruction: Option<String>,
}

#[derive(Serialize, Deserialize)]
pub(super) struct Task {
    task_id: String,
    draft_id: String,
    objective: String,
    decision_provider: String,
    policy_id: String,
    rules: Rules,
    start_revision: u32,
    candidate_revisions: Vec<u32>,
    selected_revision: Option<u32>,
    status: String,
    step: usize,
    decisions: Vec<Decision>,
}

#[derive(Serialize, Deserialize)]
struct Decision {
    decision_id: String,
    #[serde(flatten)]
    input: Advance,
    result_revision: Option<u32>,
}

fn bounded(text: &str, name: &str, max: usize) -> Result<()> {
    ensure!(
        !text.trim().is_empty() && text.chars().count() <= max,
        "{name} must contain 1..{max} characters"
    );
    Ok(())
}

fn distinct(ids: &[String], max: usize) -> Result<()> {
    ensure!(
        ids.len() <= max && ids.iter().collect::<HashSet<_>>().len() == ids.len(),
        "Use at most {max} distinct references"
    );
    Ok(())
}

fn task(db: &Connection, id: &str) -> Result<Task> {
    let data: String = db
        .query_row("SELECT state FROM rsi_tasks WHERE id=?", [id], |r| r.get(0))
        .optional()?
        .context("Unknown RSI task")?;
    Ok(serde_json::from_str(&data)?)
}

fn update(db: &Connection, t: &Task) -> Result<()> {
    db.execute(
        "UPDATE rsi_tasks SET state=? WHERE id=?",
        params![serde_json::to_string(t)?, t.task_id],
    )?;
    Ok(())
}

impl Drafts {
    pub fn start_rsi(&self, input: Start) -> Result<Value> {
        bounded(&input.objective, "objective", 4000)?;
        bounded(&input.decision_provider, "decision_provider", 160)?;
        self.snapshot(&input.draft_id, Some(input.revision))?;
        let db = self.connect()?;
        let rules = policy::load(&db, &input.policy_id)?.rules;
        let state = Task {
            task_id: Uuid::new_v4().to_string(),
            draft_id: input.draft_id,
            start_revision: input.revision,
            candidate_revisions: vec![input.revision],
            objective: input.objective,
            decision_provider: input.decision_provider,
            policy_id: input.policy_id,
            rules,
            selected_revision: None,
            step: 0,
            decisions: Vec::new(),
            status: "active".into(),
        };
        db.execute(
            "INSERT INTO rsi_tasks(id,state) VALUES(?,?)",
            params![state.task_id, serde_json::to_string(&state)?],
        )?;
        Ok(serde_json::to_value(state)?)
    }

    pub fn read_rsi(&self, input: TaskQuery) -> Result<Value> {
        let mut db = self.connect()?;
        let tx = db.transaction()?;
        let mut data = serde_json::to_value(task(&tx, &input.task_id)?)?;
        let mut stmt =
            tx.prepare("SELECT receipt FROM rsi_previews WHERE task=? ORDER BY rowid")?;
        let receipts = stmt
            .query_map([input.task_id], |r| r.get::<_, String>(0))?
            .map(|r| Ok(serde_json::from_str::<Value>(&r?)?))
            .collect::<Result<Vec<_>>>()?;
        data["preview_evidence"] = json!(receipts);
        Ok(data)
    }

    pub fn advance_rsi(&self, input: Advance) -> Result<Value> {
        let mut db = self.connect()?;
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let mut t = task(&tx, &input.task_id)?;
        ensure!(
            t.status == "active" && t.step == input.expected_step,
            "Task is closed or step changed; call read_rsi_task before retrying"
        );
        ensure!(
            t.candidate_revisions.contains(&input.revision),
            "Revision is not a task candidate"
        );
        bounded(&input.reason, "reason", 1600)?;
        let actionable = matches!(input.action, Action::Revise | Action::RequestEvidence);
        ensure!(
            actionable == input.instruction.is_some(),
            "Only revise and request_evidence take instruction"
        );
        if let Some(instruction) = &input.instruction {
            bounded(instruction, "instruction", 1600)?;
        }
        ensure!(
            (input.action == Action::Revise) == input.tool.is_some(),
            "Only revise takes an edit tool"
        );
        ensure!(
            !actionable || t.step + 1 < t.rules.max_steps,
            "Decision budget reached; select a reviewed candidate or stop with the unresolved reason"
        );
        distinct(&input.review_ids, 16)?;
        for id in &input.review_ids {
            let bound: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM review_observations
                 WHERE review_id=?1 AND draft=?2 AND revision=?3) OR EXISTS(SELECT 1 FROM rsi_previews
                 WHERE id=?1 AND task=?4 AND revision=?3)",
                params![id,t.draft_id,input.revision,t.task_id], |r|r.get(0))?;
            ensure!(
                bound,
                "Evidence does not belong to this task draft and candidate revision: {id}"
            );
        }
        if matches!(input.action, Action::Revise | Action::Select) {
            ensure!(
                !input.review_ids.is_empty(),
                "Review this candidate and cite its evidence first"
            );
        }
        if let Some(tool) = input.tool {
            ensure!(
                t.rules.allowed_edit_tools.contains(&tool),
                "Pinned policy does not allow this edit tool"
            );
            let head: u32 = tx.query_row(
                "SELECT revision FROM drafts WHERE id=?",
                [&t.draft_id],
                |r| r.get(0),
            )?;
            ensure!(
                head == input.revision,
                "Edits require the current draft head; select a candidate or stop"
            );
        }
        if input.action == Action::Select {
            if t.rules.compare_before_select {
                ensure!(
                    t.decisions
                        .iter()
                        .any(|d| d.input.revision != input.revision
                            && !d.input.review_ids.is_empty()),
                    "Pinned policy requires evidence for a second candidate before selection"
                );
            }
            t.selected_revision = Some(input.revision);
            t.status = "selected".into();
        }
        if input.action == Action::Stop {
            t.status = "stopped".into();
        }
        t.step += 1;
        t.decisions.push(Decision {
            decision_id: format!("{}/{}", t.task_id, t.step),
            input,
            result_revision: None,
        });
        update(&tx, &t)?;
        tx.commit()?;
        Ok(serde_json::to_value(t)?)
    }
}

/// Called within the existing edit transaction. Unrelated edits can never become task candidates.
pub fn record_edit(
    db: &Connection,
    decision_id: Option<&str>,
    draft: &str,
    next: u32,
    tool: EditTool,
) -> Result<()> {
    let Some(id) = decision_id else { return Ok(()) };
    let (task_id, _) = id.split_once('/').context("Invalid rsi_decision_id")?;
    let mut t = task(db, task_id)?;
    let last = t
        .decisions
        .last_mut()
        .context("Task has no edit decision")?;
    ensure!(
        t.status == "active"
            && t.draft_id == draft
            && last.decision_id == id
            && last.input.action == Action::Revise
            && last.input.tool == Some(tool)
            && last.input.revision.checked_add(1) == Some(next)
            && last.result_revision.is_none(),
        "RSI edit does not match the pending decision, tool, draft or revision"
    );
    last.result_revision = Some(next);
    t.candidate_revisions.push(next);
    update(db, &t)
}

mod evidence;
