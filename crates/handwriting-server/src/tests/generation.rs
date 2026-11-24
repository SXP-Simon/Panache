use super::*;
use handwriting_core::export;

#[tokio::test]
async fn photo_payload_is_accepted_but_body_limit_is_preserved() {
    let (_dir, s) = setup();
    let document = image_support::image_document();
    let id = generate(&s, &[("text", &document)]).await;
    let (status, bytes) = call(&s, &format!("/api/generate_handwriting/task/{id}/result")).await;
    assert_eq!(status, StatusCode::OK);
    assert!(!bytes.is_empty());
    let (status, error) = send(
        &s,
        "/api/generate_handwriting",
        &[("text", &"字".repeat(100_001))],
        None,
    )
    .await;
    assert_eq!(status, StatusCode::PAYLOAD_TOO_LARGE);
    assert_eq!(error["error_code"], "text_limit");
}

#[tokio::test]
async fn real_generation_preview_pdf_zip_and_idempotent_download() {
    let (_dir, s) = setup();
    for (extra, content_type, attachment) in [
        (
            vec![("preview", "true"), ("full_preview", "false")],
            "image/png",
            None,
        ),
        (
            vec![("preview", "true"), ("full_preview", "true")],
            "application/json",
            None,
        ),
        (
            vec![
                ("preview", "true"),
                ("full_preview", "false"),
                ("ink_layers", "true"),
            ],
            "application/json",
            None,
        ),
        (
            vec![("pdf_save", "true")],
            "application/pdf",
            Some("attachment; filename=images.pdf"),
        ),
        (
            vec![("preview", "false")],
            "application/zip",
            Some("attachment; filename=images.zip"),
        ),
    ] {
        let id = generate(&s, &extra).await;
        let (_, state) = call(&s, &format!("/api/generate_handwriting/task/{id}")).await;
        let state: serde_json::Value = serde_json::from_slice(&state).unwrap();
        assert_eq!(state["task_stage"], "completed");
        assert_eq!(
            state["pages_completed"],
            if extra.contains(&("full_preview", "false")) {
                1
            } else {
                2
            }
        );
        let path = format!("/api/generate_handwriting/task/{id}/result");
        let response = s
            .router()
            .oneshot(Request::builder().uri(&path).body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(response.headers()["content-type"], content_type);
        assert_eq!(
            header(response.headers(), "content-disposition"),
            attachment
        );
        let bytes = axum::body::to_bytes(response.into_body(), 32 * 1024 * 1024)
            .await
            .unwrap();
        assert_eq!(bytes.as_ref(), call(&s, &path).await.1.as_slice());
        if extra.contains(&("pdf_save", "true")) {
            assert!(bytes.starts_with(b"%PDF-"));
        } else if extra.contains(&("preview", "false")) {
            assert!(bytes.starts_with(b"PK"));
        } else if extra.contains(&("ink_layers", "true")) {
            let data: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
            let layers = data["layers"].as_array().unwrap();
            assert_eq!(layers.len(), 1);
            for kind in ["paper", "ink"] {
                assert!(layers[0][kind].as_str().unwrap().starts_with("iVBORw0KGgo"));
            }
        } else if extra.contains(&("full_preview", "false")) {
            assert!(bytes.starts_with(b"\x89PNG"));
        } else {
            let data: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
            assert_eq!(data["images"].as_array().unwrap().len(), 2);
        }
    }
}

#[tokio::test]
async fn imports_selected_pdf_page() {
    let (_dir, s) = setup();
    let mut pdf = export::PdfExport::new();
    pdf.add(&image_for_test()).unwrap();
    let bytes = pdf.finish();
    let (status, data) = send(
        &s,
        "/api/pdfpageprocess",
        &[("pageIndex", "0"), ("mode", "fill")],
        Some(("file", "paper.pdf", &bytes)),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{data}");
    assert_eq!(data["pageCount"], 1);
    assert_eq!(data["pageIndex"], 0);
    assert!(data["backgroundPng"].as_str().unwrap().starts_with("iVBOR"));
    let (status, data) = send(
        &s,
        "/api/pdfpageprocess",
        &[("pageIndex", "1")],
        Some(("file", "paper.pdf", &bytes)),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(data["error_code"], "invalid_parameter");
}

#[tokio::test]
async fn uploads_text_and_background_identification() {
    let (_dir, s) = setup();
    let (status, data) = send(
        &s,
        "/api/textfileprocess",
        &[],
        Some(("file", "t.txt", "你好 Rust".as_bytes())),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(data["text"], "你好 Rust");
    let mut image = image_for_test();
    let bytes = export::png(&image).unwrap();
    let (status, data) = send(
        &s,
        "/api/imagefileprocess",
        &[],
        Some(("file", "page.png", &bytes)),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{data}");
    assert_eq!(data["lineSpacing"], 40);
    let tilted = image::RgbaImage::from_fn(400, 500, |x, y| {
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
    let bytes = export::png(&tilted).unwrap();
    let expected = imaging::identify(&image::DynamicImage::ImageRgba8(tilted)).unwrap();
    let (status, data) = send(
        &s,
        "/api/imagefileprocess",
        &[],
        Some(("file", "tilted.png", &bytes)),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let wire_expected: serde_json::Value =
        serde_json::from_slice(&serde_json::to_vec(&expected).unwrap()).unwrap();
    assert_eq!(data, wire_expected);
    assert!(data["correctedBackground"].as_str().unwrap().len() > 100);
    image.fill(255);
    let bytes = export::png(&image).unwrap();
    let (status, data) = send(
        &s,
        "/api/imagefileprocess",
        &[],
        Some(("file", "blank.png", &bytes)),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(data["error_code"], "identification_unreliable");
}
fn image_for_test() -> image::RgbaImage {
    let mut image = image::RgbaImage::from_pixel(300, 400, image::Rgba([255, 255, 255, 255]));
    for y in (40..360).step_by(40) {
        for yy in y..y + 4 {
            for x in 30..270 {
                image[(x, yy)] = image::Rgba([0, 0, 0, 255]);
            }
        }
    }
    image
}
