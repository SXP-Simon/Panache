import 'ink_page.dart';
import 'png_blur.dart';
import 'render_parameter.dart';

export 'render_parameter.dart';

enum PaperStyle { blank, ruled, grid, dots }

class Settings {
  Settings();
  PngBlur pngBlur = PngBlur();

  /// A portrait exercise-book page sized for comfortable mobile previews.
  /// The usable area targets about twenty CJK characters and sixteen lines;
  /// actual glyph advances remain determined by the selected handwriting font.
  factory Settings.notebook() {
    final settings = Settings();
    settings.values.addAll({
      'width': '1600',
      'height': '2200',
      'font_size': '70',
      'word_spacing': '2',
      'left_margin': '80',
      'right_margin': '80',
      'top_margin': '100',
      'bottom_margin': '100',
      'line_spacing': '120',
      'font_size_sigma': '1',
      'word_spacing_sigma': '1',
      'perturb_x_sigma': '1',
      'perturb_y_sigma': '1',
      'perturb_theta_sigma': '0.025',
      'strikethrough_probability': '0',
    });
    return settings;
  }

  final Map<String, String> values = {
    for (final p in [...parameters, ...inkParameters]) p.key: '${p.value}',
  };
  static const cameraKeys = [
    'camera_make',
    'camera_model',
    'camera_lens',
    'camera_iso',
  ];
  final Map<String, String> camera = {};
  static bool validCameraValue(String key, String value) {
    if (value.isEmpty) return true;
    if (key == 'camera_iso') {
      final n = int.tryParse(value);
      return RegExp(r'^[0-9]+$').hasMatch(value) &&
          n != null &&
          n >= 1 &&
          n <= 65535;
    }
    return value.trim().isNotEmpty &&
        value.length <= 96 &&
        !RegExp(r'[^ -~]').hasMatch(value);
  }

  bool strikethroughEnabled = false;
  String fill = '(0, 0, 0, 255)';
  String layoutStyle = 'standard';
  String? font;
  String? latinFont;
  int latinScale = 100;
  bool latinDigits = false, firstLineIndent = false, monospaced = false;
  String? _paperPattern;
  bool transparentBackground = false;
  bool underlined = true, englishSpacing = false, fullPreview = false;

  PaperStyle get paperStyle => switch (_paperPattern) {
    'grid' => PaperStyle.grid,
    'dots' => PaperStyle.dots,
    _ => underlined ? PaperStyle.ruled : PaperStyle.blank,
  };
  set paperStyle(PaperStyle style) {
    underlined = style == PaperStyle.ruled;
    _paperPattern = switch (style) {
      PaperStyle.grid || PaperStyle.dots => style.name,
      _ => null,
    };
  }

  InkLook get inkLook {
    final rgb = fill
        .replaceAll(RegExp(r'[()\[\]\s]'), '')
        .split(',')
        .map(int.tryParse)
        .toList();
    int channel(int index, [int fallback = 0]) =>
        index < rgb.length ? (rgb[index] ?? fallback).clamp(0, 255) : fallback;
    return (
      opacity: int.parse(values['ink_opacity']!),
      thickness: double.parse(values['ink_thickness']!),
      softness: double.parse(values['ink_softness']!),
      color:
          (channel(3, 255) << 24) |
          (channel(0) << 16) |
          (channel(1) << 8) |
          channel(2),
    );
  }

  Map<String, dynamic> toJson() => {
    ...values,
    ...camera,
    'pngBlur': pngBlur.toJson(),
    'fill': fill,
    'layoutStyle': layoutStyle,
    'font_option': font,
    'latin_font_option': latinFont,
    'latin_font_scale': latinScale,
    'digit_font': latinDigits ? 'latin' : 'primary',
    'first_line_indent': firstLineIndent,
    'monospaced': monospaced,
    'paper_pattern': _paperPattern,
    'isUnderlined': underlined,
    'transparent_background': transparentBackground,
    'enableEnglishSpacing': englishSpacing,
    'full_preview': fullPreview,
    'strikethroughEnabled': strikethroughEnabled,
  };

  void restore(Map<String, dynamic> json) {
    json = {
      ...json,
      for (final entry in legacyFields.entries)
        if (json.containsKey(entry.key)) entry.value: json[entry.key],
    };
    pngBlur = PngBlur.restore(json['pngBlur']);
    _restoreCamera(json);
    for (final p in [...parameters, ...inkParameters]) {
      final value = p.valueFromDraft(json[p.key]);
      if (value != null) values[p.key] = value;
    }
    _restoreStrikethrough(json);
    layoutStyle = (json['layoutStyle'] ?? json['layout_style']) == 'homework'
        ? 'homework'
        : 'standard';
    _restoreInkAndFont(json);
    firstLineIndent = json['first_line_indent'] == true;
    monospaced = json['monospaced'] == true;
    _paperPattern = switch (json['paper_pattern']) {
      'grid' => 'grid',
      'dots' => 'dots',
      _ => null,
    };
    transparentBackground =
        (json['transparent_background'] ?? json['transparentBackground']) ==
        true;
    if (json.containsKey('isUnderlined')) {
      underlined = json['isUnderlined'] == true;
    }
    if (json.containsKey('enableEnglishSpacing')) {
      englishSpacing = json['enableEnglishSpacing'] == true;
    }
    if (json.containsKey('full_preview') ||
        json.containsKey('enableFullPreview')) {
      fullPreview = (json['full_preview'] ?? json['enableFullPreview']) == true;
    }
  }

  void _restoreCamera(Map<String, dynamic> json) {
    camera.clear();
    for (final key in cameraKeys) {
      final value = json[key]?.toString() ?? '';
      if (value.isNotEmpty && validCameraValue(key, value)) camera[key] = value;
    }
  }

  void _restoreStrikethrough(Map<String, dynamic> json) {
    if (json['strikethroughEnabled'] is bool) {
      strikethroughEnabled = json['strikethroughEnabled'] as bool;
    } else if (json.containsKey('strikethrough_probability')) {
      strikethroughEnabled =
          (num.tryParse('${json['strikethrough_probability']}') ?? 0) > 0;
    }
  }

  void _restoreInkAndFont(Map<String, dynamic> json) {
    if (json['fill'] is String) fill = json['fill'];
    if (json['font_option'] is String) font = json['font_option'];
    final latin = json['latin_font_option'];
    latinFont = latin is String && latinFonts.containsKey(latin) ? latin : null;
    final scale = '${json['latin_font_scale']}';
    latinScale = latinScaleParameter.accepts(scale) ? int.parse(scale) : 100;
    latinDigits = json['digit_font'] == 'latin';
  }

  bool get valid =>
      camera.entries.every((e) => validCameraValue(e.key, e.value)) &&
      parameters.every((p) => p.accepts(values[p.key])) &&
      num.parse(values['left_margin']!) + num.parse(values['right_margin']!) <
          num.parse(values['width']!) &&
      num.parse(values['top_margin']!) + num.parse(values['bottom_margin']!) <
          num.parse(values['height']!);

  Map<String, String> form(
    String text, {
    required bool preview,
    required bool pdf,
    bool supportsPngBlur = true,
  }) => {
    if (!pdf && supportsPngBlur) ...{'seed': '0', ...pngBlur.fields},
    ...values,
    ...camera,
    if (!strikethroughEnabled) 'strikethrough_probability': '0',
    'text': text,
    'fill': fill,
    'font_option': ?font,
    'latin_font_option': ?latinFont,
    'latin_font_scale': '$latinScale',
    'digit_font': latinDigits ? 'latin' : 'primary',
    'first_line_indent': '$firstLineIndent',
    'monospaced': '$monospaced',
    'paper_pattern': ?_paperPattern,
    'preview': '$preview',
    'pdf_save': '$pdf',
    'transparent_background': '${transparentBackground && !pdf}',
    'full_preview': '$fullPreview',
    'ink_layers': 'true',
    'layout_style': layoutStyle,
    'isUnderlined': '$underlined',
    'enableEnglishSpacing': '$englishSpacing',
  };

  void setStrikethroughEnabled(bool enabled) {
    strikethroughEnabled = enabled;
    if (enabled &&
        (num.tryParse(values['strikethrough_probability'] ?? '') ?? 0) <= 0) {
      values['strikethrough_probability'] = '0.005';
    }
  }

  void smallPreset() {
    strikethroughEnabled = false;
    values.addAll({for (final p in parameters) p.key: '${p.value}'});
    englishSpacing = false;
    values.addAll({
      'font_size': '70',
      'line_spacing': '100',
      'word_spacing': '2',
      'top_margin': '150',
      'bottom_margin': '150',
      'left_margin': '150',
      'right_margin': '150',
      'line_spacing_sigma': '1',
      'font_size_sigma': '1',
      'perturb_x_sigma': '1',
      'perturb_y_sigma': '1',
      'strikethrough_probability': '0',
    });
    paperStyle = PaperStyle.ruled;
  }
}
