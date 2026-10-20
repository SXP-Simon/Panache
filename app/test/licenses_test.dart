import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/main.dart';
import 'package:handwriting_app/services/licenses.dart';
import 'package:handwriting_app/services/workspace.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('随包许可与原始声明一致，四款 OFL 字体包含完整许可', () async {
    const originals = {
      'project-MIT.txt': '../LICENSE',
      'handright-BSD-3-Clause.txt':
          '../crates/handwriting-core/licenses/handright-LICENSE.txt',
      'handright-NOTICE.txt': '../crates/handwriting-core/NOTICE',
      'katex-fonts-MIT.txt':
          '../crates/handwriting-core/licenses/katex-fonts-MIT.txt',
    };
    for (final entry in originals.entries) {
      final bundled = await rootBundle.loadString(
        'packages/handwriting_assets/licenses/${entry.key}',
      );
      expect(bundled, await File(entry.value).readAsString());
    }
    for (final font in [
      'lxgw-wenkai',
      'lxgw-marker-gothic',
      'yozai',
      'zhimangxing',
    ]) {
      final text = await rootBundle.loadString(
        'packages/handwriting_assets/licenses/$font-OFL.txt',
      );
      expect(text, contains('SIL OPEN FONT LICENSE Version 1.1'));
      expect(text, contains('PERMISSION & CONDITIONS'));
      expect(text, contains('DISCLAIMER'));
    }
  });

  testWidgets('关于页面可打开随包项目、算法与字体许可', (tester) async {
    LicenseRegistry.reset();
    addTearDown(LicenseRegistry.reset);
    registerBundledLicenses();
    final entries = await tester.runAsync(
      () => LicenseRegistry.licenses.toList(),
    );
    final text = entries!
        .expand((entry) => entry.paragraphs)
        .map((paragraph) => paragraph.text)
        .join('\n');
    expect(text, contains('Copyright (c) 2025 Liuweiqing'));
    expect(text, contains('Chenghui LI'));
    expect(text, contains('SIL OPEN FONT LICENSE Version 1.1'));

    final workspace = Workspace();
    addTearDown(workspace.dispose);
    await tester.pumpWidget(HandwritingApp(workspace: workspace));
    Navigator.of(tester.element(find.byType(Scaffold).first))
        .pushNamed('/About');
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('开源许可'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('开源许可'));
      await tester.pump();
      await LicenseRegistry.licenses.toList();
    });
    await tester.pumpAndSettle();
    expect(find.byType(LicensePage), findsOneWidget);
    expect(find.text('handwriting-web'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
