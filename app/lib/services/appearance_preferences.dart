import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/handwriting_theme.dart';

/// UI preferences have their own storage key and never enter paper settings.
class AppearancePreferences extends ChangeNotifier {
  AppearancePreferences({Future<SharedPreferences> Function()? open})
    : _open = open ?? SharedPreferences.getInstance;
  final Future<SharedPreferences> Function() _open;
  static const colorKey = 'panache.themeColor';
  static const motionKey = 'panache.reduceMotion';
  bool reduceMotion = false;
  int _motionRevision = 0;
  Color color = defaultThemeColor;
  bool saveFailed = false;
  bool _disposed = false;
  int _revision = 0;
  Future<void> _writes = Future.value();
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  Future<void> restore() async {
    final revision = _revision;
    final motionRevision = _motionRevision;
    try {
      final preferences = await _open();
      final value = preferences.getInt(colorKey);
      if (!_disposed && motionRevision == _motionRevision) {
        reduceMotion = preferences.getBool(motionKey) ?? false;
        _emit();
      }
      if (!_disposed && revision == _revision && value != null) {
        color = Color(value | 0xFF000000);
        _emit();
      }
    } catch (_) {
      /* Unavailable storage keeps the usable default theme. */
    }
  }

  Future<bool> setColor(Color value) {
    var success = false;
    color = value;
    saveFailed = false;
    final revision = ++_revision;
    _emit();
    _writes = _writes.then((_) async {
      try {
        final saved = await (await _open()).setInt(colorKey, value.toARGB32());
        success = saved;
        if (revision == _revision) {
          saveFailed = !saved;
          _emit();
        }
      } catch (_) {
        if (revision == _revision) {
          saveFailed = true;
          _emit();
        }
      }
    });
    return _writes.then((_) => success);
  }

  Future<bool> setReduceMotion(bool value) {
    reduceMotion = value;
    ++_motionRevision;
    _emit();
    var saved = false;
    _writes = _writes.then((_) async {
      try {
        saved = await (await _open()).setBool(motionKey, value);
      } catch (_) {
        saved = false;
      }
    });
    return _writes.then((_) => saved);
  }

  Future<void> get settled => _writes;
  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
