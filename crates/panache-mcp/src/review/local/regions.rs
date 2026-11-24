use anyhow::{Result, ensure};
use image::{GenericImageView, RgbaImage};

pub(super) type Point = [i32; 2];

pub(super) struct Regions<'a> {
    pub current: &'a [Point],
    pub previous: Option<&'a [Point]>,
    pub bounds: [u32; 4],
}

impl<'a> Regions<'a> {
    pub fn new(
        region: &'a [Point],
        previous: Option<&'a [Point]>,
        size: (u32, u32),
    ) -> Result<Self> {
        validate_polygon(region, size)?;
        if let Some(old) = previous {
            validate_polygon(old, size)?;
        }
        let [mut left, mut top] = region[0];
        let [mut right, mut bottom] = region[0];
        for &[x, y] in region.iter().chain(previous.unwrap_or_default()) {
            left = left.min(x);
            top = top.min(y);
            right = right.max(x);
            bottom = bottom.max(y);
        }
        let bounds = [
            left as u32,
            top as u32,
            (right - left) as u32,
            (bottom - top) as u32,
        ];
        Ok(Self {
            current: region,
            previous,
            bounds,
        })
    }

    pub fn crop(&self, image: &RgbaImage) -> RgbaImage {
        let [x, y, w, h] = self.bounds;
        super::thumbnail(&*image.view(x, y, w, h))
    }
}

fn edges(poly: &[Point]) -> impl Iterator<Item = (Point, Point)> + '_ {
    poly.iter()
        .copied()
        .zip(poly.iter().copied().cycle().skip(1))
}

fn turn(a: Point, b: Point, p: Point) -> i64 {
    i64::from(b[0] - a[0]) * i64::from(p[1] - a[1])
        - i64::from(b[1] - a[1]) * i64::from(p[0] - a[0])
}

fn between(a: Point, p: Point, b: Point) -> bool {
    (0..2).all(|i| (a[i].min(b[i])..=a[i].max(b[i])).contains(&p[i]))
}

fn intersects(a: Point, b: Point, c: Point, d: Point) -> bool {
    let (ac, ad, ca, cb) = (turn(a, b, c), turn(a, b, d), turn(c, d, a), turn(c, d, b));
    (ac.signum() * ad.signum() < 0 && ca.signum() * cb.signum() < 0)
        || (ac == 0 && between(a, c, b))
        || (ad == 0 && between(a, d, b))
        || (ca == 0 && between(c, a, d))
        || (cb == 0 && between(c, b, d))
}

fn validate_polygon(poly: &[Point], (w, h): (u32, u32)) -> Result<()> {
    ensure!((3..=32).contains(&poly.len()), "Use 3..32 polygon vertices");
    ensure!(
        poly.iter()
            .all(|&[x, y]| (0..=w as i32).contains(&x) && (0..=h as i32).contains(&y)),
        "Polygon vertices must be inside native output pixel edges [0,{w}] x [0,{h}]"
    );
    for (i, (a, b)) in edges(poly).enumerate() {
        let c = poly[(i + 2) % poly.len()];
        ensure!(
            a != b && (turn(a, b, c) != 0 || between(a, b, c)),
            "Polygon has a duplicate or reversing edge"
        );
        for (j, (c, d)) in edges(poly).enumerate().skip(i + 2) {
            if i != 0 || j + 1 != poly.len() {
                ensure!(
                    !intersects(a, b, c, d),
                    "Polygon must be simple with no intersecting edges"
                );
            }
        }
    }
    Ok(())
}

// Fill horizontal spans at pixel centers. Concave polygons can produce several spans.
pub(super) fn row_mask(poly: &[Point], y: u32, mask: &mut [bool]) {
    mask.fill(false);
    let cy = f64::from(y) + 0.5;
    let mut cuts = [0usize; 32];
    let mut count = 0;
    for ([ax, ay], [bx, by]) in edges(poly) {
        if (f64::from(ay) > cy) != (f64::from(by) > cy) {
            let x = f64::from(ax) + (cy - f64::from(ay)) * f64::from(bx - ax) / f64::from(by - ay);
            cuts[count] = (x - 0.5).ceil() as usize;
            count += 1;
        }
    }
    cuts[..count].sort_unstable();
    for pair in cuts[..count].chunks_exact(2) {
        mask[pair[0]..pair[1]].fill(true);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_invalid_photo_polygons() {
        for poly in [
            vec![[1, 0], [2, 0], [3, 0]],
            vec![[0, 0], [8, 8], [8, 0], [0, 8]],
            vec![[0, 0], [9, 1], [1, 4]],
            vec![[0, 0], [8, 0], [8, 8], [0, 0]],
            vec![[0, 0], [8, 0], [7, 0], [0, 8]],
        ] {
            assert!(validate_polygon(&poly, (8, 8)).is_err(), "{poly:?}");
        }
    }

    #[test]
    fn mask_matches_even_odd_centers_for_concave_polygon_including_photo_edges() {
        let poly = [[0, 0], [8, 0], [8, 6], [6, 4], [4, 1], [2, 4], [0, 6]];
        validate_polygon(&poly, (8, 6)).unwrap();
        let mut mask = [true; 8];
        for y in 0..6 {
            row_mask(&poly, y, &mut mask);
            for (x, &inside) in mask.iter().enumerate() {
                assert_eq!(
                    inside,
                    crate::review::contains(&poly, [x as f32 + 0.5, y as f32 + 0.5])
                );
            }
        }
    }
}
