//! 2026-10-24：根号钩部、长根式、分式与高次根指数的真实引擎对比图。
use handwriting_core::{Cancellation, FontBook, Limits, Parameters, RenderRequest, export, render};
use std::{env, fs, path::PathBuf};
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let output = PathBuf::from(env::args_os().nth(1).ok_or("output directory required")?);
    fs::create_dir_all(&output)?;
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../assets/font_assets");
    let text = "根式与数值分析\n1. 常用根式：√(2)、√(x)、√(x²+y²)\n2. 高次根：∛(1+x)，∜(a²+b²)，⁵√(x+1)\n3. 二次方程：x=(-b±√(b²-4ac))/(2a)\n4. 标准差：σ=√((Σᵢ₌₁ⁿ(xᵢ-μ)²)/(n))\n5. 长根式：√(a²+b²+c²+d²+e²+f²)\n6. 嵌套根式：√(1+√(1+x²))\n7. 分式嵌套：√((1+(a+b)/(c+d))/(1+(x+1)/(x+2)))\n8. 根指数与下标：³√(x₁²+x₂²)，√(aₙ²+bₙ²)";
    for (key, name) in [
        ("yunyan", "云烟体"),
        ("huayang", "华阳手写体"),
        ("liguofu", "李国夫手写体"),
        ("wenkai", "霞鹜文楷"),
    ] {
        let font = FontBook::load(&fs::read(dir.join(format!("{name}.ttf")))?)?;
        let fonts = FontBook::with_text_fallbacks(font, text, |name| {
            Ok(Some(FontBook::load(&fs::read(dir.join(name)).unwrap())?))
        })?;
        let r = RenderRequest {
            text: text.into(),
            fonts,
            background: None,
            limits: Limits::default(),
            params: Parameters {
                width: Some(1500),
                height: Some(1800),
                font_size: 54.,
                line_spacing: 155.,
                left_margin: 85.,
                right_margin: 85.,
                top_margin: 30.,
                bottom_margin: 70.,
                underlined: true,
                font_size_sigma: 0.,
                word_spacing_sigma: 0.,
                perturb_x_sigma: 0.6,
                perturb_y_sigma: 0.6,
                perturb_theta_sigma: 0.01,
                ink_depth_sigma: 5.,
                strikethrough_probability: 0.,
                preview: false,
                seed: 20261024,
                ..Parameters::default()
            },
        };
        render(&r, &Cancellation::default(), |index, image| {
            fs::write(
                output.join(format!("{key}-{}.png", index + 1)),
                export::png(&image)?,
            )
            .unwrap();
            Ok(())
        })?;
    }
    Ok(())
}
