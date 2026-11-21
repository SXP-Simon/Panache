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
  static const paletteKey = 'panache.themePalette';
  static const modeKey = 'panache.themeMode';
  static const motionKey = 'panache.reduceMotion';
  static const guideReadKey = 'panache.quickStartRead';
  bool? _guideRead;
  bool get guideUnread => _guideRead == false;
  bool reduceMotion = false;
  ThemeMode mode = ThemeMode.system;
  int _modeRevision = 0;
  int _motionRevision = 0;
  Color color = defaultThemeColor;
  Color secondaryColor = defaultSecondaryThemeColor;
  int _secondaryRevision = 0;
  int _paletteRevision = 0;
  bool saveFailed = false;
  bool _disposed = false;
  int _revision = 0;
  Future<void> _writes = Future.value();
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  Future<void> restore() async {
    final revision = _revision;
    final modeRevision = _modeRevision;
    final motionRevision = _motionRevision;
    final secondaryRevision = _secondaryRevision;
    try {
      final preferences = await _open();
      if (_disposed) return;
      if (preferences.getBool(guideReadKey) == true) _guideRead = true;
      final (storedPrimary, storedSecondary) = _readPalette(preferences);
      if (modeRevision == _modeRevision) {
        mode = switch (preferences.getString(modeKey)) {
          'light' => ThemeMode.light,
          'dark' => ThemeMode.dark,
          _ => ThemeMode.system,
        };
      }
      if (motionRevision == _motionRevision) {
        reduceMotion = preferences.getBool(motionKey) ?? false;
      }
      if (revision == _revision) color = storedPrimary;
      if (secondaryRevision == _secondaryRevision) {
        secondaryColor = storedSecondary;
      }
    } catch (_) {
      /* Unavailable storage keeps the usable default theme. */
    } finally {
      _guideRead ??= false;
      _emit();
    }
  }

  Future<void> markGuideRead() async {
    if (_guideRead == true) return;
    _guideRead = true;
    _emit();
    await _save((storage) => storage.setBool(guideReadKey, true));
  }

  (Color, Color) _readPalette(SharedPreferences storage) {
    final pair = storage.getStringList(paletteKey);
    if (pair != null && pair.length == 2) {
      final primary = int.tryParse(pair[0]);
      final accent = int.tryParse(pair[1]);
      if (primary != null && accent != null) {
        return (Color(primary | 0xff000000), Color(accent | 0xff000000));
      }
    }
    return (
      Color(
        (storage.getInt(colorKey) ?? defaultThemeColor.toARGB32()) | 0xff000000,
      ),
      Color(
        (storage.getInt(secondaryColorKey) ??
                defaultSecondaryThemeColor.toARGB32()) |
            0xff000000,
      ),
    );
  }

  Future<bool> setPalette(Color primary, Color accent) =>
      _updatePalette(primary, accent);
  Future<bool> setColor(Color value) => _updatePalette(value, null);
  Future<bool> setSecondaryColor(Color value) => _updatePalette(null, value);

  Future<bool> _updatePalette(Color? primary, Color? accent) async {
    final generation = ++_paletteRevision;
    if (primary != null) {
      color = primary;
      ++_revision;
    }
    if (accent != null) {
      secondaryColor = accent;
      ++_secondaryRevision;
    }
    saveFailed = false;
    _emit();
    final saved = await _save((storage) {
      final previous = _readPalette(storage);
      return storage.setStringList(paletteKey, [
        (primary ?? previous.$1).toARGB32().toString(),
        (accent ?? previous.$2).toARGB32().toString(),
      ]);
    });
    if (generation == _paletteRevision && !saved) {
      saveFailed = true;
      _emit();
    }
    return saved;
  }

  Future<bool> setMode(ThemeMode value) {
    mode = value;
    ++_modeRevision;
    _emit();
    return _save((storage) => storage.setString(modeKey, value.name));
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
