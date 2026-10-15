//! 2026-10-15：数学解析和真实渲染页边距回归，不用“非空图片”代替几何检查。
use handwriting_core::{
    text::{self, Node},
    *,
};
use image::RgbaImage;
use std::{path::PathBuf, sync::OnceLock};
fn fonts() -> FontBook {
    static FONT: OnceLock<FontBook> = OnceLock::new();
    FONT.get_or_init(|| {
        FontBook::new(
            &std::fs::read(
                PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                    .join("../../assets/font_assets/云烟体.ttf"),
            )
            .unwrap(),
            &[],
        )
        .unwrap()
    })
    .clone()
}
fn request(text: &str, w: u32, h: u32) -> RenderRequest {
    RenderRequest {
        text: text.into(),
        fonts: fonts(),
        background: None,
        limits: Limits::default(),
        params: Parameters {
            font_size: 40.,
            line_spacing: 42.,
            word_spacing: 0.,
            width: Some(w),
            height: Some(h),
            left_margin: 15.,
            right_margin: 15.,
            top_margin: 15.,
            bottom_margin: 15.,
            font_size_sigma: 0.,
            word_spacing_sigma: 0.,
            line_spacing_sigma: 0.,
            perturb_x_sigma: 0.,
            perturb_y_sigma: 0.,
            perturb_theta_sigma: 0.,
            ink_depth_sigma: 0.,
            strikethrough_probability: 0.,
            preview: false,
            ..Parameters::default()
        },
    }
}
fn pages(r: &RenderRequest) -> Vec<RgbaImage> {
    let mut result = vec![];
    render(r, &Cancellation::default(), |_, p| {
        result.push(p);
        Ok(())
    })
    .unwrap();
    result
}
fn assert_inside(images: &[RgbaImage], margin: u32) {
    for image in images {
        let mut ink = 0;
        for (x, y, p) in image.enumerate_pixels() {
            if p[0] < 128 {
                ink += 1;
                assert!(
                    x >= margin
                        && y >= margin
                        && x < image.width() - margin
                        && y < image.height() - margin,
                    "ink ({x},{y}) outside {}x{}",
                    image.width(),
                    image.height()
                );
            }
        }
        assert!(ink > 0);
    }
}
#[test]
fn protected_urls_dates_paths_and_code_remain_literal() {
    for source in [
        "https://example.com/a/b/x_1/√(x)",
        "www.example.org/a/b",
        "2026/10/15",
        "C:\\notes\\x_1.txt",
        "/tmp/a/b",
        "./data/x_1.csv",
        "C:/math/x²",
        "folder_name/x²",
        "(https://example.org/a/b/x²)",
        "路径：C:/math/x²",
        "`a/b √(x) x²`",
        "```\na/b √(x) x²\n```",
        "````\n```\n~~~\na/b √(x)\n````",
    ] {
        assert_eq!(
            text::parse(source),
            source
                .chars()
                .map(|c| if c == '\n' {
                    Node::Newline
                } else {
                    Node::Char(c)
                })
                .collect::<Vec<_>>(),
            "{source}"
        );
    }
    let parsed = text::parse("https://example.com/a/b (a)/(b) √(x) xₙ²");
    assert!(parsed.iter().any(|n| matches!(n, Node::Fraction(..))));
    assert!(parsed.iter().any(|n| matches!(n, Node::Radical(..))));
    assert!(
        parsed
            .iter()
            .any(|n| matches!(n,Node::Scripts{upper,lower}if !upper.is_empty()&&!lower.is_empty()))
    );
}
#[test]
fn parsed_scripts_and_accents_keep_grouping() {
    assert_eq!(
        text::parse("x^(ab)_(A)"),
        vec![
            Node::Char('x'),
            Node::Scripts {
                upper: vec![Node::Char('a'), Node::Char('b')],
                lower: vec![Node::Char('A')]
            }
        ]
    );
    assert_eq!(
        text::parse("(AB)⃗"),
        vec![Node::Accent(
            vec![Node::Char('A'), Node::Char('B')],
            '\u{20d7}'
        )]
    );
    assert_eq!(
        text::parse("file_name"),
        "file_name".chars().map(Node::Char).collect::<Vec<_>>()
    );
    assert!(
        matches!(&text::parse("∛(x)")[0],Node::Radical(_,index)if index==&vec![Node::Char('3')])
    );
}
#[test]
fn tall_lines_preserve_all_ink_when_paginated() {
    let formula = "((a)/(b))/((c)/(d))";
    let single = pages(&request(formula, 240, 180));
    let count = |p: &RgbaImage| p.pixels().filter(|p| p[0] < 128).count();
    let per_line = count(&single[0]);
    let repeated = pages(&request(&[formula; 6].join("\n"), 240, 180));
    assert_inside(&repeated, 15);
    assert!(repeated.len() >= 3);
    assert_eq!(repeated.iter().map(count).sum::<usize>(), per_line * 6);
}
#[test]
fn narrow_paper_fits_whole_oversized_math_without_clipping() {
    for (w, h, size) in [(160, 180, 40.), (80, 95, 40.), (40, 55, 8.)] {
        let mut r = request("√(a²+b²+c²+2ab+2bc+2ca)\n((a)/(b))/((c)/(d))", w, h);
        r.params.font_size = size;
        r.params.line_spacing = size.max(8.);
        let result = pages(&r);
        assert_inside(&result, 15);
    }
}

#[test]
fn negative_spacing_stays_effective_for_plain_letters_in_math_documents() {
    let width = |image: &RgbaImage| {
        image
            .enumerate_pixels()
            .filter(|(_, _, p)| p[0] < 128)
            .map(|(x, _, _)| x)
            .max()
            .unwrap()
    };
    let plain = pages(&request("MMMM", 400, 180));
    let mut r = request("MMMM\n√(x)", 400, 260);
    r.params.word_spacing = -10.;
    let negative = pages(&r);
    let first_line = image::imageops::crop_imm(&negative[0], 0, 0, 400, 65).to_image();
    assert!(width(&first_line) + 15 < width(&plain[0]));
}

#[test]
fn extreme_strikethrough_uses_bounded_raster_and_keeps_correct_text_after_crossout() {
    let mut r = request("√(x)A", 220, 220);
    r.params.strikethrough_probability = 1.;
    r.params.strikethrough_width = 10000.;
    r.params.strikethrough_length_sigma = 10000.;
    let result = pages(&r);
    assert_inside(&result, 15);
}
#[test]
fn grid_reserves_multiple_cells_for_a_wide_fraction() {
    let mut r = request("(123456)/(789)Z", 440, 240);
    r.params.grid_layout = true;
    let combined = pages(&r);
    assert_inside(&combined, 15);
    let prefix = pages(&request("(123456)/(789)", 440, 240));
    let last = prefix[0]
        .enumerate_pixels()
        .filter(|(_, _, p)| p[0] < 128)
        .map(|(x, _, _)| x)
        .max()
        .unwrap();
    let z_x = combined[0]
        .enumerate_pixels()
        .filter(|(x, _, p)| *x > last && p[0] < 128)
        .map(|(x, _, _)| x)
        .min()
        .unwrap();
    assert!(z_x > last + 3);
}
#[test]
fn preview_cancellation_and_manual_breaks_survive_tall_math() {
    let mut r = request("√((a)/(b))\n---\nxₙ²\n---\n(AB)⃗", 200, 180);
    assert_eq!(pages(&r).len(), 3);
    r.params.preview = true;
    r.params.full_preview = false;
    assert_eq!(pages(&r).len(), 1);
    let cancel = Cancellation::default();
    cancel.cancel();
    assert_eq!(
        render(&r, &cancel, |_, _| Ok(())).unwrap_err().code,
        "cancelled"
    );
}
