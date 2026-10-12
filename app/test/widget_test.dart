import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/main.dart';

void main() {
  for (final locale in [const Locale('zh'), const Locale('en')]) {
    testWidgets('首页在 ${locale.languageCode} 下支持窄屏和桌面宽度', (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      for (final width in [320.0, 1200.0]) {
        tester.view.physicalSize = Size(width, 800);
        await tester.pumpWidget(HandwritingApp(locale: locale));
        await tester.pumpAndSettle();

        final title = locale.languageCode == 'zh'
            ? '手写体生成器'
            : 'Handwriting Generator';
        expect(find.text(title), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });
  }
}
