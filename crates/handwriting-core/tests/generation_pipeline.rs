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
fn standard_wrap_keeps_words_and_closing_punctuation_with_their_neighbours() {
    fn lines(text: &str, width: u32) -> Vec<String> {
        let mut req = request(text);
        req.params.width = Some(width);
        req.params.monospaced = true;
        req.params.fine_edit = true;
        req.params.full_preview = true;
        let source: Vec<_> = text.encode_utf16().collect();
        let (_, glyphs) = fine_edit::inspect_page(&req, 1, &Cancellation::default()).unwrap();
        let mut lines = Vec::<String>::new();
        let mut previous = None;
        for glyph in glyphs {
            if previous != Some(glyph.baseline) {
                lines.push(String::new());
                previous = Some(glyph.baseline);
            }
            let [start, end] = glyph.source_utf16.unwrap();
            let letters = String::from_utf16(&source[start as usize..end as usize]).unwrap();
            lines.last_mut().unwrap().push_str(&letters);
        }
        lines
    }
    assert_eq!(lines("12345 planet,", 140), ["12345", "planet,"]);
    assert_eq!(lines("中文混排好，", 140), ["中文混排", "好，"]);
    assert_eq!(lines("中文 planet!", 140), ["中文", "planet!"]);
    assert_eq!(lines("12345 nice ,", 140), ["12345", "nice,"]);
    assert_eq!(lines("a              ,", 140), ["a,"]);
    assert_eq!(lines("prefix don't", 140), ["prefix", "don't"]);
    assert_eq!(lines("1234567890123456", 140), ["1234567890", "123456"]);
    assert_eq!(lines("end\n，start", 140), ["end", "，start"]);
}

#[test]
fn transparent_png_and_zip_keep_ink_alpha_and_pdf_keeps_the_paper() {
    use base64::{Engine, engine::general_purpose::STANDARD};
    let cancel = Cancellation::default();
    for (uploaded, layered, fine) in [
        (false, false, false),
        (false, true, false),
        (true, true, false),
        (true, true, true),
    ] {
        let mut req = request("Ink\n---\nTwo");
        req.params.preview = false;
        req.params.underlined = true;
        req.params.ink_layers = layered;
        req.params.fine_edit = fine;
        req.params.fill = [35, 90, 160, 160];
        if uploaded {
            req.params.width = None;
            req.params.height = None;
            req.background = Some(
                export::png(&image::RgbaImage::from_pixel(
                    240,
                    180,
                    image::Rgba([32, 40, 55, 255]),
                ))
                .unwrap(),
            );
        }
        let pdf = |req: &RenderRequest| {
            let mut bytes = Vec::new();
            generation::generate(req, &cancel, Output::Pdf(&mut bytes), |_| Ok(())).unwrap();
            bytes
        };
        let opaque_pdf = pdf(&req);
        req.params.transparent_background = true;
        assert_eq!(pdf(&req), opaque_pdf);
        let mut pngs = Vec::new();
        generation::generate(
            &req,
            &cancel,
            Output::Preview(&mut |_, bytes| {
                let im = image::load_from_memory(&bytes).unwrap().to_rgba8();
                assert_eq!(im.dimensions(), (240, 180));
                assert_eq!(im[(0, 0)][3], 0);
                assert_eq!(im[(150, 46)][3], 0);
                assert!(im.pixels().any(|p| p[3] > 0 && p[3] < 255 && p[2] > p[0]));
                pngs.push(bytes);
                Ok(())
            }),
            |_| Ok(()),
        )
        .unwrap();
        assert_eq!(pngs.len(), 2);
        if layered {
            generation::generate(
                &req,
                &cancel,
                Output::InkLayers(&mut |_, page| {
                    let paper = image::load_from_memory(&STANDARD.decode(page.paper).unwrap())
                        .unwrap()
                        .to_rgba8();
                    assert!(paper.pixels().all(|p| p[3] == 0));
                    Ok(())
                }),
                |_| Ok(()),
            )
            .unwrap();
        }
        let mut bytes = Cursor::new(vec![]);
        generation::generate(&req, &cancel, Output::Zip(&mut bytes), |_| Ok(())).unwrap();
        let mut zip = zip::ZipArchive::new(bytes).unwrap();
        assert_eq!(zip.len(), pngs.len());
        for (index, png) in pngs.iter().enumerate() {
            let mut entry = Vec::new();
            zip.by_index(index)
                .unwrap()
                .read_to_end(&mut entry)
                .unwrap();
            assert_eq!(&entry, png);
        }
    }
}

#[test]
fn preview_prefix_stops_before_the_next_page_and_matches_export() {
    let mut request = request("第一页\n---\n第二页\n---\n第三页");
    request.params.preview = false;
    let cancel = Cancellation::default();
    let mut full = Vec::new();
    assert_eq!(
        render(&request, &cancel, |_, page| {
            full.push(page);
            Ok(())
        })
        .unwrap(),
        3
    );
    request.limits.max_pages = 2;
    let mut prefix = Vec::new();
    let count = render::render_until_page(&request, &cancel, 2, |_, page| {
        prefix.push(page);
        Ok(())
    })
    .unwrap();
    assert_eq!(count, 2);
    assert_eq!(prefix, full[..2]);
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
            warp: Some([1., 0., 0., 0., 1., 0., 0.004, 0.]),
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

#[test]
fn photo_camera_tags_and_manual_fallback_survive_page_exports() {
    use base64::{Engine, engine::general_purpose::STANDARD};
    use exif::{Field, In, Reader, Tag, Value, experimental::Writer};
    use image::ImageEncoder;
    let mut source = Cursor::new(vec![]);
    let mut writer = Writer::new();
    let fields = [
        (Tag::Model, Value::Ascii(vec![b"Source phone".to_vec()])),
        (Tag::ExposureTime, Value::Rational(vec![(1, 125).into()])),
        (Tag::Orientation, Value::Short(vec![6])),
        (
            Tag::BodySerialNumber,
            Value::Ascii(vec![b"private serial".to_vec()]),
        ),
        (Tag::GPSLongitudeRef, Value::Ascii(vec![b"E".to_vec()])),
    ]
    .map(|(tag, value)| Field {
        tag,
        value,
        ifd_num: In::PRIMARY,
    });
    for f in &fields {
        writer.push_field(f);
    }
    writer.write(&mut source, false).unwrap();
    let mut jpeg = Vec::new();
    let mut encoder = image::codecs::jpeg::JpegEncoder::new(&mut jpeg);
    encoder.set_exif_metadata(source.into_inner()).unwrap();
    encoder
        .encode_image(&image::RgbImage::from_pixel(180, 240, image::Rgb([240; 3])))
        .unwrap();

    let mut req = request("hello\n---\nworld");
    req.background = Some(jpeg);
    req.params.preview = false;
    req.params.camera.camera_model = Some("Ignored model".into());
    req.params.camera.camera_iso = Some(400);
    let cancel = Cancellation::default();
    let mut pages = vec![];
    generation::generate(
        &req,
        &cancel,
        Output::Preview(&mut |_, page| {
            pages.push(page);
            Ok(())
        }),
        |_| Ok(()),
    )
    .unwrap();
    assert_eq!(pages.len(), 2);
    let verify = |exif: exif::Exif| {
        let field = |tag| &exif.get_field(tag, In::PRIMARY).unwrap().value;
        assert!(matches!(field(Tag::Model), Value::Ascii(v) if v[0] == b"Source phone"));
        assert_eq!(field(Tag::PhotographicSensitivity).get_uint(0), Some(400));
        assert!(
            matches!(field(Tag::ExposureTime), Value::Rational(v) if (v[0].num, v[0].denom) == (1, 125))
        );
        assert!(
            matches!(field(Tag::ImageDescription), Value::Ascii(v) if v[0].ends_with(b"User supplied: ISO."))
        );
        for tag in [
            Tag::Orientation,
            Tag::GPSLongitudeRef,
            Tag::BodySerialNumber,
        ] {
            assert!(exif.get_field(tag, In::PRIMARY).is_none());
        }
    };
    let mut zip = Cursor::new(vec![]);
    generation::generate(&req, &cancel, Output::Zip(&mut zip), |_| Ok(())).unwrap();
    let mut zip = zip::ZipArchive::new(zip).unwrap();
    for (index, page) in pages.iter().enumerate() {
        verify(
            Reader::new()
                .read_from_container(&mut Cursor::new(page))
                .unwrap(),
        );
        let mut archived = vec![];
        zip.by_index(index)
            .unwrap()
            .read_to_end(&mut archived)
            .unwrap();
        assert_eq!(&archived, page);
    }
    let mut pdf = vec![];
    generation::generate(&req, &cancel, Output::Pdf(&mut pdf), |_| Ok(())).unwrap();
    let doc = pdf_extract::Document::load_mem(&pdf).unwrap();
    let info_id = doc.trailer.get(b"Info").unwrap().as_reference().unwrap();
    let info = doc.get_dictionary(info_id).unwrap();
    let subject = pdf_extract::decode_text_string(info.get(b"Subject").unwrap()).unwrap();
    assert!(subject.contains("Source phone") && subject.contains("User supplied: ISO."));
    req.params.ink_layers = true;
    generation::generate(
        &req,
        &cancel,
        Output::InkLayers(&mut |_, page| {
            verify(
                Reader::new()
                    .read_raw(STANDARD.decode(page.camera_exif.unwrap()).unwrap())
                    .unwrap(),
            );
            Ok(())
        }),
        |_| Ok(()),
    )
    .unwrap();
}
