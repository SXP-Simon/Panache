//! 2026-10-22：有界 CircuiTikZ 子集；未知语法整块保留，绝不猜测电路连接。
use std::collections::HashMap;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Point(pub f32, pub f32);
#[derive(Debug, Clone, PartialEq)]
pub struct Label {
    pub text: String,
    pub side: f32,
    pub kind: char,
    pub direction: f32,
}
#[derive(Debug, Clone, PartialEq)]
pub struct Segment {
    pub start: Point,
    pub end: Point,
    pub kind: String,
    pub labels: Vec<Label>,
    pub marks: (char, char),
}
#[derive(Debug, Clone, PartialEq)]
pub struct Decoration {
    pub point: Point,
    pub kind: String,
    pub text: String,
}
#[derive(Debug, Clone, PartialEq)]
pub struct Circuit {
    pub american: bool,
    pub segments: Vec<Segment>,
    pub decorations: Vec<Decoration>,
}

pub const BEGIN: &str = "\\begin{circuitikz}";
pub const END: &str = "\\end{circuitikz}";
fn component_name(name: &str) -> Option<&str> {
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
struct Parser<'a> {
    source: &'a str,
    at: usize,
    names: HashMap<String, Point>,
    circuit: Circuit,
    current: Point,
    relative: Point,
    rp: bool,
}
impl<'a> Parser<'a> {
    fn space(&mut self) {
        loop {
            let before = self.at;
            while self.source[self.at..].starts_with(char::is_whitespace) {
                self.at += self.source[self.at..].chars().next().unwrap().len_utf8();
            }
            if self.source[self.at..].starts_with('%') {
                self.at += self.source[self.at..]
                    .find('\n')
                    .unwrap_or(self.source.len() - self.at);
            }
            if self.at == before {
                break;
            }
        }
    }
    fn eat(&mut self, s: &str) -> bool {
        self.space();
        if self.source[self.at..].starts_with(s) {
            self.at += s.len();
            true
        } else {
            false
        }
    }
    fn group(&mut self, open: char, close: char) -> Option<String> {
        self.space();
        if !self.source[self.at..].starts_with(open) {
            return None;
        }
        self.at += open.len_utf8();
        let start = self.at;
        let mut depth = 1;
        let mut escaped = false;
        while self.at < self.source.len() {
            let c = self.source[self.at..].chars().next()?;
            self.at += c.len_utf8();
            if escaped {
                escaped = false;
                continue;
            }
            if c == '\\' {
                escaped = true;
                continue;
            }
            if c == open {
                depth += 1;
            }
            if c == close {
                depth -= 1;
                if depth == 0 {
                    return Some(self.source[start..self.at - c.len_utf8()].to_owned());
                }
            }
            if depth > 16 {
                return None;
            }
        }
        None
    }
    fn point(&mut self) -> Option<Point> {
        self.space();
        let relative = if self.eat("++") {
            2
        } else if self.eat("+") {
            1
        } else {
            0
        };
        let raw = self.group('(', ')')?;
        let mut p = if let Some((x, y)) = raw.split_once(',') {
            let x = x.trim().parse::<f32>().ok()?;
            let y = y.trim().parse::<f32>().ok()?;
            if !x.is_finite() || !y.is_finite() || x.abs() > 1000. || y.abs() > 1000. {
                return None;
            }
            Point(x, y)
        } else {
            if relative != 0 {
                return None;
            }
            *self.names.get(raw.trim())?
        };
        if relative > 0 {
            p = Point(p.0 + self.relative.0, p.1 + self.relative.1);
        }
        if p.0.abs() > 1000. || p.1.abs() > 1000. {
            return None;
        }
        if relative != 1 {
            self.relative = p;
        }
        Some(p)
    }
    fn node(&mut self) -> Option<()> {
        let options = if self.source[self.at..].trim_start().starts_with('[') {
            self.group('[', ']')?
        } else {
            String::new()
        };
        let text = self.group('{', '}')?;
        let kind = options.trim();
        if ![
            "ground",
            "rground",
            "circ",
            "ocirc",
            "above",
            "below",
            "left",
            "right",
            "above left",
            "above right",
            "below left",
            "below right",
            "",
        ]
        .contains(&kind)
        {
            return None;
        }
        if text.chars().count() > 256
            || (matches!(kind, "ground" | "rground" | "circ" | "ocirc") && !text.is_empty())
        {
            return None;
        }
        if self.circuit.decorations.len() >= 128 {
            return None;
        }
        self.circuit.decorations.push(Decoration {
            point: self.current,
            kind: kind.to_owned(),
            text: if text.is_empty() {
                String::new()
            } else {
                label_text(&text)?
            },
        });
        Some(())
    }
    fn segment(
        &mut self,
        kind: String,
        labels: Vec<Label>,
        marks: (char, char),
        end: Point,
    ) -> Option<()> {
        if self.circuit.segments.len() >= 128 || end == self.current {
            return None;
        }
        self.circuit.segments.push(Segment {
            start: self.current,
            end,
            kind,
            labels,
            marks,
        });
        self.current = end;
        Some(())
    }
    fn path(&mut self) -> Option<()> {
        if self.source[self.at..].trim_start().starts_with('[') {
            let styles = self.group('[', ']')?;
            if split_options(&styles)?
                .iter()
                .any(|s| !["thin", "semithick", "thick"].contains(s))
            {
                return None;
            }
        }
        self.current = self.point()?;
        let first = self.current;
        loop {
            self.space();
            if self.eat(";") {
                return Some(());
            }
            if self.eat("node") {
                self.node()?;
                continue;
            }
            let (kind, labels, marks, route) = if self.eat("--") {
                (String::from("short"), Vec::new(), (' ', ' '), 0)
            } else if self.eat("|-") {
                (String::from("short"), Vec::new(), (' ', ' '), 1)
            } else if self.eat("-|") {
                (String::from("short"), Vec::new(), (' ', ' '), 2)
            } else if self.eat("to") {
                let options = self.group('[', ']')?;
                let (k, l, m) = component(&options, self.rp)?;
                (k, l, m, 0)
            } else {
                return None;
            };
            let end = if self.eat("cycle") {
                first
            } else {
                self.point()?
            };
            if route != 0 {
                let middle = if route == 1 {
                    Point(self.current.0, end.1)
                } else {
                    Point(end.0, self.current.1)
                };
                if middle != self.current {
                    self.segment("short".into(), Vec::new(), (' ', ' '), middle)?;
                }
            }
            if self.current != end {
                self.segment(kind, labels, marks, end)?;
            } else if route == 0 {
                return None;
            }
        }
    }
}
fn split_options(source: &str) -> Option<Vec<&str>> {
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
fn component(source: &str, rp: bool) -> Option<(String, Vec<Label>, (char, char))> {
    let mut kind = None;
    let mut pending = Vec::new();
    let mut marks = (' ', ' ');
    for item in split_options(source)? {
        if item.is_empty() || ["thin", "semithick", "thick"].contains(&item) {
            continue;
        }
        if let Some(name) = component_name(item) {
            if kind.is_some() {
                return None;
            }
            kind = Some(name.to_owned());
            continue;
        }
        if let Some((key, value)) = item.split_once('=') {
            let key = key.trim();
            if let Some(component) = component_name(key) {
                if kind.is_some() || pending.len() >= 4 {
                    return None;
                }
                kind = Some(component.to_owned());
                pending.push(('l', String::new(), label_text(value.trim())?));
                continue;
            }
            let base = key.chars().next()?;
            if !matches!(base, 'l' | 'a' | 'i' | 'v') || pending.len() >= 4 {
                return None;
            }
            let tail = &key[1..];
            if ![
                "", "_", "^", ">", "<", "^>", "^<", "_>", "_<", ">^", "<^", ">_", "<_",
            ]
            .contains(&tail)
            {
                return None;
            }
            if matches!(base, 'l' | 'a') && (tail.contains('<') || tail.contains('>')) {
                return None;
            }
            if matches!(base, 'i' | 'v') && !rp && !tail.contains('<') && !tail.contains('>') {
                return None;
            }
            pending.push((base, tail.to_owned(), label_text(value.trim())?));
            continue;
        }
        let endpoints = match item {
            "*-*" => ('*', '*'),
            "o-o" => ('o', 'o'),
            "*-" => ('*', ' '),
            "-*" => (' ', '*'),
            "o-" => ('o', ' '),
            "-o" => (' ', 'o'),
            "*-o" => ('*', 'o'),
            "o-*" => ('o', '*'),
            _ => return None,
        };
        if marks != (' ', ' ') {
            return None;
        }
        marks = endpoints;
    }
    let kind = kind.unwrap_or_else(|| "short".into());
    let mut labels = Vec::new();
    for (base, tail, text) in pending {
        let direction = if tail.contains('>') {
            1.
        } else if tail.contains('<') {
            -1.
        } else if base == 'i' {
            if matches!(kind.as_str(), "V" | "sV" | "battery1") {
                -1.
            } else {
                1.
            }
        } else if matches!(kind.as_str(), "V" | "sV" | "battery1") {
            1.
        } else {
            -1.
        };
        labels.push(Label {
            text,
            side: if tail.contains('_') { -1. } else { 1. },
            kind: base,
            direction,
        });
    }
    Some((kind, labels, marks))
}
mod labels;
fn label_text(source: &str) -> Option<String> {
    labels::normalize(source)
}
pub fn parse(source: &str) -> Option<Circuit> {
    if source.len() > 32768 {
        return None;
    }
    let body = source.strip_prefix(BEGIN)?.strip_suffix(END)?;
    let mut p = Parser {
        source: body,
        at: 0,
        names: HashMap::new(),
        circuit: Circuit {
            american: false,
            segments: Vec::new(),
            decorations: Vec::new(),
        },
        current: Point(0., 0.),
        relative: Point(0., 0.),
        rp: false,
    };
    p.space();
    if p.source[p.at..].starts_with('[') {
        let options = p.group('[', ']')?;
        for option in split_options(&options)? {
            match option {
                "american" | "american resistors" => p.circuit.american = true,
                "RPvoltages" | "voltage dir=RP" => p.rp = true,
                "thin" | "semithick" | "thick" => (),
                "european" | "european resistors" => p.circuit.american = false,
                _ => return None,
            }
        }
    }
    loop {
        p.space();
        if p.at == body.len() {
            break;
        }
        if p.eat("\\coordinate") {
            let name = p.group('(', ')')?;
            if name.is_empty() || name.len() > 64 || p.names.len() >= 128 || !p.eat("at") {
                return None;
            }
            let point = p.point()?;
            if !p.eat(";") || p.names.insert(name, point).is_some() {
                return None;
            }
        } else if p.eat("\\draw") {
            p.path()?;
        } else {
            return None;
        }
    }
    if p.circuit.segments.is_empty() {
        None
    } else {
        Some(p.circuit)
    }
}
/// Circuits are extracted before line/image parsing. Fenced examples stay literal.
fn environment_end(source: &str, start: usize) -> usize {
    let mut at = start + BEGIN.len();
    let mut depth = 1usize;
    while at < source.len() {
        if source[at..].starts_with('%')
            && source[..at]
                .bytes()
                .rev()
                .take_while(|c| *c == b'\\')
                .count()
                % 2
                == 0
        {
            at += source[at..].find('\n').unwrap_or(source.len() - at);
            continue;
        }
        if source[at..].starts_with(BEGIN) {
            depth += 1;
            at += BEGIN.len();
            continue;
        }
        if source[at..].starts_with(END) {
            depth -= 1;
            at += END.len();
            if depth == 0 {
                return at;
            }
            continue;
        }
        at += source[at..].chars().next().unwrap().len_utf8();
    }
    source.len()
}
pub(super) fn document(source: &str) -> Option<Vec<super::Node>> {
    if !source.contains(BEGIN) {
        return None;
    }
    let mut spans = Vec::new();
    let mut at = 0;
    let mut fence: Option<(char, usize)> = None;
    while at < source.len() {
        let end = source[at..].find('\n').map_or(source.len(), |n| at + n + 1);
        let line = &source[at..end];
        let trim = line.trim();
        let mark = trim
            .chars()
            .next()
            .filter(|c| "`~".contains(*c))
            .map(|c| (c, trim.chars().take_while(|x| *x == c).count()))
            .filter(|x| x.1 >= 3);
        if let Some(open) = fence {
            if mark.is_some_and(|close| close.0 == open.0 && close.1 >= open.1) {
                fence = None;
            }
            at = end;
            continue;
        }
        if mark.is_some() {
            fence = mark;
            at = end;
            continue;
        }
        if let Some(offset) = line.find(BEGIN) {
            let start = at + offset;
            let close = environment_end(source, start);
            spans.push((start, close));
            at = close;
        } else {
            at = end;
        }
    }
    if spans.is_empty() {
        return None;
    }
    let mut nodes = Vec::new();
    let mut previous = 0;
    for (start, end) in spans {
        nodes.extend(super::parse(&source[previous..start]));
        if let Some(circuit) = parse(&source[start..end]) {
            nodes.push(super::Node::Circuit(circuit));
        } else {
            nodes.extend(source[start..end].chars().map(|c| {
                if c == '\n' {
                    super::Node::Newline
                } else {
                    super::Node::Char(c)
                }
            }));
        }
        previous = end;
    }
    nodes.extend(super::parse(&source[previous..]));
    Some(nodes)
}
