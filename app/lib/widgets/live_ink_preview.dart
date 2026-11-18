import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/ink_page.dart';
import '../utils/ink_effects.dart';

class LiveInkPreview extends StatefulWidget {
  const LiveInkPreview({
    super.key,
    required this.page,
    required this.look,
    required this.label,
  });
  final InkPage page;
  final InkLook look;
  final String label;

  @override
  State<LiveInkPreview> createState() => _LiveInkPreviewState();
}

class _LiveInkPreviewState extends State<LiveInkPreview> {
  InkMask? _source;
  ui.Image? _mask;
  bool _busy = false, _pending = false;

  @override
  void initState() {
    super.initState();
    unawaited(_render());
  }

  @override
  void didUpdateWidget(LiveInkPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.look.thickness != widget.look.thickness ||
        oldWidget.look.softness != widget.look.softness) {
      unawaited(_render());
    }
  }

  Future<void> _render() async {
    if (_busy) {
      _pending = true;
      return;
    }
    _busy = true;
    final look = widget.look;
    try {
      final mask = look.thickness == 0 && look.softness == 0
          ? await decodeInkImage(widget.page.ink!)
          : await shapeInk(
              _source ??= await decodeInkMask(widget.page.ink!),
              look,
            );
      if (!mounted) {
        mask.dispose();
        return;
      }
      final old = _mask;
      setState(() => _mask = mask);
      old?.dispose();
    } catch (error) {
      debugPrint('Unable to show ink layer: $error');
    } finally {
      _busy = false;
      if (mounted && _pending) {
        _pending = false;
        unawaited(_render());
      }
    }
  }

  @override
  void dispose() {
    _mask?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Image.memory(
        widget.page.paper,
        fit: BoxFit.contain,
        semanticLabel: widget.label,
      ),
      if (_mask case final mask?)
        Positioned.fill(
          child: RawImage(
            image: mask,
            fit: BoxFit.contain,
            color: composeInkColor(widget.look),
            colorBlendMode: BlendMode.srcIn,
          ),
        ),
    ],
  );
}
