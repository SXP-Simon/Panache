import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/handwriting_theme.dart';

/// UI preferences have their own storage key and never enter paper settings.
class AppearancePreferences extends ChangeNotifier {
  AppearancePreferences({Future<SharedPreferences> Function()? open})
    : _open = open ?? SharedPreferences.getInstance;
  final Future<SharedPreferences> Function() _open;
  static const colorKey = 'panache.themeColor';
  static const secondaryColorKey = 'panache.secondaryThemeColor';
  static const motionKey = 'panache.reduceMotion';
  bool reduceMotion = false;
  int _motionRevision = 0;
  Color color = defaultThemeColor;
  Color secondaryColor = defaultSecondaryThemeColor;
  int _secondaryRevision = 0;
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
    final secondaryRevision = _secondaryRevision;
    try {
      final preferences = await _open();
      final value = preferences.getInt(colorKey);
      final secondaryValue = preferences.getInt(secondaryColorKey);
      if (!_disposed && motionRevision == _motionRevision) {
        reduceMotion = preferences.getBool(motionKey) ?? false;
        _emit();
      }
      if (!_disposed && revision == _revision && value != null) {
        color = Color(value | 0xFF000000);
        _emit();
      }
      if (!_disposed &&
          secondaryRevision == _secondaryRevision &&
          secondaryValue != null) {
        secondaryColor = Color(secondaryValue | 0xFF000000);
        _emit();
      }
    } catch (_) {
      /* Unavailable storage keeps the usable default theme. */
    }
  }

  Future<bool> setSecondaryColor(Color value) {
    secondaryColor = value;
    ++_secondaryRevision;
    _emit();
    return _save(
      (storage) => storage.setInt(secondaryColorKey, value.toARGB32()),
    );
  }

  Future<bool> setColor(Color value) async {
    color = value;
    saveFailed = false;
    final revision = ++_revision;
    _emit();
    final success = await _save(
      (storage) => storage.setInt(colorKey, value.toARGB32()),
    );
    if (revision == _revision) {
      saveFailed = !success;
      _emit();
    }
    return success;
  }

  Future<bool> setReduceMotion(bool value) {
    reduceMotion = value;
    ++_motionRevision;
    _emit();
    return _save((storage) => storage.setBool(motionKey, value));
  }

  Future<bool> _save(Future<bool> Function(SharedPreferences) write) {
    var saved = false;
    _writes = _writes.then((_) async {
      try {
        saved = await write(await _open());
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
