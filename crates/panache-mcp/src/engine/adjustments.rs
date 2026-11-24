use super::{Engine, glyph_point};
use crate::{
    Nudge, Shape, Style,
    drafts::{Section, Snapshot},
    placement::Placement,
};
use anyhow::{Context, Result, ensure};
use handwriting_core::{
    Cancellation, Parameters,
    fine_edit::{self, Adjustment, Adjustments, GlyphBounds},
};
use serde_json::json;
use std::collections::{BTreeMap, BTreeSet};

impl Engine {
    pub fn adjust(
        &mut self,
        draft: &Snapshot<'_>,
        section: Section,
        input: &crate::Nudge,
        cancel: &Cancellation,
    ) -> Result<u32> {
        let changes = GlyphChanges::parse(input, &draft.style)?;
        let version = section.version;
        let mut req = self.fine_request(draft, section)?;
        let (key, mut bounds) = fine_edit::inspect_page(&req, input.page, cancel)
            .map_err(|error| draft.page_error(input.section, error))?;
        bounds.retain(|g| changes.ids.contains(&g.id));
        let mut selected = BTreeMap::new();
        for glyph in &bounds {
            selected.entry(glyph.id).or_insert(glyph);
        }
        ensure!(
            selected.len() == changes.ids.len(),
            "Glyph not on this page; inspect its layout first"
        );
        let mut edits: BTreeMap<_, _> = req
            .params
            .fine_edits
            .take()
            .into_iter()
            .flat_map(|v| v.glyphs)
            .map(|e| (e.id, e))
            .collect();
        let geometry = Geometry::resolve(input, draft, &req.params, &bounds, &edits)?;
        for (id, glyph) in selected {
            let edit = edits.entry(id).or_insert(Adjustment {
                id,
                dx: 0,
                dy: 0,
                scale: 100,
                angle: 0,
                opacity: 100,
                color: None,
                thickness: 0,
                softness: 0,
                warp: None,
            });
            changes.apply(&geometry, glyph, edit)?;
        }
        ensure!(edits.len() <= 10000, "Section glyph edit limit reached");
        cancel.check()?;
        draft.store_edits(
            input.section,
            version,
            &Adjustments {
                key,
                glyphs: edits.into_values().collect(),
            },
            &json!({"page":input.page,"ids":input.ids,"place_center":input.place_center,"target_quad":input.target_quad,"dx":input.dx,"dy":input.dy,"scale":input.scale,"angle":input.angle,"shape":input.shape,"opacity":input.opacity,"thickness":input.thickness,"softness":input.softness,"color":input.color,"note":input.note}),
        )
    }
}

struct GlyphChanges<'a> {
    input: &'a Nudge,
    ids: BTreeSet<u32>,
    thickness: Option<i8>,
    softness: Option<i8>,
    color: Option<Option<[u8; 3]>>,
}

impl<'a> GlyphChanges<'a> {
    fn parse(input: &'a Nudge, style: &Style) -> Result<Self> {
        let ids: BTreeSet<_> = input.ids.iter().copied().collect();
        ensure!(
            !ids.is_empty() && ids.len() == input.ids.len() && ids.len() <= 32,
            "Choose 1..32 distinct glyph IDs"
        );
        ensure!(
            input.target_quad.is_some()
                || input.place_center.is_some()
                || input.dx.is_some()
                || input.dy.is_some()
                || input.scale.is_some()
                || input.angle.is_some()
                || input.opacity.is_some()
                || input.shape.is_some()
                || input.thickness.is_some()
                || input.softness.is_some()
                || input.color.is_some(),
            "Supply at least one adjustment"
        );
        ensure!(
            input.dx.is_none_or(|v| (-65535..=65535).contains(&v))
                && input.dy.is_none_or(|v| (-65535..=65535).contains(&v))
                && input.scale.is_none_or(|v| (50..=200).contains(&v))
                && input.angle.is_none_or(|v| (-45..=45).contains(&v))
                && input.opacity.is_none_or(|v| v <= 100)
                && input
                    .shape
                    .as_ref()
                    .is_none_or(|s| (-20..=20).contains(&s.shear_degrees)
                        && (80..=120).contains(&s.top_width_percent)),
            "Invalid glyph adjustment"
        );
        let delta = |v: f64| -> Result<i8> {
            ensure!(
                (-2.0..=2.0).contains(&v) && (v * 10.).fract() == 0.,
                "Expected -2..2 pixels in steps of 0.1"
            );
            Ok((v * 10.) as i8)
        };
        let thickness = input.thickness.map(delta).transpose()?;
        let softness = input.softness.map(delta).transpose()?;
        let color = input
            .color
            .as_ref()
            .map(|c| -> Result<_> {
                if c == "inherit" {
                    return Ok(None);
                }
                let [r, g, b, _] = crate::Style {
                    ink: c.clone(),
                    ..style.clone()
                }
                .ink_rgba()?;
                Ok(Some([r, g, b]))
            })
            .transpose()?;
        Ok(Self {
            input,
            ids,
            thickness,
            softness,
            color,
        })
    }

    fn apply(&self, geometry: &Geometry, glyph: &GlyphBounds, e: &mut Adjustment) -> Result<()> {
        let input = self.input;
        if let Geometry::Quadrilateral(map) = geometry {
            map.apply(e, glyph.bounds)?;
        }
        if let Some(shape) = &input.shape {
            e.warp = shape_warp(shape, glyph.bounds[3]);
        }
        if let Geometry::Translation([dx, dy]) = *geometry {
            e.dx = e.dx.checked_add(dx).context("Position overflow")?;
            e.dy = e.dy.checked_add(dy).context("Position overflow")?;
            ensure!(
                (-65535..=65535).contains(&e.dx) && (-65535..=65535).contains(&e.dy),
                "Move exceeds the supported layout range"
            );
        }
        e.dx = input.dx.unwrap_or(e.dx);
        e.dy = input.dy.unwrap_or(e.dy);
        e.angle = input.angle.unwrap_or(e.angle);
        e.scale = input.scale.unwrap_or(e.scale);
        e.opacity = input.opacity.unwrap_or(e.opacity);
        e.thickness = self.thickness.unwrap_or(e.thickness);
        e.softness = self.softness.unwrap_or(e.softness);
        if let Some(c) = self.color {
            e.color = c;
        }
        ensure!(
            fine_edit::usable_shape(e, glyph.bounds[2], glyph.bounds[3]),
            "Shape exceeds safe bounds at the requested scale or rotation"
        );
        Ok(())
    }
}

fn shape_warp(shape: &Shape, height: i32) -> Option<[f64; 8]> {
    let height = f64::from(height.max(1));
    let ratio = f64::from(shape.top_width_percent) / 100.;
    let shear = f64::from(shape.shear_degrees).to_radians().tan();
    let h = 2. * (ratio - 1.) / ((ratio + 1.) * height);
    let f = h * height * height / 4.;
    if shape.shear_degrees == 0 && shape.top_width_percent == 100 {
        None
    } else {
        Some([
            2. * ratio / (ratio + 1.),
            shear,
            shear * f,
            0.,
            1.,
            f,
            0.,
            h,
        ])
    }
}

enum Geometry {
    Unchanged,
    Quadrilateral(Placement),
    Translation([i32; 2]),
}

impl Geometry {
    fn resolve(
        input: &Nudge,
        draft: &Snapshot<'_>,
        params: &Parameters,
        bounds: &[GlyphBounds],
        edits: &BTreeMap<u32, Adjustment>,
    ) -> Result<Self> {
        let [w, h] = draft
            .paper
            .as_ref()
            .map(|p| p.photo_size.unwrap_or([p.width, p.height]))
            .unwrap_or([params.width.unwrap_or(0), params.height.unwrap_or(0)]);
        if let Some(quad) = input.target_quad {
            ensure!(
                input.place_center.is_none()
                    && input.dx.is_none()
                    && input.dy.is_none()
                    && input.angle.is_none()
                    && input.scale.is_none()
                    && input.shape.is_none(),
                "Use target_quad separately from other geometry fields"
            );
            return Ok(Self::Quadrilateral(Placement::new(
                draft,
                [w, h],
                bounds,
                quad,
            )?));
        }
        if let Some(target) = input.place_center {
            ensure!(
                input.dx.is_none() && input.dy.is_none() && input.shape.is_none(),
                "Use place_center separately from dx/dy/shape"
            );
            ensure!(target[0] < w && target[1] < h, "Target outside the page");
            let projection = draft.paper.as_ref().and_then(|p| p.projection.as_ref());
            let dest = target.map(|v| v as f32);
            let dest = projection.map_or(dest, |p| p.paper_point(dest));
            let mut mean = [0., 0.];
            for g in bounds {
                let pos = glyph_point(g, edits.get(&g.id), [0., 0.]);
                for axis in 0..2 {
                    mean[axis] += pos[axis] / input.ids.len() as f32;
                }
            }
            return Ok(Self::Translation([
                (dest[0] - mean[0]).round() as i32,
                (dest[1] - mean[1]).round() as i32,
            ]));
        }
        Ok(Self::Unchanged)
    }
}
