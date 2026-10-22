# Copyright (c) 2026 Simon and Panache contributors.
"""2026-10-22：有界电路标注转写；未知宏保留整幅电路源码."""

import re

_SYMBOLS = {
    "Gamma": "\u0393",
    "Theta": "\u0398",
    "Lambda": "\u039b",
    "Xi": "\u039e",
    "Pi": "\u03a0",
    "Sigma": "\u03a3",
    "Upsilon": "\u03a5",
    "Phi": "\u03a6",
    "Psi": "\u03a8",
    "Omega": "Ω",
    "omega": "ω",
    "mu": "μ",
    "alpha": "α",
    "beta": "β",
    "gamma": "\u03b3",
    "delta": "δ",
    "zeta": "\u03b6",
    "eta": "\u03b7",
    "iota": "\u03b9",
    "kappa": "\u03ba",
    "nu": "\u03bd",
    "xi": "\u03be",
    "omicron": "\u03bf",
    "upsilon": "\u03c5",
    "chi": "\u03c7",
    "psi": "\u03c8",
    "varpi": "\u03d6",
    "varsigma": "\u03c2",
    "Delta": "Δ",
    "phi": "\u03d5",
    "varphi": "φ",
    "theta": "θ",
    "vartheta": "\u03d1",
    "pi": "π",
    "lambda": "λ",
    "tau": "τ",
    "sigma": "\u03c3",
    "rho": "\u03c1",
    "varrho": "\u03f1",
    "epsilon": "\u03f5",
    "varepsilon": "ε",
    "cdot": "·",
    "times": "×",
    "pm": "±",
    "infty": "∞",
    "angle": "∠",
    "circ": "°",
    "sin": "sin ",
    "cos": "cos ",
    "exp": "exp ",
    "ln": "ln ",
    "log": "log ",
}
_UNITS = {
    "ohm": "Ω",
    "Omega": "Ω",
    "volt": "V",
    "ampere": "A",
    "farad": "F",
    "henry": "H",
    "hertz": "Hz",
    "second": "s",
    "watt": "W",
    "radian": "rad",
    "degree": "°",
    "kilo": "k",
    "mega": "M",
    "giga": "G",
    "milli": "m",
    "micro": "μ",
    "nano": "n",
    "pico": "p",
}
_MAX_LABEL = 256
_MAX_DEPTH = 8
_ASCII_CONTROL_LIMIT = 32


class _InvalidLabelError(ValueError):
    pass


class _LabelParser:
    def __init__(self, source: str) -> None:
        self.source = source
        self.index = 0

    def argument(self, depth: int) -> str:
        if depth > _MAX_DEPTH:
            raise _InvalidLabelError
        while self.index < len(self.source) and self.source[self.index].isspace():
            self.index += 1
        if self.index == len(self.source):
            raise _InvalidLabelError
        if self.source[self.index] == "{":
            self.index += 1
            return self.content(depth + 1, grouped=True)
        value = self.source[self.index]
        if value == "\\":
            self.index += 1
            return self.command(depth + 1)
        if value in "}_^[]":
            raise _InvalidLabelError
        self.index += 1
        return value

    def command(self, depth: int) -> str:
        match = re.match(r"[A-Za-z]+|.", self.source[self.index :])
        if match is None:
            raise _InvalidLabelError
        command = match[0]
        self.index += len(command)
        if command in (",", ";", ":", " ", "quad", "qquad"):
            return " "
        if command in ("%", "&", "#", "_"):
            return command
        if command in _SYMBOLS:
            return _SYMBOLS[command]
        if command in ("mathrm", "text", "textrm", "operatorname", "mathbf", "mathit"):
            return self.argument(depth)
        if command in ("frac", "dfrac", "tfrac"):
            numerator = self.argument(depth)
            denominator = self.argument(depth)
            return f"({numerator})/({denominator})"
        if command == "sqrt":
            return f"√({self.argument(depth)})"
        raise _InvalidLabelError

    def content(self, depth: int = 0, *, grouped: bool = False) -> str:
        if depth > _MAX_DEPTH:
            raise _InvalidLabelError
        parts: list[str] = []
        while self.index < len(self.source):
            char = self.source[self.index]
            self.index += 1
            if char == "}":
                if not grouped:
                    raise _InvalidLabelError
                return "".join(parts)
            if char == "{":
                parts.append(self.content(depth + 1, grouped=True))
            elif char == "\\":
                parts.append(self.command(depth))
            elif char in "_^":
                argument = self.argument(depth)
                parts.append("°" if char == "^" and argument == "°" else f"{char}({argument})")
            elif char in "$\n\r" or ord(char) < _ASCII_CONTROL_LIMIT:
                raise _InvalidLabelError
            else:
                parts.append(char)
        if grouped:
            raise _InvalidLabelError
        return "".join(parts)


def _si_unit(source: str) -> str | None:
    tokens = re.findall(r"\\[A-Za-z]+|[A-Za-zΩμ°]+", source)
    if "".join(tokens) != re.sub(r"\s+", "", source):
        return None
    parts: list[str] = []
    for token in tokens:
        if token.startswith("\\"):
            value = _UNITS.get(token[1:])
            if value is None:
                return None
            parts.append(value)
        else:
            parts.append(token)
    return "".join(parts) or None


def normalize_circuit_label(source: str) -> str | None:
    """2026-10-22：将已知电路数学标注转为引擎上下标协议；未知标注返回 None."""
    if len(source) > _MAX_LABEL:
        return None
    value = source.strip()
    if value.startswith("$") and value.endswith("$"):
        value = value[1:-1]
    si = re.fullmatch(r"\\SI\{([+-]?(?:\d+(?:\.\d*)?|\.\d+))\}\{([^{}]+)\}", value)
    if si:
        unit = _si_unit(si[2])
        return None if unit is None else f"{si[1]} {unit}"
    unit_match = re.fullmatch(r"\\si\{([^{}]+)\}", value)
    if unit_match:
        return _si_unit(unit_match[1])
    try:
        result = _LabelParser(value).content()
    except _InvalidLabelError:
        return None
    return re.sub(r" +", " ", result).strip() or None
