//! 2026-10-23：直接使用生产引擎生成完整电路作业，便于核对图与推导排版。
#[path = "support/realistic_circuits.rs"]
mod realistic;
use handwriting_core::{Cancellation, FontBook, Limits, Parameters, RenderRequest, export, render};
use std::{env, fs, path::PathBuf};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = env::args_os().collect();
    if args.len() < 3 {
        return Err("usage: realistic_circuit_gallery FONT_DIR OUTPUT_DIR [FONT_NAME] [--ruled|--notebook] [--natural]".into());
    }
    let directory = PathBuf::from(&args[1]);
    let output = PathBuf::from(&args[2]);
    let name = args.get(3).map_or_else(
        || "霞鹜文楷.ttf".into(),
        |s| s.to_string_lossy().into_owned(),
    );
    let ruled = args.iter().any(|s| s == "--ruled");
    let notebook = args.iter().any(|s| s == "--notebook");
    let natural = args.iter().any(|s| s == "--natural");
    let background = if notebook {
        // 2026-10-23：经真实上传背景入口使用淡蓝横线纸，不改变产品默认纸线。
        let mut paper = image::RgbaImage::from_pixel(1700, 2200, image::Rgba([255; 4]));
        for y in (198..2100).step_by(98) {
            for row in y..y + 2 {
                for x in 100..1600 {
                    paper[(x, row)] = image::Rgba([205, 219, 226, 255]);
                }
            }
        }
        Some(export::png(&paper)?)
    } else {
        None
    };
    fs::create_dir_all(&output)?;
    let primary = FontBook::load(&fs::read(directory.join(&name))?)?;
    for case in realistic::cases() {
        let parsed = handwriting_core::text::circuit::parse(&case.source).unwrap();
        assert_eq!(
            parsed.segments.iter().filter(|s| s.kind != "short").count(),
            case.components.values().sum::<usize>()
        );
        let text = realistic::homework(&case);
        let fonts = FontBook::with_text_fallbacks(primary.clone(), &text, |name| {
            let bytes = fs::read(directory.join(name))
                .map_err(|e| handwriting_core::Error::new("font_io", e.to_string()))?;
            Ok(Some(FontBook::load(&bytes)?))
        })?;
        let request = RenderRequest {
            text: text.clone(),
            fonts,
            background: background.clone(),
            limits: Limits::default(),
            params: Parameters {
                font_size: 60.,
                line_spacing: 98.,
                word_spacing: 0.5,
                width: if notebook { None } else { Some(1700) },
                height: if notebook { None } else { Some(2200) },
                left_margin: 100.,
                right_margin: 100.,
                top_margin: 100.,
                bottom_margin: 100.,
                font_size_sigma: if natural { 1.4 } else { 0. },
                word_spacing_sigma: if natural { 0.7 } else { 0. },
                line_spacing_sigma: 0.,
                perturb_x_sigma: if natural { 0.7 } else { 0. },
                perturb_y_sigma: if natural { 0.6 } else { 0. },
                perturb_theta_sigma: if natural { 0.008 } else { 0. },
                ink_depth_sigma: if natural { 5. } else { 0. },
                strikethrough_probability: 0.,
                underlined: ruled && !notebook,
                preview: false,
                seed: 20261023,
                ..Parameters::default()
            },
        };
        let mut pdf = export::PdfExport::new();
        render(&request, &Cancellation::default(), |index, image| {
            fs::write(
                output.join(format!("{}-{}.png", case.id, index + 1)),
                export::png(&image)?,
            )
            .unwrap();
            pdf.add(&image)
        })?;
        fs::write(output.join(format!("{}.pdf", case.id)), pdf.finish())?;
        fs::write(output.join(format!("{}.txt", case.id)), text)?;
    }
    Ok(())
}
