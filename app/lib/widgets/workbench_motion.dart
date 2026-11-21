import 'package:flutter/material.dart';

/// Motion belongs to presentation. Business operations never wait for this clock.
abstract final class WorkbenchMotion {
  static const enter = Cubic(.22, 1, .36, 1);
  static const selection = Duration(milliseconds: 180);
  static const pane = Duration(milliseconds: 300);
  static const page = Duration(milliseconds: 360);
}

/// Keeps each pane mounted once, including its form fields and scroll position.
/// Only the selected pane can receive input, focus or accessibility traversal.
class RetainedPaneSwitcher extends StatefulWidget {
  const RetainedPaneSwitcher({
    super.key,
    required this.index,
    required this.children,
  }) : assert(index >= 0 && index < children.length);

  final int index;
  final List<Widget> children;

  @override
  State<RetainedPaneSwitcher> createState() => _RetainedPaneSwitcherState();
}

class _RetainedPaneSwitcherState extends State<RetainedPaneSwitcher>
    with SingleTickerProviderStateMixin {
  late final _clock = AnimationController(
    vsync: this,
    duration: WorkbenchMotion.pane,
    value: 1,
  )..addStatusListener(_finished);
  // Preserve every still-visible layer when a third destination interrupts.
  // The tracks share a vsync clock but the departing surface settles first.
  final _slides = <int, Animation<Offset>>{};
  final _fades = <int, Animation<double>>{};
  bool _reduced = false;

  void _clear() {
    _slides.clear();
    _fades.clear();
  }

  void _finished(AnimationStatus status) {
    if (status == AnimationStatus.completed && _slides.isNotEmpty) {
      setState(_clear);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = MediaQuery.disableAnimationsOf(context);
    if (_reduced) {
      _clock.stop();
      _clear();
    }
  }

  @override
  void didUpdateWidget(RetainedPaneSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_reduced || oldWidget.index == widget.index) return;
    final direction = widget.index > oldWidget.index ? 1.0 : -1.0;
    final entering = _clock.drive(CurveTween(curve: WorkbenchMotion.enter));
    final leaving = _clock.drive(
      CurveTween(curve: const Interval(0, .72, curve: Curves.easeOut)),
    );
    for (var i = 0; i < widget.children.length; i++) {
      final selected = i == widget.index;
      final alpha = _fades[i]?.value ?? (i == oldWidget.index ? 1.0 : 0.0);
      if (!selected && alpha == 0) {
        _slides.remove(i);
        _fades.remove(i);
        continue;
      }
      final offset =
          _slides[i]?.value ??
          (selected ? Offset(.085 * direction, 0) : Offset.zero);
      final progress = selected ? entering : leaving;
      _slides[i] = Tween<Offset>(
        begin: offset,
        end: selected ? Offset.zero : Offset(-.035 * direction, 0),
      ).animate(progress);
      _fades[i] = Tween<double>(
        begin: alpha,
        end: selected ? 1 : 0,
      ).animate(progress);
    }
    _clock.forward(from: 0);
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRect(
    child: Stack(
      fit: StackFit.expand,
      children: [
        for (var index = 0; index < widget.children.length; index++)
          Positioned.fill(
            key: ValueKey(index),
            child: Offstage(
              offstage: index != widget.index && !_slides.containsKey(index),
              child: TickerMode(
                enabled: index == widget.index,
                child: ExcludeFocus(
                  excluding: index != widget.index,
                  child: IgnorePointer(
                    ignoring: index != widget.index,
                    child: ExcludeSemantics(
                      excluding: index != widget.index,
                      child: FadeTransition(
                        opacity:
                            _fades[index] ?? const AlwaysStoppedAnimation(1),
                        child: SlideTransition(
                          position:
                              _slides[index] ??
                              const AlwaysStoppedAnimation(Offset.zero),
                          child: RepaintBoundary(
                            child: Material(
                              animationDuration: Duration.zero,
                              type:
                                  Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? MaterialType.transparency
                                  : MaterialType.canvas,
                              color: Theme.of(context).colorScheme.surface,
                              child: widget.children[index],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}
