//! 2026-10-15：自然公式字距、正文方格节奏与复合墨迹共同扰动的真实像素回归。
use handwriting_core::*;
use image::RgbaImage;
use std::{path::PathBuf, sync::OnceLock};
fn request(text: &str) -> RenderRequest {
    static FONTS: OnceLock<FontBook> = OnceLock::new();
    let fonts = FONTS.get_or_init(|| {
        FontBook::new(
            &std::fs::read(
                PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                    .join("../../assets/font_assets/云烟体.ttf"),
            )
            .unwrap(),
            &[],
        )
        .unwrap()
    });
    RenderRequest {
        text: text.into(),
        fonts: fonts.clone(),
        background: None,
        limits: Limits::default(),
        params: Parameters {
            width: Some(440),
            height: Some(320),
            font_size: 40.,
            line_spacing: 70.,
            word_spacing: 0.,
            left_margin: 30.,
            right_margin: 30.,
            top_margin: 30.,
            bottom_margin: 30.,
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
fn page(request: &RenderRequest) -> RgbaImage {
    let mut pages = vec![];
    render(request, &Cancellation::default(), |_, image| {
        pages.push(image);
        Ok(())
    })
    .unwrap();
    assert_eq!(pages.len(), 1);
    pages.remove(0)
}
fn ink_crop(image: &RgbaImage) -> RgbaImage {
    let ink: Vec<_> = image
        .enumerate_pixels()
        .filter(|(_, _, p)| p[0] < 128)
        .map(|(x, y, _)| (x, y))
        .collect();
    let minx = ink.iter().map(|p| p.0).min().unwrap();
    let maxx = ink.iter().map(|p| p.0).max().unwrap();
    let miny = ink.iter().map(|p| p.1).min().unwrap();
    let maxy = ink.iter().map(|p| p.1).max().unwrap();
    image::imageops::crop_imm(image, minx, miny, maxx - minx + 1, maxy - miny + 1).to_image()
}
#[test]
fn grid_keeps_formulas_natural_and_chinese_cell_rhythm() {
    let normal = request("x=ab²+cₙ");
    let mut grid = request("x=ab²+cₙ");
    grid.params.grid_layout = true;
    assert!(
        page(&normal) == page(&grid),
        "formula must not expand into one full cell per symbol"
    );
    let mut chinese = request("中中中");
    chinese.params.grid_layout = true;
    let image = page(&chinese);
    let left = image::imageops::crop_imm(&image, 30, 0, 40, 320).to_image();
    let middle = image::imageops::crop_imm(&image, 70, 0, 40, 320).to_image();
    assert!(
        left == middle,
        "Chinese cells must retain their 40px rhythm"
    );
}
#[test]
fn narrow_grid_paper_uses_actual_width_for_double_digit_circles() {
    let mut normal = request("⑩⑳㉑㊿⑩⑳㉑㊿");
    normal.params.width = Some(220);
    normal.params.height = Some(520);
    let mut grid = request(&normal.text);
    grid.params.width = normal.params.width;
    grid.params.height = normal.params.height;
    grid.params.grid_layout = true;
    assert!(
        page(&normal) == page(&grid),
        "circled digits must wrap with their true advance, including CJK code points"
    );
}
#[test]
fn nonzero_translation_moves_whole_formula_without_detaching_ink_components() {
    for source in [
        "    xₙ²",
        "    √(a²+b²)",
        "    (a)/(b)",
        "    (AB)⃗",
        "⟦ 点对 | SNN ; ── ; (1,2) | 0 ; ── ; (1,4) | 1 ; ── ; (3,4) | 0 ⟧",
        "⟦ X | 0  1 ; ── ; P | (8)/(15)  (7)/(15) ⟧",
        "⟦ a ┆ b ; ╌╌ ; c ┆ d ⟧",
    ] {
        let baseline = ink_crop(&page(&request(source)));
        for seed in 1..=8 {
            let mut shifted = request(source);
            shifted.params.perturb_x_sigma = 2.;
            shifted.params.perturb_y_sigma = 3.;
            shifted.params.seed = seed;
            let actual = ink_crop(&page(&shifted));
            if source.contains('√') || source.contains(")/(") {
                // 2026-10-24：分数线与根顶允许两像素内的自然曲线，不能让结构或字形独立漂移。
                assert!(actual.width().abs_diff(baseline.width()) <= 2);
                assert!(actual.height().abs_diff(baseline.height()) <= 2);
                for (a, b) in [(&baseline, &actual), (&actual, &baseline)] {
                    for (x, y, _) in a.enumerate_pixels().filter(|(_, _, p)| p[0] < 128) {
                        assert!(
                            (-2..=2).any(|dx| (-2..=2).any(|dy| {
                                let (xx, yy) = (x as i32 + dx, y as i32 + dy);
                                xx >= 0
                                    && yy >= 0
                                    && xx < b.width() as i32
                                    && yy < b.height() as i32
                                    && b[(xx as u32, yy as u32)][0] < 128
                            })),
                            "{source}/{seed}: formula components moved independently"
                        );
                    }
                }
            } else {
                assert!(
                    actual == baseline,
                    "{source}/{seed}: non-math frames must remain rigid"
                );
            }
        }
    }
}

#[test]
fn rotated_compound_ink_stays_inside_paper_margins() {
    for source in [
        "xₙ²",
        "√(a²+b²+c²+d²+e²)",
        "(a+b+c)/(x+y+z)",
        "(AB)⃗",
        "⟦ 点对 | SNN ; ── ; (1,2) | 0 ; ── ; (1,4) | 1 ; ── ; (3,4) | 0 ⟧",
        "⟦ X | 0  1 ; ── ; P | (8)/(15)  (7)/(15) ⟧",
        "⟦ a ┆ b ; ╌╌ ; c ┆ d ⟧",
    ] {
        for seed in 1..=8 {
            let mut varied = request(source);
            varied.params.perturb_x_sigma = 2.;
            varied.params.perturb_y_sigma = 3.;
            varied.params.perturb_theta_sigma = 0.05;
            varied.params.seed = seed;
            let image = page(&varied);
            for (x, y, pixel) in image.enumerate_pixels() {
                if pixel[0] < 128 {
                    assert!(
                        x >= 30 && y >= 30 && x < 410 && y < 290,
                        "{source}/{seed}: ink outside paper ({x},{y})"
                    );
                }
            }
        }
    }
}
