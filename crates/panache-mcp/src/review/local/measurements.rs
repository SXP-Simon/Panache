use super::{
    regions::{Regions, row_mask},
    rgb_delta,
};
use anyhow::{Result, ensure};
use handwriting_core::Cancellation;
use image::RgbaImage;
use serde::Serialize;

pub(super) const THRESHOLD: u16 = 8;

#[derive(Default, Serialize)]
struct Ink {
    sampled_pixels: u64,
    ink_pixels: u64,
    max_rgb_delta: u16,
}

impl Ink {
    fn sample(&mut self, delta: u16) {
        self.sampled_pixels += 1;
        self.ink_pixels += u64::from(delta >= THRESHOLD);
        self.max_rgb_delta = self.max_rgb_delta.max(delta);
    }
}

#[derive(Default, Serialize)]
pub(super) struct Measurements {
    region: Ink,
    previous_region: Option<Ink>,
}

impl Measurements {
    fn sample(&mut self, region: bool, previous: bool, delta: u16) {
        if region {
            self.region.sample(delta);
        }
        if previous {
            self.previous_region.get_or_insert_default().sample(delta);
        }
    }
}

#[derive(Default, Serialize)]
pub(super) struct Difference {
    inside_union_changed_pixels: u64,
    outside_union_changed_pixels: u64,
    region_changed_pixels: u64,
    previous_region_changed_pixels: Option<u64>,
}

impl Difference {
    fn record_change(&mut self, in_region: bool, in_previous: bool) {
        self.region_changed_pixels += u64::from(in_region);
        if let Some(count) = &mut self.previous_region_changed_pixels {
            *count += u64::from(in_previous);
        }
        if in_region || in_previous {
            self.inside_union_changed_pixels += 1;
        } else {
            self.outside_union_changed_pixels += 1;
        }
    }
}

pub(super) struct PageMeasurements {
    pub after: Measurements,
    pub before: Option<Measurements>,
    pub difference: Option<Difference>,
}

pub(super) fn measure(
    regions: &Regions<'_>,
    paper: &RgbaImage,
    after: &RgbaImage,
    before: Option<&RgbaImage>,
    cancel: &Cancellation,
) -> Result<PageMeasurements> {
    let mut after_metrics = Measurements::default();
    let mut before_metrics = Measurements::default();
    let mut difference = Difference {
        previous_region_changed_pixels: regions.previous.map(|_| 0),
        ..Default::default()
    };
    // A paired review counts changes on the entire page, including outside both polygons.
    let [left, top, width, height] = if before.is_some() {
        [0, 0, after.width(), after.height()]
    } else {
        regions.bounds
    };
    let mut mask = vec![false; after.width() as usize];
    let mut previous_row = regions.previous.map(|poly| (poly, mask.clone()));
    for y in top..top + height {
        cancel.check()?;
        row_mask(regions.current, y, &mut mask);
        if let Some((poly, old_mask)) = &mut previous_row {
            row_mask(poly, y, old_mask);
        }
        for x in left..left + width {
            let inside = mask[x as usize];
            let old = previous_row
                .as_ref()
                .is_some_and(|(_, row)| row[x as usize]);
            let pixel = after[(x, y)];
            let base = paper[(x, y)];
            if inside || old {
                after_metrics.sample(inside, old, rgb_delta(pixel, base));
            }
            if let Some(before) = before {
                let prior = before[(x, y)];
                if inside || old {
                    before_metrics.sample(inside, old, rgb_delta(prior, base));
                }
                if rgb_delta(pixel, prior) >= THRESHOLD {
                    difference.record_change(inside, old);
                }
            }
        }
    }
    ensure!(
        after_metrics.region.sampled_pixels > 0
            && (regions.previous.is_none() || after_metrics.previous_region.is_some()),
        "Each polygon must enclose at least one pixel center"
    );
    Ok(PageMeasurements {
        after: after_metrics,
        before: before.map(|_| before_metrics),
        difference: before.map(|_| difference),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::Rgba;

    #[test]
    fn paired_differences_count_overlap_once_and_include_pixels_outside_the_crop() -> Result<()> {
        let paper = RgbaImage::from_pixel(4, 3, Rgba([255; 4]));
        let mut before = paper.clone();
        before[(0, 0)] = Rgba([0, 255, 255, 255]);
        before[(1, 1)] = Rgba([248, 255, 255, 255]);
        let mut after = paper.clone();
        for point in [(1, 0), (2, 1), (3, 2)] {
            after[point] = Rgba([247, 255, 255, 255]);
        }
        let current = [[0, 0], [2, 0], [2, 2], [0, 2]];
        let previous = [[1, 0], [3, 0], [3, 2], [1, 2]];
        let regions = Regions::new(&current, Some(&previous), paper.dimensions())?;
        let cancel = Cancellation::default();
        let paired = measure(&regions, &paper, &after, Some(&before), &cancel)?;
        assert_eq!(paired.after.region.sampled_pixels, 4);
        assert_eq!(paired.after.region.ink_pixels, 1);
        assert_eq!(paired.after.previous_region.unwrap().ink_pixels, 2);
        let prior = paired.before.unwrap();
        assert_eq!(prior.region.ink_pixels, 1);
        assert_eq!(prior.previous_region.unwrap().ink_pixels, 0);
        let difference = paired.difference.unwrap();
        assert_eq!(difference.inside_union_changed_pixels, 3);
        assert_eq!(difference.outside_union_changed_pixels, 1);
        assert_eq!(difference.region_changed_pixels, 2);
        assert_eq!(difference.previous_region_changed_pixels, Some(2));

        let single = Regions::new(&current, None, paper.dimensions())?;
        let result = measure(&single, &paper, &after, None, &cancel)?;
        assert_eq!(result.after.region.ink_pixels, 1);
        assert!(result.after.previous_region.is_none());
        assert!(result.before.is_none() && result.difference.is_none());
        Ok(())
    }
}
