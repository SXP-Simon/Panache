import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../models/ink_page.dart';
import '../models/fine_edit.dart';
import '../services/image_clipboard.dart';
import 'preview_image_actions.dart';
import 'workbench_motion.dart';
import 'zoomable_preview_page.dart';

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
    this.inkPages = const [],
    this.inkLook = defaultInkLook,
    this.fineEdits = const [],
    this.enlargeInitially = false,
  }) : assert(pages.length > 0);

  final List<Uint8List> pages;
  final int page;
  final Object heroOwner;
  final ValueChanged<int> onPageChanged;
  final VoidCallback? onOpen;
  final ImageClipboardWriter copyImage;
  final bool readerMode;
  final List<InkPage?> inkPages;
  final InkLook inkLook;
  final List<Map<int, FineAdjustment>> fineEdits;
  final bool enlargeInitially;

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
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = MediaQuery.disableAnimationsOf(context);
    if (reduced && _target != null) _move(animate: false);
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
          curve: WorkbenchMotion.enter,
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
                itemBuilder: (context, index) => ZoomablePreviewPage(
                  key: ValueKey((index, widget.pages[index])),
                  bytes: widget.pages[index],
                  ink: index < widget.inkPages.length
                      ? widget.inkPages[index]
                      : null,
                  look: widget.inkLook,
                  fineEdits:
                      widget.fineEdits.elementAtOrNull(index) ?? const {},
                  heroTag: (widget.heroOwner, index, widget.pages[index]),
                  active: index == _visible,
                  reset: _resetZoom,
                  onOpen: widget.onOpen,
                  copyImage: widget.copyImage,
                  readerMode: widget.readerMode,
                  enlargeInitially:
                      widget.enlargeInitially && !widget.readerMode,
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
            _PageNumber(
              page: _selected,
              count: widget.pages.length,
              pager: _pager,
            ),
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

/// Roll the counter directly from the physical page position, including drags.
class _PageNumber extends StatelessWidget {
  const _PageNumber({
    required this.page,
    required this.count,
    required this.pager,
  });
  final PageController pager;
  final int page, count;

  @override
  Widget build(BuildContext context) {
    final label = '${page + 1} / $count';
    if (MediaQuery.disableAnimationsOf(context)) return Text(label);
    return Semantics(
      label: label,
      child: ExcludeSemantics(
        child: ClipRect(
          child: ListenableBuilder(
            listenable: pager,
            builder: (_, _) {
              final position =
                  (pager.hasClients && pager.position.hasContentDimensions
                          ? pager.page ?? page.toDouble()
                          : page.toDouble())
                      .clamp(0.0, count - 1.0);
              final first = position.floor().clamp(0, count - 1);
              final fraction = position - first;
              return Stack(
                alignment: Alignment.center,
                children: [
                  FractionalTranslation(
                    translation: Offset(0, -fraction),
                    child: Text('${first + 1} / $count'),
                  ),
                  if (fraction > 0 && first + 1 < count)
                    FractionalTranslation(
                      translation: Offset(0, 1 - fraction),
                      child: Text('${first + 2} / $count'),
                    ),
                ],
              );
            },
          ),
        ),
      ),
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
  List<InkPage?> inkPages = const [],
  InkLook inkLook = defaultInkLook,
  List<Map<int, FineAdjustment>> fineEdits = const [],
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
      inkPages: inkPages,
      inkLook: inkLook,
      fineEdits: fineEdits,
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
    required this.inkPages,
    required this.inkLook,
    required this.fineEdits,
  });
  final List<Uint8List> pages;
  final int initialPage;
  final Object heroOwner;
  final ValueChanged<int> onPageChanged;
  final ImageClipboardWriter copyImage;
  final List<InkPage?> inkPages;
  final InkLook inkLook;
  final List<Map<int, FineAdjustment>> fineEdits;

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
            inkPages: widget.inkPages,
            inkLook: widget.inkLook,
            fineEdits: widget.fineEdits,
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
