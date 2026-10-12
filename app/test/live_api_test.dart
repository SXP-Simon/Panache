import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/services/api.dart';
import 'package:handwriting_app/services/workspace.dart';

void main() {
  const base = String.fromEnvironment('LIVE_API_BASE');
  test(
    '真实 Python 后端：文本导入、单页/多页 PNG、PDF 与 ZIP',
    () async {
      HttpOverrides.global = null;
      final w = Workspace(api: HandwritingApi(base));
      addTearDown(w.dispose);
      await w.connect();
      expect(w.connected, isTrue, reason: w.error);
      final imported = await w.api.importFile(
        '/api/textfileprocess',
        Upload('flutter-smoke.txt', utf8.encode('你好 Flutter')),
      );
      expect(imported['text'], '你好 Flutter');
      w.text = imported['text'];
      w.settings.values.addAll({
        'font_size': '32',
        'line_spacing': '45',
        'width': '420',
        'height': '320',
        'left_margin': '20',
        'right_margin': '20',
        'top_margin': '20',
        'bottom_margin': '20',
        'strikethrough_probability': '0',
      });
      await w.generate();
      expect(w.error, isEmpty);
      expect(w.pages.single.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
      w.settings.fullPreview = true;
      w.text = '第一页\n---\n第二页';
      await w.generate();
      expect(w.error, isEmpty);
      expect(w.pages.length, 2);
      for (final pdf in [true, false]) {
        await w.generate(preview: false, pdf: pdf);
        expect(w.error, isEmpty);
        expect(
          latin1.decode(w.exportBytes!.take(pdf ? 5 : 2).toList()),
          pdf ? '%PDF-' : 'PK',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: base.isEmpty
        ? '通过 --dart-define=LIVE_API_BASE=http://127.0.0.1:5005 启用'
        : false,
  );
}
