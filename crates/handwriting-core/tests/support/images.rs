// 2026-10-16：生成无法高比例压缩的真实 PNG，覆盖超过原正文字符限额的照片负载。
pub fn image_document() -> String {
    use base64::{Engine, engine::general_purpose::STANDARD};
    let mut state = 42u32;
    let mut image = image::RgbaImage::new(180, 180);
    for pixel in image.pixels_mut() {
        let mut rgb = [0u8; 4];
        for channel in &mut rgb[..3] {
            state = state.wrapping_mul(1664525).wrapping_add(1013904223);
            *channel = (state >> 24) as u8;
        }
        rgb[3] = 255;
        *pixel = image::Rgba(rgb);
    }
    let bytes = handwriting_core::export::png(&image).unwrap();
    let data = STANDARD.encode(bytes);
    assert!(data.len() > 100_000);
    format!("前文\n![图|50%](data:image/png;base64,{data})\n---\n后文")
}
