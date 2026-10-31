import 'package:flutter/material.dart';

/// Motion belongs to presentation. Business operations never wait for this clock.
abstract final class WorkbenchMotion {
  static const pane = Duration(milliseconds: 240);
  static const page = Duration(milliseconds: 280);
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
  late final _progress = _clock.drive(CurveTween(curve: Curves.easeOutCubic));
  late int _to = widget.index;
  int? _from;
  double _direction = 1;
  bool _reduced = false;

  void _finished(AnimationStatus status) {
    if (_from == null) return;
    if (status == AnimationStatus.completed && widget.index == _to ||
        status == AnimationStatus.dismissed && widget.index == _from) {
      setState(() {
        _from = null;
        _to = widget.index;
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = MediaQuery.disableAnimationsOf(context);
    if (_reduced) {
      _clock.stop();
      _from = null;
      _to = widget.index;
    }
  }

  @override
  void didUpdateWidget(RetainedPaneSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index == widget.index) return;
    if (_reduced) {
      _from = null;
      _to = widget.index;
    } else if (_from != null && widget.index == _from) {
      _clock.reverse();
    } else if (_from != null && widget.index == _to) {
      _clock.forward();
    } else {
      _from = oldWidget.index;
      _to = widget.index;
      _direction = _to > _from! ? 1 : -1;
      _clock.forward(from: 0);
    }
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
        for (final index in [
          for (var i = 0; i < widget.children.length; i++)
            if (i != _to && i != _from) i,
          if (_direction > 0) ...[?_from, _to] else ...[_to, ?_from],
        ])
          Positioned.fill(
            key: ValueKey(index),
            // Stable widget ancestry is essential for EditableText and Form.
            child: Offstage(
              offstage: index != _to && index != _from,
              child: TickerMode(
                enabled: index == widget.index,
                child: ExcludeFocus(
                  excluding: index != widget.index,
                  child: IgnorePointer(
                    ignoring: index != widget.index,
                    child: ExcludeSemantics(
                      excluding: index != widget.index,
                      child: SlideTransition(
                        position: _from == null
                            ? const AlwaysStoppedAnimation(Offset.zero)
                            : Tween<Offset>(
                                begin: index == _to
                                    ? Offset(_direction > 0 ? 1 : -.15, 0)
                                    : Offset.zero,
                                end: index == _to
                                    ? Offset.zero
                                    : Offset(_direction > 0 ? -.15 : 1, 0),
                              ).animate(_progress),
                        child: RepaintBoundary(
                          child: Material(
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
      ],
    ),
  );
}
