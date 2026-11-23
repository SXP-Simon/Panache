import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

import '../l10n/app_localizations.dart';
import '../models/fine_edit.dart';
import '../models/ink_page.dart';
import '../utils/ink_effects.dart';
import 'fine_preview.dart';
import 'live_ink_preview.dart';
import 'preview_image_actions.dart';
import 'preview_zoom.dart';
import 'workbench_motion.dart';

class ZoomablePreviewPage extends StatefulWidget {
  const ZoomablePreviewPage({
    super.key,
    required this.bytes,
    required this.heroTag,
    required this.active,
    required this.reset,
    required this.onZoomChanged,
    required this.onOpen,
    required this.copyImage,
    required this.readerMode,
    required this.ink,
    required this.look,
    required this.fineEdits,
    required this.enlargeInitially,
  });
  final Uint8List bytes;
  final Object heroTag;
  final bool active;
  final int reset;
  final ValueChanged<bool> onZoomChanged;
  final VoidCallback? onOpen;
  final ImageClipboardWriter copyImage;
  final bool readerMode;
  final InkPage? ink;
  final InkLook look;
  final Map<int, FineAdjustment> fineEdits;
  final bool enlargeInitially;

  @override
  State<ZoomablePreviewPage> createState() => _ZoomablePageState();
}

class _ZoomablePageState extends State<ZoomablePreviewPage>
    with SingleTickerProviderStateMixin {
  late final _transform = TransformationController()..addListener(_changed);
  late final _animation = AnimationController(
    vsync: this,
    duration: WorkbenchMotion.page,
  )..addListener(_animate);
  // Translation events leave the reader scale controls unchanged.
  final _readerControls = ValueNotifier((100, true, true));
  Matrix4Tween? _tween;
  bool _zoomed = false;
  bool _dragging = false;
  bool _manualZoom = false;
  Size? _defaultZoomViewport;
  Offset _doubleTapPoint = Offset.zero;
  Size _viewport = Size.zero;
  double get _scale => _transform.value.getMaxScaleOnAxis();
  double get _minScale => widget.readerMode ? .25 : 1;
  double get _maxScale => widget.readerMode ? 8 : 5;

  void _animate() {
    _transform.value = _tween!.transform(
      Curves.easeOutCubic.transform(_animation.value),
    );
  }

  void _to(Matrix4 destination) {
    _animation.stop();
    if (MediaQuery.disableAnimationsOf(context)) {
      _transform.value = destination;
    } else {
      _tween = Matrix4Tween(begin: _transform.value.clone(), end: destination);
      _animation.forward(from: 0);
    }
  }

  void _zoomTo(double scale, Offset focalPoint) {
    final target = scale.clamp(_minScale, _maxScale);
    final scene = _transform.toScene(focalPoint);
    _to(
      Matrix4.identity()
        ..translateByDouble(
          focalPoint.dx - scene.dx * target,
          focalPoint.dy - scene.dy * target,
          0,
          1,
        )
        ..scaleByDouble(target, target, target, 1),
    );
  }

  void _reset() => _to(Matrix4.identity());

  void _updateReaderControls() {
    if (!widget.readerMode) return;
    final scale = _scale;
    _readerControls.value = (
      (scale * 100).round(),
      scale > _minScale + .001,
      scale < _maxScale - .001,
    );
  }

  void _changed() {
    _updateReaderControls();
    final zoomed = widget.readerMode
        ? (_scale - 1).abs() > .001 ||
              _transform.value.getTranslation().length > .1
        : _scale > 1.01;
    if (zoomed == _zoomed) return;
    setState(() => _zoomed = zoomed);
    if (widget.active) widget.onZoomChanged(zoomed);
  }

  @override
  void didUpdateWidget(ZoomablePreviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final layoutChanged = oldWidget.enlargeInitially != widget.enlargeInitially;
    if (layoutChanged || oldWidget.active != widget.active) {
      _defaultZoomViewport = null;
      _manualZoom = false;
    } else if (oldWidget.reset != widget.reset && widget.active) {
      _manualZoom = true;
    }
    if (layoutChanged ||
        oldWidget.reset != widget.reset ||
        oldWidget.active && !widget.active) {
      // Parent already clears its zoom flag; do not notify during its build.
      _animation.stop();
      _transform.removeListener(_changed);
      _transform.value = Matrix4.identity();
      _zoomed = false;
      _transform.addListener(_changed);
    }
    _updateReaderControls();
  }

  void _scheduleInitialZoom() {
    if (_manualZoom ||
        _viewport == _defaultZoomViewport ||
        !widget.active ||
        !widget.enlargeInitially ||
        _viewport.isEmpty) {
      return;
    }
    final size = previewPngSize(widget.bytes);
    if (size == null) return;
    _defaultZoomViewport = _viewport;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _manualZoom ||
          !widget.active ||
          !widget.enlargeInitially ||
          _viewport.isEmpty) {
        return;
      }
      final glyphs = widget.ink?.fine?.glyphs;
      var top = size.height;
      for (final glyph in glyphs ?? const <FineGlyph>[]) {
        if (glyph.y < top) top = glyph.y.toDouble();
      }
      _transform.value = initialPreviewZoom(
        _viewport,
        size,
        contentTop: top == size.height ? 0 : top,
      );
    });
  }

  @override
  void dispose() {
    _animation.dispose();
    _transform.dispose();
    _readerControls.dispose();
    super.dispose();
  }

  void _pointerDown(PointerDownEvent event) {
    _animation.stop();
    if (!widget.readerMode) return;
    setState(() {
      _dragging =
          event.kind == PointerDeviceKind.mouse &&
          event.buttons == kPrimaryMouseButton;
    });
  }

  void _pointerMove(PointerMoveEvent event) {
    if (!_dragging || event.buttons != kPrimaryMouseButton) return;
    // Apply even short mouse deltas below the scale gesture slop.
    final matrix = _transform.value.clone();
    matrix.setEntry(0, 3, matrix.entry(0, 3) + event.localDelta.dx);
    matrix.setEntry(1, 3, matrix.entry(1, 3) + event.localDelta.dy);
    _transform.value = matrix;
  }

  void _releasePointer(PointerEvent _) {
    if (_dragging) setState(() => _dragging = false);
  }

  Widget _image(AppLocalizations l) {
    final ink = widget.ink;
    final look = widget.look;
    final copy = widget.copyImage;
    if (ink?.fine != null) {
      return SizedBox.expand(
        child: FinePreview(
          page: ink!,
          look: look,
          edits: widget.fineEdits,
          copyImage: copy,
        ),
      );
    }
    return PreviewImageActions(
      bytes: widget.bytes,
      onOpen: widget.onOpen,
      copyImage: ink == null
          ? copy
          : (_) async => copy(await compositeInkPage(ink, look)),
      child: Semantics(
        identifier: widget.active ? 'preview-image' : null,
        child: ink != null
            ? LiveInkPreview(page: ink, look: look, label: l.preview)
            : Image.memory(
                widget.bytes,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                semanticLabel: l.preview,
              ),
      ),
    );
  }

  Widget _viewer(AppLocalizations l) {
    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            _viewport = constraints.biggest;
            _scheduleInitialZoom();
            return MouseRegion(
              cursor: widget.readerMode
                  ? (_dragging
                        ? SystemMouseCursors.grabbing
                        : SystemMouseCursors.grab)
                  : MouseCursor.defer,
              child: Listener(
                onPointerDown: _pointerDown,
                onPointerUp: _releasePointer,
                onPointerMove: _pointerMove,
                onPointerCancel: _releasePointer,
                child: GestureDetector(
                  onDoubleTapDown: widget.readerMode
                      ? (details) => _doubleTapPoint = details.localPosition
                      : null,
                  onDoubleTap: widget.readerMode
                      ? () => _zoomed ? _reset() : _zoomTo(2.5, _doubleTapPoint)
                      : null,
                  child: InteractiveViewer(
                    key: widget.readerMode
                        ? const ValueKey('reader-canvas')
                        : null,
                    transformationController: _transform,
                    onInteractionStart: (_) {
                      _manualZoom = true;
                      _animation.stop();
                    },
                    panEnabled: _zoomed && !_dragging,
                    boundaryMargin: widget.readerMode
                        ? const EdgeInsets.all(double.infinity)
                        : EdgeInsets.zero,
                    minScale: _minScale,
                    maxScale: _maxScale,
                    child: Center(
                      child: HeroMode(
                        enabled:
                            widget.active &&
                            !MediaQuery.disableAnimationsOf(context),
                        child: Hero(
                          tag: widget.heroTag,
                          transitionOnUserGestures: true,
                          child: _image(l),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final viewer = _viewer(l);
    if (!widget.readerMode) return viewer;
    return Column(
      children: [
        Expanded(child: viewer),
        ValueListenableBuilder(
          valueListenable: _readerControls,
          builder: (_, controls, _) => Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton.icon(
                key: const ValueKey('reader-zoom-out'),
                onPressed: controls.$2
                    ? () => _zoomTo(_scale / 1.5, _viewport.center(Offset.zero))
                    : null,
                icon: const Icon(Icons.zoom_out),
                label: Text(l.previewZoomOut),
              ),
              Tooltip(
                message: l.previewZoomRatioHint,
                child: Text(
                  '${controls.$1}%',
                  key: const ValueKey('reader-zoom-ratio'),
                ),
              ),
              TextButton.icon(
                key: const ValueKey('reader-zoom-in'),
                onPressed: controls.$3
                    ? () => _zoomTo(_scale * 1.5, _viewport.center(Offset.zero))
                    : null,
                icon: const Icon(Icons.zoom_in),
                label: Text(l.previewZoomIn),
              ),
              TextButton.icon(
                key: const ValueKey('preview-reset-zoom'),
                onPressed: _reset,
                icon: const Icon(Icons.fit_screen_outlined),
                label: Text(l.resetPreviewZoom),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text(
            l.previewReaderHint,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}
