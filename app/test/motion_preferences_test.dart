import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:handwriting_app/main.dart';
import 'package:handwriting_app/services/appearance_preferences.dart';
import 'package:handwriting_app/services/workspace.dart';

void main() {
  testWidgets(
    'compact theme switch uses one transition to return to the workbench',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        AppearancePreferences.modeKey: 'light',
      });
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(960, 650);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final workspace = Workspace();
      addTearDown(workspace.dispose);
      await tester.pumpWidget(HandwritingApp(workspace: workspace));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('app-preferences')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('切换明暗主题'));
      await tester.pump();
      expect(find.byType(BottomSheet), findsNothing);
      final context = tester.element(find.byType(Scaffold).first);
      expect(Theme.of(context).brightness, Brightness.dark);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('app-preferences')), findsOneWidget);
    },
  );

  test(
    'motion choice beats late restore without losing stored theme color',
    () async {
      SharedPreferences.setMockInitialValues({
        AppearancePreferences.motionKey: false,
        AppearancePreferences.colorKey: 0xff123456,
      });
      final ready = Completer<SharedPreferences>();
      final preferences = AppearancePreferences(open: () => ready.future);
      final restore = preferences.restore();
      final save = preferences.setReduceMotion(true);
      ready.complete(await SharedPreferences.getInstance());
      await restore;
      expect(await save, isTrue);
      expect(preferences.reduceMotion, isTrue);
      expect(preferences.color, const Color(0xff123456));
      preferences.dispose();
      final restarted = AppearancePreferences();
      await restarted.restore();
      expect(restarted.reduceMotion, isTrue);
      restarted.dispose();
    },
  );

  testWidgets(
    'app setting disables motion and cannot override system preference',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(375, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final workspace = Workspace();
      addTearDown(workspace.dispose);
      await tester.pumpWidget(HandwritingApp(workspace: workspace));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('app-preferences')));
      await tester.pumpAndSettle();
      final toggle = find.byKey(const ValueKey('reduce-motion'));
      final settingsScroll = find.descendant(
        of: find.byKey(const ValueKey('app-settings-list')),
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(toggle, 160, scrollable: settingsScroll);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(MediaQuery.disableAnimationsOf(tester.element(toggle)), isTrue);
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      expect(MediaQuery.disableAnimationsOf(tester.element(toggle)), isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
