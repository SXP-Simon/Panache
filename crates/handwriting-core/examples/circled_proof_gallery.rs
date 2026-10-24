//! 2026-10-24：用户原始命题证明及单双位圈号的真实引擎对比图。
use handwriting_core::{Cancellation, FontBook, Limits, Parameters, RenderRequest, export, render};
use std::{env, fs, path::PathBuf};
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let output = PathBuf::from(env::args_os().nth(1).ok_or("output directory required")?);
    fs::create_dir_all(&output)?;
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../assets/font_assets");
    let text = "（1）证明：\n① ¬(p∧¬q)　前提\n② q→¬r　前提\n③ r　前提\n④ ¬q　②③拒取式、双重否定律\n⑤ ¬p∨q　①德摩根律、双重否定律\n⑥ ¬p　⑤④析取三段论\n编号：⓪ ⑩ ⑪ ⑳ ㉑ ㉟ ㊱ ㊿\n引用：由①③得到④，再由⑤④得到⑥。";
    for (key, name) in [
        ("yunyan", "云烟体"),
        ("huayang", "华阳手写体"),
        ("liguofu", "李国夫手写体"),
        ("wenkai", "霞鹜文楷"),
    ] {
        let primary = FontBook::load(&fs::read(dir.join(format!("{name}.ttf")))?)?;
        let fonts = FontBook::with_text_fallbacks(primary, text, |name| {
            Ok(Some(FontBook::load(&fs::read(dir.join(name)).unwrap())?))
        })?;
        let request = RenderRequest {
            text: text.into(),
            fonts,
            background: None,
            limits: Limits::default(),
            params: Parameters {
                width: Some(1400),
                height: Some(1250),
                font_size: 54.,
                line_spacing: 112.,
                left_margin: 90.,
                right_margin: 90.,
                top_margin: 40.,
                bottom_margin: 60.,
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
        render(&request, &Cancellation::default(), |index, image| {
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
