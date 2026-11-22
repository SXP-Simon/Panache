//! 2026-10-15：复合公式统一变换，不能把上下标、分数线、向量箭头作为独立连通域随机漂移。
use super::*;
use image::Pixel;
pub(in crate::render) fn paint_math_unit(
    canvas: &mut RgbaImage,
    mask: &GrayImage,
    origin: (i32, i32),
    p: &Parameters,
    align_to_rulings: bool,
    rng: &mut ChaCha8Rng,
    cancel: &Cancellation,
) -> Result<()> {
    let cx = (mask.width() - 1) as f32 / 2.;
    let cy = (mask.height() - 1) as f32 / 2.;
    let sampled_angle = normal(rng, p.perturb_theta_sigma);
    // 2026-11-22：横线纸上的整表或整图先与纸面平行，随后随纸面投影；保留字迹自身的扰动。
    let mut angle = if align_to_rulings { 0. } else { sampled_angle };
    let bounds = |angle: f32| {
        let mut bounds = (
            f32::INFINITY,
            f32::INFINITY,
            f32::NEG_INFINITY,
            f32::NEG_INFINITY,
        );
        for (x, y) in [(-cx, -cy), (cx, -cy), (-cx, cy), (cx, cy)] {
            let xx = x * angle.cos() + y * angle.sin() + cx;
            let yy = y * angle.cos() - x * angle.sin() + cy;
            bounds = (
                bounds.0.min(xx),
                bounds.1.min(yy),
                bounds.2.max(xx),
                bounds.3.max(yy),
            );
        }
        bounds
    };
    let mut b = bounds(angle);
    let (right, bottom) = (
        canvas.width() as f32 - p.effective_right_margin() - 1.,
        canvas.height() as f32 - p.bottom_margin - 1.,
    );
    if b.2 - b.0 > right - p.left_margin || b.3 - b.1 > bottom - p.top_margin {
        angle = 0.;
        b = bounds(angle);
    }
    let dx = normal(rng, p.perturb_x_sigma).clamp(
        p.left_margin - origin.0 as f32 - b.0,
        right - origin.0 as f32 - b.2,
    );
    let dy = normal(rng, p.perturb_y_sigma).clamp(
        p.top_margin - origin.1 as f32 - b.1,
        bottom - origin.1 as f32 - b.3,
    );
    let ink = normal(rng, p.ink_depth_sigma);
    let fill = Rgba([
        (p.fill[0] as f32 + ink).clamp(0., 255.) as u8,
        (p.fill[1] as f32 + ink).clamp(0., 255.) as u8,
        (p.fill[2] as f32 + ink).clamp(0., 255.) as u8,
        p.fill[3],
    ]);
    for (x, y, pixel) in mask.enumerate_pixels() {
        if x == 0 && y % 32 == 0 {
            cancel.check()?;
        }
        if pixel[0] < 128 {
            continue;
        }
        let (rx, ry) = (x as f32 - cx, y as f32 - cy);
        let nx = (rx * angle.cos() + ry * angle.sin() + cx + origin.0 as f32 + dx).round() as u32;
        let ny = (ry * angle.cos() - rx * angle.sin() + cy + origin.1 as f32 + dy).round() as u32;
        if nx < canvas.width() && ny < canvas.height() {
            canvas[(nx, ny)].blend(&fill);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use rand_chacha::rand_core::SeedableRng;

    #[test]
    fn locked_table_rules_stay_on_the_paper_axis_across_seeds() {
        let mut mask = GrayImage::new(201, 21);
        for y in [0, 20] {
            for x in 0..201 {
                mask[(x, y)] = Luma([255]);
            }
        }
        let p = Parameters {
            left_margin: 0.,
            right_margin: 0.,
            top_margin: 0.,
            bottom_margin: 0.,
            word_spacing: 0.,
            perturb_theta_sigma: 0.12,
            perturb_x_sigma: 0.,
            perturb_y_sigma: 0.,
            ..Default::default()
        };
        for seed in 0..8 {
            let mut canvas = RgbaImage::new(360, 180);
            paint_math_unit(
                &mut canvas,
                &mask,
                (60, 70),
                &p,
                true,
                &mut ChaCha8Rng::seed_from_u64(seed),
                &Cancellation::default(),
            )
            .unwrap();
            for y in [70, 90] {
                assert!((60..=260).all(|x| canvas[(x, y)][3] > 0));
            }
        }
    }
}
