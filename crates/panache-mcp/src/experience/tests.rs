use super::*;
use crate::{Style, storage::Storage};
use serde::de::DeserializeOwned;
use tempfile::TempDir;

fn fixture() -> Result<(TempDir, Drafts)> {
    let home = tempfile::tempdir()?;
    std::fs::create_dir(home.path().join("exports"))?;
    let drafts = Drafts::open(home.path())?;
    Storage::open(home.path(), &drafts)?;
    Ok((home, drafts))
}

fn args<T: DeserializeOwned>(data: Value) -> T {
    serde_json::from_value(data).unwrap()
}

fn draft(db: &Drafts, text: &str, pixels: &str) -> Result<Value> {
    let save = args(json!({"markdown":text}));
    let result = db.save(&save, text, Some(&Style::default()), None, None)?;
    let id = result["draft_id"].as_str().unwrap();
    make_case(db, id, 1, pixels)
}

fn make_case(db: &Drafts, id: &str, revision: u32, pixels: &str) -> Result<Value> {
    let check = db.snapshot(id, Some(revision))?.record_review(
        1,
        1,
        "test",
        pixels,
        "content",
        &json!({}),
    )?;
    let export = Uuid::new_v4().to_string();
    db.connect()?.execute("INSERT INTO export_files(id,draft,revision,format,temp_name,identity,published) VALUES(?,?,?,'zip','','',1)",params![export,id,revision])?;
    Ok(
        json!({"draft_id":id,"revision":revision,"export_id":export,"reviews":[{"review_id":check["review_id"],"revision":revision}]}),
    )
}

fn record(case: &Value, tag: &str) -> Value {
    let mut value = case.clone();
    let reviews = value.as_object_mut().unwrap().remove("reviews").unwrap();
    value["rules"] = json!([{"tags":[tag],"scope":"When the last denominator is clipped","action":"Move this formula to a fresh line","reason":"The last digit touches the right edge","reviews":reviews}]);
    value
}

fn validation(id: &Value, case: &Value, kind: &str, passed: bool) -> Validate {
    let mut value = case.clone();
    value["rule_id"] = id.clone();
    value["kind"] = json!(kind);
    value["passed"] = json!(passed);
    value["reason"] = json!("Checked the rightmost denominator and the line below.");
    args(value)
}

fn search(db: &Drafts, tags: Value) -> Result<Value> {
    db.search_experience(args(json!({"tags":tags})))
}

#[test]
fn chinese_bm25_backfills_active_rules_and_tracks_their_lifecycle() -> Result<()> {
    let (home, db) = fixture()?;
    let source = draft(&db, "source", "source")?;
    let positive = draft(&db, "positive", "positive")?;
    let boundary = draft(&db, "boundary", "boundary")?;
    let mut request = record(&source, "math");
    let rule = &mut request["rules"][0];
    rule["scope"] = json!("分母碰到横线时，检查分母与横线间距");
    rule["action"] = json!("上移算式");
    rule["reason"] = json!("分母遮住了数字");
    let mut other = rule.clone();
    other["scope"] = json!("纸页有横线");
    other["reason"] = json!("格内空间充足");
    let mut hidden = other.clone();
    hidden["action"] = json!("绝密待验证的规则");
    request["rules"]
        .as_array_mut()
        .unwrap()
        .extend([other, hidden]);
    let records = db.record_experience(args(request))?;
    let rows = records["rules"].as_array().unwrap();
    for row in &rows[..2] {
        for (case, role) in [(&positive, "positive"), (&boundary, "boundary")] {
            db.validate_experience(validation(&row["rule_id"], case, role, true))?;
        }
    }
    let first = rows[0]["rule_id"].clone();
    let second = rows[1]["rule_id"].clone();
    // Simulate a store created by a release before the FTS index existed.
    db.connect()?.execute_batch("DROP TABLE experience_fts")?;
    let reader = Drafts::open(home.path())?;
    let again = Drafts::open(home.path())?;
    let lookup = |query: Value| reader.search_experience(args(query));
    let prompt = "请把分母与横线之间的间距留出来";
    let found = lookup(json!({"query":prompt}))?;
    assert_eq!(found["rules"].as_array().unwrap().len(), 2);
    assert_eq!(found["rules"][0]["rule_id"], first);
    assert_eq!(found["rules"][1]["rule_id"], second);
    assert_eq!(
        found["rules"][0]["source"]["export_id"],
        source["export_id"]
    );
    assert_eq!(
        lookup(json!({"query":prompt,"tags":["table"]}))?["rules"],
        json!([])
    );
    assert_eq!(lookup(json!({"query":prompt,"tags":["MATH"]}))?, found);
    assert_eq!(
        lookup(json!({"query":prompt,"offset":1}))?["rules"][0]["rule_id"],
        second
    );
    assert_eq!(lookup(json!({"query":"绝密待验证"}))?["rules"], json!([]));
    assert!(lookup(json!({"query":" —— "})).is_err());
    assert!(lookup(json!({"query":"\"分母\" OR (*) -NEAR"})).is_ok());
    again.retire_experience(args(json!({"rule_id":first,"reason":"withdraw"})))?;
    db.validate_experience(validation(
        &second,
        &draft(&db, "bad", "bad")?,
        "boundary",
        false,
    ))?;
    assert_eq!(lookup(json!({"query":prompt}))?["rules"], json!([]));
    assert_eq!(
        db.connect()?
            .query_row("SELECT count(*) FROM experience_fts", [], |r| r
                .get::<_, u32>(0))?,
        0
    );
    Ok(())
}

#[test]
fn only_active_matches_are_visible_and_a_failed_boundary_removes_the_rule() -> Result<()> {
    let (home, db) = fixture()?;
    let source = draft(&db, "source", "source")?;
    let mut req = record(&source, " Formula ");
    req["rules"][0]["tags"] = json!([" Formula ", "ruled-paper"]);
    let positive = draft(&db, "positive", "positive")?;
    let boundary = draft(&db, "boundary", "boundary")?;
    let id = db.record_experience(args(req.clone()))?["rules"][0]["rule_id"].clone();
    let mut req2 = record(&source, "formula");
    req2["rules"][0]["tags"] = json!(["ruled-paper", "formula"]);
    req2["rules"][0]["reason"] = json!("Equivalent observation on the same page");
    assert_eq!(db.record_experience(args(req2))?["rules"][0]["rule_id"], id);
    assert_eq!(
        search(&db, json!(["formula"]))?["available_tags"],
        json!([])
    );
    assert!(
        db.validate_experience(validation(&id, &source, "positive", true))
            .is_err()
    );
    let copy = draft(&db, "copy of source", "source")?;
    assert!(
        db.validate_experience(validation(&id, &copy, "positive", true))
            .is_err()
    );
    assert_eq!(
        db.validate_experience(validation(&id, &positive, "positive", true))?["status"],
        "pending"
    );
    assert!(
        db.validate_experience(validation(&id, &positive, "boundary", true))
            .is_err()
    );
    let duplicate_pixels = draft(&db, "cloned control", "positive")?;
    assert!(
        db.validate_experience(validation(&id, &duplicate_pixels, "boundary", true))
            .is_err()
    );
    let db = Drafts::open(home.path())?;
    assert_eq!(
        db.validate_experience(validation(&id, &boundary, "boundary", true))?["status"],
        "active"
    );
    assert_eq!(
        search(&db, json!([]))?["available_tags"],
        json!(["formula", "ruled-paper"])
    );
    assert_eq!(search(&db, json!(["formula"]))?["rules"], json!([]));
    assert_eq!(search(&db, json!(["table"]))?["rules"], json!([]));
    let result = search(&db, json!(["TABLE", " FORMULA", "ruled-paper"]))?;
    assert_eq!(result["rules"][0]["rule_id"], id);
    let review = &result["rules"][0]["source"]["reviews"][0];
    assert_eq!(
        review["read_section_arguments"]["review_id"],
        source["reviews"][0]["review_id"]
    );
    assert_eq!(review["section"], 1);
    let regressed = draft(&db, "later regression", "regressed")?;
    for _ in 0..2 {
        assert_eq!(
            db.validate_experience(validation(&id, &regressed, "boundary", false))?["status"],
            "rejected"
        );
    }
    assert_eq!(
        search(&db, json!(["formula"]))?["available_tags"],
        json!([])
    );
    assert_eq!(
        db.record_experience(args(req))?["rules"][0]["status"],
        "rejected"
    );
    assert!(
        db.validate_experience(validation(&id, &regressed, "boundary", true))
            .is_err()
    );
    let audit = db.read_experience(args(json!({"rule_id":id})))?;
    assert_eq!(audit["cases"].as_array().unwrap().len(), 4);
    assert_eq!(audit["cases"][3]["passed"], false);
    Ok(())
}

#[test]
fn source_evidence_and_export_must_match_and_a_bad_batch_rolls_back() -> Result<()> {
    let (_home, db) = fixture()?;
    let early = draft(&db, "unfinished", "early")?;
    let id = early["draft_id"].as_str().unwrap();
    let save = args(json!({"draft_id":id,"section":1,"expected_revision":1,"markdown":"repaired"}));
    db.save(&save, "repaired", None, None, None)?;
    let final_case = make_case(&db, id, 2, "final")?;
    let mut req = record(&final_case, "table");
    req["rules"][0]["reviews"]
        .as_array_mut()
        .unwrap()
        .push(early["reviews"][0].clone());
    let mut empty = req.clone();
    empty["rules"] = json!([]);
    assert_eq!(
        db.record_experience(args(empty.clone()))?["rules"],
        json!([])
    );
    empty["export_id"] = early["export_id"].clone();
    assert!(db.record_experience(args(empty)).is_err());
    let deliver = final_case["export_id"].as_str().unwrap();
    db.connect()?
        .execute("UPDATE export_files SET published=0 WHERE id=?", [deliver])?;
    assert!(db.record_experience(args(req.clone())).is_err());
    db.connect()?
        .execute("UPDATE export_files SET published=1 WHERE id=?", [deliver])?;
    let unrelated = draft(&db, "other", "other")?;
    for refs in [
        early["reviews"].clone(),
        unrelated["reviews"].clone(),
        json!([{"revision":2,"review_id":early["reviews"][0]["review_id"]}]),
    ] {
        let mut bad = req.clone();
        let mut bad_rule = bad["rules"][0].clone();
        bad_rule["reviews"] = refs;
        bad["rules"].as_array_mut().unwrap().push(bad_rule);
        assert!(db.record_experience(args(bad)).is_err());
        assert_eq!(
            db.connect()?
                .query_row("SELECT COUNT(*) FROM experience_rules", [], |r| r
                    .get::<_, i64>(0))?,
            0
        );
    }
    let second = json!({"tags":["table","photo"],"scope":"When lines overlap the text","action":"Increase row spacing","reason":"Header overlaps","reviews":final_case["reviews"]});
    req["rules"].as_array_mut().unwrap().push(second);
    let recorded = db.record_experience(args(req))?;
    let rules = recorded["rules"].as_array().unwrap();
    assert_eq!(rules.len(), 2);
    let audit = db.read_experience(args(json!({"rule_id":rules[0]["rule_id"]})))?;
    assert_eq!(audit["cases"][0]["reviews"].as_array().unwrap().len(), 2);
    let retire =
        json!({"rule_id":rules[0]["rule_id"],"reason":"Replaced by revised typography guidance"});
    assert_eq!(
        db.retire_experience(args(retire.clone()))?["status"],
        "retired"
    );
    assert_eq!(db.retire_experience(args(retire))?["status"], "retired");
    assert!(
        db.validate_experience(validation(
            &rules[0]["rule_id"],
            &unrelated,
            "positive",
            true
        ))
        .is_err()
    );
    Ok(())
}

#[test]
fn concurrent_submission_and_validation_are_idempotent() -> Result<()> {
    let (home, db) = fixture()?;
    let source = draft(&db, "source", "source")?;
    let req = record(&source, "glyph");
    let positive = draft(&db, "positive", "positive")?;
    let boundary = draft(&db, "boundary", "boundary")?;
    let path = home.path();
    let ready = std::sync::Barrier::new(4);
    let ids =
        std::thread::scope(|s| {
            let workers =
                (0..4)
                    .map(|idx| {
                        s.spawn({
            let (req,positive,boundary,ready)=(&req,&positive,&boundary,&ready);
            move || -> Result<Value> {
                let drafts=Drafts::open(path)?;
                ready.wait();
                let id=drafts.record_experience(args(req.clone()))?["rules"][0]["rule_id"].clone();
                let (role,sample)=if idx%2==0 {("positive",positive)} else {("boundary",boundary)};
                drafts.validate_experience(validation(&id,sample,role,true))?;
                Ok(id)
            }
        })
                    })
                    .collect::<Vec<_>>();
            workers
                .into_iter()
                .map(|w| w.join().unwrap())
                .collect::<Result<Vec<_>>>()
        })?;
    assert!(ids.iter().all(|id| *id == ids[0]));
    let audit = db.read_experience(args(json!({"rule_id":ids[0]})))?;
    assert_eq!(audit["cases"].as_array().unwrap().len(), 3);
    assert_eq!(audit["status"], "active");
    let note = args(json!({"rule_id":ids[0],"reason":"Stop applying this lesson"}));
    db.retire_experience(note)?;
    assert_eq!(search(&db, json!(["glyph"]))?["available_tags"], json!([]));
    Ok(())
}

#[test]
fn instruction_identity_preserves_case_and_internal_whitespace() -> Result<()> {
    let (_home, db) = fixture()?;
    let source = draft(&db, "unit symbols", "unit pixels")?;
    let mut ids = BTreeSet::new();
    for instruction in [
        r"Use 1 mW and \Delta",
        r"Use 1 MW and \delta",
        r"Use  1 mW and \Delta",
    ] {
        let mut req = record(&source, "Formula");
        req["rules"][0]["action"] = json!(instruction);
        let result = db.record_experience(args(req))?;
        ids.insert(result["rules"][0]["rule_id"].as_str().unwrap().to_owned());
    }
    assert_eq!(ids.len(), 3);
    Ok(())
}
