import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../models/ink_page.dart';

enum _Kernel { minimum, maximum, mean }

typedef InkMask = ({Uint8List alpha, int width, int height});
typedef _ShapeJob = ({InkMask mask, int thickness, int softness});

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

// Same separable morphology and box blur as the export engine.
Uint8List _shape(_ShapeJob job) {
  final (alpha: alpha, width: w, height: h) = job.mask;
  Uint8List transform(Uint8List mask, int radius, _Kernel mode) =>
      _pass(_pass(mask, w, 1, radius, mode), h, w, radius, mode);
  var mask = alpha;
  if (job.thickness != 0) {
    final thin = job.thickness < 0;
    mask = transform(
      alpha,
      job.thickness.abs(),
      thin ? _Kernel.minimum : _Kernel.maximum,
    );
    if (thin) {
      for (var i = 0; i < mask.length; i++) {
        mask[i] = (mask[i] * 7 + alpha[i] * 3 + 5) ~/ 10;
      }
    }
  }
  if (job.softness != 0) mask = transform(mask, job.softness, _Kernel.mean);
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
    final ink = await shapeInk(await decodeInkMask(page.ink), look);
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
          return (await rendered.toByteData(format: ui.ImageByteFormat.png))!
              .buffer
              .asUint8List();
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
