// A deliberately small siunitx subset. Unrecognised options, units and numeric
// uncertainties remain source, so a course formula cannot silently change units.
String normalizeCourseLatex(String source) {
  final out = StringBuffer();
  var cursor = 0;
  while (cursor < source.length) {
    if (source[cursor] != r'\') {
      out.write(source[cursor++]);
      continue;
    }
    final command = RegExp(r'^\\([A-Za-z]+|.)')
        .firstMatch(source.substring(cursor));
    if (command == null) {
      out.write(source[cursor++]);
      continue;
    }
    final name = command[1]!;
    final end = cursor + command[0]!.length;
    final first = _argument(source, end);
    if ({'text', 'textrm', 'textbf', 'textit', 'verb'}.contains(name) &&
        first != null) {
      out.write(source.substring(cursor, first.end));
      cursor = first.end;
      continue;
    }
    if (!{'SI', 'si', 'num'}.contains(name) || first == null) {
      out.write(command[0]);
      cursor = end;
      continue;
    }
    final second = name == 'SI' ? _argument(source, first.end) : null;
    final number = name == 'si' ? null : _number(first.body);
    final unit = name == 'num'
        ? null
        : _unit(name == 'si' ? first.body : second?.body ?? '');
    final replacement = name == 'num'
        ? number
        : unit == null || (name == 'SI' && number == null)
        ? null
        : name == 'si'
        ? unit
        : '$number\\,$unit';
    final consumed = second?.end ?? first.end;
    out.write(replacement ?? source.substring(cursor, consumed));
    cursor = consumed;
  }
  return out.toString();
}

({String body, int end})? _argument(String source, int start) {
  while (start < source.length && RegExp(r'\s').hasMatch(source[start])) {
    start++;
  }
  if (start >= source.length || source[start] != '{') return null;
  var depth = 1;
  for (var i = start + 1; i < source.length; i++) {
    if (source[i] == r'\') {
      i++;
      continue;
    }
    if (source[i] == '{') depth++;
    if (source[i] == '}' && --depth == 0) {
      return (body: source.substring(start + 1, i), end: i + 1);
    }
  }
  return null;
}

String? _number(String value) {
  final match = RegExp(
    r'^([+-]?(?:\d+(?:\.\d*)?|\.\d+))(?:[eE]([+-]?\d{1,3}))?$',
  ).firstMatch(value.trim());
  if (match == null) return null;
  return match[2] == null
      ? match[1]
      : '${match[1]}\\times10^{${int.parse(match[2]!)}}';
}

const _prefixes = {
  'pico': 'p',
  'nano': 'n',
  'micro': 'μ',
  'milli': 'm',
  'centi': 'c',
  'deci': 'd',
  'kilo': 'k',
  'mega': 'M',
  'giga': 'G',
  'tera': 'T',
};
const _units = {
  'metre': 'm',
  'meter': 'm',
  'second': 's',
  'ampere': 'A',
  'kelvin': 'K',
  'mole': 'mol',
  'candela': 'cd',
  'gram': 'g',
  'kilogram': 'kg',
  'hertz': 'Hz',
  'newton': 'N',
  'pascal': 'Pa',
  'joule': 'J',
  'watt': 'W',
  'coulomb': 'C',
  'volt': 'V',
  'farad': 'F',
  'ohm': 'Ω',
  'siemens': 'S',
  'weber': 'Wb',
  'tesla': 'T',
  'henry': 'H',
  'radian': 'rad',
  'steradian': 'sr',
  'degree': '°',
  'degreeCelsius': '°C',
  'liter': 'L',
  'litre': 'L',
  'electronvolt': 'eV',
  'decibel': 'dB',
  'percent': r'\%',
  'bit': 'bit',
  'byte': 'B',
};

String? _unit(String source) {
  final tokens = RegExp(r'\\([A-Za-z]+)(?:\{([+-]?\d{1,3})\})?');
  final numerator = <String>[], denominator = <String>[];
  var cursor = 0, prefix = '', divided = false, powered = false;
  List<String>? lastTarget;
  for (final token in tokens.allMatches(source)) {
    if (source.substring(cursor, token.start).trim().isNotEmpty) return null;
    cursor = token.end;
    final name = token[1]!;
    final target = divided ? denominator : numerator;
    if (name == 'per' && token[2] == null) {
      if (divided || prefix.isNotEmpty) return null;
      divided = true;
      powered = false;
      lastTarget = null;
    } else if (_prefixes.containsKey(name) && token[2] == null) {
      if (prefix.isNotEmpty) return null;
      prefix = _prefixes[name]!;
    } else if (_units.containsKey(name) && token[2] == null) {
      target.add('\\mathrm{$prefix${_units[name]}}');
      lastTarget = target;
      divided = false;
      prefix = '';
      powered = false;
    } else if ({'squared', 'cubed', 'tothe'}.contains(name)) {
      if (lastTarget == null || prefix.isNotEmpty || powered) return null;
      final power = name == 'tothe'
          ? token[2]
          : token[2] == null
          ? (name == 'squared' ? '2' : '3')
          : null;
      if (power == null) return null;
      lastTarget[lastTarget.length - 1] += '^{${int.parse(power)}}';
      powered = true;
    } else {
      return null;
    }
  }
  if (source.substring(cursor).trim().isNotEmpty ||
      prefix.isNotEmpty ||
      (numerator.isEmpty && denominator.isEmpty) ||
      divided) {
    return null;
  }
  final top = numerator.isEmpty ? '1' : numerator.join(r'\,');
  if (denominator.isEmpty) return top;
  final bottom = denominator.join(r'\,');
  return '$top/${denominator.length > 1 ? '($bottom)' : bottom}';
}

String calligraphicCapitals(String value) {
  if (!RegExp(r'^[A-Z]+$').hasMatch(value)) {
    throw const FormatException('Unsupported calligraphic symbol');
  }
  const legacy = {
    'B': 'ℬ',
    'E': 'ℰ',
    'F': 'ℱ',
    'H': 'ℋ',
    'I': 'ℐ',
    'L': 'ℒ',
    'M': 'ℳ',
    'R': 'ℛ',
  };
  return value
      .split('')
      .map(
        (letter) =>
            legacy[letter] ??
            String.fromCharCode(0x1d49c + letter.codeUnitAt(0) - 65),
      )
      .join();
}
