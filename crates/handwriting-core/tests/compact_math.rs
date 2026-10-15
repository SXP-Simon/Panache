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
fn nonzero_translation_moves_whole_formula_without_detaching_ink_components() {
    for source in ["    xₙ²", "    √(a²+b²)", "    (a)/(b)", "    (AB)⃗"] {
        let baseline = ink_crop(&page(&request(source)));
        for seed in 1..=8 {
            let mut shifted = request(source);
            shifted.params.perturb_x_sigma = 2.;
            shifted.params.perturb_y_sigma = 3.;
            shifted.params.seed = seed;
            assert!(
                ink_crop(&page(&shifted)) == baseline,
                "{source}/{seed}: formula components moved independently"
            );
        }
    }
}

#[test]
fn rotated_compound_ink_stays_inside_paper_margins() {
    for source in ["xₙ²", "√(a²+b²+c²+d²+e²)", "(a+b+c)/(x+y+z)", "(AB)⃗"] {
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
