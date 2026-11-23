import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/text_preparation/prepare.dart';

/// Coordinates a preparation job with the editor that requested it. The caller
/// owns the editor and its native undo stack; this stores one formatting step.
class EditorPreparation extends ChangeNotifier {
  EditorPreparation({
    required this.readText,
    required this.applyText,
    required this.onFailure,
    this.start = startTextPreparation,
  });

  final String Function() readText;
  final ValueChanged<String> applyText;
  final VoidCallback onFailure;
  final TextPreparationJob Function(
    String, {
    required String tableMode,
    required bool english,
  })
  start;

  String tableMode = 'latex';
  TextPreparationJob? _job;
  bool _stopping = false;
  ({String original, String formatted, String mode})? _last;

  bool get running => _job != null;
  bool get stopping => _stopping;

  void forgetFormatting() => _last = null;

  String? undoText(String text) =>
      text == _last?.formatted ? _last?.original : null;
  String? redoText(String text) =>
      text == _last?.original ? _last?.formatted : null;

  Future<void> run(String mode, {required bool english}) async {
    if (running) return;
    tableMode = mode;
    final input = readText();
    final previous = _last;
    final alreadyFormatted = previous != null && input == previous.formatted;
    if (alreadyFormatted && mode == previous.mode) return;
    final original = alreadyFormatted ? previous.original : input;
    final job = start(original, tableMode: mode, english: english);
    _job = job;
    _stopping = false;
    notifyListeners();
    try {
      final formatted = await job.result;
      if (_job != job ||
          _stopping ||
          readText() != input ||
          formatted == input) {
        return;
      }
      _last = (original: original, formatted: formatted, mode: mode);
      applyText(formatted);
    } on TextPreparationCancelled {
      // Cancellation preserves the previous formatting step and editor text.
    } catch (_) {
      if (_job == job) onFailure();
    } finally {
      if (_job == job) {
        _job = null;
        _stopping = false;
        notifyListeners();
      }
    }
  }

  Future<void> stop() async {
    final job = _job;
    if (job == null || _stopping) return;
    _stopping = true;
    notifyListeners();
    await job.cancel();
  }

  @override
  void dispose() {
    final job = _job;
    _job = null;
    if (job != null) unawaited(job.cancel());
    super.dispose();
  }
}
