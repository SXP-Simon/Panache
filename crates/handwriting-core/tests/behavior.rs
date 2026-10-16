use handwriting_core::{
    document, export, imaging,
    text::{self, Node},
    *,
};
use image::{DynamicImage, GrayImage, Luma, Rgba, RgbaImage};
use std::{
    collections::HashMap,
    io::{Cursor, Write},
    path::PathBuf,
};
fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}
fn request(text: &str) -> RenderRequest {
    static FONT: std::sync::OnceLock<std::sync::Arc<fontdue::Font>> = std::sync::OnceLock::new();
    let font = FONT
        .get_or_init(|| {
            FontBook::load(&std::fs::read(root().join("assets/font_assets/霞鹜文楷.ttf")).unwrap())
                .unwrap()
        })
        .clone();
    RenderRequest {
        text: text.into(),
        fonts: FontBook::from_fonts(font, vec![]),
        background: None,
        limits: Limits::default(),
        params: Parameters {
            font_size: 24.,
            line_spacing: 36.,
            width: Some(240),
            height: Some(180),
            left_margin: 10.,
            right_margin: 10.,
            top_margin: 10.,
            bottom_margin: 10.,
            font_size_sigma: 0.,
            word_spacing_sigma: 0.,
            line_spacing_sigma: 0.,
            perturb_x_sigma: 0.,
            perturb_y_sigma: 0.,
            perturb_theta_sigma: 0.,
            ink_depth_sigma: 0.,
            strikethrough_probability: 0.,
            ..Parameters::default()
        },
    }
}
fn pages(r: &RenderRequest) -> Vec<RgbaImage> {
    let mut pages = Vec::new();
    render(r, &Cancellation::default(), |_, im| {
        pages.push(im);
        Ok(())
    })
    .unwrap();
    pages
}
#[test]
fn manual_page_breaks_and_single_preview() {
    let mut r = request("---\n第一页\r\n---\r\n第二页\n-----\n第三页\n---");
    assert_eq!(pages(&r).len(), 3);
    r.params.full_preview = false;
    assert_eq!(pages(&r).len(), 1);
}
#[test]
fn deterministic_seed_and_variation() {
    let mut r = request("手写测试 Hello world");
    r.params.perturb_x_sigma = 2.;
    r.params.perturb_theta_sigma = 0.07;
    r.params.font_size_sigma = 1.;
    let a = pages(&r);
    assert_eq!(a, pages(&r));
    r.params.seed = 12;
    assert_ne!(a, pages(&r));
}
#[test]
fn cancelled_and_limits_are_explicit() {
    let r = request("测试");
    let token = Cancellation::default();
    token.cancel();
    assert_eq!(
        render(&r, &token, |_, _| Ok(())).unwrap_err().code,
        "cancelled"
    );
    let mut r = r;
    r.limits.max_pixels = 10;
    assert_eq!(
        render(&r, &Cancellation::default(), |_, _| Ok(()))
            .unwrap_err()
            .code,
        "image_limit"
    );
    r.limits = Limits::default();
    r.text = "正文\n---\n第二页".into();
    r.limits.max_pages = 1;
    assert_eq!(
        render(&r, &Cancellation::default(), |_, _| Ok(()))
            .unwrap_err()
            .code,
        "page_limit"
    );
}
#[test]
fn background_and_fill_are_used() {
    let mut r = request("测试");
    r.params.width = None;
    r.params.height = None;
    r.params.fill = [200, 0, 0, 255];
    r.background =
        Some(export::png(&RgbaImage::from_pixel(240, 180, Rgba([245, 235, 210, 255]))).unwrap());
    let p = pages(&r);
    assert_eq!(p[0][(0, 0)], Rgba([245, 235, 210, 255]));
    assert!(p[0].pixels().any(|p| p[0] == 200 && p[1] == 0));
}
#[test]
fn alignment_and_negative_spacing_do_not_wrap() {
    let mut r = request(">>> July 27, 2026");
    r.params.word_spacing = -4.;
    assert_eq!(pages(&r).len(), 1);
    let p = pages(&r);
    let left = p[0]
        .enumerate_pixels()
        .filter(|(_, _, p)| p[0] < 128)
        .map(|(x, _, _)| x)
        .min()
        .unwrap();
    assert!(left > 10);
}
#[test]
fn formula_nodes_and_marker_boundaries() {
    let n = text::parse("(A+B)/(c) √(x+1) \\sqrt[3]{y} 1/2 ½");
    assert_eq!(
        n.iter().filter(|n| matches!(n, Node::Fraction(..))).count(),
        3
    );
    assert_eq!(
        n.iter().filter(|n| matches!(n, Node::Radical(..))).count(),
        2
    );
    let r = request("1/2 √(x) ∑ ≤ ≥");
    assert!(pages(&r)[0].pixels().any(|p| p[0] < 128));
    assert!(
        !text::parse("正文---仍在本页\n--\n---后有正文")
            .iter()
            .any(|n| matches!(n, Node::Break))
    );
    assert_eq!(
        text::normalize("hello world\n中文 文本", true),
        "hello  world\n中文 文本"
    );
}
#[test]
fn exports_are_valid_and_keep_page_geometry() {
    let image = pages(&request("导出")).remove(0);
    let mut pdf = export::PdfExport::new();
    pdf.add(&image).unwrap();
    pdf.add(&image).unwrap();
    let bytes = pdf.finish();
    assert!(bytes.starts_with(b"%PDF-"));
    assert!(String::from_utf8_lossy(&bytes).contains("/MediaBox [0 0 240 180]"));
    assert_eq!(export::PDF_JPEG_QUALITY, 75);
    let mut zip = export::ZipExport::new(Cursor::new(Vec::new()));
    zip.add(0, &image).unwrap();
    zip.add(1, &image).unwrap();
    let data = zip.finish().unwrap().into_inner();
    let mut archive = zip::ZipArchive::new(Cursor::new(data)).unwrap();
    assert_eq!(archive.len(), 2);
    assert_eq!(archive.by_index(1).unwrap().name().unwrap(), "1.png");
}
#[test]
fn identify_real_line_spacing_blank_and_tilt() {
    let mut page = GrayImage::from_pixel(800, 1000, Luma([255]));
    for y in (80..920).step_by(70) {
        for yy in y..=y + 8 {
            for x in 60..=740 {
                page[(x, yy)] = Luma([15]);
            }
        }
    }
    let result = imaging::identify(&DynamicImage::ImageLuma8(page.clone())).unwrap();
    assert!((result.line_spacing as i32 - 70).abs() <= 4);
    assert!((result.margin_left as i32 - 60).abs() <= 4);
    assert!((result.margin_bottom as i32 - 141).abs() <= 4);
    let tilted = imageproc::geometric_transformations::rotate_about_center(
        &page,
        3f32.to_radians(),
        imageproc::geometric_transformations::Interpolation::Bilinear,
        imageproc::geometric_transformations::Border::Constant(Luma([255])),
    );
    assert!(
        (imaging::identify(&DynamicImage::ImageLuma8(tilted))
            .unwrap()
            .line_spacing as i32
            - 70)
            .abs()
            <= 4
    );
    assert_eq!(
        imaging::identify(&DynamicImage::ImageLuma8(GrayImage::from_pixel(
            80,
            100,
            Luma([255])
        )))
        .unwrap_err()
        .code,
        "identification_unreliable"
    );
}
#[test]
fn inline_image_scale_and_transparent_filter() {
    use base64::{Engine, engine::general_purpose::STANDARD};
    let mut image = RgbaImage::from_pixel(80, 60, Rgba([255, 255, 255, 255]));
    for x in 10..70 {
        image[(x, 30)] = Rgba([0, 0, 0, 255]);
    }
    let filter = imaging::handdrawn(
        &DynamicImage::ImageRgba8(image.clone()),
        1,
        &Cancellation::default(),
    )
    .unwrap();
    assert_eq!(filter[(0, 0)][3], 0);
    assert!(filter.pixels().any(|p| p[3] > 0));
    let mut r = request(&format!(
        "正文\n![插图|50%](data:image/png;base64,{})\n结尾",
        STANDARD.encode(export::png(&image).unwrap())
    ));
    r.params.height = Some(400);
    assert_eq!(pages(&r).len(), 1);
    assert_eq!(imaging::scale("插图|200%"), 2.);
    assert_eq!(imaging::fit(&image, 30, 30, 2.).width(), 30);
}
#[test]
fn full_page_illustration_paginates_and_half_scale_leaves_room_for_text() {
    use base64::{Engine, engine::general_purpose::STANDARD};
    let mut image = RgbaImage::new(1000, 800);
    for x in 100..900 {
        for y in 390..410 {
            image[(x, y)] = Rgba([0, 0, 0, 255]);
        }
    }
    let data = STANDARD.encode(export::png(&image).unwrap());
    let full = request(&format!("![图|100%](data:image/png;base64,{data})\n结尾"));
    let half = request(&format!("![图|50%](data:image/png;base64,{data})\n结尾"));
    assert_eq!(pages(&full).len(), 2);
    assert_eq!(pages(&half).len(), 1);
}
#[test]
fn document_order_math_entities_and_spans() {
    let xml = r#"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math"><w:body><w:p><w:r><w:t>正文 &amp; </w:t><w:tab/><w:t>结尾</w:t></w:r><m:oMath><m:r><m:t>x²</m:t></m:r></m:oMath></w:p><w:tbl><w:tr><w:tc><w:tcPr><w:gridSpan w:val="2"/></w:tcPr><w:p><w:r><w:t>单元格</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:body></w:document>"#;
    let mut zip = zip::ZipWriter::new(Cursor::new(Vec::new()));
    zip.start_file(
        "word/document.xml",
        zip::write::SimpleFileOptions::default(),
    )
    .unwrap();
    zip.write_all(xml.as_bytes()).unwrap();
    let bytes = zip.finish().unwrap().into_inner();
    assert_eq!(
        document::extract("test.docx", &bytes, &Limits::default()).unwrap(),
        "正文 & \t结尾x²\n单元格\t单元格"
    );
    let limited = Limits {
        max_archive_bytes: 10,
        ..Limits::default()
    };
    assert_eq!(
        document::extract("t.docx", &bytes, &limited)
            .unwrap_err()
            .code,
        "archive_limit"
    );
    assert_eq!(
        document::extract("t.doc", b"", &Limits::default())
            .unwrap_err()
            .code,
        "unsupported_document"
    );
}
#[test]
fn form_validation_rejects_nan_and_conflicting_geometry() {
    let mut f = HashMap::from([("font_size".into(), "NaN".into())]);
    let p = Parameters::from_form(&f).unwrap();
    assert!(p.validate(800, 1000, &Limits::default()).is_err());
    f.insert("font_size".into(), "32".into());
    f.insert("fill".into(), "(10,20,30,255)".into());
    assert_eq!(Parameters::from_form(&f).unwrap().fill, [10, 20, 30, 255]);
}
#[test]
fn all_default_fonts_load_and_render() {
    let mut r = request("中文 English，。123");
    for file in std::fs::read_dir(root().join("assets/font_assets")).unwrap() {
        let file = file.unwrap();
        if file.path().extension().is_some_and(|e| e == "ttf") {
            r.fonts = FontBook::new(&std::fs::read(file.path()).unwrap(), &[]).unwrap();
            assert!(
                pages(&r)[0].pixels().any(|p| p[0] < 128),
                "{:?}",
                file.path()
            );
        }
    }
}

#[test]
fn unmatched_brackets_are_literal_and_strikethrough_advances() {
    let input = "(".repeat(100_000);
    assert_eq!(text::parse(&input).len(), 100_000);
    assert_eq!(text::parse(&"![".repeat(50_000)).len(), 100_000);
    let r = request("A");
    let plain = pages(&r);
    let mut crossed = request("A");
    crossed.params.strikethrough_probability = 1.;
    let crossed = pages(&crossed);
    let rightmost = |im: &RgbaImage| {
        im.enumerate_pixels()
            .filter(|(_, _, p)| p[0] < 128)
            .map(|(x, _, _)| x)
            .max()
            .unwrap()
    };
    assert!(rightmost(&crossed[0]) > rightmost(&plain[0]) + 10);
}

#[test]
fn pdf_text_import_reads_real_content_and_obeys_text_limit() {
    use pdf_writer::{Content, Finish, Name, Pdf, Rect, Ref, Str};
    let mut pdf = Pdf::new();
    let (catalog, tree, page, font, stream) = (
        Ref::new(1),
        Ref::new(2),
        Ref::new(3),
        Ref::new(4),
        Ref::new(5),
    );
    pdf.catalog(catalog).pages(tree);
    pdf.pages(tree).kids([page]).count(1);
    let mut p = pdf.page(page);
    p.parent(tree)
        .media_box(Rect::new(0., 0., 240., 180.))
        .contents(stream);
    p.resources().fonts().pair(Name(b"F1"), font);
    p.finish();
    pdf.type1_font(font).base_font(Name(b"Helvetica"));
    let mut content = Content::new();
    content.begin_text();
    content.set_font(Name(b"F1"), 12.);
    content.next_line(20., 140.);
    content.show(Str(b"Hello PDF import"));
    content.end_text();
    pdf.stream(stream, &content.finish());
    let bytes = pdf.finish();
    assert!(
        document::extract("test.pdf", &bytes, &Limits::default())
            .unwrap()
            .contains("Hello PDF import")
    );
    let limits = Limits {
        max_text_chars: 2,
        ..Limits::default()
    };
    assert_eq!(
        document::extract("test.pdf", &bytes, &limits)
            .unwrap_err()
            .code,
        "text_limit"
    );
}
