import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../services/image_clipboard.dart';
import 'preview_image_actions.dart';
import 'workbench_motion.dart';

/// A controlled image viewer. Page intent is reported without waiting for motion;
/// drag progress, zoom and animation lifetimes never enter the workspace model.
class PreviewPager extends StatefulWidget {
  const PreviewPager({
    super.key,
    required this.pages,
    required this.page,
    required this.heroOwner,
    required this.onPageChanged,
    this.onOpen,
    this.copyImage = copyPreviewImage,
    this.readerMode = false,
  }) : assert(pages.length > 0);

  final List<Uint8List> pages;
  final int page;
  final Object heroOwner;
  final ValueChanged<int> onPageChanged;
  final VoidCallback? onOpen;
  final ImageClipboardWriter copyImage;
  final bool readerMode;

  @override
  State<PreviewPager> createState() => _PreviewPagerState();
}

class _PreviewPagerState extends State<PreviewPager> {
  int get _selected => widget.page.clamp(0, widget.pages.length - 1);
  late int _visible = _selected;
  late final _pager = PageController(initialPage: _selected);
  int? _target;
  int _navigation = 0;
  bool _zoomed = false;
  int _resetZoom = 0;
  final _contacts = <int>{};
  bool _multiTouch = false;

  void _releasePointer(PointerEvent event) {
    _contacts.remove(event.pointer);
    if (_contacts.isEmpty && _multiTouch) {
      setState(() => _multiTouch = false);
    }
  }

  @override
  void didUpdateWidget(PreviewPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.pages, widget.pages)) {
      _target = null;
      ++_navigation;
      _visible = _selected;
      _zoomed = false;
      ++_resetZoom;
      _move(animate: false);
    } else if (oldWidget.page != widget.page) {
      // A controlled echo must not start an animation under a held finger.
      if (_selected == _visible && _target == null) return;
      _zoomed = false;
      ++_resetZoom;
      _move(animate: true);
    }
  }

  void _move({required bool animate}) {
    final ticket = ++_navigation;
    final destination = _selected;
    _target = destination;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || ticket != _navigation || !_pager.hasClients) return;
      if (!animate ||
          MediaQuery.disableAnimationsOf(context) ||
          !TickerMode.valuesOf(context).enabled) {
        _pager.jumpToPage(destination);
      } else {
        await _pager.animateToPage(
          destination,
          duration: WorkbenchMotion.page,
          curve: Curves.easeOutCubic,
        );
      }
      if (mounted && ticket == _navigation) _target = null;
    });
  }

  void _pageChanged(int index) {
    setState(() {
      _visible = index;
      _zoomed = false;
    });
    if (_target == null && index != _selected) widget.onPageChanged(index);
  }

  @override
  void dispose() {
    ++_navigation;
    _pager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Column(
      children: [
        Expanded(
          child: Listener(
            onPointerDown: (event) {
              _contacts.add(event.pointer);
              if (_contacts.length > 1 && !_multiTouch) {
                setState(() => _multiTouch = true);
              }
            },
            onPointerUp: _releasePointer,
            onPointerCancel: _releasePointer,
            child: NotificationListener<ScrollStartNotification>(
              onNotification: (notification) {
                if (notification.depth == 0 &&
                    notification.dragDetails != null) {
                  ++_navigation;
                  _target = null;
                }
                return false;
              },
              child: PageView.builder(
                key: const ValueKey('preview-pager'),
                controller: _pager,
                physics: _zoomed || _multiTouch
                    ? const NeverScrollableScrollPhysics()
                    : null,
                onPageChanged: _pageChanged,
                itemCount: widget.pages.length,
                itemBuilder: (context, index) => _ZoomablePage(
                  key: ValueKey((index, widget.pages[index])),
                  bytes: widget.pages[index],
                  heroTag: (widget.heroOwner, index, widget.pages[index]),
                  active: index == _visible,
                  reset: _resetZoom,
                  onOpen: widget.onOpen,
                  copyImage: widget.copyImage,
                  readerMode: widget.readerMode,
                  onZoomChanged: (zoomed) {
                    if (index == _visible && _zoomed != zoomed) {
                      setState(() => _zoomed = zoomed);
                    }
                  },
                ),
              ),
            ),
          ),
        ),
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton.icon(
              key: const ValueKey('preview-previous'),
              onPressed: _selected > 0
                  ? () => widget.onPageChanged(_selected - 1)
                  : null,
              icon: const Icon(Icons.chevron_left),
              label: Text(l.previousPage),
            ),
            Text('${_selected + 1} / ${widget.pages.length}'),
            TextButton.icon(
              key: const ValueKey('preview-next'),
              onPressed: _selected < widget.pages.length - 1
                  ? () => widget.onPageChanged(_selected + 1)
                  : null,
              icon: const Icon(Icons.chevron_right),
              label: Text(l.nextPage),
            ),
            if (_zoomed && !widget.readerMode)
              TextButton.icon(
                key: const ValueKey('preview-reset-zoom'),
                onPressed: () => setState(() {
                  _zoomed = false;
                  ++_resetZoom;
                }),
                icon: const Icon(Icons.fit_screen_outlined),
                label: Text(l.resetPreviewZoom),
              ),
          ],
        ),
      ],
    );
  }
}

class _ZoomablePage extends StatefulWidget {
  const _ZoomablePage({
    super.key,
    required this.bytes,
    required this.heroTag,
    required this.active,
    required this.reset,
    required this.onZoomChanged,
    required this.onOpen,
    required this.copyImage,
    required this.readerMode,
  });
  final Uint8List bytes;
  final Object heroTag;
  final bool active;
  final int reset;
  final ValueChanged<bool> onZoomChanged;
  final VoidCallback? onOpen;
  final ImageClipboardWriter copyImage;
  final bool readerMode;

  @override
  State<_ZoomablePage> createState() => _ZoomablePageState();
}

class _ZoomablePageState extends State<_ZoomablePage>
    with SingleTickerProviderStateMixin {
  late final _transform = TransformationController()..addListener(_changed);
  late final _animation = AnimationController(
    vsync: this,
    duration: WorkbenchMotion.page,
  )..addListener(_animate);
  Matrix4Tween? _tween;
  bool _zoomed = false;
  bool _mouse = false;
  bool _dragging = false;
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

  void _changed() {
    final zoomed = widget.readerMode
        ? (_scale - 1).abs() > .001 ||
              _transform.value.getTranslation().length > .1
        : _scale > 1.01;
    final changed = zoomed != _zoomed;
    if (!changed && !widget.readerMode) return;
    setState(() => _zoomed = zoomed);
    if (changed && widget.active) widget.onZoomChanged(zoomed);
  }

  @override
  void didUpdateWidget(_ZoomablePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reset != widget.reset || oldWidget.active && !widget.active) {
      // Parent already clears its zoom flag; do not notify during its build.
      _animation.stop();
      _transform.removeListener(_changed);
      _transform.value = Matrix4.identity();
      _zoomed = false;
      _transform.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final viewer = RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            _viewport = constraints.biggest;
            return MouseRegion(
              cursor: widget.readerMode
                  ? (_dragging
                        ? SystemMouseCursors.grabbing
                        : SystemMouseCursors.grab)
                  : MouseCursor.defer,
              child: Listener(
                onPointerDown: (event) {
                  _animation.stop();
                  if (widget.readerMode) {
                    setState(() {
                      _mouse = event.kind == PointerDeviceKind.mouse;
                      _dragging =
                          _mouse && event.buttons == kPrimaryMouseButton;
                    });
                  }
                },
                onPointerUp: (_) {
                  if (_dragging) setState(() => _dragging = false);
                },
                onPointerMove: (event) {
                  if (!_dragging || event.buttons != kPrimaryMouseButton) {
                    return;
                  }
                  // Mouse panning follows every delta, including a short drag
                  // that would otherwise only cross the scale gesture slop.
                  final matrix = _transform.value.clone();
                  matrix.setEntry(
                    0,
                    3,
                    matrix.entry(0, 3) + event.localDelta.dx,
                  );
                  matrix.setEntry(
                    1,
                    3,
                    matrix.entry(1, 3) + event.localDelta.dy,
                  );
                  _transform.value = matrix;
                },
                onPointerCancel: (_) {
                  if (_dragging) setState(() => _dragging = false);
                },
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
                    onInteractionStart: (_) => _animation.stop(),
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
                          child: PreviewImageActions(
                            bytes: widget.bytes,
                            onOpen: widget.onOpen,
                            copyImage: widget.copyImage,
                            child: Semantics(
                              identifier: widget.active
                                  ? 'preview-image'
                                  : null,
                              child: Image.memory(
                                widget.bytes,
                                fit: BoxFit.contain,
                                gaplessPlayback: true,
                                semanticLabel: l.preview,
                              ),
                            ),
                          ),
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
    if (!widget.readerMode) return viewer;
    return Column(
      children: [
        Expanded(child: viewer),
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton.icon(
              key: const ValueKey('reader-zoom-out'),
              onPressed: _scale > _minScale + .001
                  ? () => _zoomTo(_scale / 1.5, _viewport.center(Offset.zero))
                  : null,
              icon: const Icon(Icons.zoom_out),
              label: Text(l.previewZoomOut),
            ),
            Tooltip(
              message: l.previewZoomRatioHint,
              child: Text(
                '${(_scale * 100).round()}%',
                key: const ValueKey('reader-zoom-ratio'),
              ),
            ),
            TextButton.icon(
              key: const ValueKey('reader-zoom-in'),
              onPressed: _scale < _maxScale - .001
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

Future<void> showFullscreenPreview(
  BuildContext context, {
  required List<Uint8List> pages,
  required int page,
  required Object heroOwner,
  required ValueChanged<int> onPageChanged,
  ImageClipboardWriter copyImage = copyPreviewImage,
}) => Navigator.of(context).push<void>(
  PageRouteBuilder<void>(
    transitionDuration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : WorkbenchMotion.page,
    reverseTransitionDuration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : WorkbenchMotion.page,
    transitionsBuilder: (_, animation, secondary, child) =>
        FadeTransition(opacity: animation, child: child),
    pageBuilder: (_, animation, secondary) => _FullscreenPreview(
      pages: pages,
      initialPage: page,
      heroOwner: heroOwner,
      onPageChanged: onPageChanged,
      copyImage: copyImage,
    ),
  ),
);

class _FullscreenPreview extends StatefulWidget {
  const _FullscreenPreview({
    required this.pages,
    required this.initialPage,
    required this.heroOwner,
    required this.onPageChanged,
    required this.copyImage,
  });
  final List<Uint8List> pages;
  final int initialPage;
  final Object heroOwner;
  final ValueChanged<int> onPageChanged;
  final ImageClipboardWriter copyImage;

  @override
  State<_FullscreenPreview> createState() => _FullscreenPreviewState();
}

class _FullscreenPreviewState extends State<_FullscreenPreview> {
  late int _page = widget.initialPage;

  @override
  Widget build(BuildContext context) => Scaffold(
    key: const ValueKey('fullscreen-preview'),
    appBar: AppBar(title: Text(AppLocalizations.of(context)!.previewTitle)),
    body: CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(),
      },
      child: Focus(
        autofocus: true,
        child: SafeArea(
          child: PreviewPager(
            readerMode: true,
            pages: widget.pages,
            page: _page,
            heroOwner: widget.heroOwner,
            copyImage: widget.copyImage,
            onPageChanged: (page) {
              setState(() => _page = page);
              widget.onPageChanged(page);
            },
          ),
        ),
      ),
    ),
  );
}
