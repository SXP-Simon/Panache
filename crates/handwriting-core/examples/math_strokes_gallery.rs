//! 2026-10-24：同参数多字体数学笔画对比，输出真实引擎横线纸预览。
use handwriting_core::{Cancellation, FontBook, Limits, Parameters, RenderRequest, export, render};
use std::{env, fs, path::PathBuf};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let output = PathBuf::from(env::args_os().nth(1).ok_or("output directory required")?);
    fs::create_dir_all(&output)?;
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../assets/font_assets");
    let text = "离散数学：推理与证明\n1. 拒取式：(A→B)∧¬B ⇒ ¬A\n2. 析取三段论：(A∨B)∧¬A ⇒ B\n3. 等价关系：A↔B，A⇔B；反向推导：B←A，B⇐A。\n4. 序关系：a<b，b>a，x≤y，y≥x，x≠y，x≈y。\n数值分析：误差估计与根式\n5. |Rₙ|≤(M)/(n+1)! × |x-a|ⁿ⁺¹\n6. 标准差：σ=√((Σᵢ₌₁ⁿ(xᵢ-μ)²)/(n))\n7. 嵌套分式：R=(1)/(1+(x+1)/(x+2))\n8. 根式：√(x²+y²)，∛(1+x)，√((a+b)/(c+d))\n结论：符号笔画随所选字体，数学含义与连接关系保持。";
    for (name, file) in [
        ("yunyan", "云烟体"),
        ("huayang", "华阳手写体"),
        ("liguofu", "李国夫手写体"),
        ("wenkai", "霞鹜文楷"),
    ] {
        let primary = FontBook::load(&fs::read(dir.join(format!("{file}.ttf")))?)?;
        let fonts = FontBook::with_text_fallbacks(primary, text, |name| {
            Ok(Some(FontBook::load(&fs::read(dir.join(name)).unwrap())?))
        })?;
        let request = RenderRequest {
            text: text.into(),
            fonts,
            background: None,
            limits: Limits::default(),
            params: Parameters {
                width: Some(1500),
                height: Some(1900),
                font_size: 58.,
                line_spacing: 126.,
                left_margin: 70.,
                right_margin: 70.,
                top_margin: 34.,
                bottom_margin: 70.,
                underlined: true,
                font_size_sigma: 0.,
                word_spacing: 1.,
                word_spacing_sigma: 0.,
                line_spacing_sigma: 0.,
                perturb_x_sigma: 0.7,
                perturb_y_sigma: 0.7,
                perturb_theta_sigma: 0.015,
                ink_depth_sigma: 5.,
                strikethrough_probability: 0.,
                preview: false,
                seed: 20261024,
                ..Parameters::default()
            },
        };
        render(&request, &Cancellation::default(), |index, image| {
            fs::write(
                output.join(format!("{name}-{}.png", index + 1)),
                export::png(&image)?,
            )
            .unwrap();
            Ok(())
        })?;
    }
    Ok(())
}
