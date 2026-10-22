//! 2026-10-22：常见电路经过生产分页、栅格、PNG 导出；窄纸不切断拓扑。
use handwriting_core::{Cancellation, FontBook, Limits, Parameters, RenderRequest, export, render};
use std::path::PathBuf;
#[test]
fn circuits_fit_narrow_pages_and_png_roundtrips() {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../assets/font_assets");
    let font = std::fs::read(dir.join("霞鹜文楷.ttf")).unwrap();
    let fonts = FontBook::new(&font, &[]).unwrap();
    let fixtures: serde_json::Value =
        serde_json::from_str(include_str!("fixtures/circuitikz.json")).unwrap();
    for case in fixtures
        .as_array()
        .unwrap()
        .iter()
        .filter(|c| c["valid"] == true)
    {
        for width in [360, 960] {
            for underlined in [false, true] {
                let text = format!("Before\n{}\nAfter", case["source"].as_str().unwrap());
                let request = RenderRequest {
                    text,
                    fonts: fonts.clone(),
                    background: None,
                    limits: Limits::default(),
                    params: Parameters {
                        font_size: 54.,
                        line_spacing: 74.,
                        width: Some(width),
                        height: Some(620),
                        left_margin: 25.,
                        right_margin: 25.,
                        top_margin: 25.,
                        bottom_margin: 25.,
                        font_size_sigma: 0.,
                        word_spacing_sigma: 0.,
                        line_spacing_sigma: 0.,
                        perturb_x_sigma: 0.,
                        perturb_y_sigma: 0.,
                        perturb_theta_sigma: 0.,
                        ink_depth_sigma: 0.,
                        strikethrough_probability: 0.,
                        underlined,
                        preview: false,
                        ..Parameters::default()
                    },
                };
                let mut count = 0;
                render(&request, &Cancellation::default(), |_, image| {
                    count += 1;
                    assert_eq!(image.width(), width);
                    assert_eq!(image.height(), 620);
                    let png = export::png(&image)?;
                    let decoded = image::load_from_memory(&png).unwrap().to_rgba8();
                    assert_eq!(decoded, image);
                    let ink = decoded
                        .pixels()
                        .filter(|p| p[0] < 128 && p[1] < 128 && p[2] < 128)
                        .count();
                    assert!(ink > 100, "{}", case["id"]);
                    if !underlined {
                        for (x, y, p) in decoded.enumerate_pixels() {
                            if p[0] < 128 && p[1] < 128 && p[2] < 128 {
                                assert!(
                                    (25..width - 25).contains(&x) && (25..595).contains(&y),
                                    "{} {x} {y}",
                                    case["id"]
                                );
                            }
                        }
                    }
                    Ok(())
                })
                .unwrap();
                assert!(count > 0 && count < 8);
            }
        }
    }
}
