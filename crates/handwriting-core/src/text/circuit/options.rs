//! Component options are order independent: a later source type can determine an earlier arrow.
use super::{Label, labels};

pub(super) fn split_options(source: &str) -> Option<Vec<&str>> {
    let mut out = Vec::new();
    let mut depth = 0i32;
    let mut start = 0;
    let mut escaped = false;
    let mut math = false;
    for (i, c) in source.char_indices() {
        if escaped {
            escaped = false;
            continue;
        }
        if c == '\\' {
            escaped = true;
            continue;
        }
        if c == '$' {
            math = !math;
        }
        if c == '{' {
            depth += 1;
        }
        if c == '}' {
            depth -= 1;
        }
        if !(0..=16).contains(&depth) {
            return None;
        }
        if c == ',' && depth == 0 && !math {
            out.push(source[start..i].trim());
            start = i + 1;
        }
    }
    if depth != 0 || math {
        return None;
    }
    out.push(source[start..].trim());
    Some(out)
}
fn component_name(name: &str) -> Option<&'static str> {
    Some(match name {
        "R" | "resistor" => "R",
        "C" | "capacitor" => "C",
        "L" | "inductor" => "L",
        "V" | "vsource" => "V",
        "I" | "isource" => "I",
        "sV" | "sinusoidal voltage source" => "sV",
        "battery" | "battery1" => "battery1",
        "D" | "diode" => "D",
        "led" => "led",
        "short" => "short",
        "open" => "open",
        "switch" => "switch",
        "closing switch" => "closing switch",
        "opening switch" => "opening switch",
        _ => return None,
    })
}

pub(super) struct Component {
    pub(super) kind: &'static str,
    pub(super) labels: Vec<Label>,
    pub(super) marks: (char, char),
}

impl Component {
    pub(super) fn wire() -> Self {
        Self {
            kind: "short",
            labels: Vec::new(),
            marks: (' ', ' '),
        }
    }

    pub(super) fn parse(source: &str, rp: bool) -> Option<Self> {
        let mut kind = None;
        let mut pending = Vec::new();
        let mut marks = None;
        for item in split_options(source)? {
            if matches!(item, "" | "thin" | "semithick" | "thick") {
                continue;
            }
            if let Some((key, value)) = item.split_once('=') {
                if pending.len() >= 4 {
                    return None;
                }
                let mut key = key.trim();
                if let Some(name) = component_name(key) {
                    if kind.replace(name).is_some() {
                        return None;
                    }
                    key = "l";
                }
                pending.push(PendingLabel::parse(key, value.trim(), rp)?);
            } else if let Some(name) = component_name(item) {
                if kind.replace(name).is_some() {
                    return None;
                }
            } else if marks.replace(endpoints(item)?).is_some() {
                return None;
            }
        }
        let kind = kind.unwrap_or("short");
        let labels = pending
            .into_iter()
            .map(|label| label.resolve(kind))
            .collect();
        Some(Self {
            kind,
            labels,
            marks: marks.unwrap_or((' ', ' ')),
        })
    }
}

fn endpoints(item: &str) -> Option<(char, char)> {
    Some(match item {
        "*-*" => ('*', '*'),
        "o-o" => ('o', 'o'),
        "*-" => ('*', ' '),
        "-*" => (' ', '*'),
        "o-" => ('o', ' '),
        "-o" => (' ', 'o'),
        "*-o" => ('*', 'o'),
        "o-*" => ('o', '*'),
        _ => return None,
    })
}

struct PendingLabel<'a> {
    kind: char,
    modifiers: &'a str,
    text: String,
}

impl<'a> PendingLabel<'a> {
    fn parse(key: &'a str, value: &str, rp: bool) -> Option<Self> {
        let mut chars = key.chars();
        let kind = chars.next()?;
        let modifiers = chars.as_str();
        if !matches!(
            modifiers,
            "" | "_" | "^" | ">" | "<" | "^>" | "^<" | "_>" | "_<" | ">^" | "<^" | ">_" | "<_"
        ) {
            return None;
        }
        let explicit_direction = modifiers.contains(['<', '>']);
        match kind {
            'l' | 'a' if !explicit_direction => (),
            'i' | 'v' if rp || explicit_direction => (),
            _ => return None,
        }
        Some(Self {
            kind,
            modifiers,
            text: labels::normalize(value)?,
        })
    }

    fn resolve(self, component: &str) -> Label {
        let voltage_direction = if matches!(component, "V" | "sV" | "battery1") {
            1.
        } else {
            -1.
        };
        let direction = if self.modifiers.contains('>') {
            1.
        } else if self.modifiers.contains('<') {
            -1.
        } else if self.kind == 'i' {
            -voltage_direction
        } else {
            voltage_direction
        };
        Label {
            text: self.text,
            side: if self.modifiers.contains('_') {
                -1.
            } else {
                1.
            },
            kind: self.kind,
            direction,
        }
    }
}
