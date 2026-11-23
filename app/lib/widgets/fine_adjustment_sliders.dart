import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/fine_edit.dart';
import '../models/ink_page.dart';

class FineAdjustmentSliders extends StatelessWidget {
  const FineAdjustmentSliders({
    super.key,
    required this.current,
    required this.selectionCount,
    required this.baseLook,
    required this.transformDraft,
    required this.onAdjust,
    required this.onTransform,
    required this.onCommit,
  });
  final FineAdjustment current;
  final int selectionCount;
  final InkLook baseLook;
  final ({String field, int value})? transformDraft;
  final void Function({
    int? scale,
    int? angle,
    int? opacity,
    int? thickness,
    int? softness,
  })
  onAdjust;
  final void Function(String field, int value) onTransform;
  final VoidCallback onCommit;

  int _transformValue(String field) =>
      transformDraft?.field == field ? transformDraft!.value : 0;

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
            onChangeEnd: (_) => onCommit(),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Wrap(
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
          (v) => onAdjust(scale: v),
        ),
        if (selectionCount == 1)
          _slider(
            'fine-angle',
            l.fineAngle,
            current.angle,
            -45,
            45,
            '°',
            (v) => onAdjust(angle: v),
          ),
        if (selectionCount > 1)
          _slider(
            'fine-transform-angle',
            l.fineGroupAngle,
            _transformValue('angle'),
            -45,
            45,
            '°',
            (value) => onTransform('angle', value),
          ),
        _slider(
          'fine-transform-horizontal',
          l.finePerspectiveX,
          _transformValue('horizontal'),
          -35,
          35,
          '%',
          (value) => onTransform('horizontal', value),
        ),
        _slider(
          'fine-transform-vertical',
          l.finePerspectiveY,
          _transformValue('vertical'),
          -35,
          35,
          '%',
          (value) => onTransform('vertical', value),
        ),
        _slider(
          'fine-opacity',
          l.fineOpacity,
          current.opacity,
          0,
          100,
          '%',
          (v) => onAdjust(opacity: v),
        ),
        _slider(
          'fine-thickness',
          l.fineThickness,
          current.thickness,
          math
              .min(current.thickness, -20 - (baseLook.thickness * 10).round())
              .clamp(-20, 0),
          math
              .max(current.thickness, 20 - (baseLook.thickness * 10).round())
              .clamp(0, 20),
          ' px',
          (v) => onAdjust(thickness: v),
          delta: true,
        ),
        _slider(
          'fine-softness',
          l.fineSoftness,
          current.softness,
          math.min(current.softness, -(baseLook.softness * 10).round()),
          math.max(current.softness, 20 - (baseLook.softness * 10).round()),
          ' px',
          (v) => onAdjust(softness: v),
          delta: true,
        ),
      ],
    );
  }
}
