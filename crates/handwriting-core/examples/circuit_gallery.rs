//! 2026-10-22：生产引擎导出常见作业电路样张，字体随用户选择。
use handwriting_core::{Cancellation, FontBook, Limits, Parameters, RenderRequest, export, render};
use std::{env, fs, path::PathBuf};
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = env::args_os().collect();
    if args.len() < 3 {
        return Err("usage: circuit_gallery FONT_DIR OUTPUT_DIR [FONT_NAME]".into());
    }
    let dir = PathBuf::from(&args[1]);
    let output = PathBuf::from(&args[2]);
    fs::create_dir_all(&output)?;
    let font = args.get(3).map_or_else(
        || "霞鹜文楷.ttf".into(),
        |s| s.to_string_lossy().into_owned(),
    );
    let fixtures: serde_json::Value =
        serde_json::from_str(include_str!("../tests/fixtures/circuitikz.json"))?;
    let titles = [
        ("rc-lowpass", "RC 低通滤波"),
        ("rlc-ac", "RLC 交流串联"),
        ("parallel-current", "并联分流"),
        ("switch-capacitor", "开关与电容充电"),
        ("diode-bridge", "二极管整流桥"),
        ("orthogonal-ports", "直角布线、端口与接地"),
        ("unit-labels", "单位与数学标签"),
        ("reverse-led", "反向路径与 LED"),
        ("annotation-rp", "电压与电流标注"),
        ("component-shorthand", "元件值简写"),
    ];
    let primary = FontBook::load(&fs::read(dir.join(&font))?)?;
    for (page, pair) in titles.chunks(2).enumerate() {
        let text = pair
            .iter()
            .map(|(id, title)| {
                let source = if *id=="annotation-rp" { r"\begin{circuitikz}[RPvoltages]\draw (0,0) to[R,l=$R$,i=$i(t)$,v_=$u_R$] (6,0);\end{circuitikz}" }else { fixtures
                    .as_array()
                    .unwrap()
                    .iter()
                    .find(|c| c["id"] == *id)
                    .unwrap()["source"]
                    .as_str()
                    .unwrap() };
                assert!(handwriting_core::text::circuit::parse(source).is_some(),"{id} must render as circuit");
                format!("{title}\n\n{source}")
            })
            .collect::<Vec<_>>()
            .join("\n\n\n");
        let fonts = FontBook::with_text_fallbacks(primary.clone(), &text, |name| {
            Ok(Some(FontBook::load(&fs::read(dir.join(name)).map_err(
                |e| handwriting_core::Error::new("font_io", e.to_string()),
            )?)?))
        })?;
        let request = RenderRequest {
            text: text.clone(),
            fonts,
            background: None,
            limits: Limits::default(),
            params: Parameters {
                font_size: 68.,
                line_spacing: 100.,
                word_spacing: 1.,
                width: Some(1500),
                height: Some(1800),
                left_margin: 110.,
                right_margin: 110.,
                top_margin: 90.,
                bottom_margin: 90.,
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
        render(&request, &Cancellation::default(), |index, image| {
            fs::write(
                output.join(format!("circuit-{}-{}.png", page + 1, index + 1)),
                export::png(&image)?,
            )
            .unwrap();
            Ok(())
        })?;
        fs::write(output.join(format!("circuit-{}.txt", page + 1)), text)?;
    }
    Ok(())
}
