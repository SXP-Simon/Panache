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
    pub end_arrow: bool,
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
mod labels;
mod options;
use options::{Component, split_options};

enum Route {
    Direct,
    VerticalFirst,
    HorizontalFirst,
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
                labels::normalize(&text)?
            },
        });
        Some(())
    }
    fn segment(&mut self, component: Component, end: Point) -> Option<()> {
        if self.circuit.segments.len() >= 128 || end == self.current {
            return None;
        }
        self.circuit.segments.push(Segment {
            start: self.current,
            end,
            kind: component.kind.into(),
            labels: component.labels,
            marks: component.marks,
            end_arrow: false,
        });
        self.current = end;
        Some(())
    }
    fn path(&mut self) -> Option<()> {
        let start = self.circuit.segments.len();
        let mut end_arrow = false;
        if self.source[self.at..].trim_start().starts_with('[') {
            let styles = self.group('[', ']')?;
            for style in split_options(&styles)? {
                match style {
                    "->" => end_arrow = true,
                    "thin" | "semithick" | "thick" => {}
                    _ => return None,
                }
            }
        }
        self.current = self.point()?;
        let first = self.current;
        loop {
            self.space();
            if self.eat(";") {
                if end_arrow {
                    let last = self.circuit.segments[start..].last_mut()?;
                    if last.kind != "short" {
                        return None;
                    }
                    last.end_arrow = true;
                }
                return Some(());
            }
            if self.eat("node") {
                self.node()?;
                continue;
            }
            let (component, route) = if self.eat("--") {
                (Component::wire(), Route::Direct)
            } else if self.eat("|-") {
                (Component::wire(), Route::VerticalFirst)
            } else if self.eat("-|") {
                (Component::wire(), Route::HorizontalFirst)
            } else if self.eat("to") {
                let options = self.group('[', ']')?;
                (Component::parse(&options, self.rp)?, Route::Direct)
            } else {
                return None;
            };
            let end = if self.eat("cycle") {
                first
            } else {
                self.point()?
            };
            let middle = match route {
                Route::Direct => None,
                Route::VerticalFirst => Some(Point(self.current.0, end.1)),
                Route::HorizontalFirst => Some(Point(end.0, self.current.1)),
            };
            if let Some(point) = middle
                && point != self.current
            {
                self.segment(Component::wire(), point)?;
            }
            if self.current != end {
                self.segment(component, end)?;
            } else if middle.is_none() {
                return None;
            }
        }
    }
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
