//! 2026-10-22：二维矩阵括号跟随内容伸缩，所有曲线共用端点和笔宽。
use crate::text::TableKind;

type Point = (i32, i32);
type Stroke = (Vec<Point>, i32);

fn brace(width: i32, height: i32) -> Vec<Point> {
    let (w, h) = (width as f32, height as f32);
    let curves = [
        [
            (w, 0.),
            (w * 0.45, 0.),
            (w * 0.45, h * 0.12),
            (w * 0.45, h * 0.25),
        ],
        [
            (w * 0.45, h * 0.25),
            (w * 0.45, h * 0.4),
            (w * 0.45, h * 0.5),
            (0., h * 0.5),
        ],
        [
            (0., h * 0.5),
            (w * 0.45, h * 0.5),
            (w * 0.45, h * 0.6),
            (w * 0.45, h * 0.75),
        ],
        [
            (w * 0.45, h * 0.75),
            (w * 0.45, h * 0.88),
            (w * 0.45, h),
            (w, h),
        ],
    ];
    curves
        .into_iter()
        .flat_map(|curve| {
            (0..=12).map(move |step| {
                let t = step as f32 / 12.;
                let factors = [
                    (1. - t).powi(3),
                    3. * (1. - t).powi(2) * t,
                    3. * (1. - t) * t * t,
                    t.powi(3),
                ];
                let x = curve.iter().zip(factors).map(|(p, f)| p.0 * f).sum::<f32>();
                let y = curve.iter().zip(factors).map(|(p, f)| p.1 * f).sum::<f32>();
                (x.round() as i32, y.round() as i32)
            })
        })
        .collect()
}

pub(in crate::render::glyph) fn delimiters(
    kind: TableKind,
    width: i32,
    height: i32,
    size: f32,
) -> (i32, Vec<Stroke>) {
    if matches!(kind, TableKind::Grid | TableKind::Matrix) {
        return (0, vec![]);
    }
    let bracket = (size * 0.25).round().max(6.) as i32;
    let gap = (size * 0.12).round().max(3.) as i32;
    let inset = bracket + gap;
    let thickness = (size * 0.025).round().max(1.) as i32;
    let left = match kind {
        TableKind::Braces | TableKind::Cases => vec![brace(bracket, height)],
        TableKind::Parentheses => vec![
            (0..=32)
                .map(|i| {
                    let t = i as f32 / 32.;
                    (
                        (bracket as f32 * (1. - 4. * t * (1. - t))).round() as i32,
                        (height as f32 * t).round() as i32,
                    )
                })
                .collect(),
        ],
        TableKind::Brackets => vec![vec![(bracket, 0), (0, 0), (0, height), (bracket, height)]],
        TableKind::Norm => vec![
            vec![(0, 0), (0, height)],
            vec![(bracket / 2, 0), (bracket / 2, height)],
        ],
        _ => vec![vec![(bracket / 2, 0), (bracket / 2, height)]],
    };
    let mut strokes: Vec<_> = left.iter().cloned().map(|path| (path, thickness)).collect();
    if kind != TableKind::Cases {
        let edge = width + inset * 2;
        strokes.extend(left.into_iter().map(|path| {
            (
                path.into_iter().map(|(x, y)| (edge - x, y)).collect(),
                thickness,
            )
        }));
    }
    (inset, strokes)
}
