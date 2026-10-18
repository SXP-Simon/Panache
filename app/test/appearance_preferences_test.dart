import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:handwriting_app/services/appearance_preferences.dart';

void main() {
  setUp(
    () => SharedPreferences.setMockInitialValues({
      AppearancePreferences.colorKey: 0xFF123456,
    }),
  );
  test('late restoration cannot replace a newly selected seed; rapid writes retain latest color', () async {
    final delayed = Completer<SharedPreferences>();
    final preferences = await SharedPreferences.getInstance();
    final appearance = AppearancePreferences(open: () => delayed.future);
    final restoring = appearance.restore();
    appearance.setColor(const Color(0xFF7955A3));
    appearance.setColor(const Color(0xFF147D79));
    delayed.complete(preferences);
    await restoring;
    await appearance.settled;
    expect(appearance.color, const Color(0xFF147D79));
    expect(preferences.getInt(AppearancePreferences.colorKey), 0xFF147D79);
    appearance.dispose();
  });
  test('storage errors retain the chosen session color and are reported without escaping', () async {
    final appearance = AppearancePreferences(
      open: () async => throw StateError('unavailable'),
    );
    await appearance.restore();
    appearance.setColor(const Color(0xFF7955A3));
    await appearance.settled;
    expect(appearance.color, const Color(0xFF7955A3));
    expect(appearance.saveFailed, isTrue);
    appearance.dispose();
  });
  test('dispose while restore or save is pending is safe', () async {
    final delayed = Completer<SharedPreferences>();
    final appearance = AppearancePreferences(open: () => delayed.future);
    final restoring = appearance.restore();
    appearance.setColor(const Color(0xFF7955A3));
    appearance.dispose();
    delayed.complete(await SharedPreferences.getInstance());
    await restoring;
    await appearance.settled;
  });
}
