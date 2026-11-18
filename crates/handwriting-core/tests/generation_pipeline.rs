//! 2026-10-31：固定请求对照原始 render/export 组合，验证共享编排不改变输出。
use handwriting_core::{
    generation::{self, Event, Output},
    *,
};
use std::{
    io::{Cursor, Read},
    path::PathBuf,
};
#[path = "support/images.rs"]
mod image_support;
fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}
fn request(text: &str) -> RenderRequest {
    static FONT: std::sync::OnceLock<std::sync::Arc<fontdue::Font>> = std::sync::OnceLock::new();
    let font = FONT
        .get_or_init(|| {
            FontBook::load(&std::fs::read(root().join("assets/font_assets/霞鹜文楷.ttf")).unwrap())
                .unwrap()
        })
        .clone();
    RenderRequest {
        text: text.into(),
        fonts: FontBook::from_fonts(font, vec![]),
        background: None,
        limits: Limits::default(),
        params: Parameters {
            font_size: 24.,
            line_spacing: 36.,
            width: Some(240),
            height: Some(180),
            left_margin: 10.,
            right_margin: 10.,
            top_margin: 10.,
            bottom_margin: 10.,
            font_size_sigma: 0.,
            word_spacing_sigma: 0.,
            line_spacing_sigma: 0.,
            perturb_x_sigma: 0.,
            perturb_y_sigma: 0.,
            perturb_theta_sigma: 0.,
            ink_depth_sigma: 0.,
            strikethrough_probability: 0.,
            seed: 42,
            ..Parameters::default()
        },
    }
}

#[test]
fn shared_pipeline_preserves_pages_pdf_and_zip() {
    for scenario in 0..5 {
        let mut request = request("手写 Hello √((a)/(b)) + x²\n---\n第二页");
        request.params.full_preview = true;
        request.params.perturb_x_sigma = 2.;
        request.params.perturb_theta_sigma = 0.03;
        if scenario == 1 {
            request.params.layout_style = LayoutStyle::Homework;
        }
        if scenario == 2 {
            request.background = Some(
                export::png(&image::RgbaImage::from_pixel(
                    240,
                    180,
                    image::Rgba([240, 235, 220, 255]),
                ))
                .unwrap(),
            );
        }
        if scenario == 3 {
            request.text = image_support::image_document();
        }
        if scenario == 4 {
            request.text = "分布表\n⟦ X | 0  1  2 ; ── ; P | ½  ¼  ¼ ⟧".into();
        }
        let cancel = Cancellation::default();
        let mut images = vec![];
        render(&request, &cancel, |_, image| {
            images.push(image);
            Ok(())
        })
        .unwrap();
        let expected: Vec<_> = images
            .iter()
            .map(|image| export::png(image).unwrap())
            .collect();
        let mut actual = vec![];
        let mut events = vec![];
        generation::generate(
            &request,
            &cancel,
            Output::Preview(&mut |index, bytes| {
                assert_eq!(index, actual.len());
                actual.push(bytes);
                Ok(())
            }),
            |event| {
                events.push(event);
                Ok(())
            },
        )
        .unwrap();
        assert_eq!(actual, expected);
        assert_eq!(events[0], Event::Rendering);
        assert_eq!(events.last(), Some(&Event::PageReady(expected.len())));
        let mut original_pdf = export::PdfExport::new();
        for image in &images {
            original_pdf.add(image).unwrap();
        }
        let mut actual_pdf = vec![];
        generation::generate(&request, &cancel, Output::Pdf(&mut actual_pdf), |_| Ok(())).unwrap();
        assert_eq!(actual_pdf, original_pdf.finish());
        let mut actual_zip = Cursor::new(vec![]);
        generation::generate(&request, &cancel, Output::Zip(&mut actual_zip), |_| Ok(())).unwrap();
        let mut archive = zip::ZipArchive::new(actual_zip).unwrap();
        assert_eq!(archive.len(), expected.len());
        for (index, png) in expected.iter().enumerate() {
            let mut bytes = vec![];
            archive
                .by_name(&format!("{index}.png"))
                .unwrap()
                .read_to_end(&mut bytes)
                .unwrap();
            assert_eq!(&bytes, png);
        }
    }
}

#[test]
fn cancellation_at_export_boundary_never_finishes_pdf() {
    let request = request("取消");
    let cancel = Cancellation::default();
    let mut pdf = vec![];
    let error = generation::generate(&request, &cancel, Output::Pdf(&mut pdf), |event| {
        if event == Event::Exporting {
            cancel.cancel();
        }
        Ok(())
    })
    .unwrap_err();
    assert_eq!(error.code, "cancelled");
    assert!(pdf.is_empty());
}

#[test]
fn failed_page_sink_stops_before_publishing_progress() {
    let request = request("失败");
    let mut events = vec![];
    let error = generation::generate(
        &request,
        &Cancellation::default(),
        Output::Preview(&mut |_, _| Err(Error::new("storage_failed", "disk full"))),
        |event| {
            events.push(event);
            Ok(())
        },
    )
    .unwrap_err();
    assert_eq!(error.code, "storage_failed");
    assert_eq!(events, [Event::Rendering]);
}

#[test]
fn fine_edit_moves_one_homework_character_and_exports_the_same_pages() {
    use fine_edit::{Adjustment, Adjustments};

    let cancel = Cancellation::default();
    let mut request = request("Wave 中文");
    request.params.fine_edit = true;
    request.params.full_preview = true;
    request.params.layout_style = LayoutStyle::Homework;
    request.params.underlined = true;

    let layers = |request: &RenderRequest| {
        let mut layers = Vec::new();
        generation::generate(
            request,
            &cancel,
            Output::InkLayers(&mut |_, page| {
                layers.push(page);
                Ok(())
            }),
            |_| Ok(()),
        )
        .unwrap();
        layers
    };
    let page_images = |request: &RenderRequest| {
        let mut images = Vec::new();
        render(request, &cancel, |_, page| {
            images.push(page);
            Ok(())
        })
        .unwrap();
        images
    };
    assert_eq!(
        layers(&request)[0].fine.as_ref().unwrap().source_ranges[..4],
        [Some([0, 1]), Some([1, 2]), Some([2, 3]), Some([3, 4])]
    );
    request.text = "Wave 中文\n---\nWave 中文".into();
    let before = page_images(&request);
    let preview = layers(&request);
    assert_eq!(preview.len(), 2);
    let fine = preview[0].fine.as_ref().unwrap();
    assert_eq!(fine.glyphs.len(), 6);
    assert!(preview[1].fine.as_ref().unwrap().glyphs[0][0] > fine.glyphs[5][0]);
    let [id, x, y, width, height, ..] = fine.glyphs[0];
    request.params.fine_edits = Some(Adjustments {
        key: fine.key.clone(),
        glyphs: vec![Adjustment {
            id: id as u32,
            dx: 90,
            dy: 49,
            scale: 115,
            angle: 12,
            opacity: 83,
            color: Some([167, 12, 36]),
            thickness: 7,
            softness: 4,
        }],
    });
    let after = page_images(&request);
    assert_eq!(before[1], after[1]);
    assert_ne!(before[0], after[0]);
    assert_eq!(layers(&request)[0].paper, preview[0].paper);
    assert!(
        after[0]
            .enumerate_pixels()
            .any(|(px, py, p)| { px as i32 > x + width && py as i32 > y + height && p[0] > p[1] })
    );
    let mut zip = Cursor::new(vec![]);
    generation::generate(&request, &cancel, Output::Zip(&mut zip), |_| Ok(())).unwrap();
    let mut archive = zip::ZipArchive::new(zip).unwrap();
    for (index, image) in after.iter().enumerate() {
        let mut bytes = vec![];
        archive
            .by_name(&format!("{index}.png"))
            .unwrap()
            .read_to_end(&mut bytes)
            .unwrap();
        assert_eq!(image::load_from_memory(&bytes).unwrap().to_rgba8(), *image);
    }
    let mut pdf = vec![];
    generation::generate(&request, &cancel, Output::Pdf(&mut pdf), |_| Ok(())).unwrap();
    let mut expected = export::PdfExport::lossless();
    for image in &after {
        expected.add(image).unwrap();
    }
    assert!(pdf == expected.finish(), "精细编辑 PDF 应嵌入无损页面");

    request.params.fine_edits.as_mut().unwrap().key = "0".repeat(64);
    assert_eq!(before, page_images(&request));
}
