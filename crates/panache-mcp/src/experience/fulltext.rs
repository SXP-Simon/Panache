use anyhow::{Result, ensure};
use rusqlite::{Connection, params};
use std::collections::BTreeSet;

// 汉字用重叠双字词元，避免整句被 unicode61 当成一个词；拉丁文字和数字按词保留。
fn is_han(c: char) -> bool {
    matches!(c as u32, 0x3400..=0x4dbf | 0x4e00..=0x9fff | 0xf900..=0xfaff | 0x20000..=0x2fa1f | 0x30000..=0x323af)
}

fn tokens(text: &str) -> Vec<String> {
    let mut result = Vec::new();
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if is_han(c) {
            let mut previous = c;
            let mut single = true;
            while let Some(next) = chars.next_if(|v| is_han(*v)) {
                result.push(format!("{previous}{next}"));
                previous = next;
                single = false;
            }
            if single {
                result.push(c.to_string());
            }
        } else if c.is_alphanumeric() {
            let mut word = String::from(c);
            while let Some(next) = chars.next_if(|v| v.is_alphanumeric() && !is_han(*v)) {
                word.push(next);
            }
            result.push(word.to_lowercase());
        }
    }
    result
}

pub(super) fn expression(text: &str) -> Result<String> {
    super::bounded(text, "query", 1200)?;
    let terms: BTreeSet<_> = tokens(text).into_iter().collect();
    ensure!(
        !terms.is_empty(),
        "Supply words in the homework description"
    );
    Ok(terms
        .into_iter()
        .map(|term| format!("\"{term}\""))
        .collect::<Vec<_>>()
        .join(" OR "))
}

pub(super) fn initialize(db: &Connection) -> Result<()> {
    if db.table_exists(None, "experience_fts")? {
        return Ok(());
    }
    db.execute_batch("CREATE VIRTUAL TABLE experience_fts USING fts5(rule_id UNINDEXED, scope, action, reason, tokenize='unicode61')")?;
    let mut active = db.prepare("SELECT id FROM experience_rules WHERE status='active'")?;
    for id in active.query_map([], |row| row.get::<_, String>(0))? {
        insert(db, &id?)?;
    }
    Ok(())
}

pub(super) fn insert(db: &Connection, id: &str) -> Result<()> {
    let (scope, action, reason) = db.query_row(
        "SELECT scope,action,reason FROM experience_rules WHERE id=?",
        [id],
        |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
            ))
        },
    )?;
    db.execute(
        "INSERT INTO experience_fts(rule_id,scope,action,reason) VALUES(?,?,?,?)",
        params![
            id,
            tokens(&scope).join(" "),
            tokens(&action).join(" "),
            tokens(&reason).join(" ")
        ],
    )?;
    Ok(())
}

pub(super) fn remove(db: &Connection, id: &str) -> Result<()> {
    db.execute("DELETE FROM experience_fts WHERE rule_id=?", [id])?;
    Ok(())
}
