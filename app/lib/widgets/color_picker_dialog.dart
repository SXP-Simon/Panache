import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// Shared HSV color editor. The caller decides what the chosen color affects.
class ColorPickerDialog extends StatefulWidget {
  const ColorPickerDialog({
    super.key,
    required this.id,
    required this.title,
    required this.color,
    required this.presets,
    this.onPreview,
  });

  final String id, title;
  final Color color;
  final List<(String, Color)> presets;
  final ValueChanged<Color>? onPreview;

  static String hexOf(Color color) =>
      '#${(color.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  @override
  State<ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<ColorPickerDialog> {
  late HSVColor selection = HSVColor.fromColor(widget.color);
  late final hex = TextEditingController(
    text: ColorPickerDialog.hexOf(widget.color),
  );
  int? pointer;
  bool invalid = false;

  void confirm() {
    if (!RegExp(r'^#?[0-9a-fA-F]{6}$').hasMatch(hex.text.trim())) {
      setState(() => invalid = true);
      return;
    }
    Navigator.pop(context, selection.toColor());
  }

  @override
  void dispose() {
    hex.dispose();
    super.dispose();
  }

  void select(HSVColor next, {bool updateHex = true}) {
    final color = next.toColor();
    setState(() {
      selection = next;
      invalid = false;
    });
    if (updateHex) hex.text = ColorPickerDialog.hexOf(color);
    widget.onPreview?.call(color);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final hueColor = HSVColor.fromAHSV(1, selection.hue, 1, 1).toColor();
    return AlertDialog(
      scrollable: true,
      title: Text(widget.title),
      content: SizedBox(
        width: 310,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l.inkColorArea),
            const SizedBox(height: 6),
            SizedBox(
              height: 150,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  final height = constraints.maxHeight;
                  void choose(Offset position) => select(
                    selection
                        .withSaturation((position.dx / width).clamp(0, 1))
                        .withValue(1 - (position.dy / height).clamp(0, 1)),
                  );
                  return RawGestureDetector(
                    gestures: {
                      EagerGestureRecognizer:
                          GestureRecognizerFactoryWithHandlers<
                            EagerGestureRecognizer
                          >(EagerGestureRecognizer.new, (_) {}),
                    },
                    child: Listener(
                      key: ValueKey('${widget.id}-area'),
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: (event) {
                        if (pointer != null ||
                            event.buttons != kPrimaryButton) {
                          return;
                        }
                        pointer = event.pointer;
                        choose(event.localPosition);
                      },
                      onPointerMove: (event) {
                        if (event.pointer == pointer) {
                          choose(event.localPosition);
                        }
                      },
                      onPointerUp: (event) {
                        if (event.pointer == pointer) pointer = null;
                      },
                      onPointerCancel: (event) {
                        if (event.pointer == pointer) pointer = null;
                      },
                      child: Stack(
                        fit: StackFit.expand,
                        clipBehavior: Clip.none,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [Colors.white, hueColor],
                                ),
                              ),
                              child: const DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [Colors.transparent, Colors.black],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            left: selection.saturation * width - 8,
                            top: (1 - selection.value) * height - 8,
                            child: IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Colors.white,
                                    width: 2,
                                  ),
                                  boxShadow: const [
                                    BoxShadow(
                                      color: Colors.black87,
                                      blurRadius: 2,
                                    ),
                                  ],
                                ),
                                child: const SizedBox.square(dimension: 16),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            Text(l.inkHue),
            Stack(
              alignment: Alignment.center,
              children: [
                Positioned(
                  left: 24,
                  right: 24,
                  child: Container(
                    height: 10,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(5),
                      gradient: const LinearGradient(
                        colors: [
                          Color(0xffff0000),
                          Color(0xffffff00),
                          Color(0xff00ff00),
                          Color(0xff00ffff),
                          Color(0xff0000ff),
                          Color(0xffff00ff),
                          Color(0xffff0000),
                        ],
                      ),
                    ),
                  ),
                ),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(trackHeight: 0),
                  child: Semantics(
                    label: l.inkHue,
                    child: Slider(
                      key: ValueKey('${widget.id}-hue'),
                      activeColor: hueColor,
                      max: 360,
                      value: selection.hue,
                      onChanged: (hue) => select(selection.withHue(hue)),
                    ),
                  ),
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final (label, color) in widget.presets)
                  ActionChip(
                    avatar: ColorSwatchIndicator(color),
                    label: Text(label),
                    onPressed: () => select(
                      HSVColor.fromColor(
                        color.withValues(alpha: selection.alpha),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                ColorSwatchIndicator(selection.toColor()),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    key: ValueKey('${widget.id}-hex'),
                    controller: hex,
                    decoration: InputDecoration(
                      labelText: l.themeColorHex,
                      errorText: invalid ? l.themeColorInvalid : null,
                      errorMaxLines: 2,
                    ),
                    autocorrect: false,
                    maxLength: 7,
                    buildCounter: (
                      _, {
                      required currentLength,
                      required isFocused,
                      maxLength,
                    }) => null,
                    onSubmitted: (_) => confirm(),
                    onChanged: (input) {
                      final digits = input.trim().replaceFirst('#', '');
                      if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(digits)) return;
                      final color = Color(
                        0xff000000 | int.parse(digits, radix: 16),
                      );
                      select(
                        HSVColor.fromColor(
                          color.withValues(alpha: selection.alpha),
                        ),
                        updateHex: false,
                      );
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.cancel),
        ),
        FilledButton(
          key: ValueKey('${widget.id}-apply'),
          onPressed: confirm,
          child: Text(l.apply),
        ),
      ],
    );
  }
}

class ColorSwatchIndicator extends StatelessWidget {
  const ColorSwatchIndicator(this.color, {super.key});
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 28,
    height: 18,
    decoration: BoxDecoration(
      color: color.withValues(alpha: 1),
      border: Border.all(color: Theme.of(context).colorScheme.outline),
      borderRadius: BorderRadius.circular(4),
    ),
  );
}
