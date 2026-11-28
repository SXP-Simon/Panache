use super::*;
use crate::{Panache, Preview, preview};
use rmcp::{
    RoleServer,
    model::{CallToolResult, ContentBlock},
    service::RequestContext,
};
use sha2::{Digest, Sha256};

fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

impl Panache {
    pub(crate) async fn rsi_preview(
        &self,
        input: Preview,
        ctx: RequestContext<RoleServer>,
    ) -> Result<CallToolResult> {
        let Some(task_id) = input.rsi_task_id.as_deref() else {
            let prepared = preview::run(self, input, ctx).await?;
            if let preview::Prepared::Ready(result) = prepared {
                return Ok(result);
            }
            let mut db = self.0.drafts.connect()?;
            let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let result = prepared.file(&tx)?;
            tx.commit()?;
            return Ok(result);
        };
        ensure!(
            !self.0.preserve_reviews,
            "此连接保留原有检查记录。查看页面请省略 rsi_task_id；已有整页单据可按 review_id 引用。"
        );
        let revision = input
            .revision
            .context("Specify the candidate revision for task evidence")?;
        let t = task(&self.0.drafts.connect()?, task_id)?;
        ensure!(
            t.status == "active"
                && input.draft_id == t.draft_id
                && t.candidate_revisions.contains(&revision),
            "Preview requires an active task and its exact draft and candidate revision"
        );
        let request = serde_json::to_value(&input)?;
        let prepared = preview::run(self, input, ctx).await?;
        self.0
            .drafts
            .file_task_preview(&t, revision, request, prepared)
    }
}

impl Drafts {
    pub(super) fn file_task_preview(
        &self,
        t: &Task,
        revision: u32,
        request: Value,
        prepared: preview::Prepared,
    ) -> Result<CallToolResult> {
        let images: Vec<_> = prepared
            .content()
            .iter()
            .filter_map(|block| match block {
                ContentBlock::Image(img) => Some(
                    json!({"mime_type":img.mime_type,"base64_sha256":digest(img.data.as_bytes())}),
                ),
                _ => None,
            })
            .collect();
        let mut db = self.connect()?;
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let current = task(&tx, &t.task_id)?;
        ensure!(
            current.step == t.step && current.status == "active",
            "Task advanced while rendering; review the current task"
        );
        let mut result = prepared.file(&tx)?;
        let metadata = result
            .structured_content
            .as_mut()
            .context("Preview did not return evidence")?;
        let mut receipt = json!({"task_id":t.task_id,"step":t.step,"revision":revision,"draft_id":t.draft_id,
            "request":request,"review_id":metadata.get("review_id"),"images":images,
            "metadata_sha256":digest(&serde_json::to_vec(metadata)?)});
        let id = format!("preview-{}", digest(&serde_json::to_vec(&receipt)?));
        receipt["evidence_id"] = json!(id);
        let count: u32 = tx.query_row(
            "SELECT count(*) FROM rsi_previews WHERE task=? AND id<>?",
            params![t.task_id, id],
            |r| r.get(0),
        )?;
        ensure!(
            count < 64,
            "Task preview limit reached; cite the existing evidence or stop"
        );
        tx.execute(
            "INSERT OR IGNORE INTO rsi_previews(id,task,revision,receipt) VALUES(?,?,?,?)",
            params![id, t.task_id, revision, receipt.to_string()],
        )?;
        tx.commit()?;
        metadata["evidence_id"] = json!(id);
        result.content.push(ContentBlock::text(format!(
            "Task preview evidence_id: {id}"
        )));
        Ok(result)
    }
}
