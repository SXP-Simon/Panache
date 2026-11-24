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
