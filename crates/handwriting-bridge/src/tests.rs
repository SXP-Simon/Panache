use crate::{
    api::{Request, Upload, execute},
    handwriting_bridge_call, handwriting_bridge_free,
};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    ffi::{CStr, CString},
    path::PathBuf,
    thread,
    time::Duration,
};

#[test]
fn local_engine_lifecycle_and_abi() {
    let root = tempfile::tempdir().unwrap();
    let font_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../assets/font_assets");
    let call = |command: &str,
                fields: HashMap<String, String>,
                files: HashMap<String, Upload>,
                id: &str| {
        execute(Request {
            command: command.into(),
            data_dir: root.path().into(),
            font_dir: font_dir.clone(),
            fields,
            files,
            task_id: id.into(),
        })
    };
    let simple = |cmd: &str, id: &str| call(cmd, HashMap::new(), HashMap::new(), id);
    simple("reset", "").unwrap();
    assert_eq!(simple("fonts", "").unwrap()[0], "神韵英子楷书.ttf");
    assert_eq!(
        simple("status", "missing").unwrap_err().code,
        "task_not_found"
    );
    let outside = tempfile::NamedTempFile::new().unwrap();
    let files = HashMap::from([(
        "file".into(),
        Upload {
            name: "text.txt".into(),
            path: outside.path().into(),
        },
    )]);
    assert_eq!(
        call("import", HashMap::new(), files, "").unwrap_err().code,
        "invalid_upload"
    );
    let fields: HashMap<String, String> = [
        ("text", "第一页\n---\n第二页"),
        ("width", "420"),
        ("height", "320"),
        ("font_size", "32"),
        ("line_spacing", "45"),
        ("left_margin", "20"),
        ("right_margin", "20"),
        ("top_margin", "20"),
        ("bottom_margin", "20"),
        ("seed", "42"),
    ]
    .into_iter()
    .map(|(k, v)| (k.into(), v.into()))
    .collect();
    let wait = |id: &str| -> Value {
        for _ in 0..600 {
            let state = simple("status", id).unwrap();
            if state["task_status"] != "processing" {
                return state;
            }
            thread::sleep(Duration::from_millis(10));
        }
        panic!("worker timed out")
    };
    for mode in ["preview", "pdf", "zip", "cancel", "invalid"] {
        let mut fields = fields.clone();
        if mode == "pdf" || mode == "zip" {
            fields.insert("preview".into(), "false".into());
            fields.insert("pdf_save".into(), (mode == "pdf").to_string());
        }
        if mode == "cancel" {
            fields.insert("text".into(), "取消\n".repeat(1000));
        }
        if mode == "invalid" {
            fields.insert("width".into(), "1000000".into());
        }
        let submitted = call("submit", fields, HashMap::new(), "").unwrap();
        let id = submitted["task_id"].as_str().unwrap();
        if mode == "cancel" {
            simple("cancel", id).unwrap();
        }
        let state = wait(id);
        match mode {
            "cancel" => {
                assert_eq!(state["task_status"], "cancelled");
                assert!(simple("result", id).is_err());
            }
            "invalid" => assert_eq!(state["task_status"], "failed"),
            "preview" => {
                assert_eq!(state["task_status"], "completed", "{state}");
                assert_eq!(state["pages"].as_array().unwrap().len(), 2);
                let bytes = std::fs::read(state["pages"][0].as_str().unwrap()).unwrap();
                assert_eq!(&bytes[..8], b"\x89PNG\r\n\x1a\n");
            }
            _ => {
                assert_eq!(state["task_status"], "completed", "{state}");
                let bytes = std::fs::read(state["result"].as_str().unwrap()).unwrap();
                assert!(bytes.starts_with(if mode == "pdf" { b"%PDF-" } else { b"PK" }));
            }
        }
    }
    simple("reset", "").unwrap();
    assert!(!root.path().join("tasks").exists());
    for request in [
        "not-json".to_owned(),
        json!({"command":"version", "data_dir":root.path(), "font_dir":font_dir}).to_string(),
    ] {
        let input = CString::new(request).unwrap();
        unsafe {
            let output = handwriting_bridge_call(input.as_ptr());
            let response: Value =
                serde_json::from_slice(CStr::from_ptr(output).to_bytes()).unwrap();
            assert!(response.get("ok").unwrap().is_boolean());
            handwriting_bridge_free(output);
        }
    }
    unsafe {
        let output = handwriting_bridge_call(std::ptr::null());
        let response: Value = serde_json::from_slice(CStr::from_ptr(output).to_bytes()).unwrap();
        assert_eq!(response["code"], "invalid_request");
        handwriting_bridge_free(output);
        handwriting_bridge_free(std::ptr::null_mut());
    }
}
