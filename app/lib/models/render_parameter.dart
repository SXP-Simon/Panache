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

  /// Drafts from older versions may contain decimal values for integer fields.
  String? valueFromDraft(Object? raw) {
    final number = num.tryParse('$raw');
    if (number == null ||
        !number.isFinite ||
        number < minimum ||
        (maximum != null && number > maximum!) ||
        (fractionalInk && !accepts('$number'))) {
      return null;
    }
    return integer ? '${number.toInt()}' : '$number';
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
