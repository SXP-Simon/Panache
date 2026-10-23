//! 2026-10-23：复杂作业的拓扑、标签、全量分页与实际 PNG/PDF/ZIP 端到端回归。
#[path = "../examples/support/realistic_circuits.rs"]
mod realistic;
use handwriting_core::{Cancellation, FontBook, Limits, Parameters, RenderRequest, export, render};
use std::{collections::BTreeMap, io::Cursor, path::PathBuf};

#[test]
fn realistic_networks_preserve_components_and_export_every_page_inside_margins() {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../assets/font_assets");
    let cases = realistic::cases();
    for case in &cases {
        let circuit = handwriting_core::text::circuit::parse(&case.source).unwrap();
        let mut kinds = BTreeMap::new();
        for segment in &circuit.segments {
            if segment.kind != "short" {
                *kinds.entry(segment.kind.clone()).or_insert(0) += 1;
            }
        }
        assert_eq!(kinds, case.components, "{}", case.id);
        assert_eq!(
            handwriting_core::text::parse(&case.source)
                .iter()
                .filter(|n| matches!(n, handwriting_core::text::Node::Circuit(_)))
                .count(),
            1
        );
    }
    let text = cases
        .iter()
        .map(realistic::homework)
        .collect::<Vec<_>>()
        .join("\n\n");
    for name in ["霞鹜文楷.ttf", "云烟体.ttf"] {
        let primary = FontBook::load(&std::fs::read(dir.join(name)).unwrap()).unwrap();
        let fonts = FontBook::with_text_fallbacks(primary, &text, |name| {
            Ok(Some(FontBook::load(
                &std::fs::read(dir.join(name)).unwrap(),
            )?))
        })
        .unwrap();
        for width in [320, 1000] {
            let request = RenderRequest {
                text: text.clone(),
                fonts: fonts.clone(),
                background: None,
                limits: Limits::default(),
                params: Parameters {
                    font_size: 46.,
                    line_spacing: 65.,
                    // 此处验证几何版心，不引入与 Python 保持一致的双倍字距右边距补偿。
                    word_spacing: 0.,
                    width: Some(width),
                    height: Some(620),
                    left_margin: 24.,
                    right_margin: 24.,
                    top_margin: 24.,
                    bottom_margin: 24.,
                    font_size_sigma: 0.,
                    word_spacing_sigma: 0.,
                    line_spacing_sigma: 0.,
                    perturb_x_sigma: 0.,
                    perturb_y_sigma: 0.,
                    perturb_theta_sigma: 0.,
                    ink_depth_sigma: 0.,
                    strikethrough_probability: 0.,
                    underlined: false,
                    preview: false,
                    seed: 20261023,
                    ..Parameters::default()
                },
            };
            let mut expected = Vec::new();
            let mut pdf = export::PdfExport::new();
            let mut zip = export::ZipExport::new(Cursor::new(Vec::new()));
            render(&request, &Cancellation::default(), |index, image| {
                let mut ink = 0;
                for (x, y, p) in image.enumerate_pixels() {
                    if p[0] < 128 {
                        ink += 1;
                        assert!(
                            (24..width - 24).contains(&x) && (24..596).contains(&y),
                            "{name}/{width}: clipped label or wire {x},{y}"
                        );
                    }
                }
                assert!(ink > 100, "empty page {name}/{width}/{index}");
                let png = export::png(&image)?;
                assert_eq!(image::load_from_memory(&png).unwrap().to_rgba8(), image);
                expected.push(png);
                pdf.add(&image)?;
                zip.add(index, &image)
            })
            .unwrap();
            assert!(
                expected.len() > 4,
                "all four homework solutions must actually paginate"
            );
            let pdf = pdf.finish();
            assert!(pdf.starts_with(b"%PDF-"));
            assert!(
                pdf.windows(format!("/Count {}", expected.len()).len())
                    .any(|b| b == format!("/Count {}", expected.len()).as_bytes())
            );
            let bytes = zip.finish().unwrap().into_inner();
            let mut archive = zip::ZipArchive::new(Cursor::new(bytes)).unwrap();
            assert_eq!(archive.len(), expected.len());
            for (index, png) in expected.iter().enumerate() {
                let mut actual = Vec::new();
                std::io::Read::read_to_end(
                    &mut archive.by_name(&format!("{index}.png")).unwrap(),
                    &mut actual,
                )
                .unwrap();
                assert_eq!(&actual, png);
            }
        }
    }
}
