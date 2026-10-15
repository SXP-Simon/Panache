//! 2026-10-15：移动默认参数的中文与公式作业本人工审查图。
use handwriting_core::{Cancellation, FontBook, Limits, Parameters, RenderRequest, export, render};
use std::{env, fs, path::PathBuf};
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../assets/font_assets");
    let output = PathBuf::from(
        env::args_os()
            .nth(1)
            .ok_or("usage: notebook_preview OUTPUT_DIR")?,
    );
    fs::create_dir_all(&output)?;
    let text = "一二三四五六七八九十一二三四五六七八九十\n求根公式：x = (-b ± √(b²-4ac))/(2a)\n上下标：aₙ₊₁² + H₂O + Ca²⁺ + CO₃²⁻\n定积分：∫₀¹ x² dx = ⅓\n向量：(AB)⃗ + (BC)⃗ = (AC)⃗\n方差：Var(X) = E(X²) - E(X)²";
    let primary = FontBook::load(&fs::read(root.join("云烟体.ttf"))?)?;
    let fonts = FontBook::with_text_fallbacks(primary, text, |name| {
        FontBook::load(&fs::read(root.join(name)).unwrap()).map(Some)
    })?;
    let request = RenderRequest {
        text: text.into(),
        fonts,
        background: None,
        limits: Limits::default(),
        params: Parameters {
            width: Some(1600),
            height: Some(2200),
            font_size: 70.,
            word_spacing: 2.,
            line_spacing: 120.,
            left_margin: 80.,
            right_margin: 80.,
            top_margin: 100.,
            bottom_margin: 100.,
            underlined: true,
            font_size_sigma: 1.,
            word_spacing_sigma: 1.,
            perturb_x_sigma: 1.,
            perturb_y_sigma: 1.,
            perturb_theta_sigma: 0.025,
            strikethrough_probability: 0.,
            preview: false,
            seed: 20261015,
            ..Parameters::default()
        },
    };
    render(&request, &Cancellation::default(), |index, image| {
        fs::write(
            output.join(format!("notebook-{}.png", index + 1)),
            export::png(&image)?,
        )
        .unwrap();
        Ok(())
    })?;
    Ok(())
}
