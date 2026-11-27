import 'dart:convert';

enum PngBlurMode { off, uniform, gradient }

class BlurAnchor {
  BlurAnchor(this.x, this.y, this.sigma);
  double x, y, sigma;

  Map<String, double> toJson() => {'x': x, 'y': y, 'sigma_px': sigma};

  static BlurAnchor? parse(Object? value) {
    if (value case {'x': num x, 'y': num y, 'sigma_px': num sigma}
        when x >= 0 && x <= 1 && y >= 0 && y <= 1 && sigma >= 0 && sigma <= 2) {
      return BlurAnchor(x.toDouble(), y.toDouble(), sigma.toDouble());
    }
    return null;
  }
}

class PngBlur {
  PngBlurMode mode = PngBlurMode.off;
  double uniform = .6;
  BlurAnchor from = BlurAnchor(.5, 0, 1.2), to = BlurAnchor(.5, 1, 0);

  bool get valid =>
      mode != PngBlurMode.gradient || from.x != to.x || from.y != to.y;
  bool get active => switch (mode) {
    PngBlurMode.off => false,
    PngBlurMode.uniform => uniform > 0,
    PngBlurMode.gradient => from.sigma > 0 || to.sigma > 0,
  };

  Map<String, Object> toJson() => {
    'mode': mode.name,
    'uniform': uniform,
    'from': from.toJson(),
    'to': to.toJson(),
  };

  static PngBlur restore(Object? data) {
    final blur = PngBlur();
    if (data is! Map) return blur;
    blur.mode =
        PngBlurMode.values.where((m) => m.name == data['mode']).firstOrNull ??
        PngBlurMode.off;
    if (data['uniform'] case num v when v >= 0 && v <= 2) {
      blur.uniform = v.toDouble();
    }
    blur.from = BlurAnchor.parse(data['from']) ?? blur.from;
    blur.to = BlurAnchor.parse(data['to']) ?? blur.to;
    return blur;
  }

  Map<String, String> get fields => switch (mode) {
    PngBlurMode.off => {},
    PngBlurMode.uniform => {'export_blur_px': '$uniform'},
    PngBlurMode.gradient => {
      'export_blur_gradient': jsonEncode({
        'from': from.toJson(),
        'to': to.toJson(),
      }),
    },
  };
}
