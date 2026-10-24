use handwriting_core::{
    Cancellation, FontBook, LayoutStyle, Limits, Parameters, RenderRequest, render,
};
use image::RgbaImage;
use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{Arc, OnceLock},
};
fn request(text: &str, style: LayoutStyle, width: u32) -> RenderRequest {
    static FONT: OnceLock<Arc<fontdue::Font>> = OnceLock::new();
    let font = FONT
        .get_or_init(|| {
            FontBook::load(
                &std::fs::read(
                    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                        .join("../../assets/font_assets/霞鹜文楷.ttf"),
                )
                .unwrap(),
            )
            .unwrap()
        })
        .clone();
    RenderRequest {
        text: text.into(),
        fonts: FontBook::from_fonts(font, vec![]),
        background: None,
        limits: Limits::default(),
        params: Parameters {
            layout_style: style,
            width: Some(width),
            height: Some(480),
            font_size: 24.,
            line_spacing: 42.,
            left_margin: 20.,
            right_margin: 20.,
            top_margin: 20.,
            bottom_margin: 20.,
            background_ruled: true,
            underlined: false,
            word_spacing: 1.,
            font_size_sigma: 0.,
            word_spacing_sigma: 0.,
            line_spacing_sigma: 0.,
            perturb_x_sigma: 0.,
            perturb_y_sigma: 0.,
            perturb_theta_sigma: 0.,
            ink_depth_sigma: 0.,
            strikethrough_probability: 0.,
            preview: false,
            seed: 42,
            ..Parameters::default()
        },
    }
}
fn pages(r: &RenderRequest) -> Vec<RgbaImage> {
    let mut result = vec![];
    render(r, &Cancellation::default(), |_, image| {
        result.push(image);
        Ok(())
    })
    .unwrap();
    result
}
#[test]
fn layout_style_contract_defaults_and_rejects_unknown_values() {
    assert_eq!(
        Parameters::from_form(&HashMap::new()).unwrap().layout_style,
        LayoutStyle::Standard
    );
    assert_eq!(
        Parameters::from_form(&HashMap::from([("layout_style".into(), "homework".into())]))
            .unwrap()
            .layout_style,
        LayoutStyle::Homework
    );
    assert!(
        Parameters::from_form(&HashMap::from([("layout_style".into(), "mystery".into())])).is_err()
    );
    let mut old = serde_json::to_value(Parameters::default()).unwrap();
    old.as_object_mut().unwrap().remove("layout_style");
    assert_eq!(
        serde_json::from_value::<Parameters>(old)
            .unwrap()
            .layout_style,
        LayoutStyle::Standard
    );
}
#[test]
fn standard_remains_identical_and_homework_keeps_paper_rules_unchanged() {
    let mut r = request(
        "1. 第一题\n(1) 这里是一段需要换行的说明文字，包含 x₁² 和 (a+b)/(c+d)。\n2. 第二题",
        LayoutStyle::Standard,
        420,
    );
    r.params.underlined = true;
    let before = pages(&r);
    r.params.layout_style = LayoutStyle::Homework;
    let after = pages(&r);
    assert_ne!(before, after);
    for image in before.iter().chain(after.iter()) {
        for y in (62..460).step_by(42) {
            assert!(image[(21, y)][0] < 200, "paper ruling changed at {y}");
        }
    }
    r.params.layout_style = LayoutStyle::Standard;
    assert_eq!(pages(&r), before);
}
#[test]
fn long_homework_math_and_tables_fit_narrow_pages_without_lost_sections() {
    let source = "第一题：逻辑证明\n(1) 附加律：A ⇒ A∨B。这里还有足够长的文字，需要检查续行对齐。\n(2) (A→B)∧(C→D)∧(A∨C) ⇒ (B∨D)\nR=(1)/(1+(x+1)/(x+2)) + √((x₁²+x₂²)/(x₃²+x₄²)) = 1。\n⟦X | 0 | 1; P | (1)/(3) | (2)/(3)⟧\n---\n最终结论：全部内容保留。";
    for width in [120, 260, 600] {
        let r = request(source, LayoutStyle::Homework, width);
        let output = pages(&r);
        assert!(output.len() >= 2 && output.len() < 30);
        for image in output {
            let ink: Vec<_> = image
                .enumerate_pixels()
                .filter(|(_, _, p)| p[0] < 180)
                .collect();
            assert!(!ink.is_empty());
            assert!(
                ink.iter()
                    .all(|(x, y, _)| *x >= 19 && *x < width - 18 && *y >= 19 && *y < 461)
            );
        }
    }
}
#[test]
fn cancelled_homework_emits_no_page() {
    let cancel = Cancellation::default();
    cancel.cancel();
    let mut count = 0;
    let error = render(
        &request("(1) 说明", LayoutStyle::Homework, 300),
        &cancel,
        |_, _| {
            count += 1;
            Ok(())
        },
    )
    .unwrap_err();
    assert_eq!(error.code, "cancelled");
    assert_eq!(count, 0);
}
#[test]
fn homework_keeps_images_and_circuits_inside_the_body_and_cancels_between_pages() {
    use base64::{Engine as _, engine::general_purpose::STANDARD};
    let mut png = std::io::Cursor::new(Vec::new());
    RgbaImage::from_fn(120, 60, |x, y| {
        let value = if (x / 20 + y / 20) % 2 == 0 { 0 } else { 255 };
        image::Rgba([value, value, value, 255])
    })
    .write_to(&mut png, image::ImageFormat::Png)
    .unwrap();
    let fixtures: serde_json::Value =
        serde_json::from_str(include_str!("fixtures/realistic-circuits.json")).unwrap();
    let circuit = fixtures[0]["source"].as_str().unwrap();
    let encoded = STANDARD.encode(png.into_inner());
    let image_source = format!("![figure](data:image/png;base64,{encoded})");
    let image_only = pages(&request(&image_source, LayoutStyle::Homework, 600));
    let ink: Vec<_> = image_only
        .iter()
        .flat_map(|image| image.enumerate_pixels())
        .filter(|(_, _, p)| p[0] < 180)
        .collect();
    assert!(
        !ink.is_empty(),
        "inline image must remain present after the sketch filter"
    );
    assert!(ink.iter().all(|(x, _, _)| *x >= 50 && *x < 550));
    let source = format!(
        "第1题：图示\n(1) 图片：![figure](data:image/png;base64,{})\n(2) 电路：\n{circuit}\n---\n最后一页仍应保留。",
        encoded
    );
    let r = request(&source, LayoutStyle::Homework, 600);
    let output = pages(&r);
    assert!(output.len() >= 2);
    let cancel = Cancellation::default();
    let mut count = 0;
    let error = render(&r, &cancel, |_, _| {
        count += 1;
        cancel.cancel();
        Ok(())
    })
    .unwrap_err();
    assert_eq!(error.code, "cancelled");
    assert_eq!(count, 1);
}
