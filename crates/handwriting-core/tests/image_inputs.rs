use handwriting_core::{Limits, imaging, render::Cancellation};
use image::{DynamicImage, ImageEncoder, Rgba, RgbaImage};
use std::io::Cursor;

#[test]
fn transparent_line_matches_opaque_white_background() {
    let mut transparent = RgbaImage::new(80, 60);
    for x in 10..70 {
        for y in 29..32 {
            transparent[(x, y)] = Rgba([0, 0, 0, 255]);
        }
    }
    let mut opaque = RgbaImage::from_pixel(80, 60, Rgba([255, 255, 255, 255]));
    image::imageops::overlay(&mut opaque, &transparent, 0, 0);
    let render = |image| {
        imaging::handdrawn(
            &DynamicImage::ImageRgba8(image),
            123,
            &Cancellation::default(),
        )
        .unwrap()
    };
    let result = render(transparent);
    assert_eq!(result, render(opaque));
    assert_eq!(result[(0, 0)][3], 0);
    assert!(result.pixels().any(|p| p[3] > 0));
}

#[test]
fn large_image_scale_is_relative_to_fitted_size() {
    let image = RgbaImage::new(1000, 800);
    assert_eq!(imaging::fit(&image, 500, 300, 1.).dimensions(), (375, 300));
    assert_eq!(imaging::fit(&image, 500, 300, 0.5).dimensions(), (187, 150));
    assert_eq!(imaging::fit(&image, 500, 300, 7.).dimensions(), (375, 300));
}

#[test]
fn jpeg_exif_orientation_is_applied_after_bounded_decode() {
    // TIFF orientation tag 274, little endian, rotation 90 degrees clockwise.
    let exif = vec![
        b'I', b'I', 42, 0, 8, 0, 0, 0, 1, 0, 0x12, 1, 3, 0, 1, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0, 0,
    ];
    let mut bytes = Vec::new();
    let mut encoder = image::codecs::jpeg::JpegEncoder::new(&mut bytes);
    encoder.set_exif_metadata(exif).unwrap();
    encoder
        .encode_image(&DynamicImage::new_rgb8(20, 10))
        .unwrap();
    let decoded = imaging::decode(&bytes, &Limits::default()).unwrap();
    assert_eq!((decoded.width(), decoded.height()), (10, 20));
    let limited = Limits {
        max_pixels: 100,
        ..Limits::default()
    };
    assert_eq!(
        imaging::decode(&bytes, &limited).unwrap_err().code,
        "image_limit"
    );
    let mut png = Cursor::new(Vec::new());
    decoded.write_to(&mut png, image::ImageFormat::Png).unwrap();
    assert!(imaging::decode(&png.into_inner(), &Limits::default()).is_ok());
}
