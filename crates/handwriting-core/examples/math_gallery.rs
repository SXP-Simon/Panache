//! 2026-10-15：生产 Rust 引擎的固定种子数学图集；参数为字体目录、PNG/TSV 输出目录。
use handwriting_core::{Cancellation, FontBook, Limits, Parameters, RenderRequest, export, render};
use std::{env, fs, path::PathBuf, time::Instant};
const CASES: [(&str, &str); 24] = [
    ("simple_fraction", "a = (1)/(2) + b"),
    ("polynomial_fraction", "f(x) = (x² + 2x + 1)/(x − 1)"),
    ("nested_fraction", "y = (1)/((2)/(3) + 4)"),
    ("fraction_both_nested", "z = ((a)/(b))/((c)/(d))"),
    ("simple_root", "y = √(x² + 1) + z"),
    ("root_fraction", "y = √((x + 1)/(x − 1))"),
    ("fraction_root", "y = (√(x + 1))/(√(x − 1))"),
    ("nested_roots", "y = √(1 + √(1 + √(x)))"),
    ("root_index", "y = ³√(8x³) + ¹²√(a)"),
    ("root_coefficient", "y = 2√(x) + 3³√(x²)"),
    ("scripts", "aₙ₊₁ = x² + y³ + eⁿ"),
    ("wide_root", "y = √(a² + b² + c² + 2ab + 2bc + 2ca)"),
    (
        "wide_fraction",
        "y = (a + b + c + d + e + f)/(x² + 2xy + y²)",
    ),
    ("quadratic", "x = (−b ± √(b² − 4ac))/(2a)"),
    ("continued_fraction", "x = (1)/(1 + (1)/(1 + (1)/(2)))"),
    ("adjacent_structures", "√(x)√(y) + (1)/(2)(3)/(4) = z"),
    ("statistical_mean", "x̄ = (x₁ + x₂ + x₃)/(3)"),
    ("vector_group", "(AB)⃗ + (BC)⃗ = (AC)⃗"),
    ("wide_hat", "(xy)̂ + ẑ"),
    ("underline", "(a+b)̲ = x̲"),
    ("derivatives_accents", "ẍ + 2ẋ + x = 0"),
    ("accent_nested_root", "(√(x²+1))⃗ + ȳ"),
    ("accent_nested_fraction", "((a)/(b))̄ + (x̄)/(ÿ)"),
    ("stacked_accents", "x̄̂ + (aₙ+bₙ)̄"),
];
fn request(
    text: &str,
    fonts: &FontBook,
    size: f32,
    width: u32,
    height: u32,
    spacing: f32,
    grid: bool,
) -> RenderRequest {
    RenderRequest {
        text: text.to_owned(),
        fonts: fonts.clone(),
        background: None,
        limits: Limits::default(),
        params: Parameters {
            font_size: size,
            line_spacing: spacing,
            word_spacing: 0.,
            width: Some(width),
            height: Some(height),
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
            grid_layout: grid,
            seed: 20261015,
            preview: false,
            full_preview: true,
            ..Parameters::default()
        },
    }
}
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = env::args().collect();
    if args.len() != 3 {
        return Err(
            "usage: cargo run -p handwriting-core --example math_gallery -- FONT_DIR OUTPUT_DIR"
                .into(),
        );
    }
    let font_root = PathBuf::from(&args[1]);
    let output = PathBuf::from(&args[2]);
    fs::create_dir_all(&output)?;
    let mut rows =
        String::from("kind\tfont\tsize\tcase\tinput\timage\twidth\theight\trender_ms\tstatus\n");
    let mut count = 0;
    for name in ["云烟体", "李国夫手写体"] {
        let fonts = FontBook::new(&fs::read(font_root.join(format!("{name}.ttf")))?, &[])?;
        for size in [24., 40., 64.] {
            for (case, input) in CASES {
                let r = request(input, &fonts, size, 4096, 1024, size * 3., false);
                let begin = Instant::now();
                let mut found = 0;
                let outcome = render(&r, &Cancellation::default(), |page, image| {
                    let filename = format!("{name}-{}-{case}-{}.png", size as u32, page + 1);
                    fs::write(output.join(&filename), export::png(&image)?).map_err(|e| {
                        handwriting_core::Error::new("gallery_write", e.to_string())
                    })?;
                    rows.push_str(&format!(
                        "sample\t{name}\t{size}\t{case}\t{input}\t{filename}\t{}\t{}\t{:.3}\tok\n",
                        image.width(),
                        image.height(),
                        begin.elapsed().as_secs_f64() * 1000.
                    ));
                    found += 1;
                    Ok(())
                });
                if let Err(e) = outcome {
                    rows.push_str(&format!(
                        "sample\t{name}\t{size}\t{case}\t{input}\t\t4096\t1024\t{:.3}\t{}\n",
                        begin.elapsed().as_secs_f64() * 1000.,
                        e.code
                    ));
                }
                count += found;
            }
        }
    }
    let fonts = FontBook::new(&fs::read(font_root.join("云烟体.ttf"))?, &[])?;
    let input = CASES
        .iter()
        .enumerate()
        .map(|(i, (_, text))| format!("{}. {}", i + 1, text))
        .collect::<Vec<_>>()
        .join("\n");
    for (layout, width, height, spacing, grid) in [
        ("roomy", 1400, 2200, 116., false),
        ("compact", 1400, 2200, 48., false),
        ("grid", 1400, 2200, 48., true),
        ("narrow", 620, 820, 48., false),
    ] {
        let r = request(&input, &fonts, 40., width, height, spacing, grid);
        let begin = Instant::now();
        let outcome = render(&r, &Cancellation::default(), |page, image| {
            let filename = format!("pages-{layout}-{}.png", page + 1);
            fs::write(output.join(&filename), export::png(&image)?)
                .map_err(|e| handwriting_core::Error::new("gallery_write", e.to_string()))?;
            rows.push_str(&format!(
                "page\t云烟体\t40\t{layout}\t\t{filename}\t{}\t{}\t{:.3}\tok\n",
                image.width(),
                image.height(),
                begin.elapsed().as_secs_f64() * 1000.
            ));
            Ok(())
        });
        if let Err(e) = outcome {
            rows.push_str(&format!(
                "page\t云烟体\t40\t{layout}\t\t\t{width}\t{height}\t{:.3}\t{}\n",
                begin.elapsed().as_secs_f64() * 1000.,
                e.code
            ));
        }
    }
    fs::write(output.join("metrics.tsv"), rows)?;
    println!(
        "Generated {count} sample pages; output {}",
        output.display()
    );
    Ok(())
}
