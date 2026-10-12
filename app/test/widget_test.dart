import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/main.dart';
import 'package:handwriting_app/services/workspace.dart';

void main() {
  for (final locale in [const Locale('zh'), const Locale('en')]) {
    testWidgets('MD3 工作台 ${locale.languageCode} 的窄屏和宽屏布局', (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final w = Workspace()..fonts = ['test.ttf'];
      w.settings.font = 'test.ttf';
      addTearDown(w.dispose);
      for (final width in [320.0, 375.0, 768.0, 1024.0, 1440.0]) {
        tester.view.physicalSize = Size(width, 900);
        await tester.pumpWidget(HandwritingApp(locale: locale, workspace: w));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('text-editor')), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });
  }
  testWidgets('输入与参数更新保持焦点，并支持明暗主题与语言切换', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final w = Workspace()..fonts = ['test.ttf'];
    w.settings.font = 'test.ttf';
    addTearDown(w.dispose);
    await tester.pumpWidget(HandwritingApp(workspace: w));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('text-editor')), '测试文字');
    await tester.pump();
    expect(w.text, '测试文字');
    final size = find.byKey(const ValueKey('font_size-0'));
    await tester.enterText(size, '80');
    await tester.pump();
    final field = tester.widget<TextFormField>(size);
    expect(field.enabled, isTrue);
    expect(w.settings.values['font_size'], '80');
    await tester.tap(find.byTooltip('切换明暗主题'));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byKey(const ValueKey('text-editor'))))
          .brightness,
      Brightness.dark,
    );
    await tester.tap(find.byTooltip('切换语言'));
    await tester.pumpAndSettle();
    expect(find.text('Your writing'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
