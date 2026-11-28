use super::*;
use crate::{Save, Style};

fn save(drafts: &Drafts, args: Value) -> Result<Value> {
    let input: Save = serde_json::from_value(args)?;
    let style = input.draft_id.is_none().then(Style::default);
    drafts.save(&input, &input.markdown, style.as_ref(), None, None)
}

fn create(drafts: &Drafts) -> Result<String> {
    Ok(save(drafts, json!({"markdown":"One."}))?["draft_id"]
        .as_str()
        .unwrap()
        .to_owned())
}

fn start(drafts: &Drafts, draft: &str, policy: &str) -> Result<String> {
    let t=drafts.start_rsi(serde_json::from_value(json!({
        "draft_id":draft,"revision":1,"objective":"Keep the title legible.","decision_provider":"test fixture","policy_id":policy
    }))?)?;
    Ok(t["task_id"].as_str().unwrap().to_owned())
}

fn receipt(drafts: &Drafts, id: &str, revision: u32) -> Result<String> {
    let r = drafts.snapshot(id, Some(revision))?.record_review(
        1,
        1,
        "test",
        "pixels",
        "content",
        &json!({}),
    )?;
    Ok(r["review_id"].as_str().unwrap().to_owned())
}

fn decide(
    d: &Drafts,
    id: &str,
    step: usize,
    revision: u32,
    action: &str,
    ids: &[&str],
) -> Result<Value> {
    let mut input = json!({"task_id":id,"expected_step":step,"revision":revision,"action":action,"review_ids":ids,"reason":"Observed title contrast."});
    if action == "revise" {
        input["tool"] = json!("save_section");
        input["instruction"] = json!("Revise title.");
    } else if action == "request_evidence" {
        input["instruction"] = json!("Inspect the title crop.");
    }
    d.advance_rsi(serde_json::from_value(input)?)
}

#[test]
fn task_links_edits_and_evidence_to_the_exact_revision_and_survives_restart() -> Result<()> {
    let home = tempfile::tempdir()?;
    let d = Drafts::open(home.path())?;
    let id = create(&d)?;
    let other = create(&d)?;
    let t = start(&d, &id, "pilot-v1")?;
    let first = receipt(&d, &id, 1)?;
    let alien = receipt(&d, &other, 1)?;
    assert!(decide(&d, &t, 0, 1, "revise", &[&alien]).is_err());
    assert!(decide(&d, &t, 0, 1, "select", &[]).is_err());
    let plan = decide(&d, &t, 0, 1, "revise", &[&first])?;
    let token = &plan["decisions"][0]["decision_id"];
    assert!(decide(&d, &t, 0, 1, "stop", &[]).is_err());
    let args = json!({"draft_id":other,"expected_revision":1,"markdown":"Wrong draft","rsi_decision_id":token});
    assert!(save(&d, args).is_err());
    assert_eq!(d.snapshot(&other, None)?.latest_revision, 1);
    let wrong = d.snapshot(&id, None)?;
    assert!(
        d.tune(
            &wrong,
            &wrong.controls,
            true,
            None,
            None,
            &json!({"rsi_decision_id":token})
        )
        .is_err()
    );
    assert_eq!(d.snapshot(&id, None)?.latest_revision, 1);
    let args =
        json!({"draft_id":id,"expected_revision":1,"markdown":"Candidate","rsi_decision_id":token});
    assert_eq!(save(&d, args)?["revision"], 2);
    assert!(decide(&d, &t, 1, 2, "select", &[&first]).is_err());
    let second = receipt(&d, &id, 2)?;
    decide(&d, &t, 1, 2, "request_evidence", &[&second])?;
    let reopened = Drafts::open(home.path())?;
    let selected = decide(&reopened, &t, 2, 1, "select", &[&first])?;
    assert_eq!(selected["candidate_revisions"], json!([1, 2]));
    assert_eq!(selected["decisions"][0]["result_revision"], 2);
    assert_eq!(selected["selected_revision"], 1);
    assert!(decide(&d, &t, 3, 2, "select", &[&second]).is_err());
    Ok(())
}

#[test]
fn policies_pin_rules_bound_work_and_validate_on_separate_drafts() -> Result<()> {
    let home = tempfile::tempdir()?;
    let d = Drafts::open(home.path())?;
    let source = create(&d)?;
    let train = start(&d, &source, "pilot-v1")?;
    let reference = receipt(&d, &source, 1)?;
    decide(&d, &train, 0, 1, "select", &[&reference])?;
    let seed = d.read_rsi_policy(PolicyQuery {
        policy_id: Some("pilot-v1".into()),
        include_evidence_guide: false,
        evidence_guide_version: None,
    })?;
    let mut rules = seed["rules"].clone();
    rules["max_steps"] = json!(2);
    rules["compare_before_select"] = json!(true);
    rules["allowed_edit_tools"] = json!(["tune_handwriting"]);
    let policy = json!({"policy_id":"example-v2","parent_policy_id":"pilot-v1","source_task_ids":[train],"rules":rules});
    d.publish_rsi_policy(serde_json::from_value(policy.clone())?)?;
    assert!(
        d.publish_rsi_policy(serde_json::from_value(policy)?)
            .is_err()
    );
    let evaluation = create(&d)?;
    let t = start(&d, &evaluation, "example-v2")?;
    let review = receipt(&d, &evaluation, 1)?;
    assert!(decide(&d, &t, 0, 1, "select", &[&review]).is_err());
    assert!(decide(&d, &t, 0, 1, "revise", &[&review]).is_err());
    decide(&d, &t, 0, 1, "request_evidence", &[&review])?;
    assert!(decide(&d, &t, 1, 1, "request_evidence", &[]).is_err());
    decide(&d, &t, 1, 1, "stop", &[])?;
    let validate = |ids: Value| -> Result<Value> {
        d.validate_rsi_policy(serde_json::from_value(json!({
        "policy_id":"example-v2","task_ids":ids,"conclusion":"Stopped at the budget with one reviewed candidate."
    }))?)
    };
    assert!(validate(json!([train])).is_err());
    let reused = start(&d, &source, "example-v2")?;
    decide(&d, &reused, 0, 1, "stop", &[&reference])?;
    assert!(validate(json!([reused])).is_err());
    validate(json!([t]))?;
    let report = d.read_rsi_policy(PolicyQuery {
        policy_id: Some("example-v2".into()),
        include_evidence_guide: false,
        evidence_guide_version: None,
    })?;
    assert_eq!(report["recent_validations"][0]["task_ids"], json!([t]));
    assert_eq!(
        d.read_rsi(TaskQuery { task_id: train })?["rules"],
        seed["rules"]
    );
    Ok(())
}

#[test]
fn evidence_guide_is_discoverable_and_independent_of_stored_rules() -> Result<()> {
    let home = tempfile::tempdir()?;
    let drafts = Drafts::open(home.path())?;
    let read = |args| drafts.read_rsi_policy(serde_json::from_value(args)?);
    let mut list = read(json!({"include_evidence_guide":true}))?;
    let guide = list
        .as_object_mut()
        .unwrap()
        .remove("evidence_guide")
        .unwrap();
    assert_eq!(list, read(json!({}))?);
    let mut pinned = read(json!({"policy_id":"pilot-v1","include_evidence_guide":true}))?;
    assert_eq!(
        pinned.as_object_mut().unwrap().remove("evidence_guide"),
        Some(guide.clone())
    );
    assert_eq!(
        pinned,
        read(json!({"policy_id":"pilot-v1","include_evidence_guide":false}))?
    );
    assert_eq!(guide["version"], "paper-homework/2");
    let old = read(json!({"evidence_guide_version":"paper-homework/1"}))?;
    assert_eq!(old["evidence_guide"]["version"], "paper-homework/1");
    assert!(
        old["evidence_guide"]["checks"]
            .get("formula_rendering")
            .is_none()
    );
    assert!(read(json!({"evidence_guide_version":"unknown"})).is_err());
    for name in [
        "paper_and_rulings",
        "focus_and_contrast",
        "pages_and_delivery",
        "table_cells",
        "diagram_branches",
        "formula_rendering",
        "mixed_content_projection",
    ] {
        let check = &guide["checks"][name];
        assert!(!check["sources"].as_array().unwrap().is_empty());
        assert!(!check["limits"].as_str().unwrap().is_empty());
        for call in check["calls"].as_array().unwrap() {
            let mut args = call["arguments"].clone();
            args["draft_id"] = json!("example");
            args["revision"] = json!(1);
            if call.get("region_from").is_some() {
                args["region"] = json!([[1, 1], [40, 1], [40, 20], [1, 20]]);
            }
            match call["tool"].as_str().unwrap() {
                "preview_handwriting" => {
                    serde_json::from_value::<crate::Preview>(args)?;
                }
                "read_section" => {
                    serde_json::from_value::<crate::Read>(args)?;
                }
                "export_handwriting" => {
                    serde_json::from_value::<crate::Export>(args)?;
                }
                other => panic!("Unknown guide tool {other}"),
            }
        }
    }
    Ok(())
}

#[test]
fn full_page_and_task_receipt_commit_together_at_capacity_or_after_close() -> Result<()> {
    use base64::{Engine as _, engine::general_purpose::STANDARD};
    let home = tempfile::tempdir()?;
    let drafts = Drafts::open(home.path())?;
    let id = create(&drafts)?;
    let task_id = start(&drafts, &id, "pilot-v1")?;
    let snapshot = drafts.snapshot(&id, Some(1))?;
    let t = task(&drafts.connect()?, &task_id)?;
    let prepared = |color| -> Result<crate::preview::Prepared> {
        let image = image::RgbaImage::from_pixel(240, 320, image::Rgba([color, color, color, 255]));
        let png = STANDARD.encode(handwriting_core::export::png(&image)?);
        let sample = crate::review::PageSample {
            table_candidates: Vec::new(),
            baselines: vec![],
            text: vec![],
            drawings: vec![],
            content_sha256: "sample".into(),
        };
        crate::review::page(
            &snapshot,
            1,
            1,
            &png,
            &sample,
            &crate::paper::focus::Cache::default(),
            &handwriting_core::Cancellation::default(),
        )
        .map(crate::preview::Prepared::FullPage)
    };
    let request = json!({"draft_id":id,"revision":1,"view":"review","rsi_task_id":task_id});
    let file = |page| drafts.file_task_preview(&t, 1, request.clone(), page);
    let counts = || -> Result<(u32, u32)> {
        Ok(drafts.connect()?.query_row("SELECT (SELECT count(*) FROM review_observations), (SELECT count(*) FROM rsi_previews)",[],|r| Ok((r.get(0)?,r.get(1)?)))?)
    };
    let db = drafts.connect()?;
    for i in 0..63 {
        db.execute(
            "INSERT INTO rsi_previews(id,task,revision,receipt) VALUES(?,?,1,'{}')",
            params![format!("other-{i}"), task_id],
        )?;
    }
    let first = file(prepared(255)?)?.structured_content.unwrap();
    assert_eq!(counts()?, (1, 64));
    let replay = file(prepared(255)?)?.structured_content.unwrap();
    assert_eq!(first, replay);
    assert_eq!(counts()?, (1, 64));

    let denied = file(prepared(240)?).unwrap_err();
    assert!(denied.to_string().contains("preview limit"));
    assert_eq!(counts()?, (1, 64));

    let in_flight = prepared(230)?;
    let review_id = first["review_id"].as_str().unwrap();
    decide(&drafts, &task_id, 0, 1, "select", &[review_id])?;
    let closed = file(in_flight).unwrap_err();
    assert!(closed.to_string().contains("Task advanced"));
    assert_eq!(counts()?, (1, 64));
    assert_eq!(
        snapshot.page_observation(1, 1, false)?["review_id"],
        review_id
    );
    Ok(())
}
