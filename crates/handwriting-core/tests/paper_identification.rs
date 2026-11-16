use base64::Engine;
use handwriting_core::{Limits, imaging};
use image::{DynamicImage, GrayImage, Luma};
use imageproc::geometric_transformations::{Border, Interpolation, rotate_about_center_no_crop};

fn paper(thickness: u32, ink: u8, background: u8, shadow: bool) -> GrayImage {
    GrayImage::from_fn(800, 1000, |x, y| {
        let shade = if shadow { (x * 25 / 800) as u8 } else { 0 };
        let line = (80..920)
            .step_by(70)
            .any(|line| y >= line && y < line + thickness);
        Luma([if line && (60..=740).contains(&x) {
            ink.saturating_sub(shade)
        } else {
            background.saturating_sub(shade)
        }])
    })
}
#[test]
fn faint_thick_and_shaded_rulings_have_one_center_per_line() {
    for (thickness, ink, bg, shadow) in [
        (1, 20, 255, false),
        (9, 20, 255, false),
        (14, 230, 245, false),
        (2, 237, 249, true),
        (4, 200, 235, true),
    ] {
        let detected =
            imaging::identify(&DynamicImage::ImageLuma8(paper(thickness, ink, bg, shadow)))
                .unwrap();
        assert!(
            (detected.line_spacing as i32 - 70).abs() <= 1,
            "{detected:?}"
        );
        assert!((detected.margin_top as i32 - (80 + (thickness - 1) / 2) as i32).abs() <= 1);
        assert_eq!(
            detected.layout_top_margin + detected.line_spacing,
            detected.margin_top
        );
        assert!(detected.layout_bottom_margin < detected.margin_bottom);
        assert!(detected.corrected_background.is_none());
    }
}
#[test]
fn corrected_background_and_geometry_share_the_same_coordinate_system() {
    for angle in [-7.3_f32, -2.25, 3.3, 8.0] {
        let source = rotate_about_center_no_crop(
            &paper(5, 205, 245, true),
            angle.to_radians(),
            Interpolation::Bilinear,
            Border::Constant(Luma([245])),
        );
        let detected = imaging::identify(&DynamicImage::ImageLuma8(source.clone())).unwrap();
        assert!(
            (detected.deskew_angle_degrees - angle).abs() <= 0.12,
            "{angle}: {detected:?}"
        );
        let png = base64::engine::general_purpose::STANDARD
            .decode(detected.corrected_background.as_ref().unwrap())
            .unwrap();
        let corrected = imaging::decode(&png, &Limits::default()).unwrap();
        assert_eq!(
            (corrected.width(), corrected.height()),
            (detected.image_width, detected.image_height)
        );
        assert!(corrected.width() >= source.width() && corrected.height() >= source.height());
        let recheck = imaging::identify(&corrected).unwrap();
        assert!(
            recheck.deskew_angle_degrees.abs() <= 0.1,
            "{angle}: {recheck:?}"
        );
        assert!(
            (recheck.margin_top as i32 - detected.margin_top as i32).abs() <= 2,
            "angle {angle} top {} vs {}; spacing {} vs {}",
            detected.margin_top,
            recheck.margin_top,
            detected.line_spacing,
            recheck.line_spacing
        );
        assert!((recheck.line_spacing as i32 - detected.line_spacing as i32).abs() <= 1);
        assert!((recheck.margin_left as i32 - detected.margin_left as i32).abs() <= 3);
    }
}
#[test]
fn blank_gradient_and_insufficient_lines_are_rejected() {
    let samples = [
        GrayImage::from_pixel(800, 1000, Luma([230])),
        GrayImage::from_fn(800, 1000, |_, y| Luma([(180 + y / 20) as u8])),
        GrayImage::from_fn(800, 1000, |x, y| {
            Luma([if x > 60 && x < 740 && (y == 80 || y == 150) {
                30
            } else {
                255
            }])
        }),
    ];
    for sample in samples {
        assert_eq!(
            imaging::identify(&DynamicImage::ImageLuma8(sample))
                .unwrap_err()
                .code,
            "identification_unreliable"
        );
    }
}
#[test]
fn top_edge_line_uses_next_available_notebook_baseline() {
    let sample = GrayImage::from_fn(800, 1000, |x, y| {
        Luma([if x > 60 && x < 740 && y >= 20 && (y - 20) % 70 < 3 {
            20
        } else {
            255
        }])
    });
    let detected = imaging::identify(&DynamicImage::ImageLuma8(sample)).unwrap();
    assert_eq!(detected.margin_top, 21);
    assert_eq!(detected.layout_top_margin, 21);
    assert_eq!(detected.layout_top_margin + detected.line_spacing, 91);
}

#[test]
fn printed_title_reserves_first_rule_as_a_separator() {
    for header in [false, true] {
        let source = GrayImage::from_fn(800, 1000, |x, y| {
            let ruling = (60..740).contains(&x) && y >= 160 && (y - 160) % 65 < 4;
            let title = header
                && (260..540).contains(&x)
                && (90..120).contains(&y)
                && ((x - 260) % 32 < 4
                    || (14..18).contains(&((x - 260) % 32))
                    || (y < 94 && (x - 260) % 32 < 18));
            Luma([if ruling || title { 24 } else { 245 }])
        });
        let result = imaging::identify(&DynamicImage::ImageLuma8(source)).unwrap();
        assert!(result.margin_top.abs_diff(162) <= 2);
        assert_eq!(result.line_spacing, 65);
        assert_eq!(
            result.layout_top_margin + result.line_spacing,
            result.margin_top + u32::from(header) * result.line_spacing
        );
    }
}

#[test]
fn distant_header_and_registration_marks_do_not_consume_dotted_body_rows() {
    let source = GrayImage::from_fn(800, 1000, |x, y| {
        let header = (260..540).contains(&x)
            && (153..181).contains(&y)
            && ((x - 260) % 32 < 4 || (y < 158 && (x - 260) % 32 < 19));
        let fields =
            (220..=223).contains(&y) && ((280..370).contains(&x) || (480..540).contains(&x));
        let sidebar = (105..109).contains(&x) && (385..821).contains(&y);
        let ruled = x % 5 < 3
            && (0..13).any(|i| {
                let center = 310.
                    + 38. * i as f32
                    + (i * (i - 1) / 2) as f32
                    + (x as f32 - 400.) * (i - 4) as f32 / 1000.;
                (145 - i as u32..670 + i as u32).contains(&x) && (y as f32 - center).abs() <= 1.
            });
        let paper = 245 - x / 55 - y.saturating_sub(550) / 18;
        Luma([if header || fields || sidebar {
            24
        } else {
            (paper - 25 * u32::from(ruled)) as u8
        }])
    });
    let result = imaging::identify(&DynamicImage::ImageLuma8(source)).unwrap();
    assert!(result.margin_top.abs_diff(310) <= 2);
    assert_eq!(
        result.layout_top_margin + result.line_spacing,
        result.margin_top
    );
    assert_eq!(result.line_spacing, 44);
    assert!((140..=180).contains(&result.margin_left));
    assert!((115..=150).contains(&result.margin_right));
    assert!((145..=170).contains(&result.margin_bottom));
    assert!(result.corrected_background.is_some());
}

#[test]
fn curved_and_perspective_rulings_are_flattened_before_layout() {
    let source = GrayImage::from_fn(800, 1000, |x, y| {
        let u = (x as f32 - 400.) / 400.;
        let ruled = (50..750).contains(&x)
            && (0..15).any(|i| {
                let center = 110. + 55. * i as f32 + 14. * u * u + (5. - i as f32) * u;
                (y as f32 - center.round()).abs() <= 2.
            });
        let header = (180..580).contains(&x) && (22..60).contains(&y);
        Luma([if ruled || header { 24 } else { 182 }])
    });
    let detected = imaging::identify(&DynamicImage::ImageLuma8(source)).unwrap();
    assert_eq!(detected.line_spacing, 55);
    assert!(detected.margin_top.abs_diff(110) <= 3);
    assert!(detected.margin_bottom.abs_diff(120) <= 3);
    let png = base64::engine::general_purpose::STANDARD
        .decode(detected.corrected_background.unwrap())
        .unwrap();
    let corrected = imaging::decode(&png, &Limits::default())
        .unwrap()
        .into_luma8();
    assert_eq!(corrected.dimensions(), (800, 1000));
    for x in [120, 400, 680] {
        for row in [0, 7, 14] {
            let y = detected.margin_top + row * detected.line_spacing;
            assert!((y - 2..=y + 2).any(|y| corrected[(x, y)][0] < 80));
        }
    }
}

#[test]
fn strong_perspective_keeps_faint_top_rows_and_common_writing_area() {
    check_perspective(false);
}

#[test]
fn isolated_track_gaps_do_not_discard_visible_rulings() {
    check_perspective(true);
}

fn check_perspective(broken_lines: bool) {
    let source = GrayImage::from_fn(960, 1200, |x, y| {
        let u = (x as f32 - 480.) / 480.;
        for row in 0..18 {
            let inset = 168 - row * 7;
            let r = row as f32;
            let center = 168. + 34. * r + r * r - (27. - r) * u + 9. * u * u;
            let occluded = broken_lines && row % 3 == 1 && (601..=628).contains(&x);
            if !occluded
                && (inset..960 - inset).contains(&x)
                && (y as f32 - center.round()).abs() <= 2.
            {
                return Luma([if row < 6 { 194 } else { 72 }]);
            }
        }
        let edge = 145u32.saturating_sub(y / 8);
        Luma([
            if (edge..960 - edge).contains(&x) && (65..1120).contains(&y) {
                220
            } else {
                42
            },
        ])
    });
    let detected = imaging::identify(&DynamicImage::ImageLuma8(source)).unwrap();
    assert!(detected.line_spacing.abs_diff(51) <= 1);
    assert!(detected.margin_top.abs_diff(168) <= 4);
    assert!(detected.margin_bottom.abs_diff(165) <= 8);
    assert!(detected.margin_left.min(detected.margin_right) >= 130);
    let png = base64::engine::general_purpose::STANDARD
        .decode(detected.corrected_background.unwrap())
        .unwrap();
    let corrected = imaging::decode(&png, &Limits::default())
        .unwrap()
        .into_luma8();
    for x in [280, 480, 680] {
        for row in [1, 8, 16] {
            let y = detected.margin_top + row * detected.line_spacing;
            assert!((y - 2..=y + 2).any(|y| corrected[(x, y)][0] < 215));
        }
    }
}
