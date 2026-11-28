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
    })?;
    assert_eq!(report["recent_validations"][0]["task_ids"], json!([t]));
    assert_eq!(
        d.read_rsi(TaskQuery { task_id: train })?["rules"],
        seed["rules"]
    );
    Ok(())
}
