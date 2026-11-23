import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'paper_exif.dart';

import '../models/fine_edit.dart';
import '../models/fine_transform.dart';
import '../models/ink_page.dart';
import 'ink_effects.dart';

class FinePose {
  FinePose(FineGlyph glyph, FineAdjustment? edit)
    : scale = (edit?.scale ?? 100) / 100,
      origin = ui.Offset(
        glyph.x + glyph.width / 2 + (edit?.dx ?? 0),
        glyph.y + glyph.height / 2 + (edit?.dy ?? 0),
      ),
      angle = (edit?.angle ?? 0) * math.pi / 180 {
    cos = math.cos(angle);
    sin = math.sin(angle);
    final warp = edit?.warp;
    if (warp != null) {
      final corners = fineCorners(glyph.width, glyph.height, scale, cos, sin);
      if (fineWarpFits(warp, corners)) {
        final m = [...coefficients(warp), 1.0];
        final points = corners.map((point) => origin + mapFinePoint(m, point));
        center = origin + mapFinePoint(m, ui.Offset.zero);
        bounds = points
            .map((point) => ui.Rect.fromPoints(point, point))
            .reduce((a, b) => a.expandToInclude(b));
        projection = m;
        inverse = inverseFineWarp(warp);
        return;
      }
    }
    center = origin;
    projection = inverse = null;
    bounds = ui.Rect.fromCenter(
      center: center,
      width: scale * (cos.abs() * glyph.width + sin.abs() * glyph.height),
      height: scale * (sin.abs() * glyph.width + cos.abs() * glyph.height),
    );
  }
  final double scale, angle;
  final ui.Offset origin;
  late final ui.Offset center;
  late final List<double>? projection, inverse;
  late final double cos, sin;
  late final ui.Rect bounds;

  bool hit(FineGlyph glyph, ui.Offset point) {
    if (!bounds.contains(point)) return false;
    final warp = inverse;
    if (warp == null) return true;
    final at = mapFinePoint(warp, point - origin);
    return (at.dx * cos + at.dy * sin).abs() <= glyph.width * scale / 2 &&
        (-at.dx * sin + at.dy * cos).abs() <= glyph.height * scale / 2;
  }
}

Future<ui.Image> _image(Uint8List bytes, int width, int height) {
  final result = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    bytes,
    width,
    height,
    ui.PixelFormat.rgba8888,
    result.complete,
  );
  return result.future;
}

typedef _Shape = ({double thickness, double softness});

_Shape _shape(InkLook look, FineAdjustment? edit) => (
  thickness: (look.thickness + (edit?.thickness ?? 0) / 10).clamp(-2.0, 2.0),
  softness: (look.softness + (edit?.softness ?? 0) / 10).clamp(0.0, 2.0),
);

/// The atlas is decoded once while moving glyphs. Clipboard and exports use
/// identical integer compositing in page pixels, independent of device zoom.
class FineRaster {
  FineRaster._(this.paper, this.page, this._pixels, this._width)
    : _displayPixels = Uint8List(_pixels.length * 4);
  final ui.Image paper;
  final FinePage page;
  final Uint8List _pixels;
  final int _width;
  final Uint8List _displayPixels;
  final _masks = <int, ({_Shape shape, Uint8List pixels})>{};
  InkLook? _look;
  ui.Image? _displayAtlas;
  bool _disposed = false;

  static Future<FineRaster> decode(InkPage page) async {
    final paper = await decodeInkImage(page.paper);
    try {
      final model = page.fine!;
      final atlas = await decodeInkImage(model.atlas);
      try {
        for (final glyph in model.glyphs) {
          if (glyph.ax + glyph.width > atlas.width ||
              glyph.ay + glyph.height > atlas.height) {
            throw const FormatException('Glyph outside fine edit atlas');
          }
        }
        final raw = (await atlas.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
        final coverage = Uint8List(atlas.width * atlas.height);
        for (var i = 0; i < coverage.length; i++) {
          coverage[i] = raw[i * 4];
        }
        return FineRaster._(paper, model, coverage, atlas.width);
      } finally {
        atlas.dispose();
      }
    } catch (_) {
      paper.dispose();
      rethrow;
    }
  }

  Uint8List _mask(FineGlyph glyph, InkLook look, _Shape shape) {
    final mask = Uint8List(glyph.width * glyph.height);
    for (var y = 0; y < glyph.height; y++) {
      final start = (glyph.ay + y) * _width + glyph.ax;
      mask.setRange(y * glyph.width, (y + 1) * glyph.width, _pixels, start);
    }
    final shaped = shapeInkAlpha(
      (alpha: mask, width: glyph.width, height: glyph.height),
      shape.thickness,
      shape.softness,
    );
    final opacity = look.opacity * (look.color >> 24 & 255);
    if (opacity != 25500) {
      // The plain mask may be shared. Each glyph has its own alpha buffer.
      for (var i = 0; i < shaped.length; i++) {
        shaped[i] = (shaped[i] * opacity + 12750) ~/ 25500;
      }
    }
    return shaped;
  }

  Future<void> prepare(InkLook look, Map<int, FineAdjustment> edits) async {
    final rebuild = _look != look;
    var changed = rebuild;
    for (final glyph in page.glyphs) {
      final base = fineInkLook(glyph, look);
      final shape = _shape(base, edits[glyph.id]);
      if (!rebuild && _masks[glyph.id]?.shape == shape) continue;
      final mask = _mask(glyph, base, shape);
      _masks[glyph.id] = (shape: shape, pixels: mask);
      changed = true;
      for (var y = 0; y < glyph.height; y++) {
        final start = ((glyph.ay + y) * _width + glyph.ax) * 4;
        for (var x = 0; x < glyph.width; x++) {
          _displayPixels[start + x * 4 + 3] = mask[y * glyph.width + x];
        }
      }
    }
    if (!changed) return;
    final atlas = await _image(
      _displayPixels,
      _width,
      _displayPixels.length ~/ (_width * 4),
    );
    if (_disposed) {
      atlas.dispose();
      return;
    }
    _displayAtlas?.dispose();
    _displayAtlas = atlas;
    _look = look;
  }

  void paint(ui.Canvas canvas, Map<int, FineAdjustment> edits, InkLook look) {
    canvas.drawImage(paper, ui.Offset.zero, ui.Paint());
    final atlas = _displayAtlas;
    if (atlas == null) return;
    final brush = ui.Paint()..filterQuality = ui.FilterQuality.none;
    final paintLook = _look ?? look;
    canvas.save();
    canvas.clipRect(
      ui.Rect.fromLTWH(0, 0, paper.width.toDouble(), paper.height.toDouble()),
    );
    for (final glyph in page.glyphs) {
      final edit = edits[glyph.id];
      final pose = FinePose(glyph, edit);
      final color = ui.Color(edit?.color ?? fineInkLook(glyph, paintLook).color)
          .withValues(alpha: (edit?.opacity ?? 100) / 100);
      brush.colorFilter = ui.ColorFilter.mode(color, ui.BlendMode.srcIn);
      final w = glyph.width.toDouble(), h = glyph.height.toDouble();
      canvas.save();
      canvas.translate(pose.origin.dx, pose.origin.dy);
      if (pose.projection case final m?) {
        canvas.transform(
          Float64List.fromList([
            m[0],
            m[3],
            0,
            m[6],
            m[1],
            m[4],
            0,
            m[7],
            0,
            0,
            1,
            0,
            m[2],
            m[5],
            0,
            m[8],
          ]),
        );
      }
      canvas.rotate(pose.angle);
      canvas.scale(pose.scale);
      canvas.drawImageRect(
        atlas,
        ui.Rect.fromLTWH(glyph.ax.toDouble(), glyph.ay.toDouble(), w, h),
        ui.Rect.fromLTWH(-w / 2, -h / 2, w, h),
        brush,
      );
      canvas.restore();
    }
    canvas.restore();
  }

  Future<ui.Image> render(Map<int, FineAdjustment> edits, InkLook look) async {
    final width = paper.width, height = paper.height;
    final data = (await paper.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final pixels = data.buffer.asUint8List();
    for (final glyph in page.glyphs) {
      final edit = edits[glyph.id];
      final pose = FinePose(glyph, edit);
      final rect = pose.bounds;
      final left = math.max(0, rect.left.floor());
      final right = math.min(width, rect.right.ceil());
      final baseLook = fineInkLook(glyph, look);
      final color = edit?.color ?? baseLook.color;
      final opacity = edit?.opacity ?? 100;
      final shape = _shape(baseLook, edit);
      final cached = _masks[glyph.id];
      final mask = _look == look && cached?.shape == shape
          ? cached!.pixels
          : _mask(glyph, baseLook, shape);
      for (
        var y = math.max(0, rect.top.floor());
        y < math.min(height, rect.bottom.ceil());
        y++
      ) {
        for (var x = left; x < right; x++) {
          var position = ui.Offset(x + .5, y + .5) - pose.origin;
          if (pose.inverse case final inverse?) {
            position = mapFinePoint(inverse, position);
            if (!position.isFinite) continue;
          }
          final dx = position.dx, dy = position.dy;
          final sx =
              ((dx * pose.cos + dy * pose.sin) / pose.scale +
                      glyph.width / 2 +
                      1e-9)
                  .floor();
          final sy =
              ((-dx * pose.sin + dy * pose.cos) / pose.scale +
                      glyph.height / 2 +
                      1e-9)
                  .floor();
          if (sx < 0 || sy < 0 || sx >= glyph.width || sy >= glyph.height) {
            continue;
          }
          final alpha = (mask[sy * glyph.width + sx] * opacity + 50) ~/ 100;
          if (alpha == 0) continue;
          final base = (y * width + x) * 4;
          for (var c = 0; c < 3; c++) {
            final value = color >> ((2 - c) * 8) & 255;
            pixels[base + c] =
                (pixels[base + c] * (255 - alpha) + value * alpha + 127) ~/ 255;
          }
        }
      }
    }
    return _image(pixels, width, height);
  }

  Future<Uint8List> png(Map<int, FineAdjustment> edits, InkLook look) async {
    final image = await render(edits, look);
    try {
      return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
          .asUint8List();
    } finally {
      image.dispose();
    }
  }

  void dispose() {
    _disposed = true;
    _displayAtlas?.dispose();
    paper.dispose();
  }
}

Future<Uint8List> compositeFinePage(
  InkPage page,
  Map<int, FineAdjustment> edits,
  InkLook look,
) async {
  final raster = await FineRaster.decode(page);
  try {
    return withPaperExif(await raster.png(edits, look), page.cameraExif);
  } finally {
    raster.dispose();
  }
}
