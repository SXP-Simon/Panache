import 'ink_page.dart';

enum PaperStyle { blank, ruled, grid, dots }

const latinFonts = {
  'handlee': 'Handlee',
  'patrick_hand': 'Patrick Hand',
  'indie_flower': 'Indie Flower',
  'kalam': 'Kalam',
  'shadows_into_light': 'Shadows Into Light',
};

const latinScaleParameter = Parameter(
  'latin_font_scale',
  '英文字号比例',
  'English font scale',
  100,
  minimum: 50,
  maximum: 150,
);

class Parameter {
  const Parameter(
    this.key,
    this.zh,
    this.en,
    this.value, {
    this.minimum = 0,
    this.maximum,
  });
  final String key, zh, en;
  final num value, minimum;
  final num? maximum;
  bool get integer =>
      !key.startsWith('strikethrough_') &&
      key != 'ink_depth_sigma' &&
      key != 'perturb_theta_sigma' &&
      !fractionalInk;
  bool get fractionalInk => key == 'ink_thickness' || key == 'ink_softness';
  bool accepts(String? raw) {
    final n = num.tryParse(raw ?? '');
    return n != null &&
        n.isFinite &&
        n >= minimum &&
        (maximum == null || n <= maximum!) &&
        (!fractionalInk || n * 10 == (n * 10).round()) &&
        (!integer || (n == n.roundToDouble() && !raw!.contains('.')));
  }
}

const inkParameters = [
  Parameter('ink_opacity', '浓淡', 'Opacity', 100, maximum: 100),
  Parameter(
    'ink_thickness',
    '笔画粗细',
    'Stroke thickness',
    0,
    minimum: -2,
    maximum: 2,
  ),
  Parameter('ink_softness', '边缘柔化', 'Edge softness', 0, maximum: 2),
];

const parameters = [
  Parameter('font_size', '字号', 'Font size', 124, minimum: 1),
  Parameter('line_spacing', '行距', 'Line spacing', 200, minimum: 1),
  Parameter('word_spacing', '字间距', 'Character spacing', 1),
  Parameter('width', '纸张宽度', 'Page width', 2481, minimum: 1),
  Parameter('height', '纸张高度', 'Page height', 3507, minimum: 1),
  Parameter('top_margin', '上边距', 'Top margin', 50),
  Parameter('bottom_margin', '下边距', 'Bottom margin', 50),
  Parameter('left_margin', '左边距', 'Left margin', 50),
  Parameter('right_margin', '右边距', 'Right margin', 50),
  Parameter('line_spacing_sigma', '行距扰动', 'Line spacing variation', 0),
  Parameter('font_size_sigma', '字号扰动', 'Font size variation', 2),
  Parameter('word_spacing_sigma', '字距扰动', 'Character spacing variation', 2),
  Parameter('perturb_x_sigma', '水平扰动', 'Horizontal variation', 3),
  Parameter('perturb_y_sigma', '垂直扰动', 'Vertical variation', 3),
  Parameter(
    'perturb_theta_sigma',
    '旋转扰动（弧度）',
    'Rotation variation (radians)',
    .05,
  ),
  Parameter('ink_depth_sigma', '墨色扰动', 'Ink variation', 30),
  Parameter(
    'strikethrough_probability',
    '删除线概率',
    'Strikethrough probability',
    .005,
    maximum: 1,
  ),
  Parameter('strikethrough_width', '删除线宽度', 'Strikethrough width', 8),
  Parameter(
    'strikethrough_length_sigma',
    '删除线长度扰动',
    'Strikethrough length variation',
    2,
  ),
  Parameter(
    'strikethrough_width_sigma',
    '删除线宽度扰动',
    'Strikethrough width variation',
    2,
  ),
  Parameter(
    'strikethrough_angle_sigma',
    '删除线角度扰动',
    'Strikethrough angle variation',
    2,
  ),
];

const legacyFields = <String, String>{
  'fontSize': 'font_size',
  'lineSpacing': 'line_spacing',
  'wordSpacing': 'word_spacing',
  'marginTop': 'top_margin',
  'marginBottom': 'bottom_margin',
  'marginLeft': 'left_margin',
  'marginRight': 'right_margin',
  'lineSpacingSigma': 'line_spacing_sigma',
  'fontSizeSigma': 'font_size_sigma',
  'wordSpacingSigma': 'word_spacing_sigma',
  'perturbXSigma': 'perturb_x_sigma',
  'perturbYSigma': 'perturb_y_sigma',
  'perturbThetaSigma': 'perturb_theta_sigma',
  'width': 'width',
  'height': 'height',
  'ink_depth_sigma': 'ink_depth_sigma',
  'strikethrough_probability': 'strikethrough_probability',
  'strikethrough_width': 'strikethrough_width',
  'strikethrough_length_sigma': 'strikethrough_length_sigma',
  'strikethrough_width_sigma': 'strikethrough_width_sigma',
  'strikethrough_angle_sigma': 'strikethrough_angle_sigma',
};

class Settings {
  Settings();

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
    camera.clear();
    for (final key in cameraKeys) {
      final value = json[key]?.toString() ?? '';
      if (value.isNotEmpty && validCameraValue(key, value)) camera[key] = value;
    }
    for (final p in [...parameters, ...inkParameters]) {
      final value = num.tryParse('${json[p.key]}');
      if (value != null &&
          value.isFinite &&
          value >= p.minimum &&
          (p.maximum == null || value <= p.maximum!) &&
          (!p.fractionalInk || p.accepts('$value'))) {
        values[p.key] = p.integer ? '${value.toInt()}' : '$value';
      }
    }
    if (json['strikethroughEnabled'] is bool) {
      strikethroughEnabled = json['strikethroughEnabled'] as bool;
    } else if (json.containsKey('strikethrough_probability')) {
      strikethroughEnabled =
          (num.tryParse('${json['strikethrough_probability']}') ?? 0) > 0;
    }
    layoutStyle = (json['layoutStyle'] ?? json['layout_style']) == 'homework'
        ? 'homework'
        : 'standard';
    if (json['fill'] is String) fill = json['fill'];
    if (json['font_option'] is String) font = json['font_option'];
    final latin = json['latin_font_option'];
    latinFont = latin is String && latinFonts.containsKey(latin) ? latin : null;
    final scale = '${json['latin_font_scale']}';
    latinScale = latinScaleParameter.accepts(scale) ? int.parse(scale) : 100;
    latinDigits = json['digit_font'] == 'latin';
    firstLineIndent = json['first_line_indent'] == true;
    monospaced = json['monospaced'] == true;
    _paperPattern = switch (json['paper_pattern']) {
      'grid' => 'grid',
      'dots' => 'dots',
      _ => null,
    };
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
  }) => {
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
