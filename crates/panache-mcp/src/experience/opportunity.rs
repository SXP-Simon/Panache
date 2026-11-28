use super::{Drafts, Result, Value, json, json_column};
use rusqlite::OptionalExtension;

impl Drafts {
    pub(crate) fn validation_opportunity(
        &self,
        draft_id: &str,
        revision: u32,
        export_id: &str,
        pages: &[Value],
    ) -> Result<Option<Value>> {
        let db = self.connect()?;
        // 2026-11-28：只从已经导出的作业找验证机会，候选不进入普通全文索引。
        let query = "
            WITH pages AS (
                SELECT value AS data,
                    EXISTS (
                        SELECT 1 FROM review_observations prev
                        WHERE prev.review_id=json_extract(value,'$.earlier_reference.review_id')
                        AND prev.draft=:draft AND prev.filed_at_revision=prev.revision
                        AND prev.pixel_sha256<>json_extract(value,'$.pixel_sha256')
                    ) AS changed
                FROM json_each(:pages)
            ),
            eligible AS (
                SELECT r.id, p.data,
                    NOT EXISTS (SELECT 1 FROM experience_cases
                        WHERE rule_id=r.id AND role='positive' AND passed=1) AS needs_positive,
                    NOT EXISTS (SELECT 1 FROM experience_cases
                        WHERE rule_id=r.id AND role='boundary' AND passed=1) AS needs_boundary,
                    p.changed,
                    (SELECT count(*) FROM experience_tags WHERE rule_id=r.id AND tag<>'homework') AS specificity
                FROM pages p JOIN experience_rules r ON r.status='pending'
                WHERE EXISTS (
                    SELECT 1 FROM export_files WHERE id=:export AND published=1
                    AND draft=:draft AND revision=:revision
                )
                AND NOT EXISTS (
                    SELECT 1 FROM experience_tags t WHERE t.rule_id=r.id
                    AND t.tag NOT IN (SELECT value FROM json_each(p.data,'$.tags'))
                )
                AND NOT EXISTS (
                    SELECT 1 FROM experience_cases c WHERE c.rule_id=r.id AND (
                        c.draft=:draft OR EXISTS (
                            SELECT 1 FROM json_each(c.reviews) old JOIN pages final
                              ON json_extract(old.value,'$.pixel_sha256')=json_extract(final.data,'$.pixel_sha256')
                            WHERE json_extract(old.value,'$.revision')=c.revision
                        )
                    )
                )
            )
            SELECT id, data, needs_positive AND changed, needs_boundary,
                (SELECT json_group_array(tag) FROM experience_tags WHERE rule_id=eligible.id)
            FROM eligible
            WHERE specificity>0 AND (needs_boundary OR (needs_positive AND changed))
            ORDER BY (needs_positive + needs_boundary), (needs_positive AND changed) DESC,
                specificity DESC, id, json_extract(data,'$.section'), json_extract(data,'$.page')
            LIMIT 1";
        let pages = serde_json::to_string(pages)?;
        let selected = db.query_row(query, rusqlite::named_params! {
            ":draft": draft_id, ":revision": revision, ":export": export_id, ":pages": pages,
        }, |row| {
            Ok((
                row.get::<_, String>(0)?,
                json_column(row, 1)?,
                row.get::<_, bool>(2)?,
                row.get::<_, bool>(3)?,
                json_column(row, 4)?,
            ))
        }).optional()?;
        Ok(selected.map(|(id, page, positive, boundary, tags)| {
            let mut kinds = Vec::new();
            let mut reviews = vec![page["reference"].clone()];
            if positive {
                kinds.push("positive");
                reviews.push(page["earlier_reference"].clone());
            }
            if boundary {
                kinds.push("boundary");
            }
            json!({
                "status":"pending", "optional":true, "matched_tags":tags,
                "read_candidate":{"tool":"read_homework_experience","arguments":{"rule_id":id}},
                "validation":{
                    "tool":"validate_homework_experience", "possible_kinds":kinds,
                    "evidence":{"draft_id":draft_id,"revision":revision,"export_id":export_id,
                        "section":page["section"],"page":page["page"],"reviews":reviews}
                },
                "guidance":"按原样交付已选文件。可以读取这条候选，判断本次已有记录能否独立验证它。正例要看到相同做法已经解决了问题；边界例要看到同类但原本正确或条件不适用的内容本来就应保留。只有确实观察到收益、无误伤或反例才提交，对照不足或不适用就跳过。填写 kind、passed、reason，并引用当前导出和相关检查单。无需为验证改稿、补看页面或重新导出。"
            })
        }))
    }
}
