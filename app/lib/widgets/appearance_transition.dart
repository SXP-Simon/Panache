import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'workbench_motion.dart';

/// Changes the live theme once. Only the previous painted frame fades, so text
/// fields, navigation, and accessibility keep targeting the live workbench.
class AppearanceTransition extends StatefulWidget {
  const AppearanceTransition({
    super.key,
    required this.appearance,
    required this.reduceMotion,
    required this.child,
  });

  final (Brightness, Color, Color) appearance;
  final bool reduceMotion;
  final Widget child;

  @override
  State<AppearanceTransition> createState() => _AppearanceTransitionState();
}

class _AppearanceTransitionState extends State<AppearanceTransition>
    with SingleTickerProviderStateMixin {
  final scene = GlobalKey();
  late final clock =
      AnimationController(vsync: this, duration: WorkbenchMotion.pane)
        ..addStatusListener((status) {
          if (status == AnimationStatus.completed && previous != null) {
            setState(clearFrame);
          }
        });
  late final opacity = clock
      .drive(CurveTween(curve: WorkbenchMotion.enter))
      .drive(Tween<double>(begin: 1, end: 0));
  ui.Image? previous;
  Size? capturedSize;

  void clearFrame() {
    previous?.dispose();
    previous = null;
    capturedSize = null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final size = MediaQuery.sizeOf(context);
    final ratio = MediaQuery.devicePixelRatioOf(context);
    if (previous != null && capturedSize != size * ratio) {
      clock.stop();
      clearFrame();
    }
  }

  @override
  void didUpdateWidget(AppearanceTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    final view = View.of(context);
    if (widget.reduceMotion) {
      clock.stop();
      clearFrame();
      return;
    }
    if (oldWidget.appearance == widget.appearance) return;
    final boundary = scene.currentContext?.findRenderObject() as _PaintedScene?;
    if (boundary == null || !boundary.hasSize || boundary.size.isEmpty) return;
    // Read the last *painted* frame, including an interrupted cross-fade.
    // Four megapixels bound the temporary texture on very large displays.
    final scale = math.min(
      view.devicePixelRatio,
      math.sqrt(4000000 / (boundary.size.width * boundary.size.height)),
    );
    try {
      final image = boundary.capture(scale);
      if (image == null) return;
      clearFrame();
      previous = image;
      capturedSize = view.physicalSize;
      clock.forward(from: 0);
    } on UnsupportedError {
      clock.stop();
      clearFrame();
    }
  }

  @override
  Widget build(BuildContext context) => _SceneBoundary(
    key: scene,
    child: Stack(
      alignment: Alignment.topLeft,
      fit: StackFit.expand,
      children: [
        RepaintBoundary(child: widget.child),
        if (previous case final image?)
          IgnorePointer(
            child: ExcludeSemantics(
              child: FadeTransition(
                opacity: opacity,
                child: RawImage(image: image, fit: BoxFit.fill),
              ),
            ),
          ),
      ],
    ),
  );

  @override
  void dispose() {
    clock.dispose();
    clearFrame();
    super.dispose();
  }
}

class _SceneBoundary extends SingleChildRenderObjectWidget {
  const _SceneBoundary({super.key, required super.child});

  @override
  _PaintedScene createRenderObject(BuildContext context) => _PaintedScene();
}

class _PaintedScene extends RenderRepaintBoundary {
  ui.Image? capture(double scale) {
    final painted = layer;
    if (painted is! OffsetLayer || !painted.attached) return null;
    return painted.toImageSync(Offset.zero & size, pixelRatio: scale);
  }
}
