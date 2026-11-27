//! Separate isolated lettering from diagram outlines while retaining every rendered ink pixel.
use crate::{
    Cancellation, Result,
    fine_edit::{PAD, Tile},
};
use image::{DynamicImage, GrayImage, Luma, RgbaImage, imageops};
use imageproc::region_labelling::{Connectivity, connected_components};

const MAX_PARTS: usize = 31;

#[derive(Clone, Copy, Default)]
struct Bounds {
    x: u32,
    y: u32,
    right: u32,
    bottom: u32,
}
impl Bounds {
    fn width(self) -> u32 {
        self.right - self.x
    }
    fn height(self) -> u32 {
        self.bottom - self.y
    }
    fn union(self, b: Self) -> Self {
        Self {
            x: self.x.min(b.x),
            y: self.y.min(b.y),
            right: self.right.max(b.right),
            bottom: self.bottom.max(b.bottom),
        }
    }
    fn same_run(self, b: Self) -> bool {
        let height = self.height().max(b.height());
        let overlap = self.bottom.min(b.bottom).saturating_sub(self.y.max(b.y));
        let gap = self.x.max(b.x).saturating_sub(self.right.min(b.right));
        overlap > 0 && overlap * 3 >= self.height().min(b.height()) && gap <= height * 2 / 3 + 1
    }
}

fn regions(source: &DynamicImage, cancel: &Cancellation) -> Result<(Vec<Bounds>, u32, u32)> {
    // A fixed analysis scale keeps IDs stable when font size, paper or layout width changes.
    let thumb = source
        .thumbnail(source.width().min(800), source.height().min(800))
        .to_rgba8();
    let (w, h) = thumb.dimensions();
    let binary = GrayImage::from_fn(w, h, |x, y| {
        let [r, g, b, a] = thumb[(x, y)].0;
        let gray = (u32::from(r) * 77 + u32::from(g) * 150 + u32::from(b) * 29) / 256;
        Luma([if (255 - gray) * u32::from(a) > 75 * 255 {
            255
        } else {
            0
        }])
    });
    cancel.check()?;
    let labels = connected_components(&binary, Connectivity::Eight, Luma([0]));
    let count = labels.pixels().map(|p| p[0]).max().unwrap_or(0) as usize;
    if count > 2048 {
        return Ok((vec![], w, h));
    }
    let mut components = vec![(Bounds::default(), 0u32); count + 1];
    for (x, y, p) in labels.enumerate_pixels().filter(|(_, _, p)| p[0] != 0) {
        let (b, n) = &mut components[p[0] as usize];
        let dot = Bounds {
            x,
            y,
            right: x + 1,
            bottom: y + 1,
        };
        *b = if *n == 0 { dot } else { b.union(dot) };
        *n += 1;
    }
    let mut structure = vec![false; components.len()];
    let mut parts = vec![];
    for (id, (b, n)) in components.into_iter().enumerate().skip(1) {
        if b.width() > w.min(h) / 3
            || b.height() > h / 3
            || (b.width() > 20 && b.width() > 8 * b.height())
        {
            structure[id] = true;
        } else if n >= 2 {
            parts.push(b);
        }
    }
    if parts.len() > 512 {
        return Ok((vec![], w, h));
    }
    // No OCR: merge adjacent marks on the same text line. Leave connected wires and frames alone.
    parts.sort_by_key(|b| (b.x, b.y));
    let mut groups: Vec<Bounds> = vec![];
    for mut part in parts {
        let mut i = 0;
        while i < groups.len() {
            if part.same_run(groups[i]) {
                part = part.union(groups.swap_remove(i));
                i = 0;
            } else {
                i += 1;
            }
        }
        groups.push(part);
    }
    let mut regions = vec![];
    for b in groups {
        if b.width() < 5 || b.height() < 5 {
            continue;
        }
        let b = Bounds {
            x: b.x.saturating_sub(2),
            y: b.y.saturating_sub(2),
            right: (b.right + 2).min(w),
            bottom: (b.bottom + 2).min(h),
        };
        if (b.y..b.bottom).any(|y| (b.x..b.right).any(|x| structure[labels[(x, y)][0] as usize])) {
            continue;
        }
        regions.push(b);
    }
    regions.sort_by_key(|b| (b.y, b.x));
    if regions.len() > MAX_PARTS {
        regions.clear();
    }
    Ok((regions, w, h))
}

pub(super) fn tiles(
    source: &DynamicImage,
    image: &RgbaImage,
    id: u32,
    x: i32,
    y: i32,
    mut budget: usize,
    cancel: &Cancellation,
) -> Result<Vec<Tile>> {
    let mut reserve = |w: u32, h: u32| -> Result<()> {
        let area = u64::from(w + 2 * PAD) * u64::from(h + 2 * PAD);
        budget = budget
            .checked_sub(usize::try_from(area).unwrap_or(usize::MAX))
            .ok_or_else(|| crate::Error::new("invalid_layout", "插图蒙版超过当前页内存预算"))?;
        Ok(())
    };
    reserve(image.width(), image.height())?;
    let (regions, w, h) = regions(source, cancel)?;
    let mut mask = GrayImage::from_fn(image.width(), image.height(), |x, y| {
        Luma([image[(x, y)][3]])
    });
    let make = |part, mask: GrayImage, dx, dy| {
        let mut padded = GrayImage::new(mask.width() + 2 * PAD, mask.height() + 2 * PAD);
        imageops::replace(&mut padded, &mask, PAD.into(), PAD.into());
        Tile {
            is_text: false,
            id: part,
            illustration: Some(id),
            x: x + dx as i32 - PAD as i32,
            y: y + dy as i32 - PAD as i32,
            baseline: y + dy as i32 + mask.height() as i32,
            mask: padded,
            source: None,
        }
    };
    let mut parts = vec![];
    for (index, b) in regions.iter().enumerate() {
        cancel.check()?;
        let dx = b.x * mask.width() / w;
        let dy = b.y * mask.height() / h;
        let right = (u64::from(b.right) * u64::from(mask.width())).div_ceil(w.into()) as u32;
        let bottom = (u64::from(b.bottom) * u64::from(mask.height())).div_ceil(h.into()) as u32;
        reserve(right - dx, bottom - dy)?;
        let part = GrayImage::from_fn(right - dx, bottom - dy, |xx, yy| {
            std::mem::replace(&mut mask[(dx + xx, dy + yy)], Luma([0]))
        });
        if part.pixels().any(|p| p[0] != 0) {
            // Text nodes use their original document index. Reserve a disjoint range for image parts.
            parts.push(make((1 << 29) + id * 32 + index as u32, part, dx, dy));
        }
    }
    parts.insert(0, make(id, mask, 0, 0));
    Ok(parts)
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{DynamicImage, Rgba};
    #[test]
    fn isolated_label_is_editable_without_losing_or_duplicating_ink() {
        let image = RgbaImage::from_fn(140, 70, |x, y| {
            let frame = (10..130).contains(&x) && ((10..13).contains(&y) || (57..60).contains(&y))
                || (10..60).contains(&y) && ((10..13).contains(&x) || (127..130).contains(&x));
            let label = (48..56).contains(&x) && (30..40).contains(&y);
            Rgba([20, 20, 25, if frame || label { 235 } else { 0 }])
        });
        let source = DynamicImage::ImageLuma8(GrayImage::from_fn(140, 70, |x, y| {
            Luma([255 - image[(x, y)][3]])
        }));
        let cancel = Cancellation::default();
        let parts = tiles(&source, &image, 12, 9, 11, 1_000_000, &cancel).unwrap();
        assert_eq!(parts.len(), 2);
        assert_eq!(parts[0].id, 12);
        assert_ne!(parts[1].id, 12);
        let mut restored = GrayImage::new(140, 70);
        for tile in &parts {
            for (x, y, p) in tile.mask.enumerate_pixels().filter(|(_, _, p)| p[0] > 0) {
                let dst = &mut restored[(
                    (tile.x + x as i32 - 9) as u32,
                    (tile.y + y as i32 - 11) as u32,
                )];
                assert_eq!(dst[0], 0);
                *dst = *p;
            }
        }
        assert!(
            image
                .enumerate_pixels()
                .all(|(x, y, p)| restored[(x, y)][0] == p[3])
        );
        let small = imageops::resize(&image, 70, 35, imageops::FilterType::Triangle);
        let smaller = tiles(&source, &small, 12, 0, 0, 1_000_000, &cancel).unwrap();
        assert_eq!(smaller[1].id, parts[1].id);
        assert!(tiles(&source, &image, 12, 0, 0, 50, &cancel).is_err());
    }
}
