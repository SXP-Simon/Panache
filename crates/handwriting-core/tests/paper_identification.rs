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
