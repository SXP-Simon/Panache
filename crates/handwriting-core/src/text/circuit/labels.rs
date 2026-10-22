//! 2026-10-22：仅转写明确支持的有界电路数学标签。
struct Parser {
    chars: Vec<char>,
    at: usize,
}
impl Parser {
    fn argument(&mut self, depth: usize) -> Option<String> {
        while self.chars.get(self.at).is_some_and(|c| c.is_whitespace()) {
            self.at += 1;
        }
        let c = *self.chars.get(self.at)?;
        self.at += 1;
        if c == '{' {
            self.content(depth + 1, true)
        } else if c == '\\' {
            self.command(depth)
        } else if "}_^[]".contains(c) {
            None
        } else {
            Some(c.to_string())
        }
    }
    fn command(&mut self, depth: usize) -> Option<String> {
        let start = self.at;
        let c = *self.chars.get(self.at)?;
        self.at += 1;
        if c.is_ascii_alphabetic() {
            while self
                .chars
                .get(self.at)
                .is_some_and(|c| c.is_ascii_alphabetic())
            {
                self.at += 1;
            }
        }
        let name: String = self.chars[start..self.at].iter().collect();
        let symbol = match name.as_str() {
            "," | ";" | ":" | " " | "quad" | "qquad" => " ",
            "!" => "",
            "Omega" => "Ω",
            "omega" => "ω",
            "mu" => "μ",
            "alpha" => "α",
            "beta" => "β",
            "gamma" => "γ",
            "delta" => "δ",
            "Delta" => "Δ",
            "phi" => "ϕ",
            "varphi" => "φ",
            "vartheta" => "ϑ",
            "varrho" => "ϱ",
            "varepsilon" => "ε",
            "theta" => "θ",
            "pi" => "π",
            "lambda" => "λ",
            "tau" => "τ",
            "sigma" => "σ",
            "eta" => "η",
            "nu" => "ν",
            "zeta" => "ζ",
            "kappa" => "κ",
            "psi" => "ψ",
            "chi" => "χ",
            "xi" => "ξ",
            "upsilon" => "υ",
            "varsigma" => "ς",
            "varkappa" => "ϰ",
            "varpi" => "ϖ",
            "Gamma" => "Γ",
            "Theta" => "Θ",
            "Lambda" => "Λ",
            "Xi" => "Ξ",
            "Pi" => "Π",
            "Sigma" => "Σ",
            "Upsilon" => "Υ",
            "Phi" => "Φ",
            "Psi" => "Ψ",
            "rho" => "ρ",
            "epsilon" => "ϵ",
            "cdot" => "·",
            "times" => "×",
            "pm" => "±",
            "infty" => "∞",
            "angle" => "∠",
            "circ" => "°",
            "sin" => "sin ",
            "cos" => "cos ",
            "exp" => "exp ",
            "ln" => "ln ",
            "log" => "log ",
            "%" => "%",
            "&" => "&",
            "#" => "#",
            "_" => "_",
            "mathrm" | "text" | "textrm" | "operatorname" | "mathbf" | "mathit" => {
                return self.argument(depth);
            }
            "frac" | "dfrac" | "tfrac" => {
                return Some(format!(
                    "({})/({})",
                    self.argument(depth)?,
                    self.argument(depth)?
                ));
            }
            "sqrt" => return Some(format!("√({})", self.argument(depth)?)),
            _ => return None,
        };
        Some(symbol.into())
    }
    fn content(&mut self, depth: usize, group: bool) -> Option<String> {
        if depth > 8 {
            return None;
        }
        let mut out = String::new();
        while let Some(c) = self.chars.get(self.at).copied() {
            self.at += 1;
            match c {
                '}' => return if group { Some(out) } else { None },
                '{' => out.push_str(&self.content(depth + 1, true)?),
                '\\' => out.push_str(&self.command(depth)?),
                '_' | '^' => {
                    let argument = self.argument(depth)?;
                    if c == '^' && argument == "°" {
                        out.push('°');
                    } else {
                        out.push_str(&format!("{c}({argument})"));
                    }
                }
                '$' | '\n' | '\r' => return None,
                c if c.is_control() => return None,
                _ => out.push(c),
            }
        }
        if group { None } else { Some(out) }
    }
}
fn unit(source: &str) -> Option<String> {
    let mut out = String::new();
    let mut chars = source.chars().peekable();
    while let Some(c) = chars.next() {
        if c.is_whitespace() {
            continue;
        }
        if c == '\\' {
            let mut command = String::new();
            while chars.peek().is_some_and(|c| c.is_ascii_alphabetic()) {
                command.push(chars.next()?);
            }
            out.push_str(match command.as_str() {
                "ohm" | "Omega" => "Ω",
                "volt" => "V",
                "ampere" => "A",
                "farad" => "F",
                "henry" => "H",
                "hertz" => "Hz",
                "second" => "s",
                "watt" => "W",
                "radian" => "rad",
                "degree" => "°",
                "kilo" => "k",
                "mega" => "M",
                "giga" => "G",
                "milli" => "m",
                "micro" => "μ",
                "nano" => "n",
                "pico" => "p",
                _ => return None,
            });
        } else if c.is_ascii_alphabetic() || "Ωμ°".contains(c) {
            out.push(c);
        } else {
            return None;
        }
    }
    if out.is_empty() { None } else { Some(out) }
}
fn decimal(source: &str) -> bool {
    let s = source.strip_prefix(['+', '-']).unwrap_or(source);
    !s.is_empty()
        && s.chars().any(|c| c.is_ascii_digit())
        && s.bytes().filter(|c| *c == b'.').count() <= 1
        && s.chars().all(|c| c.is_ascii_digit() || c == '.')
}
pub(super) fn normalize(source: &str) -> Option<String> {
    let mut s = source.trim();
    while s.starts_with('{') && s.ends_with('}') {
        s = s[1..s.len() - 1].trim();
    }
    if s.starts_with('$') && s.ends_with('$') {
        s = &s[1..s.len() - 1];
    } else if s.starts_with("\\(") && s.ends_with("\\)") {
        s = &s[2..s.len() - 2];
    }
    if s.chars().count() > 256 {
        return None;
    }
    let result = if let Some(s) = s.strip_prefix("\\SI{") {
        let (number, units) = s.split_once("}{")?;
        if !units.ends_with('}') || !decimal(number) {
            return None;
        }
        format!("{number} {}", unit(&units[..units.len() - 1])?)
    } else if let Some(s) = s.strip_prefix("\\si{") {
        unit(s.strip_suffix('}')?)?
    } else {
        Parser {
            chars: s.chars().collect(),
            at: 0,
        }
        .content(0, false)?
    };
    let value = result.split_whitespace().collect::<Vec<_>>().join(" ");
    if value.is_empty() { None } else { Some(value) }
}
