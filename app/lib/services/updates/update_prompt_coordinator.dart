import 'dart:async';

import 'update_controller.dart';

/// Only a visible, idle route may claim a notice shared by all app routes.
class UpdatePromptCoordinator {
  UpdatePromptCoordinator({
    required this.controller,
    required this.ready,
    required this.present,
    this.retryDelay = const Duration(milliseconds: 400),
  }) {
    controller.addListener(evaluate);
    evaluate();
  }
  final UpdateController controller;
  final bool Function() ready;
  final Future<void> Function(UpdateNotice) present;
  final Duration retryDelay;
  Timer? _timer;
  bool _disposed = false, _presenting = false;
  int _handled = 0;

  void evaluate() {
    if (_disposed || _presenting || _timer?.isActive == true) return;
    final notice = controller.notice;
    if (notice == null || notice.sequence <= _handled) return;
    _timer = Timer(Duration.zero, _attempt);
  }

  Future<void> _attempt() async {
    if (_disposed || _presenting) return;
    final candidate = controller.notice;
    if (candidate == null || candidate.sequence <= _handled) return;
    if (!ready()) {
      _timer = Timer(retryDelay, _attempt);
      return;
    }
    _handled = candidate.sequence;
    if (!controller.claimNotice(candidate)) return;
    _presenting = true;
    try {
      await present(candidate);
    } catch (_) {
      // A navigator removed during presentation must not crash the app.
    } finally {
      _presenting = false;
      evaluate();
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    controller.removeListener(evaluate);
  }
}
