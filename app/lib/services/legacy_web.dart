import 'dart:convert';

import 'package:web/web.dart' as web;

import '../models/settings.dart';

Map<String, dynamic> readLegacyDraft() {
  final values = <String, dynamic>{};
  try {
    for (final key in [
      'text',
      'fill',
      'selectedOption',
      'isUnderlined',
      'enableEnglishSpacing',
      'enableFullPreview',
      ...legacyFields.keys,
    ]) {
      final value = web.window.localStorage.getItem(key);
      if (value != null) {
        try {
          values[key] = jsonDecode(value);
        } catch (_) {
          values[key] = value;
        }
      }
    }
  } catch (_) {
    /* Private browsing may block storage access. */
  }
  return values;
}
