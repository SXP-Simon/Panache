use base64::{Engine, engine::general_purpose::STANDARD};
use handwriting_core::{
    Limits,
    pdf_page::{self, PdfPage},
};
use lopdf::{Document, Stream, dictionary};
use std::collections::HashMap;

fn fixture(contents: &[&[u8]]) -> Vec<u8> {
    let mut doc = Document::with_version("1.7");
    let pages = doc.new_object_id();
    let font = doc.add_object(dictionary! {
        "Type" => "Font",
        "Subtype" => "Type1",
        "BaseFont" => "Helvetica",
        "Encoding" => "WinAnsiEncoding",
    });
    let mut kids = Vec::new();
    for stream in contents {
        let content = doc.add_object(Stream::new(dictionary! {}, stream.to_vec()));
        let id = doc.add_object(dictionary! {
            "Type" => "Page",
            "Parent" => pages,
            "Contents" => content,
        });
        kids.push(id.into());
    }
    let resources = dictionary! {
        "Font" => dictionary! {"F1" => font},
        "ExtGState" => dictionary! {"Hidden" => dictionary! {"ca" => 0.0f32}},
    };
    doc.objects.insert(
        pages,
        dictionary! {
            "Type" => "Pages",
            "Kids" => kids,
            "Count" => contents.len() as i64,
            "MediaBox" => vec![0.into(), 0.into(), 280.into(), 200.into()],
            "CropBox" => vec![10.into(), 20.into(), 250.into(), 180.into()],
            "Resources" => resources,
        }
        .into(),
    );
    let catalog = doc.add_object(dictionary! {"Type"=>"Catalog","Pages"=>pages});
    doc.trailer.set("Root", catalog);
    let mut out = Vec::new();
    doc.save_to(&mut out).unwrap();
    out
}

fn page(pdf: &[u8], index: usize, mode: &str) -> PdfPage {
    pdf_page::import(
        pdf.to_vec(),
        &HashMap::from([
            ("pageIndex".into(), index.to_string()),
            ("mode".into(), mode.to_string()),
        ]),
        &Limits::default(),
    )
    .unwrap()
}

fn pixels(page: &PdfPage) -> image::RgbImage {
    image::load_from_memory(&STANDARD.decode(&page.background_png).unwrap())
        .unwrap()
        .to_rgb8()
}

#[test]
fn selected_page_preserves_artwork_and_only_replaces_extractable_text() {
    let pdf=fixture(&[
        b"1 0 0 rg 20 25 40 40 re f",
        b"0.8 0.9 1 rg 10 20 240 160 re f 0 0 0 rg BT /F1 16 Tf 40 100 Td [(Exam) -200 (paper)] TJ ET BT /F1 12 Tf 0 1 -1 0 200 70 Tm (Vertical) Tj ET"
    ]);
    let layout = page(&pdf, 1, "layout");
    let fill = page(&pdf, 1, "fill");
    assert_eq!((layout.page_index, layout.page_count), (1, 2));
    assert_eq!((layout.width, layout.height), (480, 320));
    assert_eq!(
        (layout.page_width_pt, layout.page_height_pt),
        (240.0, 160.0)
    );
    assert_eq!(layout.lines.len(), 1, "{:?}", layout.lines);
    let line = &layout.lines[0];
    assert_eq!(line.text, "Exam paper");
    assert!((line.x - 60.0).abs() < 0.1 && (line.y - 134.4).abs() < 0.1);
    assert!((line.height - 32.0).abs() < 0.1);
    assert!(layout.warnings.contains(&"unsupported_text"));
    let (back, original) = (pixels(&layout), pixels(&fill));
    let paper = *original.get_pixel(2, 2);
    assert!(paper.0[0] < paper.0[2]);
    assert!(
        back.enumerate_pixels()
            .any(|(x, y, p)| *p != *original.get_pixel(x, y))
    );
    for (x, y, p) in back.enumerate_pixels() {
        if x < 310 {
            assert_eq!(*p, paper);
        } else {
            assert_eq!(*p, *original.get_pixel(x, y));
        }
    }
    assert!(
        back.enumerate_pixels()
            .any(|(x, _, p)| x > 310 && p.0[0] < 150)
    );
    let scanned = page(&pdf, 0, "layout");
    assert!(scanned.lines.is_empty() && scanned.warnings.contains(&"no_editable_text"));
    assert_eq!(pixels(&scanned).get_pixel(30, 250).0, [255, 0, 0]);
}
#[test]
fn rejects_invalid_page_and_resource_limits() {
    let pdf = fixture(&[b"BT /F1 12 Tf 40 40 Td (hello) Tj ET"]);
    let fields = HashMap::from([("pageIndex".into(), "1".into())]);
    assert_eq!(
        pdf_page::import(pdf.clone(), &fields, &Limits::default())
            .unwrap_err()
            .code,
        "invalid_parameter"
    );
    let limits = Limits {
        max_text_chars: 2,
        ..Default::default()
    };
    assert_eq!(
        pdf_page::import(pdf.clone(), &HashMap::new(), &limits)
            .unwrap_err()
            .code,
        "text_limit"
    );
    assert_eq!(
        pdf_page::import(vec![0], &HashMap::new(), &limits)
            .unwrap_err()
            .code,
        "invalid_document"
    );
}
#[test]
fn redacted_transparent_and_same_color_text_never_enter_the_editor() {
    let pdf = fixture(&[b"
        BT /F1 12 Tf 30 140 Td (Visible) Tj ET
        BT /F1 12 Tf 30 100 Td (Covered) Tj ET
        0 g 45 98 25 16 re f
        q /Hidden gs BT /F1 12 Tf 30 75 Td (Transparent) Tj ET Q
        1 g BT /F1 12 Tf 30 50 Td (White) Tj ET
    "]);
    for mode in ["fill", "layout"] {
        let parsed = page(&pdf, 0, mode);
        let labels: Vec<_> = parsed.lines.iter().map(|l| l.text.as_str()).collect();
        assert_eq!(labels, ["Visible"], "{mode}");
        assert!(parsed.warnings.contains(&"unsupported_text"));
    }
}
