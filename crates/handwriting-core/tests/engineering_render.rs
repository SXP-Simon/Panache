//! 2026-10-22：工程课程二维数学在窄纸、大字号、跨页场景的真实墨迹回归。
#[path = "../examples/support/engineering.rs"]
mod engineering;
use handwriting_core::{Cancellation, FontBook, Limits, Parameters, RenderRequest, export, render};
use std::{collections::HashMap, path::PathBuf};

fn structural_tables(nodes: &[handwriting_core::text::Node]) -> usize {
    use handwriting_core::text::Node;
    nodes
        .iter()
        .map(|node| match node {
            Node::Table(table) => {
                1 + table
                    .rows
                    .iter()
                    .flatten()
                    .map(|cell| structural_tables(cell))
                    .sum::<usize>()
            }
            Node::Fraction(a, b) | Node::Radical(a, b) => {
                structural_tables(a) + structural_tables(b)
            }
            Node::Scripts { upper, lower } => structural_tables(upper) + structural_tables(lower),
            Node::Accent(body, _) => structural_tables(body),
            _ => 0,
        })
        .sum()
}

fn request(source: &str, fonts: &FontBook, size: f32, width: u32, grid: bool) -> RenderRequest {
    RenderRequest {
        text: source.into(),
        fonts: fonts.clone(),
        background: None,
        limits: Limits::default(),
        params: Parameters {
            font_size: size,
            line_spacing: size * 1.2,
            word_spacing: 0.,
            width: Some(width),
            height: Some(360),
            left_margin: 18.,
            right_margin: 18.,
            top_margin: 18.,
            bottom_margin: 18.,
            font_size_sigma: 0.,
            word_spacing_sigma: 0.,
            line_spacing_sigma: 0.,
            perturb_x_sigma: 0.,
            perturb_y_sigma: 0.,
            perturb_theta_sigma: 0.,
            ink_depth_sigma: 0.,
            strikethrough_probability: 0.,
            grid_layout: grid,
            preview: false,
            seed: 20261022,
            ..Parameters::default()
        },
    }
}

#[test]
fn engineering_homework_stays_visible_inside_margins_and_exports_identically() {
    let directory = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../assets/font_assets");
    let available: HashMap<_, _> = handwriting_core::fonts::FALLBACK_FONT_NAMES
        .iter()
        .map(|name| {
            (
                *name,
                FontBook::load(&std::fs::read(directory.join(name)).unwrap()).unwrap(),
            )
        })
        .collect();
    let primary = available["霞鹜文楷.ttf"].clone();
    for (name, source) in engineering::CASES {
        assert_eq!(
            structural_tables(&handwriting_core::text::parse(source)),
            source.matches('⟦').count(),
            "{name}: structured source must not silently degrade to literal text"
        );
        let fonts = FontBook::with_text_fallbacks(primary.clone(), source, |name| {
            Ok(available.get(name).cloned())
        })
        .unwrap();
        for (size, width, grid) in [(24., 480, false), (70., 240, false), (48., 220, true)] {
            let mut count = 0;
            render(
                &request(source, &fonts, size, width, grid),
                &Cancellation::default(),
                |_, image| {
                    let mut ink = 0;
                    for (x, y, pixel) in image.enumerate_pixels() {
                        if pixel[0] < 128 {
                            ink += 1;
                            assert!(
                                x >= 18
                                    && y >= 18
                                    && x < image.width() - 18
                                    && y < image.height() - 18,
                                "{name}: clipped at {x},{y}"
                            );
                        }
                    }
                    assert!(ink > 20, "{name}: missing image");
                    assert_eq!(
                        image::load_from_memory(&export::png(&image)?)
                            .unwrap()
                            .to_rgba8(),
                        image
                    );
                    count += 1;
                    Ok(())
                },
            )
            .unwrap();
            assert!(count > 0);
        }
    }
}
