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
      key != 'perturb_theta_sigma';
  bool accepts(String? raw) {
    final n = num.tryParse(raw ?? '');
    return n != null &&
        n.isFinite &&
        n >= minimum &&
        (maximum == null || n <= maximum!) &&
        (!integer || (n == n.roundToDouble() && !raw!.contains('.')));
  }
}

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
    for (final p in parameters) p.key: '${p.value}',
  };
  String fill = '(0, 0, 0, 255)';
  String? font;
  bool underlined = true, englishSpacing = false, fullPreview = false;

  Map<String, dynamic> toJson() => {
    ...values,
    'fill': fill,
    'font_option': font,
    'isUnderlined': underlined,
    'enableEnglishSpacing': englishSpacing,
    'full_preview': fullPreview,
  };

  void restore(Map<String, dynamic> json) {
    json = {
      ...json,
      for (final entry in legacyFields.entries)
        if (json.containsKey(entry.key)) entry.value: json[entry.key],
    };
    for (final p in parameters) {
      final value = num.tryParse('${json[p.key]}');
      if (value != null &&
          value.isFinite &&
          value >= p.minimum &&
          (p.maximum == null || value <= p.maximum!)) {
        values[p.key] = p.integer ? '${value.toInt()}' : '$value';
      }
    }
    if (json['fill'] is String) fill = json['fill'];
    if (json['font_option'] is String) font = json['font_option'];
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
    'text': text,
    'fill': fill,
    'font_option': ?font,
    'preview': '$preview',
    'pdf_save': '$pdf',
    'full_preview': '$fullPreview',
    'isUnderlined': '$underlined',
    'enableEnglishSpacing': '$englishSpacing',
  };

  void smallPreset() {
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
    underlined = true;
  }
}
