// The supported siunitx grammar accepts decimal numbers and products of units.
String? normalizeSiNumber(String value) {
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

String? normalizeSiQuantity(String numberSource, String unitSource) {
  final number = normalizeSiNumber(numberSource);
  final unit = normalizeSiUnit(unitSource);
  if (number == null || unit == null) return null;
  return '$number\\,$unit';
}

String? normalizeSiUnit(String source) {
  final reader = _UnitReader(source);
  final numerator = <String>[], denominator = <String>[];
  while (!reader.atEnd) {
    final target = reader.takePer() ? denominator : numerator;
    final factor = reader.readFactor();
    if (factor == null) return null;
    target.add(factor);
  }
  if (numerator.isEmpty && denominator.isEmpty) return null;
  final top = numerator.isEmpty ? '1' : numerator.join(r'\,');
  if (denominator.isEmpty) return top;
  final bottom = denominator.join(r'\,');
  return '$top/${denominator.length > 1 ? '($bottom)' : bottom}';
}

// Each factor has an optional prefix, a required bare unit and an optional
// power. A preceding \per puts just this factor in the denominator.
class _UnitReader {
  _UnitReader(this.source) {
    _advance();
  }

  final String source;
  static final _command = RegExp(r'\\([A-Za-z]+)(?:\{([+-]?\d{1,3})\})?');
  int _offset = 0;
  Match? _token;

  bool get atEnd => _offset == source.length && _token == null;
  String? get _bareName {
    if (_token?[2] != null) return null;
    return _token?[1];
  }

  void _advance() {
    while (_offset < source.length && source[_offset].trim().isEmpty) {
      _offset++;
    }
    _token = _command.matchAsPrefix(source, _offset);
    if (_token != null) _offset = _token!.end;
  }

  bool takePer() {
    if (_bareName != 'per') return false;
    _advance();
    return true;
  }

  String? readFactor() {
    final prefix = _prefixes[_bareName];
    if (prefix != null) _advance();
    final unit = _units[_bareName];
    if (unit == null) return null;
    _advance();

    final symbol = '\\mathrm{${prefix ?? ''}$unit}';
    final power = switch ((_token?[1], _token?[2])) {
      ('squared', null) => 2,
      ('cubed', null) => 3,
      ('tothe', final String exponent) => int.parse(exponent),
      _ => null,
    };
    if (power == null) return symbol;
    _advance();
    return '$symbol^{$power}';
  }
}
