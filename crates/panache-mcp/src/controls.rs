use crate::{Paper, drafts::Snapshot};
use anyhow::{Context, Result, bail, ensure};
use handwriting_core::{LayoutStyle, Limits, PaperPattern, Parameters};
use serde_json::{Map, Value, json};
use std::sync::OnceLock;

pub type Changes = Map<String, Value>;

pub fn catalog() -> &'static Changes {
    static CATALOG: OnceLock<Changes> = OnceLock::new();
    CATALOG.get_or_init(|| {
        serde_json::from_str(include_str!("controls.json")).expect("embedded control catalog")
    })
}

/// Normalize catalog groups at the input boundary. A scalar control (e.g. ink)
/// can share its name with a group; only an object selects the grouped syntax.
pub fn flatten_patch(changes: Changes) -> Result<Changes> {
    let mut patch = Changes::new();
    for (key, value) in changes {
        if let (Some(group), Value::Object(fields)) = (catalog().get(&key), &value) {
            ensure!(!fields.is_empty(), "Empty control group {key}");
            for (field, setting) in fields {
                ensure!(
                    group.get(field).is_some(),
                    "Unknown control {field} in group {key}"
                );
                ensure!(
                    patch.insert(field.clone(), setting.clone()).is_none(),
                    "Duplicate control {field}"
                );
            }
        } else {
            ensure!(
                patch.insert(key.clone(), value).is_none(),
                "Duplicate control {key}"
            );
        }
    }
    Ok(patch)
}

pub fn merge(current: &Changes, patch: &Changes, fonts: &[String]) -> Result<Changes> {
    ensure!(!patch.is_empty(), "Supply at least one control");
    let mut next = current.clone();
    for (name, value) in patch {
        let spec = catalog()
            .values()
            .find_map(|g| g.get(name))
            .with_context(|| format!("Unknown control {name}; use describe_controls"))?;
        if value.is_null() {
            next.remove(name);
            continue;
        }
        let valid = match spec["type"].as_str() {
            Some("string") => value.as_str().is_some_and(|s| {
                !s.trim().is_empty()
                    && s.len() <= spec["maxLength"].as_u64().unwrap() as usize
                    && s.bytes().all(|b| (b' '..=b'~').contains(&b))
            }),
            Some("boolean") => value.is_boolean(),
            Some("focus_gradient") => serde_json::from_value(value.clone()).is_ok_and(|gradient| {
                handwriting_core::export_blur::finish(None, Some(gradient)).is_ok()
            }),
            Some("choice") => spec["values"].as_array().unwrap().contains(value),
            Some("font") => fonts.iter().any(|f| value.as_str() == Some(f.as_str())),
            Some("color") => value.as_str().is_some_and(|s| {
                s.len() == 7
                    && s.starts_with('#')
                    && s.as_bytes()[1..].iter().all(u8::is_ascii_hexdigit)
            }),
            Some("integer" | "number") => value.as_f64().is_some_and(|n| {
                (spec["type"] != "integer" || value.is_i64() || value.is_u64())
                    && n >= spec["min"].as_f64().unwrap()
                    && n <= spec["max"].as_f64().unwrap()
                    && (spec.get("step").is_none() || (n * 10.).fract() == 0.)
            }),
            _ => false,
        };
        ensure!(valid, "Invalid {name}; expected {spec}");
        // Keep the stored JSON representation when a numeric override is unchanged.
        if spec["type"] == "number" && current.get(name).and_then(Value::as_f64) == value.as_f64() {
            continue;
        }
        next.insert(name.clone(), value.clone());
    }
    Ok(next)
}

pub fn parameters(draft: &Snapshot<'_>, section: u32, changes: &Changes) -> Result<Parameters> {
    let style = &draft.style;
    let size = f32::from(style.font_size);
    let mut params = Parameters {
        width: Some(794),
        height: Some(1123),
        font_size: size,
        line_spacing: (size * 1.65).round(),
        left_margin: 65.,
        right_margin: 65.,
        top_margin: 62.,
        bottom_margin: 55.,
        fill: style.ink_rgba()?,
        illustration_uses_pen: style.illustration_uses_pen.unwrap_or(false),
        strikethrough_probability: 0.,
        perturb_x_sigma: 1.,
        perturb_y_sigma: 1.,
        ink_depth_sigma: 8.,
        font_size_sigma: 1.,
        seed: u64::from(style.seed) + u64::from(section) - 1,
        layout_style: if style.homework {
            LayoutStyle::Homework
        } else {
            LayoutStyle::Standard
        },
        underlined: matches!(style.paper, Paper::Ruled),
        paper_pattern: match style.paper {
            Paper::Grid => Some(PaperPattern::Grid),
            Paper::Dots => Some(PaperPattern::Dots),
            _ => None,
        },
        preview: false,
        full_preview: false,
        ..Default::default()
    };
    if style.relaxed_handwriting == Some(true) {
        params.font_size_sigma = 1.5;
        params.perturb_theta_sigma = 0.07;
    }
    if let Some(layout) = &draft.paper {
        layout.apply(&mut params);
    }

    let mut fields = serde_json::to_value(&params)?;
    for (k, v) in changes {
        match k.as_str() {
            "font" | "ink_alpha" => continue,
            "seed" => {
                fields["seed"] = json!(v.as_u64().context("Invalid seed")? + u64::from(section) - 1)
            }
            "paper" => {
                ensure!(
                    draft.paper.is_none(),
                    "Preset paper requires a draft without imported stationery"
                );
                fields["underlined"] = json!(v == "ruled");
                fields["paper_pattern"] = if v == "grid" || v == "dots" {
                    v.clone()
                } else {
                    Value::Null
                };
            }
            "ink" => {
                let mut tinted = style.clone();
                tinted.ink = v.as_str().context("Invalid ink")?.to_owned();
                fields["fill"] = json!(tinted.ink_rgba()?);
            }
            "photo_ink_light" | "photo_ink_focus"
                if draft
                    .paper
                    .as_ref()
                    .is_none_or(|paper| paper.projection.is_none()) =>
            {
                bail!(
                    "Photo ink lighting and focus require an original paper imported in photo mode"
                )
            }
            "width" | "height" if draft.paper.is_some() => {
                bail!("Custom paper uses the dimensions of the photograph")
            }
            _ => fields[k] = v.clone(),
        }
    }
    if let Some(alpha) = changes.get("ink_alpha") {
        fields["fill"][3] = alpha.clone();
    }
    params = serde_json::from_value(fields)?;
    params.ink_layers =
        params.ink_opacity != 100 || params.ink_thickness != 0. || params.ink_softness != 0.;
    let (w, h) = draft
        .paper
        .as_ref()
        .map(|p| (p.width, p.height))
        .unwrap_or((
            params.width.unwrap_or_default(),
            params.height.unwrap_or_default(),
        ));
    params.validate(w, h, &Limits::default())?;
    Ok(params)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn equivalent_numbers_keep_the_stored_representation() -> Result<()> {
        for (old, new) in [(json!(4), json!(4.0)), (json!(4.0), json!(4))] {
            let current = Changes::from_iter([("word_spacing".into(), old.clone())]);
            let patch = Changes::from_iter([
                ("word_spacing".into(), new),
                ("ink_opacity".into(), json!(77)),
            ]);
            let merged = merge(&current, &patch, &[])?;
            assert_eq!(merged["word_spacing"], old);
            assert_eq!(merged["ink_opacity"], 77);
        }
        Ok(())
    }

    #[test]
    fn numeric_overrides_can_be_pinned_changed_and_cleared() -> Result<()> {
        let mut current = Changes::new();
        for value in [json!(1), json!(1.25), Value::Null] {
            let patch = Changes::from_iter([("word_spacing".into(), value.clone())]);
            current = merge(&current, &patch, &[])?;
            assert_eq!(
                current.get("word_spacing"),
                (!value.is_null()).then_some(&value)
            );
        }
        Ok(())
    }

    #[test]
    fn equal_values_still_require_a_valid_patch() {
        for (name, old, new) in [
            ("ink_opacity", json!(77), json!(77.0)),
            ("word_spacing", json!(4), json!("4")),
            ("word_spacing", json!(10001), json!(10001.0)),
            ("ink_thickness", json!(0.25), json!(0.25)),
        ] {
            let current = Changes::from_iter([(name.into(), old)]);
            let patch = Changes::from_iter([(name.into(), new)]);
            assert!(merge(&current, &patch, &[]).is_err());
        }
    }
}
