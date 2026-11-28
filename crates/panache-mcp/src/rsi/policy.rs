use super::*;

#[derive(Clone, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Rules {
    /// How the host executes a candidate edit.
    pub execution: String,
    /// What to measure and which visual evidence to inspect.
    pub review: String,
    /// How the host chooses between reviewed candidate revisions.
    pub selection: String,
    /// Which uncertainty and experiment to prioritize next.
    pub experiment: String,
    /// Total decisions per task including its final select or stop.
    pub max_steps: usize,
    pub allowed_edit_tools: Vec<EditTool>,
    pub compare_before_select: bool,
}

#[derive(Deserialize, Serialize)]
pub(super) struct Policy {
    policy_id: String,
    parent_policy_id: Option<String>,
    source_task_ids: Vec<String>,
    pub(super) rules: Rules,
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Publish {
    pub policy_id: String,
    pub parent_policy_id: String,
    /// Closed tasks on the parent policy whose evidence motivated the change.
    pub source_task_ids: Vec<String>,
    pub rules: Rules,
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PolicyQuery {
    /// Omit to list recent versions. Use the exact ID to read a pinned document.
    pub policy_id: Option<String>,
    /// Include the versioned evidence guide alongside the list or policy document.
    #[serde(default)]
    pub include_evidence_guide: bool,
}

#[derive(Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Validate {
    pub policy_id: String,
    /// Completed tasks using this version on drafts distinct from its source tasks.
    pub task_ids: Vec<String>,
    /// Host-reported outcome including failures, metrics and limitations.
    pub conclusion: String,
}

pub(super) fn seed(db: &Connection) -> Result<()> {
    let policy = Policy { policy_id: "pilot-v1".into(), parent_policy_id: None, source_task_ids: vec![],
        rules: Rules {
            execution: "Use one existing editing tool per decision. Preserve the supplied content, paper and requested placement.".into(),
            review: "Inspect the rendered candidate against the objective. Cite a full-page check or task-bound preview at the same revision.".into(),
            selection: "Select the candidate that best satisfies the objective; stop with the unresolved reason if none qualifies.".into(),
            experiment: "Choose a small reversible change that tests an observed problem. Request evidence first when the next edit is unclear.".into(),
            max_steps: 8, allowed_edit_tools: vec![EditTool::TuneHandwriting, EditTool::AdjustGlyphs, EditTool::SaveSection, EditTool::ReplaceSectionText],
            compare_before_select: false
        }
    };
    db.execute(
        "INSERT OR IGNORE INTO rsi_policies(id,document) VALUES(?,?)",
        params![policy.policy_id, serde_json::to_string(&policy)?],
    )?;
    Ok(())
}

pub(super) fn load(db: &Connection, id: &str) -> Result<Policy> {
    let s: String = db
        .query_row("SELECT document FROM rsi_policies WHERE id=?", [id], |r| {
            r.get(0)
        })
        .optional()?
        .context("Unknown policy; use read_rsi_policy to list versions")?;
    Ok(serde_json::from_str(&s)?)
}

impl Drafts {
    pub fn read_rsi_policy(&self, input: PolicyQuery) -> Result<Value> {
        let mut result = self.policy_and_reports(input.policy_id)?;
        if input.include_evidence_guide {
            result["evidence_guide"] =
                serde_json::from_str(include_str!("../../evidence-guide-v1.json"))?;
        }
        Ok(result)
    }

    fn policy_and_reports(&self, policy_id: Option<String>) -> Result<Value> {
        let db = self.connect()?;
        let Some(id) = policy_id else {
            let mut stmt =
                db.prepare("SELECT id FROM rsi_policies ORDER BY rowid DESC LIMIT 50")?;
            let ids = stmt
                .query_map([], |r| r.get::<_, String>(0))?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            return Ok(json!({"recent_policy_ids":ids,"seed_policy_id":"pilot-v1"}));
        };
        let mut result = serde_json::to_value(load(&db, &id)?)?;
        let mut stmt = db.prepare(
            "SELECT report FROM rsi_validations WHERE policy=? ORDER BY rowid DESC LIMIT 20",
        )?;
        let reports = stmt
            .query_map([id], |r| r.get::<_, String>(0))?
            .map(|r| Ok(serde_json::from_str::<Value>(&r?)?))
            .collect::<Result<Vec<_>>>()?;
        result["recent_validations"] = json!(reports);
        Ok(result)
    }

    pub fn publish_rsi_policy(&self, input: Publish) -> Result<Value> {
        bounded(&input.policy_id, "policy_id", 80)?;
        ensure!(
            input
                .policy_id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b)),
            "Use an alphanumeric version ID with hyphen, underscore or dot"
        );
        distinct(&input.source_task_ids, 16)?;
        ensure!(
            !input.source_task_ids.is_empty(),
            "Cite at least one completed source task"
        );
        let rules = &input.rules;
        for text in [
            &rules.execution,
            &rules.review,
            &rules.selection,
            &rules.experiment,
        ] {
            bounded(text, "policy rule", 1600)?;
        }
        ensure!(
            (2..=16).contains(&rules.max_steps),
            "max_steps must be 2..16"
        );
        ensure!(
            rules
                .allowed_edit_tools
                .iter()
                .collect::<HashSet<_>>()
                .len()
                == rules.allowed_edit_tools.len(),
            "Duplicate edit tool"
        );
        let mut db = self.connect()?;
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let parent = load(&tx, &input.parent_policy_id)?;
        ensure!(
            parent.rules != input.rules,
            "Change a rule to publish a new version"
        );
        for id in &input.source_task_ids {
            let t = task(&tx, id)?;
            ensure!(
                t.status != "active"
                    && t.policy_id == parent.policy_id
                    && t.decisions.iter().any(|d| !d.input.review_ids.is_empty()),
                "Source tasks must be closed, cite evidence, and use the named parent policy"
            );
        }
        let policy = Policy {
            policy_id: input.policy_id,
            parent_policy_id: Some(input.parent_policy_id),
            source_task_ids: input.source_task_ids,
            rules: input.rules,
        };
        ensure!(
            tx.execute(
                "INSERT INTO rsi_policies(id,document) VALUES(?,?) ON CONFLICT(id) DO NOTHING",
                params![policy.policy_id, serde_json::to_string(&policy)?]
            )? == 1,
            "Policy version already exists and is immutable"
        );
        tx.commit()?;
        Ok(serde_json::to_value(policy)?)
    }

    pub fn validate_rsi_policy(&self, input: Validate) -> Result<Value> {
        distinct(&input.task_ids, 16)?;
        ensure!(
            !input.task_ids.is_empty(),
            "Cite at least one validation task"
        );
        bounded(&input.conclusion, "conclusion", 3000)?;
        let db = self.connect()?;
        let mut version = load(&db, &input.policy_id)?;
        // Keep development drafts out of subsequent generations' validation sets as well.
        let mut source_drafts = HashSet::new();
        loop {
            for id in version.source_task_ids {
                source_drafts.insert(task(&db, &id)?.draft_id);
            }
            let Some(parent) = version.parent_policy_id else {
                break;
            };
            version = load(&db, &parent)?;
        }
        for id in &input.task_ids {
            let t = task(&db, id)?;
            ensure!(
                t.status != "active"
                    && t.policy_id == input.policy_id
                    && !source_drafts.contains(&t.draft_id)
                    && t.decisions.iter().any(|d| !d.input.review_ids.is_empty()),
                "Validation requires closed tasks with evidence on this version, using distinct evaluation drafts"
            );
        }
        let report =
            json!({"origin":"host_report","task_ids":input.task_ids,"conclusion":input.conclusion});
        db.execute(
            "INSERT OR IGNORE INTO rsi_validations(policy,report) VALUES(?,?)",
            params![input.policy_id, report.to_string()],
        )?;
        Ok(report)
    }
}
