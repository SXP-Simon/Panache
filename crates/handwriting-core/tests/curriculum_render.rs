//! 2026-10-15：跨学科结构文本真实排版、页边界和导出回归。
#[path = "../examples/support/curriculum.rs"]
mod curriculum;
use handwriting_core::{Cancellation, FontBook, export, render};
use image::RgbaImage;
use std::{
    io::{Cursor, Read},
    path::PathBuf,
    sync::OnceLock,
};

fn fonts() -> &'static FontBook {
    static FONTS: OnceLock<FontBook> = OnceLock::new();
    FONTS.get_or_init(|| {
        curriculum::fonts(
            &PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../assets/font_assets"),
        )
    })
}
fn pages(text: &str, size: f32, width: u32, grid: bool) -> Vec<RgbaImage> {
    let mut result = vec![];
    render(
        &curriculum::request(text, fonts(), size, width, grid),
        &Cancellation::default(),
        |_, image| {
            result.push(image);
            Ok(())
        },
    )
    .unwrap();
    result
}
fn assert_geometry(image: &RgbaImage, name: &str) {
    let mut ink = 0;
    for (x, y, pixel) in image.enumerate_pixels() {
        if pixel[0] < 128 {
            ink += 1;
            assert!(
                x >= 18 && y >= 18 && x < image.width() - 18 && y < image.height() - 18,
                "{name}: ink ({x},{y}) outside paper margins"
            );
        }
    }
    assert!(ink > 20, "{name}: formula disappeared");
}
#[test]
fn critical_scientific_symbols_have_real_ink_not_blank_font_glyphs() {
    let directory = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../assets/font_assets");
    let data =
        ["云烟体.ttf", "霞鹜文楷.ttf"].map(|name| std::fs::read(directory.join(name)).unwrap());
    let faces = data
        .iter()
        .map(|bytes| ttf_parser::Face::parse(bytes, 0).unwrap())
        .collect::<Vec<_>>();
    for symbol in "∫∑∇∂∞λσπμρζωεΔ→≥·×↓′".chars() {
        assert!(
            faces.iter().any(|face| face.glyph_index(symbol).is_some()),
            "scientific symbol {symbol} must not render as missing-glyph tofu"
        );
        let rendered = pages(&symbol.to_string(), 36., 220, false);
        assert!(
            rendered[0].pixels().any(|pixel| pixel[0] < 128),
            "scientific symbol {symbol} has no visible ink"
        );
    }
}

#[test]
fn all_curriculum_cases_fit_multiple_sizes_narrow_paper_and_grid() {
    for (subject, name, text) in curriculum::CASES {
        for (size, width, grid) in [(20., 480, false), (36., 220, false), (48., 220, true)] {
            let images = pages(text, size, width, grid);
            assert!(!images.is_empty(), "{subject}/{name}");
            for image in images {
                assert_geometry(&image, name);
            }
        }
    }
}
#[test]
fn curriculum_exports_roundtrip_png_zip_and_keep_pdf_page_geometry() {
    let mut pdf = export::PdfExport::new();
    let mut zip = export::ZipExport::new(Cursor::new(Vec::new()));
    let mut originals = vec![];
    // 每个学科选一个含结构的实际生成结果；导出后核对像素而非只检查文件头。
    for (index, (_, name, text)) in curriculum::CASES.iter().step_by(4).enumerate() {
        let image = pages(text, 28., 480, false).remove(0);
        assert_geometry(&image, name);
        let png = export::png(&image).unwrap();
        assert_eq!(image::load_from_memory(&png).unwrap().to_rgba8(), image);
        pdf.add(&image).unwrap();
        zip.add(index, &image).unwrap();
        originals.push(image);
    }
    let bytes = pdf.finish();
    let pdf = String::from_utf8_lossy(&bytes);
    assert!(bytes.starts_with(b"%PDF-"));
    assert!(pdf.contains("/Count 6"));
    assert_eq!(pdf.matches("/MediaBox [0 0 480 360]").count(), 6);
    let mut archive =
        zip::ZipArchive::new(Cursor::new(zip.finish().unwrap().into_inner())).unwrap();
    assert_eq!(archive.len(), originals.len());
    for (index, original) in originals.iter().enumerate() {
        let mut bytes = vec![];
        archive
            .by_name(&format!("{index}.png"))
            .unwrap()
            .read_to_end(&mut bytes)
            .unwrap();
        assert_eq!(
            &image::load_from_memory(&bytes).unwrap().to_rgba8(),
            original
        );
    }
}

#[test]
fn narrow_grid_keeps_chemical_subscripts_and_charge_with_the_base() {
    let automatic = pages("AO₃²⁻", 48., 96, true);
    let explicit = pages("A\nO₃²⁻", 48., 96, true);
    assert!(
        automatic == explicit,
        "base O and its scripts must wrap together"
    );
}
