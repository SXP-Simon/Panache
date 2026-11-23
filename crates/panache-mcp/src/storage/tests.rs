use super::*;
use std::process::Command;

// Exit inside the registered writer to exercise actual process death and kernel lock release.
#[test]
fn interrupted_writer() -> Result<()> {
    let Some(home) = env::var_os("PANACHE_TEST_CRASH_HOME") else {
        return Ok(());
    };
    let home = PathBuf::from(home);
    let drafts = Drafts::open(&home)?;
    let store = Storage::open(&home, &drafts)?;
    store.export(&drafts, "draft", 1, Format::Zip, |writer| {
        writer.write_all(b"unfinished")?;
        writer.flush()?;
        std::process::exit(23)
    })?;
    unreachable!()
}

#[test]
fn plan_reclaims_only_selected_abandoned_writes() -> Result<()> {
    let dir = tempfile::tempdir()?;
    fs::create_dir(dir.path().join("exports"))?;
    let drafts = Drafts::open(dir.path())?;
    let store = Storage::open(dir.path(), &drafts)?;
    let db = drafts.connect()?;
    db.execute("INSERT INTO drafts VALUES('draft','test','{}',1,0,1)", [])?;
    let historical = drafts.snapshot("draft", Some(1))?;
    let record = historical.record_review(
        1,
        1,
        "a",
        "p",
        "c",
        &json!({"visibility":"inspect_visually"}),
    )?;
    let review_id = record["review_id"].as_str().unwrap();
    drafts.annotate(&crate::ReviewFeedback {
        draft_id: "draft".into(),
        review_id: review_id.into(),
        origin: crate::FeedbackOrigin::UserQuote,
        text: "保留这个墨色".into(),
    })?;
    let old = dir.path().join("exports").join("panache-old.pdf");
    fs::write(&old, b"legacy")?;
    let (delivered, _) = store.export(&drafts, "draft", 1, Format::Pdf, |writer| {
        writer.write_all(b"delivered")?;
        Ok(1)
    })?;
    // Simulate a crash after the final rename but before recording publication.
    db.execute("UPDATE export_files SET published=0 WHERE published=1", [])?;
    let crash = || -> Result<()> {
        let status = Command::new(env::current_exe()?)
            .args(["--exact", "storage::tests::interrupted_writer"])
            .env("PANACHE_TEST_CRASH_HOME", dir.path())
            .status()?;
        ensure!(status.code() == Some(23), "Expected interrupted writer");
        Ok(())
    };
    crash()?;
    let plan = || {
        store.plan_cleanup(
            &drafts,
            CleanupScope {
                draft_id: "draft".into(),
                after_id: None,
            },
        )
    };
    let first = plan()?;
    let eligible = |plan: &Value| -> (String, String) {
        let item = plan["entries"]
            .as_array()
            .unwrap()
            .iter()
            .find(|v| v["class"] == "abandoned_temp")
            .unwrap();
        (
            item["id"].as_str().unwrap().to_string(),
            item["filename"].as_str().unwrap().to_string(),
        )
    };
    let (id, name) = eligible(&first);
    let apply = |plan: &Value, id: &str| {
        store.apply_cleanup(
            &drafts,
            ApplyCleanup {
                plan_id: plan["plan_id"].as_str().unwrap().into(),
                candidate_ids: vec![id.into()],
            },
        )
    };
    let delivered_id = first["entries"]
        .as_array()
        .unwrap()
        .iter()
        .find(|v| v["class"] == "delivered_report_only")
        .unwrap()["id"]
        .as_str()
        .unwrap();
    assert!(apply(&first, delivered_id).is_err());
    let original = store.exports.join(name);
    fs::rename(&original, store.exports.join("moved-by-user"))?;
    fs::write(&original, b"user-owned replacement")?;
    assert_eq!(apply(&first, &id)?["removed_file_bytes"], 0);
    assert_eq!(fs::read(&original)?, b"user-owned replacement");
    crash()?;
    let next = plan()?;
    let (id, _) = eligible(&next);
    let reopened = Storage::open(dir.path(), &drafts)?;
    assert!(
        reopened
            .apply_cleanup(
                &drafts,
                ApplyCleanup {
                    plan_id: next["plan_id"].as_str().unwrap().into(),
                    candidate_ids: vec![id.clone()]
                }
            )
            .is_err()
    );
    let live = store.write_lock()?;
    assert!(store.import(1).is_err());
    assert!(plan().is_err());
    assert!(apply(&next, &id).is_err());
    assert_eq!(
        store.usage(&drafts, Usage { draft_id: None })?["eligible_temp_bytes"],
        0
    );
    drop(live);
    assert_eq!(apply(&next, &id)?["removed_file_bytes"], 10);
    assert_eq!(apply(&next, &id)?["removed_file_bytes"], 0);
    assert_eq!(
        Drafts::open(dir.path())?
            .snapshot("draft", Some(1))?
            .observation(review_id)?["feedback"][0]["text"],
        "保留这个墨色"
    );
    assert_eq!(fs::read(&old)?, b"legacy");
    assert_eq!(fs::read(delivered)?, b"delivered");
    assert_eq!(
        store.usage(&drafts, Usage { draft_id: None })?["home_classes"]["unclassified_export_bytes"],
        38
    );
    Ok(())
}

#[test]
fn budgets_block_heavy_writes_without_publishing_partial_outputs() -> Result<()> {
    let dir = tempfile::tempdir()?;
    fs::create_dir(dir.path().join("exports"))?;
    let drafts = Drafts::open(dir.path())?;
    let mut store = Storage::open(dir.path(), &drafts)?;
    store.policy.min_free_bytes = Some(u64::MAX);
    assert!(store.import(1).is_err());
    let result = store.export(&drafts, "draft", 1, Format::Zip, |w| {
        w.write_all(&[0; 17])?;
        Ok(1)
    });
    assert!(result.is_err());
    assert_eq!(fs::read_dir(&store.exports)?.count(), 0);
    store.policy.min_free_bytes = None;
    store.policy.max_home_bytes = Some(directory_bytes(&store.home)? + 200_000);
    assert!(store.import(300_000).is_err());
    let result = store.export(&drafts, "draft", 1, Format::Zip, |w| {
        w.write_all(&[0; 200])?;
        w.seek(SeekFrom::Start(100))?;
        w.write_all(&[0; 100])?;
        w.write_all(&vec![0; 300_000])?;
        Ok(1)
    });
    assert!(result.is_err());
    assert_eq!(fs::read_dir(&store.exports)?.count(), 0);
    let usage = store.usage(&drafts, Usage { draft_id: None })?;
    assert_eq!(usage["delivered_bytes"], 0);
    Ok(())
}
