//! 2026-10-24：复测用户原始命题证明，覆盖坏字形字体和两种实际页面布局。
use handwriting_core::{
    Cancellation, FontBook, LayoutStyle, Limits, Parameters, RenderRequest, export, render,
};
use std::{env, fs, path::PathBuf};

const PROOF: &str = "（1）证明：\n① ¬(p∧¬q)　前提\n② q→¬r　前提\n③ r　前提\n④ ¬q　②③拒取式、双重否定律\n⑤ ¬p∨q　①德摩根律、双重否定律\n⑥ ¬p　⑤④析取三段论";

#[test]
fn original_proof_renders_with_all_negations_in_both_layouts_and_bundled_fonts() {
    assert_eq!(PROOF.chars().filter(|c| *c == '¬').count(), 6);
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../assets/font_assets");
    let fallback = fs::read(root.join("霞鹜文楷.ttf")).unwrap();
    let output = env::var_os("PANACHE_PROOF_GALLERY").map(PathBuf::from);
    if let Some(path) = &output {
        fs::create_dir_all(path).unwrap();
    }
    for name in ["云烟体", "华阳手写体", "李国夫手写体", "霞鹜文楷"] {
        let fonts = FontBook::new(
            &fs::read(root.join(format!("{name}.ttf"))).unwrap(),
            std::slice::from_ref(&fallback),
        )
        .unwrap();
        for (style_name, style) in [
            ("standard", LayoutStyle::Standard),
            ("homework", LayoutStyle::Homework),
        ] {
            let request = RenderRequest {
                text: PROOF.into(),
                fonts: fonts.clone(),
                background: None,
                limits: Limits::default(),
                params: Parameters {
                    layout_style: style,
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
                    perturb_x_sigma: 0.,
                    perturb_y_sigma: 0.,
                    perturb_theta_sigma: 0.,
                    ink_depth_sigma: 0.,
                    strikethrough_probability: 0.,
                    preview: false,
                    ..Parameters::default()
                },
            };
            let mut count = 0;
            render(&request, &Cancellation::default(), |index, image| {
                assert_eq!(image.dimensions(), (1400, 1250));
                assert!(image.pixels().any(|pixel| pixel[1] < 150));
                if let Some(path) = &output {
                    fs::write(
                        path.join(format!("rust-{name}-{style_name}-{}.png", index + 1)),
                        export::png(&image)?,
                    )
                    .unwrap();
                }
                count += 1;
                Ok(())
            })
            .unwrap();
            assert_eq!(count, 1, "{name} {style_name}");
        }
    }
}
