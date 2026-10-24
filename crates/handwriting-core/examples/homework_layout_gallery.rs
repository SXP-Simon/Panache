//! 2026-10-24：标准排版与作业笔记使用同一字体、原文和横线背景，便于人工比较。
use handwriting_core::{
    Cancellation, FontBook, LayoutStyle, Limits, Parameters, RenderRequest, export, render,
};
use std::{env, fs, path::PathBuf};
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let output = PathBuf::from(
        env::args_os()
            .nth(1)
            .ok_or("usage: homework_layout_gallery OUTPUT_DIR")?,
    );
    fs::create_dir_all(&output)?;
    let font_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../assets/font_assets");
    let source = "第1题：共同近邻与图上的相似度\n给定无向图，分别计算下列点对的共同近邻及 SNN 相似度。\n1. 点对 (1, 2)\nN(1)={2,3,4}，N(2)={1,3,4}。\n(1) 两个顶点互为邻居。共同近邻是 {3,4}，因此相似度为 2。这一结论只依赖邻域交集，不计入顶点自身。\n(2) 记住：先计算两个邻域，再判断邻接关系，最后检查共同近邻的数量，避免把顶点自身当作共同邻居。\nSNN(1,2)=|N(1)∩N(2)|=|{3,4}|=2。\n2. 点对 (3, 4)\nN(3)={1,2,4}，N(4)={1,2,3}。\n(1) N(3)∩N(4)={1,2}，所以 SNN(3,4)=2。\n第2题：概率与数值积分\n1. 验证离散分布的归一化条件\nP(X=0)+P(X=1)+P(X=2)+P(X=3)=(8)/(15)+(4)/(15)+(2)/(15)+(1)/(15)=1。\n(1) 数学期望：E(X)=0×(8)/(15)+1×(4)/(15)+2×(2)/(15)+3×(1)/(15)=(11)/(15)。\n(2) 较长的推导优先在等号或加号处续行，分数、根式和上下标仍然作为完整书写单元。\n2. 检验求积公式的代数精度\n∫₀¹ x² dx=(1)/(3)，Q(x²)=(1)/(2)((1)/(2)-(1)/(2√(3)))²+(1)/(2)((1)/(2)+(1)/(2√(3)))²=(1)/(3)。\n结论：纸张横线不变，只调整正文留白与条目层次。";
    let source = if let Some(path) = env::args_os().nth(2) {
        fs::read_to_string(path)?
    } else {
        source.to_owned()
    };
    fs::write(output.join("source.txt"), &source)?;
    let primary = FontBook::load(&fs::read(font_dir.join("云烟体.ttf"))?)?;
    for (name, style) in [
        ("standard", LayoutStyle::Standard),
        ("homework", LayoutStyle::Homework),
    ] {
        let fonts = FontBook::with_text_fallbacks(primary.clone(), &source, |name| {
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
                layout_style: style,
                width: Some(1200),
                height: Some(1697),
                font_size: 46.,
                line_spacing: 82.,
                left_margin: 35.,
                right_margin: 35.,
                top_margin: 28.,
                bottom_margin: 64.,
                underlined: true,
                font_size_sigma: 0.5,
                word_spacing: 1.,
                word_spacing_sigma: 0.5,
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
                output.join(format!("{name}-{}.png", index + 1)),
                export::png(&image)?,
            )
            .unwrap();
            Ok(())
        })?;
    }
    Ok(())
}
