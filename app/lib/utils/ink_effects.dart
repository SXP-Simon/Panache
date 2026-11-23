import 'dart:async';
import 'dart:ui' as ui;

import 'paper_exif.dart';

import 'package:flutter/foundation.dart';

import '../models/ink_page.dart';

enum _Kernel { minimum, maximum, mean }

typedef InkMask = ({Uint8List alpha, int width, int height});
typedef _ShapeJob = ({InkMask mask, double thickness, double softness});

Uint8List _pass(
  Uint8List input,
  int length,
  int stride,
  int radius,
  _Kernel mode,
) {
  final output = Uint8List(input.length);
  for (var i = 0; i < input.length; i++) {
    final position = (i ~/ stride) % length;
    var value = mode == _Kernel.minimum ? 255 : 0;
    for (var delta = -radius; delta <= radius; delta++) {
      final sample =
          input[i +
              ((position + delta).clamp(0, length - 1) - position) * stride];
      value = switch (mode) {
        _Kernel.minimum => sample < value ? sample : value,
        _Kernel.maximum => sample > value ? sample : value,
        _Kernel.mean => value + sample,
      };
    }
    output[i] = mode == _Kernel.mean
        ? (value + radius) ~/ (2 * radius + 1)
        : value;
  }
  return output;
}

// Interpolate masks at neighboring integer radii like the export engine.
Uint8List shapeInkAlpha(InkMask source, double thickness, double softness) {
  final (alpha: alpha, width: w, height: h) = source;
  Uint8List transform(Uint8List mask, double radius, _Kernel mode) {
    Uint8List at(int whole) => whole == 0
        ? mask
        : _pass(_pass(mask, w, 1, whole, mode), h, w, whole, mode);
    final tenths = (radius * 10).round();
    final whole = tenths ~/ 10;
    final weight = tenths % 10;
    final lower = at(whole);
    if (weight == 0) return lower;
    final upper = at(whole + 1);
    final result = Uint8List(mask.length);
    for (var i = 0; i < result.length; i++) {
      result[i] = (lower[i] * (10 - weight) + upper[i] * weight + 5) ~/ 10;
    }
    return result;
  }

  var mask = alpha;
  if (thickness != 0) {
    final thin = thickness < 0;
    mask = transform(
      alpha,
      thickness.abs(),
      thin ? _Kernel.minimum : _Kernel.maximum,
    );
    if (thin) {
      for (var i = 0; i < mask.length; i++) {
        mask[i] = (mask[i] * 7 + alpha[i] * 3 + 5) ~/ 10;
      }
    }
  }
  if (softness != 0) mask = transform(mask, softness, _Kernel.mean);
  return mask;
}

Uint8List _shape(_ShapeJob job) {
  final mask = shapeInkAlpha(job.mask, job.thickness, job.softness);
  final rgba = Uint8List(mask.length * 4);
  for (var i = 0; i < mask.length; i++) {
    rgba[i * 4 + 3] = mask[i];
  }
  return rgba;
}

Future<ui.Image> decodeInkImage(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}

Future<InkMask> decodeInkMask(Uint8List bytes) async {
  final image = await decodeInkImage(bytes);
  try {
    final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final alpha = Uint8List(image.width * image.height);
    for (var i = 0; i < alpha.length; i++) {
      alpha[i] = data.getUint8(i * 4 + 3);
    }
    return (alpha: alpha, width: image.width, height: image.height);
  } finally {
    image.dispose();
  }
}

Future<ui.Image> shapeInk(InkMask source, InkLook look) async {
  final bytes = await compute(_shape, (
    mask: source,
    thickness: look.thickness,
    softness: look.softness,
  ));
  final result = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    bytes,
    source.width,
    source.height,
    ui.PixelFormat.rgba8888,
    result.complete,
  );
  return result.future;
}

Future<Uint8List> compositeInkPage(InkPage page, InkLook look) async {
  final paper = await decodeInkImage(page.paper);
  try {
    final ink = await shapeInk(await decodeInkMask(page.ink!), look);
    try {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawImage(paper, ui.Offset.zero, ui.Paint());
      canvas.drawImage(
        ink,
        ui.Offset.zero,
        ui.Paint()
          ..colorFilter = ui.ColorFilter.mode(
            composeInkColor(look),
            ui.BlendMode.srcIn,
          ),
      );
      final picture = recorder.endRecording();
      try {
        final rendered = await picture.toImage(paper.width, paper.height);
        try {
          final png = (await rendered.toByteData(
            format: ui.ImageByteFormat.png,
          ))!;
          return withPaperExif(Uint8List.sublistView(png), page.cameraExif);
        } finally {
          rendered.dispose();
        }
      } finally {
        picture.dispose();
      }
    } finally {
      ink.dispose();
    }
  } finally {
    paper.dispose();
  }
}
