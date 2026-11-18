import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../models/fine_edit.dart';
import '../models/ink_page.dart';
import '../utils/fine_raster.dart';
import '../view_models/fine_selection.dart';
import 'color_picker_dialog.dart';
import 'preview_image_actions.dart';
import 'preview_zoom.dart';
import 'workbench_controls.dart';

typedef FineInspector = ({
  Object owner,
  WidgetBuilder build,
  VoidCallback close,
  VoidCallback fitPage,
  bool hasSelection,
});

class FineInspectorSlot extends ValueNotifier<FineInspector?> {
  FineInspectorSlot() : super(null);

  bool _disposed = false;

  void clear(Object owner) {
    if (!_disposed && identical(value?.owner, owner)) value = null;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class FinePreview extends StatefulWidget {
  const FinePreview({
    super.key,
    required this.page,
    required this.look,
    required this.edits,
    required this.copyImage,
    this.editing = false,
    this.toolbar = false,
    this.canUndo = false,
    this.canRedo = false,
    this.onEdit,
    this.onHistory,
    this.source,
    this.onCanvasSelect,
    this.inspector,
  });

  final InkPage page;
  final InkLook look;
  final Map<int, FineAdjustment> edits;
  final ImageClipboardWriter copyImage;
  final bool editing, toolbar, canUndo, canRedo;
  final ValueChanged<List<FineAdjustment>>? onEdit;
  final ValueChanged<bool>? onHistory;
  final FineRange? source;
  final VoidCallback? onCanvasSelect;
  final FineInspectorSlot? inspector;

  @override
  State<FinePreview> createState() => _FinePreviewState();
}

typedef _Gesture = ({
  int pointer,
  Offset start,
  Offset screen,
  FineGlyph? hit,
  bool move,
  bool add,
  bool tap,
});

class _FinePreviewState extends State<FinePreview> {
  final _selection = FineSelection();
  final _focus = FocusNode();
  final _zoom = TransformationController();
  FinePage get model => widget.page.fine!;
  FineRaster? _raster;
  ui.Image? _committed;
  _Gesture? _gesture;
  Rect? _box;
  List<FineAdjustment> _draft = [];
  bool _moved = false, _painting = false, _pending = false, _failed = false;
  bool _awaitingPixels = false;
  bool _shapeDraft = false;
  bool? _zoomLayout;
  bool _manualZoom = false;
  Size? _defaultZoomViewport;
  Size _viewport = Size.zero;
  final _retired = <ui.Image>{};

  bool get _touchNavigation =>
      Theme.of(context).platform == TargetPlatform.android ||
      Theme.of(context).platform == TargetPlatform.iOS;
  bool get _compact =>
      MediaQuery.sizeOf(context).width < 900 || _touchNavigation;

  Size get _size =>
      Size(_raster!.paper.width.toDouble(), _raster!.paper.height.toDouble());
  Map<int, FineAdjustment> get _visible => _draft.isEmpty
      ? widget.edits
      : {...widget.edits, for (final value in _draft) value.id: value};

  @override
  void initState() {
    super.initState();
    _sourceSelection();
    unawaited(_paintCommitted());
  }

  @override
  void didUpdateWidget(FinePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.inspector != widget.inspector) {
      _detachInspector(oldWidget.inspector);
    }
    if (oldWidget.source != widget.source && widget.source != null) {
      _sourceSelection();
    }
    if (widget.look != oldWidget.look ||
        !mapEqualsFine(widget.edits, oldWidget.edits)) {
      _awaitingPixels = true;
      unawaited(_paintCommitted());
    }
  }

  void _sourceSelection() {
    final range = widget.source;
    if (range == null || !model.glyphs.any((glyph) => glyph.source != null)) {
      return;
    }
    _selection.select(
      model.glyphs
          .where((glyph) {
            final span = glyph.source;
            return span != null &&
                span.start < range.end &&
                span.end > range.start;
          })
          .map((glyph) => glyph.id),
    );
  }

  Future<void> _paintCommitted() async {
    if (_painting) {
      _pending = true;
      return;
    }
    _painting = true;
    final look = widget.look;
    final edits = widget.edits;
    final draft = _shapeDraft && _committed != null;
    final visible = draft ? _visible : edits;
    try {
      final raster = _raster ?? await FineRaster.decode(widget.page);
      if (!mounted) {
        raster.dispose();
        return;
      }
      _raster = raster;
      await raster.prepare(look, visible);
      if (!mounted) return;
      if (draft) {
        setState(() => _failed = false);
        return;
      }
      final image = await raster.render(edits, look);
      if (!mounted) {
        image.dispose();
        return;
      }
      final old = _committed;
      setState(() {
        _committed = image;
        _failed = false;
        _awaitingPixels = _pending;
      });
      if (old != null) {
        _retired.add(old);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_retired.remove(old)) old.dispose();
        });
      }
    } catch (error) {
      if (mounted) setState(() => _failed = true);
    } finally {
      _painting = false;
      if (mounted && _pending) {
        _pending = false;
        unawaited(_paintCommitted());
      }
    }
  }

  @override
  void dispose() {
    _detachInspector(widget.inspector);
    _focus.dispose();
    _zoom.dispose();
    _raster?.dispose();
    _committed?.dispose();
    for (final image in _retired) {
      image.dispose();
    }
    _retired.clear();
    super.dispose();
  }

  void _detachInspector(FineInspectorSlot? slot) {
    if (slot == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      slot.clear(this);
    });
  }

  void _publishInspector() {
    final slot = widget.inspector;
    if (slot == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(widget.inspector, slot)) {
        slot.value = (
          owner: this,
          build: (context) => _sideInspector(context),
          close: _clearSelection,
          fitPage: _fitPage,
          hasSelection: _selection.selected.isNotEmpty,
        );
      }
    });
  }

  Widget _sideInspector(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return WorkbenchPanel(
      title: l.fineEdit,
      icon: Icons.select_all,
      actions: [
        IconButton(
          tooltip: l.close,
          onPressed: _clearSelection,
          icon: const Icon(Icons.close),
        ),
      ],
      child: LayoutBuilder(
        builder: (context, bounds) => Align(
          alignment: Alignment.topCenter,
          child: IgnorePointer(
            ignoring: !widget.editing || _committed == null,
            child: _inspector(context, bounds.maxHeight, sidebar: true),
          ),
        ),
      ),
    );
  }

  void _down(PointerDownEvent event, double fit) {
    if (!widget.editing ||
        _selection.tool == FineTool.pan ||
        _gesture != null ||
        event.buttons != kPrimaryButton) {
      return;
    }
    final touch =
        event.kind == PointerDeviceKind.touch ||
        event.kind == PointerDeviceKind.stylus;
    final at = event.localPosition / fit;
    final hit = _selection.hit(model, widget.edits, at);
    final add = !touch && HardwareKeyboard.instance.isShiftPressed;
    final group = _selection.bounds(model, widget.edits);
    final selected =
        group != null &&
        group.contains(at) &&
        (hit == null || _selection.selected.contains(hit.id));
    final move = touch
        ? _selection.tool == FineTool.move
        : !add && (selected || hit != null);
    _gesture = (
      pointer: event.pointer,
      start: at,
      screen: event.position,
      hit: hit,
      move: move,
      add: add,
      tap: touch && _selection.tool == FineTool.select,
    );
    _moved = false;
    _focus.requestFocus();
  }

  void _move(PointerMoveEvent event, double fit) {
    final gesture = _gesture;
    if (gesture == null ||
        gesture.pointer != event.pointer ||
        (!_moved && (event.position - gesture.screen).distance < 4)) {
      return;
    }
    if (!_moved &&
        gesture.move &&
        gesture.hit != null &&
        !_selection.selected.contains(gesture.hit!.id) &&
        event.kind == PointerDeviceKind.mouse) {
      _selection.select([gesture.hit!.id]);
      widget.onCanvasSelect?.call();
    }
    _moved = true;
    if (gesture.tap) return;
    final point = event.localPosition / fit;
    setState(() {
      if (gesture.move) {
        _draft = _selection.move(
          model,
          widget.edits,
          point - gesture.start,
          _size,
          snapToLine: !HardwareKeyboard.instance.isAltPressed,
        );
      } else {
        _box = Rect.fromPoints(gesture.start, point);
      }
    });
  }

  void _up(PointerUpEvent event, double fit) {
    final gesture = _gesture;
    if (gesture == null || gesture.pointer != event.pointer) return;
    final point = event.localPosition / fit;
    if (!_moved) {
      if (event.kind == PointerDeviceKind.mouse || !gesture.move) {
        _selection.select([
          if (gesture.hit case final glyph?) glyph.id,
        ], append: gesture.add);
        widget.onCanvasSelect?.call();
      }
    } else if (!gesture.tap) {
      if (gesture.move) {
        _finish(
          _selection.move(
            model,
            widget.edits,
            point - gesture.start,
            _size,
            snapToLine: !HardwareKeyboard.instance.isAltPressed,
          ),
        );
      } else {
        _selection.box(
          model,
          widget.edits,
          Rect.fromPoints(gesture.start, point),
          append: gesture.add,
        );
        widget.onCanvasSelect?.call();
      }
    }
    _cancelGesture();
  }

  void _cancelGesture() => setState(() {
    _gesture = null;
    _box = null;
    _draft = [];
  });

  void _clearSelection() {
    _selection.select([]);
    widget.onCanvasSelect?.call();
    _cancelGesture();
  }

  void _fitPage() {
    _manualZoom = true;
    _zoom.value = Matrix4.identity();
  }

  void _finish(List<FineAdjustment> values) {
    if (values.isNotEmpty) widget.onEdit?.call(values);
  }

  void _adjust({
    int? scale,
    int? angle,
    int? opacity,
    int? color,
    int? thickness,
    int? softness,
  }) {
    final changesShape = thickness != null || softness != null;
    setState(() {
      _shapeDraft = changesShape;
      _draft = _selection.change(
        widget.edits,
        (v) => (
          id: v.id,
          dx: v.dx,
          dy: v.dy,
          scale: scale ?? v.scale,
          angle: angle ?? v.angle,
          opacity: opacity ?? v.opacity,
          color: color ?? v.color,
          thickness: thickness ?? v.thickness,
          softness: softness ?? v.softness,
        ),
      );
    });
    if (changesShape) unawaited(_paintCommitted());
  }

  void _commitDraft() {
    final wasShaping = _shapeDraft;
    _finish(_draft);
    setState(() {
      _draft = [];
      _shapeDraft = false;
    });
    if (wasShaping) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_paintCommitted());
      });
    }
  }

  void _nudge(Offset by) => _finish(
    _selection.move(model, widget.edits, by, _size, snapToLine: false),
  );

  KeyEventResult _key(FocusNode _, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    if ((keyboard.isControlPressed || keyboard.isMetaPressed) &&
        [LogicalKeyboardKey.keyZ, LogicalKeyboardKey.keyY].contains(key)) {
      widget.onHistory?.call(
        key == LogicalKeyboardKey.keyY || keyboard.isShiftPressed,
      );
    } else if (key == LogicalKeyboardKey.escape) {
      _clearSelection();
    } else if (_selection.selected.isNotEmpty) {
      final shift = switch (key) {
        LogicalKeyboardKey.arrowLeft => const Offset(-1, 0),
        LogicalKeyboardKey.arrowRight => const Offset(1, 0),
        LogicalKeyboardKey.arrowUp => const Offset(0, -1),
        LogicalKeyboardKey.arrowDown => const Offset(0, 1),
        _ => null,
      };
      if (shift == null) return KeyEventResult.ignored;
      _nudge(shift * (keyboard.isShiftPressed ? 10 : 1));
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Future<void> _pickColor(FineAdjustment current) async {
    final l = AppLocalizations.of(context)!;
    final color = await showDialog<Color>(
      context: context,
      builder: (_) => ColorPickerDialog(
        id: 'fine-color',
        title: l.fineColor,
        color: Color(current.color ?? widget.look.color),
        presets: [
          (l.black, Colors.black),
          (l.blue, const Color(0xff003399)),
          (l.red, const Color(0xffb40000)),
        ],
        onPreview: (value) {
          if (mounted) _adjust(color: value.toARGB32());
        },
      ),
    );
    if (!mounted) return;
    if (color != null) {
      _adjust(color: color.toARGB32());
      _commitDraft();
    } else {
      setState(() => _draft = []);
    }
  }

  void _zoomBy(double factor) {
    _manualZoom = true;
    final scale = (_zoom.value.getMaxScaleOnAxis() * factor).clamp(1.0, 4.0);
    final center = _viewport.center(Offset.zero);
    final translation = center - _zoom.toScene(center) * scale;
    _zoom.value = scale == 1
        ? Matrix4.identity()
        : (Matrix4.identity()
            ..translateByDouble(translation.dx, translation.dy, 0, 1)
            ..scaleByDouble(scale, scale, 1, 1));
  }

  Widget _paper(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final raster = _raster;
    final image = _committed;
    if (_failed) return Center(child: Text(l.fineUnavailable));
    if (raster == null || image == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final color = Theme.of(context).colorScheme.primary;
    return LayoutBuilder(
      builder: (context, bounds) {
        _viewport = bounds.biggest;
        final fit = math.min(
          bounds.maxWidth / _size.width,
          bounds.maxHeight / _size.height,
        );
        if (fit <= 0 || !fit.isFinite) return const SizedBox.shrink();
        if (widget.toolbar) {
          final wide = widget.inspector != null;
          if (_zoomLayout != wide) {
            _zoomLayout = wide;
            _manualZoom = false;
            _defaultZoomViewport = null;
          }
          if (!_manualZoom &&
              (_defaultZoomViewport == null ||
                  wide && _defaultZoomViewport != _viewport)) {
            _defaultZoomViewport = _viewport;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || _zoomLayout != wide || _manualZoom) return;
              final top = model.glyphs.fold<double>(
                _size.height,
                (top, glyph) => math.min(top, glyph.y.toDouble()),
              );
              _zoom.value = wide
                  ? initialPreviewZoom(
                      _viewport,
                      _size,
                      contentTop: model.glyphs.isEmpty ? 0 : top,
                    )
                  : Matrix4.identity();
            });
          }
        }
        final surface = SizedBox.fromSize(
          size: _size * fit,
          child: PreviewImageActions(
            bytes: widget.page.paper,
            longPress: !widget.editing,
            copyImage: (_) async => widget.copyImage(
              await compositeFinePage(widget.page, widget.edits, widget.look),
            ),
            child: Listener(
              key: const ValueKey('fine-canvas'),
              behavior: HitTestBehavior.opaque,
              onPointerDown: (event) => _down(event, fit),
              onPointerMove: (event) => _move(event, fit),
              onPointerUp: (event) => _up(event, fit),
              onPointerCancel: (_) => _cancelGesture(),
              child: CustomPaint(
                painter: _FinePainter(
                  raster,
                  image,
                  widget.look,
                  _visible,
                  draft: _draft.isNotEmpty || _awaitingPixels,
                  outlines: widget.editing
                      ? {
                          for (final glyph in model.glyphs.where(
                            (glyph) => _selection.selected.contains(glyph.id),
                          ))
                            FinePose(glyph, _visible[glyph.id]).bounds,
                        }
                      : {},
                  box: _box,
                  color: color,
                ),
              ),
            ),
          ),
        );
        return widget.toolbar
            ? InteractiveViewer(
                transformationController: _zoom,
                onInteractionStart: (_) => _manualZoom = true,
                scaleEnabled:
                    _selection.tool == FineTool.select ||
                    _selection.tool == FineTool.pan,
                panEnabled:
                    (_touchNavigation && _selection.tool == FineTool.select) ||
                    _selection.tool == FineTool.pan,
                maxScale: 4,
                child: Center(child: surface),
              )
            : Center(child: surface);
      },
    );
  }

  Widget _inspector(
    BuildContext context,
    double maxHeight, {
    bool sidebar = false,
  }) {
    final l = AppLocalizations.of(context)!;
    final selection = _selection.selected;
    final first = selection.firstOrNull;
    final current = _visible[first] ?? defaultFineAdjustment(first ?? 0);
    final summary = Text(
      first == null ? l.fineHint : l.fineSelected(selection.length),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: _compact || sidebar ? TextAlign.center : TextAlign.start,
      style: Theme.of(context).textTheme.bodySmall,
    );
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: SingleChildScrollView(
                primary: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_compact || sidebar) summary,
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (!_compact && !sidebar) Flexible(child: summary),
                        Flexible(
                          child: Wrap(
                            alignment: WrapAlignment.center,
                            children: [
                              IconButton(
                                key: const ValueKey('fine-undo'),
                                tooltip: l.fineUndo,
                                onPressed: widget.canUndo
                                    ? () => widget.onHistory?.call(false)
                                    : null,
                                icon: const Icon(Icons.undo),
                              ),
                              IconButton(
                                key: const ValueKey('fine-redo'),
                                tooltip: l.fineRedo,
                                onPressed: widget.canRedo
                                    ? () => widget.onHistory?.call(true)
                                    : null,
                                icon: const Icon(Icons.redo),
                              ),
                              IconButton(
                                tooltip: l.previewZoomOut,
                                onPressed: () => _zoomBy(1 / 1.25),
                                icon: const Icon(Icons.zoom_out),
                              ),
                              IconButton(
                                tooltip: l.previewZoomIn,
                                onPressed: () => _zoomBy(1.25),
                                icon: const Icon(Icons.zoom_in),
                              ),
                              if (!_touchNavigation)
                                IconButton(
                                  isSelected: _selection.tool == FineTool.pan,
                                  tooltip: l.finePan,
                                  onPressed: () => setState(() {
                                    _selection.tool =
                                        _selection.tool == FineTool.pan
                                        ? FineTool.select
                                        : FineTool.pan;
                                  }),
                                  icon: const Icon(Icons.pan_tool_outlined),
                                  selectedIcon: const Icon(Icons.pan_tool),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (_compact)
                      SegmentedButton<FineTool>(
                        showSelectedIcon: false,
                        segments: [
                          ButtonSegment(
                            value: FineTool.select,
                            label: Text(l.fineTap),
                          ),
                          ButtonSegment(
                            value: FineTool.box,
                            label: Text(l.fineBox),
                          ),
                          ButtonSegment(
                            value: FineTool.move,
                            label: Text(l.fineMove),
                            enabled: first != null,
                          ),
                        ],
                        selected: {
                          _selection.tool == FineTool.pan
                              ? FineTool.select
                              : _selection.tool,
                        },
                        onSelectionChanged: (value) =>
                            setState(() => _selection.tool = value.first),
                      ),
                    Visibility(
                      visible: first != null,
                      maintainState: true,
                      maintainAnimation: true,
                      maintainSize: true,
                      child: Wrap(
                        spacing: 10,
                        runSpacing: 4,
                        alignment: WrapAlignment.center,
                        children: [
                          _slider(
                            'fine-scale',
                            l.fineScale,
                            current.scale,
                            50,
                            200,
                            '%',
                            (v) => _adjust(scale: v),
                          ),
                          _slider(
                            'fine-angle',
                            l.fineAngle,
                            current.angle,
                            -45,
                            45,
                            '°',
                            (v) => _adjust(angle: v),
                          ),
                          _slider(
                            'fine-opacity',
                            l.fineOpacity,
                            current.opacity,
                            0,
                            100,
                            '%',
                            (v) => _adjust(opacity: v),
                          ),
                          _slider(
                            'fine-thickness',
                            l.fineThickness,
                            current.thickness,
                            math
                                .min(
                                  current.thickness,
                                  -20 - (widget.look.thickness * 10).round(),
                                )
                                .clamp(-20, 0),
                            math
                                .max(
                                  current.thickness,
                                  20 - (widget.look.thickness * 10).round(),
                                )
                                .clamp(0, 20),
                            ' px',
                            (v) => _adjust(thickness: v),
                            delta: true,
                          ),
                          _slider(
                            'fine-softness',
                            l.fineSoftness,
                            current.softness,
                            math.min(
                              current.softness,
                              -(widget.look.softness * 10).round(),
                            ),
                            math.max(
                              current.softness,
                              20 - (widget.look.softness * 10).round(),
                            ),
                            ' px',
                            (v) => _adjust(softness: v),
                            delta: true,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Visibility(
              visible: first != null,
              maintainState: true,
              maintainAnimation: true,
              maintainSize: true,
              child: Wrap(
                spacing: 4,
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TextButton.icon(
                    key: const ValueKey('fine-color'),
                    onPressed: () => _pickColor(current),
                    icon: ColorSwatchIndicator(
                      Color(current.color ?? widget.look.color),
                    ),
                    label: Text(l.fineColor),
                  ),
                  FilterChip(
                    label: Text(l.fineSnap),
                    selected: _selection.snap,
                    onSelected: (value) =>
                        setState(() => _selection.snap = value),
                  ),
                  TextButton.icon(
                    key: const ValueKey('fine-reset'),
                    label: Text(l.fineReset),
                    icon: const Icon(Icons.restart_alt),
                    onPressed: () =>
                        _finish(selection.map(defaultFineAdjustment).toList()),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _slider(
    String key,
    String label,
    int value,
    int min,
    int max,
    String unit,
    ValueChanged<int> change, {
    bool delta = false,
  }) {
    final display = delta
        ? '${value > 0 ? '+' : ''}${(value / 10).toStringAsFixed(1)}$unit'
        : '$value$unit';
    return SizedBox(
      width: 107,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, textAlign: TextAlign.center),
          Text(display, softWrap: false),
          Slider(
            key: ValueKey(key),
            value: value.toDouble(),
            min: min.toDouble(),
            max: max.toDouble(),
            divisions: max - min,
            label: display,
            onChanged: (v) => change(v.round()),
            onChangeEnd: (_) => _commitDraft(),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _publishInspector();
    if (!widget.toolbar) return _paper(context);
    return Focus(
      focusNode: _focus,
      onKeyEvent: _key,
      child: LayoutBuilder(
        builder: (context, bounds) => Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: _paper(context),
              ),
            ),
            if (widget.inspector == null &&
                widget.editing &&
                _committed != null)
              _inspector(context, bounds.maxHeight * .6),
          ],
        ),
      ),
    );
  }
}

bool mapEqualsFine(Map<int, FineAdjustment> a, Map<int, FineAdjustment> b) =>
    identical(a, b) ||
    a.length == b.length &&
        a.entries.every((entry) => entry.value == b[entry.key]);

class _FinePainter extends CustomPainter {
  _FinePainter(
    this.raster,
    this.image,
    this.look,
    this.edits, {
    required this.draft,
    required this.outlines,
    required this.box,
    required this.color,
  });
  final FineRaster raster;
  final ui.Image image;
  final InkLook look;
  final Map<int, FineAdjustment> edits;
  final bool draft;
  final Set<Rect> outlines;
  final Rect? box;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    final fit = size.width / image.width;
    canvas.scale(fit);
    if (draft) {
      raster.paint(canvas, edits, look);
    } else {
      canvas.drawImage(
        image,
        Offset.zero,
        Paint()..filterQuality = FilterQuality.low,
      );
    }
    final fill = Paint()..color = color.withValues(alpha: .14);
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1 / fit;
    for (final rect in [...outlines, ?box]) {
      canvas.drawRect(rect, fill);
      canvas.drawRect(rect, line);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _FinePainter oldDelegate) => true;
}
