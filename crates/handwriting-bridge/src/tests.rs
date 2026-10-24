#[path = "../../handwriting-core/tests/support/images.rs"]
mod image_support;
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
    // 2026-10-24：移动 ABI 必须返回与 HTTP 同源的完整校正图片和排版坐标。
    let paper = image::RgbaImage::from_fn(400, 500, |x, y| {
        let line = (50..420)
            .step_by(60)
            .any(|row| y >= row + x / 20 && y < row + x / 20 + 4);
        let shade = if line && (30..370).contains(&x) {
            220
        } else {
            245
        };
        image::Rgba([shade, shade, shade, 255])
    });
    let paper_path = root.path().join("paper.png");
    paper.save(&paper_path).unwrap();
    let expected =
        handwriting_core::imaging::identify(&image::DynamicImage::ImageRgba8(paper)).unwrap();
    let identified = call(
        "identify",
        HashMap::new(),
        HashMap::from([(
            "file".into(),
            Upload {
                name: "paper.png".into(),
                path: paper_path,
            },
        )]),
        "",
    )
    .unwrap();
    assert_eq!(identified, serde_json::to_value(&expected).unwrap());
    assert!(identified["correctedBackground"].as_str().unwrap().len() > 100);
    assert_eq!(identified["lineSpacing"], 60);
    let fields: HashMap<String, String> = [
        (
            "text",
            "第一页 √((a)/(b)) + xₙ²\n---\n第二页 ((a)/(b))/((c)/(d)) + (AB)⃗",
        ),
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
    for mode in [
        "preview",
        "math",
        "image",
        "text_limit",
        "pdf",
        "zip",
        "cancel",
        "invalid",
    ] {
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
        if mode == "image" {
            fields.insert("text".into(), image_support::image_document());
        }
        if mode == "text_limit" {
            fields.insert("text".into(), "字".repeat(20_001));
        }
        // 2026-10-15：公式经移动端同一 C ABI 进入真实 worker，不只测试直接 Rust 函数。
        let submitted = if mode == "math" || mode == "image" {
            if mode == "math" {
                fields.insert(
                    "text".into(),
                    "√((a)/(b)) + xₙ²\n---\n((a)/(b))/((c)/(d)) + (AB)⃗".into(),
                );
            }
            let input = CString::new(
                json!({
                    "command":"submit", "data_dir":root.path(), "font_dir":font_dir,
                    "fields":fields
                })
                .to_string(),
            )
            .unwrap();
            let response: Value = unsafe {
                let output = handwriting_bridge_call(input.as_ptr());
                let response = serde_json::from_slice(CStr::from_ptr(output).to_bytes()).unwrap();
                handwriting_bridge_free(output);
                response
            };
            assert_eq!(response["ok"], true, "{response}");
            response["data"].clone()
        } else {
            call("submit", fields, HashMap::new(), "").unwrap()
        };
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
            "text_limit" => {
                assert_eq!(state["task_status"], "failed");
                assert!(
                    state["error_message"]
                        .as_str()
                        .unwrap()
                        .contains("文本过长")
                );
            }
            "invalid" => assert_eq!(state["task_status"], "failed"),
            "preview" | "math" | "image" => {
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
