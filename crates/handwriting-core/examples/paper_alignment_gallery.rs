//! 2026-10-24：通过生产识别和渲染引擎生成纸张对齐检查图。
use base64::Engine;
use handwriting_core::{
    Cancellation, FontBook, Limits, Parameters, RenderRequest, export, imaging, render,
};
use image::{DynamicImage, Rgba, RgbaImage};
use imageproc::geometric_transformations::{Border, Interpolation, rotate_about_center_no_crop};
use std::{env, fs, path::PathBuf};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let output = PathBuf::from(
        env::args_os()
            .nth(1)
            .ok_or("usage: paper_alignment_gallery OUTPUT_DIR")?,
    );
    fs::create_dir_all(&output)?;
    let font_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../assets/font_assets");
    let primary = FontBook::load(&fs::read(font_dir.join("云烟体.ttf"))?)?;
    for (id, title, thickness, ink, bg, tilt, shade) in [
        (
            "thick",
            "粗横线纸：每条粗线只算一行",
            9,
            120u8,
            255u8,
            0f32,
            false,
        ),
        ("faint", "浅灰横线：低对比纸张对齐", 2, 225, 245, 0., false),
        (
            "tilted",
            "倾斜照片：校正后文字贴线",
            3,
            160,
            250,
            3.25,
            false,
        ),
        (
            "shaded",
            "有阴影的浅色纸：旋转后对齐",
            3,
            210,
            240,
            -6.2,
            true,
        ),
    ] {
        let paper = RgbaImage::from_fn(800, 1000, |x, y| {
            let shadow = if shade { (x * 25 / 800) as u8 } else { 0 };
            let on_line = (80..920)
                .step_by(70)
                .any(|line| y >= line && y < line + thickness)
                && (60..=740).contains(&x);
            let color = if on_line { ink } else { bg }.saturating_sub(shadow);
            Rgba([color, color, color, 255])
        });
        let paper = if tilt == 0. {
            paper
        } else {
            rotate_about_center_no_crop(
                &paper,
                tilt.to_radians(),
                Interpolation::Bilinear,
                Border::Constant(Rgba([bg, bg, bg, 255])),
            )
        };
        let source = export::png(&paper)?;
        fs::write(output.join(format!("{id}-before.png")), &source)?;
        let detected = imaging::identify(&DynamicImage::ImageRgba8(paper))?;
        fs::write(
            output.join(format!("{id}-measurements.json")),
            serde_json::to_vec_pretty(&detected)?,
        )?;
        let corrected = match &detected.corrected_background {
            Some(data) => base64::engine::general_purpose::STANDARD.decode(data)?,
            None => source,
        };
        fs::write(
            output.join(format!("{id}-aligned-background.png")),
            &corrected,
        )?;
        let text = format!(
            "{title}\n横线间距固定，首行从实际横线开始。\n第二行：中文、英文 baseline 与数字 123。\n定积分：∫₀¹ x² dx = ⅓\n分式：(1)/(1+(x²+1)/(x+2))\n较高公式之后，下一行仍回到横线上。\n页尾也保留字母 g、p、y 的下伸空间。\n浅色纸张不需要把线条加深再识别。\n更换背景后重新识别即可。\nPanache 手写纸张对齐示例"
        );
        let fonts = FontBook::with_text_fallbacks(primary.clone(), &text, |name| {
            Ok(Some(FontBook::load(
                &fs::read(font_dir.join(name)).unwrap(),
            )?))
        })?;
        let request = RenderRequest {
            text,
            fonts,
            background: Some(corrected),
            limits: Limits::default(),
            params: Parameters {
                width: None,
                height: None,
                font_size: 38.,
                line_spacing: detected.line_spacing as f32,
                top_margin: detected.layout_top_margin as f32,
                bottom_margin: detected.layout_bottom_margin as f32,
                left_margin: detected.margin_left as f32,
                right_margin: detected.margin_right as f32,
                background_ruled: true,
                underlined: false,
                word_spacing: 1.,
                word_spacing_sigma: 0.5,
                font_size_sigma: 0.5,
                line_spacing_sigma: 0.,
                perturb_x_sigma: 0.5,
                perturb_y_sigma: 0.5,
                perturb_theta_sigma: 0.01,
                ink_depth_sigma: 8.,
                strikethrough_probability: 0.,
                preview: false,
                seed: 20261024,
                ..Parameters::default()
            },
        };
        render(&request, &Cancellation::default(), |index, image| {
            fs::write(
                output.join(format!("{id}-rendered-{}.png", index + 1)),
                export::png(&image)?,
            )
            .unwrap();
            Ok(())
        })?;
    }
    Ok(())
}
