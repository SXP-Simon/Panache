use super::*;

#[test]
fn deleted_continuation_anchor_does_not_restart_the_list() -> Result<()> {
    let home = tempfile::tempdir()?;
    let drafts = Drafts::open(home.path())?;
    let db = drafts.connect()?;
    for n in 1..=21 {
        db.execute(
            "INSERT INTO drafts(id,title,style,revision,chars,sections) VALUES (?1,'same','{}',1,1,1)",
            [format!("d{n}")],
        )?;
    }
    let page = drafts.list(&crate::List {
        offset: None,
        before_draft_id: None,
    })?;
    let id = page["next_before_draft_id"].as_str().unwrap();
    assert_eq!(id, "d2");
    assert_eq!(db.execute("DELETE FROM drafts WHERE id=?1", [id])?, 1);
    let error = drafts
        .list(&crate::List {
            offset: None,
            before_draft_id: Some(id.to_owned()),
        })
        .unwrap_err();
    assert_eq!(error.to_string(), "Unknown before_draft_id");
    Ok(())
}
