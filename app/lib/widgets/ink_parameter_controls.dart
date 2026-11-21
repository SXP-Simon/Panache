import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/ink_page.dart';
import '../models/settings.dart';
import 'ink_color_control.dart';

class InkParameterControls extends StatelessWidget {
  const InkParameterControls({
    super.key,
    required this.look,
    required this.onChanged,
    required this.colorKey,
  });

  final InkLook look;
  final ValueChanged<InkLook>? onChanged;
  final Key colorKey;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Column(
      children: [
        InkColorControl(
          key: colorKey,
          color: Color(look.color),
          onChanged: onChanged == null
              ? null
              : (color) => onChanged!((
                  opacity: look.opacity,
                  thickness: look.thickness,
                  softness: look.softness,
                  color: color.toARGB32(),
                )),
        ),
        for (final (i, label, id, value) in [
          (0, l.inkOpacity, 'ink-opacity', look.opacity.toDouble()),
          (1, l.inkThickness, 'ink-thickness', look.thickness),
          (2, l.inkSoftness, 'ink-softness', look.softness),
        ])
          NumericSlider(
            label: label,
            id: id,
            value: value,
            parameter: inkParameters[i],
            unit: i == 0 ? '%' : 'px',
            onChanged: onChanged == null
                ? null
                : (next) => onChanged!((
                    opacity: i == 0 ? next.round() : look.opacity,
                    thickness: i == 1 ? next : look.thickness,
                    softness: i == 2 ? next : look.softness,
                    color: look.color,
                  )),
          ),
      ],
    );
  }
}

class NumericSlider extends StatefulWidget {
  const NumericSlider({
    super.key,
    required this.label,
    required this.id,
    required this.value,
    required this.parameter,
    required this.unit,
    required this.onChanged,
  });

  final String label, id, unit;
  final double value;
  final Parameter parameter;
  final ValueChanged<double>? onChanged;

  @override
  State<NumericSlider> createState() => _NumericSliderState();
}

class _NumericSliderState extends State<NumericSlider> {
  late final _controller = TextEditingController(text: formatted);
  late final _focus = FocusNode()..addListener(_resetOnBlur);

  int get digits => widget.parameter.fractionalInk ? 1 : 0;
  String get formatted => widget.value.toStringAsFixed(digits);

  void _resetOnBlur() {
    if (!_focus.hasFocus) _controller.text = formatted;
  }

  @override
  void didUpdateWidget(covariant NumericSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value && !_focus.hasFocus) {
      _controller.text = formatted;
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final min = widget.parameter.minimum.toDouble();
    final max = widget.parameter.maximum!.toDouble();
    final multiplier = digits == 0 ? 1 : 10;
    final slider = Semantics(
      label: widget.label,
      child: Slider(
        key: ValueKey(widget.id),
        min: min,
        max: max,
        divisions: ((max - min) * multiplier).round(),
        value: widget.value,
        label: formatted,
        onChanged: widget.onChanged == null
            ? null
            : (value) {
                final next = (value * multiplier).round() / multiplier;
                _controller.text = next.toStringAsFixed(digits);
                widget.onChanged!(next);
              },
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: Text(widget.label)),
              SizedBox(
                width: MediaQuery.textScalerOf(context)
                    .scale(68)
                    .clamp(68, 112)
                    .toDouble(),
                child: Semantics(
                  label: widget.label,
                  child: TextField(
                    key: ValueKey('${widget.id}-number'),
                    controller: _controller,
                    focusNode: _focus,
                    enabled: widget.onChanged != null,
                    keyboardType: TextInputType.numberWithOptions(
                      decimal: digits > 0,
                      signed: min < 0,
                    ),
                    textAlign: TextAlign.end,
                    decoration: InputDecoration(
                      isDense: true,
                      suffixText: widget.unit,
                    ),
                    onChanged: (raw) {
                      if (widget.parameter.accepts(raw)) {
                        widget.onChanged?.call(double.parse(raw));
                      }
                    },
                  ),
                ),
              ),
            ],
          ),
          // Keep the SDK's always-mounted value-indicator portal in the same
          // semantics subtree as its slider when the settings pane is hidden.
          if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows)
            Overlay.wrap(
              alwaysSizeToContent: true,
              clipBehavior: Clip.none,
              child: slider,
            )
          else
            slider,
        ],
      ),
    );
  }
}
