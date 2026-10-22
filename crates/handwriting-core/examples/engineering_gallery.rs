//! 2026-10-22：使用生产 Rust 引擎与霞鹜文楷输出工整作业样张，不使用浏览器排版替代。
#[path = "support/engineering.rs"]
mod engineering;
use handwriting_core::{Cancellation, FontBook, Limits, Parameters, RenderRequest, export, render};
use std::{env, fs, path::PathBuf};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = env::args_os().collect();
    if args.len() != 3 {
        return Err("usage: engineering_gallery FONT_DIR OUTPUT_DIR".into());
    }
    let font_dir = PathBuf::from(&args[1]);
    let output = PathBuf::from(&args[2]);
    fs::create_dir_all(&output)?;
    let source = engineering::CASES
        .iter()
        .map(|(title, text)| format!("{title}\n{text}"))
        .collect::<Vec<_>>()
        .join("\n\n");
    let primary = FontBook::load(&fs::read(font_dir.join("霞鹜文楷.ttf"))?)?;
    let fonts = FontBook::with_text_fallbacks(primary, &source, |name| {
        Ok(Some(FontBook::load(
            &fs::read(font_dir.join(name)).unwrap(),
        )?))
    })?;
    let request = RenderRequest {
        text: source.clone(),
        fonts,
        background: None,
        limits: Limits::default(),
        params: Parameters {
            font_size: 54.,
            line_spacing: 88.,
            word_spacing: 1.,
            width: Some(1600),
            height: Some(2200),
            left_margin: 80.,
            right_margin: 80.,
            top_margin: 80.,
            bottom_margin: 80.,
            font_size_sigma: 0.,
            word_spacing_sigma: 0.,
            line_spacing_sigma: 0.,
            perturb_x_sigma: 0.,
            perturb_y_sigma: 0.,
            perturb_theta_sigma: 0.,
            ink_depth_sigma: 0.,
            strikethrough_probability: 0.,
            preview: false,
            seed: 20261022,
            ..Parameters::default()
        },
    };
    let mut pdf = export::PdfExport::new();
    render(&request, &Cancellation::default(), |index, image| {
        fs::write(
            output.join(format!("engineering-{}.png", index + 1)),
            export::png(&image)?,
        )
        .unwrap();
        pdf.add(&image)?;
        Ok(())
    })?;
    fs::write(output.join("engineering.pdf"), pdf.finish())?;
    fs::write(output.join("input.txt"), source)?;
    Ok(())
}
