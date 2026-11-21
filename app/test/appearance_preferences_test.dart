import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:handwriting_app/services/appearance_preferences.dart';
import 'package:handwriting_app/theme/handwriting_theme.dart';

void main() {
  test(
    'old Iris becomes petal-first while custom palettes retain their order',
    () async {
      const green = Color(0xff2d5016), violet = Color(0xff8b6db5);
      final oldPair = [
        green.toARGB32().toString(),
        violet.toARGB32().toString(),
      ];
      for (final stored in <Map<String, Object>>[
        {},
        {'panache.themePalette': oldPair},
        {
          AppearancePreferences.colorKey: green.toARGB32(),
          AppearancePreferences.secondaryColorKey: violet.toARGB32(),
        },
      ]) {
        SharedPreferences.setMockInitialValues(stored);
        final prefs = AppearancePreferences();
        await prefs.restore();
        expect((prefs.color, prefs.secondaryColor), (violet, green));
        await prefs.setPalette(green, violet);
        final restarted = AppearancePreferences();
        await restarted.restore();
        expect((restarted.color, restarted.secondaryColor), (green, violet));
        restarted.dispose();
        prefs.dispose();
      }
      SharedPreferences.setMockInitialValues({
        AppearancePreferences.colorKey: 0xff347566,
      });
      final partial = AppearancePreferences();
      await partial.restore();
      expect(
        (partial.color, partial.secondaryColor),
        (const Color(0xff347566), defaultThemeColor),
      );
      partial.dispose();
    },
  );
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
    final restarted = AppearancePreferences();
    await restarted.restore();
    expect(restarted.color, const Color(0xFF147D79));
    restarted.dispose();
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
  test('legacy blue and its accent restore exactly until a paired palette is chosen', () async {
    SharedPreferences.setMockInitialValues({
      AppearancePreferences.colorKey: 0xff438fc1,
      AppearancePreferences.secondaryColorKey: 0xff438fc1,
    });
    final appearance = AppearancePreferences();
    await appearance.restore();
    expect(appearance.color, const Color(0xff438fc1));
    expect(appearance.secondaryColor, const Color(0xff438fc1));
    var notifications = 0;
    appearance.addListener(() => notifications++);
    expect(
      await appearance.setPalette(
        const Color(0xff27665d),
        const Color(0xffa28247),
      ),
      isTrue,
    );
    expect(notifications, 1);
    final restarted = AppearancePreferences();
    await restarted.restore();
    expect(restarted.color, appearance.color);
    expect(restarted.secondaryColor, appearance.secondaryColor);
    restarted.dispose();
    appearance.dispose();
  });
  test('opening the guide during restore keeps it read on restart', () async {
    final delayed = Completer<SharedPreferences>();
    final appearance = AppearancePreferences(open: () => delayed.future);
    final restoring = appearance.restore();
    final saving = appearance.markGuideRead();
    delayed.complete(await SharedPreferences.getInstance());
    await restoring;
    await saving;
    expect(appearance.guideUnread, isFalse);
    appearance.dispose();

    final restarted = AppearancePreferences();
    await restarted.restore();
    expect(restarted.guideUnread, isFalse);
    restarted.dispose();
  });

  test(
    'mode chosen during restore persists and can return to the system',
    () async {
      final delayed = Completer<SharedPreferences>();
      final appearance = AppearancePreferences(open: () => delayed.future);
      final restore = appearance.restore();
      final save = appearance.setMode(ThemeMode.dark);
      delayed.complete(await SharedPreferences.getInstance());
      await restore;
      expect(await save, isTrue);
      expect(appearance.mode, ThemeMode.dark);
      appearance.dispose();
      final restarted = AppearancePreferences();
      await restarted.restore();
      expect(restarted.mode, ThemeMode.dark);
      expect(await restarted.setMode(ThemeMode.system), isTrue);
      restarted.dispose();
      final following = AppearancePreferences();
      await following.restore();
      expect(following.mode, ThemeMode.system);
      following.dispose();
    },
  );

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
